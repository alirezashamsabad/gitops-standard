#!/usr/bin/env bash
# Break every rule on purpose, one at a time, and confirm the gate refuses it.
#
# A check that matches nothing passes silently and looks like coverage. Three
# were written that way in the previous structure before anyone noticed.
#
# The cases below prove two different things, and the second is the one that was
# missing when this slice was first submitted: that the GATE refuses bad input,
# and that what the machine PRODUCES is an Application Argo CD would accept.
# A gate can be perfect while the template it guards renders something unusable.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd)

# WHERE THE FIXTURE LIVES, AND WHY IT IS NOT /tmp
#
# `mktemp -d` puts it in /tmp, and /tmp on a hardened host is a separate mount
# with `noexec`. Nothing on a noexec filesystem is executable, whatever its
# mode says -- `os.access(f, os.X_OK)` returns false for every one of them.
#
# So the copy failed `check_scripts_are_executable` for all eleven scripts, on
# a checkout where validate, running in the same job as the same user, found
# nothing wrong. The harness was measuring the filesystem it had chosen for
# itself and reporting the result as findings about the repository. The first
# attempt at a fix -- `cp -a` instead of `cp -r`, to stop the umask clearing
# the bit -- was a correct change for a different cause, and changed nothing
# here, because the bits were never the problem.
#
# The workspace is probed rather than assumed: write a script, run it, keep the
# directory only if it ran. Candidates in order, and every one of them can be
# wrong on some host, which is exactly why there is a probe and not a choice.
make_work() {
  local base w
  for base in "${PROVE_TMPDIR:-}" "$(dirname "$SRC")" "$HOME" "${TMPDIR:-/tmp}"; do
    [ -n "$base" ] && [ -d "$base" ] && [ -w "$base" ] || continue
    w=$(mktemp -d "$base/prove-checks.XXXXXX") || continue
    printf '#!/bin/sh\nexit 0\n' > "$w/.probe"
    chmod +x "$w/.probe"
    # The failure IS the answer here, the same exemption `command -v` gets.
    if "$w/.probe" 2>/dev/null; then
      rm -f "$w/.probe"
      printf '%s' "$w"
      return 0
    fi
    rm -rf "$w"
  done
  return 1
}
WORK=$(make_work) || {
  echo "ERROR: nowhere to put the fixture." >&2
  echo "  This needs a directory that is writable AND allows execution. It tried" >&2
  echo "  \$PROVE_TMPDIR, $(dirname "$SRC"), \$HOME and \$TMPDIR, and ran a script" >&2
  echo "  in each -- none of them ran it. A noexec mount is the usual reason." >&2
  echo "  Set PROVE_TMPDIR to somewhere that works and run this again." >&2
  exit 1
}
trap 'rm -rf "$WORK"' EXIT
echo "fixture: $WORK"
# -a, not -r: `cp -r` applies the umask to what it creates, so a host whose
# umask clears the execute bit hands the fixture over without it. Not the cause
# of the failure above, and still the right way to copy a tree whose modes are
# part of what is being checked.
cp -a "$SRC"/. "$WORK"/; cd "$WORK"

# This proves the MACHINE. Whatever this cluster happens to run is not part of
# the fixture, and leaving it in means the baseline is different on every repo
# the script is copied to -- on a cluster with a real tool it disagreed with the
# fixture's cluster.yaml and reported six errors before a single case ran.
rm -rf platform tenants shared
pass=0; fail=0

