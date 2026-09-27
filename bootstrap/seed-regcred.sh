#!/usr/bin/env bash
# Put the image-pull secret into the platform namespaces, by hand, once.
#
# THE LOOP THIS BREAKS
#   Every platform tool sets imagePullSecrets: [regcred] and pulls from the
#   private mirror. `regcred` is produced by External Secrets, reading it out
#   of Vault. So Vault, vault-transit and External Secrets cannot start until
#   regcred exists by some other means -- and nothing in git can create it,
#   because the thing that would is the thing that cannot start.
#
#   ESO takes over afterwards, but only for namespaces carrying
#   gitops.internal/secrets-distribute, which charts/env-baseline stamps on
#   tenant namespaces and nothing stamps on platform ones. These copies stay
#   imperative on purpose.
#
# Not a workaround and not a one-off. It runs on every new cluster and after
# any recovery that loses the platform namespaces, which is why it is a
# versioned idempotent script and not a paragraph somebody retypes.
#
#   ./bootstrap/seed-regcred.sh                      copy from a namespace
#   SOURCE_NS=<ns> ./bootstrap/seed-regcred.sh
#   DOCKERCONFIG=/path/to/config.json ./bootstrap/seed-regcred.sh
#
# ASCII only. RTL text has corrupted shell scripts in this project before.
set -euo pipefail
cd "$(dirname "$0")/.."

# From cluster.yaml, not written out again here. The previous version of this
# script carried three namespace names in a default, and the cluster it was
# copied to had five.
PLATFORM_NAMESPACES="${PLATFORM_NAMESPACES:-$(python3 -c "
import yaml
print(' '.join(yaml.safe_load(open('cluster.yaml')).get('platformNamespaces') or []))")}"

SOURCE_NS="${SOURCE_NS:-}"
SECRET_NAME="${SECRET_NAME:-regcred}"
# The name to read may differ from the name to write: the cluster this was
# first used on had a working pull secret under another name, and reading it
# with SECRET_NAME also renamed what got written.
SOURCE_SECRET="${SOURCE_SECRET:-$SECRET_NAME}"
DOCKERCONFIG="${DOCKERCONFIG:-}"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
kubectl version -o json >/dev/null || die "cannot reach the cluster"
[ -n "$PLATFORM_NAMESPACES" ] || die "cluster.yaml names no platformNamespaces"

# --- resolve the payload once ---------------------------------------------- #
if [ -n "$DOCKERCONFIG" ]; then
  [ -f "$DOCKERCONFIG" ] || die "DOCKERCONFIG file not found: $DOCKERCONFIG"
  log "==> source: file $DOCKERCONFIG"
  PAYLOAD_FILE="$DOCKERCONFIG"; CLEANUP=false
elif [ -n "$SOURCE_NS" ]; then
  log "==> source: secret $SOURCE_SECRET in namespace $SOURCE_NS"
  kubectl -n "$SOURCE_NS" get secret "$SOURCE_SECRET" >/dev/null \
    || die "secret $SOURCE_SECRET not found in $SOURCE_NS"
  PAYLOAD_FILE="$(mktemp)"; CLEANUP=true
  # The decoded payload only. Never pipe a live Secret's YAML through sed and
  # re-apply it: that carries uid, resourceVersion and ownerReferences into a
  # namespace where they are wrong.
  kubectl -n "$SOURCE_NS" get secret "$SOURCE_SECRET" \
    -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$PAYLOAD_FILE"
  [ -s "$PAYLOAD_FILE" ] || die "decoded .dockerconfigjson is empty"
else
  die "give it a source: DOCKERCONFIG=/path/to/config.json, or SOURCE_NS=<ns>
  holding a working pull secret (SOURCE_SECRET=<name> if it is not called
  $SECRET_NAME). There is no default -- a default here is a customer's
  namespace name living in the machine.

  To find one:
    kubectl get secret -A --field-selector type=kubernetes.io/dockerconfigjson"
fi
trap '[ "${CLEANUP:-false}" = true ] && rm -f "$PAYLOAD_FILE"' EXIT

# A dockerconfigjson that is not JSON produces a Secret that exists, mounts,
# and fails every pull with a message about the registry.
python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$PAYLOAD_FILE" \
  || die "payload is not valid JSON"

# And one that is JSON but holds placeholders is worse: it is a Secret that
# looks right in every listing and 401s on first pull.
python3 - "$PAYLOAD_FILE" <<'PY' || die "refusing to write a placeholder credential"
import json, sys
d = json.load(open(sys.argv[1]))
bad = [h for h, a in (d.get("auths") or {}).items()
       if any(s in json.dumps(a) for s in ("<user>", "<pass>", "<username>", "<password>"))]
if bad:
    print("ERROR: placeholder credentials for: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
if not (d.get("auths") or {}):
    print("ERROR: the payload has no auths entry", file=sys.stderr)
    sys.exit(1)
PY

for ns in $PLATFORM_NAMESPACES; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$ns" create secret generic "$SECRET_NAME" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$PAYLOAD_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "    ok  $ns/$SECRET_NAME"
done

log ""
log "==> verify before syncing anything:"
log "    for ns in $PLATFORM_NAMESPACES; do kubectl -n \$ns get secret $SECRET_NAME; done"
