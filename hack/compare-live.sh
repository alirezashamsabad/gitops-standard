#!/usr/bin/env bash
# Compare what this repository DECLARES against what is running, before cutting
# a thing over to it.
#
# Not a full render: the application chart lives in a mirror a workstation
# usually cannot reach, and a comparison that needs the mirror is one nobody
# runs. This compares the fields that decide whether an adoption is silent --
# image, replicas, ports, route -- taken from config.yaml and the merged value
# layers, against the live objects.
#
# Everything it cannot compare, it says so rather than passing quietly.
#
#   ./hack/compare-live.sh                      every workload
#   ./hack/compare-live.sh <tenant> <env> <service>   one
set -uo pipefail
cd "$(dirname "$0")/.."

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is not on PATH. This compares against a live cluster; there is" >&2
  echo "nothing useful it can do without one." >&2; exit 2; }

# The cluster answers before anything is compared.
#
# Ending every kubectl below in `|| true` leaves an empty string that reads as
# "not deployed": point this at a cluster it cannot reach and every workload
# reports NOT RUNNING, nothing differs, and the tool whose only job is to say
# whether an adoption is safe exits 0 having seen nothing. drill.sh guards
# against the same pair.
#
# /version is readable by any authenticated user, so this asks the one question
# that separates "the cluster has no such object" from "the cluster said
# nothing" -- and asks it once, before the first workload, not sixty times.
#
# `</dev/null` and a bounded request, because there is a third outcome besides
# yes and no: kubectl asks `Please enter Username:` for a kubeconfig whose user
# carries no credentials, and waits on stdin for as long as anyone lets it. A
# gate that stops to ask a human has not passed and has not failed. Same reason
# the request is bounded -- a cluster that accepts the connection and then says
# nothing would hang here just as long.
kubectl get --raw /version --request-timeout=30s </dev/null >/dev/null || {
  echo >&2
  echo "The cluster did not answer. The message above says why." >&2
  echo "Nothing was compared. An empty answer from a cluster that is not there" >&2
  echo "looks exactly like a workload that is not deployed, and only one of" >&2
  echo "those two means an adoption is safe." >&2; exit 2; }

# Reads one field, or fails. --ignore-not-found turns an absent object into an
# empty answer with exit 0, which leaves a non-zero exit meaning one thing only:
# the request itself failed. Never `|| true` on a caller of this.
live() { kubectl "$@" --ignore-not-found --request-timeout=30s </dev/null; }

unreachable() {
  echo >&2
  echo "  kubectl failed part-way through. The message above says why." >&2
  echo "  Stopping here: what is printed above was compared, the rest was not," >&2
  echo "  and a partial comparison must not be reported as agreement." >&2
  exit 2
}

# One reader for every declared value, over the layers the machine declares.
# Three fields were read from the workload's own file while the header claimed
# the layers -- a value set in a shared default compared as absent and reported a
# difference that is not one, in the tool whose whole job is to say whether an
# adoption is safe.
declared() {  # declared <workload-dir> <dotted.path>
  python3 - "$1" "$2" <<'PY'
import sys, os, yaml
d, path = sys.argv[1], sys.argv[2]
parts = d.split("/")
scope, owner, env = parts[0], parts[1], parts[2]

def merge(a, b):
    o = dict(a)
    for k, v in (b or {}).items():
        o[k] = merge(o[k], v) if isinstance(o.get(k), dict) and isinstance(v, dict) else v
    return o

# From the machine, not written out again here: a fifth layer added there has to
# reach this tool, and a copy would agree with it right up until it did not.
cc = yaml.safe_load(open("charts/cluster-config/values.yaml")) or {}
files = []
if scope == "tenants":
    for layer in cc.get("tenantValueLayers") or []:
        files.append(layer.replace("{t}", owner).replace("{e}", env))
files.append(f"{d}/values.yaml")

v = {}
for f in files:
    if os.path.exists(f):
        v = merge(v, yaml.safe_load(open(f)) or {})

cur = v
for key in path.split("."):
    if key.endswith("]"):
        key, idx = key[:-1].split("[")
        cur = (cur or {}).get(key) or []
        cur = cur[int(idx)] if len(cur) > int(idx) else {}
    else:
        cur = (cur or {}).get(key)
    if cur is None:
        print("")
        sys.exit()
print(cur)
PY
}

T="${1:-*}"; E="${2:-*}"; S="${3:-*}"
diffs=0; compared=0; absent=0

row() { printf '    %-22s repo=%-34s live=%s\n' "$1" "$2" "$3"; }
cmp_() {
  if [ "$2" = "$3" ]; then row "$1" "$2" "$3"; else
    printf '    %-22s repo=%-34s live=%s   <-- DIFFERS\n' "$1" "$2" "$3"; diffs=$((diffs+1)); fi
}

for cfg in tenants/$T/$E/$S/config.yaml; do
  [ -e "$cfg" ] || continue
  d=$(dirname "$cfg"); svc=$(basename "$d"); env=$(basename "$(dirname "$d")")
  ten=$(basename "$(dirname "$(dirname "$d")")")
  ns=$(python3 -c "import yaml;print(yaml.safe_load(open('$cfg'))['namespace'])")
  echo "$ten/$env/$svc  (namespace $ns)"

  read -r want_img want_tag < <(python3 -c "
import yaml
d=yaml.safe_load(open('$cfg'))['image']
print(d['repository'], d['tag'])")
  # Assigned first, compared after. A `$(live ...)` written inside the argument
  # list of cmp_ runs in a subshell, where a failure exits that subshell and the
  # comparison carries on with an empty string -- the same lie in a new place.
  live_img=$(live -n "$ns" get deploy "$svc" -o jsonpath='{.spec.template.spec.containers[0].image}') || unreachable
  if [ -z "$live_img" ]; then
    echo "    NOT RUNNING — nothing to adopt; this will be a create, not an adoption"
    absent=$((absent+1)); echo; continue
  fi
  compared=$((compared+1))
  cmp_ image "$want_img:$want_tag" "$live_img"

  want_rep=$(declared "$d" deployment.replicas)
  live_rep=$(live -n "$ns" get deploy "$svc" -o jsonpath='{.spec.replicas}') || unreachable
  cmp_ replicas "$want_rep" "$live_rep"

  want_port=$(declared "$d" "deployment.ports[0].containerPort")
  live_port=$(live -n "$ns" get deploy "$svc" -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}') || unreachable
  cmp_ containerPort "$want_port" "$live_port"

  live_tport=$(live -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].targetPort}') || unreachable
  cmp_ svc.targetPort "$(declared "$d" "service.ports[0].targetPort")" "$live_tport"

  want_host=$(declared "$d" "httpRoute.hostnames[0]")
  if [ -n "$want_host" ]; then
    live_host=$(live -n "$ns" get httproute "$svc" -o jsonpath='{.spec.hostnames[0]}') || unreachable
    cmp_ route.hostname "$want_host" "$live_host"
  fi

  # Named, not compared. Probes and env come from four merged layers and a
  # chart's own defaults; claiming to have checked them here would be worse
  # than saying they are unchecked.
  echo "    not compared: probes, env, resources, labels — read the render for those"
  echo
done

# Both numbers, always. "0 field(s) differ" over an empty cluster reads as
# permission to cut over; "0 compared" is the same sentence with the missing
# half put back.
echo "----- $compared compared, $absent not running, $diffs field(s) differ -----"
[ "$diffs" -eq 0 ]
