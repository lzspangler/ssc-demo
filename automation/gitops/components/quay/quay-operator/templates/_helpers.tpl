{{/*
Expand the name of the chart.
*/}}
{{- define "quay-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart name and version, for the helm.sh/chart label.
*/}}
{{- define "quay-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "quay-operator.labels" -}}
helm.sh/chart: {{ include "quay-operator.chart" . }}
app.kubernetes.io/name: {{ include "quay-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Namespace the Subscription goes into.
*/}}
{{- define "quay-operator.namespace" -}}
{{- default .Release.Namespace .Values.namespace }}
{{- end }}
