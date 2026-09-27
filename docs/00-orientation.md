# Orientation — what this repository is

One repository, one cluster, one Argo CD. If a customer has a nonprod cluster
and a prod cluster, that is two repositories. There is no folder inside one that
means "the other cluster".

Everything here is one of two things, and knowing which is the first thing to
work out about any file:

| | what it is | where | how it travels |
|---|---|---|---|
| **machine** | `charts/`, `hack/`, `bootstrap/` | built once | merged one way into every cluster repo, never edited here |
| **product** | `cluster.yaml`, `platform/`, `tenants/`, `shared/` | this cluster only | never merged anywhere |

The machine contains no address, no customer name and no tool inventory. If you
find one, that is a bug and `hack/validate.py` will usually already be saying so.

## The four planes

Only the third and fourth are in this repository.

| plane | what | who applies it |
|---|---|---|
| 0 | Argo CD itself, its repo credential, the root Application | a human, once — see `bootstrap/` |
| 1 | CNI, CSI, load-balancer addresses, L2 or BGP | Ansible or helm, outside this repo |
| 2a | cluster tooling: `platform/<tool>/` | Argo CD |
| 2b | tenant workloads and environments: `tenants/`, `shared/` | Argo CD |

`cluster.yaml` **claims** things about plane 1 so they can be checked. It never
applies them. A repository that could delete an address pool could take down
every service on the cluster at once, including ones it does not manage.

## What decides whether something belongs here at all

Four tests. All four must hold.

1. **Argo CD can apply it without it already being applied.** If syncing needs
   the thing itself, that is a loop. This is why the CNI, the CSI, the address
   pool and Argo CD are not here — not because they are delicate, but because
   the dependency is circular and that is not a matter of opinion.
2. **Its desired state is fully expressible as data.** Deploying a Vault, yes.
   `operator init` and unsealing it, no: that is a ceremony with keys a human
   holds.
3. **Reverting the file really reverts the thing.** If `git revert` does not
   bring the data back, this repository is offering an undo it does not have.
   That is what forbids `prune` on anything stateful.
4. **It exists today, on this cluster.** Nothing is declared for later. A
   contract written ahead of the thing it describes is the expensive kind of
   mistake: declare a health endpoint before any application implements one and
   the startup probe kills every pod, while the container log says
   `Application is shutting down...` — a
   graceful message for a kill, naming no probe.

## Two classes of commit

**`product`** adds or changes one tool or one app. It may touch that thing's own
folder, and `cluster.yaml`, and the shared value layers. Nothing else.

```bash
git diff --name-only HEAD~1
```

If anything outside that list appears, the shelf is wrong — not the service.

**`machine`** changes `charts/`, `hack/` or `bootstrap/`. The shelf test does
not apply; the rules in `docs/20-gates.md` do. One commit is never both.

## Where to go next

| you want to | read |
|---|---|
| **understand how any of this works** | `docs/01-how-it-works.md` — start here |
| bring up a new cluster | `bootstrap/README.md` |
| start a cluster repository from this one | `docs/15-a-new-cluster-repo.md` |
| carry a machine change into a cluster repository | `docs/15-a-new-cluster-repo.md` |
| add a tool the cluster needs | `docs/10-add-a-tool.md` |
| add an application | `docs/11-add-an-app.md` |
| add an environment | `docs/12-add-an-environment.md` |
| understand a refusal from the gate | `docs/20-gates.md` |
| remove an application, a tool or an environment | `docs/13-remove-something.md` |
| configure Vault on a new cluster | `docs/05-vault-eso.md` |
| something is broken right now | `docs/30-incident.md` — it opens with a symptom table |

## These pages are machine, and they are not merged out

`charts/`, `hack/` and `bootstrap/` go into every cluster repository one way.
`docs/` does not, and that is deliberate rather than an omission.

These pages describe the structure itself, and the structure has one home. A
cluster repository that carried its own copy would carry a copy that can go stale
against the machine beside it, and there would then be as many versions of the
explanation as there are clusters. One copy, here, alongside the code it explains.

What a cluster repository carries instead is the documentation that belongs to the
thing it describes, which is per cluster and cannot live here:

```
platform/<tool>/RUNBOOK.md    how that tool is healthy, and what its silent failures are
bootstrap/README.md           the procedures a human runs against that cluster
README.md                     what the repository is and how to run its gates
```

Two checks here read `docs/` off disk and are therefore silent in a cluster
repository: `check_a_page_does_not_hand_back_a_written_out_syncpolicy` and
`check_the_seeding_page_defers_to_the_script`. Their docstrings say so. A check
that is silent in one of the two places is not broken; a check nobody knows is
silent is.

