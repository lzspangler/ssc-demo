{{/*
Public GitLab hostname. Explicit `gitlab.host` wins; otherwise derive the name
the OpenShift router assigns to the `gitlab` Route in this namespace, so a new
cluster only has to set `cluster.subdomain`.
*/}}
{{- define "gitlab.host" -}}
{{- if .Values.gitlab.host -}}
{{- .Values.gitlab.host -}}
{{- else -}}
{{- required "Set cluster.subdomain (or gitlab.host)" .Values.cluster.subdomain | printf "gitlab-%s.%s" .Release.Namespace -}}
{{- end -}}
{{- end }}

{{/*
SSH hostname. Only used in GITLAB_SSH_HOST (the clone URL GitLab advertises);
the demo clones over HTTPS, so this is cosmetic.
*/}}
{{- define "gitlab.sshHost" -}}
{{- if .Values.gitlab.ssh.host -}}
{{- .Values.gitlab.ssh.host -}}
{{- else -}}
{{- required "Set cluster.subdomain (or gitlab.ssh.host)" .Values.cluster.subdomain | printf "gitlab-ssh-%s.%s" .Release.Namespace -}}
{{- end -}}
{{- end }}

{{/*
User password
*/}}
{{- define "gitlab-user.password" -}}
{{- if .Values.gitlab.users.password }}
{{- .Values.gitlab.users.password }}
{{- else }}
{{- randAlpha 8 }}
{{- end }}
{{- end }}

{{ define "gitlab.repo.check-pipeline" -}}
{{- $arg := . }}
{{- if $arg.properties }}
{{- if $arg.properties.onlyMergeWhenPipelineSucceeds }}
{{- $arg.properties.onlyMergeWhenPipelineSucceeds }}
{{- else }}
{{- false }}
{{- end }}
{{- else }}
{{- false }}
{{- end }}
{{- end }}
