# Plane 0 — bringing a cluster up

Everything here is applied **by a human, once**, and none of it is managed by
Argo CD. That is test 1 of the standard: a thing Argo CD needs in order to sync
cannot be a thing Argo CD syncs.

Before you start, the cluster must already have a CNI, a CSI and a way to get an
address — Plane 1. `cluster.yaml:network.loadBalancer` records what this cluster
uses so it can be checked, and nothing here installs any of it.

## 1. Install Argo CD

```bash
cp bootstrap/argocd-values.example.yaml bootstrap/argocd-values.yaml
```

Fill in the mirror and the version, then:

```bash
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f bootstrap/argocd-values.yaml
```

Upgrading Argo CD later is this same command with a new version. There is no
Application for it and there should not be.

## 2. Give it read access to this repository

```bash
kubectl -n argocd create secret generic gitops-repo \
  --from-literal=type=git \
  --from-literal=url="$(python3 -c 'import yaml;print(yaml.safe_load(open("cluster.yaml"))["argocd"]["repoURL"])')" \
  --from-literal=username=<user> --from-literal=password=<read-only token>
```

```bash
kubectl -n argocd label secret gitops-repo argocd.argoproj.io/secret-type=repository
```

Read-only. CI writes to this repository with a different token, and nothing that
reads needs to write.

## 3. Apply the root Application

Read it first. It is the only thing here that creates other things.

```bash
./bootstrap/render-root.sh
```

```bash
./bootstrap/render-root.sh | kubectl apply -f -
```

From this point the AppProjects and the five ApplicationSets exist, and every
folder in `platform/`, `tenants/` and `shared/` becomes an Application on its
own.

## 4. Check what it made, before trusting it

```bash
kubectl -n argocd get appproject
```

```bash
kubectl -n argocd get applicationset
```

```bash
kubectl -n argocd get application -o wide
```

An Application at `Unknown` with no events is almost always a destination the
AppProject does not permit. `hack/validate.py` refuses that state before a push,
so if you see it, something reached the cluster without passing the gate.

## What is deliberately not here

**A webhook.** Set one up if the git server can reach Argo CD — the difference
is seconds against up to `timeout.reconciliation`. In an air-gapped estate it
often cannot, and then the polling interval is the number that matters and it
belongs in the incident page.

**Anything that unseals a secret store.** A Vault's `operator init` and its
unseal are a ceremony with keys a human must hold. Test 2: the desired state has
to be expressible as data, and a key ceremony is not.

**Applying anything twice.** Every command above is idempotent except the two
that create a Secret. Running the whole file again on a live cluster is safe.

## The ceremonies that are not declarative, and cannot be

Every script in this directory is listed here. `hack/validate.py` refuses a
script that is not, and a name here that is not a script — because a procedure
nobody can find is the same as no procedure. The case that matters is the transit
Vault sitting sealed while the main Vault is one pod restart from being stuck: the
recovery is a script, and it is no use if the person holding the incident cannot
find out that it exists.

```
bootstrap/render-root.sh       render the root Application (step 3 above)
bootstrap/seed-regcred.sh      the image-pull secret, before anything can pull
bootstrap/vault-day0.sh        initialise both Vaults, wire auto-unseal
bootstrap/unseal-transit.sh    unseal transit after a restart -- day N, not day 0
bootstrap/seed-vault-kv.sh     write the KV paths the ClusterExternalSecrets read
```

`seed-regcred.sh` breaks a real loop: every platform tool needs `regcred` to
pull, and `regcred` is produced by External Secrets reading Vault. Nothing in
git can create it, because the thing that would is the thing that cannot start.
Run it before the first sync, on every new cluster and after any recovery that
loses the platform namespaces.

`vault-day0.sh` refuses to continue until you confirm the key material has left
the node, and issues the auto-unseal token from the pod straight into a Secret
without printing it. Both matter: a key written into a shell history or echoed
into a log is a key that has left the ceremony. Then `docs/05-vault-eso.md` for the KV and Kubernetes auth side.

`unseal-transit.sh` is the one you will actually run more than once. The transit
Vault is sealed with Shamir over a file on a PVC, so it comes back SEALED from
every restart there is — a node reboot, a drain, an eviction, an OOM kill, a
Longhorn volume reattaching. That is not a fault, it is what a Shamir seal
means. What makes it dangerous is that nothing reports it: the main Vault keeps
running, because a Vault only needs to unseal at startup, so the cluster looks
perfect right up until a main Vault pod restarts and cannot open.

It unseals, proves the auto-unseal token still encrypts, and then reports the
seal state of every main Vault pod — which is the part `vault-day0.sh` was too
large to be run for. It initialises nothing and exits non-zero while any main
Vault pod is still sealed.

`seed-vault-kv.sh` writes the KV paths that the ClusterExternalSecrets read, and
derives every one of them from this repository rather than from a runbook — the
registry path from the ClusterExternalSecret, the Helm paths from
`cluster.yaml:chartRepos`, the Redis paths from `platform/platform-config`. It
refuses a placeholder. A placeholder pasted literally into a live command
before it existed.
