#!/usr/bin/env bash
# Print the root Application for THIS cluster. Never applies it.
#
# The template lives in the machine and may contain no address; every value it
# needs is in cluster.yaml, which is product. This script is the join, and it
# prints to stdout so that what gets applied is something a human read first.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f cluster.yaml ] || { echo "no cluster.yaml here — run this from a cluster repo" >&2; exit 1; }

# python3 without PyYAML exits non-zero here, and `set -e` does not see it:
# the failure is inside a command substitution in sed's argument list, so sed
# runs with an empty value and succeeds. That printed a root Application with
# every field blank, and the only reason it was not applied is that kubectl
# happens to require repoURL. Assigned first, checked, then used.
get() {
  local out
  out=$(python3 -c "
import sys
try:
    import yaml
except ModuleNotFoundError:
    sys.exit('PyYAML is not installed. This reads cluster.yaml; install it '
             '(python3-pyyaml) rather than editing the template by hand.')
d = yaml.safe_load(open('cluster.yaml'))
for k in '$1'.split('.'):
    d = (d or {}).get(k)
if not d:
    sys.exit('cluster.yaml is missing $1')
print(d)") || { echo "render-root.sh: could not read $1 -- the message above says why" >&2
       exit 1; }
  printf '%s' "$out"
}

ARGOCD_NAMESPACE=$(get argocd.namespace)
REPO_URL=$(get argocd.repoURL)
TARGET_REVISION=$(get argocd.targetRevision)
DESTINATION_SERVER=$(get argocd.destinationServer)

sed -e "s|__ARGOCD_NAMESPACE__|$ARGOCD_NAMESPACE|g" \
    -e "s|__REPO_URL__|$REPO_URL|g" \
    -e "s|__TARGET_REVISION__|$TARGET_REVISION|g" \
    -e "s|__DESTINATION_SERVER__|$DESTINATION_SERVER|g" \
    bootstrap/root-application.yaml.tmpl
