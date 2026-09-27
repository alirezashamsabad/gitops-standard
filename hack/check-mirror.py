#!/usr/bin/env python3
"""Is everything this repository declares actually in the mirrors?

NOT ONE OF THE FOUR GATES. It reaches the network, and the gates deliberately
do not; it is the thing an operator runs before turning a component's
sync.automated on, and the question it answers is the one nobody can hold in
their head: twenty-eight images and six charts, of which any single absence is
an ImagePullBackOff under an Application reporting Healthy.

It reads only what the repository itself declares -- platform/*/images.yaml,
tenants/**/images.yaml, every config.yaml image, every chart named by a
component or a workload -- so it cannot drift from what is actually deployed.

THREE OUTCOMES, NOT TWO, and the whole design is about the third.

  present        the mirror has it
  ABSENT         the mirror answered, and does not have it
  COULD NOT LOOK the registry refused, timed out, or did not resolve

A tool that collapses the third into the second reports every image as missing
the moment a VPN drops -- twenty-eight alarms, none of them true, on the day
the network is already the problem. So a failed probe stops the run before a
single verdict is printed, and an individual lookup that cannot be completed is
reported as its own thing and never as an absence. compare-live.sh was hardened
against exactly this and it is the same mistake in a different tool.
"""
import base64
import json
import pathlib
import sys
import urllib.error
import urllib.request

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
TIMEOUT = 25


def die(msg):
    print(f"\nCANNOT ANSWER: {msg}")
    print("  Nothing above is a verdict about any image. A tool that reports")
    print("  everything missing because it could not look is worse than one that")
    print("  stops.")
    sys.exit(2)


def load(p):
    return yaml.safe_load(p.read_text(encoding="utf-8")) if p.exists() else None


def credential_for(host):
    """Whatever this machine already uses to pull, or nothing.

    Nothing is a valid answer: a public project answers anonymously, and most of
    the platform images live in one. What must not happen is treating the 401
    that a private project then returns as an absence.
    """
    cfg = pathlib.Path.home() / ".docker" / "config.json"
    if not cfg.exists():
        return None
    try:
        entry = (json.loads(cfg.read_text()).get("auths") or {}).get(host) or {}
    except ValueError:
        return None
    if entry.get("auth"):
        return entry["auth"]
    if entry.get("username"):
        raw = f"{entry['username']}:{entry.get('password', '')}".encode()
        return base64.b64encode(raw).decode()
    return None


def fetch(url, auth, want_json=True):
    """(payload, status) where status is one of ok / absent / unreachable."""
    req = urllib.request.Request(url)
    if auth:
        req.add_header("Authorization", "Basic " + auth)
    try:
        body = urllib.request.urlopen(req, timeout=TIMEOUT).read()
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None, "absent"
        # 401 and 403 are NOT absences. They are the registry declining to say.
        return None, f"unreachable (HTTP {exc.code})"
    except Exception as exc:                                     # noqa: BLE001
        return None, f"unreachable ({exc})"
    if not want_json:
        return body, "ok"
    try:
        return json.loads(body), "ok"
    except ValueError as exc:
        return None, f"unreachable (not JSON: {exc})"


# --------------------------------------------------------------------------- #
# What the repository declares
# --------------------------------------------------------------------------- #
cluster = load(ROOT / "cluster.yaml") or load(ROOT / "cluster.example.yaml")
if not cluster:
    die("neither cluster.yaml nor cluster.example.yaml is here")
registries = cluster.get("allowedImageRegistries") or []
if not registries:
    die("cluster.yaml declares no allowedImageRegistries, so there is no mirror "
        "to ask")
HOST = registries[0]
AUTH = credential_for(HOST)

images, charts = {}, {}
for f in sorted(ROOT.glob("platform/*/images.yaml")) + \
        sorted(ROOT.glob("tenants/**/images.yaml")) + \
        sorted(ROOT.glob("shared/**/images.yaml")):
    doc = load(f) or {}
    for i in (doc if isinstance(doc, list) else doc.get("images") or []):
        images.setdefault(str(i), []).append(str(f.relative_to(ROOT)))

for pattern in ("tenants/*/*/*/config.yaml", "shared/*/*/*/config.yaml",
                "platform/*/component.yaml"):
    for f in sorted(ROOT.glob(pattern)):
        doc = load(f) or {}
        rel = str(f.relative_to(ROOT))
        im = doc.get("image") or {}
        if isinstance(im, dict) and im.get("repository") and im.get("tag"):
            images.setdefault(f"{im['repository']}:{im['tag']}", []).append(rel)
        ch = doc.get("chart") or {}
        if isinstance(ch, dict) and ch.get("name"):
            charts.setdefault((ch["name"], str(ch.get("version"))), []).append(rel)

if not images and not charts:
    die("this repository declares no images and no charts. That is a repository "
        "at genesis or a bad checkout, and either way there is nothing to check")

# --------------------------------------------------------------------------- #
# Probe first. Nothing is printed about anything until both mirrors answer.
# --------------------------------------------------------------------------- #
print(f"mirror:  {HOST}   ({'with a credential' if AUTH else 'anonymously'})")
_, st = fetch(f"http://{HOST}/v2/", AUTH, want_json=False)
# 401 here is a healthy registry declining an anonymous ping -- it answered.
if st.startswith("unreachable") and "HTTP 401" not in st:
    die(f"the registry did not answer: {st}")

