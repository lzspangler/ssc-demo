{{/*
Expand the name of the chart.
*/}}
{{- define "odf-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart name and version, for the helm.sh/chart label.
*/}}
{{- define "odf-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "odf-operator.labels" -}}
helm.sh/chart: {{ include "odf-operator.chart" . }}
app.kubernetes.io/name: {{ include "odf-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Namespace ODF is installed into.
*/}}
{{- define "odf-operator.namespace" -}}
{{- default .Release.Namespace .Values.namespace }}
{{- end }}
