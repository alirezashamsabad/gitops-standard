# cert-manager — runbook

Issues certificates from a ClusterIssuer. It issues nothing by itself; an issuer
is a separate component that depends on this one.

## Healthy

```bash
kubectl -n cert-manager get deploy
```

```bash
kubectl get clusterissuer
```

Three Deployments Available, and every issuer `Ready=True`. An issuer that is not
ready looks the same as one that is until something asks it for a certificate.

## Silent failure

**The CRDs present and the controller down.** Certificate objects are accepted
and nothing acts on them, so a `Certificate` sits without a Secret and the
workload that mounts that Secret stays in `ContainerCreating` — an error naming a
volume, one step away from naming this.

## What breaks if it stops

Nothing already issued. Existing Secrets keep working until they expire, which is
what makes this quiet: the first symptom is an expiry, weeks later.

## Turning it off

Remove the folder. Certificates already issued stay, because `prune` removing a
Certificate does not remove the Secret it created.
