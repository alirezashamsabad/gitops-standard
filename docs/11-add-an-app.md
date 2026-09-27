# Adding an application

```
tenants/<tenant>/<env>/<service>/
  config.yaml     the promotable unit
  values.yaml     everything else about this service
```

The folder name is the service name. Nothing inside restates it — the
ApplicationSet injects it — so the two cannot drift.

## config.yaml

```yaml
namespace: <the namespace of this environment>

chart:
  repo: <key from cluster.yaml:chartRepos>
  name: <chart>
  version: "<exact>"

image:
  repository: <mirror>/<path>
  # The only line a pipeline edits, in this whole repository.
  tag: v1.2.3-dev

sync:
  automated: true
  selfHeal: true
  prune: true          # false in the environment closest to production
```

`image` is required. Without it the ApplicationSet injects no image parameter,
the chart renders with whatever its own values say, and the Application reports
Healthy running something nobody chose.

## values.yaml

Everything about this service lives here: ports, probes, HPA, strategy,
`httpRoute`, resources. One folder, one service, one place to look.

Four value layers are mounted, later winning:

```
tenants/_shared/values.yaml            every app on this cluster
tenants/<t>/common-values.yaml         every app of this tenant
tenants/<t>/<env>/env-values.yaml      every app in this environment
tenants/<t>/<env>/<svc>/values.yaml    this one
```

Missing layers are skipped, not an error.

A tempting rule is "do not create a layer for one service — a default is what two
things agree on". That is right for a replica count and wrong for a pull secret,
and following it leaves `tenants/_shared/values.yaml` empty, which ships
Deployments that cannot pull an image. **A layer is for what is true of that
layer, not for what two services happen to agree on.** Where this estate keeps
its images is true of the estate with one service in it. See "The pull secret,
and the four layers" below.

## Publishing it

```yaml
httpRoute:
  enabled: true
  hostnames:
    - <env>-<service>.<cluster.yaml:network.baseDomain>
  parentRefs:
    - name: <cluster.yaml:network.gatewayName>
      namespace: <cluster.yaml:network.gatewayNamespace>
```

**`<env>-<service>`, in that order**, and both halves are read from the folder
this file sits in, so the hostname cannot drift from the workload it belongs to.
The gate refuses anything else — including `<service>-<env>`, which is what this
estate had and which ends in the right domain, so the check that only tested the
suffix passed it.

The gate checks all three, because every one of these failures is silent: a
misspelled hostname is accepted by the API server and then matches nothing at
all; a parentRef naming another Gateway reports `Accepted` with
`ResolvedRefs=False` in a status field nobody reads; and a hostname that belongs
to another environment reports `Accepted` while receiving nothing, because
Gateway API resolves a hostname conflict by age and the older route keeps
serving.

### Why the gate is the boundary, and not the Gateway

You would expect the listener to enforce this — `hostname: "*.dev.<base>"` plus
an `allowedRoutes` selector. It cannot here, and the reason is worth
understanding before someone tries:

- The pattern puts the environment in the **leftmost label together with the
  service**: `dev-orders`. A DNS wildcard matches one whole leftmost label, so
  there is no wildcard meaning "starts with `dev-`". `*.<base>` is the only
  listener hostname available and it matches everything.
- The domain is shared with objects this repository does not own. Narrowing the
  listener would detach them.

So the boundary is this gate, in git, before anything reaches the cluster —
which is stronger than the listener would have been anyway, because it refuses
the hostname instead of silently not serving it.

A hierarchical scheme (`<service>.<env>.<base>`) would let the listener do it
too. That is a DNS decision, not a repository one.

## The port, and why you do not read it off the base image

This is the field most likely to be wrong while everything reports green, so it
gets its own section.

`mcr.microsoft.com/dotnet/aspnet` sets `ASPNETCORE_HTTP_PORTS=8080`, and an
application that overrides Kestrel in `appsettings.json` binds something else
and says nothing. `EXPOSE` in a Dockerfile binds nothing either — it is
documentation.

**Ask a running instance.** If the service already runs anywhere, the Service in
front of it is the answer:

```bash
kubectl -n <namespace-where-it-runs> get svc -o custom-columns=NAME:.metadata.name,PORT:.spec.ports[*].port,TARGET:.spec.ports[*].targetPort
```

```bash
kubectl -n <namespace> logs deploy/<name> --tail=60 | grep -i "now listening"
```

If it runs nowhere yet, `ASPNETCORE_URLS` in the Dockerfile is authoritative
when it is set, and nothing else is.

It went wrong here in exactly the way the comment in the file had predicted:
one service was given 8080 by reasoning from the base image, the application
listens on 5155, and its Application reported `Synced/Healthy` for its
whole life with a Service pointing at a port nothing was bound to. With probes
off there is no signal at all.

## gRPC services

`httpRoute.enabled: false`, unless the Gateway is configured for h2c on that
backend.

gRPC is HTTP/2 with prior knowledge. A route through the shared Gateway reaches
the Service over cleartext HTTP/1.1 and the failure is not a 404 — the
connection opens and produces a protocol error inside the client, a long way
from this file. In-cluster callers reach `<svc>.<namespace>.svc:<port>` and need
no route.

Every gRPC service in this estate has it off.

## The pull secret, and the four layers

