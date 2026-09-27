#!/usr/bin/env bash
# Render everything this cluster would apply, into out/.
#
# The gate checks what the files SAY. This checks what they PRODUCE: a Helm
# template error, a chart's own `fail`, a value the chart rejects. Those surface
# in Argo CD otherwise, after the commit is already on main, as a red
# Application whose message names a template line in someone else's chart.
#
# Local charts only by default. A remote chart needs the mirror to be reachable,
# which from a workstation it usually is not -- so that half is opt-in rather
# than a gate that fails for the wrong reason.
#
# CI is not a workstation. The runner sits inside the estate the mirror serves,
# so .gitlab-ci.yml sets WITH_REMOTE=1 and the remote charts are rendered there.
# Until it did, every remote chart on this cluster -- cert-manager, vault,
# vault-transit, external-secrets, redis-operator -- was rendered for the first
# time by Argo CD, on main, after the push.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT:-out}"
WITH_REMOTE="${WITH_REMOTE:-0}"
rm -rf "$OUT"; mkdir -p "$OUT"

# The machine repo has no cluster.yaml -- it is product. Falling back to the
# example lets the machine render itself in its own CI, which is the only way
# the template is checked before a cluster repo inherits it.
CLUSTER=cluster.yaml
[ -f "$CLUSTER" ] || CLUSTER=cluster.example.yaml
[ -f "$CLUSTER" ] || { echo "no cluster.yaml or cluster.example.yaml here" >&2; exit 1; }
echo "using $CLUSTER"

y() { python3 -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d=(d or {}).get(k)
print('' if d is None else d)" "$1" "$2"; }

echo "machine:"
helm template cluster-config charts/cluster-config -f "$CLUSTER" > "$OUT/cluster-config.yaml"
echo "  ok  charts/cluster-config"

echo "environments:"
for env_file in tenants/*/*/env.yaml shared/*/*/env.yaml; do
  [ -e "$env_file" ] || continue
  d=$(dirname "$env_file"); e=$(basename "$d"); o=$(basename "$(dirname "$d")")
  helm template "$e-baseline" charts/env-baseline \
    --namespace "$(y "$env_file" namespace)" \
    -f "$env_file" --set "sourcePath=$d" > "$OUT/env-$o-$e.yaml"
  echo "  ok  $env_file"
done

echo "platform:"
for comp in platform/*/component.yaml; do
  [ -e "$comp" ] || continue
  d=$(dirname "$comp"); n=$(basename "$d")
  local_chart=$(y "$comp" localChart); mdir=$(y "$comp" manifestsDir)
  if [ -n "$local_chart" ]; then
    helm template "$n" "$local_chart" -f "$CLUSTER" -f "$d/values.yaml" > "$OUT/platform-$n.yaml"
    echo "  ok  $n (localChart)"
  elif [ -n "$mdir" ]; then
    # Raw manifests are not rendered; they are parsed, which is the only thing
    # that can be wrong about them before they reach a cluster.
    python3 -c "
import sys,yaml,glob
for f in sorted(glob.glob('$mdir/**/*.yaml', recursive=True)):
    list(yaml.safe_load_all(open(f)))
" && echo "  ok  $n (manifestsDir, parsed)"
  elif [ "$WITH_REMOTE" = "1" ]; then
    repo=$(y "$CLUSTER" "chartRepos.$(y "$comp" chart.repo)")
    helm template "$n" "$(y "$comp" chart.name)" --repo "$repo" \
      --version "$(y "$comp" chart.version)" \
      --namespace "$(y "$comp" namespace)" -f "$d/values.yaml" > "$OUT/platform-$n.yaml"
    echo "  ok  $n (remote chart)"
  else
    echo "  --  $n (remote chart; set WITH_REMOTE=1 to fetch)"
  fi
done

# Everything above proves the chart RENDERS. This proves the result is an object
# the API server will hold, which is a different claim -- and the gap between the
# two is where a container that declares one env var twice gets through.
#
# `env`, `volumes`, `volumeMounts`, `containers` and `imagePullSecrets` are
# listType=map: Kubernetes keys them, and a typed patch cannot hold two entries
# under one key. It does not merge them and it does not take the last one, it
# refuses the object:
#
#   failed to create typed patch object (vault-transit/vault-transit;
#   apps/v1, Kind=StatefulSet): .spec.template.spec.containers[name="vault"].env:
#   duplicate entries for key [name="VAULT_ADDR"]
#
# Argo CD reports that as ComparisonError. The object itself reaches the cluster
# -- the API server treats a repeated env name as a warning, and vault-transit-0
# was created -- so the Application reads Healthy. What breaks is the diff: Argo
# builds a typed patch to compare desired against live, and that patch cannot
# exist. ComparisonError is neither Synced nor OutOfSync. It is an Application
# that has compared nothing, and selfHeal has nothing to act on.
#
# The message names a field of the rendered StatefulSet and no file. The two
# lines of values.yaml that produced it appear nowhere in it.
echo
echo "rendered objects:"
python3 - "$OUT" <<'PY'
import sys, glob, yaml

# field -> the key Kubernetes identifies an entry in it by.
KEYED = {"env": "name", "volumes": "name", "volumeMounts": "mountPath",
         "containers": "name", "initContainers": "name",
         "imagePullSecrets": "name"}
bad = []

def walk(node, where):
    if isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, "%s[%d]" % (where, i))
        return
    if not isinstance(node, dict):
        return
    for k, v in node.items():
        key = KEYED.get(k)
        # Only when every entry is a map carrying that key. A CRD is free to own
        # a `volumes` that means something else, and a gate guessing at one
        # refuses things it does not understand.
        if key and isinstance(v, list) and v and all(
                isinstance(i, dict) and key in i for i in v):
            seen = {}
            for i in v:
                seen[i[key]] = seen.get(i[key], 0) + 1
            for name, n in sorted(seen.items()):
                if n > 1:
                    bad.append("%s.%s: %d entries for %s=%s"
                               % (where, k, n, key, name))
        walk(v, "%s.%s" % (where, k))

n = 0
for f in sorted(glob.glob(sys.argv[1] + "/*.yaml")):
    for doc in yaml.safe_load_all(open(f)):
        if not isinstance(doc, dict) or "kind" not in doc:
            continue
        n += 1
        md = doc.get("metadata") or {}
        walk(doc, "%s %s/%s" % (doc["kind"], md.get("namespace", "-"),
                                md.get("name", "-")))
if bad:
    print("  a listType=map field carries the same key twice. The API server")
    print("  refuses the whole object and Argo CD stops at ComparisonError:")
    for b in bad:
        print("    " + b)
    sys.exit(1)
print("  ok  %d object(s), no duplicate entries" % n)
PY

echo
echo "wrote $(find "$OUT" -type f | wc -l) file(s) to $OUT/"
