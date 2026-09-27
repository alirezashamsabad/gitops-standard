#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Vault Day-0, end to end, with the key material handled once and deliberately.
#
#   ./bootstrap/05-vault-day0.sh            initialise both vaults
#   ./bootstrap/05-vault-day0.sh --wipe     destroy and re-initialise both
#
# WHY THIS IS A SCRIPT AND NOT A RUNBOOK
#
# Written as a runbook, this is fifteen copy-paste steps with two `tee` commands
# in the middle, and the failure it exists to prevent is the one it produces: the
# init file is deleted before it has been copied anywhere, taking the main Vault's
# root token and every recovery key with it. Vault keeps running -- auto-unseal
# does not need them -- so nothing breaks and nothing warns. It surfaces the first
# time somebody needs to administer Vault, which may be months later.
#
# So this script REFUSES TO CONTINUE until you type the confirmation that the
# key material is stored somewhere other than this node. That is a weak
# guarantee - you can lie to it - but it moves the moment of decision to when
# the keys are on screen, instead of leaving it to be remembered later.
#
# WHAT --wipe DESTROYS
#
# Both Vaults' storage, permanently. Safe only while they hold nothing: a fresh
# install, or a recovery from lost keys where there is nothing left to lose.
# Never on a Vault holding real secrets - restore from a snapshot instead, see
# docs/30-incident.md.
#
# RUN IT UNDER tmux OR screen
#
# It stops at a prompt and waits for a human, twice. A dropped SSH session
# between the keys appearing and the confirmation being typed leaves the
# ceremony half done, which is the ordinary outcome of running a long ceremony
# over a VPN.
#
#   tmux new -s vault   then   ./bootstrap/vault-day0.sh
#
# A dropped session is now recoverable rather than dangerous: every step here
# checks what exists before acting, so running this again on a cluster in any
# state is safe. It was not always -- see the commit that added init_into. But
# recoverable is not the same as free, and the keys are on screen while you are
# reconnecting.
#
# ASCII only.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

WIPE=false
# Set where transit is initialised, read where the main Vault is judged -- so it
# is declared before either, above everything. Assigning it between the two
# resets the flag that was just set.
TRANSIT_WAS_INITIALISED=false
[ "${1:-}" = "--wipe" ] && WIPE=true

KEYDIR="${KEYDIR:-/root/vault-keys}"
TRANSIT_NS=vault-transit
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

# `vault status` uses its exit code to say what state the Vault is in: 0
# unsealed, 2 sealed, 1 could not reach the listener. That is data, not a
# failure -- but pipefail turns it into one, so `vx ... vault status | grep`
# reported no match whatever the output said, and a sealed-but-initialised
# Vault read as uninitialised. This script had that shape in three places.
# Capture, then match. Same trap as the one hack/prove-checks.sh names twice.
#
# </dev/null because `kubectl exec -i` otherwise eats the stdin that
# confirm_custody reads from, and a ceremony that swallows its own confirmation
# is worse than one that fails.
vstatus() { vx "$1" "$2" "" vault status </dev/null 2>&1 || true; }

# What the next step needs is not Ready. It is an API that answers.
#
# A sealed or uninitialised Vault is never Ready -- deliberately: the probes in
# platform/vault-transit/values.yaml make readiness the signal that it is
# sealed. So `wait --for=condition=Ready` spends its entire timeout on the
# normal path and then continues anyway. Five silent minutes on every fresh
# cluster, indistinguishable from a hang, ending in a line saying it did not
# matter. A wait whose timeout IS the expected path teaches people to ignore
# the one time it means something.
#
# Running, then the first line of `vault status`. Seconds, and it fails for a
# reason when it fails.
wait_api() {
  local ns="$1" pod="$2" i st
  kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Running "pod/$pod" \
    --timeout=300s >/dev/null || return 1
  for i in $(seq 1 60); do
    st=$(vstatus "$ns" "$pod")
    if grep -q 'Initialized' <<<"$st"; then
      grep -E 'Initialized|Sealed' <<<"$st" | sed 's/^/  /'
      return 0
    fi
    sleep 2
  done
  echo "  $ns/$pod is Running but its API did not answer in 120s. Last reply:" >&2
  sed 's/^/    /' <<<"$st" >&2
  return 1
}

