{{- define "db-bootstrap.labels" -}}
app.kubernetes.io/name: db-bootstrap
app.kubernetes.io/version: {{ .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
