#!/usr/bin/env bash
# Rehearse the incident procedure on one non-critical workload, and print a log.
#
# docs/30-incident.md makes three claims that are only worth anything if they
# have been seen to hold:
#
#   1. freezing one Application actually stops Argo CD reverting a hand change
#      -- which depends on ignoreApplicationDifferences being on every
#      ApplicationSet, and is silently false without it;
#   2. a hand change survives long enough to be useful;
#   3. unfreezing returns ownership without a fight.
#
# This runs all three against a real cluster and times them. It changes only
# replicas, and only on a workload you name.
#
#   ./hack/drill.sh tenants/<tenant>/<env>/<service> --yes
set -uo pipefail
cd "$(dirname "$0")/.."

p="${1:-}"; confirm="${2:-}"
[ -n "$p" ] || { echo "usage: drill.sh <tenants/<t>/<env>/<svc>> --yes" >&2; exit 2; }
p="${p%/}"

# ---- refusals that need no cluster, so they are the ones that can be proved --
case "$p" in
  tenants/*/*/*|shared/*/*/*) : ;;
  *) echo "REFUSED: $p is not a tenant workload. Rehearse on something disposable," >&2
     echo "never on a platform component -- the secret plane is not a drill." >&2; exit 1 ;;
esac
[ -f "$p/config.yaml" ] || { echo "REFUSED: no $p/config.yaml" >&2; exit 1; }
# Not silenced. A parse error here would have exited non-zero and been read as
# "not stateful", which is how a drill ends up running against something that
# owns data.
stateful=$(python3 -c "
import yaml
d=yaml.safe_load(open('$p/config.yaml')) or {}
print('yes' if d.get('stateful') else 'no')") || {
  echo "REFUSED: cannot read $p/config.yaml" >&2; exit 1; }
if [ "$stateful" = "yes" ]; then
  echo "REFUSED: $p is stateful. A drill that touches something owning data is" >&2
  echo "not a drill." >&2; exit 1