cat > cluster.yaml <<'EOF'
metadata: {clusterName: c, tier: nonprod}
argocd: {namespace: argocd, repoURL: "ssh://git@host/x.git", targetRevision: main, destinationServer: https://kubernetes.default.svc}
allowedImageRegistries: [reg.example]
chartRepos: {tools: "https://charts.example/"}
platformNamespaces: [demo-ns]
tenants: [{name: t1, environments: {dev: t1-dev, qa: t1-qa}}]
sharedScopes: []
network: {gatewayClass: c, gatewayName: gw, gatewayNamespace: gwns, baseDomain: example.test}
EOF
mkdir -p platform/demo
cat > platform/demo/component.yaml <<'EOF'
namespace: demo-ns
chart: {repo: tools, name: demo, version: "1.0.0"}
sync: {automated: true, selfHeal: true, prune: false}
EOF
printf -- '- reg.example/demo:1.0.0\n' > platform/demo/images.yaml
: > platform/demo/RUNBOOK.md

mkdir -p tenants/t1/dev/svc
cat > tenants/t1/dev/env.yaml <<'EOF'
tenant: t1
env: dev
namespace: t1-dev
network: {enabled: false, profiles: []}
EOF
cat > tenants/t1/dev/svc/config.yaml <<'EOF'
namespace: t1-dev
chart: {repo: tools, name: svc, version: "1.0.0"}
image: {repository: reg.example/svc, tag: "v1"}
sync: {automated: true, selfHeal: true, prune: true}
EOF
: > tenants/t1/dev/svc/values.yaml

# A SECOND environment, because one is not enough to prove anything about
# environments. The hostname rule refuses `dev-qa-...` by knowing that `qa` is
# an environment name, and a fixture with only `dev` cannot tell the difference
# between that and any other word.
mkdir -p tenants/t1/qa
cat > tenants/t1/qa/env.yaml <<'EOF'
tenant: t1
env: qa
namespace: t1-qa
network: {enabled: false, profiles: []}
EOF

# Layer 1 of tenantValueLayers. The fixture had no value layers at all, which
# made it a tree no real cluster looks like: every workload here pulls from a
# private mirror and nothing said so. That is exactly the shape that shipped
# four Deployments unable to pull.
mkdir -p tenants/_shared
cat > tenants/_shared/values.yaml <<'EOF'
deployment:
  imagePullSecrets:
    - name: regcred
EOF

# THE PAGES THE DOC CASES MUTATE, BUILT RATHER THAN BORROWED.
#
# docs/ is machine and is deliberately NOT merged into cluster repositories, so
# four cases below had a fixture in this repository and nothing to edit in the
# other one. They failed there -- on the absence of a file, reported as four
# broken rules.
#
# That is the /tmp-with-noexec lesson for the fourth time: a harness that reads
# its subject out of whatever tree it was copied into measures the tree, not the
# rules. Every other part of this fixture is written here for exactly that
# reason; these two pages were the last thing still borrowed.
#
# Minimal on purpose. Each carries only the line its cases need, so the case
# count is now identical in both repositories -- and a count that silently
# differs between two runs is the thing this avoids.
mkdir -p docs
cat > docs/05-vault-eso.md <<'EOF'
# vault and external secrets

Seeding is bootstrap/seed-vault-kv.sh. It reads every name out of the
repository and takes every value from a prompt that does not echo.
EOF
cat > docs/30-incident.md <<'EOF'
# incident

Hand the sync policy back exactly as it was. The placeholder is the point: no
page knows what a given workload declared, so it is read off the Application
before the freeze and put back verbatim.

  kubectl -n argocd patch application <app> --type merge -p '{"spec":{"syncPolicy":{"automated":<what step 1 printed>}}}'
EOF

base=$(python3 hack/validate.py 2>&1)
echo "baseline: $(tail -1 <<<"$base")"
if ! grep -q "0 error" <<<"$base"; then
  echo "  FATAL: baseline is not clean, every case below is meaningless"
  echo "$base"; exit 1
fi
echo "  baseline clean"; echo

# Restore by replacing whole subtrees, not a list of files.
#
# A named list cannot undo a mutation that CREATES a file: a case that adds a
# workload folder leaves it behind, and every case after it runs against a tree
# that already has an error in it. Replacing whole subtrees undoes anything.
PRISTINE="$WORK/.pristine"
# bootstrap was missing here until a case mutated it. Nothing had, so the gap
# was invisible: the first case to append a line to bootstrap/vault-day0.sh
# left it there, and the next case ran against a tree that already had the
# error in it and reported the check broken. Exactly the failure the comment
# above describes, in the list the comment above is attached to.
MUTABLE_TREES=(platform tenants shared charts hack docs bootstrap cluster.yaml .gitlab-ci.yml)

snapshot() {
  [ -d "$PRISTINE" ] && return 0
  mkdir -p "$PRISTINE"
  for t in "${MUTABLE_TREES[@]}"; do
    [ -e "$t" ] && cp -a "$t" "$PRISTINE/" || true
  done
}
restore() {
  for t in "${MUTABLE_TREES[@]}"; do
    rm -rf "${t:?}"
    [ -e "$PRISTINE/$(basename "$t")" ] && cp -a "$PRISTINE/$(basename "$t")" "$t" || true
  done
}

case_() {
  local name="$1" expect="$2" mut="$3" out
  snapshot
  bash -c "$mut"
  # NOT `validate | grep`. pipefail is on and validate exits 1 whenever it
  # refuses something, so the pipeline reported failure even when grep matched --
  # which showed all sixteen checks as broken while every one had fired.
  out=$(python3 hack/validate.py 2>&1)
  if grep -qF -- "$expect" <<<"$out"; then
    printf '  PASS  %s\n' "$name"; pass=$((pass+1))
  else
    printf '  FAIL  %s   (expected: %s)\n' "$name" "$expect"; fail=$((fail+1))
    grep -E '^(ERROR|WARN)' <<<"$out" | sed 's/^/          /'
  fi
  restore
}

echo "component.yaml contract:"
case_ "namespace empty"        "namespace is required"          "sed -i 's/^namespace: .*/namespace: \"\"/' platform/demo/component.yaml"
case_ "wave key present"       "is not a valid key"             "printf 'wave: 10\n' >> platform/demo/component.yaml"
# YAML replaces a duplicate key rather than merging it, and three real values
# files in this estate had been assembled by appending a second block with the
# same top-level keys. Everything above was discarded, on screen the whole time.
case_ "a key repeated in the same map" "repeats the key" \
  "printf 'namespace: somewhere-else\n' >> platform/demo/component.yaml"
case_ "top-level path key"     "is not a valid key"             "printf 'manifestsDir: x\npath: y\n' >> platform/demo/component.yaml"
case_ "no delivery kind"       "exactly one of chart"           "sed -i '/^chart:/d' platform/demo/component.yaml"
case_ "two delivery kinds"     "exactly one of chart"           "printf 'manifestsDir: platform/demo/manifests\n' >> platform/demo/component.yaml"
case_ "chart.repo unknown key" "is not a key in cluster.yaml"   "sed -i 's/repo: tools/repo: nowhere/' platform/demo/component.yaml"
case_ "sync.prune omitted"     "sync.prune must be written"     "sed -i 's/^sync: .*/sync: {automated: true, selfHeal: true}/' platform/demo/component.yaml"
case_ "requires a missing dir" "does not exist on this cluster" "printf 'requires: [ghost]\n' >> platform/demo/component.yaml"
case_ "stateful with prune"    "stateful with sync.prune true"  "printf 'stateful: true\n' >> platform/demo/component.yaml; sed -i 's/prune: false/prune: true/' platform/demo/component.yaml"
case_ "image outside registry" "allowedImageRegistries"         "printf -- '- evil-registry/demo:1\n' > platform/demo/images.yaml"
# An absent optional file is a warning, never a parse error. Both messages used
# to appear at once, disagreeing about whether it mattered.
case_ "images.yaml absent"     "the air-gap mirror list for this tool is unstated" \
  "rm -f platform/demo/images.yaml"

echo; echo "derived AppProject destinations:"
case_ "platformNamespaces stale"   "does not match platform" "sed -i 's/^platformNamespaces: .*/platformNamespaces: [wrong-ns]/' cluster.yaml"
# The same shape one level down: a tool creating a cluster-scoped kind that
# cluster.yaml does not declare. Argo refuses that object and names neither the
# tool nor this list.
case_ "a cluster-scoped kind not declared" "platformClusterResources does not name" \
  "sed -i '/^chart:/d' platform/demo/component.yaml; printf 'manifestsDir: platform/demo/manifests\n' >> platform/demo/component.yaml; mkdir -p platform/demo/manifests; printf 'apiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata:\n  name: x\n' > platform/demo/manifests/x.yaml"
case_ "platformNamespaces missing" "does not match platform" "sed -i 's/^platformNamespaces: .*/platformNamespaces: []/' cluster.yaml"

echo; echo "env.yaml contract:"
case_ "tenant/env disagree with folder" "The folder is the truth" \
  "sed -i 's/^env: dev/env: qa/' tenants/t1/dev/env.yaml"
case_ "namespace not in cluster.yaml"   "is not what cluster.yaml:tenants says" \
  "sed -i 's/^namespace: t1-dev/namespace: elsewhere/' tenants/t1/dev/env.yaml"
case_ "network.enabled omitted"         "must be written explicitly" \
  "sed -i 's/^network: .*/network: {profiles: []}/' tenants/t1/dev/env.yaml"
case_ "profiles list not derived"       "is a view of the folders" \
  "sed -i 's/profiles: \\[\\]/profiles: [redis]/' tenants/t1/dev/env.yaml"
case_ "workload names an unknown profile" "is a view of the folders" \
  "printf 'networkProfile: ghost\n' >> tenants/t1/dev/svc/config.yaml"
# Both lists agreeing on a name whose file does not exist is a different hole
# from the two disagreeing, and the aggregation case above cannot reach it.
case_ "profile agreed on but has no file"  "has no file in" \
  "printf 'networkProfile: ghost\n' >> tenants/t1/dev/svc/config.yaml; sed -i 's/profiles: \\[\\]/profiles: [ghost]/' tenants/t1/dev/env.yaml"
case_ "workload folder called baseline"    "may not be called" \
  "mkdir -p tenants/t1/dev/baseline && cp tenants/t1/dev/svc/config.yaml tenants/t1/dev/baseline/config.yaml && : > tenants/t1/dev/baseline/values.yaml"

echo; echo "httpRoute:"
ROUTE='httpRoute:\n  enabled: true\n  hostnames: [dev-svc.example.test]\n  parentRefs:\n    - name: gw\n      namespace: gwns\n'
case_ "hostname outside baseDomain"   "does not end in" \
  "printf '$ROUTE' | sed 's/svc.example.test/svc.example.tes/' >> tenants/t1/dev/svc/values.yaml"
case_ "no hostnames at all"           "matches every host" \
  "printf 'httpRoute:\n  enabled: true\n  hostnames: []\n  parentRefs: [{name: gw, namespace: gwns}]\n' >> tenants/t1/dev/svc/values.yaml"
case_ "parentRef names another gateway" "is not cluster.yaml:network.gatewayName" \
  "printf '$ROUTE' | sed 's/name: gw$/name: other/' >> tenants/t1/dev/svc/values.yaml"
case_ "parentRef in another namespace"  "is not cluster.yaml:network.gatewayNamespace" \
  "printf '$ROUTE' | sed 's/namespace: gwns/namespace: default/' >> tenants/t1/dev/svc/values.yaml"
case_ "route with no parentRefs"        "attaches to no Gateway" \
  "printf 'httpRoute:\n  enabled: true\n  hostnames: [dev-svc.example.test]\n' >> tenants/t1/dev/svc/values.yaml"
# THE CASE THE OTHER FIVE CANNOT REACH. All of them write to the workload's own
# file, so a check that read only that file would pass every one of them. Here
# the route is enabled in the workload and the bad hostname is set two layers
# up, which is exactly what merging the layers is for.
case_ "bad hostname set in a shared layer" "does not end in" \
  "mkdir -p tenants/_shared && printf 'httpRoute:\n  hostnames: [dev-svc.example.tes]\n' >> tenants/_shared/values.yaml && printf 'httpRoute:\n  enabled: true\n  parentRefs: [{name: gw, namespace: gwns}]\n' >> tenants/t1/dev/svc/values.yaml"
case_ "baseDomain empty with a route"      "baseDomain is empty" \
  "sed -i 's/baseDomain: example.test/baseDomain: \"\"/' cluster.yaml; printf '$ROUTE' >> tenants/t1/dev/svc/values.yaml"

echo; echo "workload config.yaml contract:"
case_ "namespace not the env's"       "is not the namespace of the environment" \
  "sed -i 's/^namespace: t1-dev/namespace: elsewhere/' tenants/t1/dev/svc/config.yaml"
case_ "image outside the registries"  "allowedImageRegistries" \
  "sed -i 's|repository: reg.example/svc|repository: docker-hub/svc|' tenants/t1/dev/svc/config.yaml"
case_ "image without a tag"           "image.tag is required" \
  "sed -i 's/, tag: \"v1\"//' tenants/t1/dev/svc/config.yaml"
case_ "workload sync.prune omitted"   "sync.prune must be written" \
  "sed -i 's/^sync: .*/sync: {automated: true, selfHeal: true}/' tenants/t1/dev/svc/config.yaml"
case_ "workload chart.repo unknown"   "is not a key in cluster.yaml" \
  "sed -i 's/repo: tools/repo: nowhere/' tenants/t1/dev/svc/config.yaml"
case_ "workload values.yaml missing"  "values.yaml is required beside" \
  "rm -f tenants/t1/dev/svc/values.yaml"
case_ "workload top-level path key"   "shadows the git generator" \
  "printf 'path: x\n' >> tenants/t1/dev/svc/config.yaml"
case_ "chart workload with no image"  "image is required for a chart workload" \
  "sed -i '/^image:/d' tenants/t1/dev/svc/config.yaml"
case_ "chart version missing"         "chart.version is required" \
  "sed -i 's/, version: \"1.0.0\"//' tenants/t1/dev/svc/config.yaml"
case_ "stateful workload with prune" "stateful with sync.prune true" \
  "printf 'stateful: true\n' >> tenants/t1/dev/svc/config.yaml"
case_ "createNamespace in a workload" "is not a valid key" \
  "printf 'createNamespace: true\n' >> tenants/t1/dev/svc/config.yaml"
case_ "image not injected into chart" "never injects the image" \
  "sed -i '/name: deployment.image.tag/,+1d' charts/cluster-config/templates/appsets.yaml"

echo; echo "render contract - what the machine PRODUCES:"
case_ "chart mirror not in sourceRepos" "does not permit" \
  "sed -i '/values .Values.chartRepos/,+2d' charts/cluster-config/templates/projects.yaml"
# Only the emitted line. A blanket /ref: values/d also deletes the comment
# line that closes a Go template block, and the chart then fails to render --
# which is a different failure, and would have proved nothing about this check.
case_ "ref: values dropped"             "without a second source" \
  "sed -i 's/^      ref: values$/      ref: notvalues/' charts/cluster-config/templates/appsets.yaml"
case_ "chart.repo lookup not baked"     "never resolves chart.repo" \
  "sed -i 's@- repoURL: {{ \$v | quote }}@- repoURL: \"BAKED-NOTHING\"@' charts/cluster-config/templates/appsets.yaml"
# 320 bytes reached a live cluster and was refused by the API, after the other
# projects and every ApplicationSet had already been created.
# `&` repeats the whole match, so the mutation needs no quoting and no command
# substitution -- five copies of a 74-byte description is 370.
case_ "an AppProject description over 255 bytes" "the API refuses anything over" \
  "sed -i 's|Namespaces, quotas.*|&&&&&|' charts/cluster-config/templates/projects.yaml"
# The indentation that reached a live cluster. Both sourcePatch includes go
# back to indent 2, which is exactly the state that generated no Applications.
# The two halves of the same list. Either side losing a file is the state that
# reached the cluster: render.sh saying ok about a chart Argo could not render.
# An unguarded parameter, which is the state cert-manager refused and the other
# two charts accepted in silence.
case_ "a helm parameter outside the image guard" "outside the image guard" \
  "sed -i '0,/^        parameters:\$/s@^        parameters:\$@        parameters:\n          - name: applicationName\n            value: x@' charts/cluster-config/templates/appsets.yaml"
case_ "localChart gets no values in the patch" "gives a localChart no" \
  "sed -i '/values\\/cluster.yaml/d' charts/cluster-config/templates/appsets.yaml"
case_ "render.sh renders without cluster.yaml" "proves something the cluster will not do" \
  "sed -i 's@-f \"\$CLUSTER\" @@' hack/render.sh"
# Two lines of a values file produced a StatefulSet the API server refuses, and
# between the commit and the cluster nothing looked at the rendered object.
case_ "render.sh stops reading what it rendered" "does not read back what it rendered" \
  "sed -i '/^echo \"rendered objects:\"\$/,/^PY\$/d' hack/render.sh"
# The half that matters. The scan above can be perfect and still see none of
# vault, cert-manager, external-secrets or redis-operator, because render.sh
# leaves remote charts alone unless CI asks for them.
case_ "CI renders no remote chart" "does not set WITH_REMOTE=1" \
  "sed -i '/WITH_REMOTE: \"1\"/d' .gitlab-ci.yml"
case_ "templatePatch keys level with spec" "at the top level" \
  "sed -i 's@indent 4 }}@indent 2 }}@' charts/cluster-config/templates/appsets.yaml"
case_ "no templatePatch at all"         "has no templatePatch" \
  "sed -i 's/^  templatePatch: |/  xtemplatePatch: |/' charts/cluster-config/templates/appsets.yaml"

case_ "bare .chart test under missingkey" "Use hasKey" \
  "sed -i 's/if hasKey \\. [^}]*chart[^}]*}}/if .chart }}/' charts/cluster-config/templates/appsets.yaml"
case_ "tenant value layer dropped"        "does not mount the value layer" \
  "sed -i '/range .layers/,+2d' charts/cluster-config/templates/appsets.yaml"
case_ "ignoreMissingValueFiles dropped"   "without ignoreMissingValueFiles" \
  "sed -i '/ignoreMissingValueFiles/d' charts/cluster-config/templates/appsets.yaml"

case_ "platform stops creating namespaces" "never emits CreateNamespace=true" \
  "sed -i '/- CreateNamespace=true/d' charts/cluster-config/templates/appsets.yaml"
case_ "tenants start creating namespaces"  "emits CreateNamespace=true" \
  "sed -i 's/\"createNamespace\" false/\"createNamespace\" true/' charts/cluster-config/templates/appsets.yaml"
case_ "createNamespace key in a component" "is not a valid key" \
  "printf 'createNamespace: true\n' >> platform/demo/component.yaml"

echo; echo "ApplicationSet invariants:"
case_ "no ignoreApplicationDifferences" "no ignoreApplicationDifferences" \
  "sed -i '/^ignoreApplicationDifferences:/,+2d' charts/cluster-config/templates/appsets.yaml"
case_ "appsSync not create-update"      "not create-update" \
  "sed -i 's/applicationsSync: create-update/applicationsSync: sync/' charts/cluster-config/templates/appsets.yaml"
case_ "preserveResourcesOnDeletion off" "does not set" \
  "sed -i 's/preserveResourcesOnDeletion: true/preserveResourcesOnDeletion: false/' charts/cluster-config/templates/appsets.yaml"
case_ "RespectIgnoreDifferences dropped" "does not set" \
  "sed -i '/RespectIgnoreDifferences=true/d' charts/cluster-config/values.yaml"

echo; echo "pins (a different gate, so its own harness):"
snapshot
# NOT `check-pins | grep`. pipefail is on and this gate exits 1 whenever it
# refuses something, so the pipeline reports failure even when grep matched.
# The same trap has now caught this script three times; capture, then match.
pins_out() { ./hack/check-pins.sh 2>&1 || true; }
printf -- '- reg.example/demo:SET-tag\n' > platform/demo/images.yaml
if grep -q 'PLACEHOLDER' <<<"$(pins_out)"; then
  echo "  PASS  placeholder tag refused"; pass=$((pass+1))
else
  echo "  FAIL  placeholder tag refused"; fail=$((fail+1))
fi
printf -- '- reg.example/demo:v0.0.0-dev\n' > platform/demo/images.yaml
if grep -q 'PLACEHOLDER VERSION' <<<"$(pins_out)"; then
  echo "  PASS  v0.0.0 refused"; pass=$((pass+1))
else
  echo "  FAIL  v0.0.0 refused"; fail=$((fail+1))
fi
printf -- '- reg.example/demo:latest\n' > platform/demo/images.yaml
if grep -q 'NOT PINNED' <<<"$(pins_out)"; then
  echo "  PASS  floating tag refused"; pass=$((pass+1))
else
  echo "  FAIL  floating tag refused"; fail=$((fail+1))
fi
# `develop` is exactly as mutable as `main` and was not on the list, which is
# the argument against lists. A tag with no digit in it is a channel name.
printf -- '- reg.example/demo:develop\n' > platform/demo/images.yaml
if grep -q 'NOT A VERSION' <<<"$(pins_out)"; then
  echo "  PASS  a branch tag refused"; pass=$((pass+1))
else
  echo "  FAIL  a branch tag refused"; fail=$((fail+1))
fi
printf -- '- reg.example/demo:alpine\n' > platform/demo/images.yaml
if grep -q 'NOT A VERSION' <<<"$(pins_out)"; then
  echo "  PASS  a base-image channel refused"; pass=$((pass+1))
else
  echo "  FAIL  a base-image channel refused"; fail=$((fail+1))
fi
# The digit rule must not refuse a digest pin, which is the strongest pin there
# is and contains no dots.
printf -- '- reg.example/demo@sha256:9f2c4e1a8b7d6c5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e\n' > platform/demo/images.yaml
if grep -q 'NOT A VERSION' <<<"$(pins_out)"; then
  echo "  FAIL  a digest pin is accepted"; fail=$((fail+1))
else
  echo "  PASS  a digest pin is accepted"; pass=$((pass+1))
fi
restore
# THE LOOP THAT READS THE LINE A PIPELINE WRITES. A branch tag here means the
# running image changes with no commit.
# Rewritten by a parser, not by sed. The fixture writes `image:` as a one-line
# flow mapping, so `s/^  tag: /` matched nothing and the case reported the rule
# broken while the tree it was testing still said v1.
python3 -c "import yaml,io
d=yaml.safe_load(open('tenants/t1/dev/svc/config.yaml'))
d['image']['tag']='develop'
yaml.safe_dump(d, open('tenants/t1/dev/svc/config.yaml','w'))"

if grep -q 'NOT A VERSION' <<<"$(pins_out)"; then
  echo "  PASS  a branch tag in a workload's config refused"; pass=$((pass+1))
else
  echo "  FAIL  a branch tag in a workload's config refused"; fail=$((fail+1))
fi
restore
# images.yaml was read under platform/ only, so a tenant workload's mirror list
# -- the file whose entire subject is which images must exist -- was never
# opened by the gate about whether an image is pinned.
mkdir -p tenants/t1/dev/svc
printf -- '- reg.example/other:latest\n' > tenants/t1/dev/svc/images.yaml
if grep -q 'NOT PINNED' <<<"$(pins_out)"; then
  echo "  PASS  a tenant images.yaml is read at all"; pass=$((pass+1))
else
  echo "  FAIL  a tenant images.yaml is read at all"; fail=$((fail+1))
fi
restore

echo; echo "sync-machine, which carries the machine one way:"
# The mechanism the whole design rests on. Two trees that are meant to be
# identical and are compared by eye diverge quietly, and nothing downstream
# reports it.
sm_target="$WORK/.sync-target"
rm -rf "$sm_target"
sm_out=$(./hack/sync-machine.sh "$sm_target" --genesis 2>&1); sm_rc=$?
if [ "$sm_rc" -eq 0 ] && [ -f "$sm_target/hack/validate.py" ] && [ -d "$sm_target/.git" ]; then
  echo "  PASS  --genesis creates a repository with the machine in it"; pass=$((pass+1))
else
  echo "  FAIL  --genesis creates a repository with the machine in it (exit $sm_rc)"; fail=$((fail+1))
fi
# NEITHER docs/ NOR examples/ TRAVELS. Both are machine -- the gates check them,
# MACHINE lists docs and check-examples.sh holds examples honest -- and both stay
# with the standard: the pages describe the structure, which has one home, and a
# cluster repository has its own real product half instead of a worked one.
#
# Carrying examples/ would be worse than untidy. Its cluster.yaml has tenants and
# addresses in it, and a second one of those beside the real one is a file
# somebody eventually edits by mistake.
for travels_not in docs examples; do
  if [ -e "$sm_target/$travels_not" ]; then
    echo "  FAIL  $travels_not/ does not travel"; fail=$((fail+1))
  else
    echo "  PASS  $travels_not/ does not travel"; pass=$((pass+1))
  fi
done
# A second --genesis onto the same path is a different intention from an update,
# and conflating them is how a repository gets half-overwritten.
sm_out=$(./hack/sync-machine.sh "$sm_target" --genesis 2>&1); sm_rc=$?
if [ "$sm_rc" -ne 0 ] && grep -q "already exists" <<<"$sm_out"; then
  echo "  PASS  --genesis onto something that exists is refused"; pass=$((pass+1))
else
  echo "  FAIL  --genesis onto something that exists is refused (exit $sm_rc)"; fail=$((fail+1))
fi
# THE ONE THAT MATTERS. An edit to the machine inside a cluster repository is the
# mistake this arrangement exists to prevent, and copying over it destroys the
# edit with no record that it was ever there.
git -C "$sm_target" add -A >/dev/null
git -C "$sm_target" -c user.email=p@x -c user.name=p commit -qm "machine" >/dev/null
printf '\n# edited in the wrong repository\n' >> "$sm_target/hack/validate.py"
sm_out=$(./hack/sync-machine.sh "$sm_target" --write 2>&1); sm_rc=$?
if [ "$sm_rc" -ne 0 ] && grep -q "the machine is modified" <<<"$sm_out"; then
  echo "  PASS  a machine edited in the target stops the copy"; pass=$((pass+1))
else
  echo "  FAIL  a machine edited in the target stops the copy (exit $sm_rc)"; fail=$((fail+1))
fi
if grep -q "edited in the wrong repository" "$sm_target/hack/validate.py"; then
  echo "  PASS  and the edit is still there afterwards"; pass=$((pass+1))
else
  echo "  FAIL  and the edit is still there afterwards"; fail=$((fail+1))
fi
git -C "$sm_target" checkout -- hack/validate.py
# A dirty PRODUCT half is the operator's own business and must not block a merge.
mkdir -p "$sm_target/tenants/t/dev/svc"
printf 'namespace: t-dev\n' > "$sm_target/tenants/t/dev/svc/config.yaml"
sm_out=$(./hack/sync-machine.sh "$sm_target" 2>&1); sm_rc=$?
if [ "$sm_rc" -eq 0 ]; then
  echo "  PASS  a dirty product half does not block it"; pass=$((pass+1))
else
  echo "  FAIL  a dirty product half does not block it (exit $sm_rc)"; fail=$((fail+1))
fi
# Content, not timestamps. Comparing mtimes reports unchanged files as changed
# after any hand copy, which teaches the reader to skim the one list that stands
# between a merge and an overwrite.
touch "$sm_target"/hack/*.py "$sm_target"/hack/*.sh
sm_out=$(./hack/sync-machine.sh "$sm_target" 2>&1)
if grep -q "already identical" <<<"$sm_out"; then
  echo "  PASS  a touched file is not reported as a change"; pass=$((pass+1))
else
  echo "  FAIL  a touched file is not reported as a change"; fail=$((fail+1))
  sed 's/^/          /' <<<"$sm_out" | head -6
fi
# Not a git repository at all: a machine merge is a commit there, so there has to
# be one to commit into.
rm -rf "$sm_target/.git"
sm_out=$(./hack/sync-machine.sh "$sm_target" --write 2>&1); sm_rc=$?
if [ "$sm_rc" -ne 0 ] && grep -q "not a git repository" <<<"$sm_out"; then
  echo "  PASS  a target that is not a git repository is refused"; pass=$((pass+1))
else
  echo "  FAIL  a target that is not a git repository is refused (exit $sm_rc)"; fail=$((fail+1))
fi
rm -rf "$sm_target"
restore

echo; echo "check-mirror over a registry that did not answer:"
# THE FAILURE THIS TOOL IS SHAPED AROUND. The fixture's registry is a name that
# does not resolve, which is what a dropped VPN looks like from here. A tool that
# treats "could not look" as "not there" prints every declared image as missing --
# twenty-eight alarms, none of them true, on the day the network is already the
# problem. compare-live.sh was hardened against exactly this.
mirror_out=$(python3 hack/check-mirror.py 2>&1); mirror_rc=$?
if [ "$mirror_rc" -eq 2 ] && grep -q "CANNOT ANSWER" <<<"$mirror_out"; then
  echo "  PASS  it refuses, with an exit code of its own"; pass=$((pass+1))
else
  echo "  FAIL  it refuses, with an exit code of its own (exit $mirror_rc)"; fail=$((fail+1))
fi
if grep -qE "^  (MISS|ok) " <<<"$mirror_out"; then
  echo "  FAIL  it says nothing about images it could not look up"; fail=$((fail+1))
  sed 's/^/          /' <<<"$mirror_out" | head -4
else
  echo "  PASS  it says nothing about images it could not look up"; pass=$((pass+1))
fi
# An empty tree has nothing missing, which reads as everything being fine.
# NOT `check-mirror | grep`. pipefail is on and this tool exits 2 whenever it
# refuses, so the pipeline reports failure even when grep matched -- which is the
# mistake the case_ helper above carries a paragraph about. Capture first, grep
# the variable.
rm -rf platform tenants shared
mirror_out=$(python3 hack/check-mirror.py 2>&1 || true)
if grep -q "declares no images and no charts" <<<"$mirror_out"; then
  echo "  PASS  an empty repository is refused, not reported clean"; pass=$((pass+1))
else
  echo "  FAIL  an empty repository is refused, not reported clean"; fail=$((fail+1))
fi
restore
# No mirror declared is not the same as a mirror with nothing in it.
sed -i 's/^allowedImageRegistries:.*/allowedImageRegistries: []/' cluster.yaml
mirror_out=$(python3 hack/check-mirror.py 2>&1 || true)
if grep -q "no allowedImageRegistries" <<<"$mirror_out"; then
  echo "  PASS  no mirror declared is refused"; pass=$((pass+1))
else
  echo "  FAIL  no mirror declared is refused"; fail=$((fail+1))
fi
restore

echo; echo "nothing is silenced:"
case_ "a silenced failure in the machine" "silences a failure" \
  "printf 'true 2>/dev/null\n' >> hack/check-pins.sh"

echo; echo "the CI file:"
case_ "CI does not parse"          "does not parse" \
  "printf 'broken: [\n' >> .gitlab-ci.yml"
case_ "HEAD~ with a depth-1 clone" "has no parent commit" \
  "sed -i 's/GIT_DEPTH: \"2\"/GIT_DEPTH: \"1\"/' .gitlab-ci.yml"
case_ "a gate that cannot fail"    "cannot fail" \
  "printf '\nnever:\n  stage: gate\n  when: manual\n  allow_failure: true\n  script: [true]\n' >> .gitlab-ci.yml"
# The machine's definition and the shelf pattern are the same list twice, so the
# drift to expect is this: a file enters the machine, the pattern does not learn
# it, and the shelf refuses a correct machine commit.
case_ "shelf allowlist misses a machine file" "is part of the machine and the shelf" \
  "sed -i 's/|\\\\.gitignore)\\$/)$/' .gitlab-ci.yml"
# The other half of the same list: the product branch read four directories and
# not the root files, so a commit with a product subject could edit README.md,
# .gitignore, or this gate. One pattern, both directions, or neither is a gate.
case_ "product branch stops reading the pattern" "may change the machine" \
  "sed -i '/bad=..grep -E /d' .gitlab-ci.yml"
# Clause 2 of the same check. A second assignment leaves the first intact, so
# the name check and the both-directions check stay green while the branch that
# reads the later one matches a different list.
case_ "machine_pattern assigned twice" "assigns machine_pattern 2 times" \
  "sed -i '/machine_pattern=/p' .gitlab-ci.yml"

echo; echo "an exit code that is data:"
# The shape that was in vault-day0.sh three times. pipefail plus `vault status`
# exiting 2 while sealed means grep's match is thrown away, and a sealed,
# initialised Vault reads as uninitialised -- so the ceremony runs operator init
# against it.
case_ "vault status piped into grep" "pipes \`vault status\` into something" \
  "printf 'if vx a b \"\" vault status | grep -q x; then :; fi\n' >> bootstrap/vault-day0.sh"
# Clause 2, and the reason this case exists twice. A check that matches the
# second character of `||` refuses the very helper written to satisfy it. A
# fallback is not a pipeline.
case_ "|| true is not a pipeline" "0 error" \
  "printf 'vx a b \"\" vault status || true\n' >> bootstrap/vault-day0.sh"

echo; echo "key material written through, not beside:"
# The exact two commands that were in vault-day0.sh, and the exact shape that
# came within one kubectl wait of emptying /root/vault-keys/transit-init.json on
# a live cluster: the redirect is on the CONTINUATION line, which is why a
# line-at-a-time check would have read both halves and refused neither.
case_ "operator init redirected into the key file" "redirects \`vault operator init\` straight into a file" \
  "printf 'vx a b \"\" vault operator init \\\n  -format=json > \"\$KEYDIR/k.json\"\n' >> bootstrap/vault-day0.sh"

echo; echo "an exec that eats the loop it is in:"
# The exact shape that submitted one unseal key of three and left transit sealed
# at 1/3, with `|| true` hiding it and the failure surfacing two steps later as
# a 503 that named the state and not the cause.
case_ "exec inside a loop reading a file" "runs an exec inside a loop that reads from a file" \
  "printf 'while read -r k; do\n  vx a b \"\" vault operator unseal \"\$k\"\ndone < \"\$UK\"\n' >> bootstrap/vault-day0.sh"
# The same loop with the exec's stdin closed is the documented way out, and must
# not be refused -- otherwise the only fix the message offers is one the gate
# rejects.
case_ "the same loop with </dev/null" "0 error" \
  "printf 'while read -r k; do\n  vx a b \"\" vault operator unseal \"\$k\" </dev/null\ndone < \"\$UK\"\n' >> bootstrap/vault-day0.sh"
# Clause 3. The wrapper's name is not knowable in advance -- vault-day0.sh
# calls it vx and seed-vault-kv.sh calls it v -- so the check reads the wrapper
# names out of each file. Hardcoding vx left it blind to the second script the
# day that script was written.
case_ "a differently named exec wrapper" "runs an exec inside a loop that reads from a file" \
  "printf 'q() { kubectl -n x exec -i y -- \"\$@\"; }\nwhile read -r k; do\n  q vault write \"\$k\"\ndone < \"\$UK\"\n' >> bootstrap/vault-day0.sh"
# Clause 4. A pipe IS a stdin redirect: the exec gets the pipe, not the loop's
# input. Refusing that form would reject the safe shape alongside the dangerous
# one, and they look nothing alike to anyone reading the file.
case_ "an exec on the right of a pipe" "0 error" \
  "printf 'while read -r k; do\n  echo x | vx a b \"\" vault write \"\$k\" -\ndone < \"\$UK\"\n' >> bootstrap/vault-day0.sh"

echo; echo "seeding commands, back on the page they were taken off:"
# The exact line that reached a live Vault with the placeholders still in it,
# and reported version 1.
case_ "the page restates a vault kv put" "restates a Vault seeding command" \
  "printf 'vault kv put kv/platform/apps username=x password=y\n' >> docs/05-vault-eso.md"
# The page quotes that command once, as the reason the script exists. Evidence
# is not an instruction, and a check that cannot tell them apart makes the page
# unable to explain itself.
case_ "the page may quote the command it refuses" "0 error" \
  "printf 'vault kv put kv/platform/apps username=\\'\\''<nexus-user>\\'\\'' password=z\n' >> docs/05-vault-eso.md"
case_ "the seeding script is deleted"    "is gone, and docs/05-vault-eso.md" \
  "rm -f bootstrap/seed-vault-kv.sh"

echo; echo "python that only parses on a new enough interpreter:"
# The exact construct that took three CI jobs down while every workstation here
# reported green: a backslash inside an f-string expression, which Python only
# allowed from 3.12.
# \047 is a single quote and \134 a backslash, spelled in octal so this line
# needs no nested quoting of its own -- the shape it writes is `f"a {'\n'}"`.
case_ "a backslash in an f-string expression" "contains a backslash" \
  "printf 'X = f\"a {\047\134n\047}\"\n' >> hack/validate.py"
# Clause 2, the other half of PEP 701 and the same failure: the delimiter quote
# reused inside the expression.
case_ "the delimiter quote inside the expression" "that delimits it" \
  "printf 'Y = f\"a {\\\"b\\\".upper()}\"\n' >> hack/validate.py"
# Clause 3: grammar that ast DOES gate by feature_version. `match` is 3.10, and
# the runner is 3.9 -- its own tracebacks say /usr/lib64/python3.9/.
case_ "a match statement, which is 3.10" "newer than Python 3.9" \
  "printf 'def _z(v):\n    match v:\n        case 1:\n            return 2\n' >> hack/validate.py"

echo; echo "a harness that changes what it copies:"
# What a runner printed: eleven errors about file modes this repository does not
# have, then FATAL: baseline is not clean, and every case after it skipped. The
# red job was describing the harness, not the code.
case_ "the fixture copied with cp -r" "copies the fixture with \`cp -r\`" \
  "sed -i 's|^cp -a \"\$SRC\"|cp -r \"\$SRC\"|' hack/prove-checks.sh"

echo; echo "a hostname that belongs to another environment:"
# The listener this attaches to takes every host from every namespace and cannot
# be narrowed -- the domain is shared with objects outside this repository, and
# a DNS wildcard matches one whole leftmost label, so `*.<baseDomain>` is all
# that can be written and it constrains nothing. This gate is the boundary.
case_ "a qa hostname in a dev folder" "does not begin with" \
  "printf 'httpRoute:\n  enabled: true\n  hostnames: [qa-svc.example.test]\n  parentRefs: [{name: gw, namespace: gwns}]\n' >> tenants/t1/dev/svc/values.yaml"
# The old order, which is what this cluster had: <service>-<env> instead of
# <env>-<service>. It ends in the right domain, so the suffix check passed it.
case_ "the two halves the wrong way round" "does not begin with" \
  "printf 'httpRoute:\n  enabled: true\n  hostnames: [svc-dev.example.test]\n  parentRefs: [{name: gw, namespace: gwns}]\n' >> tenants/t1/dev/svc/values.yaml"
# Prefixed dev- and then naming qa. It satisfies the prefix rule by accident and
# belongs to neither environment.
case_ "prefixed dev- and then naming qa" "and then names the environment" \
  "printf 'httpRoute:\n  enabled: true\n  hostnames: [dev-qa-svc.example.test]\n  parentRefs: [{name: gw, namespace: gwns}]\n' >> tenants/t1/dev/svc/values.yaml"
# NOT an error, and this is the case the rule was relaxed for: a folder called
# a folder named auth-simulator published as dev-sso. A folder name is an object
# name; a hostname
# is typed by people. Forcing them to be one string makes the wrong one win.
case_ "a service part that is not the folder name" "0 error" \
  "printf 'httpRoute:\n  enabled: true\n  hostnames: [dev-anything.example.test]\n  parentRefs: [{name: gw, namespace: gwns}]\n' >> tenants/t1/dev/svc/values.yaml"
# Nothing could collide while the hostname was derived from the folder name.
# Now that the service part is free, two folders can reach for one host, and
# Gateway API gives it to whichever route is older without saying so.
case_ "two workloads claiming one hostname" "is claimed by 2 workloads" \
  "printf 'httpRoute:\n  enabled: true\n  hostnames: [dev-svc.example.test]\n  parentRefs: [{name: gw, namespace: gwns}]\n' >> tenants/t1/dev/svc/values.yaml && mkdir -p tenants/t1/dev/svc2 && cp tenants/t1/dev/svc/config.yaml tenants/t1/dev/svc2/config.yaml && cp tenants/t1/dev/svc/values.yaml tenants/t1/dev/svc2/values.yaml"

echo; echo "raw manifests nobody can mirror from:"
# check-pins.sh proved the tag was an exact version and never asked whether the
# version was in the registry. Nothing offline can. What can be checked is that
# somebody wrote the list down, and that it still says what the manifests say.
RAW='mkdir -p tenants/t1/dev/raw/manifests && printf "namespace: t1-dev\nmanifestsDir: tenants/t1/dev/raw/manifests\nsync: {automated: true, selfHeal: true, prune: false}\n" > tenants/t1/dev/raw/config.yaml && printf "apiVersion: v1\nkind: Pod\nmetadata: {name: p}\nspec:\n  imagePullSecrets: [{name: regcred}]\n  containers:\n  - name: c\n    image: reg.example/x:1.0.0\n" > tenants/t1/dev/raw/manifests/p.yaml'
case_ "no images.yaml beside the manifests" "does not exist. This workload pulls" \
  "$RAW"
case_ "an images.yaml that has drifted behind" "does not list" \
  "$RAW && printf 'images:\n  - reg.example/other:1.0.0\n' > tenants/t1/dev/raw/images.yaml"
case_ "an images.yaml naming something nothing pulls" "which no manifest in" \
  "$RAW && printf 'images:\n  - reg.example/x:1.0.0\n  - reg.example/ghost:1.0.0\n' > tenants/t1/dev/raw/images.yaml"

echo; echo "a folder name that cannot be an object name:"
# These pass every other gate -- they are perfectly good directories -- and then
# the API server refuses the Application while the other eight generate fine.
# One missing Application and a line in a controller log. Nothing red.
case_ "upper case in a workload folder" "cannot be a Kubernetes object name" \
  "mv tenants/t1/dev/svc tenants/t1/dev/SvcName"
case_ "an underscore in a workload folder" "cannot be a Kubernetes object name" \
  "mv tenants/t1/dev/svc tenants/t1/dev/my_svc"
case_ "upper case in a platform folder" "cannot be a Kubernetes object name" \
  "mv platform/demo platform/Demo"

echo; echo "an image nobody can fetch:"
# A Deployment with no imagePullSecrets pulls anonymously and every pod fails
# with `no basic auth credentials`. All four gates pass over it: check-pins
# proves the tag is exact and never asks whether anything can fetch it.
case_ "no pull secret in any layer" "no value layer sets imagePullSecrets" \
  "rm -f tenants/_shared/values.yaml"
# The chart's own default is `[]`. It renders nothing and reads as configured,
# which is worse than absent.
case_ "an empty pull secret list" "no value layer sets imagePullSecrets" \
  "printf 'deployment:\n  imagePullSecrets: []\n' > tenants/_shared/values.yaml"
# No value layer reaches raw manifests, so a manifestsDir workload cannot
# inherit it -- and the two redis folders are exactly that shape.
case_ "raw manifests with no pull secret" "none of them sets imagePullSecrets" \
  "mkdir -p tenants/t1/dev/raw/manifests && printf 'namespace: t1-dev\nmanifestsDir: tenants/t1/dev/raw/manifests\nsync: {automated: true, selfHeal: true, prune: false}\n' > tenants/t1/dev/raw/config.yaml && printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: p}\nspec:\n  containers:\n  - name: c\n    image: reg.example/x:1.0.0\n' > tenants/t1/dev/raw/manifests/p.yaml"

RELOADER='mkdir -p platform/reloader && printf -- "- reg.example/reloader:1.0.0\n" > platform/reloader/images.yaml && : > platform/reloader/RUNBOOK.md && sed -i "s/platformNamespaces: \[demo-ns\]/platformNamespaces: [demo-ns, reloader-ns]/" cluster.yaml'

echo; echo "a credential in a file that is not a secret:"
# Moving configuration out of an image and into this repository is right, and it
# carries one thing that must not come along. A ConfigMap is readable by
# everything in the namespace that can read ConfigMaps -- a much wider set than
# can read Secrets -- and git keeps the line after it is deleted. The repository
# is pushed to a server other people can clone, so the only cheap moment to
# catch this is before the push.
# A JSON key, not a connection string. A fixture holding both lets the
# connection-string rule fire first, and the case then proves that rule twice
# while proving the JSON reader not at all.
SECRET_JSON='configMap:\n  enabled: true\n  files:\n    appsettings:\n      appsettings.Production.json: |\n        {"Database": {"Host": "db", "Password": "Str0ng-P4ssw0rd"}}\n'
case_ "a credential under a credential-named key" "holds what reads as a real credential" \
  "printf 'deployment:\n  env:\n    DbPassword:\n      value: Str0ng-P4ssw0rd\n' >> tenants/t1/dev/svc/values.yaml"
# The realistic shape, and the one no structural check can see: the whole
# settings file is ONE YAML string, so walking the document finds a blob.
case_ "a password inside a JSON blob" "is a JSON document with" \
  "printf '$SECRET_JSON' >> tenants/t1/dev/svc/values.yaml"
# Host and credential travel in one line, which is what makes a settings file
# look harmless.
case_ "a connection string in a plain value" "contains a connection string with a password" \
  "printf 'deployment:\n  env:\n    Conn:\n      value: \"Server=db;User Id=sa;Password=Str0ng-P4ssw0rd;\"\n' >> tenants/t1/dev/svc/values.yaml"
case_ "a PEM private key" "contains a PEM private key header" \
  "printf 'deployment:\n  env:\n    Cert:\n      value: \"-----BEGIN RSA PRIVATE KEY-----AAAA\"\n' >> tenants/t1/dev/svc/values.yaml"
case_ "a signed token" "contains what parses as a JWT" \
  "printf 'deployment:\n  env:\n    Bearer:\n      value: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln\n' >> tenants/t1/dev/svc/values.yaml"
# A shared layer is a file a workload never mentions. A check reading only the
# leaf is blind to the layer above it -- which is where a default goes.
# WRITTEN, NOT APPENDED. Appending a second `deployment:` to a file that already
# has one is refused by check_no_duplicate_yaml_keys first, and the case then
# passes on the wrong error. A fixture that is invalid YAML proves nothing about
# the rule it was built for.
case_ "a credential in a shared layer" "holds what reads as a real credential" \
  "printf 'deployment:\n  imagePullSecrets:\n    - name: regcred\n  env:\n    ApiKey:\n      value: k7Qx-9fLm2Pw-aa\n' > tenants/_shared/values.yaml"

echo; echo "  ...and the things it must NOT refuse:"
# A gate that refuses correct files is worked around, and then it guards nothing.
case_ "a redacted placeholder" "0 error(s)" \
  "printf 'deployment:\n  env:\n    DbPassword:\n      value: \"<redacted>\"\n' >> tenants/t1/dev/svc/values.yaml"
# PasswordPolicy CONTAINS the word and is a setting. The rule is the last word
# of the key, not a substring of it.
case_ "a setting named after a credential" "0 error(s)" \
  "printf 'deployment:\n  env:\n    PasswordMinLength:\n      value: \"12\"\n    PasswordPolicy:\n      value: strict\n' >> tenants/t1/dev/svc/values.yaml"
# A reference is named after the thing it points at. The two redis CRs in this
# estate are the general case -- `redisSecret: {name: x, key: password}` and a
# secretKeyRef under a field called redisReplicationPassword -- and they were
# eight refusals on the first real repository this check ran against. Both sides
# of the distinction are proved: the value position above, the reference position
# here.
case_ "a Secret reference under a credential-named field" "0 error(s)" \
  "printf 'deployment:\n  env:\n    DbPassword:\n      valueFrom:\n        secretKeyRef: {name: svc-db, key: password}\n' >> tenants/t1/dev/svc/values.yaml && $RELOADER && printf 'namespace: reloader-ns\nchart: {repo: tools, name: reloader, version: \"1.0.0\"}\nsync: {automated: true, selfHeal: true, prune: true}\n' > platform/reloader/component.yaml"
case_ "a raw CR naming the Secret that holds its password" "0 error(s)" \
  "mkdir -p tenants/t1/dev/raw/manifests && printf 'namespace: t1-dev\nmanifestsDir: tenants/t1/dev/raw/manifests\nsync: {automated: true, selfHeal: true, prune: false}\n' > tenants/t1/dev/raw/config.yaml && printf 'images:\n  - reg.example/x:1.0.0\n' > tenants/t1/dev/raw/images.yaml && printf 'apiVersion: redis.redis.opstreelabs.in/v1beta2\nkind: RedisReplication\nmetadata: {name: r}\nspec:\n  kubernetesConfig:\n    image: reg.example/x:1.0.0\n    imagePullSecrets: [{name: regcred}]\n    redisSecret: {name: redis-secret, key: password}\n' > tenants/t1/dev/raw/manifests/r.yaml"
# The externalSecret block is the same thing, and is skipped as a subtree because
# every field in it is a reference by construction.
case_ "an ExternalSecret naming its remote keys" "0 error(s)" \
  "printf 'externalSecret:\n  enabled: true\n  data:\n    - secretKey: DbPassword\n      remoteRef: {key: kv/svc, property: password}\n' >> tenants/t1/dev/svc/values.yaml"

echo; echo "a config change that reaches the ConfigMap and not the pod:"
# Kubernetes never refreshes a subPath mount -- the file is copied once, when the
# container starts -- and a settings file has to be a subPath mount, because
# mounting a directory over the application's own directory buries the binaries.
# So the change arrives when the pod is replaced and never otherwise, and the
# application chart already writes an annotation asking a controller to replace
# it. Without the controller: Synced, Healthy, and not delivered.
CM_FILES='printf "configMap:\n  enabled: true\n  files:\n    appsettings:\n      a.json: \"{}\"\n" >> tenants/t1/dev/svc/values.yaml'
case_ "a mounted ConfigMap with no reloader" "no reloader component on this cluster has sync.automated true" \
  "$CM_FILES"
case_ "envFrom with no reloader" "no reloader component on this cluster has sync.automated true" \
  "printf 'deployment:\n  envFrom:\n    cm:\n      type: configmap\n      nameSuffix: settings\n' >> tenants/t1/dev/svc/values.yaml"
case_ "a configMap volume with no reloader" "no reloader component on this cluster has sync.automated true" \
  "printf 'deployment:\n  volumes:\n    cfg:\n      configMap: {name: svc-settings}\n' >> tenants/t1/dev/svc/values.yaml"
# One key out of a ConfigMap is the same problem as the whole file.
case_ "one key from a ConfigMap with no reloader" "no reloader component on this cluster has sync.automated true" \
  "printf 'deployment:\n  env:\n    Level:\n      valueFrom:\n        configMapKeyRef: {name: svc-settings, key: level}\n' >> tenants/t1/dev/svc/values.yaml"
# THE DISTINCTION THAT MATTERS. A component parked with automated false is a
# plan, and a plan does not restart a pod. platform/reloader landed in exactly
# this state, deliberately, because neither its chart nor its image was mirrored.
case_ "a reloader folder that is not syncing" "no reloader component on this cluster has sync.automated true" \
  "$RELOADER && printf 'namespace: reloader-ns\nchart: {repo: tools, name: reloader, version: \"1.0.0\"}\nsync: {automated: false, selfHeal: true, prune: true}\n' > platform/reloader/component.yaml && $CM_FILES"
case_ "a reloader that is actually syncing" "0 error(s)" \
  "$RELOADER && printf 'namespace: reloader-ns\nchart: {repo: tools, name: reloader, version: \"1.0.0\"}\nsync: {automated: true, selfHeal: true, prune: true}\n' > platform/reloader/component.yaml && $CM_FILES"

echo; echo "a ceremony nobody can find:"
# A script added and never listed leaves the file that enumerates the ceremonies
# saying "two" while there are three; and a recovery ceremony nobody can find is
# the same as not having one. Both directions are refused.
case_ "a bootstrap script missing from the README" "is not named in bootstrap/README.md" \
  "cp bootstrap/seed-regcred.sh bootstrap/seed-nothing.sh"
case_ "a README naming a script that is not there" "which does not exist" \
  "printf '\nbootstrap/seed-imaginary.sh  nothing\n' >> bootstrap/README.md"

echo; echo "a gate that cannot be run:"
# A checkout that has lost the mode fails every case at once, which reads as
# every rule being broken. It is one bit.
case_ "a script that is not executable" "is not executable" \
  "chmod -x hack/check-pins.sh"

echo; echo "render-root refuses rather than printing a blank Application:"
# python3 without PyYAML exits non-zero inside a command substitution, which
# `set -e` does not see. The old form printed a template with every field
# empty, and only kubectl's required-field check stopped it being applied.
rr_out=$(sed -i '/repoURL:/d' cluster.yaml && ./bootstrap/render-root.sh 2>/dev/null); rr_rc=$?
if [ "$rr_rc" -ne 0 ] && [ -z "$rr_out" ]; then
  echo "  PASS  a missing value stops it, and prints nothing"; pass=$((pass+1))
else
  echo "  FAIL  a missing value stops it, and prints nothing (exit $rr_rc)"; fail=$((fail+1))
  sed 's/^/          /' <<<"$rr_out" | head -3
fi
restore

echo; echo "render.sh reads its own output (a different gate, so its own harness):"
# Everything above proves validate.py refuses a render.sh that does not scan.
# This runs the scan, over a chart written to fail it -- because the two lines
# in platform/vault-transit/values.yaml were refused by nothing until they were
# a StatefulSet, and by then they were on a cluster.
snapshot
render_out() { ./hack/render.sh 2>&1; }
out=$(render_out); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'no duplicate entries' <<<"$out"; then
  echo "  PASS  a clean tree renders and is scanned"; pass=$((pass+1))
else
  echo "  FAIL  a clean tree renders and is scanned"; fail=$((fail+1))
  sed 's/^/          /' <<<"$out" | tail -5
fi
mkdir -p platform/dup/chart/templates
cat > platform/dup/component.yaml <<'YML'
namespace: demo-ns
localChart: platform/dup/chart
sync: {automated: true, selfHeal: true, prune: false}
YML
: > platform/dup/values.yaml
cat > platform/dup/chart/Chart.yaml <<'YML'
apiVersion: v2
name: dup
version: 0.0.0
YML
# The exact shape the chart and the values file made between them: one container,
# one variable, declared twice with the same value. Identical values are the
# point -- nothing about the object is ambiguous, and it is refused anyway.
cat > platform/dup/chart/templates/sts.yaml <<'YML'
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: dup}
spec:
  template:
    spec:
      containers:
        - name: vault
          env:
            - {name: VAULT_ADDR, value: "https://127.0.0.1:8200"}
            - {name: VAULT_ADDR, value: "https://127.0.0.1:8200"}