# `cmd > file` truncates the file BEFORE cmd runs. So an init that fails empties
# the key file that was already there -- and the one failure that reaches this
# line is `Vault is already initialized`, which is precisely the case where that
# file was the only copy of the keys. A Vault initialised with no keys cannot be
# administered or unsealed again; for transit it also means the main Vault never
# unseals. That is the disaster written across the header of this script,
# arriving through the script itself.
#
# Write beside it, move on success, and refuse to run at all if keys are already
# there -- because reaching this branch with a full key file means the state and
# the file disagree, and guessing which one is right is not a decision a script
# gets to make.
# A key file for a Vault that no longer exists.
#
# init_into refuses to write over a full key file, which is right: reaching the
# initialise branch with keys already there means the Vault and the file
# disagree, and a script does not get to decide which is correct.
#
# It does get to decide THIS case. The branch is only reached because `vault
# status` just said Initialized false, and a Vault that has never been
# initialised cannot be the one those keys belong to. So the file is provably
# stale -- and moved aside rather than deleted, because it is key material and
# the operator, not this script, decides when it is worthless.
set_aside_stale_keys() {   # $1 = file ; $2 = what it was for
  local f="$1" what="$2" moved
  [ -s "$f" ] || return 0
  moved="$f.superseded-$(date +%Y%m%dT%H%M%S)"
  mv "$f" "$moved"
  echo "  $f held keys for a $what that no longer exists -- that Vault reports"
  echo "  Initialized false, so nothing can be using them. Moved to:"
  echo "    $moved"
  echo "  Shred it once you are certain. It is still key material."
}

