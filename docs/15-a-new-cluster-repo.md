# Starting a cluster repository, and keeping its machine current

The design rests on two repositories and one direction of travel between them.
`hack/sync-machine.sh` is that direction: it carries the machine into a cluster
repository, or creates one.

Copying it by hand works until it does not. Two trees that are supposed to be
identical and are compared by eye diverge quietly, and nothing downstream reports
it — a cluster runs an older gate than the one that was written for it and every
pipeline stays green.

## The two repositories

```
the standard          this repository. The machine, and these pages.
                      No cluster.yaml, no platform/, no tenants/.

a cluster repository  one per cluster. The machine, copied, plus the product:
                      cluster.yaml, platform/, tenants/, shared/.
```

The machine travels **one way, always**. A cluster repository never edits it. Not
"should not" — the CI there refuses the commit, because a commit that mixes the
two classes cannot be merged one way. `docs/20-gates.md` has the rules.

What travels:

```
charts/  hack/  bootstrap/  README.md  .gitlab-ci.yml  .gitignore
```

What does not: `docs/`. It is machine — the gates check it, `MACHINE` in
`hack/validate.py` lists it — and it stays here. These pages describe the
structure, the structure has one home, and a copy per cluster is a copy per
cluster that can go stale. `docs/00-orientation.md` says the same at more length.

## Starting one

```bash
./hack/sync-machine.sh ../gitops-config-<cluster> --genesis
```

That creates the directory, runs `git init`, and copies the machine. Then the
product half, which is yours and is not derived from anything here:

```bash
cp cluster.example.yaml ../gitops-config-<cluster>/cluster.yaml
```

Fill it in. Every value in it is a fact about one cluster: its registries, its
chart mirrors, its tenants and their namespaces, its gateway and base domain.
`hack/validate.py` reads it and refuses what does not agree with it, so an empty
or half-filled `cluster.yaml` is not a soft start — it is the first thing to get
right.

Then `platform/<tool>/` for each tool the cluster needs
(`docs/10-add-a-tool.md`), and `tenants/<t>/<e>/` for each environment
(`docs/12-add-an-environment.md`). Neither is copied from here: one cluster may
run Redis and four applications while another runs RabbitMQ and ten. They share
the machine, not the inventory.

Bringing Argo CD up against it is plane 0 — `bootstrap/README.md`.

## Carrying a machine change into one

A change to `charts/`, `hack/` or `bootstrap/` is made **here**, with the subject
`Machine: <what it does>`. Then:

```bash
./hack/sync-machine.sh ../gitops-config-<cluster>
```

with no flag, which writes nothing and prints what would change. Read it. Then:

```bash
./hack/sync-machine.sh ../gitops-config-<cluster> --write
```

and in the cluster repository:

```bash
python3 hack/validate.py && ./hack/prove-checks.sh && ./hack/check-pins.sh && ./hack/render.sh
```

**All four, there, before committing.** A machine change that is green here can
still be refused there, and the reason is structural rather than bad luck: this
repository has no `platform/` and no `tenants/`, so every check that reads a
product file finds nothing to read and says nothing. The gates here prove the
machine is coherent; they cannot prove it is right about real files.

That is not hypothetical. A credential check added here passed both repositories'
gates and then produced eight refusals on the merge — a Redis CR that names the
Secret holding its password, which the rule read as holding one. The rule was too
narrow, the merge is where it showed, and the fix went back into the standard and
came down again.

Finally, commit there with the subject:

```
Machine merge: <the same subject as the Machine commit>
```

The same sentence, so the two halves are traceable to each other by reading
either log. `sync-machine.sh` does not commit for you; a subject line is a
sentence only the person who wrote the original can produce.

## What the script refuses, and why

**A dirty machine path in the target.** Copying over it would destroy the edit
with no record that it existed. An edit to the machine in a cluster repository is
the mistake this whole arrangement is built to prevent, so the script stops and
names the files rather than quietly winning the argument.

The product half being dirty is fine and is not looked at. That is the operator's
own work in their own repository.

**`--genesis` onto something that exists.** Creating and updating are different
intentions and conflating them is how a repository gets half-overwritten.

## Checking the two are the same

Run it with no flag. `=` against every path means the machines are identical.

It compares by **content**, not by timestamp. A file copied by hand has a
different modification time and identical bytes; reporting that as a change
teaches the reader to skim the list, and the list is the only thing standing
between a merge and an overwrite.