YML
out=$(render_out); rc=$?
if [ "$rc" -ne 0 ] && grep -q '2 entries for name=VAULT_ADDR' <<<"$out"; then
  echo "  PASS  a duplicate env entry is refused, and the run fails"; pass=$((pass+1))
else
  echo "  FAIL  a duplicate env entry is refused, and the run fails (exit $rc)"; fail=$((fail+1))
  sed 's/^/          /' <<<"$out" | tail -5
fi
restore

echo; echo "the unseal step, run instead of read:"
# Every claim about this step until now was made by reading it, and it has
# failed twice on a live cluster: once submitting one key of three, once
# carrying on past a sealed Vault into three 503s that named the state and not
# the cause. This runs the step itself -- lifted out of bootstrap/vault-day0.sh
# with sed, not paraphrased -- against a Vault that answers.
snapshot
UNSEAL_T="$WORK/unseal-harness.sh"
build_unseal_harness() {   # $1 = threshold the fake Vault needs
  cat > "$UNSEAL_T" <<EOF
set -euo pipefail
NEED=$1
EOF
  cat >> "$UNSEAL_T" <<'EOF'
KEYDIR=$(mktemp -d); chmod 700 "$KEYDIR"
TRANSIT_NS=vault-transit
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n=== %s\n' "$*"; }
python3 -c "import json;print(json.dumps({'unseal_keys_b64':['AAA','BBB','CCC','DDD','EEE'],'root_token':'rt'}))" > "$KEYDIR/transit-init.json"
# A Vault that starts where this cluster was left: one share in, two to go.
SHARES=$(mktemp); echo "AAA" > "$SHARES"
vx() {
  shift 3
  local n k
  case "$*" in
    "vault status")
      n=$(grep -c . "$SHARES" || true)
      echo "Initialized        true"
      if [ "$n" -ge "$NEED" ]; then echo "Sealed             false"; else
        echo "Sealed             true"; echo "Unseal Progress    $n/$NEED"; fi
      [ "$n" -ge "$NEED" ] || return 2 ;;
    "vault operator unseal -reset") : > "$SHARES"; echo "reset ok" ;;
    "vault operator unseal "*)
      k=${@: -1}
      grep -qx "$k" "$SHARES" && { echo "key already submitted"; return 2; }
      echo "$k" >> "$SHARES"; echo "progress $(grep -c . "$SHARES")/$NEED" ;;
    *) echo "the step called something this fake does not model: $*"; return 1 ;;
  esac
}
vstatus() { vx "$1" "$2" "" vault status </dev/null 2>&1 || true; }
EOF
  sed -n '/^log "unsealing transit"/,/^fi$/p' bootstrap/vault-day0.sh >> "$UNSEAL_T"
}
# Threshold 3: the real case. A Vault stuck at 1/3 has to come out unsealed,
# because submitting a share Vault already holds does not advance it -- so the
# step only works if it resets first.
build_unseal_harness 3
u_out=$(bash "$UNSEAL_T" 2>&1); u_rc=$?
if [ "$u_rc" -eq 0 ] && grep -q 'Sealed *false' <<<"$u_out"; then
  echo "  PASS  a Vault left at 1/3 ends unsealed"; pass=$((pass+1))
