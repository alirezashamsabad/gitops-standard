# The Vault side of External Secrets

`bootstrap/vault-day0.sh` gets both Vaults initialised and auto-unsealing. It
stops there on purpose. Everything below is Day-1: the KV mount, the role
External Secrets logs in with, and the paths the platform reads on its first
sync.

## Run it, do not retype it

```bash
./bootstrap/seed-vault-kv.sh
```

```bash
DOCKERCONFIG=/path/to/config.json ./bootstrap/seed-vault-kv.sh
```

It is idempotent: run it on a cluster in any state and it reports what already
exists and changes only what is missing or wrong.

## Rotating a credential

"Missing or wrong" is not enough on its own. A password that is perfectly valid
and belongs to an account you are retiring reads as fine, so say so explicitly:

```bash
FORCE=1 ./bootstrap/seed-vault-kv.sh
```

Naming a file is the same kind of instruction, and applies to that path alone:

```bash
DOCKERCONFIG=/path/to/new-config.json ./bootstrap/seed-vault-kv.sh
```

Neither mode will accept a placeholder. Rotating to a placeholder is rotating
to nothing.

**Vault is only half of it.** The image-pull secret exists twice on every
cluster and only one copy comes from Vault:

| copy | where | maintained by |
|---|---|---|
| platform namespaces | `cert-manager`, `vault`, `vault-transit`, `external-secrets`, `redis-operator` | `bootstrap/seed-regcred.sh`, imperative |
| tenant namespaces | whatever carries `gitops.internal/secrets-distribute` | External Secrets, out of Vault |

The platform copies are imperative on purpose: External Secrets cannot create
them, because External Secrets needs the mirror to start. So a registry
credential rotation is two commands, and doing only the Vault one leaves every
platform tool pulling with the old account until its next image pull.

```bash
DOCKERCONFIG=/path/to/new-config.json ./bootstrap/seed-regcred.sh
```

Then force the Secrets External Secrets owns to be rewritten now rather than at
the next refresh interval:

```bash
kubectl annotate externalsecret -A --all force-sync="$(date +%s)" --overwrite
```

**A page of commands with placeholders to substitute is the wrong shape for
this**, with `<mount>`, `<role>` and `<user>` to fill in. What placeholders
produce is this:

```
vault kv put kv/platform/apps username='<mirror-user>' password='<mirror-pass>'
==== Secret Path ====  kv/data/platform/apps    version 1
```

Success, a version number, and two credentials that authenticate to nothing.
Not a typo an operator catches, because the output is what a correct run
prints. The same evening a literal `<KEY-1>` reached a live unseal call and a
literal `/path/to/config.json` reached a shell — both failed loudly, and this
one did not.

So the script reads every name out of this repository, takes every value from a
prompt that does not echo, and refuses a value shaped like a placeholder.

## What it reads, and from where

Nothing here is a list to maintain. The script derives all of it:

| what | from |
|---|---|
| mount, auth mount, role, ServiceAccount | `platform/eso-config/manifests/00-cluster-secret-store.yaml` |
| the image-pull path | the `ClusterExternalSecret` asking for a `dockerconfigjson` property |
| Helm repository paths | `cluster.yaml:chartRepos`, one per **distinct URL** |

The last one matters and is easy to get wrong by hand: several `chartRepos`
keys usually share one mirror, and `platform/platform-config/chart/` creates one
credential per URL rather than per key — the first key for that URL in sorted
order. Read what it decided:

```bash
python3 -c "import yaml;c=yaml.safe_load(open('cluster.yaml'));s={};[s.setdefault(c['chartRepos'][k],k) for k in sorted(c['chartRepos'])];print(sorted(s.values()))"
```

## Why the policy is read-only

External Secrets never writes. A store that can write is a store that can be
used to change what every workload in the cluster reads.

`bound_service_account_names` and `bound_service_account_namespaces` are the
whole security boundary. A role bound to `*` is a role any pod can assume.

## Adoption — read before the first sync

External Secrets will not take ownership of a Secret it did not create. Any
Secret that already exists under a name an `ExternalSecret` targets must be
deleted once, **after** the store is Ready and the paths are seeded:

```bash
kubectl -n argocd delete secret repo-helm-apps
```

One at a time, so that if the Vault side is wrong there is still a working Helm
repository while you debug it.

## Proving it, rather than assuming it

A `ClusterSecretStore` reports `Valid` when Vault answered, not when a secret
was read.

```bash
kubectl get clustersecretstore -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[0].reason
```

The evidence is a Secret appearing in a namespace nobody created it in:

```bash
kubectl get secret -A --field-selector metadata.name=regcred
```

`kubectl get secret regcred -A` does not work — a named resource cannot be
fetched across all namespaces, and the error says so in a way that reads like
the Secret is the problem.

If the store is `Valid` and no Secret appears, the selector matched no
namespace. That is the failure this platform has produced before, silently,
because a `ClusterExternalSecret` matching nothing reports `Ready`.

## Proving the credential, which is a different claim again

`Ready=True SecretSynced` means External Secrets read Vault and wrote a Secret.
It says nothing about whether what is in that Secret opens anything. A Vault
holding `username: <user>` verbatim reports exactly that status, indefinitely.

So ask the repository. This sends the stored credential and nothing else — it
comes out of the Secret and goes into curl through a config on stdin, so it is
in no shell history and no process list:

```bash
kubectl -n argocd get secret repo-helm-apps -o json | python3 -c "import json,sys,base64;d=json.load(sys.stdin)['data'];print('user = \"%s:%s\"' % (base64.b64decode(d['username']).decode(), base64.b64decode(d['password']).decode()))" | curl -s -o /dev/null -w '%{http_code}\n' -K - $CHART_MIRROR/index.yaml
```

`200` is the proof. `401` means the credential is wrong whatever every status
field says.

Do not test it by typing a username into a `curl -u` line. A placeholder pasted
literally into a live command is the ordinary outcome, and one of them into a test exactly like that — which then returned `401` and proved
nothing about the cluster at all.

The registry credential has the same gap and the same shape of answer: the
evidence is a pod pulling, not a Secret existing.

```bash
kubectl get pods -A --field-selector status.phase!=Running | grep -i imagepull
```
