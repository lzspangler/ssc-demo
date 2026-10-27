{{/*
Common labels for Pipelines chart resources.
*/}}
{{- define "pipelines.labels" -}}
demo.redhat.com/application: "ssc-demo"
app.kubernetes.io/name: pipelines
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: lightwell-tssc-workshop
{{- end -}}

{{/*
The TektonConfig .spec.chain block, as JSON for the bootstrap Job.

  artifacts.*.format: in-toto      -> SLSA provenance attestations (.att)
  artifacts.oci.format: simplesigning -> image signatures (.sig)
  artifacts.*.storage: oci         -> both stored beside the image in the
                                      registry, rather than in a Tekton
                                      annotation only

`transparency.*` logs each signature to Rekor. Pointed at the in-cluster RHTAS
Service rather than its Route -- no router timeout, no TLS to configure, and
it keeps working if the Route is renamed.
*/}}
{{- define "pipelines.chainConfig" -}}
{{- $c := dict
  "disabled" false
  "artifacts.taskrun.format" "in-toto"
  "artifacts.taskrun.storage" "oci"
  "artifacts.pipelinerun.format" "in-toto"
  "artifacts.pipelinerun.storage" "oci"
  "artifacts.oci.format" "simplesigning"
  "artifacts.oci.storage" "oci"
-}}
{{- if .Values.chains.transparency.enabled -}}
{{- $_ := set $c "transparency.enabled" "true" -}}
{{- $_ := set $c "transparency.url" (required "Set chains.transparency.url when transparency is enabled" .Values.chains.transparency.url) -}}
{{- end -}}
{{- toJson $c }}
{{- end -}}
