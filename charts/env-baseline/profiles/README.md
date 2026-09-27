# Network profiles

What a *kind* of service needs on the network, written once.

**Empty on purpose.** A profile for something no cluster runs is inventory, and
test 4 of the standard refuses it. The first workload that names a profile
brings the file with it — and because `charts/` is machine, that is a `machine`
commit, separate from the `product` commit that adds the workload.

## Shape

```yaml
# charts/env-baseline/profiles/<kind>.yaml
description: >-
  One or two sentences. What this kind of service is, and who legitimately
  talks to it.
ingress:
  - description: Clients within the environment
    from: sameNamespace
    ports:
      - {port: "6379", protocol: TCP}
egress: []
```

A profile describes the service's own requirements. It never contains a
customer's addresses: an external database is a fact about the customer, so it
belongs in `network.extraEgressCIDRs` in that environment's `env.yaml`, and
`hack/validate.py` refuses an address here.

## How an environment gets one

It does not choose. A workload names it:

```yaml
# tenants/<tenant>/<env>/<workload>/config.yaml
networkProfile: redis
```

and `network.profiles` in `env.yaml` is the aggregation of what the workloads in
that environment named. `hack/validate.py` derives the list and refuses a
mismatch in either direction, so the folder is the source and the list is a
view. A hand-kept list here would be the inventory that gates execution which
section 2 of the standard forbids.
