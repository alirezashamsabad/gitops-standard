# Something is broken right now

One page. Read the first section before touching anything, because half the
worry about GitOps during an incident is misplaced and knowing which half saves
the argument.

## What you are looking at, and where it is answered

Every row is a symptom this structure can produce. Find the line you are staring
at.

| what you see | what it usually is | where |
|---|---|---|
| `ComparisonError` naming a field | the rendered object, or the live one — read which | §0.1 below |
| Application `Healthy` but nothing works | probes are off here; Healthy means the Deployment has replicas | `docs/01-how-it-works.md` §2 |
| `Healthy` and the Service has no backend | the container port is wrong; check what the app really listens on | `docs/11-add-an-app.md` |
| `OutOfSync` on a Vault Application | `automated: false`, deliberately — they wait for a human | `docs/05-vault-eso.md` |
| `OutOfSync/Missing` on a promoted workload | held back on purpose, or CI has not promoted yet | `docs/01-how-it-works.md` §7 |
| `ImagePullBackOff` in a tenant namespace | `regcred` has not arrived — the chain is in §4 of how-it-works | `docs/05-vault-eso.md` |
| `is not permitted in project` | the AppProject whitelist, derived from `cluster.yaml` | `docs/20-gates.md` |
| `ExternalSecret` `Ready` and no Secret anywhere | the namespaceSelector matched nothing | `docs/05-vault-eso.md` |
| `SecretSynced` but the credential 401s | synced is not valid; prove the credential | `docs/05-vault-eso.md` |
| `volume ... is not ready for workloads` | Longhorn reservations, not disk space | `docs/13-remove-something.md` §4 |
| `insufficient storage` with free disk | same — `storageScheduled` above `storageMaximum` | `docs/13-remove-something.md` §4 |
| `vault-transit-0` `0/1`, readiness 503 | it restarted and came back sealed — every restart does this | §7 below |
| a main Vault pod `0/1` while transit is open | it started during a window when transit was sealed | §7 below |
| Vault pod `0/1 Running` and staying | sealed or uninitialised; that is what readiness means here | §7, then §6 |
| Vault `Initialized true` `Sealed true` forever | the transit key is gone | §6 below |
| `permission denied / invalid token` from Vault | two root tokens exist; or a sealed Vault refusing everything | §6 below |
| a new hostname answers `301` to `/ui/`, or `404` from nothing you deployed | a route with no hostname is claiming it — see §8 | §8 below |
| a hostname that worked yesterday now 404s | its route was renamed and the old host fell through to the catch-all | §8 below |
| a pod runs an image git does not name | its StatefulSet cannot replace a pod that never became Ready | §9 below |
| an Application is `Healthy` over a pod that never started | the kind has no health check; Argo reports the object exists | §9 below |
| a gate is red in CI and green on your laptop | the runner: Python 3.9, no helm, `/tmp` noexec | `docs/20-gates.md` |

### 0.1 ComparisonError — read which side it names

`ComparisonError` is neither `Synced` nor `OutOfSync`. Argo CD could not build a
comparison at all, so nothing on this page works until it is cleared: a sync
will not run, `selfHeal` has nothing to act on, and a fix committed to git
changes nothing.

```
error running server side apply in dryrun mode ... failed to create typed patch
```
is the **desired** state — what your commit renders. Fix the file, sync, done.

```
error removing non config mutations ... error converting live state
```
is the **live object**, and no commit reaches it. Delete the object and let a
sync recreate it. Full detail in §0 of this page.

The condition clears when the object goes; the UI panel does not. Read the
object, not the panel:

```bash
kubectl -n argocd get application <name> -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

Nothing printed is the answer. And do not read `.status.sync.revision` to check
which commit is in play — an Application with more than one source leaves it
empty and fills `.status.sync.revisions` instead.

## 0. What Argo CD will and will not undo

Argo CD only fights what it manages, and most incident work is not that.

```
kubectl exec ... rabbitmqctl forget_cluster_node    Argo never sees it
kubectl delete pod ...                              recreated by its own controller
kubectl cordon / drain                              nothing to do with Argo
```

What it **will** revert, within seconds, is an edit to a resource it manages:
changing `replicas` on a CR, editing a Deployment, deleting a Service. If your
fix is one of those, freeze first.

### The state where none of the rest of this page works

`ComparisonError` is neither `OutOfSync` nor `Degraded`. It means Argo CD could
not build a comparison at all — and everything on this page runs through
comparison. A sync will not run, `selfHeal` has nothing to act on, and a fix
committed to git changes nothing on the cluster.

Read which side the message names.

```
error running server side apply in dryrun mode for resource ...
failed to create typed patch object ...
```

is the **desired** state: what your commit renders. Fix the file, sync, done.

```
error removing non config mutations for resource StatefulSet/vault-transit:
error converting live state from unstructured to apps/v1, Kind=StatefulSet:
.spec.template.spec.containers[name="vault"].env:
duplicate entries for key [name="VAULT_ADDR"]
```

is the **live** object, and no commit can reach it. The shape is always the same:
a values file sends an environment variable through a chart that already sets it;
the API server accepts the object, because a repeated env name is a warning there
and not a rejection; and the commit that removes the duplicate leaves the live
object exactly as it was. Argo CD can no longer parse the thing it is
holding.

The repair is by hand, and what has to go is the object, not the file:

```bash
kubectl -n <namespace> delete statefulset <name>
```

Then sync the Application, which recreates it from the git state that is
already correct. `--cascade=orphan` keeps the pods and lets the new StatefulSet
adopt them; use it when a pod must survive, and know that you are choosing it —
for a stateful service that is a decision, not a detail. PersistentVolumeClaims
survive either way; a StatefulSet does not delete them.

The condition clears the moment the object goes. The UI panel does not: it kept
showing this error for an Application whose `status.conditions` was already
empty, through a hard refresh, with the StatefulSet deleted and no pod in the
namespace. Read the object, not the panel:

```bash
kubectl -n argocd get application <name> -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

Nothing printed is the answer. And do not read `.status.sync.revision` to check
which commit is in play — an Application with more than one source leaves it
empty and fills `.status.sync.revisions` instead, so the empty field looks like
a failure and is not one.

Section 4 does not apply afterwards. Nothing has drifted — git was right the whole
time, and the cluster was holding an object it could no longer describe.

## 1. Freeze — two ways, and one that does not work

**Do not `kubectl edit appproject`.** The AppProjects are rendered by
`charts/cluster-config`, which is itself an Application. The root Application
puts your edit back. The same ownership question applies to the freeze mechanism
as to everything else.

**Fast, one service.** Two commands, and the first one is not optional.

Read what auto-sync says now, and keep it somewhere you will still have it in an
hour. Step 4 puts back what you write down here, and nothing else knows it:

```bash
kubectl -n argocd get application <name> -o jsonpath='{.spec.syncPolicy.automated}'
```

It prints something like `{"prune":false,"selfHeal":true}`. Two answers are not
that:

- **nothing at all** — the Application is already frozen, by a hand or by a
  drill that did not finish. Find out whose freeze it is before adding yours.
- **`map[prune:false selfHeal:true]`** — that is Go's map printing, not JSON,
  and it will not go back in as a patch in step 4. Get the JSON with
  `-o json` and take `.spec.syncPolicy.automated` out of it.

Then freeze:

```bash
kubectl -n argocd patch application <name> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

This works only because every ApplicationSet here carries
`ignoreApplicationDifferences` on `/spec/syncPolicy`. Without it the controller
would put auto-sync back within seconds.

**Durable, a whole namespace.** Commit a deny window to the AppProject:

```yaml
syncWindows:
  - kind: deny
    schedule: '* * * * *'
    duration: 24h
    namespaces: [<namespace>]
    manualSync: true