You do not write one. `tenants/_shared/values.yaml` sets it for every workload
delivered by a `chart:`, and the gate refuses a new service if that stops being
true.

Know it is there, because when it is missing the message names nothing useful:

```
failed to resolve image: pull access denied, repository does not exist or may
require authorization: authorization failed: no basic auth credentials
```

**`no basic auth credentials` means the pull was anonymous** — nothing was sent.
A credential that is present but wrong or insufficient says `unauthorized to
access repository` instead. That difference is the whole diagnosis: the first is
your workload, the second is the registry. Two commands separate them:

```bash
kubectl -n <namespace> get deploy -o custom-columns=NAME:.metadata.name,PULLSECRETS:.spec.template.spec.imagePullSecrets[*].name
```

```bash
kubectl -n <namespace> get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -c "import json,sys;print(list(json.load(sys.stdin)['auths'].keys()))"
```

The second prints only the registry host, never the credential. It must equal
the host in your image exactly: `https://host/v1/` and `host` are different keys
to the kubelet, and a mismatch produces the same anonymous-pull message with the
secret correctly attached.

A workload delivered by `manifestsDir:` inherits none of this. Raw manifests are
not templated, so no value layer reaches them and the pull secret goes in the
manifest itself.

### The four layers

```
tenants/_shared/values.yaml            every tenant, every environment
tenants/<t>/common-values.yaml         one tenant, every environment
tenants/<t>/<e>/env-values.yaml        one tenant, one environment
tenants/<t>/<e>/<svc>/values.yaml      one service
```

Later wins. The list is `charts/cluster-config/values.yaml:tenantValueLayers`
and it is mounted with `ignoreMissingValueFiles`, so a layer this cluster does
not use is absent rather than an error — which also means **a layer that should
exist and does not is silent**. That is how the pull secret went missing: the
list survived a refactor and the file did not.

Put something in a layer when it is true of that layer, not when two services
happen to agree. A pull secret is true of the estate with one service in it.

### What is not in `_shared` and arguably should be

These are the keys most often put in a shared layer by copying, and each is a
decision with a cost rather than a default:

| | why it is not there | what it needs first |
|---|---|---|
| `replicas: 2` | doubles what every service costs | a capacity decision |
| `pdb.enabled` | a PDB over one replica protects nothing | the replica count above |
| `priorityClassName` | names a PriorityClass this cluster does not have | create it, or drop the key |
| `terminationGracePeriodSeconds`, `preStop` | free, and genuinely wanted | nothing — this is the easy one |
| `topologySpreadConstraints` | its selector was injected by the ApplicationSet as a parameter, and the current one injects only the name, image and tag | the parameter, or the constraint pushes a literal sentinel into a label selector and the API server refuses the object |
| `containerSecurityContext` | was a separate layer mounted conditionally | a decision about whether every app can run non-root |

## Probes

Whatever you set, it must point at something that exists today. A probe against
an endpoint an application has not implemented ends as a SIGTERM that the
container log reports as a clean shutdown, naming no probe.

That is the common case rather than the exotic one, on an estate whose applications have
no `/health`, and it put every pod into CrashLoopBackOff with nothing in any log
naming a probe. Whether it is true of **your** cluster is a fact about your
cluster and belongs in its own notes, not here.

The middle setting, when you know the port but there is no health endpoint yet,
is `tcpSocket` on that port: it proves the process is accepting connections
without needing an endpoint to exist.

With readiness off, know what you have given up: the pod joins its Service the
moment the container starts, and `Healthy` no longer means the app works.

## Network

If this service is a kind the cluster already has a profile for, name it:

```yaml
# config.yaml
networkProfile: redis
```

`network.profiles` in the environment's `env.yaml` is the aggregation of what
the workloads in that environment named, and the gate refuses a mismatch either
way. It is a view of the folders, never a list you keep by hand.

If no profile file exists yet for that kind, adding one is a **machine** commit
to `charts/env-baseline/profiles/`, separate from this one.

---

## Wiring the pipeline

An application is not added until its own repository writes the tag here. The
`deploy` job is the same for every service; one variable differs.

```yaml
variables:
  GITOPS_APP: <the folder name under tenants/<tenant>/<env>/>
```

It needs one GitLab variable in that project: **`GITOPS_TOKEN`**, a project
access token with scope `write_repository` on this repository only, masked.

What it does:

| tag | effect |
|---|---|
| `v1.2.3-dev` | writes `image.tag` in `tenants/<tenant>/<env>/<service>/config.yaml` |
| `v1.2.3-qa` | writes it in `.../qa/<app>/config.yaml` |

**Order matters: the folder has to exist first.** A pipeline pointed at a folder
that is not here stops with `does not exist in gitops-config-nonprod`. Loud,
which is right, and still a red pipeline for a service nobody could promote.

**No `kubectl apply` into a namespace Argo CD manages.** With `selfHeal` on,
Argo reverts it within seconds and the job still reports success — the
deployment looks done and is not. If a pipeline also feeds an unmanaged
namespace, that half stays imperative and this half stays declarative; they are
different namespaces and neither writes into the other's.

**Four pipelines can push to this repository at once.** The deploy job clones,
edits, pushes, and on rejection starts over from a fresh clone. A single
`pull --rebase` loses that race often enough to matter, and a lost promotion is
silent: the job is green and the tag never moved.
