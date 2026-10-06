{{/*
Common labels for ArgoCD Applications managed by this App-of-Apps chart.
*/}}
{{- define "root-app.labels" -}}
demo.redhat.com/application: "ssc-demo"
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ssc-demo
{{- end -}}

{{/*
The syncPolicy every platform Application shares. Identical to the reference
cluster's, including the generous retry: several of these charts create custom
resources whose CRDs are still being installed by OLM when the first sync runs,
and without the retry those Applications fail once and stay failed.
*/}}
{{- define "root-app.syncPolicy" -}}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  retry:
    limit: 30
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 2m
  syncOptions:
    - CreateNamespace=true
    - RespectIgnoreDifferences=true
    - SkipDryRunOnMissingResource=true
{{- end -}}
