#!/usr/bin/env bash
# Vault Day-1: the KV mount, the Kubernetes auth role External Secrets logs in
# with, and the paths the platform reads on its very first sync.
#
#   ./bootstrap/seed-vault-kv.sh                      seed what is missing
#   FORCE=1 ./bootstrap/seed-vault-kv.sh              rewrite it all, rotation
#   DOCKERCONFIG=/path/to/config.json ./bootstrap/seed-vault-kv.sh
#   VAULT_ROOT_TOKEN=... ./bootstrap/seed-vault-kv.sh
#
# WHY THIS IS A SCRIPT AND NOT A PAGE
#
# Written as a page, this is seven commands with <mount>, <role> and <user> to
# substitute, and what placeholders produce is this:
#
#   vault kv put kv/platform/apps username='<mirror-user>' password='<mirror-pass>'
#   ==== Secret Path ====  kv/data/platform/apps   version 1
#
# Success, a version number, and two credentials that authenticate to nothing.
# It is not a typo an operator catches, because the command reports exactly what
# a correct one reports. The same evening a literal <KEY-1> went into a live
# unseal call, where it failed loudly, and a literal /path/to/config.json, where
# it failed loudly -- this one did not.
#
# So: every name is read out of the repository, every value is typed into a
# prompt that does not echo, and a value shaped like a placeholder is refused.
#
# Idempotent. Run it on a cluster in any state; it reports what already exists
# and changes only what is missing or wrong.
#
# ROTATION
#
# "Missing or wrong" is not enough on its own. A credential that is perfectly
# valid and belongs to an account you are retiring reads as OK here. A script
# that can seed a cluster and cannot change it leaves only one way round, which
# is somebody editing Vault by hand -- the thing this script exists to stop.
#
#   FORCE=1              rewrite every path, whatever is in it
#   DOCKERCONFIG=<file>  naming a file IS the instruction to write it
#
# It still refuses placeholders in both modes. Rotating to a placeholder is
# rotating to nothing.
#
# ASCII only. RTL text has corrupted shell scripts in this project before.
set -euo pipefail
cd "$(dirname "$0")/.."

FORCE="${FORCE:-0}"
KEYDIR="${KEYDIR:-/root/vault-keys}"
VAULT_NS="${VAULT_NS:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
# Named only so the refusal below can say where the other root token belongs.
TRANSIT_NS_HINT="${TRANSIT_NS_HINT:-vault-transit}"
STORE=platform/eso-config/manifests/00-cluster-secret-store.yaml

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found"
command -v python3 >/dev/null || die "python3 not found"
[ -f "$STORE" ] || die "$STORE is not here. This script belongs to a cluster
  repository, next to the manifests it reads."

# The names live in the ClusterSecretStore, because that is the object that has
# to agree with Vault. Restating them here is how a page comes to describe a
# mount nothing uses. shlex.quote, then eval: the input is a file from this
# repository, and the alternative is six more subprocesses.
eval "$(python3 - "$STORE" <<'PY'
import yaml, sys, shlex
d = [x for x in yaml.safe_load_all(open(sys.argv[1]))
     if x and x.get("kind") == "ClusterSecretStore"][0]["spec"]["provider"]["vault"]
k = d["auth"]["kubernetes"]
for name, val in (("MOUNT", d["path"]), ("AUTH_MOUNT", k["mountPath"]),
                  ("ROLE", k["role"]), ("SA_NAME", k["serviceAccountRef"]["name"]),
                  ("SA_NS", k["serviceAccountRef"]["namespace"])):
    print("%s=%s" % (name, shlex.quote(str(val))))
PY
)"
echo "mount=$MOUNT  auth=$AUTH_MOUNT  role=$ROLE  sa=$SA_NS/$SA_NAME"

# The namespaces that already hold an imperative copy of the pull secret, from
# cluster.yaml rather than written out again -- the same list
# bootstrap/seed-regcred.sh writes into.
PLATFORM_NAMESPACES="${PLATFORM_NAMESPACES:-$(python3 -c "
import yaml
print(' '.join(yaml.safe_load(open('cluster.yaml')).get('platformNamespaces') or []))")}"

# A value that looks like something a person was supposed to replace. Empty is
# the same class: `vault kv put k=` writes an empty string and reports success.
is_placeholder() {
  case "$1" in
    "" ) return 0 ;;
    "<"*">" ) return 0 ;;
    *"<user"*|*"<pass"*|*"CHANGEME"*|*"changeme"*|*"REPLACE"*|*"xxxx"* ) return 0 ;;
  esac
  return 1
}

