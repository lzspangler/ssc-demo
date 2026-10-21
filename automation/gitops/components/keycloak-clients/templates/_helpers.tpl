{{- define "keycloak-clients.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "keycloak-clients.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "keycloak-clients.labels" -}}
helm.sh/chart: {{ include "keycloak-clients.chart" . }}
app.kubernetes.io/name: {{ include "keycloak-clients.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "keycloak-clients.namespace" -}}
{{- default .Release.Namespace .Values.namespace }}
{{- end }}

{{/*
The cluster's apps subdomain. Required, because every URL below derives from
it and Argo CD renders with no cluster connection to look it up.
*/}}
{{- define "keycloak-clients.subdomain" -}}
{{- required "Set global.cluster.subdomain" .Values.global.cluster.subdomain }}
{{- end }}

{{/*
Keycloak base URL: explicit, else https://sso.<subdomain>.
*/}}
{{- define "keycloak-clients.url" -}}
{{- if .Values.keycloakUrl }}
{{- .Values.keycloakUrl | trimSuffix "/" }}
{{- else }}
{{- printf "https://sso.%s" (include "keycloak-clients.subdomain" .) }}
{{- end }}
{{- end }}

{{/*
RHTPA console redirect URIs: explicit, else derived from the RHTPA Route the
chart publishes as server-trusted-profile-analyzer.<subdomain>.
*/}}
{{- define "keycloak-clients.tpaRedirectUris" -}}
{{- $uris := .Values.clients.tpaFrontend.redirectUris }}
{{- if not $uris }}
{{- $host := printf "server-trusted-profile-analyzer.%s" (include "keycloak-clients.subdomain" .) }}
{{- $uris = list (printf "https://%s" $host) (printf "https://%s/*" $host) }}
{{- end }}
{{- toJson $uris }}
{{- end }}
