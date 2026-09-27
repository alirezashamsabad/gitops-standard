# A worked example of the product half

Everything a cluster repository holds and this one does not: a filled-in
`cluster.yaml`, two platform components, one tenant with two environments, and
two workloads showing two of the three delivery shapes.

```
cluster.yaml                         filled in, for one imaginary cluster
platform/cert-manager/               a component delivered by a remote CHART
platform/redis-operator/             a second, and where an instance must NOT go
tenants/_shared/values.yaml          value layer 1, and what deliberately is not in it
tenants/acme/dev/env.yaml            one environment
tenants/acme/qa/env.yaml             the second, identical in shape
tenants/acme/{dev,qa}/orders/        a workload delivered by a chart, in both
tenants/acme/dev/redis/              a STATEFUL workload delivered by RAW MANIFESTS
```

## Why it is here and not at the root

The standard has no `cluster.yaml`, no `platform/` and no `tenants/`, and that is
load bearing: the machine must contain no address, no customer name and no tool
inventory, and `hack/validate.py` refuses all three. A product half at the root
would become exactly the inventory the machine is forbidden to have.

## It is checked, not decorative

```bash
./hack/check-examples.sh
```

That builds a throwaway cluster repository out of the machine and this tree and
runs the gates on it, as a real one would. An example nothing checks is the first
thing a newcomer copies and the first thing to rot, and it rots into something
that looks authoritative.

It earns its keep in both directions: because this tree supplies a `cluster.yaml`
with real tenants in it, the gate also runs the checks that are structurally
silent in the standard — the ones that refuse a customer or service name in the
machine can only fire where there are names to compare against.

## To start from it

```bash
./hack/sync-machine.sh ../gitops-config-mycluster --genesis
cp examples/cluster.yaml ../gitops-config-mycluster/cluster.yaml
cp -r examples/platform examples/tenants ../gitops-config-mycluster/
```

Then change every value, and fix `manifestsDir` in `tenants/acme/dev/redis/config.yaml`:
it is written `examples/tenants/...` here so a reader can follow the path to the
files, and in a real repository the prefix is gone. `hack/check-examples.sh`
rewrites it the same way when it materialises this tree.

`docs/15-a-new-cluster-repo.md` is the full procedure, and
`cluster.example.yaml` at the root is the same `cluster.yaml` with `SET-`
placeholders, for filling in from scratch instead of editing a copy.