```

`deny` beats `allow`. `manualSync: true` is the point: automatic is closed, a
human can still sync deliberately.

## 2. Know how long a change takes here

With a webhook, seconds. Without one, up to `timeout.reconciliation` — the value
set in `bootstrap/argocd-values.yaml`, **and if it is not written here, write it
now**:

> reconciliation interval on this cluster: `_______`

Three minutes per attempt is the difference between using this repository during
an incident and going around it with `kubectl` and not coming back.

To stop waiting once:

```bash
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite
```

If a sync seems stuck, an operation from a previous attempt may still be held.
It does not time out quickly and backoff makes it look idle:

```bash
kubectl -n argocd patch application <name> --type json -p '[{"op":"remove","path":"/operation"}]'
```

That errors harmlessly when there is no operation — which is itself the answer
to "is it stuck".

## 3. Fix it

Whatever it takes. Exec into the pod, scale to one, delete the PVC if that is
genuinely the call. The freeze is what makes this safe.

One exception, because it is the reflex that costs the most:
`kubectl delete pod --force` **on a StatefulSet pod**.

`--force` does not make anything stop. It removes the record from the API
server while the container may still be running. For a StatefulSet that record
is the identity — `vault-1` is a raft member, not an interchangeable replica —
so a replacement can start with the same name, the same volume claim and the
same cluster membership while the first one is still writing. On a raft cluster
or a database that is how two members holding one identity come to disagree,
and nothing reports it.

It is safe on a pod that holds nothing yet: an uninitialised Vault, a
StatefulSet that has never come up. Anywhere else, wait for the ordinary
delete, and if it will not terminate, find out why before forcing it.

## 4. Reconcile — not optional, and it is the step that gets skipped

Everything done by hand goes back into git and is applied from git again. The
person who made the change and the platform team own this together.

Until it is done, the service **stays frozen**, and that is deliberate: a frozen
Application is visible, and undocumented drift is not. Six months later someone
reverts a file and something comes back that was never there.

Put back **what step 1 printed**, not a value from this page:

```bash
kubectl -n argocd patch application <name> --type merge -p '{"spec":{"syncPolicy":{"automated":<what step 1 printed>}}}'
```

Do not write `{"selfHeal":true,"prune":false}` out here. That is right for most
workloads and wrong for any that declares `prune: true`, and
the same `ignoreApplicationDifferences` that makes the freeze work means the
ApplicationSet will not correct it: the wrong value stays, silently, on a service
somebody has just finished fixing. `hack/drill.sh` reads the live value at its
step 0 and hands back exactly that; this page has to do the same by hand.

Then remove the deny window if you committed one, and confirm the Application is
Synced against the commit you just made — not merely Healthy.

## 5. The whole cluster, from nothing

`git revert` and let it sync. That works for everything in `platform/`,
`tenants/` and `shared/`.

It does **not** cover:

- **Plane 1** — CNI, CSI, addresses. Different repository, different runbook.
- **Argo CD itself** — reinstall from `bootstrap/`, by hand, on purpose.
- **A secret store's keys.** Unsealing is a ceremony, not data. If yours uses a
  transit unseal, the order matters: the transit instance first, then the one
  that depends on it. Restarting them together leaves the second sealed.
- **Data.** `prune: false` on stateful things means a revert does not delete a
  volume. It also means a revert does not bring one back.

## 6. The root token is gone

Nothing stops working the moment you notice. Vault stays unsealed -- auto-unseal
uses the transit token, not this one -- External Secrets keeps authenticating
through Kubernetes auth, and every Secret it has already written stays where it
is. What you have lost is administration: no root token, and if the recovery
keys were in the same file, no `vault operator generate-root` either.

Look for it before anything else. It is one file and it is small:

```bash
find / -xdev -name "main-init.json" 2>&1 | grep -v Permission
```

and on every machine it might have been copied to. A file called
`vault-transit-init.json` is **not** it — tell them apart by their contents
rather than their names:

```bash
python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print('unseal:',len(d.get('unseal_keys_b64',[])),'recovery:',len(d.get('recovery_keys_b64',[])))" <file>
```

The transit Vault's file has 5 unseal keys and 0 recovery keys. The main
Vault's has 0 and 5, because it is transit-sealed and has no unseal keys at all.

### Before anything: do not rebuild the transit Vault to fix this

A transit-sealed Vault's master key is stored encrypted with the transit key.
Rebuild the transit Vault and that key is gone — a new one with the same name
is a different key, and `autounseal-nonprod` names the same thing only in the
sense that two people can share a first name. Every Vault it sealed is then
initialised, sealed, and unopenable.

The recovery keys do not help. They authorise `generate-root` and `rekey` on a
Vault that is already open. They are not unseal keys, and a transit-sealed
Vault has none.

So the two are rebuilt together or not at all, in this order: transit first,
then the Vault it seals. `bootstrap/vault-day0.sh` says so while it runs and
refuses to call a sealed Vault up at the end.

### If the recovery keys survived

`vault operator generate-root` issues a new root token from a threshold of
them, and nothing is destroyed.

### If they did not

Rebuild the main Vault, and only it. This is cheaper than it sounds, and the
reason is worth knowing before the day you need it: the main Vault holds the KV
mount, the Kubernetes auth backend, one policy and one role — and
`bootstrap/seed-vault-kv.sh` recreates all of it from this repository in a few
minutes. What is not in this repository is the values in KV, which is why the
operator is prompted for them again.

**The transit Vault is not touched.** It is what unseals the new main Vault,
its token is already in `vault/vault-transit-token`, and its own keys are in
whoever's hands they were.

```bash
kubectl -n vault delete statefulset vault
```

```bash
VOLS=$(kubectl -n vault get pvc -o jsonpath='{range .items[*]}{.spec.volumeName}{" "}{end}'); echo "$VOLS"
```

Read that list before the next line. Those three volumes are the Vault's raft
storage and they are about to go.

```bash
kubectl -n vault delete pvc --all && kubectl delete pv $VOLS && kubectl -n longhorn-system delete volumes.longhorn.io $VOLS
```

The PersistentVolumes and the Longhorn volumes both, because `reclaimPolicy` is
`Retain` here: deleting a PVC leaves the PV, and deleting the PV leaves the
Longhorn volume holding the disk. See `REBUILD.md` section 2.5.

Then sync the Application and run the ceremony again. It skips the transit half
on its own.

```bash
kubectl -n argocd patch application vault --type merge -p '{"operation":{"initiatedBy":{"username":"bootstrap"},"sync":{"prune":false,"syncStrategy":{"apply":{}}}}}'
```

```bash
./bootstrap/vault-day0.sh && ./bootstrap/seed-vault-kv.sh
```

External Secrets goes NotReady while the KV mount does not exist and recovers
when it does. Secrets already written stay written throughout, so no workload
notices.

## 7. The transit Vault is sealed again

This is not a fault and it will happen again. The transit Vault is sealed with
Shamir over a file on a PVC, so it comes back **sealed** from every restart
there is: a node reboot, a drain, an eviction, an OOM kill, a Longhorn volume
detaching and reattaching. Nothing unseals it but a human with three of five
keys.

What it looks like:

```
pod vault-transit-0   0/1 Running
Readiness probe failed: HTTP probe failed with statuscode: 503
```

That 503 is the signal, and it is deliberate — `platform/vault-transit/values.yaml`
makes readiness fail while sealed precisely so a sealed transit leaves the
Service endpoints instead of looking healthy. Liveness tolerates sealed, because
a restart cannot supply a key and killing it there is a loop nobody can break.

### Why it is urgent even though nothing is broken

Look at the rest of the cluster while transit is sealed and everything is fine.
The main Vault is unsealed and serving, External Secrets is reading it, every
Application is Synced. That is the trap: **a Vault only unseals at startup.**
The main Vault does not need transit again until one of its pods restarts — and
when that happens, with transit sealed, the pod comes up initialised, sealed and
with nothing to open it.

This state can persist for as long as nobody restarts a main Vault pod. A node
event restarts the transit pod, it comes back sealed, and the only thing saying so
is a readiness probe returning 503 — which no dashboard shows unless something is
scraping it. Until the next main Vault restart everything serves normally, and the
platform is one pod restart away from losing its secret store.

### What to run

```bash
./bootstrap/unseal-transit.sh
```

It unseals, proves the auto-unseal token still encrypts against the transit key,
and then reports the seal state of every main Vault pod. It initialises nothing
and wipes nothing — `vault-day0.sh` is not the script for this, and reaching for
it here is how a routine restart becomes a rebuild.

It needs `transit-init.json` back on the node. That file lives in custody, off
this machine, which is correct — so this is the moment the ceremony needs a
human, not a defect:

```bash
scp transit-init.json root@node1:/root/vault-keys/
```

Shred it again when the script finishes; the script prints the command.

### If a main Vault pod is still sealed

The script exits non-zero and names them. A Vault never retries its unseal, so
they stay sealed until they restart — and transit is open now, so a restart is
all they need. One at a time, each back to `1/1` before the next, because they
are a raft quorum:

```bash
kubectl -n vault delete pod vault-1
```

Watch it come back on its own. Auto-unseal takes seconds, including the image
start. If it comes back sealed,
stop and read §6: that is the transit key being gone, which is a different
problem with a much longer answer.

### Why there is no alert for this

`vault_core_unsealed` is the one metric that reports this from outside the
cluster's own endpoint logic, and it needs something scraping it.
`serverTelemetry.serviceMonitor.enabled` is `false` in both Vault values files,
because turning it on before a Prometheus operator exists makes Argo CD refuse the
whole Application rather than skip the one object it cannot create. Until the
operator is there, the readiness probe is the only signal and nothing reads it for
you.

Check it by hand after any node reboot, drain or upgrade. `-n` twice does not
mean two namespaces — the second one wins — so it is two commands:

```bash
kubectl get pods -n vault-transit
```

```bash
kubectl get pods -n vault
```

## 8. A hostname answers something you did not deploy

An `HTTPRoute` with no `hostnames` matches **every** host that reaches its
listener. On a listener that also has no `hostname` and `allowedRoutes.from:
All`, that is every host in the cluster, and it turns every hostname mistake
into a plausible-looking answer instead of an error:

| what happened | what you expect | what you get |
|---|---|---|
| a typo in a DNS record | an error | whatever the catch-all serves |
| a route that has not synced yet | an error | the same |
| a hostname you renamed | an error | the same, from the old name |
| any `Host:` header at all against the listener's address | an error | the catch-all's backend, exposed |

This is not a bug in Gateway API. A route without `hostnames` is defined to
match all of them, and the `gitops.internal` gate refuses one in any namespace
this repository owns — `httpRoute.enabled` with no hostnames is an error at
`validate.py`. It is only reachable from a route applied outside this
repository.

### Recognising it

The response code is the tell, and it is never the code you were looking for:

```bash
curl -isS -H 'Host: <the hostname>' http://<gateway address>/ | head -8
```

A `location:` or a body naming a service you did not deploy means you reached a
catch-all. So does a `404` on a path that your application does not even have a
handler for — a 404 from the wrong backend and a 404 from the right one look
identical in `%{http_code}`, which is why this asks for headers.

Renaming a route is where it bites hardest, because the sequence reads as a
regression:

```
before the sync   old hostname -> your app       400   (the app's own answer)
after  the sync   old hostname -> the catch-all  404
```

Two identical commands, two different codes, and nothing changed about your
application. The second one is not your service failing; it is your service no
longer being addressed by that name.

### Fixing it

Give the catch-all a hostname. One line, on the route that has none:

```bash
kubectl get httproute -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.hostnames[*],PARENT:.spec.parentRefs[*].name
```

Any row whose `HOSTS` column reads `<none>` is a catch-all. If it belongs to a
namespace this repository does not manage, that is a change to somebody else's
object and a decision for whoever owns it — not something to patch quietly,
because a service that has been reachable on every hostname for months may have
callers that rely on it.

Until then, treat an unexpected `301`, `404` or redirect on a **new** hostname
as "not routed yet" rather than "broken".

## 9. The pod is running an image that is in no file anywhere

Three places agree and the fourth does not:

```bash
grep image tenants/<t>/<e>/<svc>/manifests/*.yaml     # v7.0.15
kubectl -n <ns> get sts <name> -o jsonpath='{.spec.template.spec.containers[*].image}'   # v7.0.15
kubectl -n <ns> get pod <name>-0 -o jsonpath='{.spec.containers[*].image}'               # v7.4.0
```

git is right. The StatefulSet is right. The pod is a month behind and pulling
something nobody has asked for since.

### Why

A StatefulSet with the default `podManagementPolicy: OrderedReady` will not
touch pod N until every pod before it is **Running and Ready**. That rule is
what makes ordered storage safe, and it applies to updates as well as to
creation.

So a pod that can never become Ready blocks its own replacement. The new spec
is sitting in the template, the controller is waiting for the old pod to be
healthy before it rolls it, and the old pod is unhealthy precisely because of
what the new spec was going to fix. It does not time out and it does not
report anything: from the controller's side it is waiting correctly.

An image that does not exist in the mirror is the usual way in, because
`ImagePullBackOff` is a state a pod stays in forever rather than one it fails
out of.

### Why nothing was red

Argo CD said `Synced` and it was — git and the cluster agreed about every
object it manages. It also said `Healthy`, and that is the part worth
understanding: **a custom resource with no health check is reported Healthy
because it exists.** `Synced/Healthy` over a workload that has never once
started is not a bug in Argo CD; it is the honest answer to a question narrower
than the one being asked.

Anything delivered as a CRD — an operator's `Redis`, `Cluster`, `Database` —
has this property unless somebody wrote a health check for that kind. The
Deployments beside it do not, which is why the panel is a mix of claims with
different strengths on one screen.

### Fixing it

Delete the pod. The controller recreates it from the current template.

```bash
kubectl -n <namespace> delete pod <name>-0
```

**Not `--force`.** Section 3 says why, and this is the case where the ordinary
delete is also the correct one: a pod that has never come up holds nothing, has
joined no quorum and has written nothing. Forcing adds risk and removes no
waiting.

Then watch it, because the next pull is the real test:

```bash
kubectl -n <namespace> get pods -w
```

If it comes back in `ImagePullBackOff` on the NEW tag, the deadlock was real and
so is a second problem: that tag is not in the mirror either. The error text
separates them — `not found` is the mirror, `no basic auth credentials` is the
pull secret, and §4 of `docs/01-how-it-works.md` has that chain.

### Avoiding the next one

The tag was wrong in the first place because it was typed from memory rather
than confirmed. Before a tag reaches this repository:

```bash
docker manifest inspect <registry>/<path>:<tag>
```

`check-pins.sh` proves every image is pinned to an exact version. It cannot
prove the version exists — nothing offline can — and the gap between those two
claims is exactly this incident.

## Practise it

A procedure nobody has run is not a procedure. Worse: step 1 of this page is
**silently false** on a cluster whose ApplicationSets lack
`ignoreApplicationDifferences` — the freeze appears to work and is undone
seconds later, and you find that out while something is broken.

```bash
./hack/drill.sh tenants/<tenant>/<env>/<service> --yes
```

It freezes one workload, changes it by hand, waits to see whether Argo CD undoes
it, hands it back, and times every step.

It refuses, at step 0 and before touching anything:

- a platform component, and anything you have not named — the secret plane is
  not a drill
- a stateful workload
- an Application that is already frozen — somebody else's freeze, or a run that
  did not finish
- a `kubectl` whose jsonpath prints `map[...]` instead of JSON, because that
  value cannot be patched back and the failure would land after the freeze
- a workload with an HorizontalPodAutoscaler on it, whose replicas come back
  whatever the freeze does

Two of those are the two answers step 1 of this page tells you to look at, asked
by a script instead of by eye: an Application already frozen is step 1 printing
nothing, and the `map[...]` refusal is step 1's second bad answer.

The HPA one belongs to the rehearsal alone. Freezing a workload that autoscales
is a perfectly good thing to do at 2am; it is only useless as a *drill*, because
the drill proves the freeze by moving replicas and an autoscaler moves them back
whatever the freeze does.

Read its exit code, not only its output. If the freeze is announced as held and
the workload moves anyway, the drill prints `THE DRILL FAILED` and exits
non-zero: that is this page being false about your cluster, found one step later
than `THE FREEZE DID NOT HOLD` would have found it.

Interrupting it is safe: Ctrl-C hands the workload back before stopping, and so
does a dropped ssh session. That second one is the reason the first is not
enough to say — this gets run over ssh, from somewhere else, and a connection
that goes away mid-drill is the interruption that actually happens.

Killing it any harder is not safe. `kill -9`, or a laptop that sleeps, leaves
the Application frozen, and the next run refuses until you put
`syncPolicy.automated` back by hand.

Run it on a disposable service, before you need it, and again after any change
to the ApplicationSets. Commit the output under `docs/drills/` with the date:
what it prints is the evidence that this page is true on **this** cluster, and
it goes stale.

Two numbers it cannot measure, and you should write beside it:

- how long Argo CD took to notice your commit — the webhook, or the polling
  interval from `bootstrap/argocd-values.yaml`
- how long you spent looking for the right command

A procedure is as fast as the second number, not the first.
