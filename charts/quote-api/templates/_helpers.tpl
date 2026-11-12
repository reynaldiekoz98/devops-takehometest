{{- define "quote-api.labels" -}}
app.kubernetes.io/name: quote-api
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{- end }}
{{- define "quote-api.selector" -}}
app.kubernetes.io/name: quote-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