fi
[ "$confirm" = "--yes" ] || {
  echo "This changes a running workload on a live cluster. Re-run with --yes." >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is not on PATH." >&2; exit 2; }

# Every kubectl in this file goes through here, and it carries the two guards
# compare-live.sh needed for the same reason.
#
# `</dev/null`: a kubeconfig whose user has no credentials makes kubectl print
# `Please enter Username:` and wait on stdin. On a terminal that is a drill
# that stops forever -- and it stops after step 1, with the Application frozen
# and nobody told.
#
# `--request-timeout`: a cluster that accepts the connection and then says
# nothing hangs in exactly the same place, and reads as the same silence.
k() { kubectl "$@" --request-timeout=30s </dev/null; }

ns=$(python3 -c "import yaml;print(yaml.safe_load(open('$p/config.yaml'))['namespace'])")
svc=$(basename "$p"); env=$(basename "$(dirname "$p")")
ten=$(basename "$(dirname "$(dirname "$p")")")
app="$ten-$env-$svc"

t0=$(date +%s); step() { printf '\n[%4ss] %s\n' "$(( $(date +%s) - t0 ))" "$1"; }
echo "=== incident drill: $app  (namespace $ns)  $(date -Is)"

# Set the moment the freeze lands, and only then. Everything after that point
# has to put the workload back before it gives up, and a drill that exits with
# the Application still frozen has done more damage than the incident it
# rehearses.
frozen=no
before=""
# What syncPolicy.automated actually said before the freeze, read off the live
# Application in step 0. Writing it back as a literal {selfHeal:true,
# prune:false} is right for most workloads and wrong for any with prune: true --
# and since ignoreApplicationDifferences covers /spec/syncPolicy, the
# ApplicationSet does not put the real one back.
# A drill that reports success and leaves the live sync policy changed is the
# same defect as one that reports success having seen nothing.
was_automated=""
# A failing step 3 has to reach the log and the exit code both. Printing
# REVERTED and then exiting 0 makes the one claim this drill exists to test
# able to fail inside a run that reads as passed.
verdict=ok

give_it_back() {
  [ "$frozen" = yes ] || return 0
  local rc=0
  echo
  echo "  putting it back: replicas -> $before, auto-sync as it was"
  k -n "$ns" scale deploy "$svc" --replicas="$before" >/dev/null || {
    echo "  *** COULD NOT RESTORE REPLICAS. $svc is left scaled in $ns; the" >&2
    echo "  *** message above says why. Fix it by hand before you leave." >&2
    rc=1; }
  k -n argocd patch application "$app" --type merge \
    -p "{\"spec\":{\"syncPolicy\":{\"automated\":$was_automated}}}" >/dev/null || {
    echo "  *** COULD NOT UNFREEZE $app. It is STILL FROZEN: Argo CD will not" >&2
    echo "  *** reconcile it, and nothing will say so. Put syncPolicy.automated" >&2
    echo "  *** back to $was_automated by hand." >&2
    return 1; }
  frozen=no
  # Not `return 0`. A restore that put the sync policy back but left the
  # workload scaled is not a restore, and step 4 reads this return value.
  return $rc
}

# Ctrl-C, a timeout, an ssh session that dropped. HUP is in the list because
# the line above names a closed terminal, and a trap catching only INT and TERM
# would miss it -- and S5 gets run over ssh. Nothing catches KILL or a laptop that
# sleeps; for those the step 0 refusal is the way back, and the page says so.
#
# Without this the script dies
# between the freeze and step 4 and the Application stays frozen -- silently,
# because the thing that would have said so is the run that just ended. The
# already-frozen refusal at step 0 is the way back from that, not a way to
# avoid it.
on_signal() {
  trap - INT TERM HUP
  echo >&2
  echo "  interrupted. Putting the workload back before stopping." >&2
  give_it_back
  exit 130
}
trap on_signal INT TERM HUP

# bash runs a trap after the current foreground command returns, and `sleep 30`
# returns when it is good and ready. Backgrounded and waited on, the signal
# reaches the trap now rather than half a minute from now -- which is the
# difference between an interrupted drill and an interrupted drill that stays
# frozen for the rest of the sleep.
#
# The sleep gets no file descriptors: signalled with `timeout`, which signals
# this process and not the group, the sleep is orphaned and would otherwise
# hold the caller's stdout open for the rest of its half minute -- so a run
# under `$(...)` or a pipe hangs long after the drill has exited.
nap() { sleep "$1" >&- 2>&- & wait $!; }

# Stop, but never while still holding the workload.
die() {
  echo >&2
  echo "  $1" >&2
  echo "  The kubectl message above says why." >&2
  # Do not say "Nothing further was attempted" here and then call give_it_back:
  # that is a confident wrong sentence one line from the thing it is wrong
  # about.
  give_it_back
  exit 1
}

step "0. baseline"
# No 2>/dev/null: "not deployed" and "cannot reach the cluster" must not
# produce the same empty answer, because only one of them means it is safe to
# carry on.
before=$(k -n "$ns" get deploy "$svc" -o jsonpath='{.spec.replicas}') || {
  echo "  $svc is not running in $ns, or the cluster refused the request." >&2
  echo "  The message above says which. Nothing has been changed." >&2; exit 1; }
echo "  replicas=$before"
# Assigned, then printed. Piped straight into sed, a failure here printed
# nothing and the drill carried on to freeze an Application it had not
# established exists.
baseline=$(k -n argocd get application "$app" \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers) || {
  echo "  cannot read Application $app in argocd. Either it is not there -- so" >&2
  echo "  there is nothing to freeze -- or the cluster refused. Nothing has been" >&2
  echo "  changed." >&2; exit 1; }
sed 's/^/  /' <<<"$baseline"
was_automated=$(k -n argocd get application "$app" -o jsonpath='{.spec.syncPolicy.automated}') \
  || { echo "  cannot read $app's sync policy, so nothing here could put it back." >&2
       echo "  Nothing has been changed." >&2; exit 1; }
if [ -z "$was_automated" ]; then
  echo "  REFUSED: $app has no syncPolicy.automated -- it is already frozen, by" >&2
  echo "  hand or by a drill that did not finish. Freezing it again proves" >&2
  echo "  nothing, and unfreezing it at the end would be a change nobody asked" >&2
  echo "  for. Put it back first, or pick another workload." >&2; exit 1
fi
# The value has to go back in as JSON inside a merge patch. Some kubectl builds
# print a map as Go does -- `map[prune:false selfHeal:true]` -- which is not
# JSON and will not patch. Caught here it costs nothing; caught in
# give_it_back it costs the freeze, because by then the Application is frozen
# and the only command that unfreezes it is the one that just failed.
case "$was_automated" in
  "{"*"}") : ;;
  *) echo "  REFUSED: this kubectl printed syncPolicy.automated as" >&2
     echo "      $was_automated" >&2
     echo "  which is not JSON and will not go back in as a merge patch. That" >&2
     echo "  failure would land after the freeze, with nothing left to undo it." >&2
     echo "  Use a kubectl whose jsonpath emits JSON. Nothing has been changed." >&2
     exit 1 ;;
esac
echo "  automated=$was_automated"

# A drill that reads replicas cannot tell an autoscaler from Argo CD: both make
# the count fall back, and step 3 would report REVERTED and fail the run for
# something that is working as designed. Refuse rather than measure the wrong
# thing.
hpas=$(k -n "$ns" get hpa \
  -o jsonpath='{range .items[*]}{.spec.scaleTargetRef.kind}/{.spec.scaleTargetRef.name}{"\n"}{end}') || {
  echo "  cannot list HorizontalPodAutoscalers in $ns, so whether something else" >&2
  echo "  moves these replicas is unknown. Nothing has been changed." >&2; exit 1; }