index = {}
for url in sorted(set((cluster.get("chartRepos") or {}).values())):
    body, st = fetch(url.rstrip("/") + "/index.yaml", None, want_json=False)
    if st != "ok":
        die(f"the chart mirror {url} did not answer: {st}")
    try:
        entries = (yaml.safe_load(body) or {}).get("entries") or {}
    except Exception as exc:                                     # noqa: BLE001
        die(f"the chart mirror {url} returned something that is not an index: {exc}")
    for name, versions in entries.items():
        index.setdefault(name, set()).update(str(v.get("version")) for v in versions)
print(f"charts:  {len(index)} chart(s) in the mirror index")
print()

# --------------------------------------------------------------------------- #
# Verdicts
# --------------------------------------------------------------------------- #
seen = {}
projects = {}


def repos_of(project):
    """Which repositories the project holds, because an empty artifact list lies.

    The registry answers HTTP 200 with `[]` for a repository path that does not
    exist -- verified against the real one, where a repository nobody has ever
    pushed and a name invented on the spot give byte-identical replies. So 404
    never arrives and "absent" would never be reported: every absence would read
    as "the repository is there and holds no tags", which is a different fact
    with a different fix.

    The project's repository listing is the one place that knows, so it is read
    once per project and the artifact call is only ever asked about a repository
    that is in it.
    """
    if project in projects:
        return projects[project]
    names, page = set(), 1
    while True:
        doc, st = fetch(f"http://{HOST}/api/v2.0/projects/{project}/repositories"
                        f"?page_size=100&page={page}", AUTH)
        if st != "ok" or not isinstance(doc, list):
            projects[project] = (None, st if st != "ok" else "unreachable (not a list)")
            return projects[project]
        for r in doc:
            # Listed as "<project>/<repo>"; the repo half is what a path uses.
            names.add(str(r.get("name", "")).split("/", 1)[-1] if "/" in str(r.get("name", ""))
                      else str(r.get("name", "")))
        if len(doc) < 100:
            break
        page += 1
    projects[project] = (names, "ok")
    return projects[project]


def tags_of(project, repo):
    """(tags, status) where status is ok / absent / a reason it is unknown."""
    if (project, repo) in seen:
        return seen[(project, repo)]
    names, st = repos_of(project)
    if st != "ok":
        seen[(project, repo)] = (set(), st)
        return seen[(project, repo)]
    if repo not in names:
        seen[(project, repo)] = (set(), "absent")
        return seen[(project, repo)]
    # Harbor nests a repository name inside a project, and the slash has to
    # survive one round of percent-encoding INSIDE a path segment -- hence %252F
    # and not %2F. With one round the server reads it as a path separator.
    enc = repo.replace("/", "%252F")
    doc, st = fetch(f"http://{HOST}/api/v2.0/projects/{project}/repositories/{enc}"
                    f"/artifacts?page_size=100&with_tag=true", AUTH)
    if st == "ok" and isinstance(doc, list):
        seen[(project, repo)] = ({t["name"] for a in doc for t in (a.get("tags") or [])}, "ok")
    else:
        seen[(project, repo)] = (set(), st if st != "ok" else "unreachable (not a list)")
    return seen[(project, repo)]


missing, blind = [], []
print("IMAGES")
for img in sorted(images):
    if not img.startswith(HOST + "/"):
        missing.append((img, f"is not on {HOST}, so it is not mirrored at all"))
        print(f"  MISS  {img}")
        continue
    path, _, tag = img[len(HOST) + 1:].rpartition(":")
    project, _, repo = path.partition("/")
    tags, st = tags_of(project, repo)
    if st == "ok" and tag in tags:
        print(f"  ok    {img}")
    elif st == "ok":
        have = ", ".join(sorted(tags)[:4]) or "no tags at all"
        missing.append((img, f"the repository is there and the tag is not (has: {have})"))
        print(f"  MISS  {img}")
    elif st == "absent":
        missing.append((img, "there is no such repository in the registry"))
        print(f"  MISS  {img}")
    else:
        blind.append((img, st))
        print(f"  ?     {img}")

print()
print("CHARTS")
for name, ver in sorted(charts):
    have = index.get(name) or set()
    if ver in have:
        print(f"  ok    {name} {ver}")
    else:
        detail = ("the mirror has no chart by that name" if not have
                  else f"the mirror has {', '.join(sorted(have))}")
        missing.append((f"{name} {ver}", detail))
        print(f"  MISS  {name} {ver}")

print()
for what, why in missing:
    print(f"MISSING  {what}")
    print(f"         {why}")
    for where in sorted(set(images.get(what, []) + charts.get(tuple(what.split(" ", 1)), []))):
        print(f"         declared in {where}")
for what, why in blind:
    print(f"UNKNOWN  {what}")
    print(f"         {why} — this is not an absence, it is a lookup that did "
          f"not complete")

print()
print(f"{len(images)} image(s), {len(charts)} chart(s) declared — "
      f"{len(missing)} missing, {len(blind)} could not be looked up")
sys.exit(1 if (missing or blind) else 0)
