#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Unseal the transit Vault after a restart. That is the whole of what it does.
#
#   ./bootstrap/unseal-transit.sh
#
# WHY THIS EXISTS SEPARATELY FROM vault-day0.sh
#
# The structure had a day-0 ceremony and no day-N one. The transit Vault is
# sealed with Shamir and its storage is a file on a PVC, so it comes back SEALED
# from every restart there is: a node reboot, a drain, an eviction, an OOM kill,
# a Longhorn volume detaching and reattaching. Nothing about that is a fault --
# it is what a Shamir seal means -- and the structure had no answer to it except
# a 30KB script with a --wipe flag.
#
# The cost of having no answer is measured in hours of silence. The transit pod
# restarts, comes back sealed, and the only thing that says so is a readiness
# probe returning 503 -- which nothing reads unless something is scraping it. For
# every minute of that, the main Vault is one pod restart away from being stuck:
# it is running and unsealed, but a Vault only unseals at startup, and the thing
# it asks is sealed.
#
# WHAT THIS REFUSES TO DO
#
# Initialise anything. Wipe anything. Issue a token. Touch the main Vault.
# If transit reports `Initialized false`, this stops -- an uninitialised transit
# means its storage is gone, which is a disaster with a different procedure, and
# this script must never be the thing that walks into it.
#
# WHAT IT DOES AFTER UNSEALING, WHICH IS THE POINT
#
# An unsealed transit is worth nothing on its own. So it proves the autounseal
# token still encrypts, and then reports the seal state of every main Vault pod
# -- because a pod that started while transit was sealed stays sealed until it
# is restarted, and nothing else in this cluster will tell you that.
#
# It is safe to run when there is nothing to do.
#
# ASCII only.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

KEYDIR="${KEYDIR:-/root/vault-keys}"
TRANSIT_NS=vault-transit
TRANSIT_POD=vault-transit-0
VAULT_NS=vault
KEY_NAME=autounseal-nonprod          # must equal platform/vault/values.yaml seal stanza
TOKEN_SECRET=vault-transit-token     # must equal extraSecretEnvironmentVars