else
  echo "  FAIL  a Vault left at 1/3 ends unsealed (exit $u_rc)"; fail=$((fail+1))
  sed 's/^/          /' <<<"$u_out" | tail -6
fi
# Threshold 4: three keys are not enough, so the step must stop here rather than
# hand a sealed Vault to the configuration that follows.
build_unseal_harness 4
u_out=$(bash "$UNSEAL_T" 2>&1); u_rc=$?
if [ "$u_rc" -ne 0 ] && grep -q 'still sealed' <<<"$u_out" \
   && grep -q 'Unseal Progress' <<<"$u_out"; then
  echo "  PASS  it refuses, and prints the progress that names the fault"; pass=$((pass+1))
else
  echo "  FAIL  it refuses, and prints the progress that names the fault (exit $u_rc)"; fail=$((fail+1))
  sed 's/^/          /' <<<"$u_out" | tail -6
fi
restore

echo; echo "a helm that fails without saying anything:"
# What a runner actually printed: `does not render: []`. That is a Python list
# repr of the last line of an empty stderr, and it names neither the chart, the
# reason, nor helm. The operator reading it goes and looks at the chart, which
# is the one place the problem is not.
snapshot
mkdir -p "$WORK/brokenbin"
printf '#!/bin/sh\nexit 127\n' > "$WORK/brokenbin/helm"
chmod +x "$WORK/brokenbin/helm"
bh_out=$(PATH="$WORK/brokenbin:$PATH" python3 hack/validate.py 2>&1)
if grep -q 'not a chart error' <<<"$bh_out" && grep -q 'helm version' <<<"$bh_out"; then
  echo "  PASS  it says helm is the problem, and how to see that"; pass=$((pass+1))
