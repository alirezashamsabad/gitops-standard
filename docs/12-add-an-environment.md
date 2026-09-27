# Adding an environment

An environment is a namespace with a budget and a network posture. It is owned
by exactly one thing — `charts/env-baseline` — and that is why a tenant
Application never carries `CreateNamespace=true`. A namespace built here arrives
with its quota and its policy attached; one built by a workload arrives bare, and
two owners that agree on the name and nothing else is worse than none.

## Two files

Declare it in `cluster.yaml`:

```yaml
tenants:
  - name: <tenant>
    environments:
      dev: <namespace>
      qa: <namespace>
```

The AppProject destinations are derived from this. A namespace that is not here
is refused by Argo CD with a message naming the project, not the missing entry.

Then the environment itself:

```yaml
# tenants/<tenant>/<env>/env.yaml
tenant: <tenant>          # must match the folder
env: <env>                # must match the folder
namespace: <same as cluster.yaml>

podSecurity:
  enforce: baseline
  audit: restricted
  warn: restricted

resourceQuota: {enabled: false, hard: {}}
limitRange:    {enabled: false}

network:
  enabled: false
  profiles: []
```

This file is **both** the generator file and the values file for
`charts/env-baseline`, so what selects the environment and what configures it
cannot drift apart.

## The three settings people get wrong

**`network.enabled: false` means no policy at all.** Not a permissive one. The
two look the same in a diff and behave nothing alike, which is why the gate
refuses the key being absent — absent would read as `false` and mean something
nobody chose.

Turn it on only against a **measured** dependency list. A default-deny over a
guessed one fails as timeouts, with nothing in any log naming the policy that
dropped the packet.

**Start with the quota off.** A budget invented before a workload exists is a
number nobody measured, and the first thing it does is refuse a pod with
`exceeded quota` — which names the quota and not the guess behind it. Turn it on
with numbers taken from what the environment actually consumes.

**`enforce: baseline` before `restricted`.** Enforcing a policy the images have
never had to satisfy is how an environment refuses every pod for a reason the
pod's own events do not mention. `audit` and `warn` at `restricted` report the
gap before it is enforced.

## Ordering

Objects inside the environment's Application are ordered: namespace, then quota
and limits, then policy. That ordering does **not** reach across Applications —
a workload whose namespace does not exist yet fails and is retried, and
converges. Sync waves are not a gate between Applications.
