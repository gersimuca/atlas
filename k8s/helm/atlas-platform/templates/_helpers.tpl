{{- define "atlas.fullname" -}}
atlas-{{ .service.name }}
{{- end -}}

{{- define "atlas.labels" -}}
app.kubernetes.io/name: {{ .service.name }}
app.kubernetes.io/part-of: atlas-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "atlas.image" -}}
{{ .Root.Values.image.registry }}/{{ .service.repository }}:{{ .Root.Values.image.tag }}
{{- end -}}