else
  echo "  FAIL  it says helm is the problem, and how to see that"; fail=$((fail+1))
  grep -E '^ERROR' <<<"$bh_out" | sed 's/^/          /' | head -3
fi
if grep -qF 'does not render: []' <<<"$bh_out"; then
  echo "  FAIL  the empty-list message is back"; fail=$((fail+1))
else
  echo "  PASS  nothing prints an empty list as a reason"; pass=$((pass+1))
fi
rm -rf "$WORK/brokenbin"
restore

echo; echo "vault-day0.sh on the path where everything is already done:"
# `bash -n` parses; it does not run, so it cannot see a variable assigned only
# inside a branch and read after it. That is what reached the cluster:
#
#   === transit is already configured
#   ./bootstrap/vault-day0.sh: line 492: TOKEN_CHANGED: unbound variable
#
# after the script had reported success on every step it had taken. The skip
# path is the path every run after the first one takes, and it is the one no
# amount of reading catches.
#
# So it is run, against a cluster that answers: transit initialised, unsealed
# and its key working; the main Vault initialised and unsealed. Nothing to do,
# which is exactly the case that broke.
snapshot
# TWO splice points, and the reason matters.
#
# Splicing the fakes in after vstatus() is correct for vx() and vstatus(), which
# the script defines itself and would otherwise overwrite them. But
# `kubectl version -o json || die "cannot reach the cluster"` runs ABOVE that, so
# it runs against the REAL kubectl. On a runner that sits on a cluster node it
# answers and the case passes; anywhere else the case fails with `cannot reach
# the cluster` -- the script's own guard, working
# correctly, reported as a broken rule.
#
# So the case measured which machine ran it. That is the third time this file
# has learned the same lesson: /tmp with noexec, `cp -r` and the umask, and now
# this. A harness that reports its own environment as a finding about the code
# proves nothing about the code.
#
# kubectl() goes in after die(), above the probe -- the script never redefines
# it. vx() and vstatus() go in after vstatus(), below the script's own.
FAKES_K="$WORK/day0-fakes-kubectl.sh"
cat > "$FAKES_K" <<'EOF'
kubectl() {
  case "$*" in
    *"get secret vault-transit-token"*) echo "dG9r" ;;
    *) return 0 ;;
  esac
}
EOF
FAKES="$WORK/day0-fakes.sh"
cat > "$FAKES" <<'EOF'
# Defined AFTER the script's own vx() and vstatus(), or they would replace
# these and the harness would drive a real kubectl.
vx() {
  shift 3
  case "$*" in
    "vault status")
      echo "Seal Type          transit"
      echo "Initialized        true"
      echo "Sealed             false"
      echo "Storage Type       raft" ;;
    "vault write -field=ciphertext transit/encrypt/"*) echo "vault:v1:zzz" ;;
    *) echo "the script called something this fake does not model: $*" >&2; return 1 ;;
  esac
}
vstatus() { vx "$1" "$2" "" vault status </dev/null 2>&1 || true; }
EOF
D0="$WORK/day0-harness.sh"
printf 'set -uo pipefail\nKEYDIR=$(mktemp -d)\n' > "$D0"
# The script, with its cd removed so it runs where the fixture is, `set -e`
# relaxed so a fake's non-zero does not end the run silently, and the fakes
# spliced in after the last function it defines.
sed -e 's|^cd "$(dirname "$0")/\.\."$|:|' \
    -e 's|^set -euo pipefail$|set -uo pipefail|' \
    -e "/^die()  /r $FAKES_K" \
    -e "/^vstatus() /r $FAKES" \
    bootstrap/vault-day0.sh >> "$D0"