init_into() {
  local dest="$1"; shift
  if [ -s "$dest" ]; then
    die "$dest already holds keys, and this is the branch that initialises.
  One of the two is wrong: either the Vault is initialised and was misread, or
  this file belongs to a Vault that is gone. Read it and \`vault status\` before
  going further. Nothing has been changed."
  fi
  local tmp; tmp=$(mktemp "$KEYDIR/.init.XXXXXX")
  chmod 600 "$tmp"
  if ! "$@" > "$tmp"; then
    rm -f "$tmp"
    die "init failed and $dest was not touched. Its output was not JSON, so
  nothing was written anywhere."
  fi
  mv "$tmp" "$dest"
  chmod 600 "$dest"
}

# Read a credential without echoing it, and refuse the empty answer. Used
# wherever a key file that custody says to remove is needed again.
ask_secret() {   # $1 = prompt ; sets REPLY_VALUE
  local prompt="$1" i val
  for i in 1 2 3; do
    printf '  %s: ' "$prompt" >&2
    read -r -s val < /dev/tty; echo >&2
    # A terminal with bracketed paste on wraps pasted text in ESC[200~ and
    # ESC[201~, and `read -s` keeps them because nothing is echoing to strip
    # them. The value is then right and its first character is not, and the
    # rejection that follows looks exactly like a wrong token. Most modern
    # shells enable bracketed paste by default, so this is the normal case for
    # anyone pasting rather than typing.
    val=${val//$'\e'\[200\~/}
    val=${val//$'\e'\[201\~/}
    val=${val//$'\e'/}
    # Whitespace either side, and any stray CR from a copy that crossed a
    # Windows clipboard.
    val="$(printf '%s' "$val" | tr -d '\r\n\t' )"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [ -n "$val" ]; then
      # The shape, never the value. This is what tells an operator they pasted
      # a recovery key, or half a token, or the wrong file's -- without any of
      # it reaching the screen or the logs.
      printf '    read %d characters, starting "%s"\n' "${#val}" "${val:0:4}" >&2
      REPLY_VALUE="$val"
      return 0
    fi
    echo "    refused: empty" >&2
  done
  die "no value for $prompt after three tries. Nothing has been changed."
}

confirm_custody() {
  # The whole point of the script, and typing COPIED was not enough.
  #
  # An operator types it, the run finishes, the keys are shredded from this node
  # as the closing page says to, and the init file is not on the other side. The
  # main Vault keeps running -- auto-unseal does not need the root token -- so
  # nothing breaks and nothing warns, which is the exact
  # sentence at the top of this file describing the failure it was written to
  # prevent. The word COPIED asserts something only the operator can see.
  #
  # So it asks for something only a real copy can produce: the first eight
  # characters of the file's md5, computed on the machine the copy is on. An
  # operator who has not copied it cannot answer, and an operator who copied the
  # wrong file answers wrongly.
  local what="$1" file="$2" want ans
  want=$(md5sum "$file" | cut -c1-8)
  echo
  echo "  $what is now in $file on THIS NODE ONLY."
  echo
  echo "  Copy it somewhere else now. If this node is lost and you have not, the"
  echo "  Vault it belongs to cannot be administered again - and for the transit"
  echo "  Vault, the main Vault cannot be unsealed either."
  echo
  echo "    scp root@\$(hostname):$file ."
  echo
  echo "  Then, ON THE MACHINE YOU COPIED IT TO, run:"
  echo
  echo "    md5sum $(basename "$file") | cut -c1-8"
  echo
  printf '  Type the eight characters it printed: '
  read -r ans
  if [ "$ans" != "$want" ]; then
    die "that is not the checksum of $file, so there is no verified copy of it.
  Stopping with the keys still on this node. Nothing has been lost: copy the
  file, check it, and run this again -- every step here is repeatable."
  fi
  echo "  verified: a copy of $file exists somewhere else"
}

mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"

# --- optional wipe --------------------------------------------------------- #
if [ "$WIPE" = true ]; then
  log "WIPING both Vaults - all storage destroyed"
  printf '  Type WIPE to confirm: '; read -r a; [ "$a" = "WIPE" ] || die "not confirmed"
  for ns in "$VAULT_NS" "$TRANSIT_NS"; do
    kubectl -n "$ns" scale sts --all --replicas=0 >/dev/null 2>&1 || true
  done
  sleep 15
  for ns in "$VAULT_NS" "$TRANSIT_NS"; do
    kubectl -n "$ns" delete pvc --all --wait=true >/dev/null 2>&1 || true
  done
  kubectl -n "$VAULT_NS" delete secret "$TOKEN_SECRET" >/dev/null 2>&1 || true
  kubectl -n "$TRANSIT_NS" scale sts --all --replicas=1 >/dev/null
  kubectl -n "$VAULT_NS"   scale sts --all --replicas=3 >/dev/null
  echo "    storage deleted, StatefulSets scaled back up"
fi

# --- transit --------------------------------------------------------------- #
log "waiting for $TRANSIT_NS/vault-transit-0"
# Two different things, and only one of them is a reason to stop. A pod that
# does not exist means the Application has not synced yet -- carrying on there
# produced three NotFound errors and an attempt to initialise something that is
# not there. A pod that exists and is not Ready is the normal state of an
# uninitialised Vault, and wait_api is built around that rather than around a
# timeout that always expires.
kubectl -n "$TRANSIT_NS" get pod vault-transit-0 >/dev/null \
  || die "$TRANSIT_NS/vault-transit-0 does not exist. Sync the vault-transit
  Application first - it is automated: false on purpose, so it waits for a
  human. Nothing has been changed."
wait_api "$TRANSIT_NS" vault-transit-0 \
  || die "$TRANSIT_NS/vault-transit-0 never answered. Nothing has been changed."

if grep -q 'Initialized *true' <<<"$(vstatus "$TRANSIT_NS" vault-transit-0)"; then
  echo "  already initialised - skipping init"
  # NOT a refusal. An absent key file is the correct state after custody: the
  # keys were copied off this node and shredded here, which is what the closing
  # page of this script tells you to do.
  #
  # Do not die here telling the operator to recover a file the procedure has
  # just instructed them to destroy. What the steps below actually need is
  # resolved where they need it: a
  # sealed transit needs three unseal keys, and the configuration step needs the
  # root token, and neither is wanted when transit is already open and set up.
  if [ -s "$KEYDIR/transit-init.json" ]; then
    echo "  its keys are in $KEYDIR"
  else
    echo "  its keys are not on this node, which is where custody leaves them"
  fi
else
  TRANSIT_WAS_INITIALISED=true
  log "initialising transit"
  set_aside_stale_keys "$KEYDIR/transit-init.json" "transit Vault"
  init_into "$KEYDIR/transit-init.json" \
    vx "$TRANSIT_NS" vault-transit-0 "" vault operator init \
      -key-shares=5 -key-threshold=3 -format=json
  confirm_custody "The transit Vault's 5 unseal keys and root token" \
    "$KEYDIR/transit-init.json"
fi

log "unsealing transit"
# Skip the whole step when it is already open. Everything below puts three
# unseal keys on disk in the clear for as long as it takes to submit them, and
# doing that to a Vault that is already unsealed is exposure bought for nothing.
if grep -qE 'Sealed +false' <<<"$(vstatus "$TRANSIT_NS" vault-transit-0)"; then
  echo "  already unsealed - skipping"
else
# In $KEYDIR, not /tmp. This file is three unseal keys in the clear. $KEYDIR is
# 700; /tmp is not, and the file lived for as long as the loop below took.
[ -s "$KEYDIR/transit-init.json" ] || die "transit is SEALED and
  $KEYDIR/transit-init.json is absent, so the three unseal keys are not here.
  Put your copy back and run this again:

    scp transit-init.json root@\$(hostname):$KEYDIR/

  Nothing has been changed. Shred it again when this finishes."
UK="$KEYDIR/.unseal"
python3 - "$KEYDIR/transit-init.json" <<'PY' > "$UK"
import json,sys
print("\n".join(json.load(open(sys.argv[1]))["unseal_keys_b64"][:3]))
PY
chmod 600 "$UK"

# NOT `while read -r k; do vx ...; done < "$UK"`.
#
# `kubectl exec -i` reads stdin, and inside that loop stdin IS the key file. The
# first unseal swallowed keys two and three, `read` hit EOF, and exactly one key
# of the three was ever submitted. Vault stayed at Unseal Progress 1/3, the
# `|| true` on that line hid it, and the step after failed with three 503s
# saying `Vault is sealed` and naming nothing that explained why.
#
# mapfile does not involve stdin at all, and </dev/null on the exec means the
# same trap cannot return if this ever becomes a loop again.
mapfile -t UNSEAL_KEYS < "$UK"
if command -v shred >/dev/null 2>&1; then shred -u "$UK"; else rm -f "$UK"; fi
[ "${#UNSEAL_KEYS[@]}" -ge 3 ] || die "$KEYDIR/transit-init.json yielded
  ${#UNSEAL_KEYS[@]} unseal key(s), and the threshold is 3. Nothing has been changed."

# A previous run can leave a partial unseal behind -- Unseal Progress 1/3, from a
# loop that submitted one key of three. Vault does not advance progress for a
# share it has already been
# given, so re-running the step from a partial state is not the same as running
# it from zero -- and a ceremony that only works on a clean Vault is one that
# fails exactly when it is needed. Reset first, then submit all three.
reset_out=$(vx "$TRANSIT_NS" vault-transit-0 "" vault operator unseal -reset \
              </dev/null 2>&1 || true)

# Each key's output is kept rather than discarded. `vault operator unseal`
# reports progress on stdout and its exit code is not a reliable "did it work" --
# so the authority is the seal state afterwards, and these lines are what
# explains a refusal when there is one.
unseal_log=""
for k in "${UNSEAL_KEYS[@]}"; do
  [ -n "$k" ] || continue
  unseal_log+=$(vx "$TRANSIT_NS" vault-transit-0 "" vault operator unseal "$k" \
                  </dev/null 2>&1 || true)$'\n'
done
unset UNSEAL_KEYS

st=$(vstatus "$TRANSIT_NS" vault-transit-0)
grep -E 'Sealed|Initialized|Unseal Progress' <<<"$st" | sed 's/^/  /'
# Unseal Progress is printed now. It was not, and it was the one line that said
# what had gone wrong: 1/3.
grep -qE 'Sealed +false' <<<"$st" || die "transit is still sealed after submitting
  3 of 5 keys. Every step after this one needs it open, and each would fail with
  a 503 naming only 'Vault is sealed'. What the reset said:
$(sed 's/^/    /' <<<"$reset_out")
  What the unseal calls said:
$(sed 's/^/    /' <<<"$unseal_log")"
unset unseal_log reset_out
fi
# ---------------------------------------------------------------------------
# IS THE TRANSIT HALF ALREADY DONE?
#
# Ask the only question that matters, and ask it of the thing that will do the
# work: can the token in $VAULT_NS/$TOKEN_SECRET encrypt with $KEY_NAME on the
# transit Vault? That is precisely what the main Vault does at every start. If
# the answer is yes then the mount, the key, the policy and the token are all
# present and correct, and there is nothing here to configure.
#
# This matters beyond saving three API calls. Everything below needs the
# TRANSIT Vault's root token, and on a cluster that has been running for a
# while that token is in split custody somewhere off-site, where fetching it to
# re-run a ceremony that has nothing to do is the wrong trade. It was also the
# state this script could not get past: transit healthy, configured, unsealed,
# its keys correctly not on the node, and the script demanding them to check
# work that was already finished.
#
# The probe encrypts a fixed byte string and throws the result away. It writes
# nothing, needs no privilege beyond the autounseal policy, and fails closed:
# any answer that is not a ciphertext means configure.
# Set before the branch, not inside it. TOKEN_CHANGED lives in the half that is
# now skippable, and line 492 reads it whether or not that half ran: under
# `set -u` the skip path died with `TOKEN_CHANGED: unbound variable` after
# reporting success on everything it had done. A variable read outside a branch
# has to be assigned outside it.
TOKEN_CHANGED=false
TRANSIT_READY=false
autounseal_tok=$(kubectl -n "$VAULT_NS" get secret "$TOKEN_SECRET" \
                   -o jsonpath='{.data.token}' --ignore-not-found | base64 -d || true)
if [ -n "$autounseal_tok" ]; then
  # cHJvYmU= is "probe". Written out rather than piped through base64 so this
  # depends on nothing installed on the node.
  probe=$(vx "$TRANSIT_NS" vault-transit-0 "$autounseal_tok" \
            vault write -field=ciphertext "transit/encrypt/$KEY_NAME" \
            plaintext=cHJvYmU= </dev/null 2>&1 || true)
  case "$probe" in
    vault:v*) TRANSIT_READY=true ;;
  esac
  unset probe
fi
unset autounseal_tok

if [ "$TRANSIT_READY" = true ]; then
  log "transit is already configured"
  echo "  $VAULT_NS/$TOKEN_SECRET encrypts with $KEY_NAME on $TRANSIT_NS."
  echo "  That is the whole of what the main Vault needs from transit, so its"
  echo "  root token is not required and is not asked for."
else

# The transit Vault's root token, which the configuration step below needs.
# From the file if custody has not taken it away yet, otherwise asked for --
# same three sources as seed-vault-kv.sh uses for the main Vault's, and for the
# same reason: a procedure that tells you to remove a file cannot then require
# it.
TR="${TRANSIT_ROOT_TOKEN:-}"
if [ -z "$TR" ] && [ -s "$KEYDIR/transit-init.json" ]; then
  TR=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["root_token"])' \
         "$KEYDIR/transit-init.json")
fi
if [ -z "$TR" ]; then
  echo "  The transit Vault's root token is needed to configure its engine, and"
  echo "  $KEYDIR/transit-init.json is not on this node -- which is correct." >&2
  echo "  Paste the root_token from your copy. It is not echoed and not stored." >&2
  echo "  Note WHICH file: transit-init.json has 5 unseal keys and 0 recovery" >&2
  echo "  keys. main-init.json is the other Vault and its token fails here." >&2
  ask_secret "transit root_token"
  TR="$REPLY_VALUE"; unset REPLY_VALUE
fi
# Ask transit whether it is any good, before it is used for anything.
tr_check=$(vx "$TRANSIT_NS" vault-transit-0 "$TR" vault token lookup </dev/null 2>&1 || true)
grep -q 'policies' <<<"$tr_check" || die "$TRANSIT_NS/vault-transit-0 rejected that
  token. Nothing has been changed. What it said:
$(sed 's/^/    /' <<<"$tr_check")"
unset tr_check

log "configuring transit engine, key and policy"
# `sh`, not `sh -e`, and that is on purpose: enabling a mount that already
# exists is the normal state of a re-run, not a failure. But it means nothing
# in here can report anything, so the block claims nothing and the check below
# asks the Vault what is actually there.
#
# A filter of `grep -v 'path is already in use'` matches English error text, and
# Vault can answer `Code: 400. Errors:` with an empty body -- the filter then
# matches nothing, the raw error prints, and the line after it says
# `transit/ enabled` regardless. An operator reading that saw a 400 and a
# success claim about the same command.
vx "$TRANSIT_NS" vault-transit-0 "$TR" sh -s <<EOF
vault secrets enable transit || true
vault write -f transit/keys/$KEY_NAME || true
vault policy write autounseal - <<'POLICY'
path "transit/encrypt/$KEY_NAME" { capabilities = ["update"] }
path "transit/decrypt/$KEY_NAME" { capabilities = ["update"] }
POLICY
EOF

# Ask, do not claim. Everything the main Vault's seal needs is one of these
# three, and each is readable in one call. A mount that failed to enable and a
# mount that was already there produce the same answer here, which is the right
# answer: the question is whether it exists now.
cfg_check=$(vx "$TRANSIT_NS" vault-transit-0 "$TR" sh -s 2>&1 <<EOF || true
vault secrets list | grep -q '^transit/' && echo MOUNT_OK
vault read transit/keys/$KEY_NAME > /dev/null && echo KEY_OK
vault policy read autounseal > /dev/null && echo POLICY_OK
EOF
)
for want in MOUNT_OK KEY_OK POLICY_OK; do
  grep -q "$want" <<<"$cfg_check" || die "transit is missing $want after the
  configuration step. The main Vault cannot unseal without it, and it would fail
  at start with a message about a seal rather than about this. What transit said:
$(sed 's/^/    /' <<<"$cfg_check")"
done
unset cfg_check
echo "  transit/ enabled, key $KEY_NAME and policy autounseal confirmed present"

log "issuing the autounseal token straight into the Secret"
# Minting a new token on every run and leaving the previous one valid gives an
# orphan with encrypt/decrypt on the seal key, one more each time, none revoked.
# And the step after it restarts all three Vault pods, so re-running the ceremony
# to check something would take the cluster down.
#
# Both are the same fault. Running this script again on a working cluster has to
# be safe, because the reason anyone runs it again is that they are not sure
# what state things are in.
#
# --ignore-not-found, not a silenced error: an absent Secret is the first-run
# answer, not a failure.
existing=$(kubectl -n "$VAULT_NS" get secret "$TOKEN_SECRET" \
             -o jsonpath='{.data.token}' --ignore-not-found | base64 -d || true)
TOKEN_CHANGED=false
# `vault token lookup` is lookup-self, which every token carries through the
# default policy. It answers the only question that matters here: does transit
# still accept what the Secret holds.
if [ -n "$existing" ] \
   && vx "$TRANSIT_NS" vault-transit-0 "$existing" vault token lookup </dev/null >/dev/null; then
  echo "  $VAULT_NS/$TOKEN_SECRET already holds a token transit accepts - keeping it"
else
  # Never printed. The token goes from the pod into a Secret without passing
  # through a terminal. A token that reaches a scrollback has to be revoked.
  AT=$(vx "$TRANSIT_NS" vault-transit-0 "$TR" vault token create -policy=autounseal \
         -orphan -period=768h -display-name=vault-autounseal -format=json \
       | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')
  kubectl -n "$VAULT_NS" create secret generic "$TOKEN_SECRET" \
    --from-literal=token="$AT" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  unset AT
  TOKEN_CHANGED=true
  echo "  $VAULT_NS/$TOKEN_SECRET written"
fi
unset existing TR
fi

# --- main vault ------------------------------------------------------------ #
kubectl -n "$VAULT_NS" get pod vault-0 >/dev/null \
  || die "$VAULT_NS/vault-0 does not exist. Sync the vault Application first --
  it is automated: false on purpose. The transit side above is done and its
  keys are in $KEYDIR."
# Knowable before anything else happens here, and the only chance to say it
# before the operator reads a wall of output and a refusal at the end.
if [ "$TRANSIT_WAS_INITIALISED" = true ] \
   && grep -q 'Initialized *true' <<<"$(vstatus "$VAULT_NS" vault-0)"; then
  echo
  echo "  NOTE: transit was initialised by THIS run, and $VAULT_NS/vault-0 was"
  echo "  already initialised before it. Its master key is sealed with the old"
  echo "  transit key, which no longer exists, so it will not unseal -- and the"
  echo "  check at the end of this script is going to say so."
  echo
  echo "  Expected when you are rebuilding both. A surprise only if you rebuilt"
  echo "  transit alone, in which case this Vault's contents are already gone"
  echo "  and nothing below brings them back."
  echo
fi
if [ "$TOKEN_CHANGED" = true ]; then
  log "restarting the main Vault so it picks up the new token"
  # Plain delete, never --force. These are raft members and the name is the
  # identity -- see section 3 of docs/30-incident.md.
  kubectl -n "$VAULT_NS" delete pod --all >/dev/null
  sleep 20
else
  log "the main Vault already has this token - not restarting"
fi
wait_api "$VAULT_NS" vault-0 \
  || die "$VAULT_NS/vault-0 never answered. The transit side above is done and its
  keys are in $KEYDIR."

if grep -q 'Initialized *true' <<<"$(vstatus "$VAULT_NS" vault-0)"; then
  echo "  already initialised - skipping init"
else
  log "initialising the main Vault"
  # VAULT_TOKEN deliberately empty: the pod's env holds the autounseal token,
  # whose policy allows only transit encrypt/decrypt, and every admin call with
  # it fails as permission denied with nothing naming the cause.
  set_aside_stale_keys "$KEYDIR/main-init.json" "main Vault"
  init_into "$KEYDIR/main-init.json" \
    vx "$VAULT_NS" vault-0 "" vault operator init \
      -recovery-shares=5 -recovery-threshold=3 -format=json
  confirm_custody "The main Vault's 5 recovery keys and root token" \
    "$KEYDIR/main-init.json"
fi

log "status"
main_status=$(vstatus "$VAULT_NS" vault-0)
grep -E 'Seal Type|Initialized|Sealed|Storage' <<<"$main_status" | sed 's/^/  /'

# "Vault is up" was printed once over `Sealed true`, which is not up by any
# reading. A transit-sealed Vault that is initialised and will not unseal has
# exactly one cause worth naming first, and it is not recoverable by any key the
# operator holds.
if ! grep -qE 'Sealed +false' <<<"$main_status"; then
  die "$VAULT_NS/vault-0 is INITIALISED and SEALED, and it will not open.

  A transit-sealed Vault stores its master key encrypted with the transit key.
  If that key is not the one that encrypted it, there is nothing to decrypt it
  with -- and the recovery keys do not help: they authorise generate-root and
  rekey on a Vault that is already open. They are not unseal keys. This Vault
  has none, by design.

  The usual cause is that the transit Vault was rebuilt. A new transit Vault
  has a new key, and \`$KEY_NAME\` names the same key only in the sense that two
  people can share a first name. Everything this Vault held is gone with it.

  The way forward is to rebuild this Vault against the transit that exists now.
  It is the procedure in docs/30-incident.md section 6, and it is quick because
  everything in here is recreated by bootstrap/seed-vault-kv.sh from the
  repository -- except the values in KV, which is why that script asks for them.

  Do NOT rebuild transit again to try to fix this. That is the loop: each
  rebuild of transit orphans the Vault it seals.

  What Vault said:
$(sed 's/^/    /' <<<"$main_status")"
fi
unset main_status

cat <<EOF

=== Vault is up. Three things remain, IN THIS ORDER, and none is optional.

1. Prove auto-unseal, which is the only evidence any of this works:

     kubectl -n $VAULT_NS delete pod vault-1
     sleep 75
     kubectl -n $VAULT_NS get pods

   vault-1 must return Ready with no manual unseal. If it does not, the token
   in $TOKEN_SECRET is wrong and the next node reboot takes the cluster down.

2. Copy $KEYDIR off this node NOW - and then configure KV and Kubernetes auth
   for ESO, which is docs/05-vault-eso.md. That needs the root token, and the
   root token is in $KEYDIR/main-init.json:

     ROOT=\$(python3 -c 'import json;print(json.load(open("$KEYDIR/main-init.json"))["root_token"])')

3. Only when step 2 is finished, shred what is left here:

     shred -u $KEYDIR/*.json

   Nothing in git can check that you did. This is the one part of the platform
   that rests entirely on the operator.

   The order matters: with shredding as step 2 and the ESO configuration a
   sentence after it, an operator following this page in order destroys the
   token the next step needs.
EOF
