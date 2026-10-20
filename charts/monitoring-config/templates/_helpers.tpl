{{- define "monitoring-config.labels" -}}
app.kubernetes.io/name: monitoring-config
app.kubernetes.io/version: {{ .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
