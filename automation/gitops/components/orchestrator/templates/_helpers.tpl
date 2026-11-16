{{- define "orchestrator.labels" -}}
demo.redhat.com/application: "ssc-demo"
app.kubernetes.io/name: orchestrator
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ssc-demo
{{- end -}}

{{- define "orchestrator.domain" -}}
{{- required "Set domain to the cluster's apps subdomain" .Values.domain }}
{{- end -}}

{{/*
GitLab's public host: gitlab-<gitlab namespace>.<domain> -- the same
derivation bootstrap-infra uses for the app-environments Applications, so
the host the workflows talk to cannot disagree with the host Argo tracks.
*/}}
{{- define "orchestrator.gitlabHost" -}}
{{- with .Values.gitlab.host }}{{ . }}{{ else }}
{{- printf "gitlab-%s.%s" .Values.gitlab.namespace (include "orchestrator.domain" .) }}
{{- end }}
{{- end -}}
