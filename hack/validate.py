#!/usr/bin/env python3
"""The gate. Refuses a commit before Argo CD refuses it less legibly.

Scope in S1: the machine's own invariants, and the component.yaml contract.
Workload-level checks arrive with the first workload.

Every refusal here exists because the alternative was a failure that named the
wrong thing -- a project name instead of a missing namespace, a
CreateContainerConfigError instead of the layer that asked for it, a graceful
shutdown message instead of the probe that sent SIGTERM.
"""
from __future__ import annotations

import os
import ast
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
errors: list[str] = []
warnings: list[str] = []
# Set when the ApplicationSets could not be rendered at all. Everything that
# reads them measures nothing after that, and reporting nothing as something is
# how a CI image without helm produced two findings about correct files.
RENDER_UNAVAILABLE: list[bool] = []

# The machine, exactly. Section 2 of the standard applies to all of it, and it
# is more than three directories: docs/ is merged into every customer too, and a
# customer's name in a procedure there is as wrong as one in a script.
#
# Anything not listed here is product. That is why the cutover inventory sits at
# the repository root and not under docs/: it names a customer on purpose.
# The oldest Python this has to run on, which is the runner's and not the
# workstation's. gitrunner is on 3.9 -- its own tracebacks say
# /usr/lib64/python3.9/ -- while every laptop here is on 3.14. Anything newer
# than this number is green in development and a SyntaxError at import in CI,
# where it takes down validate, and prove-checks with it.
#
#   verify: sudo -u gitlab-runner -i python3 --version
MIN_PYTHON = (3, 9)

# examples/ is machine and does NOT travel, exactly like docs/: it ships with the
# standard and a cluster repository has its own real product half instead.
#
# It is NOT scanned by check_machine_clean or check_machine_names_nothing, and
# that is deliberate -- a worked cluster.yaml is addresses and names, which is
# what makes it worked. hack/check-examples.sh is what holds it honest, by
# materialising it into a cluster repository and running the gates there.
MACHINE = ("charts", "hack", "bootstrap", "docs")
MACHINE_FILES = ("README.md", ".gitlab-ci.yml", "cluster.example.yaml",
                 ".gitignore")

# Section 2 clause 1: an address or a customer name in the machine means the
# machine stopped being portable. Matches a bare IP or a dotted hostname.
ADDRESS = re.compile(
    r"\b(?:\d{1,3}(?:\.\d{1,3}){3}"
    r"|(?:[a-z0-9-]+\.)+(?:local|ir|com|net|io|internal|lan|svc))\b",
    re.IGNORECASE,
)
# Hostnames that are Kubernetes vocabulary, not addresses of anyone's cluster.
ADDRESS_ALLOW = re.compile(
    r"^(kubernetes\.default\.svc|cluster\.local|kubernetes\.io|"
    r"(argoproj|apiextensions|rbac\.authorization|admissionregistration|"
    r"scheduling|external-secrets|gateway\.networking|cilium)\.io|"
    r"[a-z0-9.-]*k8s\.io|"
    # The machine's own label prefix. Anchored, so a host UNDER it is still an
    # address and only the bare domain is vocabulary -- and writing the example
    # out here made this very check refuse this very line, which is the
    # shortest proof of the anchor anyone is going to get.
    r"gitops\.internal|"
    # Loopback is nobody's cluster. A ceremony that exec's into a pod and talks
    # to the process inside it says 127.0.0.1 and means it.
    r"127\.0\.0\.1|0\.0\.0\.0)$",
    re.IGNORECASE,
)


def _is_key_domain(line: str, at: int) -> bool:
    """A Kubernetes label/annotation/API domain, not somebody's address.

    An allow-list of the Kubernetes and Argo API domains goes stale the first
    time a new one appears, and widening the
    pattern to "public domains" is the false-negative machine warned about in
    the standard. The difference is structural instead:

      app.kubernetes.io/managed-by: argocd     <- domain in the KEY position
      repository: <mirror-host>/x/y            <- domain in the VALUE position

    A label key is a key; a registry is a value. The two exceptions are
    `apiVersion:` and `group:`, whose values are API domains by definition.
    """
    # A comment is prose, not a key/value pair. An address in one is still an
    # address in the machine, and letting `#` through was a regression the
    # prover caught on the very case that exists for it.
    if line.lstrip().startswith("#"):
        return False
    colon = line.find(":")
    if colon == -1:
        return False
    if at < colon:
        return True
    key = line[:colon].lstrip(" -{[").strip().strip('"\'')
    return key in ("apiVersion", "group")


def err(where: str, msg: str) -> None:
    errors.append(f"{where}: {msg}")


def warn(where: str, msg: str) -> None:
    warnings.append(f"{where}: {msg}")


