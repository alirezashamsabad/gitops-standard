#!/usr/bin/env bash
# The worked example under examples/ is a real cluster repository, and this proves it.
#
# WHY IT IS NOT JUST A DIRECTORY. The standard deliberately has no cluster.yaml,
# no platform/ and no tenants/: the machine must contain no address, no customer
# name and no tool inventory, and hack/validate.py enforces that. So the example
# product half cannot live at the root, or it would become the inventory the
# machine is forbidden to have.
#
# Which leaves the failure this script exists to prevent: an example nothing
# checks. It is the first thing a newcomer copies, it rots the first time a rule
# changes, and it rots into something that looks authoritative.
#
# So: build a throwaway cluster repository out of the machine and examples/, and
# run the gates on it exactly as a real one would. If the example cannot pass the
# gates, it is not an example.
#
# Offline, like the other gates. Nothing here reaches a network.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd)

command -v helm >/dev/null || {
  echo "FATAL: helm is missing, so nothing can be rendered and this proves nothing." >&2
  echo "  Install it rather than skipping: a gate that steps aside reports green." >&2
  exit 1
}

[ -d examples ] || { echo "there is no examples/ directory"; exit 1; }

# Execution matters: the gates it runs are scripts. A directory that allows
# writing and not executing is the usual reason this fails somewhere strange.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-examples.XXXXXX") || exit 1
printf '#!/bin/sh\nexit 0\n' > "$WORK/.probe"; chmod +x "$WORK/.probe"
# CAPTURED, not silenced. What the shell says when it cannot execute a file is
# the whole diagnosis -- discarding it leaves "does not allow execution" as a
# guess about a mount the operator then has to find on their own.
if ! probe_said=$("$WORK/.probe" 2>&1); then
  rm -rf "$WORK"
  echo "FATAL: $WORK does not allow execution, so the gates below cannot run." >&2
  echo "  The shell said: $probe_said" >&2
  echo "  A noexec mount is the usual reason. Set TMPDIR somewhere that allows" >&2
  echo "  execution and run this again." >&2
  exit 1
fi
rm -f "$WORK/.probe"
trap 'rm -rf "$WORK"' EXIT

# -a, not -r: `cp -r` applies the umask to what it creates, so a host whose umask
# clears the execute bit hands over a tree whose gates cannot run.
for p in charts hack bootstrap README.md .gitignore .gitlab-ci.yml; do
  [ -e "$p" ] && cp -a "$p" "$WORK/"
done
cp -a examples/cluster.yaml "$WORK/cluster.yaml"
cp -a examples/platform "$WORK/platform"
cp -a examples/tenants  "$WORK/tenants"

# manifestsDir is a path from the repository root, and in the example tree it is
# written relative to examples/ so that a reader can follow it there. In the
# materialised repository that prefix is gone.
#
# Rewritten here rather than stored without the prefix, because a path that is
# wrong where it is READ is worse than one adjusted where it is USED: the example
# has to be followable by a person opening the file.
find "$WORK/tenants" -name config.yaml -exec \
  sed -i 's#^manifestsDir: examples/#manifestsDir: #' {} +

echo "materialised a cluster repository from examples/ in $WORK"
echo

rc=0
cd "$WORK"
for gate in "python3 hack/validate.py" "./hack/check-pins.sh" "./hack/render.sh"; do
  echo "--- $gate"
  if ! $gate; then
    rc=1
    echo "    ^ the example does not pass this gate"
  fi
  echo
done

# prove-checks.sh is NOT run here. It proves the machine, on a fixture it builds
# itself, and running it again against the same machine would measure nothing new
# and triple the time this takes.

if [ "$rc" -eq 0 ]; then
  echo "the worked example is a valid cluster repository"
else
  echo "THE WORKED EXAMPLE IS BROKEN. It is the first thing anyone copies."
fi
exit "$rc"