# Bounded. A hang here is a red case, not a pipeline that sits for twenty
# minutes -- the lesson hack/compare-live.sh already carries.
d0_out=$(timeout 60 bash "$D0" 2>&1); d0_rc=$?
if [ "$d0_rc" -eq 0 ] && grep -q 'Vault is up' <<<"$d0_out"; then
  echo "  PASS  it runs to the end with nothing to do"; pass=$((pass+1))
else
  echo "  FAIL  it runs to the end with nothing to do (exit $d0_rc)"; fail=$((fail+1))
  sed 's/^/          /' <<<"$d0_out" | tail -6
fi
if grep -qi 'unbound variable' <<<"$d0_out"; then
  echo "  FAIL  an unbound variable on the skip path"; fail=$((fail+1))
else
  echo "  PASS  no unbound variable on the skip path"; pass=$((pass+1))
fi
# And the state that loses a Vault: the main one initialised and sealed, because
# transit was rebuilt and its key is gone. Printing "Vault is up" over
# `Sealed true` is the failure this case exists to refuse.
cat > "$FAKES" <<'EOF'
vx() { shift 3; case "$*" in
  "vault status")
     if [ "$WHO" = transit ]; then echo "Initialized        true"; echo "Sealed             false";
     else echo "Seal Type          transit"; echo "Initialized        true"; echo "Sealed             true"; fi ;;
  "vault write -field=ciphertext transit/encrypt/"*) echo "vault:v1:zzz" ;;
  *) echo "unmodelled: $*" >&2; return 1 ;; esac; }