def load(path: Path) -> Any:
    # A file that is not there is not a parse failure. Reporting it as one
    # produced an error naming a filename beside a warning that already said the
    # file was optional -- two messages about one absence, disagreeing on whether
    # it mattered. Whether an absent file is an error is the caller's decision.
    if not path.exists():
        return None
    try:
        with path.open(encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001
        err(str(path.relative_to(ROOT)), f"unparseable YAML: {exc}")
        return None


def cluster_file() -> Path:
    for name in ("cluster.yaml", "cluster.example.yaml"):
        if (ROOT / name).exists():
            return ROOT / name
    sys.exit("neither cluster.yaml nor cluster.example.yaml is present")


# --------------------------------------------------------------------------- #
# Section 2 - what the machine may not contain
# --------------------------------------------------------------------------- #
def check_machine_clean() -> None:
    """No address, no customer name, no behaviour conditional on a tool name.

    Clause 2 -- no hand-maintained inventory that gates execution -- is not a
    text search. It is enforced structurally: the AppProject destinations are
    derived (check_platform_namespaces), and discovery is by folder, so there
    is no list whose contents decide what runs.
    """
    for top in MACHINE:
        base = ROOT / top
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*")):
            if not f.is_file() or f.suffix not in (".yaml", ".yml", ".tpl", ".sh", ".py"):
                continue
            rel = str(f.relative_to(ROOT))
            # The prover has to contain the very strings it proves this check
            # catches. Exempting it by name is narrow and stated; widening the
            # pattern to let it through would excuse a real address too.
            if rel == "hack/prove-checks.sh":
                continue
            for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                for m in ADDRESS.finditer(line):
                    if ADDRESS_ALLOW.match(m.group(0)):
                        continue
                    if _is_key_domain(line, m.start()):
                        continue
                    err(f"{rel}:{n}", f"machine file contains an address `{m.group(0)}`. "
                                      f"Addresses belong in cluster.yaml")


def check_machine_names_nothing() -> None:
    """No customer, tenant, environment or service name anywhere in the machine.

    check_machine_clean catches an address. A name is not an address: a tenant
    name in a usage example passed every gate and would have been merged into every
    other customer's repository, telling them to run a command against a tenant
    they do not have.

    The machine cannot know what those names are, so it reads them from the one
    place that does: this cluster's own cluster.yaml and its folders.

    WHICH MEANS THE MACHINE'S OWN CI CANNOT RUN THIS CHECK, and it is worth
    knowing before trusting a green pipeline there. gitops-standard has no
    tenants and no tenants/ tree, so `owners` and `services` are both empty and
    this returns at the line below without looking at anything. The only place a
    customer name in the machine is caught is a cluster repository, after the
    merge -- which is late, and is the whole reason the merge is 1:1 and the
    gates run there too.

    It earned the comment: two new pages were written with a tenant name, a
    service name and a namespace in nine places, passed every gate in the
    machine repository, and were refused by the first cluster repository they
    were merged into.
    """
    cluster = load(cluster_file()) or {}
    owners, services = set(), set()
    for t in (cluster.get("tenants") or []) + (cluster.get("sharedScopes") or []):
        if t.get("name"):
            owners.add(str(t["name"]))
    for scope in ("tenants", "shared"):
        base = ROOT / scope
        if base.is_dir():
            for cfg in base.glob("*/*/*/config.yaml"):
                services.add(cfg.parent.name)
    if not owners and not services:
        return

    targets = [f for top in MACHINE for f in sorted((ROOT / top).rglob("*"))
               if (ROOT / top).is_dir()]
    targets += [ROOT / f for f in MACHINE_FILES if (ROOT / f).exists()]
    for f in targets:
        if not f.is_file() or f.suffix not in (".yaml", ".yml", ".tpl", ".sh", ".py", ".md"):
            continue
        rel = str(f.relative_to(ROOT))
        # The prover builds its fixture at a real path and therefore contains
        # one. Same narrow, named exemption as the address check, and for the
        # same reason: the file that proves a rule has to contain what the rule
        # catches.
        if rel == "hack/prove-checks.sh":
            continue
        for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            # A tenant or shared-scope name, anywhere. There are one or two of
            # them per cluster and they are distinctive.
            for name in sorted(owners):
                if re.search(rf"(?<![.\w-]){re.escape(name)}(?![.\w-])", line):
                    err(f"{rel}:{n}", f"names the tenant `{name}`. The machine is merged "
                                      f"into every other customer's repository, where "
                                      f"that name means nothing")
            # A service name ONLY inside a path. A service may legitimately be
            # called `svc` or `api`, and those are ordinary words in a script --
            # matching them everywhere produced eighty-seven findings and not one
            # of them was a leak. What a leak actually looks like is a usage
            # example with a real path in it.
            for m in re.finditer(r"(?:tenants|shared|platform)/[\w.-]+/[\w.-]+/([\w.-]+)", line):
                if m.group(1) in services:
                    err(f"{rel}:{n}", f"names the service `{m.group(1)}` in a path. The "
                                      f"machine is merged into every other customer's "
                                      f"repository, where that path does not exist")

def check_nothing_is_silenced() -> None:
    """Section 12: never silence something whose failure matters.

    The machine had eight of them and every one turned two different outcomes
    into the same empty answer -- a workload that is not deployed and a cluster
    that refused the request; a config file that says stateful and one that does
    not parse. The second of each pair is the one that matters and the silenced
    form cannot report it.

    `command -v` is the exception: asking whether a command exists is the one
    case where the failure IS the answer.
    """
    pattern = "2>" + "/dev/null"          # not written whole; this file is scanned
    targets = [f for top in MACHINE for f in sorted((ROOT / top).rglob("*"))
               if (ROOT / top).is_dir()]
    targets += [ROOT / f for f in MACHINE_FILES if (ROOT / f).exists()]
    for f in targets:
        if not f.is_file() or f.suffix not in (".sh", ".py", ".yaml", ".yml", ".tpl"):
            continue
        rel = str(f.relative_to(ROOT))
        # Third named exemption for the same file and the same reason: the prover
        # has to contain the thing it proves is refused.
        if rel == "hack/prove-checks.sh":
            continue
        for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            st = line.strip()
            if st.startswith("#") or "command -v" in line:
                continue
            if pattern in line:
                err(f"{rel}:{n}", f"silences a failure with `{pattern}`. It makes two "
                                  f"different outcomes produce one empty answer, and the "
                                  f"one that matters is the one it hides")

def check_ci_parses() -> None:
    """The CI file is YAML and nothing was reading it.

    A broken .gitlab-ci.yml is committed silently and fails at the next push, on
    a runner, with a parse error naming a line number -- and every gate in it is
    skipped, so the pipeline that would have caught the rest of the commit never
    runs. This one was committed broken by the commit that made the shelf test
    real.
    """
    f = ROOT / ".gitlab-ci.yml"
    if not f.exists():
        return
    class Loose(yaml.SafeLoader):
        pass
    Loose.add_multi_constructor("!", lambda loader, suffix, node: None)
    try:
        doc = yaml.load(f.read_text(encoding="utf-8"), Loader=Loose)
    except Exception as exc:  # noqa: BLE001
        err(".gitlab-ci.yml", f"does not parse: {exc}")
        return
    for name, job in (doc or {}).items():
        if not isinstance(job, dict) or name.startswith(".") or name in ("stages", "variables", "default"):
            continue
        depth = str((doc.get("variables") or {}).get("GIT_DEPTH", ""))
        script = " ".join(str(x) for x in (job.get("script") or []))
        if "HEAD~" in script and depth in ("1",):
            err(".gitlab-ci.yml", f"job `{name}` compares against HEAD~ with GIT_DEPTH "
                                  f"{depth}. A clone that shallow has no parent commit, "
                                  f"so the job fails on every commit -- on the runner it "
                                  f"was written for, while passing anywhere the clone is "
                                  f"deeper")
        if job.get("allow_failure") and job.get("when") == "manual":
            err(".gitlab-ci.yml", f"job `{name}` is both manual and allow_failure, which "
                                  f"is a gate that cannot fail: nobody runs it, and "
                                  f"running it changes nothing")


def check_shelf_allowlist() -> None:
    """The machine's definition and the shelf test's pattern are one list in two
    languages, and two copies of a list drift.

    The first time the machine grows a file, the new file is committed with a
    `Machine:` subject, the pattern does not name it, and the gate refuses a
    correct commit. The fault is not in the commit; it is one list knowing
    something the other does not.

    The shell cannot import this tuple -- it runs in CI, in bash -- so the tuple
    checks the pattern. Three things, because a gate can be half open:

    1. the pattern names every part of the machine,
    2. it is written once, and
    3. BOTH directions read it -- `grep -vE` for a machine commit, `grep -E`
       for a product one. A product branch that lists only the directories lets a
       commit with a product subject edit README.md, .gitignore, or the CI file
       itself. A gate a product commit can rewrite is not a gate.

    Matched on tokens, not substrings: `hack` occurs inside `hacks`, and a check
    that accepts the wrong name for the right reason is a loose match that gets
    paid for later.
    """
    f = ROOT / ".gitlab-ci.yml"
    if not f.exists():
        return
    text = f.read_text(encoding="utf-8")
    n = text.count("machine_pattern=")
    if n == 0:
        err(".gitlab-ci.yml", "has no `machine_pattern=` line. The shelf test is the "
                              "only thing keeping a commit in one class, and it cannot "
                              "do that from a list it does not have")
        return
    if n > 1:
        # Clause 2, which was prose until it was not. A second assignment leaves
        # the first one complete, so every other clause here stays green while
        # the branch that reads the later one is matching a different list --
        # the same two-copies drift, moved inside the file that was supposed to
        # have ended it.
        err(".gitlab-ci.yml", f"assigns machine_pattern {n} times. The list is one "
                              f"list; a second assignment means the two branches can "
                              f"read different machines while every check here still "
                              f"passes")
        return
    line = next(l for l in text.splitlines() if "machine_pattern=" in l)
    # The pattern escapes its dots; compare against the text it matches, and cut
    # it into the alternation's own pieces rather than searching the whole line.
    flat = line.replace("\\", "")
    tokens = {t for t in re.split(r"[|()^$/'\s]+", flat) if t}
    for name in (*MACHINE, *MACHINE_FILES):
        if name not in tokens:
            err(".gitlab-ci.yml", f"`{name}` is part of the machine and the shelf "
                                  f"pattern does not name it. A `Machine:` commit that "
                                  f"touches it is refused on the runner, for a file the "
                                  f"standard calls machine")
    for direction, what in ((r'grep -vE "$machine_pattern"',
                             "a machine commit is not held to the machine"),
                            (r'grep -E "$machine_pattern"',
                             "a product commit may change the machine, including this gate")):
        if direction not in text:
            err(".gitlab-ci.yml", f"the shelf test does not use `{direction}`, so {what}. "
                                  f"One list, read in both directions, or the two halves "
                                  f"disagree about what the machine is")


def check_no_written_out_sync_policy() -> None:
    """A procedure page must not hand back a sync policy it guessed.

    An unfreeze step that writes out `{"selfHeal":true,"prune":false}` is right
    for most workloads and wrong for any that declares `prune: true`, and the
    `ignoreApplicationDifferences` that makes the freeze work in the first place
    means the ApplicationSet will not correct it -- so the wrong value stays,
    silently, on a service somebody has just finished fixing.

    hack/drill.sh reads the live value before it freezes and hands back exactly
    that. The page has to say the same thing, and this is what keeps the two
    from drifting apart again: a docs line that both patches an Application and
    opens an object right after `automated` is writing a policy it cannot know.

    Anchored on the line, and on both halves of it. `automated` alone appears
    all over these pages, and `patch application` alone is the freeze command,
    which is a literal `null` on purpose.

    Matched with whitespace allowed, not as the fixed string `"automated":{`. A
    check that only sees the compact form goes quiet on one space after the
    colon. A break across two lines still passes: the anchor is a line,
    deliberately, because widening an anchor to a whole file is how a check comes
    to report green about a field that is not there.
    """
    # INERT WHERE docs/ IS ABSENT, and that is every cluster repository: the
    # pages are machine but they are deliberately NOT merged out, so this runs
    # here and finds nothing there. Same shape as check_machine_names_nothing,
    # which is inert in the standard for the opposite reason. A check that is
    # silent in one of the two places is not broken; a check nobody knows is
    # silent is.
    written_out = re.compile(r'"automated"\s*:\s*\{')
    for f in sorted((ROOT / "docs").rglob("*.md")):
        rel = str(f.relative_to(ROOT))
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if "patch application" in line and written_out.search(line):
                err(f"{rel}:{n}", 'hands back a written-out syncPolicy.automated. '
                                  'Nothing on a page knows what a given workload '
                                  'declared; read it off the Application before the '
                                  'freeze and put that back. hack/drill.sh does')


def check_no_duplicate_yaml_keys() -> None:
    """YAML replaces a duplicate key; it does not merge it. Nothing here looked.

    A values file assembled by appending a per-cluster block to a base block,
    each with the same top-level keys, loses the earlier block whole. A Vault
    values file written that way loses its listener, its TLS, its storage stanza
    and its `seal "transit"` -- every one still on screen, none of them reaching
    the chart -- and a rebuild from it installs a Vault with no configuration and
    no auto-unseal.

    It is silent from every side. render.sh skips remote charts, so such a file
    is never rendered. check-pins.sh reads images.yaml, not the result. And
    PyYAML -- which this very script uses -- takes the last key without a word,
    so every other check here reads the same truncated document and agrees with
    it.

    Composed, not constructed: compose_all walks the nodes of every document
    without building objects, which is what makes a duplicate visible at all.
    Go templates are skipped because they are not YAML until Helm has run.
    """
    for f in sorted(ROOT.rglob("*.yaml")):
        parts = f.relative_to(ROOT).parts
        if ".git" in parts or "out" in parts:
            continue
        rel = str(f.relative_to(ROOT))
        text = f.read_text(encoding="utf-8", errors="replace")
        try:
            docs = list(yaml.compose_all(text))
        except Exception as exc:  # noqa: BLE001
            # A Go template is not YAML until Helm has run, so it is skipped --
            # but only once it has actually failed to parse. Skipping on the
            # mere presence of `{{` steps over any values file that merely
            # contains a templated string -- an affinity block, for instance --
            # and those parse perfectly well. The file whose duplicate matters
            # most is usually one of them.
            if "{{" in text:
                continue
            err(rel, f"is not parseable YAML: {exc}")
            continue
        for doc in docs:
            if doc is None:
                continue
            stack = [doc]
            while stack:
                node = stack.pop()
                if isinstance(node, yaml.MappingNode):
                    seen: dict[str, int] = {}
                    for kn, vn in node.value:
                        stack.append(vn)
                        if not isinstance(kn, yaml.ScalarNode):
                            continue
                        first = seen.get(kn.value)
                        if first is not None:
                            err(f"{rel}:{kn.start_mark.line + 1}",
                                f"repeats the key `{kn.value}`, first set at line "
                                f"{first}. YAML does not merge a duplicate key -- "
                                f"this one replaces everything the first one held, "
                                f"and both stay on screen")
                        else:
                            seen[kn.value] = kn.start_mark.line + 1
                elif isinstance(node, yaml.SequenceNode):
                    stack.extend(node.value)


def check_rendered_output_is_read() -> None:
    """Rendering a chart and reading what came out are two different claims.

    A values file can pass an environment variable that the chart already emits
    itself -- the same name, often the same value -- and the rendered pod spec
    then declares it twice in one container.

    `env` is listType=map. Server-side apply builds a typed patch keyed by name
    and cannot hold two entries under one key, so it refuses the whole object:

        failed to create typed patch object (vault-transit/vault-transit;
        apps/v1, Kind=StatefulSet):
        .spec.template.spec.containers[name="vault"].env:
        duplicate entries for key [name="VAULT_ADDR"]

    Argo CD surfaces that as ComparisonError. The object still reaches the
    cluster -- the API server treats a repeated env name as a warning, and the
    pod was created -- so the Application reads Healthy. What breaks is the
    diff: ComparisonError is neither Synced nor OutOfSync, it is an Application
    that has compared nothing, and selfHeal has nothing to act on.

    The message names a field of a rendered StatefulSet and no file. The two
    lines that caused it are in a values file it does not mention.

    Two things had to be true for it to reach a cluster, so this refuses both:

    1. render.sh wrote the object and never read it back.
    2. render.sh does not render remote charts unless WITH_REMOTE=1, and CI did
       not set it -- so vault, vault-transit, cert-manager, external-secrets and
       redis-operator were rendered for the first time by Argo CD, on main.

    The second is the one that matters. Adding the scan while CI still skips
    every remote chart would be a check that cannot see the thing it was written
    for.
    """
    r = ROOT / "hack" / "render.sh"
    if r.exists():
        body = r.read_text(encoding="utf-8")
        for token, what in (('echo "rendered objects:"',
                             "does not read back what it rendered"),
                            ("duplicate entries",
                             "does not refuse a duplicate entry in a "
                             "listType=map field")):
            if token not in body:
                err("hack/render.sh",
                    f"{what}. A chart that renders can still produce an object "
                    f"the API server will not hold, and Argo CD reports that as "
                    f"ComparisonError -- naming a field, never the values file")

    f = ROOT / ".gitlab-ci.yml"
    if not f.exists():
        return
    class Loose(yaml.SafeLoader):
        pass
    Loose.add_multi_constructor("!", lambda loader, suffix, node: None)
    try:
        doc = yaml.load(f.read_text(encoding="utf-8"), Loader=Loose) or {}
    except Exception:  # noqa: BLE001
        return  # check_ci_parses owns this failure and says so better
    job = doc.get("render")
    if not isinstance(job, dict):
        err(".gitlab-ci.yml", "has no `render` job, so nothing renders this "
                              "repository before Argo CD does")
        return
    variables = {**(doc.get("variables") or {}), **(job.get("variables") or {})}
    if str(variables.get("WITH_REMOTE", "")) != "1":
        err(".gitlab-ci.yml", "job `render` does not set WITH_REMOTE=1, so it "
                              "renders the local charts only and reports ok. "
                              "Every remote chart the platform installs is then "
                              "rendered for the first time by Argo CD, on main, "
                              "after the push -- which is where this repository "
                              "found a StatefulSet the API server refused")

def check_status_exit_codes_are_not_piped() -> None:
    """`vault status` reports state through its exit code, and pipefail turns
    that into a failure.

    0 unsealed, 2 sealed, 1 could not reach the listener. Every one of those is
    an answer. With `set -o pipefail` on -- which every script here sets --
    `vault status | grep -q X` returns 2 whenever the Vault is sealed, no matter
    what grep found. So:

        if vx ... vault status | grep -q 'Initialized *true'; then

    reads false on a Vault that is initialised and sealed, and the ceremony goes
    on to run `operator init` against it.

    The general rule -- a command whose non-zero exit is data must not be the
    left side of a pipeline -- cannot be checked, because only the author knows
    which commands those are. `vault status` is named here because the
    consequence is a destroyed Vault.

    Capture, then match:

        st=$(vx ... vault status || true)
        if grep -q 'Initialized *true' <<<"$st"; then
    """
    d = ROOT / "bootstrap"
    if not d.is_dir():
        return
    for f in sorted(d.rglob("*.sh")):
        rel = str(f.relative_to(ROOT))
        for n, line in enumerate(f.read_text(encoding="utf-8",
                                             errors="replace").splitlines(), 1):
            if line.strip().startswith("#"):
                continue
            if "vault status" not in line:
                continue
            after = line.split("vault status", 1)[1]
            # `||` is a fallback, not a pipeline. A single `|` is -- and the
            # lookbehind matters: without it the second character of `||`
            # matches, and the check refused the very helper written to satisfy
            # it.
            if re.search(r"(?<!\|)\|(?!\|)", after):
                err(f"{rel}:{n}",
                    "pipes `vault status` into something. Its exit code is the "
                    "seal state -- 2 while sealed -- and pipefail makes the whole "
                    "pipeline fail on it, so the match is discarded and a sealed "
                    "Vault reads as no match. Capture it first, then match on the "
                    "variable")

def check_key_material_is_not_written_through() -> None:
    """`vault operator init > keys.json` destroys keys.json before it runs.

    The shell truncates a redirect target before the command starts. So an init
    that fails empties the file that was already there — and the one failure
    that reaches that line is `Vault is already initialized`, which is exactly
    the case where the file held the only copy of the keys.

    A Vault that is initialised with no keys cannot be administered or unsealed
    again. For the transit Vault it is worse: the main Vault never unseals
    either. That is the disaster written across the header of
    bootstrap/vault-day0.sh, and the script contained the mechanism for it in
    two places.

    The path to it is short: transit is initialised, the operator interrupts the
    run at the custody prompt, and the re-run reads the initialised-but-sealed
    Vault as uninitialised — the pipefail defect above — and takes the branch
    that truncates.

    Write beside the file and move it into place on success. init_into does
    that, and refuses to run at all when keys are already there.
    """
    d = ROOT / "bootstrap"
    if not d.is_dir():
        return
    for f in sorted(d.rglob("*.sh")):
        rel = str(f.relative_to(ROOT))
        # Join continuations first. A script can put `operator init` on one line
        # and the redirect on the next, and a line-at-a-time check then reads
        # both halves and sees neither -- passing over the exact command it
        # exists to refuse.
        logical, start, buf = [], 0, ""
        for n, line in enumerate(f.read_text(encoding="utf-8",
                                             errors="replace").splitlines(), 1):
            if not buf:
                start = n
            buf += line[:-1] + " " if line.rstrip().endswith("\\") else line
            if not line.rstrip().endswith("\\"):
                logical.append((start, buf))
                buf = ""
        if buf:
            logical.append((start, buf))
        for n, body in logical:
            if body.strip().startswith("#"):
                continue
            if "operator init" not in body:
                continue
            if not re.search(r"(?<![0-9&])>\s*\S", body):
                continue
            err(f"{rel}:{n}",
                "redirects `vault operator init` straight into a file. The shell "
                "truncates that file before the command runs, so a failed init "
                "destroys the keys already in it -- and `Vault is already "
                "initialized` is the failure that gets there. Write beside it "
                "and move on success")

def check_exec_does_not_share_a_loop_with_read() -> None:
    """`kubectl exec -i` inside a `while read ... done < file` eats the file.

    The loop's stdin IS the file being read. `kubectl exec -i` forwards stdin to
    the container, so the first iteration consumes every remaining line, `read`
    hits EOF, and the loop runs exactly once however many lines there were.

    bootstrap/vault-day0.sh unsealed with it. Three keys were written, one was
    submitted, transit stayed at Unseal Progress 1/3, and `|| true` on that line
    meant nothing said so. The failure surfaced two steps later as three 503s
    reading `Vault is sealed`, which names the state and not the cause.

    The loop ran once and looked like it ran three times. That is the part worth
    refusing: it is not a crash, it is a loop quietly doing a third of its job.

    Read into an array first — mapfile involves no stdin — or redirect the exec
    with `</dev/null`.
    """
    d = ROOT / "bootstrap"
    if not d.is_dir():
        return
    for f in sorted(d.rglob("*.sh")):
        rel = str(f.relative_to(ROOT))
        lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        # The wrapper's name is not knowable in advance: vault-day0.sh calls it
        # vx, seed-vault-kv.sh calls it v. Hardcoding one meant the check was
        # blind to the other the day it was written. So: any function in this
        # file whose body starts with a kubectl exec is an exec wrapper.
        wrappers = set(re.findall(r"^\s*(\w+)\(\)\s*{[^\n]*kubectl[^\n]*exec",
                                  "\n".join(lines), re.M))
        start, body = None, []
        for n, line in enumerate(lines, 1):
            st = line.strip()
            if st.startswith("#"):
                continue
            if start is None:
                if re.match(r"(while|until)\s+read\b", st):
                    start, body = n, []
                continue
            if st.startswith("done"):
                # Only a loop fed from a file or a here-string: a loop reading a
                # pipe has the same problem, and `done` alone is a loop reading
                # the script's own stdin, which is the same thing again.
                if re.search(r"done\s*<", st) or re.search(r"\|\s*(while|until)", lines[start - 1]):
                    for bn, bl in body:
                        called = any(re.search(r"\b%s\b" % re.escape(w), bl)
                                     for w in wrappers)
                        if "kubectl" not in bl and not called:
                            continue
                        if "</dev/null" in bl or "< /dev/null" in bl:
                            continue
                        # A pipe IS a stdin redirect: `something | vx ...` gives
                        # the exec the pipe, not the loop's input. Refusing that
                        # form would make the check reject the safe shape as
                        # well as the dangerous one, and the two look nothing
                        # alike to anyone reading the file.
                        if re.search(r"(?<!\|)\|\s*(?:%s)\b"
                                     % "|".join(re.escape(w) for w in wrappers), bl):
                            continue
                        err(f"{rel}:{bn}",
                            "runs an exec inside a loop that reads from a file. "
                            "`kubectl exec -i` forwards stdin, and here stdin is "
                            "the file being read -- the first iteration eats the "
                            "rest and the loop runs once, quietly. Read into an "
                            "array first, or redirect the exec with `</dev/null`")
                start = None
                continue
            body.append((n, line))

def check_seeding_is_not_retyped() -> None:
    """The Vault seeding page must point at the script, not restate its commands.

    A page of seeding commands with `<mount>`, `<role>` and `<user>` to
    substitute by hand produces this, sooner or later:

        vault kv put kv/platform/apps username='<user>' password='<pass>'
        ==== Secret Path ====  kv/data/platform/apps   version 1

    A version number, a success, and two credentials that authenticate to
    nothing. No operator catches it, because a correct run prints the same thing.
    Most placeholders left in a command fail loudly; a `kv put` is the shape that
    does not, because Vault will store whatever it is given.

    bootstrap/seed-vault-kv.sh owns these: it reads every name out of the
    repository, takes every value from a prompt that does not echo, and refuses
    a value shaped like a placeholder. A page that also carries the commands is
    the page someone will use instead, and it is the copy that drifts.
    """
    page = ROOT / "docs" / "05-vault-eso.md"
    if not page.exists():
        # A cluster repository, where docs/ is deliberately absent. The pages
        # are machine and are not merged out, so there is no page here to hold
        # to its script.
        return
    script = ROOT / "bootstrap" / "seed-vault-kv.sh"
    text = page.read_text(encoding="utf-8")
    if not script.exists():
        err("bootstrap/seed-vault-kv.sh",
            "is gone, and docs/05-vault-eso.md is written on the assumption "
            "that it does the seeding. Restore it, or rewrite the page -- but "
            "not back into placeholders somebody substitutes by hand")
        return
    if "seed-vault-kv.sh" not in text:
        err("docs/05-vault-eso.md",
            "never names bootstrap/seed-vault-kv.sh, so an operator reading it "
            "has no way to reach the thing that refuses a placeholder")
    for n, line in enumerate(text.splitlines(), 1):
        st = line.strip()
        # A fenced command, not prose about one.
        if not st.startswith(("vault ", "kubectl ")) and "vault kv put" not in st:
            continue
        if "vault kv put" in st or re.search(r"vault (secrets|auth|policy) ", st):
            # The page quotes the defective command on purpose, as the reason
            # the script exists. That line is evidence, not an instruction, and
            # it is the one place a placeholder is allowed to appear.
            #
            # Recognised by the SHAPE of a placeholder, not by one spelling of
            # one. This tested for a single literal name, so renaming the
            # placeholder in the page turned the page's own evidence line into a
            # refusal -- a check coupled to an example rather than to a rule.
            if re.search(r"<[a-z][a-z0-9-]*>", st):
                continue
            err(f"docs/05-vault-eso.md:{n}",
                "restates a Vault seeding command. bootstrap/seed-vault-kv.sh "
                "owns these -- a page that carries them too is the copy that "
                "drifts, and the one that still has placeholders in it")

def check_python_parses_on_an_older_runner() -> None:
    """An f-string expression containing a backslash, or the quote that
    delimits it, is Python 3.12 or newer only.

    PEP 701 relaxed both in 3.12. On 3.11 and older each is a SyntaxError at
    import — not a failing check, the whole file refusing to load:

        File "hack/validate.py", line 932
            f"platform`, naming neither the tool nor this list")
        SyntaxError: f-string expression part cannot include a backslash

    That is what the GitLab runner printed. Every workstation here runs a newer
    Python, so it was green in every place it was tested and red in the only
    place that decides anything, and it took three jobs down with it: validate,
    prove-checks, which runs validate, and render, for its own reason.

    `ast.parse(..., feature_version=)` does not catch it — the f-string
    relaxations are not gated that way — so this reads the expressions
    themselves, at the positions the parser reports, and looks for the two
    things that changed.

    Hoist the value into a variable. It is shorter and it reads better anyway.

    The same pass also parses each file at MIN_PYTHON, which catches the
    grammar-level features ast does gate that way -- `match`, parenthesised
    context managers, the rest. It does not catch the f-string relaxations,
    which is why both halves are here.
    """
    for top in MACHINE:
        base = ROOT / top
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*.py")):
            rel = str(f.relative_to(ROOT))
            src = f.read_text(encoding="utf-8")
            try:
                tree = ast.parse(src)
            except SyntaxError as exc:
                err(f"{rel}:{exc.lineno}", f"does not parse: {exc.msg}")
                continue
            try:
                ast.parse(src, feature_version=MIN_PYTHON)
            except SyntaxError as exc:
                err(f"{rel}:{exc.lineno}",
                    f"uses syntax newer than Python "
                    f"{MIN_PYTHON[0]}.{MIN_PYTHON[1]}: {exc.msg}")
            for node in ast.walk(tree):
                if not isinstance(node, ast.JoinedStr):
                    continue
                lit = ast.get_source_segment(src, node) or ""
                if lit[1:4] in ('"""', "'''"):
                    quote = lit[1:4]
                elif '"' in lit[:3]:
                    quote = '"'
                else:
                    quote = "'"
                for part in node.values:
                    if not isinstance(part, ast.FormattedValue):
                        continue
                    seg = ast.get_source_segment(src, part.value)
                    if seg is None:
                        continue
                    what = ("a backslash" if "\\" in seg
                            else f"the {quote} that delimits it" if quote in seg
                            else None)
                    if what is None:
                        continue
                    err(f"{rel}:{part.value.lineno}",
                        f"f-string expression `{seg}` contains {what}. That is "
                        f"Python 3.12 and newer only, and on the runner it is a "
                        f"SyntaxError at import -- the file never loads and the "
                        f"gate never runs. Hoist it into a variable")

def check_the_prover_copies_faithfully() -> None:
    """The prover's fixture must be a faithful copy, modes included.

    hack/prove-checks.sh works on a throwaway copy of the tree. `cp -r` applies
    the umask to what it creates, so on a runner whose umask clears the execute
    bit the copy arrives without it -- and one of the checks run against that
    copy is check_scripts_are_executable.

    That is what happened: the baseline reported eleven errors about file modes
    the repository does not have, `FATAL: baseline is not clean` followed, and
    every case after it was skipped. Three jobs green, one red, and the red one
    was describing the harness rather than the code.

    A harness that changes the thing under test while copying it proves nothing
    about the thing. `cp -a` preserves the mode.
    """
    f = ROOT / "hack" / "prove-checks.sh"
    if not f.exists():
        return
    for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        st = line.strip()
        if st.startswith("#"):
            continue
        # Fourth named exemption for this file and the same reason: the prover
        # has to contain the thing it proves is refused. A case's mutation is a
        # string argument, and in this file every one of them is a `sed -i` or a
        # `printf` -- not a command the harness runs on its own fixture.
        if st.startswith("case_ ") or "sed -i" in st or "printf " in st:
            continue
        if re.search(r"\bcp\s+-[a-zA-Z]*r", st) and "--preserve" not in st:
            err(f"hack/prove-checks.sh:{n}",
                "copies the fixture with `cp -r`, which applies the umask and "
                "can drop the execute bit the checks then measure. Use `cp -a`: "
                "a harness that changes the thing under test while copying it "
                "proves nothing about it")

def check_every_ceremony_is_listed() -> None:
    """A procedure nobody can find is the same as no procedure.

    Everything in bootstrap/ is run by a human, under pressure, usually at the
    worst hour. The only index of what exists is bootstrap/README.md, and an
    index that is allowed to drift is worse than none: it reads complete.

    Both failures are ordinary. A script added and never listed leaves the file
    that claims to enumerate the ceremonies saying "two" while there are three.
    And a transit Vault can sit sealed for hours -- the main Vault one pod restart
    from being unopenable -- because the recovery ceremony is not findable and
    nothing names what to run instead.

    Both directions are refused. A script missing from the README is a procedure
    nobody will find; a README naming a script that is not there sends someone
    looking for a file during an incident.
    """
    d = ROOT / "bootstrap"
    readme = d / "README.md"
    if not d.is_dir() or not readme.exists():
        return
    text = readme.read_text(encoding="utf-8", errors="replace")
    listed = set(re.findall(r"bootstrap/([A-Za-z0-9._-]+\.sh)", text))
    on_disk = {f.name for f in d.iterdir() if f.suffix == ".sh" and f.is_file()}
    for name in sorted(on_disk - listed):
        err(f"bootstrap/{name}",
            "is not named in bootstrap/README.md. That file is the only index "
            "of what a human runs, and a ceremony missing from it is one nobody "
            "finds at 01:00")
    for name in sorted(listed - on_disk):
        err("bootstrap/README.md",
            f"names bootstrap/{name}, which does not exist. An index that sends "
            "someone looking for a missing file during an incident is worse "
            "than one that says nothing")

def check_a_private_image_has_a_pull_secret(cluster: dict) -> None:
    """A pinned image nobody can fetch is still a pinned image.

    Every image in this estate comes from a private mirror, and a Deployment
    with no imagePullSecrets pulls anonymously. containerd says:

      failed to resolve image: pull access denied, repository does not exist or
      may require authorization: authorization failed: no basic auth credentials

    "no basic auth credentials" means nothing was sent. A credential that is
    present but wrong says `unauthorized to access repository` instead — a
    different fault with a different fix, and the message is the only place the
    difference shows.

    Every gate passes over it. check-pins.sh proves each image is pinned to an
    exact version and never asks whether anything can fetch it, and nothing
    renders a remote chart offline, so no gate sees the pod spec at all.

    The value can sit in any of the layers in tenantValueLayers or in the
    workload's own values.yaml — this reads the list rather than hardcoding it,
    so moving a layer does not blind the check. An empty list fails too: `[]` is
    the chart's own default, it renders nothing, and it reads as configured.

    SCOPE, and why it stops where it does. Tenant workloads only. The platform
    components pull from the same mirror and five of them declare no pull secret
    at all, yet they run — which means either that Harbor project allows
    anonymous pull or their images were already on the nodes. Those are
    different answers with different consequences for the next node that joins,
    and until one of them is established, extending this check would produce
    five refusals resting on a guess.
    """
    registries = cluster.get("allowedImageRegistries") or []
    if not registries:
        return
    ccv = load(ROOT / "charts" / "cluster-config" / "values.yaml") or {}
    layers = ccv.get("tenantValueLayers") or []

    def carries_a_pull_secret(node) -> bool:
        """Any key named imagePullSecrets, at any depth, with something in it.

        By key name rather than by path: imagePullSecrets is the PodSpec field
        name and charts surface it under their own prefix -- application 9.0.0
        puts it at deployment.imagePullSecrets, vault-helm at server. A path
        would be right for one chart and blind for the next.
        """
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "imagePullSecrets" and v:
                    return True
                if carries_a_pull_secret(v):
                    return True
        elif isinstance(node, list):
            return any(carries_a_pull_secret(v) for v in node)
        return False

    for scope in ("tenants", "shared"):
        base = ROOT / scope
        if not base.is_dir():
            continue
        for cfg in sorted(base.glob("*/*/*/config.yaml")):
            d = load(cfg)
            if not isinstance(d, dict):
                continue
            img = d.get("image") or {}
            repo = str(img.get("repository", ""))
            host = repo.split("/", 1)[0]
            private = host in registries
            rel = str(cfg.relative_to(ROOT))
            segs = cfg.relative_to(ROOT).parts     # scope / tenant / env / svc
            if d.get("chart") or d.get("localChart"):
                if not private:
                    continue
                files = []
                for lay in layers:
                    files.append(ROOT / lay.replace("{t}", segs[1]).replace("{e}", segs[2]))
                files.append(cfg.parent / "values.yaml")
                found = [f for f in files
                         if f.is_file() and carries_a_pull_secret(load(f))]
                if not found:
                    err(rel,
                        f"pulls `{repo}` from a private mirror and no value layer sets "
                        f"imagePullSecrets. The pod pulls anonymously and containerd "
                        f"reports `no basic auth credentials`, naming neither this file "
                        f"nor the secret. Layers read: "
                        + ", ".join(str(f.relative_to(ROOT)) for f in files))
            elif d.get("manifestsDir"):
                # Raw manifests are not templated, so no layer reaches them --
                # the pull secret has to be in the manifests themselves.
                mdir = ROOT / str(d["manifestsDir"])
                if not mdir.is_dir():
                    continue
                texts = [f.read_text(encoding="utf-8", errors="replace")
                         for f in sorted(mdir.rglob("*.yaml"))]
                blob = "\n".join(texts)
                if not any(h in blob for h in registries):
                    continue
                if "imagePullSecrets" not in blob:
                    err(rel,
                        f"delivers raw manifests that pull from a private mirror and "
                        f"none of them sets imagePullSecrets. No value layer reaches a "
                        f"manifestsDir workload, so it has to be in {d['manifestsDir']}")

def check_a_folder_name_is_a_kubernetes_name() -> None:
    """The folder name becomes an object name, and not every folder name can be one.

    `tenants/<t>/<e>/<svc>/` becomes the Application `<t>-<e>-<svc>`, the Helm
    release `<svc>`, and through the chart the Deployment and Service names.
    `platform/<tool>/` becomes the Application `<tool>`. All of those are
    DNS-1123 labels: lower case, digits and hyphens, starting and ending
    alphanumeric.

    A folder called `Order-API` or `MockService` passes every other gate in this
    repository -- it is a perfectly good directory -- and then the API server
    refuses the object:

      metadata.name: Invalid value: "acme-dev-Order-API": a lowercase RFC 1123
      subdomain must consist of lower case alphanumeric characters, '-' or '.'

    Where that surfaces is the problem. The ApplicationSet generates every other
    folder correctly, so the result is one Application missing out of nine and a
    line in the applicationset controller's log. Nothing is red. Nobody is
    looking at a log for an object that does not exist, and the folder that
    caused it looks exactly like the eight that worked.

    An underscore is the same story and is easier to type by accident.
    """
    pat = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
    targets = []
    pdir = ROOT / "platform"
    if pdir.is_dir():
        for f in sorted(pdir.glob("*/component.yaml")):
            targets.append((f.parent.name, str(f.parent.relative_to(ROOT)), "Application"))
    for scope in ("tenants", "shared"):
        base = ROOT / scope
        if not base.is_dir():
            continue
        for f in sorted(base.glob("*/*/*/config.yaml")):
            targets.append((f.parent.name, str(f.parent.relative_to(ROOT)),
                            "Application, Helm release and every object the chart names"))
    for name, rel, becomes in targets:
        if pat.match(name):
            continue
        why = []
        if name != name.lower():
            why.append("it has upper case")
        if "_" in name:
            why.append("it has an underscore")
        if name and not (name[0].isalnum() and name[-1].isalnum()):
            why.append("it does not start and end alphanumeric")
        if len(name) > 63:
            why.append(f"it is {len(name)} characters and the limit is 63")
        err(rel,
            f"folder name `{name}` cannot be a Kubernetes object name — "
            + (", and ".join(why) or "it is not a DNS-1123 label")
            + f". This name becomes the {becomes}, so the API server refuses the "
              f"object while every other folder generates normally: one missing "
              f"Application and a line in a controller log, with nothing red")

def check_no_two_workloads_claim_one_hostname(cluster: dict) -> None:
    """Two routes on one hostname is not an error anywhere except here.

    Gateway API resolves a hostname conflict by age: the older route keeps
    serving and the newer one reports `Accepted` while receiving nothing. No
    controller logs it, no status field says "somebody else has this", and the
    service that was just deployed is the one that loses.

    The Gateway cannot prevent it either, where its listener has no hostname
    constraint and `from: All` -- which is the usual arrangement when the domain
    is shared with objects this repository does not own.

    So this is the only place a duplicate can be caught, and it became load
    bearing the moment the hostname stopped being derived from the folder name.
    While it was `<env>-<service>` there was nothing to collide; now that the
    service part is a free name, two folders can reach for `dev-gateway` and one
    of them silently gets nothing.

    Only hostnames this repository declares. A collision with something applied
    outside it is invisible from here, which is worth stating rather than
    leaving to be assumed.
    """
    seen: dict = {}
    for scope in ("tenants", "shared"):
        base = ROOT / scope
        if not base.is_dir():
            continue
        for cfg in sorted(base.glob("*/*/*/config.yaml")):
            route = (merged_values(cfg).get("httpRoute") or {})
            if not route.get("enabled"):
                continue
            for h in route.get("hostnames") or []:
                seen.setdefault(str(h), []).append(str(cfg.parent.relative_to(ROOT)))
    for host, owners in sorted(seen.items()):
        if len(owners) > 1:
            err(owners[-1],
                f"hostname `{host}` is claimed by {len(owners)} workloads: "
                + ", ".join(owners)
                + ". Gateway API resolves that by age -- the older route keeps "
                  "serving and the newer one reports Accepted while receiving "
                  "nothing, with no controller saying so")

def check_raw_manifests_list_what_must_be_mirrored(cluster: dict) -> None:
    """A manifestsDir workload's images are in no list anybody mirrors from.

    Every platform component carries an images.yaml under a line that says what
    it is for: "everything this cluster's mirror must hold before the first
    sync." A workload delivered by `manifestsDir` carries nothing, and its
    images are just as private and just as absent from the mirror on day one.

    The shape to expect: a Redis instance whose manifests name the operator
    vendor's SERVER image, while the mirror holds only the OPERATOR from the same
    vendor. Two names one path apart, and the registry answers `not found` for
    both. The pod sits in ImagePullBackOff behind an Application reporting Synced
    and Healthy, and correcting the tag in git changes nothing because neither
    tag was ever there.

    check-pins.sh proved the tag was an exact version. Nothing asked whether the
    version was in the registry, and nothing offline can. What CAN be checked is
    that somebody wrote the list down -- and that the list still says what the
    manifests say, which is the half that rots.

    Only images from allowedImageRegistries. A public image needs no mirror and
    listing it would teach people the list is noise.
    """
    registries = cluster.get("allowedImageRegistries") or []
    if not registries:
        return
    img_re = re.compile(r"^\s*(?:-\s*)?image:\s*[\"']?([^\s\"']+)", re.M)
    for scope in ("tenants", "shared"):
        base = ROOT / scope
        if not base.is_dir():
            continue
        for cfg in sorted(base.glob("*/*/*/config.yaml")):
            d = load(cfg)
            if not isinstance(d, dict) or not d.get("manifestsDir"):
                continue
            mdir = ROOT / str(d["manifestsDir"])
            if not mdir.is_dir():
                continue
            used = set()
            for f in sorted(mdir.rglob("*.yaml")):
                for m in img_re.finditer(f.read_text(encoding="utf-8", errors="replace")):
                    if m.group(1).split("/", 1)[0] in registries:
                        used.add(m.group(1))
            if not used:
                continue
            rel = str(cfg.parent.relative_to(ROOT))
            listed_file = cfg.parent / "images.yaml"
            if not listed_file.is_file():
                err(f"{rel}/images.yaml",
                    "does not exist. This workload pulls "
                    + ", ".join(sorted(used))
                    + " from a private mirror, and nothing anywhere lists them. A "
                      "platform component carries images.yaml for exactly this -- the "
                      "list somebody mirrors from before the first sync -- and a "
                      "manifestsDir workload needs it for the same reason")
                continue
            doc = load(listed_file)
            listed = set(map(str, (doc.get("images") if isinstance(doc, dict) else doc) or []))
            for extra in sorted(listed - used):
                err(f"{rel}/images.yaml",
                    f"lists `{extra}`, which no manifest in {d['manifestsDir']} uses. "
                    f"A list that names images nobody pulls is one people stop "
                    f"reading")
            for missing in sorted(used - listed):
                err(f"{rel}/images.yaml",
                    f"does not list `{missing}`, which {d['manifestsDir']} pulls. "
                    f"The list and the manifests have drifted, and the list is what "
                    f"somebody mirrors from")

def _tenant_value_files() -> list[Path]:
    """Every product file that can carry a workload's configuration.

    The workload's own values.yaml, the shared layers above it, and any raw
    manifest a workload ships. A check that read only the leaf file would be
    blind to exactly the place a shared default goes.
    """
    out = []
    for scope in ("tenants", "shared"):
        base = ROOT / scope
        if not base.is_dir():
            continue
        out += sorted(base.rglob("values.yaml"))
        out += sorted(base.rglob("manifests/*.yaml"))
    return out


def _walk(node: Any, path: str = "") -> Any:
    """Every (dotted path, key, value) leaf, skipping the externalSecret subtree.

    That subtree is excluded by construction, not by exception. Its whole
    content is REFERENCES to secrets held elsewhere -- `secretKey`,
    `remoteRef.key`, `remoteRef.property` -- and those field names are the same
    words a secret is named after. Reading it would refuse every correctly
    written ExternalSecret in the repository for saying the word.
    """
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "externalSecret":
                continue
            yield from _walk(v, f"{path}.{k}" if path else str(k))
            if not isinstance(v, (dict, list)):
                yield (f"{path}.{k}" if path else str(k)), str(k), v
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from _walk(v, f"{path}[{i}]")
            if not isinstance(v, (dict, list)):
                yield f"{path}[{i}]", "", v


# The last word of a key, not a substring of it. `DbPassword` ends with
# `password` and is one; `PasswordPolicy` and `PasswordMinLength` contain the
# word and are not. A substring match refuses both and teaches people to work
# around the gate, which is worse than no gate.
SECRET_KEY_TERMS = (
    "password", "passwd", "pwd", "secret", "secretkey", "token", "apikey",
    "accesskey", "privatekey", "clientsecret", "connectionstring", "credential",
)
# A LEAF IN REFERENCE POSITION, which is not a value however it is named.
#
#   redisSecret: {name: redis-secret, key: password}
#   redisReplicationPassword: {secretKeyRef: {name: redis-secret, key: password}}
#
# Both paths have a segment ending in a credential word, and neither holds one:
# they name a Secret that holds it. Excluding the externalSecret subtree covered
# one instance of this; the rule is general, and the leaf key is what says which
# side of it a value is on. Eight refusals on the first real repository this ran
# against were all this shape.
REFERENCE_LEAVES = {
    "name", "key", "secretname", "secretkey", "configmapname", "property",
    "namesuffix", "type", "optional", "kind", "apiversion", "version",
}
# The same words in a JSON blob held as a single string value -- which is the
# shape an appsettings file takes inside configMap.files, and the shape the
# structural walk above cannot see into.
JSON_SECRET = re.compile(
    r'"([A-Za-z0-9_.-]*?(?:' + "|".join(SECRET_KEY_TERMS) + r'))"\s*:\s*"([^"]+)"',
    re.IGNORECASE)
# Two things that are secret material whatever they are called.
PEM = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")
CONNSTRING_PASSWORD = re.compile(r"(?i)\b(?:password|pwd)\s*=\s*[^;\s\"]+")
JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.")


def _is_a_placeholder(v: str) -> bool:
    s = v.strip()
    if not s:
        return True
    if s.startswith("<") and s.endswith(">"):
        return True
    if s.startswith("$"):
        return True
    return bool(re.fullmatch(r"(?i)(redacted|changeme|change[-_]?me|todo|"
                             r"replace[-_]?me|xxx+|\*+)", s))


def _looks_like_a_value_worth_hiding(v: Any) -> bool:
    """A string long enough and mixed enough to be a real credential.

    The length floor is what keeps a policy name out. `strict` under a key
    called PasswordPolicy is six characters of one class; a credential is
    neither.
    """
    if not isinstance(v, str):
        return False
    s = v.strip()
    if _is_a_placeholder(s):
        return False
    if len(s) < 8:
        return False
    return (any(c.isdigit() for c in s) and any(c.isalpha() for c in s)) \
        or any(not c.isalnum() for c in s) or len(s) >= 20


def check_a_config_file_in_git_holds_no_secret() -> None:
    """A ConfigMap is world-readable inside its namespace and forever in git.

    Configuration moving out of an image and into this repository is the right
    direction, and it carries one thing that must not come with it. An
    application's settings file is where a connection string lives, and a
    connection string carries the password to the database in the same line as
    the host.

    Two properties make this worse than an ordinary mistake:

      A ConfigMap is not a Secret. Every ServiceAccount that can read
      ConfigMaps in the namespace can read it, which is a much wider set than
      the one that can read Secrets, and RBAC written about secrets does not
      cover it.

      Git does not forget. Deleting the line in a later commit leaves it
      readable in `git log -p` for as long as the repository exists, and this
      repository is pushed to a server other people can clone. The
      remedy after the fact is a history rewrite and a force-push that breaks
      every clone -- so the only cheap moment to catch it is before the push,
      which is here.

    What it refuses: a path ANY OF WHOSE SEGMENTS ends in a credential word,
    holding a value long and mixed enough to be a real one; a PEM private key
    header; a `Password=` assignment inside any string, which is how a database
    connection string carries one; a JWT. It reads into JSON held as a single
    string value, because that is the shape a settings file takes under
    configMap.files and a structural walk sees only the blob.

    What it deliberately does not refuse: `<redacted>`, an empty value, a `$`
    reference, a key that merely contains a credential word without ending in one
    -- PasswordPolicy and PasswordMinLength are settings, not secrets -- and a
    leaf in REFERENCE position, which is the general form of the externalSecret
    exclusion: `redisSecret: {name: x, key: password}` names a Secret rather than
    holding one, and so does every secretKeyRef. A check that refuses correct
    files is one people learn to route around, and then it guards nothing.

    The place a value like this belongs is Vault, reached by the externalSecret
    block that every workload already has and which this check skips for the
    same reason: that block holds references, and references are named after
    the thing they point at.
    """
    for f in _tenant_value_files():
        doc = load(f)
        if doc is None:
            continue
        rel = str(f.relative_to(ROOT))
        for dotted, key, value in _walk(doc):
            # EVERY SEGMENT OF THE PATH, not the leaf key. The leaf key is very
            # often a generic wrapper: the application chart spells an
            # environment variable `env: {DbPassword: {value: ...}}`, so the leaf
            # is `value` and the credential's name is its parent. Reading only
            # the leaf missed that shape -- which is the commonest one there is --
            # and the prover case for this check is what said so.
            segs = [re.sub(r"[^a-z0-9]", "", seg.lower())
                    for seg in re.sub(r"\[\d+\]", "", dotted).split(".")]
            leaf = re.sub(r"[^a-z0-9]", "", str(key).lower())
            if leaf not in REFERENCE_LEAVES \
                    and any(seg.endswith(t) for seg in segs for t in SECRET_KEY_TERMS) \
                    and _looks_like_a_value_worth_hiding(value):
                err(rel, f"`{dotted}` holds what reads as a real credential. A "
                         f"ConfigMap is readable by everything that can read "
                         f"ConfigMaps in the namespace, and git keeps it after the "
                         f"line is deleted. Put the value in Vault and reach it "
                         f"through the externalSecret block; leave a `<redacted>` "
                         f"or a $-reference here")
            if not isinstance(value, str):
                continue
            if PEM.search(value):
                err(rel, f"`{dotted}` contains a PEM private key header. Nothing in "
                         f"this repository is a place for key material")
            if JWT.search(value):
                err(rel, f"`{dotted}` contains what parses as a JWT. A signed token "
                         f"in git is valid until it expires, and deleting the line "
                         f"does not shorten that")
            if CONNSTRING_PASSWORD.search(value) and not _is_a_placeholder(
                    CONNSTRING_PASSWORD.search(value).group(0).split("=", 1)[1]):
                err(rel, f"`{dotted}` contains a connection string with a password "
                         f"in it. The host and the credential travel in one line, so "
                         f"a settings file that looks harmless carries both. Split "
                         f"the credential into Vault")
            for m in JSON_SECRET.finditer(value):
                if _looks_like_a_value_worth_hiding(m.group(2)):
                    err(rel, f"`{dotted}` is a JSON document with `{m.group(1)}` set "
                             f"to what reads as a real credential. This is the shape "
                             f"a settings file takes inside configMap.files, and the "
                             f"blob is one YAML string -- no structural check sees "
                             f"into it. Put the value in Vault and inject it as an "
                             f"environment variable, which overrides the file")


def check_a_mounted_config_has_something_to_reload_it() -> None:
    """A ConfigMap that changes does not change the file in a running pod.

    Kubernetes refreshes a whole-volume mount in place. It does not refresh a
    `subPath` mount at all -- that file is copied once, when the container
    starts -- and a settings file has to be a subPath mount, because mounting a
    directory over the application's own directory buries the binaries.

    So a config change reaches a pod when the pod is replaced and never
    otherwise. Something has to replace it.

    The application chart already assumes something does. It defaults
    `deployment.reloadOnChange` to true, which writes an annotation naming
    Stakater's Reloader onto every Deployment it renders. An annotation naming a
    controller that is not installed is an error to nothing: not to the API
    server, not to Argo CD, not to `kubectl describe`. The whole failure is:

      config committed -> ConfigMap updated -> Application Synced and Healthy
      -> every pod still serving the old file

    That is indistinguishable from success from every angle except the
    application's own behaviour.

    A component folder is not a controller either, which is why this asks for
    `sync.automated` and not merely for the folder to exist. A component parked
    with automated false is a plan, and a plan does not restart a pod.
    """
    reloader_running = False
    pdir = ROOT / "platform"
    if pdir.is_dir():
        for comp in sorted(pdir.glob("*/component.yaml")):
            doc = load(comp) or {}
            chart = doc.get("chart") if isinstance(doc.get("chart"), dict) else {}
            if comp.parent.name != "reloader" and chart.get("name") != "reloader":
                continue
            if ((doc.get("sync") or {}).get("automated")):
                reloader_running = True
    if reloader_running:
        return

    for f in _tenant_value_files():
        if f.name != "values.yaml":
            continue
        doc = load(f)
        if not isinstance(doc, dict):
            continue
        rel = str(f.relative_to(ROOT))
        dep = doc.get("deployment") if isinstance(doc.get("deployment"), dict) else {}
        reasons = []
        if dep.get("envFrom"):
            reasons.append("deployment.envFrom")
        # A single key pulled out of a ConfigMap is the same problem as the whole
        # file. `value:` is not -- that is baked into the pod spec and changes
        # when the Deployment changes, which Argo CD already rolls.
        env = dep.get("env")
        for name, spec in (env.items() if isinstance(env, dict) else []):
            vf = (spec or {}).get("valueFrom") if isinstance(spec, dict) else None
            if isinstance(vf, dict) and ("configMapKeyRef" in vf or "secretKeyRef" in vf):
                reasons.append(f"deployment.env.{name}.valueFrom")
        for name, vol in (dep.get("volumes") or {}).items() if isinstance(
                dep.get("volumes"), dict) else []:
            if isinstance(vol, dict) and ("configMap" in vol or "secret" in vol):
                reasons.append(f"deployment.volumes.{name}")
        cm = doc.get("configMap") if isinstance(doc.get("configMap"), dict) else {}
        if cm.get("enabled") and cm.get("files"):
            reasons.append("configMap.files")
        if not reasons:
            continue
        err(rel, f"takes configuration from a ConfigMap or Secret ({', '.join(reasons)}) "
                 f"and no reloader component on this cluster has sync.automated true. "
                 f"A subPath mount is never refreshed in a running container, so the "
                 f"change reaches the pod only when the pod is replaced — and the chart "
                 f"already writes an annotation asking a controller to replace it. "
                 f"Without the controller the config change is Synced, Healthy, and not "
                 f"delivered")


def check_scripts_are_executable() -> None:
    """A gate that cannot be run is not a gate, and it fails as something else.

    The mode is part of what git stores, and a checkout that lost it turns every
    gate into `Permission denied`. In the prover that surfaces as every case
    failing at once, which reads as every rule being broken rather than as one
    wrong file mode -- and the line that says which is the third line of each
    failure.

    Checked on the working tree, which is what CI has: the runner's checkout is
    exactly where a lost mode does its damage.
    """
    for top in ("hack", "bootstrap"):
        d = ROOT / top
        if not d.is_dir():
            continue
        for f in sorted(d.iterdir()):
            if f.suffix not in (".sh", ".py") or not f.is_file():
                continue
            if not os.access(f, os.X_OK):
                err(f"{top}/{f.name}", "is not executable. Every caller runs it as "
                                       "`./" + top + "/" + f.name + "`, so this is a "
                                       "gate that reports Permission denied instead "
                                       "of an answer")


def check_no_tool_conditionals() -> None:
    """Clause 3: `if name == "<tool>"` in the machine means a tool leaked in."""
    pattern = re.compile(r'(?:eq\s+\S+\s+"([a-z0-9-]{3,})"|==\s*["\']([a-z0-9-]{3,})["\'])')
    generic = {"chart", "path", "helm", "true", "false", "app", "data", "raw",
               "tenants", "shared", "platform", "dev", "qa", "stage", "prod",
               "directory", "kustomize", "operator", "oidc", "none", "external",
               # The suffix the envs ApplicationSet gives its own Application,
               # and git's own object type. Machine vocabulary, not tools.
               # GitLab's own vocabulary, and git's. Machine words, not tools.
               "baseline", "blob", "tree", "commit", "manual", "always",
               "on_success", "gate",
               # Kubernetes' own Secret vocabulary, same class as blob and
               # commit above: the key inside a kubernetes.io/dockerconfigjson
               # Secret, which bootstrap/seed-vault-kv.sh matches on to find
               # which Vault path holds the image pull credential. Not a tool.
               "dockerconfigjson",
               # Status vocabulary in hack/check-mirror.py. That tool has to keep
               # "the mirror answered and does not have it" apart from "the
               # mirror did not answer", because collapsing the two reports every
               # image as missing the moment a network drops. The word for the
               # first one is this, and it is not a tool.
               "absent", "unreachable"}
    for top in MACHINE:
        base = ROOT / top
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*")):
            if not f.is_file() or f.suffix not in (".yaml", ".tpl", ".py", ".sh"):
                continue
            rel = str(f.relative_to(ROOT))
            for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                for a, b in pattern.findall(line):
                    tok = a or b
                    if tok in generic:
                        continue
                    warn(f"{rel}:{n}", f"machine behaviour conditional on `{tok}`. "
                                       f"If that is a tool name, it does not belong here")


# --------------------------------------------------------------------------- #
# The derived AppProject destinations
# --------------------------------------------------------------------------- #
def check_platform_namespaces(cluster: dict, cfile: Path) -> None:
    """cluster.yaml:platformNamespaces is a VIEW of platform/*/component.yaml.

    Helm cannot read files outside its chart directory, so the AppProject needs
    the list at render time. That is the only reason it is repeated. The folder
    is the source; this refuses the moment the view stops matching it.

    Without the check the failure is Argo CD's, and it names the project rather
    than the missing entry:

        application destination namespace 'X' does not match any of the
        allowed destinations in project 'platform'
    """
    declared = sorted(set(cluster.get("platformNamespaces") or []))
    derived = set()
    for comp in sorted((ROOT / "platform").glob("*/component.yaml")):
        doc = load(comp) or {}
        ns = doc.get("namespace")
        if ns:
            derived.add(ns)
    derived_l = sorted(derived)
    if declared != derived_l:
        rel = str(cfile.relative_to(ROOT))
        missing = [n for n in derived_l if n not in declared]
        extra = [n for n in declared if n not in derived_l]
        parts = []
        if missing:
            parts.append(f"missing {missing}")
        if extra:
            parts.append(f"stale {extra}")
        err(rel, f"platformNamespaces does not match platform/*/component.yaml "
                 f"({'; '.join(parts)}). The folders are the source; fix this list, "
                 f"not them")


# --------------------------------------------------------------------------- #
# The component.yaml contract
# --------------------------------------------------------------------------- #
# The seven the machine grants unconditionally; anything else is this
# cluster's, and cluster.yaml has to say so.
BASELINE_CLUSTER_KINDS = {
    ("", "Namespace"),
    ("apiextensions.k8s.io", "CustomResourceDefinition"),
    ("rbac.authorization.k8s.io", "ClusterRole"),
    ("rbac.authorization.k8s.io", "ClusterRoleBinding"),
    ("admissionregistration.k8s.io", "ValidatingWebhookConfiguration"),
    ("admissionregistration.k8s.io", "MutatingWebhookConfiguration"),
    ("scheduling.k8s.io", "PriorityClass"),
}


def check_platform_cluster_resources(cluster: dict, cfile: Path) -> None:
    """The platform AppProject's cluster-scoped whitelist, against what the
    components in this repository actually create.

    Same shape as platformNamespaces, and for the same reason: a hand-kept list
    of one customer's kinds inside the machine is what section 1 of the
    standard was written about. The folders are the source.

    pki creates a ClusterIssuer and eso-config a ClusterSecretStore and a
    ClusterExternalSecret. None was permitted, so both Applications sat at
    OutOfSync/Missing with `resource external-secrets.io:ClusterSecretStore is
    not permitted in project platform` -- a message that names the kind and the
    project and neither the tool nor the file to edit.

    What can be seen from here: manifestsDir components are parsed, localChart
    components are rendered. A remote chart cannot be read without fetching it,
    so a third-party chart bringing its own cluster-scoped kind is still found
    the way this one was -- on the cluster. The seven baseline kinds cover what
    installing anything needs, which is most of that gap.

    A kind counts as cluster-scoped here if it is named `Cluster...` or is one
    of the three the API has always had at that level. That is a heuristic, and
    it is the honest one: the alternative is asking a cluster, and this runs
    before there is one.
    """
    declared = {(d.get("group", ""), d.get("kind"))
                for d in (cluster.get("platformClusterResources") or [])}
    found: dict[tuple[str, str], set[str]] = {}
    for comp in sorted((ROOT / "platform").glob("*/component.yaml")):
        d = comp.parent
        c = yaml.safe_load(comp.read_text(encoding="utf-8")) or {}
        docs: list = []
        if c.get("manifestsDir"):
            for f in sorted((ROOT / c["manifestsDir"]).rglob("*.yaml")):
                docs += [x for x in yaml.safe_load_all(f.read_text(encoding="utf-8")) if x]
        elif c.get("localChart"):
            out = subprocess.run(
                ["helm", "template", d.name, str(ROOT / c["localChart"]),
                 "-f", str(cfile), "-f", str(d / "values.yaml")],
                capture_output=True, text=True)
            if out.returncode != 0:
                continue
            docs += [x for x in yaml.safe_load_all(out.stdout) if x]
        for x in docs:
            kind = x.get("kind", "")
            if not (kind.startswith("Cluster")
                    or kind in ("CustomResourceDefinition", "Namespace", "PriorityClass")):
                continue
            api = x.get("apiVersion", "")
            grp = api.split("/")[0] if "/" in api else ""
            found.setdefault((grp, kind), set()).add(d.name)

    for key in sorted(found):
        if key in BASELINE_CLUSTER_KINDS or key in declared:
            continue
        grp, kind = key
        # Hoisted, because `{grp or '\"\"'}` inside the f-string below is a
        # backslash in an f-string expression. Python only started allowing that
        # in 3.12 (PEP 701); on 3.11 and older it is a SyntaxError at import,
        # and the whole gate never runs. The runner this file is written for has
        # the older one, and every workstation here has the newer -- so it was
        # green everywhere it was tested and red in the only place that counts.
        shown = grp if grp else '""'
        err(str(cfile.name), f"platformClusterResources does not name "
                             f"`{{group: {shown}, kind: {kind}}}`, which "
                             f"{sorted(found[key])[0]} creates. Argo refuses it with "
                             f"`resource {grp}:{kind} is not permitted in project "
                             f"platform`, naming neither the tool nor this list")
    for key in sorted(declared - set(found) - BASELINE_CLUSTER_KINDS):
        shown = key[0] if key[0] else '""'
        warn(str(cfile.name), f"platformClusterResources names "
                              f"`{{group: {shown}, kind: {key[1]}}}` and "
                              f"nothing in platform/ creates it. Stale entries widen "
                              f"the project for nothing")


def check_components(cluster: dict) -> int:
    base = ROOT / "platform"
    if not base.is_dir():
        return 0
    registries = cluster.get("allowedImageRegistries") or []
    chart_repos = cluster.get("chartRepos") or {}
    seen = 0
    for comp_file in sorted(base.glob("*/component.yaml")):
        seen += 1
        tool = comp_file.parent.name
        rel = str(comp_file.relative_to(ROOT))
        doc = load(comp_file)
        if not isinstance(doc, dict):
            err(rel, "must be a YAML mapping")
            continue

        if not doc.get("namespace"):
            err(rel, "namespace is required and may not be empty — it is what the "
                     "AppProject destination is derived from")
        if "wave" in doc:
            err(rel, "`wave` is not a valid key. Ordering Applications relative to one "
                     "another needs RollingSync, and RollingSync forces autosync off on "
                     "every generated Application — selfHeal with it. Section 4 ranks "
                     "reconciliation above ordering, so the machine has neither. "
                     "`requires` records the dependency; Argo CD retries until it holds")
        if "path" in doc:
            err(rel, "`path` is not a valid key. The git generator supplies its own "
                     "`.path` for this file, and a top-level `path` here shadows it — "
                     "the Application name and the source path both break, and neither "
                     "failure mentions this file. Use `manifestsDir`")
        kinds = [k for k in ("chart", "manifestsDir", "localChart") if doc.get(k)]
        if len(kinds) != 1:
            err(rel, f"exactly one of chart / manifestsDir / localChart is required, "
                     f"got {kinds or 'none'}")
        if doc.get("chart"):
            ch = doc["chart"]
            for key in ("name", "version", "repo"):
                if not (isinstance(ch, dict) and ch.get(key)):
                    err(rel, f"chart.{key} is required")
            repo = (ch or {}).get("repo")
            if repo and repo not in chart_repos:
                err(rel, f"chart.repo `{repo}` is not a key in cluster.yaml:chartRepos "
                         f"({sorted(chart_repos) or 'none defined'}). A key that does not "
                         f"resolve reaches Argo CD verbatim and fails there as "
                         f"`repository not permitted`, which names neither file")

        sync = doc.get("sync")
        if not isinstance(sync, dict):
            err(rel, "sync is required")
            sync = {}
        for key in ("automated", "selfHeal", "prune"):
            if key not in sync:
                err(rel, f"sync.{key} must be written explicitly. The difference "
                         f"between `false` and absent is the difference between a "
                         f"decision and an oversight")

        # No createNamespace key, deliberately. CreateNamespace=true is decided
        # by SCOPE in the machine -- every platform Application gets it, no
        # tenant one does -- because creating a namespace that already exists is
        # a no-op. A per-component key would change no behaviour, and a field
        # that changes no behaviour is a number nobody reads.
        if "createNamespace" in doc:
            err(rel, "`createNamespace` is not a valid key. Namespace creation is "
                     "decided by scope in the machine: platform Applications create "
                     "theirs, tenant ones never do because charts/env-baseline owns "
                     "those. Creating one that exists is a no-op, so there is nothing "
                     "for a component to decide")

        for dep in doc.get("requires") or []:
            if not (base / dep / "component.yaml").exists():
                err(rel, f"requires `{dep}`, but platform/{dep}/component.yaml does "
                         f"not exist on this cluster. The sync fails later on a "
                         f"missing CRD or certificate, naming neither component")

        if doc.get("stateful"):
            if sync.get("prune"):
                err(rel, "stateful with sync.prune true — pruning a stateful "
                         "service's resources is how its PersistentVolumeClaims get "
                         "deleted, and `git revert` does not bring data back")
            if not appset_index()[0].get("platform", {}).get("preserve"):
                err(rel, "stateful, but the platform ApplicationSet does not set "
                         "preserveResourcesOnDeletion — removing this folder would "
                         "cascade to its volumes")

        images = load(comp_file.parent / "images.yaml")
        if images is None:
            warn(rel, "no images.yaml beside it — the air-gap mirror list for this "
                      "tool is unstated")
        else:
            for img in images if isinstance(images, list) else (images or {}).get("images") or []:
                if registries and not any(str(img).startswith(r) for r in registries):
                    err(f"platform/{tool}/images.yaml",
                        f"`{img}` is not in cluster.yaml:allowedImageRegistries. On an "
                        f"air-gapped cluster the first pull goes nowhere, a long way "
                        f"from this file")
        if not (comp_file.parent / "RUNBOOK.md").exists():
            warn(rel, "no RUNBOOK.md beside it — how it is healthy, what its silent "
                      "failure is, and what turning it off breaks are unrecorded")
    return seen


# --------------------------------------------------------------------------- #
# ApplicationSet invariants
# --------------------------------------------------------------------------- #
def appset_index(probe: bool = False) -> tuple[dict[str, dict], str]:
    """Render the machine and read back what it actually produced.

    With probe=True, a synthetic chartRepos entry is injected. The chart branch
    of the templatePatch is only emitted when there is at least one repo to bake
    a lookup for, so on a cluster that has none yet — a repo at genesis — the
    structural checks would find no layers and no ref, and report the machine as
    broken. Those checks are about the MACHINE, so they run against a render
    that always has the branch, independent of what this cluster has today.
    """
    import subprocess
    cfile = cluster_file()
    cmd = ["helm", "template", "cc", str(ROOT / "charts" / "cluster-config"),
           "-f", str(cfile)]
    if probe:
        cmd += ["--set", "chartRepos.probe=https://probe.example/"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        # An error, not a warning, and it stops here.
        #
        # Warning and carrying on with an empty index is worse than stopping.
        # Every check that reads the index then measures nothing and reports it
        # as something: on an image without helm it announces that the stateful
        # components are unprotected while the ApplicationSet it compares against
        # was never rendered -- a frightening sentence about files that are
        # correct. The run says `0 ApplicationSet(s)` in the same breath, and
        # nobody reads that line first.
        #
        # A gate that cannot run must say so and refuse. Inventing findings is
        # worse than skipping, and skipping is already worse than nothing.
        err("hack/validate.py", "helm is not installed, so the ApplicationSets were "
                                "never rendered and nothing that depends on them "
                                "could be checked. Put helm in this image rather "
                                "than reading past this line")
        RENDER_UNAVAILABLE.append(True)
        return {}, ""
    except subprocess.CalledProcessError as exc:
        # The whole of stderr, and the exit code. Printing
        # `stderr.strip().splitlines()[-1:]` gives a Python list repr of the last
        # line, which is `[]` when helm said nothing at all -- `does not render:
        # []`, naming neither the chart, the reason, nor the fact that helm
        # itself was the problem.
        #
        # A helm that exits non-zero with an empty stderr is not a chart error.
        # It is an environment one -- no writable HOME or cache directory is the
        # usual cause -- and the message says so, because the operator reading
        # this is about to go and look at the chart.
        detail = (exc.stderr or "").strip()
        if not detail:
            detail = (f"helm exited {exc.returncode} and said nothing. That is not "
                      f"a chart error: run `helm version` and `helm template "
                      f"charts/cluster-config -f cluster.yaml` in the same image "
                      f"to see it. A helm with no writable HOME fails exactly "
                      f"like this.")
        else:
            detail = f"helm exited {exc.returncode}:\n" + "\n".join(
                "    " + l for l in detail.splitlines())
        err("charts/cluster-config", f"does not render. {detail}")
        return {}, ""
    index = {}
    for doc in yaml.safe_load_all(out):
        if doc and doc.get("kind") == "ApplicationSet":
            sp = doc["spec"]
            pol = sp.get("syncPolicy") or {}
            index[doc["metadata"]["name"]] = {
                "ignoreAppDiff": any(
                    "/spec/syncPolicy" in (e.get("jsonPointers") or [])
                    for e in sp.get("ignoreApplicationDifferences") or []),
                "appsSync": pol.get("applicationsSync"),
                "preserve": bool(pol.get("preserveResourcesOnDeletion")),
                "patch": sp.get("templatePatch") or "",
            }
    return index, out


def chart_values() -> dict:
    return load(ROOT / "charts" / "cluster-config" / "values.yaml") or {}


def check_render_contract(cluster: dict, rendered: str) -> None:
    """The gate proved itself; this proves what the gate produces.

    Every refusal below is a way the machine renders happily and then fails on
    the FIRST real folder, which is exactly the class of failure this structure
    exists to move earlier.
    """
    where = "charts/cluster-config"
    projects, appsets = [], []
    for doc in yaml.safe_load_all(rendered):
        if not doc:
            continue
        (projects if doc["kind"] == "AppProject" else appsets).append(doc)

    urls = set((cluster.get("chartRepos") or {}).values())

    # Only the projects that actually host chart-based Applications. Derived,
    # not named: an ApplicationSet with a templatePatch is one that resolves
    # chart.repo, and the literal prefix of its `project:` says which projects
    # its Applications land in. A project whose Applications only ever pull one
    # local chart by path needs no mirror in sourceRepos, and granting it one
    # would widen what that project may pull for no reason.
    chart_hosts = []
    for aset in appsets:
        if not aset["spec"].get("templatePatch"):
            continue
        proj_tpl = ((aset["spec"].get("template") or {}).get("spec") or {}).get("project", "")
        chart_hosts.append(str(proj_tpl).split("{{")[0])

    for proj in projects:
        pname = proj["metadata"]["name"]
        if not any(pname.startswith(pre) for pre in chart_hosts if pre):
            continue
        allowed = set(proj["spec"].get("sourceRepos") or [])
        for url in sorted(urls - allowed):
            err(where, f"AppProject `{proj['metadata']['name']}` does not permit "
                       f"`{url}`, which is a cluster.yaml:chartRepos value. Validating "
                       f"that chart.repo is a known key does not help if the URL it "
                       f"resolves to is refused by the project — the same "
                       f"`repository not permitted`, on the other axis")

    for aset in appsets:
        name = aset["metadata"]["name"]
        patch = aset["spec"].get("templatePatch") or ""
        # Only an ApplicationSet that resolves chart.repo at all. One pulling a
        # single local chart by path has no key to look up, and asking it for a
        # baked mirror URL is a check firing on something it was not about.
        if not patch:
            continue
        for url in sorted(urls):
            if url not in patch:
                err(where, f"ApplicationSet `{name}` never resolves chart.repo to "
                           f"`{url}`. chart.repo is a KEY into cluster.yaml:chartRepos "
                           f"and the lookup has to be baked in at render time")


def check_project_descriptions(rendered: str) -> None:
    """The API caps AppProject.spec.description at 255 bytes, and rejects the
    object rather than truncating it.

    The `envs` project carried 320 bytes of reasoning. Nothing on a workstation
    saw it: helm renders it, the YAML is valid, and every gate here read it
    happily. The API found it on the first real sync -- and by then the other
    projects and all five ApplicationSets existed, so the cluster looked mostly
    built while the one project that owns namespaces was missing and the root
    Application sat Degraded.

    Bytes, not characters: the limit is on the encoded value, and Persian or a
    dash in the wrong place makes those two numbers differ.
    """
    for doc in yaml.safe_load_all(rendered):
        if not doc or doc.get("kind") != "AppProject":
            continue
        desc = (doc.get("spec") or {}).get("description") or ""
        n = len(desc.encode("utf-8"))
        if n > 255:
            err(f"charts/cluster-config: AppProject {doc['metadata']['name']}",
                f"has a {n}-byte description and the API refuses anything over "
                f"255. Put the reasoning in a YAML comment, which never reaches "
                f"the cluster")


def check_templatepatch_scope(rendered: str) -> None:
    """A templatePatch may only carry `spec`, and the indentation decides that.

    The patch is a merge patch against the generated Application. Its keys came
    out level with `spec:` instead of under it, because the block scalar's base
    indentation is set by `spec:` and the helper's own two spaces were added to
    two more. The result read: spec is null -- which in a merge patch means
    DELETE spec -- plus root-level sources and syncPolicy, which are not fields
    of an Application at all.

    Every Application generated from it was rejected for having no spec. Three
    ApplicationSets produced nothing on a live cluster while the two without a
    patch worked, and that difference was the only symptom. Nothing rendered
    wrong: the YAML was valid at every step.

    Read as text, not parsed: the patch is a Go template and half its lines are
    directives. A key at column zero is the whole question.
    """
    key = re.compile(r"^([A-Za-z_][\w.-]*):")
    for doc in yaml.safe_load_all(rendered):
        if not doc or doc.get("kind") != "ApplicationSet":
            continue
        patch = (doc.get("spec") or {}).get("templatePatch")
        if not patch:
            continue
        name = doc["metadata"]["name"]
        top = set()
        for line in patch.splitlines():
            if not line.strip() or line.lstrip().startswith(("{{", "#")):
                continue
            m = key.match(line)
            if m:
                top.add(m.group(1))
        if top - {"spec"}:
            err(f"charts/cluster-config: ApplicationSet {name}",
                f"templatePatch carries {sorted(top - {'spec'})} at the top level. "
                f"A merge patch against an Application has one key there, `spec`; "
                f"anything beside it is dropped as an unknown field, and a bare "
                f"`spec:` with nothing under it deletes the spec instead")


def check_localchart_values(rendered: str) -> None:
    """hack/render.sh and the ApplicationSet must feed a local chart the same
    files.

    They can disagree silently. render.sh runs
    `helm template <chart> -f cluster.yaml -f <comp>/values.yaml` and reports
    `ok`, while a patch that gives a localChart component no values leaves Argo
    running `helm template .` with only the chart's own defaults. The chart then
    refuses to render for want of a required value, and the Application sits at
    Unknown with Healthy beside it -- Healthy because nothing was compared.

    The gate is then right about the chart and wrong about the deployment: it
    passes for a reason unrelated to what it claims.

    Two lists, in two languages, that have to say the same thing: the patch
    reaches them through $values because a localChart path's depth is a
    convention, and render.sh reaches them as ordinary paths.
    """
    want_patch = ("$values/cluster.yaml", "/values.yaml")
    for doc in yaml.safe_load_all(rendered):
        if not doc or doc.get("kind") != "ApplicationSet":
            continue
        patch = (doc.get("spec") or {}).get("templatePatch") or ""
        if ".localChart" not in patch:
            continue
        name = doc["metadata"]["name"]
        seg = patch[patch.index(".localChart"):]
        seg = seg[:seg.index("{{- else }}")] if "{{- else }}" in seg else seg
        for token in want_patch:
            if token not in seg:
                err(f"charts/cluster-config: ApplicationSet {name}",
                    f"gives a localChart no `{token}`. A chart in this repository "
                    f"still needs values; without them Argo renders it with its "
                    f"own defaults and the Application stops at Unknown")

    r = ROOT / "hack" / "render.sh"
    if not r.exists():
        return
    line = next((l for l in r.read_text(encoding="utf-8").splitlines()
                 if "helm template" in l and "local_chart" in l), None)
    if line is None:
        err("hack/render.sh", "no longer renders localChart components, so nothing "
                              "here checks that a chart in this repository renders "
                              "at all")
        return
    for token in ('-f "$CLUSTER"', '-f "$d/values.yaml"'):
        if token not in line:
            err("hack/render.sh", f"renders a localChart without `{token}`, so it "
                                  f"proves something the cluster will not do. The "
                                  f"ApplicationSet passes both; this has to pass "
                                  f"both")


def check_app_chart_parameters(rendered: str) -> None:
    """Parameters meant for the generic application chart must not be sent to
    every chart.

    `applicationName` sat outside the image guard, so the patch set it on every
    remote chart. Whether that is fatal depends on something the machine cannot
    see: cert-manager ships a values.schema.json and refused with `additional
    properties 'applicationName' not allowed`; external-secrets and
    redis-operator ship none and ignored it. One Application stuck at Unknown,
    two green, the same wrong parameter in all three -- and the two green ones
    are why nobody looked.

    A component declaring an image is the signal that it uses the application
    chart, because that is the only chart here taking an image from config.yaml.
    So every injected parameter belongs inside that guard, and this check reads
    the patch as text to say so: for each parameter emitted, the nearest `if`
    above it has to be the image one.
    """
    for doc in yaml.safe_load_all(rendered):
        if not doc or doc.get("kind") != "ApplicationSet":
            continue
        patch = (doc.get("spec") or {}).get("templatePatch") or ""
        name = doc["metadata"]["name"]
        lines = patch.splitlines()
        for i, line in enumerate(lines):
            m = re.match(r"\s*- name: (\S+)", line)
            if not m:
                continue
            guard = ""
            for j in range(i - 1, -1, -1):
                st = lines[j].strip()
                if st.startswith("{{- if") or st.startswith("{{ if"):
                    guard = st
                    break
                if st.startswith("{{- end"):
                    break
            if 'hasKey . "image"' not in guard:
                err(f"charts/cluster-config: ApplicationSet {name}",
                    f"emits helm parameter `{m.group(1)}` outside the image guard, "
                    f"so it reaches every chart. A chart with a values schema "
                    f"refuses it and one without silently ignores it -- and the "
                    f"second kind is why this stayed hidden")
                break


def check_patch_structure(rendered: str) -> None:
    """Checks about the machine's templatePatch, not about this cluster."""
    where = "charts/cluster-config"
    for aset in yaml.safe_load_all(rendered):
        if not aset or aset.get("kind") != "ApplicationSet":
            continue
        name = aset["metadata"]["name"]
        patch = aset["spec"].get("templatePatch") or ""
        tspec = ((aset["spec"].get("template") or {}).get("spec") or {})
        in_template = bool(tspec.get("source") or tspec.get("sources"))
        if not patch and not in_template:
            err(where, f"ApplicationSet `{name}` has no templatePatch and its template "
                       f"declares no source. It would generate Applications with "
                       f"nothing to pull from")
            continue
        # An ApplicationSet whose source shape is fixed declares it in the
        # template and needs no patch. Only the `ref: values` rule applies to
        # those; a chart.repo lookup, the value layers and the hasKey guards are
        # all properties of a patch that has a chart branch, and demanding them
        # of an ApplicationSet that pulls one local chart is a check firing on
        # something it was not written about.
        if in_template and not patch:
            if not re.search(r"\$values", yaml.safe_dump(tspec)) or re.search(
                    r"^\s*-?\s*ref:\s*values\s*$", yaml.safe_dump(tspec), re.M):
                continue
            err(where, f"ApplicationSet `{name}` uses $values without a second source "
                       f"carrying `ref: values`. Argo CD resolves $values only against "
                       f"such a source; without it the chart renders with its own "
                       f"defaults, which looks like it worked")
            continue
        # The prose above this field in the patch also contains the words
        # "ref: values", and matched — so the check passed while the field it
        # guards was gone. Match the emitted YAML key, anchored to a line.
        if not re.search(r"^\s*-?\s*ref:\s*values\s*$", patch, re.MULTILINE):
            err(where, f"ApplicationSet `{name}` uses $values without a second source "
                       f"carrying `ref: values`. Argo CD resolves $values only against "
                       f"such a source; without it the chart renders with its own "
                       f"defaults, which looks like it worked")
        # missingkey=error turns a bare truthiness test on an ABSENT key into a
        # hard failure: `map has no entry for key "chart"`, and generation stops.
        # A component using manifestsDir, and every tenant config.yaml, has no
        # `chart` key. The optional keys must be reached through hasKey.
        if "RespectIgnoreDifferences=true" not in patch:
            err(where, f"ApplicationSet `{name}` does not set "
                       f"RespectIgnoreDifferences=true. Without it ignoreDifferences "
                       f"affects only the diff, and sync still applies the field from "
                       f"git — so a controller-owned field is stomped every sync")

        for key in ("chart", "localChart", "manifestsDir", "sync"):
            # A nested test such as `if .sync.automated` is safe when the patch
            # guards the parent somewhere, so the presence of the guard anywhere
            # is the evidence. Crude, and deliberately so: the alternative is
            # parsing Go templates to prove a lexical scope.
            if f'hasKey . "{key}"' in patch:
                continue
            for form in (f"if .{key}", f"if not .{key}"):
                if form in patch:
                    err(where, f"ApplicationSet `{name}` templatePatch tests `{form}` "
                               f"directly. goTemplateOptions sets missingkey=error, "
                               f"under which that is not false on a file without "
                               f"`{key}` — it is `map has no entry for key \"{key}\"` "
                               f"and generation stops. Use hasKey")
        # Matched against the emitted option, never the word: the comment that
        # explains this field also contains it, and a looser match passes while
        # the option is gone. That mistake was already made once here.
        emits_ns = bool(re.search(r"^\s*- CreateNamespace=true\s*$", patch, re.M))
        if name == "platform" and not emits_ns:
            err(where, "the platform ApplicationSet never emits CreateNamespace=true. "
                       "On a cluster where the namespace already exists this is "
                       "invisible; on an empty one every component stops at "
                       "`namespace not found`")
        if name in ("tenants", "shared") and emits_ns:
            err(where, f"ApplicationSet `{name}` emits CreateNamespace=true. Tenant "
                       f"namespaces are owned by charts/env-baseline, which builds them "
                       f"from env.yaml with the quota and network posture attached — an "
                       f"Application creating its own would be a second owner")
        if name in ("tenants", "shared"):
            # A values file is not templated and cannot know the folder it is in
            # or the tag CI just wrote. If the patch does not inject them, the
            # chart renders with its own defaults and the Application looks
            # perfectly healthy running the wrong image.
            for param in ("applicationName", "deployment.image.repository",
                          "deployment.image.tag"):
                if param not in patch:
                    err(where, f"ApplicationSet `{name}` never injects the image or the "
                               f"name: `{param}` is not among its Helm parameters. The "
                               f"values file cannot supply either, so the chart falls "
                               f"back to its own defaults and says nothing")
        if name in ("tenants",):
            for layer in chart_values().get("tenantValueLayers") or []:
                stem = layer.split("{")[0]
                if stem not in patch:
                    err(where, f"ApplicationSet `{name}` does not mount the value layer "
                               f"`{layer}`. A workload needing a shared default would "
                               f"otherwise require a machine commit, which a product "
                               f"commit may not make")
            if "ignoreMissingValueFiles: true" not in patch:
                err(where, f"ApplicationSet `{name}` mounts value layers without "
                           f"ignoreMissingValueFiles — a cluster that does not use one "
                           f"of them fails to render instead of skipping it")


def check_appsets(index: dict) -> None:
    if not index:
        return
    for name, a in sorted(index.items()):
        where = "charts/cluster-config/templates/appsets.yaml"
        if not a["ignoreAppDiff"]:
            err(where, f"ApplicationSet `{name}` has no ignoreApplicationDifferences "
                       f"for /spec/syncPolicy. Disabling auto-sync on one Application "
                       f"during an incident would be undone by this controller within "
                       f"seconds, and the break-glass procedure would be a lie")
        if a["appsSync"] != "create-update":
            err(where, f"ApplicationSet `{name}` has applicationsSync "
                       f"`{a['appsSync']}`, not create-update — it may delete "
                       f"Applications it generated")
        if not a["preserve"]:
            err(where, f"ApplicationSet `{name}` does not set "
                       f"preserveResourcesOnDeletion. A folder removed by a bad rebase "
                       f"would cascade to its PersistentVolumeClaims")



def merged_values(cfg: Path) -> dict:
    """The value layers, in the order the ApplicationSet mounts them.

    The list comes from charts/cluster-config/values.yaml, not from a copy here:
    a fifth layer added to the machine has to reach this check, and a copy agrees
    with it exactly until it does not.

    A workload under shared/ gets ONE layer, its own, because the machine passes
    an empty layer list for that scope. Reading tenants/<scope>/ for it would
    merge files belonging to a tenant that happens to share the name.
    """
    scope = cfg.relative_to(ROOT).parts[0]
    owner, envname = cfg.parent.parent.parent.name, cfg.parent.parent.name
    files = []
    if scope == "tenants":
        for layer in chart_values().get("tenantValueLayers") or []:
            files.append(ROOT / layer.replace("{t}", owner).replace("{e}", envname))
    files.append(cfg.parent / "values.yaml")
    out: dict = {}
    for f in files:
        if f.exists():
            out = deep_merge(out, load(f) or {})
    return out


def deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in (over or {}).items():
        out[k] = deep_merge(out[k], v) if isinstance(out.get(k), dict) and isinstance(v, dict) else v
    return out


def check_route(cluster: dict, cfg: Path, rel: str) -> None:
    """An HTTPRoute that is Accepted and matches nothing is the quietest failure
    this repository can produce. Both halves of it are checkable here.
    """
    route = (merged_values(cfg).get("httpRoute") or {})
    if not route.get("enabled"):
        return
    net = cluster.get("network") or {}
    base = net.get("baseDomain")
    gw_name, gw_ns = net.get("gatewayName"), net.get("gatewayNamespace")

    if not gw_name or not gw_ns:
        err(rel, "httpRoute.enabled is true but cluster.yaml:network.gatewayName or "
                 "gatewayNamespace is empty. The route would attach to nothing and "
                 "report Accepted with ResolvedRefs=False, which nobody reads")
    if not base:
        # Skipping the hostname check when baseDomain is empty made the loudest
        # of these two failures the only one that could not be caught.
        err(rel, "httpRoute.enabled is true but cluster.yaml:network.baseDomain is "
                 "empty, so no hostname can be checked against anything")

    hosts = route.get("hostnames") or []
    if not hosts:
        err(rel, "httpRoute.enabled is true with no hostnames — the route then matches "
                 "every host that reaches the listener, including ones meant for "
                 "someone else")
    # THE ENVIRONMENT PREFIX IS THE RULE. The service part is a name.
    #
    # Demanding `<env>-<service>.<baseDomain>` with BOTH halves read from the
    # folder does not survive contact with real hostnames, and it is worth being
    # exact about why: the strictness is not wrong, it is aimed at the wrong
    # half.
    #
    # Four legitimate names it would refuse:
    #
    #   dev-sso        folder auth-simulator
    #   dev-gateway    folder edge-gateway
    #   dev-mock       folder mock-services
    #   dev            the user-facing root, which has no service part at all
    #
    # A folder name is an object name -- it becomes the Application, the Helm
    # release and every object the chart names, so it is long and explicit on
    # purpose. A hostname is typed by people. Those are different jobs and
    # forcing them to be one string makes the wrong one win. A gate that forbids
    # a legitimate requirement is a gate somebody eventually deletes, and then
    # the protection goes with it.
    #
    # WHAT THE PROTECTION ACTUALLY WAS, kept in full: one environment must not
    # be able to claim another environment's hostname. The listener this cluster
    # attaches to has no hostname constraint and `from: All`, and it cannot get
    # one -- the domain is shared with objects outside this repository, and a
    # DNS wildcard matches one whole leftmost label, so `*.<baseDomain>` is the
    # only listener hostname available and it constrains nothing. A route that
    # claims a host already taken does not fail either: Gateway API resolves the
    # conflict by age, the older route keeps serving, and the newer one reports
    # Accepted while receiving nothing.
    #
    # So the rule is now the prefix, which is the part that carries the
    # environment, and the service part is free:
    #
    #   <env>.<baseDomain>            the environment's own root
    #   <env>-<anything>.<baseDomain> a service in it
    #
    # `dev-qa-thing` is refused by the same rule that refuses `qa-thing` in a
    # dev folder: the label after the prefix may not itself be another
    # environment's name.
    segs = cfg.relative_to(ROOT).parts          # scope / tenant / env / svc
    env = segs[2] if len(segs) >= 4 else None
    envs = set()
    for t in (cluster.get("tenants") or []):
        if isinstance(t, dict):
            envs.update((t.get("environments") or {}).keys())
    for h in hosts:
        h = str(h)
        if base and not h.endswith(f".{base}"):
            err(rel, f"httpRoute hostname `{h}` does not end in `.{base}` "
                     f"(cluster.yaml:network.baseDomain). A misspelled host is accepted "
                     f"by the API server and then matches nothing at all")
            continue
        if not (base and env):
            continue
        left = h[: -len(f".{base}")]
        if left == env:
            continue                            # the environment's own root
        if not left.startswith(f"{env}-"):
            err(rel, f"httpRoute hostname `{h}` does not begin with `{env}` or "
                     f"`{env}-`. The service part is free -- `{env}-sso` for a folder "
                     f"named auth-simulator is fine -- but the environment prefix is not, "
                     f"because it is the only thing standing between this environment "
                     f"and another one's hostname. The Gateway cannot enforce it: its "
                     f"listener takes every host from every namespace")
            continue
        rest = left[len(env) + 1:]
        # `dev-qa-orders` reads as dev and belongs to neither. It passes the
        # prefix rule by accident, which is exactly the kind of near-miss this
        # gate exists for.
        if rest.split("-", 1)[0] in (envs - {env}):
            err(rel, f"httpRoute hostname `{h}` is prefixed `{env}-` and then names "
                     f"the environment `{rest.split('-', 1)[0]}`. It belongs to neither "
                     f"and will serve nothing")

    refs = route.get("parentRefs") or []
    if not refs:
        err(rel, "httpRoute.enabled is true with no parentRefs — it attaches to no "
                 "Gateway")
    for ref in refs:
        if not isinstance(ref, dict):
            continue
        if gw_name and ref.get("name") != gw_name:
            err(rel, f"httpRoute parentRef name `{ref.get('name')}` is not "
                     f"cluster.yaml:network.gatewayName `{gw_name}`")
        if gw_ns and ref.get("namespace") != gw_ns:
            err(rel, f"httpRoute parentRef namespace `{ref.get('namespace')}` is not "
                     f"cluster.yaml:network.gatewayNamespace `{gw_ns}`")


def namespace_labels() -> set[str]:
    """The label keys charts/env-baseline actually puts on a namespace."""
    # Both files: the common ones arrive through an include, and reading only
    # the template that carries the `labels:` key found three of five. A check
    # that sees part of the vocabulary reports the rest as unknown.
    base = ROOT / "charts" / "env-baseline" / "templates"
    files = [base / "namespace.yaml", base / "_helpers.tpl"]
    if not files[0].exists():
        return set()
    keys, in_labels = set(), False
    lines = []
    for f in files:
        if f.exists():
            lines += f.read_text(encoding="utf-8").splitlines()
    for line in lines:
        st = line.strip()
        if st.startswith("labels:"):
            in_labels = True
            continue
        if st.startswith("#"):
            continue
        m = re.match(r"([a-z0-9][a-z0-9._-]*\.[a-z0-9._-]+/[a-z0-9._-]+)\s*:", st)
        if m and (in_labels or line.startswith(("gitops", "app."))):
            keys.add(m.group(1))
        if in_labels and st and not line.startswith((" ", "\t")):
            in_labels = False
    return keys


def check_namespace_selectors() -> None:
    """A selector in platform/ must name a label the namespace actually carries.

    This guards the most expensive failure the structure can produce, and it
    produces it with every gate green: the namespace labels are renamed in the
    machine and the selectors in platform/ are not renamed with them. Nothing
    complains, because the render is correct and the Application is Healthy.
    What happens is that adopting a live namespace replaces its labels with the
    new set, the pull-secret distributor stops matching it, the Secret is
    removed, and every pod that pulls after that fails -- with an error naming a
    registry.
    """
    emitted = namespace_labels()
    if not emitted:
        return
    base = ROOT / "platform"
    if not base.is_dir():
        return
    for f in sorted(base.rglob("*.yaml")):
        rel = str(f.relative_to(ROOT))
        # ONLY inside a namespaceSelector. Matching every `*.internal/x:` line
        # under platform/ reports mostly labels being PUT ON an object rather
        # than selected on, and a check that cannot tell those apart is a check
        # nobody keeps.
        depth = None
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            st = line.strip()
            indent = len(line) - len(line.lstrip())
            if st.startswith("#"):
                continue
            if re.match(r"namespaceSelectors?\s*:", st):
                depth = indent
                continue
            if depth is None:
                continue
            if st and indent <= depth:
                depth = None
                continue
            m = re.match(r"([a-z0-9-]+\.internal/[a-z0-9-]+)\s*:", st)
            if m and m.group(1) not in emitted:
                err(f"{rel}:{n}",
                    f"a namespaceSelector matches on `{m.group(1)}`, which "
                    f"charts/env-baseline does not put on a namespace. It emits "
                    f"{sorted(k for k in emitted if '.internal/' in k)}. A selector "
                    f"matching nothing is not an error anywhere: the object is "
                    f"created, reports Ready, and simply covers no namespace")


def check_workloads(cluster: dict) -> int:
    """The same contract as a platform component, for a tenant workload.

    Without it a workload folder is the only thing in this repository nothing
    reads before Argo CD does, and every one of these refusals is a failure that
    surfaces on the cluster naming something other than this file.
    """
    registries = cluster.get("allowedImageRegistries") or []
    chart_repos = cluster.get("chartRepos") or {}
    seen = 0
    for scope in ("tenants", "shared"):
        base = ROOT / scope
        if not base.is_dir():
            continue
        for cfg in sorted(base.glob("*/*/*/config.yaml")):
            seen += 1
            rel = str(cfg.relative_to(ROOT))
            d = load(cfg)
            if not isinstance(d, dict):
                err(rel, "must be a YAML mapping")
                continue
            env_doc = load(cfg.parent.parent / "env.yaml") or {}
            if d.get("namespace") != env_doc.get("namespace"):
                err(rel, f"namespace `{d.get('namespace')}` is not the namespace of the "
                         f"environment it sits in (`{env_doc.get('namespace')}`). The "
                         f"AppProject destinations come from cluster.yaml, so Argo CD "
                         f"refuses it with a message naming the project")

            if "path" in d:
                err(rel, "`path` is not a valid key — it shadows the git generator's own "
                         "`.path`, breaking the Application name and the source path. "
                         "Use `manifestsDir`")
            if "wave" in d:
                err(rel, "`wave` is not a valid key; nothing reads it")
            if "createNamespace" in d:
                err(rel, "`createNamespace` is not a valid key. A tenant Application "
                         "never creates a namespace — charts/env-baseline owns them, "
                         "and two owners of one namespace agree on the name and "
                         "nothing else")
            kinds = [k for k in ("chart", "manifestsDir", "localChart") if d.get(k)]
            if len(kinds) != 1:
                err(rel, f"exactly one of chart / manifestsDir / localChart is required, "
                         f"got {kinds or 'none'}")
            ch = d.get("chart") if isinstance(d.get("chart"), dict) else {}
            if d.get("chart"):
                for key in ("name", "version"):
                    if not ch.get(key):
                        err(rel, f"chart.{key} is required — an unpinned chart is a "
                                 f"different render on every sync")
            repo = ch.get("repo")
            if d.get("chart") and repo not in chart_repos:
                err(rel, f"chart.repo `{repo}` is not a key in cluster.yaml:chartRepos "
                         f"({sorted(chart_repos) or 'none defined'})")

            # REQUIRED for a chart workload, not merely checked when present.
            # `hasKey image` in the ApplicationSet means a workload without one
            # simply gets no image parameter: the chart renders with whatever its
            # own values say and the Application reports Healthy running it. That
            # is the silent shape this whole contract exists for.
            img = d.get("image") or {}
            if d.get("chart") and not img:
                err(rel, "image is required for a chart workload. Without it the "
                         "ApplicationSet injects no image parameter, the chart renders "
                         "with its own default, and the Application is Healthy running "
                         "something nobody chose")
            if img:
                r = str(img.get("repository", ""))
                if not r:
                    err(rel, "image.repository is required when image is set")
                elif registries and not any(r.startswith(a) for a in registries):
                    err(rel, f"image.repository `{r}` is not in "
                             f"cluster.yaml:allowedImageRegistries")
                if not img.get("tag"):
                    err(rel, "image.tag is required — it is the one line CI writes")

            sync = d.get("sync")
            if not isinstance(sync, dict):
                err(rel, "sync is required")
                sync = {}
            for key in ("automated", "selfHeal", "prune"):
                if key not in sync:
                    err(rel, f"sync.{key} must be written explicitly")

            # Same rule as a platform component. Dormant today because no
            # workload here is stateful -- which is exactly when a missing check
            # is cheapest to add and most likely to be forgotten. A tenant's
            # database instance is a workload, and pruning it deletes the volume.
            if d.get("stateful") and (sync or {}).get("prune"):
                err(rel, "stateful with sync.prune true — pruning a stateful "
                         "workload's resources is how its PersistentVolumeClaims get "
                         "deleted, and `git revert` does not bring data back")

            check_route(cluster, cfg, rel)

            if not (cfg.parent / "values.yaml").exists() and d.get("chart"):
                err(rel, "values.yaml is required beside config.yaml for a chart "
                         "workload — the ApplicationSet mounts it as the last value "
                         "layer and Argo CD fails the render without it")
    return seen


def check_envs(cluster: dict) -> int:
    """env.yaml: the namespace's own contract, and the derived profile list."""
    seen = 0
    declared = {"tenants": {}, "shared": {}}
    for t in cluster.get("tenants") or []:
        declared["tenants"][t.get("name")] = t.get("environments") or {}
    for sc in cluster.get("sharedScopes") or []:
        declared["shared"][sc.get("name")] = sc.get("environments") or {}
    for scope in ("tenants", "shared"):
        for env_file in sorted((ROOT / scope).glob("*/*/env.yaml")) if (ROOT / scope).is_dir() else []:
            seen += 1
            rel = str(env_file.relative_to(ROOT))
            d = load(env_file)
            if not isinstance(d, dict):
                err(rel, "must be a YAML mapping")
                continue
            owner, envname = env_file.parent.parent.name, env_file.parent.name
            if d.get("tenant") != owner or d.get("env") != envname:
                err(rel, f"says tenant={d.get('tenant')!r} env={d.get('env')!r} but sits "
                         f"in {owner}/{envname}. The folder is the truth; these two keys "
                         f"are what the chart labels every object with")
            ns = d.get("namespace")
            if not ns:
                err(rel, "namespace is required")
            elif declared[scope].get(owner, {}).get(envname) != ns:
                key = "tenants" if scope == "tenants" else "sharedScopes"
                err(rel, f"namespace `{ns}` is not what cluster.yaml:{key} says for "
                         f"{owner}/{envname} "
                         f"({declared[scope].get(owner, {}).get(envname)!r}). "
                         f"The AppProject destinations come from cluster.yaml, so the "
                         f"Application would be refused with a message naming the "
                         f"project and not this file")

            net = d.get("network") or {}
            if "enabled" not in net:
                err(rel, "network.enabled must be written explicitly. Absent reads as "
                         "`no policy`, which is the same as `false` and means something "
                         "very different from a permissive policy")

            # The aggregation, derived. Section 11.1 of the standard: the
            # workload folder is the source and this is a view of it.
            want = sorted({
                (load(c) or {}).get("networkProfile")
                for c in sorted(env_file.parent.glob("*/config.yaml"))
                if (load(c) or {}).get("networkProfile")
            })
            have = sorted(net.get("profiles") or [])
            if want != have:
                err(rel, f"network.profiles is {have}, but the workloads in this "
                         f"environment name {want}. This list is a view of the folders, "
                         f"never a declaration — a hand-kept one is the inventory that "
                         f"gates execution which section 2 forbids")
            # <t>-<env>-baseline is the environment's own Application. A
            # workload folder of that name generates a second Application with
            # the same name, and the two would overwrite each other's spec on
            # every reconcile. The ApplicationSet comment claimed this was
            # already refused; it was not.
            for w in sorted(env_file.parent.glob("*/config.yaml")):
                if w.parent.name == "baseline":
                    err(str(w.parent.relative_to(ROOT)),
                        "a workload folder may not be called `baseline` — its "
                        "Application would be named <tenant>-<env>-baseline, which is "
                        "the environment's own, and the two would fight over one object")

            for name in have:
                if not (ROOT / "charts" / "env-baseline" / "profiles" / f"{name}.yaml").exists():
                    err(rel, f"network profile `{name}` has no file in "
                             f"charts/env-baseline/profiles/. The chart fails at render "
                             f"rather than emitting a policy with a silent hole, but it "
                             f"fails at sync time and this fails now")
    return seen


def main() -> int:
    cfile = cluster_file()
    cluster = load(cfile) or {}
    check_machine_clean()
    check_no_tool_conditionals()
    check_machine_names_nothing()
    check_ci_parses()
    check_shelf_allowlist()
    check_scripts_are_executable()
    check_no_written_out_sync_policy()
    check_no_duplicate_yaml_keys()
    check_rendered_output_is_read()
    check_status_exit_codes_are_not_piped()
    check_key_material_is_not_written_through()
    check_exec_does_not_share_a_loop_with_read()
    check_seeding_is_not_retyped()
    check_python_parses_on_an_older_runner()
    check_the_prover_copies_faithfully()
    check_every_ceremony_is_listed()
    check_a_private_image_has_a_pull_secret(cluster)
    check_a_folder_name_is_a_kubernetes_name()
    check_no_two_workloads_claim_one_hostname(cluster)
    check_raw_manifests_list_what_must_be_mirrored(cluster)
    check_a_config_file_in_git_holds_no_secret()
    check_a_mounted_config_has_something_to_reload_it()
    check_nothing_is_silenced()
    check_platform_namespaces(cluster, cfile)
    check_platform_cluster_resources(cluster, cfile)
    check_namespace_selectors()
    index, rendered = appset_index()
    if RENDER_UNAVAILABLE:
        # Stop here. Every check below reads the index, and an empty index makes
        # each of them report the absence of something it never looked at.
        for line in warnings:
            print(f"WARN  {line}")
        for line in errors:
            print(f"ERROR {line}")
        print("\nnothing was checked — see the error above")
        sys.exit(1)
    check_appsets(index)
    if rendered:
        check_render_contract(cluster, rendered)
        check_project_descriptions(rendered)
        check_templatepatch_scope(rendered)
        check_localchart_values(rendered)
        check_app_chart_parameters(rendered)
        _, probed = appset_index(probe=True)
        if probed:
            check_patch_structure(probed)
    n = check_components(cluster)
    e = check_envs(cluster)
    w = check_workloads(cluster)

    for line in warnings:
        print(f"WARN  {line}")
    for line in errors:
        print(f"ERROR {line}")
    print(f"\n{len(index)} ApplicationSet(s), {n} platform component(s), "
          f"{e} environment(s), {w} workload(s) checked — "
          f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
