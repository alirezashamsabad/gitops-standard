#!/usr/bin/env bash
# Bring ONE thing from main onto the migration branch, with the cluster.yaml
# lines it needs, and stop if the gate refuses the result.
#
# The migration branch starts with no product so that the new ApplicationSets
# generate nothing while the old ones are still running. Both structures name
# their Applications identically, and two controllers owning one Application
# rewrite each other's spec on every reconcile -- quietly. One thing at a time is
# what keeps them from ever seeing the same folder.
#
#   ./hack/cutover.sh platform/vault
#   ./hack/cutover.sh tenants/<tenant>/<env>            (the environment)
#   ./hack/cutover.sh tenants/<tenant>/<env>/<service>   (one workload)
#
# It never pushes and never touches a cluster. Undo is `git revert` of the
# commit it makes.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${SRC_BRANCH:-main}"
p="${1:?usage: cutover.sh <platform/<tool>|tenants/<t>/<env>[/<svc>]>}"
p="${p%/}"

[ "$(git rev-parse --abbrev-ref HEAD)" != "$SRC" ] || {
  echo "You are on $SRC. Switch to the migration branch first." >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || {
  echo "Working tree is not clean; commit or stash first." >&2; exit 1; }

# An environment path is a directory whose subdirectories are its workloads.
# Checking the directory out would drag all of them across in one step, which is
# the opposite of what this script is for -- and each of them would arrive
# before the environment that owns their namespace. Take only the files sitting
# directly in it.
case "$p" in
  tenants/*/*|shared/*/*)
    if [ "$(awk -F/ '{print NF}' <<<"$p")" = 3 ]; then
      # By object type, not by the shape of the name: ls-tree prints a
      # directory without a trailing slash, so filtering on one silently
      # matched nothing and every workload came across anyway.
      mapfile -t files < <(git ls-tree "$SRC" "$p/" | awk '$2=="blob"{print $4}')
      [ "${#files[@]}" -gt 0 ] || { echo "nothing to bring from $SRC:$p" >&2; exit 1; }
      git checkout "$SRC" -- "${files[@]}"
    else
      git checkout "$SRC" -- "$p"
    fi ;;
  *) git checkout "$SRC" -- "$p" ;;
esac

python3 - "$p" "$SRC" <<'PY'
import subprocess, sys, yaml, os
p, src = sys.argv[1], sys.argv[2]
cl = yaml.safe_load(open("cluster.yaml")) or {}
full = yaml.safe_load(subprocess.run(["git","show",f"{src}:cluster.yaml"],
                                     capture_output=True, text=True, check=True).stdout) or {}
txt = open("cluster.yaml", encoding="utf-8").read()

def add_list(key, value):
    global txt
    if value in (cl.get(key) or []):
        return
    if f"\n{key}: []" in txt:
        txt = txt.replace(f"\n{key}: []", f"\n{key}:\n  - {value}")
    else:
        lines = txt.splitlines(keepends=True)
        for i, l in enumerate(lines):
            if l.startswith(f"{key}:"):
                j = i + 1
                while j < len(lines) and lines[j].startswith("  -"):
                    j += 1
                lines.insert(j, f"  - {value}\n"); break
        txt = "".join(lines)
    print(f"  cluster.yaml: {key} += {value}")

def add_map(key, k, v):
    global txt
    if k in (cl.get(key) or {}):
        return
    if f"\n{key}: {{}}" in txt:
        txt = txt.replace(f"\n{key}: {{}}", f"\n{key}:\n  {k}: {v}")
    else:
        txt = txt.replace(f"\n{key}:\n", f"\n{key}:\n  {k}: {v}\n", 1)
    print(f"  cluster.yaml: {key}.{k} = {v}")

parts = p.split("/")
if parts[0] == "platform":
    d = yaml.safe_load(open(f"{p}/component.yaml"))
    add_list("platformNamespaces", d["namespace"])
    ch = d.get("chart") or {}
    if ch.get("repo"):
        add_map("chartRepos", ch["repo"], (full.get("chartRepos") or {})[ch["repo"]])
elif len(parts) == 3:                     # an environment
    # Inserted as text, never re-serialised. Dumping the tenants list back
    # through the YAML writer loses every comment in it and reindents the rest,
    # which turns a one-line migration step into a diff nobody can read -- and
    # this tool runs against a live cluster, where an unreadable diff is the
    # thing you are trying not to have.
    t, e = parts[1], parts[2]
    ns = yaml.safe_load(open(f"{p}/env.yaml"))["namespace"]
    lines = txt.splitlines(keepends=True)
    start = next(i for i, l in enumerate(lines) if l.startswith("tenants:"))
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip() and not lines[i].startswith((" ", "\t", "#"))), len(lines))
    # Insert before any trailing blank lines, not after them: a block that grows
    # downward past its own whitespace reads as belonging to whatever is next.
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1
    block = lines[start:end]
    marker = f"  - name: {t}\n"
    if any(l == marker for l in block):
        for i in range(start, end):
            if lines[i].strip() == "environments:":
                j = i + 1
                while j < end and lines[j].startswith("      "):
                    j += 1
                if not any(lines[k].strip().startswith(f"{e}:") for k in range(i + 1, j)):
                    lines.insert(j, f"      {e}: {ns}\n")
                break
    else:
        if lines[start].rstrip() == "tenants: []":
            lines[start] = "tenants:\n"
        desc = next((x.get("description", "") for x in (full.get("tenants") or [])
                     if x.get("name") == t), "")
        ins = [f"  - name: {t}\n"]
        if desc:
            ins.append(f"    description: {desc}\n")
        ins += ["    environments:\n", f"      {e}: {ns}\n"]
        lines[end:end] = ins
    txt = "".join(lines)
    print(f"  cluster.yaml: tenants[{t}].environments.{e} = {ns}")
else:                                     # a workload
    d = yaml.safe_load(open(f"{p}/config.yaml"))
    ch = d.get("chart") or {}
    if ch.get("repo"):
        add_map("chartRepos", ch["repo"], (full.get("chartRepos") or {})[ch["repo"]])
open("cluster.yaml","w",encoding="utf-8").write(txt)
PY

echo
python3 hack/validate.py || { echo; echo "The gate refused this. Nothing has been committed." >&2; exit 1; }

git add "$p" cluster.yaml
git commit -q -m "cutover: $p

Brought from $SRC onto the migration branch, with the cluster.yaml lines it
needs. The old repository must already have released this folder: two
ApplicationSets generating one Application name rewrite each other's spec on
every reconcile, and neither says so."
echo
echo "committed. undo with: git revert HEAD"
