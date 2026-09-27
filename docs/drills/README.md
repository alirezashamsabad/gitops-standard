# Drill logs

The output of `hack/drill.sh`, one file per run, named by date and cluster.

An empty directory means the incident procedure has never been rehearsed, which
is close to not having one: the procedure rests on a freeze holding, and a freeze
is silently undone within seconds when an ApplicationSet is missing
`ignoreApplicationDifferences`. Nothing reports that. The drill is what finds it.

A log goes stale. Re-run after any change to `charts/cluster-config`.
