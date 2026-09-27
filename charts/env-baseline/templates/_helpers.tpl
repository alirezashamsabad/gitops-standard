{{- define "env-baseline.commonLabels" -}}
app.kubernetes.io/managed-by: argocd
gitops.internal/tenant: {{ .Values.tenant | quote }}
gitops.internal/env: {{ .Values.env | quote }}
{{- end -}}

{{- /*
Required values, checked by name. A namespace rendered with an empty name is
refused by the API server with a message about a field, not about which env.yaml
forgot to say who it belongs to.
*/ -}}
{{- define "env-baseline.validate" -}}
{{- if not .Values.tenant }}{{ fail "env-baseline: tenant is required in env.yaml" }}{{ end }}
{{- if not .Values.env }}{{ fail "env-baseline: env is required in env.yaml" }}{{ end }}
{{- if not .Values.namespace }}{{ fail "env-baseline: namespace is required in env.yaml" }}{{ end }}
{{- end -}}

{{- /*
Read one profile out of the chart's own library.

A name with no file is `fail`, not an empty rule set. A policy that silently
loses the rules for one service is a default-deny with an invisible hole, and
the symptom is a timeout that names nothing.
*/ -}}
{{- define "env-baseline.profile" -}}
{{- $path := printf "profiles/%s.yaml" .name -}}
{{- $raw := .root.Files.Get $path -}}
{{- if not $raw }}
{{- fail (printf "env-baseline: network.profiles names %q but charts/env-baseline/%s does not exist. A workload referencing a profile brings the profile with it - see profiles/README.md" .name $path) }}
{{- end }}
{{- $raw }}
{{- end -}}