# Read without echoing, and refuse to accept a placeholder rather than warn
# about one. Three retries, then stop -- a loop nobody can leave is its own bug.
ask_secret() {   # $1 = prompt ; sets REPLY_VALUE
  local prompt="$1" i val
  for i in 1 2 3; do
    printf '  %s: ' "$prompt" >&2
    read -r -s val < /dev/tty; echo >&2
    if is_placeholder "$val"; then
      echo "    refused: that is empty or looks like a placeholder" >&2
      continue
    fi
    REPLY_VALUE="$val"
    return 0
  done
  die "no usable value for $prompt after three tries. Nothing has been changed."
}

# Three ways to get the root token, in order, and the third is why this is not
# just a file read.
#
# vault-day0.sh writes $KEYDIR/main-init.json and its closing message says to
# copy it off the node and then shred what is left. An operator who did exactly
# that -- correctly -- cannot run this script, and the error told them to put
# back a file the other page told them to destroy. Circular, and the advice went
# stale the moment this script became a second consumer of that token.
#
# So: the environment if it is set, the file if it is still there, and otherwise
# ask. The prompt does not echo and the value never reaches argv or shell
# history, which typing VAULT_ROOT_TOKEN=... on a command line does.
ROOT="${VAULT_ROOT_TOKEN:-}"
if [ -z "$ROOT" ] && [ -s "$KEYDIR/main-init.json" ]; then
  ROOT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["root_token"])' \
           "$KEYDIR/main-init.json")
  echo "root token: read from $KEYDIR/main-init.json"
fi
if [ -z "$ROOT" ]; then
  echo "  No root token here. $KEYDIR/main-init.json is absent, which is the" >&2
  echo "  correct state after bootstrap/vault-day0.sh -- you copied it off the" >&2
  echo "  node and shredded what was left." >&2
  echo "  Paste the root_token from your copy. It is not echoed and it is not" >&2
  echo "  stored: this script holds it for its own run and nothing else." >&2
  ask_secret "root_token"
  ROOT="$REPLY_VALUE"
  unset REPLY_VALUE
fi

# Same shape as vx() in vault-day0.sh, and the same caveat: the token is in the
# argv of `env` inside the Vault pod. That pod is Vault itself, which already
# holds everything the token unlocks.
v() { kubectl -n "$VAULT_NS" exec -i "$VAULT_POD" -- \
        env VAULT_TOKEN="$ROOT" VAULT_ADDR=https://127.0.0.1:8200 \
        VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt "$@"; }

kubectl -n "$VAULT_NS" get pod "$VAULT_POD" >/dev/null \
  || die "$VAULT_NS/$VAULT_POD does not exist. Run bootstrap/vault-day0.sh first."

# Ask Vault whether the token is any good, before doing anything with it.
#
# Without this the first real call returns `permission denied / invalid token`,
# the script carries on to the next one, and that returns the same -- so a
# mistyped or wrong token produces a page of 403s and a Python traceback from a
# probe parsing an empty reply. None of it says "the token is wrong".
#
# The commonest cause is not a typo. There are TWO root tokens on a cluster
# built by vault-day0.sh, in two files, and they are not interchangeable:
# transit-init.json holds the transit Vault's, main-init.json holds this one's.
# Pasting the transit token here fails exactly like a wrong one.
tok_check=$(v vault token lookup </dev/null 2>&1 || true)
# A sealed Vault refuses every token, including a perfect one. Saying "rejected
# that token" there sends the operator to look at their key file, which is the
# one thing that is not wrong.
if grep -q 'Vault is sealed' <<<"$tok_check"; then
  die "$VAULT_NS/$VAULT_POD is SEALED. Nothing to do with the token, which was
  not even read.

  This Vault unseals itself from the transit Vault at start. If it is sealed and
  staying sealed, its master key is encrypted with a transit key that no longer
  answers -- usually because the transit Vault was rebuilt after this one was
  initialised. docs/30-incident.md section 6 has the way out, and the short
  version is that this Vault has to be rebuilt against the transit that exists
  now. Run bootstrap/vault-day0.sh first; it says the same thing with more
  detail and refuses to call a sealed Vault up."
fi
if ! grep -q 'policies' <<<"$tok_check"; then
  die "$VAULT_NS/$VAULT_POD rejected that token. Nothing has been changed.

  Two root tokens exist on a cluster built by bootstrap/vault-day0.sh, and they
  are not interchangeable:

    main-init.json     root_token  -> this Vault, which is what is wanted here
    transit-init.json  root_token  -> the transit Vault in $TRANSIT_NS_HINT

  Check which file you copied from, and that the value is the root_token field
  and not one of the recovery keys beside it. What Vault said:
