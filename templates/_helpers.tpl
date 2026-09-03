{{- /* Render a value as the quoted string "true" or "false" via Helm
       truthiness. Kept in one place so a value like `1` can never be truthy
       to the template and false to the Job script's `= "true"` test — the
       silent-profile-skip bug this idiom was introduced to fix. */ -}}
{{- define "nvidia-aicr.bool" -}}
{{- if . }}"true"{{- else }}"false"{{- end }}
{{- end }}

{{- /* Resolve which pull Secret the pack initContainer uses: an existing
       one (dataPackSecret), the chart-managed one (dataPackAuth), or none.
       Both at once is a configuration error — fail the render, never pick
       silently. dataPackAuth set without dataPack would create a Secret
       with no consumer — also fail-closed, never orphan it silently.
       `| default dict` guards `--set dataPackAuth=null`, which would
       otherwise nil-deref on the `.dockerconfigjson` lookup below, and the
       kindIs check catches a SCALAR dataPackAuth (`--set dataPackAuth=x`),
       which would otherwise abort with Go's raw "can't evaluate field
       dockerconfigjson in type string" — same reason aicrSha256 carries an
       explicit scalar-shape guard rather than letting `get` blow up. */}}
{{- define "nvidia-aicr.packSecretName" -}}
{{- if and .Values.dataPackAuth (not (kindIs "map" .Values.dataPackAuth)) -}}
{{- fail "dataPackAuth must be a map with a dockerconfigjson key, e.g. --set dataPackAuth.dockerconfigjson='{\"auths\":{}}'" -}}
{{- end -}}
{{- $dataPackAuth := .Values.dataPackAuth | default dict -}}
{{- if and $dataPackAuth.dockerconfigjson (not .Values.dataPack) -}}
{{- fail "dataPackAuth requires dataPack (the Secret would have no consumer)" -}}
{{- else if and .Values.dataPackSecret $dataPackAuth.dockerconfigjson -}}
{{- fail "set only one of dataPackSecret (existing Secret) or dataPackAuth.dockerconfigjson (chart-created Secret)" -}}
{{- else if .Values.dataPackSecret -}}
{{- .Values.dataPackSecret -}}
{{- else if $dataPackAuth.dockerconfigjson -}}
{{- printf "%s-pack-auth" .Release.Name -}}
{{- end -}}
{{- end -}}
