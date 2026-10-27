{{- define "rhtpa-operator.labels" -}}
demo.redhat.com/application: "ssc-demo"
app.kubernetes.io/name: rhtpa-operator
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ssc-demo
{{- end -}}

{{- define "rhtpa-operator.domain" -}}
{{- required "Set domain to the cluster's apps subdomain" .Values.domain }}
{{- end -}}

{{/*
appDomain is a SUFFIX, not a hostname: the operator publishes the server at
`server<appDomain>`, so it must start with a separator.
*/}}
{{- define "rhtpa-operator.appDomain" -}}
{{- with .Values.trustedProfileAnalyzer.appDomain }}{{ . }}{{ else }}
{{- printf "-trusted-profile-analyzer.%s" (include "rhtpa-operator.domain" .) }}
{{- end }}
{{- end -}}

{{/*
NooBaa's S3 endpoint, unless overridden.
*/}}
{{- define "rhtpa-operator.s3Endpoint" -}}
{{- with .Values.trustedProfileAnalyzer.storage.regionEndpoint }}{{ . }}{{ else }}
{{- printf "https://s3-openshift-storage.%s:443" (include "rhtpa-operator.domain" .) }}
{{- end }}
{{- end -}}
