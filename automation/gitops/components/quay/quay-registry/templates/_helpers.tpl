{{/*
Expand the name of the chart. Everything the operator creates is prefixed with
this, so `quay` gives quay-quay-app, quay-quay-database, quay-clair-app, and so
on -- the names the reference cluster uses.
*/}}
{{- define "quay-registry.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart name and version, for the helm.sh/chart label.
*/}}
{{- define "quay-registry.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "quay-registry.labels" -}}
helm.sh/chart: {{ include "quay-registry.chart" . }}
app.kubernetes.io/name: {{ include "quay-registry.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Registry hostname: quay.host if set, otherwise quay.<cluster subdomain>.

Upstream looked the subdomain up from the default IngressController. Argo CD
renders with `helm template` and no cluster connection, so that lookup returns
empty and SERVER_HOSTNAME collapses to a bare "quay." -- which Quay accepts and
then issues unusable registry URLs from. Requiring the value is the only
behaviour that is the same everywhere.
*/}}
{{- define "quay-registry.host" -}}
{{- if .Values.quay.host -}}
{{- .Values.quay.host -}}
{{- else -}}
{{- $sub := required "Set global.cluster.subdomain (or quay.host) -- the registry hostname cannot be derived without it" .Values.global.cluster.subdomain -}}
{{- printf "quay.%s" $sub -}}
{{- end -}}
{{- end }}

{{/*
Full Quay account name of the pipeline robot, e.g. tssc+remediation.
*/}}
{{- define "quay-registry.robotAccount" -}}
{{- printf "%s+%s" .Values.quay.pipeline.organization .Values.quay.pipeline.robotName -}}
{{- end }}

{{/*
Whether the pipeline robot/Secret step runs at all. Requires both the toggle
and a target namespace.
*/}}
{{- define "quay-registry.pipelineEnabled" -}}
{{- if and .Values.quay.pipeline.enabled .Values.quay.pipeline.namespace -}}
true
{{- end -}}
{{- end }}
