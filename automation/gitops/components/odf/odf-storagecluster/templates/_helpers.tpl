{{/*
Expand the name of the chart.
*/}}
{{- define "odf-storagecluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart name and version, for the helm.sh/chart label.
*/}}
{{- define "odf-storagecluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "odf-storagecluster.labels" -}}
helm.sh/chart: {{ include "odf-storagecluster.chart" . }}
app.kubernetes.io/name: {{ include "odf-storagecluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Namespace ODF is installed into.
*/}}
{{- define "odf-storagecluster.namespace" -}}
{{- default .Release.Namespace .Values.namespace }}
{{- end }}

{{/*
ServiceAccount shared by the labelling Job and the readiness gate.
*/}}
{{- define "odf-storagecluster.serviceAccountName" -}}
{{- printf "%s-bootstrap" (include "odf-storagecluster.name" .) }}
{{- end }}
