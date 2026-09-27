# Migrating a live cluster onto this structure

For a cluster already running from an older GitOps repository. Nothing here is
delete-then-rebuild: on a live cluster that means pruning workloads that are
serving traffic, and the window is not recoverable by a revert.

## The fact that shapes the whole thing

**Both structures name their Applications the same way.** Old and new both
produce `<tenant>-<env>-<service>` and `<tool>`, in the same `argocd` namespace.

If both ApplicationSets are live at once, two controllers own one Application
object and rewrite each other's spec on every reconcile. Nothing about that is
loud: the Application flickers between two correct-looking states.

So the two must never see the same folder at the same time. Everything below
follows from that.

## Phase 0 — before anything is applied

Confirm the old ApplicationSets will not take resources with them. This is the
one prerequisite; without it every step below deletes a workload.

```bash
kubectl -n argocd get applicationset -o json | python3 -c "import sys,json;
[print(a['metadata']['name'], (a['spec'].get('syncPolicy') or {}).get('preserveResourcesOnDeletion'))
 for a in json.load(sys.stdin)['items']]"
```

Every one must say `True`. If any says `None` or `False`, fix that in the old
repository first and let it sync.

Then check that what the new repository declares matches what is running:

```bash
./hack/compare-live.sh
```

Every difference is a decision to make **now**, in the new repository, not
during a cutover. A field that differs is a change disguised as a migration.

## Phase 1 — a branch that starts with no product

The new repository's `main` already contains every folder. If Argo CD pointed at
it, every ApplicationSet would immediately generate every Application and
collide with the old ones.

```bash
git checkout -b migration <the commit before the first platform/ folder>
```

```bash
# on the branch only
sed -i 's/targetRevision: main/targetRevision: migration/' cluster.yaml
```

The branch is the cutover order made explicit: it gains one folder per step, and
each step is a `git revert` away from the state before it.

## Phase 2 — plane 0

Argo CD already exists on this cluster, so only two things are new.

```bash
kubectl -n argocd get secret | grep repository
```

Add a read-only credential for the new repository if it is not there, then:

```bash
./bootstrap/render-root.sh
```

Read it. Then apply it. The AppProjects and the five ApplicationSets appear and
generate **nothing**, because the branch has no product folders yet.

```bash
kubectl -n argocd get applicationset
```

```bash
kubectl -n argocd get application | wc -l
```

The count must be unchanged from before. If it is not, the branch was cut in the
wrong place.

## Phase 3 — one thing at a time

For each folder, in dependency order — tools before the environments that use
them, environments before their workloads.

**1. Take it out of the old repository.**

```bash
git -C <old repo> rm -r platform/<name>        # or tenants/<t>/<env>/<svc>
```

Commit and push. The old Application disappears; its resources stay, because of
Phase 0.

**2. Confirm the resources are still there and now unmanaged.**

```bash
kubectl -n <namespace> get all
```

```bash
kubectl -n argocd get application <name>
```

The second must report `NotFound`. This is the only moment the thing is
unmanaged, and it should be short.

**3. Put it into the new repository's branch.**

```bash
git cherry-pick <the commit that added that folder on main>
```

Push. The new ApplicationSet generates the Application, and Argo CD adopts the
live resources rather than recreating them — `ServerSideApply` takes over field
ownership without a delete.

**4. Check the adoption, not the colour.**

```bash
kubectl -n argocd get application <name> -o wide
```

```bash
kubectl -n <namespace> get events --sort-by=.lastTimestamp | tail -20
```

`Synced` and `Healthy` is not enough on its own. What you are looking for in the
events is the absence of anything that says `Deleted` or `Killing` for a pod
that was already running. **An adoption that restarted the workload was not an
adoption.**

If something is wrong, revert the cherry-pick. The resources stay; you are back
to step 2 with nothing lost.

## Phase 4 — the last step

When the branch has every folder and nothing is left in the old repository:

```bash
git checkout main && git merge migration
```

```bash
sed -i 's/targetRevision: migration/targetRevision: main/' cluster.yaml
```

Commit, push, then patch the root Application to follow `main`:

```bash
kubectl -n argocd patch application cluster-config --type merge -p '{"spec":{"source":{"targetRevision":"main"}}}'
```

Then archive the old repository. Do not delete it: it is the only record of what
the cluster looked like before, and the tag you cut before starting is the thing
you would restore from.

## What this does not migrate

**Namespaces that were never declared.** Anything running that is not in
`cluster.yaml` stays outside this structure and keeps running. Adopting it is a
separate decision, taken deliberately.

**Anything with data, without a plan for the data.** `prune: false` means a
revert will not delete a volume — and also that it will not bring one back.

**A hand-applied object something now depends on.** If the new repository's
routes attach to a Gateway nobody owns, that dependency is real after the
migration too, and the migration is a good moment to decide whether to adopt it.