log()  { printf '\n=== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl not found"
command -v python3 >/dev/null || die "python3 not found"
kubectl version -o json >/dev/null 2>&1 || die "cannot reach the cluster"

vx()  { kubectl -n "$1" exec -i "$2" -- env VAULT_ADDR=https://127.0.0.1:8200 \
          VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt VAULT_TOKEN="${3:-}" "${@:4}"; }

# Captured, never piped. `vault status` says the state in its exit code -- 0
# unsealed, 2 sealed, 1 unreachable -- and under pipefail a sealed Vault turns
# `vault status | grep` into a failure whatever the output said. vault-day0.sh
# had that shape in three places and read sealed-but-initialised as
# uninitialised, one step away from truncating the key file.
vstatus() { vx "$1" "$2" "" vault status </dev/null 2>&1 || true; }

# Running, then an API that answers. NOT `wait --for=condition=Ready`: a sealed
# Vault is never Ready by design here, so that wait burns its whole timeout on
# the normal path and then continues anyway -- five silent minutes that look
# exactly like a hang and end in a line saying it did not matter.
wait_api() {
  local ns="$1" pod="$2" i st
  kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Running "pod/$pod" \
    --timeout=300s >/dev/null || return 1
  for i in $(seq 1 60); do
    st=$(vstatus "$ns" "$pod")
    if grep -q 'Initialized' <<<"$st"; then
      return 0
    fi
    sleep 2
  done
  echo "  $ns/$pod is Running but its API did not answer in 120s. Last reply:" >&2
  sed 's/^/    /' <<<"$st" >&2
  return 1
}

# ---------------------------------------------------------------------------
log "why this pod restarted"
# Asked before anything is changed, because unsealing erases the evidence that
# would say whether this happens again tonight. A restartCount that climbs
# between runs is a different problem from a node that rebooted once, and the
# two have nothing in common except the symptom.
kubectl -n "$TRANSIT_NS" get pod "$TRANSIT_POD" \
  -o jsonpath='  restarts: {.status.containerStatuses[0].restartCount}{"\n"}  started: {.status.containerStatuses[0].state.running.startedAt}{"\n"}  previous: {.status.containerStatuses[0].lastState}{"\n"}' \
  || echo "  (could not be read -- the pod may not exist yet)"
echo

# ---------------------------------------------------------------------------
log "transit"
wait_api "$TRANSIT_NS" "$TRANSIT_POD" \
  || die "$TRANSIT_NS/$TRANSIT_POD never answered. Nothing has been changed."

st=$(vstatus "$TRANSIT_NS" "$TRANSIT_POD")
grep -E 'Seal Type|Initialized|Sealed|Unseal Progress|Storage' <<<"$st" | sed 's/^/  /'

grep -q 'Initialized *true' <<<"$st" || die "transit reports Initialized false.

  This script unseals; it does not initialise, and the difference matters here.
  An initialised transit that reads uninitialised means its storage is gone --
  the PVC was deleted, or a fresh volume was attached in its place.

  Its transit key went with it. A new key with the same name is a DIFFERENT key,
  so re-initialising transit leaves the main Vault initialised, sealed, and
  unopenable: its recovery keys authorise generate-root and rekey on a Vault
  that is already open, and a transit-sealed Vault has no unseal keys at all.

  Read docs/30-incident.md section 6 before running anything. Nothing has been
  changed."

if grep -qE 'Sealed +false' <<<"$st"; then
  echo "  already unsealed - nothing to do here"
else
  log "unsealing"
  # In $KEYDIR, not /tmp. This file is three unseal keys in the clear, and
  # $KEYDIR is 700 where /tmp is not.
  [ -s "$KEYDIR/transit-init.json" ] || die "transit is SEALED and
  $KEYDIR/transit-init.json is absent, so the three unseal keys are not here.
  That is the correct resting state -- custody takes them off this node -- so
  this is not a fault, it is the moment the ceremony needs a human.

  Put your copy back and run this again:

    scp transit-init.json root@\$(hostname):$KEYDIR/

  Nothing has been changed. Shred it again when this finishes."

  UK="$KEYDIR/.unseal"
  python3 - "$KEYDIR/transit-init.json" <<'PY' > "$UK"
import json,sys
print("\n".join(json.load(open(sys.argv[1]))["unseal_keys_b64"][:3]))
PY
  chmod 600 "$UK"

  # mapfile, not `while read ... done < "$UK"`. `kubectl exec -i` forwards
  # stdin, and inside that loop stdin IS the key file: the first unseal
  # swallowed keys two and three, read hit EOF, and one key of three was ever
  # submitted. Vault sat at Unseal Progress 1/3 and the next step failed with a
  # 503 naming only `Vault is sealed`.
  mapfile -t UNSEAL_KEYS < "$UK"
  if command -v shred >/dev/null 2>&1; then shred -u "$UK"; else rm -f "$UK"; fi
  [ "${#UNSEAL_KEYS[@]}" -ge 3 ] || die "$KEYDIR/transit-init.json yielded
  ${#UNSEAL_KEYS[@]} unseal key(s), and the threshold is 3. Nothing has been changed."

  # Reset first. Vault does not advance progress for a share it has already
  # been given, so re-running from a partial unseal is not the same as running
  # from zero -- and a ceremony that only works on a clean Vault fails exactly
  # when it is needed.
  reset_out=$(vx "$TRANSIT_NS" "$TRANSIT_POD" "" vault operator unseal -reset \
                </dev/null 2>&1 || true)

  unseal_log=""
  for k in "${UNSEAL_KEYS[@]}"; do
    [ -n "$k" ] || continue
    unseal_log+=$(vx "$TRANSIT_NS" "$TRANSIT_POD" "" vault operator unseal "$k" \
                    </dev/null 2>&1 || true)$'\n'
  done
  unset UNSEAL_KEYS

  st=$(vstatus "$TRANSIT_NS" "$TRANSIT_POD")
  grep -E 'Sealed|Initialized|Unseal Progress' <<<"$st" | sed 's/^/  /'
  grep -qE 'Sealed +false' <<<"$st" || die "transit is still sealed after submitting
  3 of 5 keys. What the reset said:
$(sed 's/^/    /' <<<"$reset_out")
  What the unseal calls said:
$(sed 's/^/    /' <<<"$unseal_log")"
  unset unseal_log reset_out
  echo "  unsealed"
fi

# ---------------------------------------------------------------------------
# An unsealed transit is not the goal. A main Vault that can unseal is.
log "can the main Vault still unseal"
# The probe encrypts a fixed byte string with the autounseal token and throws
# the result away -- exactly what the main Vault does at every start. It writes
# nothing, needs no privilege beyond the autounseal policy, and fails closed.
# cHJvYmU= is "probe", written out so this depends on nothing on the node.
autounseal_tok=$(kubectl -n "$VAULT_NS" get secret "$TOKEN_SECRET" \
                   -o jsonpath='{.data.token}' --ignore-not-found | base64 -d || true)
[ -n "$autounseal_tok" ] || die "$VAULT_NS/$TOKEN_SECRET does not exist or is empty.
  Transit is open, and the main Vault has nothing to open it with. That is
  bootstrap/vault-day0.sh's job, not this script's."

probe=$(vx "$TRANSIT_NS" "$TRANSIT_POD" "$autounseal_tok" \
          vault write -field=ciphertext "transit/encrypt/$KEY_NAME" \
          plaintext=cHJvYmU= </dev/null 2>&1 || true)
unset autounseal_tok
case "$probe" in
  vault:v*) echo "  yes - $VAULT_NS/$TOKEN_SECRET encrypts with $KEY_NAME" ;;
  *) die "transit is unsealed but the autounseal token cannot encrypt with
  $KEY_NAME. The main Vault will NOT unseal at its next restart. What transit
  said:
