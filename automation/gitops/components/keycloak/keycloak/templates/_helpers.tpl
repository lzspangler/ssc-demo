{{/*
Expand the name of the chart.
*/}}
{{- define "keycloak.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "keycloak.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "keycloak.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "keycloak.labels" -}}
helm.sh/chart: {{ include "keycloak.chart" . }}
{{ include "keycloak.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "keycloak.selectorLabels" -}}
app.kubernetes.io/name: {{ include "keycloak.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "keycloak.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "keycloak.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
ArgoCD Syncwave
*/}}
{{- define "keycloak.argocd-syncwave" -}}
{{- if .Values.argocd }}
{{- if and (.Values.argocd.syncwave) (.Values.argocd.enabled) -}}
argocd.argoproj.io/sync-wave: "{{ .Values.argocd.syncwave }}"
{{- else }}
{{- "{}" }}
{{- end }}
{{- else }}
{{- "{}" }}
{{- end }}
{{- end }}

{{/*
Find the name of the OpenShift domain.

`global.cluster.subdomain` wins over the IngressController lookup: Argo CD
renders charts with `helm template` and no cluster connection, so `lookup`
returns an empty dict there and the hostname silently collapses to
"keycloak-keycloak." -- which the Keycloak operator accepts and then serves
issuer URLs nobody can reach. Setting the subdomain explicitly is the only
thing that behaves the same under `helm template`, `helm install` and Argo.
*/}}
{{- define "keycloak.ocpDomain" -}}
{{- $global := .Values.global | default dict }}
{{- $cluster := (get $global "cluster") | default dict }}
{{- $subdomain := (get $cluster "subdomain") | default "" }}
{{- if $subdomain }}
{{- printf "%s" $subdomain }}
{{- else }}
{{- $ingresscontroller := (lookup "operator.openshift.io/v1" "IngressController" "openshift-ingress-operator" "default") | default dict }}
{{- $status := (get $ingresscontroller "status") | default dict }}
{{- $ocpDomain := (get $status "domain") | default dict }}
{{- printf "%s" $ocpDomain }}
{{- end }}
{{- end }}

{{/*
Keycloak hostname
*/}}
{{- define "keycloak.hostname" -}}
{{- if .Values.route.host }}
{{- printf "%s" .Values.route.host }}
{{- else if .Values.route.localName }}
{{- printf "%s.%s" .Values.route.localName (include "keycloak.ocpDomain" .) }}
{{- else }}
{{- printf "%s-%s.%s" (include "keycloak.name" .) .Release.Namespace (include "keycloak.ocpDomain" .) }}
{{- end }}
{{- end }}