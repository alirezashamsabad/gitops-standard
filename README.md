# One repository, one cluster, one Argo CD

A GitOps structure for Argo CD where everything the cluster runs is a folder, the
folder name is the object name, and a CI pipeline touches exactly one line.

It is built for estates that cannot reach the public internet: every image and
chart comes from a mirror, every version is pinned, and the gates that check all
of it run offline.

```bash
python3 hack/validate.py && ./hack/prove-checks.sh && ./hack/check-pins.sh && ./hack/render.sh
```

Needs `python3` with PyYAML, `helm`, and `bash`. Nothing else, and no network.

## What it is

Two repositories, and one direction of travel between them.

| | holds | travels |
|---|---|---|
| **this repository — the standard** | the machine: `charts/` `hack/` `bootstrap/`, and `docs/` | copied one way into every cluster repository |
| **a cluster repository** | the machine, plus `cluster.yaml` `platform/` `tenants/` | nothing leaves it |

One cluster, one repository. A customer with a nonprod and a prod cluster has two;
there is no folder inside one that means "the other cluster".

A cluster repository never edits the machine. Not by convention — its CI refuses a
commit that mixes the two classes, because a mixed commit cannot be merged one
way. `hack/sync-machine.sh` does the merging and `docs/15-a-new-cluster-repo.md`
is the procedure.

## Start here

```bash
./hack/sync-machine.sh ../gitops-config-mycluster --genesis
cp cluster.example.yaml ../gitops-config-mycluster/cluster.yaml
```

Then fill in `cluster.yaml` — registries, chart mirrors, tenants and their
namespaces, gateway, base domain — and read `docs/00-orientation.md`.

## Nothing here is an Argo CD Application

Folders are. Three ApplicationSets in `charts/cluster-config` turn every folder
into one, so adding a service is adding a folder and there is no list anywhere for
anyone to forget to update.

```
cluster.yaml             registries, chart mirrors, tenants, namespaces, domain
platform/<tool>/         one cluster tool: component.yaml, values.yaml,
                         images.yaml, RUNBOOK.md
tenants/_shared/         value layer 1: every tenant, every environment
tenants/<t>/<e>/env.yaml one environment: namespace, quotas, policy
tenants/<t>/<e>/<svc>/   one workload: config.yaml + values.yaml

charts/cluster-config    the AppProjects and the three ApplicationSets
charts/env-baseline      namespace, labels, quota, limits, policy
hack/                    the four gates, and five tools that are not gates
bootstrap/               everything a human runs once, before Argo CD can sync
docs/                    how to work in it
```

`tenants/<t>/<e>/<svc>/` becomes the Application `<t>-<e>-<svc>` and the Helm
release `<svc>`. **The folder name is the service name** — nothing inside the
folder restates it, so the two cannot drift, and the name must be a valid
Kubernetes object name because that is what it becomes.

## A pipeline touches one line

```yaml
# tenants/<tenant>/<env>/<service>/config.yaml
image:
  repository: <mirror>/<tenant>/<service>
  tag: v1.2.3          # <- the only line a pipeline writes
```

A filled-in version of the whole product half is in `examples/`, and
`hack/check-examples.sh` proves it still passes every gate.

Nothing else. Not the Application, not the namespace, not the chart version.
A promotion from dev to qa is the same line in the next folder.

## The four gates

| gate | asks |
|---|---|
| `validate.py` | do the files say something consistent and allowed |
| `prove-checks.sh` | does every check actually refuse what it claims to — it breaks each rule on purpose and expects the refusal |
| `check-pins.sh` | is every image and chart pinned to an exact version |
| `render.sh` | does what the files produce render, and would the API server hold it |

`prove-checks.sh` is the unusual one and it is why the other three can be
trusted. **A check that matches nothing passes silently and is indistinguishable
from coverage.** So every rule has a case that breaks it deliberately; if the
refusal does not arrive, the case fails. When you add a check, add its case in the
same commit.

Every refusal from `validate.py` comes from a function whose docstring explains
the failure it prevents and why that failure is hard to see. Read the docstring
before working around the rule.

## Five things in `hack/` that are not gates

They reach a cluster, a registry or another repository, which is why they are not
gates and are not in CI. Each is run deliberately, and each refuses rather than
guessing when the thing it talks to does not answer.

| tool | does |
|---|---|
| `check-mirror.py` | asks the registry and the chart mirror whether everything this repository declares is actually there |
| `compare-live.sh` | compares a running cluster against what these files say |
| `sync-machine.sh` | carries the machine into a cluster repository, or starts one |
| `drill.sh` | breaks one thing on purpose and proves the structure recovers |
| `cutover.sh` | moves a workload that is already running onto this structure |

`check-mirror.py` is the one to run before turning any component's
`sync.automated` on. An image the mirror does not have is `ImagePullBackOff`
underneath an Application reporting `Synced` and `Healthy`, and no gate can see
that, because no gate reaches a registry.

## Commit classes

```
Machine:        a change to the machine, made here
Machine merge:  that same change, in a cluster repository
<subject>:      a product change, in a cluster repository, one folder
```

## Licence

Apache-2.0. See `LICENSE`.