$(sed 's/^/    /' <<<"$probe")

  A 403 means the token or the policy is wrong -- run bootstrap/vault-day0.sh,
  which reissues it. A 404 on the mount means transit's storage is not the one
  that was configured." ;;
esac
unset probe

# ---------------------------------------------------------------------------
# A main Vault pod only tries to unseal when it starts. One that started during
# the window when transit was sealed is still sealed now, and will stay sealed
# forever -- there is no retry, and nothing in Argo CD reports it, because the
# Application is Synced and the StatefulSet has the replicas it asked for.
#
# That is the silence from the header arriving at its actual cost, and it is why
# this script does not stop at "transit is open".
log "main Vault"
sealed_pods=""
# Derived from the StatefulSet's replica count, not from a label selector. The
# chart's labels are the chart's to change between versions; `vault-$i` is the
# StatefulSet naming contract and cannot drift. It also fails loudly when the
# StatefulSet is absent, where a selector matching nothing would print an empty
# list and read as "all pods fine".
replicas=$(kubectl -n "$VAULT_NS" get statefulset vault -o jsonpath='{.spec.replicas}') \
  || die "$VAULT_NS has no statefulset/vault. Transit is open, but there is
  nothing here to report on -- sync the vault Application first."
[ -n "$replicas" ] || die "statefulset/vault in $VAULT_NS reports no replica count."
for p in $(seq 0 $((replicas - 1)) | sed 's/^/vault-/'); do
  ps=$(vstatus "$VAULT_NS" "$p")
  line=$(grep -E 'Sealed' <<<"$ps" | head -1)
  printf '  %-16s %s\n' "$p" "${line:-no answer}"
  grep -qE 'Sealed +false' <<<"$ps" || sealed_pods="$sealed_pods $p"
done

if [ -n "$sealed_pods" ]; then
  echo
  echo "  SEALED:$sealed_pods"
  echo
  echo "  A Vault unseals at startup and never retries, so these will stay sealed"
  echo "  until they restart. Transit is open now, so a restart is all they need."
  echo "  One at a time, waiting for each to come back 1/1 before the next -- they"
  echo "  are a raft quorum:"
  echo
  for p in $sealed_pods; do
    echo "    kubectl -n $VAULT_NS delete pod $p"
  done
  echo
  exit 1
fi

log "done"
echo "  transit unsealed, the autounseal token proven against it, and every"
echo "  main Vault pod reports Sealed false."
echo
echo "  If you brought $KEYDIR/transit-init.json back for this, shred it:"
echo
echo "    shred -u $KEYDIR/transit-init.json"
