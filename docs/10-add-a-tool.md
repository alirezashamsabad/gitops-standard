# Adding a tool this cluster needs

A tool exists on this cluster because `platform/<name>/` exists. There is no
selection file to also remember, and therefore no long list of `enabled: false`.
Absence is absence.

Add it when a real need appears here — not because another cluster has it. That
is test 4, and it is per cluster: one cluster may run Redis and four apps while
another runs RabbitMQ and ten, and they share the machine, not the inventory.

## The four files

```
platform/<name>/
  component.yaml   what it is and how it is delivered
  values.yaml      how it is configured on THIS cluster
  images.yaml      everything the mirror must hold first
  RUNBOOK.md       healthy / silent failure / what breaks if it stops
```

### component.yaml

```yaml
namespace: <its own namespace>
requires: []                 # folder names under platform/, checked to exist

chart:                       # exactly one of chart / manifestsDir / localChart
  repo: <key from cluster.yaml:chartRepos>
  name: <chart name>
  version: "<exact version>"

sync:
  automated: false           # see below
  selfHeal: true
  prune: false
```

**`chart.repo` is a key, not a URL.** Keys are by purpose, so moving mirror is
one line in `cluster.yaml` rather than one per tool.

**Pick the delivery kind by what the vendor ships.** `chart` for a Helm chart.
`manifestsDir` for a vendor's raw install YAML — take it verbatim so the next
version is a replace and not a merge. `localChart` only when a value has to come
from `cluster.yaml`, which a raw manifest cannot read.

Never a top-level `path:` key. The generator supplies its own `.path` for the
file, and yours would shadow it: the Application name and the source path both
break, and neither failure mentions your file.

**Write all three `sync` keys.** The difference between `prune: false` and not
writing it is the difference between a decision and an oversight.

**Start with `automated: false`.** The folder existing means the Application
exists; this is what stops it syncing before `images.yaml` has been read back
out of the mirror. Turning it true afterwards is a one-line commit — and one
more step, because the commit alone changes nothing on a live cluster.

The ApplicationSets ignore `/spec/syncPolicy` on the Applications they own
(`ignoreApplicationDifferences`), so that an auto-sync switched off during an
incident stays off. The same rule means a `sync` change in git reaches only an
Application that does not exist yet. After the commit has been pushed, delete
the Application once and let the ApplicationSet create it again:

```bash
kubectl -n argocd delete application <tool>
```

Generated Applications carry no finalizer and the ApplicationSet preserves
resources on deletion, so nothing the Application deployed is touched. Confirm
the new one carries the policy from git:

```bash
kubectl -n argocd get application <tool> -o jsonpath='{.spec.syncPolicy.automated}'
```

### images.yaml

```yaml
images:
  - <mirror>/<org>/<image>:<exact tag>
```

Every entry must start with an allowed registry. Read each one back before
turning `automated` on:

```bash
docker manifest inspect <image>
```

A path that is right here and wrong in the registry is `ImagePullBackOff` on the
cluster, a long way from this file.

### RUNBOOK.md

Three questions, and the first one is not "is the Application green":

- **How do you know it is healthy?** Name the command. `Healthy` in Argo CD
  means the Deployment has replicas, not that the thing works.
- **What is its silent failure?** The one that leaves everything green.
- **What breaks if it stops?** Including what keeps working for a while and then
  does not, which is the dangerous kind.

## Then

```bash
python3 hack/validate.py
```

```bash
./hack/check-pins.sh
```

```bash
git diff --name-only HEAD~1
```

The last one must show your folder, and at most `cluster.yaml` if the tool
needed a new `chartRepos` key or a new registry.

Argo CD makes the Application itself. You do not edit an ApplicationSet, and if
you find yourself wanting to, the shelf is wrong.

## Ordering

There is no `wave`. Ordering Applications relative to each other needs
RollingSync, and RollingSync forces autosync off on every Application it
generates — selfHeal with it. Continuous reconciliation is worth more than
ordering, so `requires` records the dependency, the gate checks the folder
exists, and Argo CD retries until the dependency is there. Bring-up takes more
than one reconcile and you can watch it: Degraded, then Healthy.
