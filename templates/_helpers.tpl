{{- /* Render a value as the quoted string "true" or "false" via Helm
       truthiness. Kept in one place so a value like `1` can never be truthy
       to the template and false to the Job script's `= "true"` test — the
       silent-profile-skip bug this idiom was introduced to fix. */ -}}
{{- define "nvidia-aicr.bool" -}}
{{- if . }}"true"{{- else }}"false"{{- end }}
{{- end }}