$(sed 's/^/    /' <<<"$tok_check")"
fi
unset tok_check
echo "root token: accepted by $VAULT_NS/$VAULT_POD"

# --- the KV mount ----------------------------------------------------------- #
log "KV v2 at $MOUNT/"
if v sh -c "vault secrets list -format=json" </dev/null 2>&1 \
     | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)          # not JSON is not a mount; the token check above owns why
sys.exit(0 if '$MOUNT/' in d else 1)"; then
  echo "  already enabled"
else
  v vault secrets enable -path="$MOUNT" -version=2 kv </dev/null
fi

# --- Kubernetes auth -------------------------------------------------------- #
log "Kubernetes auth at $AUTH_MOUNT/, role $ROLE"
if v sh -c "vault auth list -format=json" </dev/null 2>&1 \
     | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if '$AUTH_MOUNT/' in d else 1)"; then
  echo "  auth method already enabled"
else
  v vault auth enable -path="$AUTH_MOUNT" kubernetes </dev/null
fi
# Rewritten every run on purpose: it is one field and it is the field that
# breaks when an API server address changes.
v vault write "auth/$AUTH_MOUNT/config" \
    kubernetes_host=https://kubernetes.default.svc </dev/null >/dev/null
echo "  auth/$AUTH_MOUNT/config written"

# Read only. External Secrets never writes, and a store that can write is a
# store that can be used to change what every workload reads.
v sh -s <<POLICY >/dev/null
vault policy write $ROLE - <<'EOP'
path "$MOUNT/data/*"     { capabilities = ["read"] }
path "$MOUNT/metadata/*" { capabilities = ["read", "list"] }
EOP
POLICY
echo "  policy $ROLE written"

# bound_service_account_names and _namespaces are the whole security boundary.
# A role bound to * is a role any pod in the cluster can assume.
v vault write "auth/$AUTH_MOUNT/role/$ROLE" \
    bound_service_account_names="$SA_NAME" \
    bound_service_account_namespaces="$SA_NS" \
    policies="$ROLE" ttl=1h </dev/null >/dev/null
echo "  role $ROLE bound to $SA_NS/$SA_NAME"

# --- what the platform reads on its first sync ------------------------------ #
# Derived, not listed. Two sources, and both are read rather than restated:
#   platform/eso-config/manifests/  -> the image pull secret's remoteRef.key,
#                                      and the name of the Secret it produces
#   cluster.yaml:chartRepos         -> one Helm credential per DISTINCT url,
#                                      keyed by the first name for that url in
#                                      sorted order, which is what
#                                      charts/platform-config does.
eval "$(python3 - <<'PY'
import yaml, glob, shlex, sys
for f in sorted(glob.glob("platform/eso-config/manifests/*.yaml")):
    for d in yaml.safe_load_all(open(f)):
        if not d or d.get("kind") != "ClusterExternalSecret":
            continue
        spec = d["spec"]["externalSecretSpec"]
        for e in (spec.get("data") or []):
            if e["remoteRef"].get("property") == "dockerconfigjson":
                print("REGISTRY_KEY=%s" % shlex.quote(e["remoteRef"]["key"]))
                print("REGCRED_NAME=%s" % shlex.quote(spec["target"]["name"]))
                sys.exit(0)
PY
)"
[ -n "${REGISTRY_KEY:-}" ] || die "no ClusterExternalSecret in
  platform/eso-config/manifests/ asks for a dockerconfigjson property, so this
  script cannot tell which path holds the image pull secret."

# key and url together, one line each. The url is what the operator needs to
# see: this credential is for a Helm repository, and the other one on this page
# is for an image registry, and nothing in the path name says which is which.
HELM_KEYS=$(python3 - <<'PY'
import yaml
c = yaml.safe_load(open("cluster.yaml"))
prefix = "platform"
seen = {}
for k in sorted((c.get("chartRepos") or {})):
    seen.setdefault(c["chartRepos"][k], k)
for url, k in sorted(seen.items(), key=lambda kv: kv[1]):
    print("%s/%s %s" % (prefix, k, url))
PY
)