vstatus() { if [ "$2" = vault-transit-0 ]; then WHO=transit; else WHO=main; fi; vx "$1" "$2" "" vault status </dev/null 2>&1 || true; }
EOF
printf 'set -uo pipefail\nKEYDIR=$(mktemp -d)\n' > "$D0"
sed -e 's|^cd "$(dirname "$0")/\.\."$|:|' \
    -e 's|^set -euo pipefail$|set -uo pipefail|' \
    -e "/^die()  /r $FAKES_K" \
    -e "/^vstatus() /r $FAKES" \
    bootstrap/vault-day0.sh >> "$D0"
d0_out=$(timeout 60 bash "$D0" 2>&1); d0_rc=$?
if [ "$d0_rc" -ne 0 ] && grep -q 'INITIALISED and SEALED' <<<"$d0_out"; then
  echo "  PASS  a sealed main Vault is refused, not called up"; pass=$((pass+1))
else
  echo "  FAIL  a sealed main Vault is refused, not called up (exit $d0_rc)"; fail=$((fail+1))
  sed 's/^/          /' <<<"$d0_out" | tail -4
fi
if grep -q 'Vault is up' <<<"$d0_out"; then
  echo "  FAIL  it still says Vault is up over a sealed Vault"; fail=$((fail+1))
else
  echo "  PASS  it does not say Vault is up over a sealed Vault"; pass=$((pass+1))
fi
restore

echo; echo "unseal-transit.sh, run against a cluster that answers:"
# Run, not read, for the reason the block above learned the hard way: the paths
# that matter here are the ones taken on a cluster where something is already
# true, and `bash -n` cannot see them.
#
# The second case is the state this script exists for: transit unsealed again,
# and a main Vault pod that started during the sealed window still sealed. A
# Vault unseals at startup and never
# retries, so nothing recovers that on its own -- and nothing else in the
# cluster reports it, because the Application is Synced and the StatefulSet has
# the replicas it asked for.
snapshot
UT_K="$WORK/ut-fakes-kubectl.sh"
cat > "$UT_K" <<'EOF'
kubectl() {
  case "$*" in
    *"get secret vault-transit-token"*) echo "dG9r" ;;
    *"get statefulset vault"*)          echo "3" ;;
    *"get pod vault-transit-0"*)        echo "  restarts: 1" ;;
    *) return 0 ;;
  esac
}
EOF
build_ut() {   # $1 = seal state the MAIN pods report
  UT_V="$WORK/ut-fakes.sh"
  cat > "$UT_V" <<EOF
vx() { local ns=\$1 pod=\$2; shift 3; case "\$*" in
  "vault status")
     if [ "\$pod" = vault-transit-0 ]; then
       echo "Seal Type          shamir"; echo "Initialized        true"; echo "Sealed             false"
     else
       echo "Seal Type          transit"; echo "Initialized        true"; echo "Sealed             $1"
     fi ;;
  "vault write -field=ciphertext transit/encrypt/"*) echo "vault:v1:zzz" ;;
  *) echo "unmodelled: \$*" >&2; return 1 ;; esac; }
vstatus() { vx "\$1" "\$2" "" vault status </dev/null 2>&1 || true; }
EOF
  UT="$WORK/ut-harness.sh"
  printf 'set -uo pipefail\nKEYDIR=$(mktemp -d)\n' > "$UT"
  sed -e 's|^cd "$(dirname "$0")/\.\."$|:|' \
      -e 's|^set -euo pipefail$|set -uo pipefail|' \
      -e "/^die()  /r $UT_K" \
      -e "/^vstatus() /r $UT_V" \
      bootstrap/unseal-transit.sh >> "$UT"
}
build_ut false
ut_out=$(timeout 60 bash "$UT" 2>&1); ut_rc=$?
if [ "$ut_rc" -eq 0 ] && grep -q 'every' <<<"$ut_out"; then
  echo "  PASS  nothing to do, and it says so and stops"; pass=$((pass+1))
else
  echo "  FAIL  nothing to do, and it says so and stops (exit $ut_rc)"; fail=$((fail+1))
  sed 's/^/          /' <<<"$ut_out" | tail -6
fi
build_ut true
ut_out=$(timeout 60 bash "$UT" 2>&1); ut_rc=$?
if [ "$ut_rc" -ne 0 ] && grep -q 'SEALED: vault-0 vault-1 vault-2' <<<"$ut_out"; then
  echo "  PASS  a main Vault pod left sealed is named, not passed over"; pass=$((pass+1))
else
  echo "  FAIL  a main Vault pod left sealed is named, not passed over (exit $ut_rc)"; fail=$((fail+1))
  sed 's/^/          /' <<<"$ut_out" | tail -6
fi
if grep -q 'delete pod vault-0' <<<"$ut_out"; then
  echo "  PASS  it prints the command that fixes it"; pass=$((pass+1))
else
  echo "  FAIL  it prints the command that fixes it"; fail=$((fail+1))
fi
restore

echo; echo "the shelf test, run instead of read:"
# Every claim about the shelf so far was made by reading its pattern. This runs
# the job's own script -- lifted out of .gitlab-ci.yml, not paraphrased -- over
# a throwaway repository with one commit in it, in both classes and both
# directions. The product half was open for as long as the machine half was
# strict, and no case here would have been green.
SHELF="$WORK/shelf.sh"
python3 - "$SHELF" <<'PY'
import sys, yaml, pathlib
d = yaml.safe_load(pathlib.Path(".gitlab-ci.yml").read_text())
pathlib.Path(sys.argv[1]).write_text("\n".join(d["shelf"]["script"]))
PY

shelf_case() {  # shelf_case <name> <subject> <path> <ok|refused>
  local name="$1" subject="$2" path="$3" want="$4" r="$WORK/shelfrepo" out rc got
  rm -rf "$r"; mkdir -p "$r"
  (
    cd "$r"
    git init -q .
    git config user.email prover@local; git config user.name prover
    git config commit.gpgsign false
    printf 'seed\n' > seed; git add -A; git commit -qm seed
    mkdir -p "$(dirname "$path")"; printf 'x\n' >> "$path"
    git add -A; git commit -qm "$subject"
  ) >/dev/null
  out=$(cd "$r" && bash "$SHELF" 2>&1); rc=$?
  got=ok; [ "$rc" -eq 0 ] || got=refused
  if [ "$got" = "$want" ]; then
    printf '  PASS  %s\n' "$name"; pass=$((pass+1))
  else
    printf '  FAIL  %s   (wanted %s, got %s)\n' "$name" "$want" "$got"; fail=$((fail+1))
    sed 's/^/          /' <<<"$out" | head -4
  fi
}

