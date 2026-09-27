# The gates, and why each refusal exists

Run all four before a push. None of them reaches the network.

```bash
python3 hack/validate.py
```

```bash
./hack/prove-checks.sh
```

```bash
./hack/check-pins.sh
```

```bash
./hack/render.sh
```

`render.sh` skips remote charts by default, because a workstation usually cannot
reach the mirror. CI is inside the estate and sets `WITH_REMOTE=1`, so the
pipeline renders more than you do here. If you are on the network, run the same
thing before pushing:

```bash
WITH_REMOTE=1 ./hack/render.sh
```

## The rule behind the rules

Every refusal in `validate.py` was written after a real failure whose error
message named the wrong thing. That is the bar for adding one: not "this could
be wrong" but "this was wrong, and what it said was misleading".

The companion rule matters as much: **a check you have not seen fail is not a
check.** `hack/prove-checks.sh` breaks every rule on purpose, one at a time, on a
throwaway copy, and confirms the gate refuses it.

A check whose pattern matches nothing passes on every run and produces exactly the
output of a check that is working. Nothing distinguishes the two from the outside,
so the only way to know a rule is enforced is to watch it refuse.

When you add a check, add its case in the same commit.

## The shapes it refuses, and what each one looks like without it

| refused | what happens otherwise |
|---|---|
| a probe port no container declares | connection refused → SIGTERM → a graceful shutdown line naming no probe |
| a Service `targetPort` outside the container ports | the pod is healthy and the Service has no backend |
| `envFrom` naming a ConfigMap nothing renders | `CreateContainerConfigError`, naming the ConfigMap and not the layer that asked |
| a chart workload with no `image` | the chart renders its own default and the app is Healthy running it |
| an unpinned chart or a floating tag | a different render on a day nobody changed anything |
| `stateful` with `prune: true` | the PVC goes, and `git revert` does not bring data back |
| `requires` naming a folder that is not here | a sync failure naming neither component |
| an httpRoute hostname outside `baseDomain` | Accepted, and matches nothing |
| a parentRef naming another Gateway | Accepted with `ResolvedRefs=False`, in a status field |
| `platformNamespaces` disagreeing with the folders | Argo CD says the project does not permit the destination |
| an address or customer name in the machine | the machine stops being portable, quietly |
| an ApplicationSet without `ignoreApplicationDifferences` | your break-glass edit is reverted within seconds |
| an ApplicationSet without `preserveResourcesOnDeletion` | a folder removed by a bad rebase cascades to a PVC |
| `RespectIgnoreDifferences` missing from syncOptions | `ignoreDifferences` affects only the diff; sync stomps the field anyway |
| a rendered container declaring one env var twice | server-side apply refuses the object; Argo CD sits at ComparisonError, naming a field and no file |
| a CI `render` job that leaves remote charts alone | every chart the platform installs is rendered for the first time by Argo CD, on main |

## When a check is in your way

Two honest options and one dishonest one.

Fix the file. Or decide the check is wrong and change it — in a `machine`
commit, with the case in `prove-checks.sh` changed alongside so the new rule is
proved too.

Never `|| true`, never `2>/dev/null`, never a special case for one name. A gate
that can be talked out of a refusal is not one.