# The per-tenant Redis credential, on the same terms: derived, and only when
# something reads it. charts/platform-config emits one ClusterExternalSecret per
# tenant environment reading <tenant>/<env>/redis, and only when
# secrets.redis.enabled is true -- so this asks that file rather than assuming.
#
# Nothing points at these Redis instances yet: every application here has its
# address compiled into its image. The credential still has to exist, because a
# RedisReplication whose Secret never appears stays Progressing and says
# nothing about why.
REDIS_KEYS=$(python3 - <<'PY'
import yaml, os
def load(p):
    return yaml.safe_load(open(p)) if os.path.exists(p) else {}
base = load("platform/platform-config/chart/values.yaml")
over = load("platform/platform-config/values.yaml")
def get(d, *path):
    for k in path:
        d = (d or {}).get(k)
    return d
enabled = get(over, "secrets", "redis", "enabled")
if enabled is None:
    enabled = get(base, "secrets", "redis", "enabled")
field = get(over, "secrets", "redis", "secretKey") or get(base, "secrets", "redis", "secretKey")
if enabled and field:
    c = load("cluster.yaml")
    for t in (c.get("tenants") or []):
        for env in sorted((t.get("environments") or {})):
            print("%s/%s/redis %s" % (t["name"], env, field))
PY
)

# Does the path already hold usable values, or a placeholder somebody pasted?
path_state() {   # $1 = path, rest = required fields ; prints OK / MISSING / BAD:<field>
  local p="$1"; shift
  local json
  json=$(v vault kv get -format=json "$MOUNT/$p" </dev/null 2>&1 || true)
  python3 - "$json" "$@" <<'PY'
import json, sys
raw, fields = sys.argv[1], sys.argv[2:]
try:
    data = json.loads(raw)["data"]["data"]
except Exception:
    print("MISSING"); sys.exit(0)
bad = [f for f in fields if f not in data]
if bad:
    print("MISSING"); sys.exit(0)
marks = ("<user", "<pass", "<nexus", "CHANGEME", "changeme", "REPLACE", "xxxx")
for f in fields:
    val = str(data[f])
    if not val or (val.startswith("<") and val.endswith(">")) \
       or any(m in val for m in marks):
        print("BAD:" + f); sys.exit(0)
print("OK")
PY
}

log "$MOUNT/$REGISTRY_KEY - the image pull secret every tenant namespace waits on"
state=$(path_state "$REGISTRY_KEY" dockerconfigjson)
# A named file and FORCE are both explicit instructions. Neither can be reached
# by accident, and both mean the operator knows better than the stored value.
[ "$FORCE" = "1" ] && state="ROTATE"
[ -n "${DOCKERCONFIG:-}" ] && state="ROTATE"
if [ "$state" = "OK" ]; then
  echo "  already seeded"
else
  case "$state" in
    MISSING ) ;;
    ROTATE  ) echo "  rewriting on request" ;;
    *       ) echo "  ${state#BAD:} is a placeholder - rewriting" ;;
  esac
  # WHAT THIS PAYLOAD IS. A prompt that asks for a path and says nothing else is
  # a prompt an operator stops at.
  #
  # It is the docker config.json that lets a node pull from the private mirror:
  # the exact bytes inside a kubernetes.io/dockerconfigjson Secret. On any
  # cluster that got past bootstrap/seed-regcred.sh it already exists, in the
  # platform namespaces, because those copies are imperative by design -- ESO
  # cannot create them, since ESO needs the mirror to start.
  #
  # What Vault is for is the OTHER half: ESO distributes this to every namespace
  # carrying gitops.internal/secrets-distribute, which charts/env-baseline
  # stamps on tenant namespaces and nothing stamps on platform ones. So the
  # source is already on the cluster, and this reads it from there rather than
  # asking a human to find it again.
  #
  # Order: an explicit file, then the cluster, then a prompt.
  cfg="${DOCKERCONFIG:-}"
  tmp_cfg=""
  if [ -z "$cfg" ]; then
    for ns in $PLATFORM_NAMESPACES; do
      payload=$(kubectl -n "$ns" get secret "$REGCRED_NAME" \
                  -o jsonpath='{.data.\.dockerconfigjson}' --ignore-not-found || true)
      [ -n "$payload" ] || continue
      tmp_cfg=$(mktemp "$KEYDIR/.dockercfg.XXXXXX"); chmod 600 "$tmp_cfg"
      printf '%s' "$payload" | base64 -d > "$tmp_cfg"
      cfg="$tmp_cfg"
      echo "  taking it from the $REGCRED_NAME Secret already in $ns"
      unset payload
      break
    done
  fi
  if [ -z "$cfg" ]; then
    echo "  No $REGCRED_NAME Secret exists in any platform namespace, so there is" >&2
    echo "  nothing on this cluster to copy. What is wanted is the docker" >&2
    echo "  config.json for the private mirror - the file 'docker login' writes" >&2
    echo "  to ~/.docker/config.json, or the one you passed to" >&2
    echo "  bootstrap/seed-regcred.sh." >&2
    printf '  path to it: ' >&2
    read -r cfg < /dev/tty
  fi
  [ -s "$cfg" ] || die "$cfg is not a file. Nothing has been changed."
  # The same refusal as bootstrap/seed-regcred.sh, for the same reason: a
  # payload that is JSON and holds placeholders looks right in every listing
  # and 401s on the first pull.
  python3 - "$cfg" <<'PY' || { rm -f "$tmp_cfg"; die "refusing to write a placeholder credential"; }