shelf_case "product subject editing the gate itself" "orders: bump" ".gitlab-ci.yml"  refused
shelf_case "product subject editing README"          "orders: bump" "README.md"       refused
shelf_case "product subject editing .gitignore"      "orders: bump" ".gitignore"      refused
shelf_case "product subject on its own folder"       "orders: bump" "tenants/t1/dev/svc/values.yaml" ok
shelf_case "machine subject on the machine"          "Machine: x"     "hack/x.sh"       ok
shelf_case "machine subject on a product folder"     "Machine: x"     "platform/demo/component.yaml" refused
shelf_case "machine merge subject on the machine"    "Machine merge: x" ".gitignore"    ok

echo; echo "the machine names nothing:"
case_ "a tenant name in a machine file"  "names the tenant" \
  "printf '# for t1 only\n' >> hack/check-pins.sh"
case_ "a real path in a machine doc"     "names the service" \
  "mkdir -p docs && printf 'Run: ./hack/x.sh tenants/t1/dev/svc\n' > docs/99-example.md"
# The narrowing that made the check usable: a service may be called svc or api,
# and matching those as bare words produced eighty-seven findings and no leaks.
case_ "a service name as an ordinary word" "0 error" \
  "mkdir -p docs && printf 'The svc variable holds the name.\n' > docs/99-example.md"
# The allow-list is anchored, and this is what the anchor is for: the machine's
# own label prefix is vocabulary, a host under it is somebody's cluster.
case_ "a host under an allowed domain"    "contains an address" \
  "printf '# see vault.gitops.internal\n' >> hack/check-pins.sh"
case_ "the allowed domain by itself"      "0 error" \
  "printf '# the gitops.internal prefix\n' >> hack/check-pins.sh"

echo; echo "the procedure page and the script agree:"
# An unfreeze step that writes the policy out is the regression, and turning the
# placeholder back into an object is one sed away.
case_ "incident page writes out a sync policy" "written-out syncPolicy.automated" \
  "sed -i 's/<what step 1 printed>/{X}/' docs/30-incident.md"
# And the same regression with one space in it, which the fixed-string version
# of this check did not see. That is the difference between a gate and a gate
# that happens to have caught the one case somebody wrote down.
case_ "the same, with a space after the colon" "written-out syncPolicy.automated" \
  "sed -i 's/<what step 1 printed>/ {X}/' docs/30-incident.md"

echo; echo "namespace label vocabulary:"
# The most expensive failure the structure can produce, and it produces it green:
# the labels are renamed in the machine and the selectors in platform/ are not.
case_ "selector on a label nothing emits" "which charts/env-baseline does not" \
  "mkdir -p platform/demo && printf 'spec:\n  namespaceSelectors:\n    - matchLabels:\n        secrets.internal/regcred: \"true\"\n' > platform/demo/extra.yaml"
# The false positives to avoid: a label PUT ON an object, outside any selector,
# must not be reported.
case_ "label set on an object is not a selector" "0 error" \
  "mkdir -p platform/demo && printf 'metadata:\n  labels:\n    gitops.internal/layer: platform\n' > platform/demo/extra.yaml"

# A cluster that is not there, for the two tools that talk to one. The user
# carries no credentials on purpose: that is what makes kubectl ask for a
# username on stdin, which is the hang both tools now have to refuse instead of
# waiting through.
cat > "$WORK/kubeconfig.dead" <<'EOF'
apiVersion: v1
kind: Config
clusters: [{name: dead, cluster: {server: "https://127.0.0.1:1"}}]
contexts: [{name: dead, context: {cluster: dead, user: dead}}]
users: [{name: dead, user: {}}]
current-context: dead
EOF

echo; echo "drill refusals (the half that needs no cluster):"
drill_refuses() {
  local what="$1" args="$2" want="$3" out
  out=$(./hack/drill.sh $args 2>&1 || true)
  if grep -qF -- "$want" <<<"$out"; then
    echo "  PASS  $what"; pass=$((pass+1))
  else
    echo "  FAIL  $what"; fail=$((fail+1)); sed 's/^/          /' <<<"$out" | head -3
  fi
}
mkdir -p tenants/t1/dev/svc
drill_refuses "a platform component"     "platform/demo --yes"        "not a tenant workload"
drill_refuses "a folder that is not there" "tenants/t1/dev/ghost --yes" "no tenants/t1/dev/ghost/config.yaml"
drill_refuses "without --yes"            "tenants/t1/dev/svc"         "Re-run with --yes"
# Bounded, because the failure this guards is the drill never returning -- and
# it would stop after the freeze, holding an Application nobody knows is held.
dr_out=$(KUBECONFIG="$WORK/kubeconfig.dead" timeout 60 ./hack/drill.sh tenants/t1/dev/svc --yes 2>&1); dr_rc=$?
if [ "$dr_rc" -eq 124 ]; then
  echo "  FAIL  a cluster that did not answer — it hung instead of refusing"; fail=$((fail+1))
elif [ "$dr_rc" -ne 0 ] && grep -qF "the cluster refused the request" <<<"$dr_out"; then
  echo "  PASS  a cluster that did not answer"; pass=$((pass+1))
else
  echo "  FAIL  a cluster that did not answer (exit $dr_rc)"; fail=$((fail+1))
  sed 's/^/          /' <<<"$dr_out" | head -3
fi
printf 'stateful: true\n' >> tenants/t1/dev/svc/config.yaml
drill_refuses "a stateful workload"      "tenants/t1/dev/svc --yes"   "is stateful"
restore

echo; echo "drill refusals that need a kubectl but not a cluster:"
# A stub on PATH answering only what step 0 asks. This runs drill.sh's own
# code rather than a copy of its condition -- a check that restates the thing
# it is checking agrees with itself and nothing else -- and the stub says so
# whenever a patch reaches it, which is what each of these refusals exists to
# prevent.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  # First arm on purpose, and not only for tidiness: the freeze patch's own JSON
  # contains the string `syncPolicy.automated`, so behind that arm it would be
  # answered as a jsonpath read and never reported as a patch.
  #
  # On stderr on purpose too: drill.sh sends every patch's stdout to /dev/null,
  # so a marker printed there is a marker nobody can assert on.
  *"patch application"*)    echo "STUB SAW A PATCH" >&2 ;;
  *"get hpa"*)              printf '%s' "${STUB_HPA:-}" ;;
  *"syncPolicy.automated"*) printf '%s' "${STUB_AUTOMATED:-}" ;;
  *custom-columns*)         echo "Synced   Healthy" ;;
  *"spec.replicas"*)        echo 1 ;;
esac
EOF
chmod +x "$WORK/stub/kubectl"
mkdir -p tenants/t1/dev/svc

stub_drill() {  # stub_drill <name> <want> <automated> <hpa>
  local name="$1" want="$2" out rc
  out=$(PATH="$WORK/stub:$PATH" STUB_AUTOMATED="$3" STUB_HPA="$4" \
        timeout 20 ./hack/drill.sh tenants/t1/dev/svc --yes 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "$want" <<<"$out" && ! grep -q "STUB SAW A PATCH" <<<"$out"; then
    printf '  PASS  %s\n' "$name"; pass=$((pass+1))
  else
    printf '  FAIL  %s   (exit %s)\n' "$name" "$rc"; fail=$((fail+1))
    sed 's/^/          /' <<<"$out" | head -4
  fi
}
stub_drill "a jsonpath that prints a Go map" "which is not JSON" \
  'map[prune:false selfHeal:true]' ''
stub_drill "an HPA on the target"            "HorizontalPodAutoscaler targets" \
  '{"prune":false,"selfHeal":true}' 'Deployment/svc'
stub_drill "an Application already frozen"   "already frozen" \
  '' ''

# The accepting half, and the trap in one: a well-formed policy and an HPA on
# something else gets past step 0 and freezes, then the run is killed during
# the wait. What comes back has to be a hand-back, not a frozen Application --
# and this is the only place that is proved, because on a real cluster it is
# proved by leaving one frozen.
kill_out=$(PATH="$WORK/stub:$PATH" STUB_AUTOMATED='{"prune":false,"selfHeal":true}' \
  STUB_HPA='Deployment/other' timeout 8 ./hack/drill.sh tenants/t1/dev/svc --yes 2>&1)
if [ "$(grep -c 'STUB SAW A PATCH' <<<"$kill_out")" -ge 2 ] \
   && grep -qF "Putting the workload back" <<<"$kill_out"; then
  echo "  PASS  killed after the freeze, hands it back anyway"; pass=$((pass+1))
else
  echo "  FAIL  killed after the freeze, hands it back anyway"; fail=$((fail+1))
  sed 's/^/          /' <<<"$kill_out" | tail -4
fi
restore

echo; echo "compare-live over a cluster that did not answer:"
# The half of compare-live.sh that needs no cluster, and the reason this case
# exists: every kubectl in it ended in `|| true`, so an unreachable cluster
# printed NOT RUNNING for every workload, differed in nothing, and exited 0.
# A tool that says "safe to adopt" when it saw nothing is worse than no tool.
# Under `timeout`, because the third outcome is a hang: this kubeconfig names a
# user with no credentials, and kubectl answers that by asking `Please enter
# Username:` on stdin and waiting. Without the bound, that failure arrives as
# this script never finishing -- neither pass nor fail, which is worse than
# either. It took two and a half minutes of a stuck prover to find.
cl_out=$(KUBECONFIG="$WORK/kubeconfig.dead" timeout 60 ./hack/compare-live.sh 2>&1); cl_rc=$?
if [ "$cl_rc" -eq 124 ]; then
  echo "  FAIL  answers at all — it hung, which is neither refusal nor agreement"
  fail=$((fail+1))
elif [ "$cl_rc" -ne 0 ] && grep -qF "The cluster did not answer" <<<"$cl_out"; then
  echo "  PASS  refuses, instead of reporting every workload NOT RUNNING"; pass=$((pass+1))
else
  echo "  FAIL  refuses, instead of reporting every workload NOT RUNNING (exit $cl_rc)"
  fail=$((fail+1)); sed 's/^/          /' <<<"$cl_out" | head -3
fi
if grep -qF "NOT RUNNING" <<<"$cl_out"; then
  echo "  FAIL  said NOT RUNNING about a cluster it never reached"; fail=$((fail+1))
else
  echo "  PASS  says nothing about workloads it could not look at"; pass=$((pass+1))
fi

echo; echo "section 2 - the machine:"
case_ "address in a machine file" "contains an address" \
  "printf '# see mirror.internal for the mirror\n' >> charts/cluster-config/values.yaml"

echo; echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
