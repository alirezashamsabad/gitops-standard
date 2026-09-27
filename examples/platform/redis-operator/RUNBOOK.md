# redis-operator — runbook

The controller. It runs no Redis: an instance is a custom resource in a tenant's
environment folder, and this folder must never contain one.

## Healthy

```bash
kubectl -n redis-operator get deploy
```

```bash
kubectl get redisreplication,redissentinel -A
```

The controller Available, and every custom resource reconciled. **A resource that
nothing is acting on looks identical to one that is** — the object exists either
way, and a custom resource with no health check reports Healthy in Argo CD simply
because it exists.

## Silent failure

**The operator down while the Redis pods are up.** Everything serves normally and
nothing is reconciling, so a failover does not happen when it is needed and the
first anyone knows is that the failover did not happen.

## What breaks if it stops

Nothing immediately. Running Redis keeps serving. What stops is reconciliation: no
failover, no recovery of a lost pod, no effect from any change to a resource.

## Where the instances are

```
tenants/<tenant>/<env>/redis/     the resource the applications connect to
```

Operator per cluster, instance per environment.