if grep -qxF "Deployment/$svc" <<<"$hpas"; then
  echo "  REFUSED: an HorizontalPodAutoscaler targets Deployment/$svc. This drill" >&2
  echo "  proves the freeze by changing replicas and watching whether they come" >&2
  echo "  back -- and they will come back either way here, from the autoscaler," >&2
  echo "  which step 3 would report as Argo CD reverting. Rehearse on a workload" >&2
  echo "  nothing else scales." >&2; exit 1
fi

step "1. freeze — patch the Application, then see whether it stays frozen"
# A patch that failed and a freeze the ApplicationSet undid are two different
# things, and unguarded they produced the same sentence: `still` stayed
# non-empty either way and the drill announced THE FREEZE DID NOT HOLD -- the
# one line in this script that is supposed to stop a migration.
k -n argocd patch application "$app" --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null || {
  echo "  the freeze was never applied: the patch itself failed." >&2
  echo "  This is not the ApplicationSet putting auto-sync back. Nothing has" >&2
  echo "  been changed." >&2; exit 1; }
frozen=yes
nap 30
# And a read that failed left `still` empty, which this reads as HELD -- a
# false pass on the only claim the drill exists to test.
still=$(k -n argocd get application "$app" -o jsonpath='{.spec.syncPolicy.automated}') \
  || die "cannot read back $app, so whether the freeze held is unknown."
if [ -z "$still" ]; then
  echo "  HELD after 30s. ignoreApplicationDifferences is doing its job."
else
  echo "  *** THE FREEZE DID NOT HOLD. The ApplicationSet put auto-sync back."
  echo "  *** Every break-glass instruction in docs/30-incident.md is false on"
  echo "  *** this cluster until that is fixed. Stopping here."
  give_it_back
  exit 1
fi

step "2. break it by hand, the way you would at 2am"
k -n "$ns" scale deploy "$svc" --replicas=$(( before + 1 )) >/dev/null \
  || die "the hand change never landed, so step 3 would be measuring nothing."
echo "  replicas $before -> $((before+1))"

step "3. wait, and confirm Argo CD does NOT undo it"
nap 60
now=$(k -n "$ns" get deploy "$svc" -o jsonpath='{.spec.replicas}') \
  || die "cannot read replicas back, so whether the change survived is unknown."
if [ "$now" = "$((before+1))" ]; then
  echo "  SURVIVED 60s. The change is yours until you give it back."
else
  echo "  *** REVERTED to $now. The freeze is not what you think it is."
  echo "  *** This is the same finding as THE FREEZE DID NOT HOLD, arriving one"
  echo "  *** step later: the Application still says frozen and Argo CD acted"
  echo "  *** anyway. Break-glass on this cluster is not what the procedure says."
  verdict=failed
fi

step "4. reconcile — hand the workload back"
# The same function the failure paths use, so the restore is written once and
# every exit from here on runs it.
give_it_back || exit 1
nap 30
after=$(k -n argocd get application "$app" \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision --no-headers) || {
  echo "  handed back, but the state could not be read afterwards. The message" >&2
  echo "  above says why; check $app by hand before writing the log." >&2; exit 1; }
sed 's/^/  /' <<<"$after"

step "5. did anything restart that should not have"
# `|| events=""` turned "the cluster refused" into "no events", and the line
# below then printed `none` -- which is the answer this step exists to give,
# arrived at without looking.
events=$(k -n "$ns" get events --sort-by=.lastTimestamp) || {
  echo "  COULD NOT READ EVENTS. This step is the whole point of the drill and" >&2
  echo '  it did not run; do not write "none" in the log.' >&2; exit 1; }
grep -iE 'killing|deleted' <<<"$events" | tail -5 | sed 's/^/  /' || echo "  none"

step "done"

# Steps 4 and 5 still ran: a failed drill is more useful with its log complete
# than truncated. But the exit code has to carry the verdict, because that is
# what a pipeline, a `&&`, and a person skimming for red will read.
if [ "$verdict" != ok ]; then
  echo
  echo "*** THE DRILL FAILED. Read step 3. The workload has been handed back and"
  echo "*** the log above is complete, but do not record this run as a pass:"
  echo "*** the freeze did not do what docs/30-incident.md says it does."
  exit 1
fi

cat <<EOF

Paste this into the audit, and write down the two numbers that are not in it:
  - how long Argo CD took to notice your commit (webhook, or the polling interval)
  - how long you spent looking for the right command

A procedure is as fast as the second number, not the first.
EOF