import json, sys
d = json.load(open(sys.argv[1]))
auths = d.get("auths") or {}
if not auths:
    print("ERROR: the payload has no auths entry", file=sys.stderr); sys.exit(1)
bad = [h for h, a in auths.items()
       if any(s in json.dumps(a) for s in ("<user>", "<pass>", "<username>", "<password>"))]
if bad:
    print("ERROR: placeholder credentials for: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
print("  registries in the payload: " + ", ".join(sorted(auths)))
PY
  python3 -c 'import json,sys;print(json.dumps({"dockerconfigjson":open(sys.argv[1]).read()}))' "$cfg" \
    | v vault kv put "$MOUNT/$REGISTRY_KEY" - >/dev/null
  [ -z "$tmp_cfg" ] || { shred -u "$tmp_cfg" || rm -f "$tmp_cfg"; }
  unset cfg tmp_cfg
  echo "  written"
fi

while read -r hk url; do
  [ -n "$hk" ] || continue
  log "$MOUNT/$hk - Helm repository credentials"
  state=$(path_state "$hk" username password)
  [ "$FORCE" = "1" ] && state="ROTATE"
  if [ "$state" = "OK" ]; then
    echo "  already seeded - FORCE=1 to replace it"
    continue
  fi
  case "$state" in
    MISSING ) ;;
    ROTATE  ) echo "  rewriting on request" ;;
    *       ) echo "  ${state#BAD:} is a placeholder - rewriting" ;;
  esac
  # Say what the credential is for. `username for platform/apps` names a Vault
  # path, which tells an operator nothing about which account to type -- and
  # this platform has two, one for charts and one for images.
  echo "  Argo CD pulls Helm charts from:"
  echo "    $url"
  echo "  This is the account that reads THAT repository. It is not the image"
  echo "  registry credential - that one is $MOUNT/$REGISTRY_KEY, already done."
  ask_secret "username"; u="$REPLY_VALUE"
  ask_secret "password"; p="$REPLY_VALUE"
  # Through stdin, not argv: `vault kv put path -` takes a JSON object, so
  # neither value appears in the process list inside the pod.
  python3 -c 'import json,sys;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$u" "$p" \
    | v vault kv put "$MOUNT/$hk" - >/dev/null
  unset u p REPLY_VALUE
  echo "  written"
# Fed by a here-string, not a pipe: a `while read` on the right of a pipe runs
# in a subshell, and the `v` calls inside it would be reading that pipe. Same
# trap as the unseal loop in vault-day0.sh, one file over.
done <<< "$HELM_KEYS"

while read -r rk field; do
  [ -n "$rk" ] || continue
  log "$MOUNT/$rk - the Redis password for that environment"
  state=$(path_state "$rk" "$field")
  [ "$FORCE" = "1" ] && state="ROTATE"
  if [ "$state" = "OK" ]; then
    echo "  already seeded - FORCE=1 to replace it"
    continue
  fi
  case "$state" in
    MISSING ) ;;
    ROTATE  ) echo "  rewriting on request" ;;
    *       ) echo "  ${state#BAD:} is a placeholder - rewriting" ;;
  esac
  echo "  Nothing connects to this Redis yet -- every application in this estate"
  echo "  has its address compiled in. The password still has to exist: the"
  echo "  RedisReplication waits for the Secret and reports nothing while it is"
  echo "  missing. Hand this value to the developers when they wire it up."
  ask_secret "password for $rk"; rp="$REPLY_VALUE"
  python3 -c 'import json,sys;print(json.dumps({sys.argv[1]:sys.argv[2]}))' "$field" "$rp" \
    | v vault kv put "$MOUNT/$rk" - >/dev/null
  unset rp REPLY_VALUE
  echo "  written"
done <<< "$REDIS_KEYS"

cat <<EOF

=== Vault is configured. Prove it rather than assuming it.

A ClusterSecretStore reports Valid when Vault answered, not when a secret was
read. The evidence is a Secret appearing in a namespace nobody created it in:

  kubectl get clustersecretstore -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[0].reason
  kubectl get secret -A --field-selector metadata.name=regcred

If the store is Valid and no Secret appears, the selector matched no namespace --
a ClusterExternalSecret that matches nothing reports Ready.

Only now is $KEYDIR safe to shred.
EOF
