{{- /* Render a value as the quoted string "true" or "false" via Helm
       truthiness. Kept in one place so a value like `1` can never be truthy
       to the template and false to the Job script's `= "true"` test — the
       silent-profile-skip bug this idiom was introduced to fix. */ -}}
{{- define "nvidia-aicr.bool" -}}
{{- if . }}"true"{{- else }}"false"{{- end }}
{{- end }}

{{- /* Render one structured passthrough argument as exactly one bash word.
       A literal apostrophe closes the single-quoted word, emits '\'' and reopens
       it; unlike the legacy unquoted strings, whitespace and glob characters
       therefore reach the CLI unchanged (Helm v4.3.0 and bash 5.3.20(1)-release,
       exercised by hack/verify-render.sh, verified 2026-11-05). */ -}}
{{- define "nvidia-aicr.shellArg" -}}
{{- $arg := replace "'" `'\''` (toString .) -}}
{{- $arg = replace "\n" `'$'\n''` $arg -}}
'{{ $arg }}'
{{- end }}

{{- /* Validate and render a structured passthrough list. Rejecting scalar lists
       and non-string elements here avoids Go's raw range error and prevents
       numbers, nulls or maps from being stringified into different arguments.
       Exercised with Helm v4.3.0 and v3.19.0 by hack/verify-render.sh,
       verified 2026-11-05. */ -}}
{{- define "nvidia-aicr.shellArgs" -}}
{{- $key := .key -}}
{{- $args := .args -}}
{{- if not (kindIs "slice" $args) -}}
{{- fail (printf "%s must be a YAML list of strings" $key) -}}
{{- end -}}
{{- range $index, $arg := $args }}{{ if not (kindIs "string" $arg) }}{{ fail (printf "%s[%d] must be a string; quote every element, including numbers and booleans" $key $index) }}{{ end }}{{ include "nvidia-aicr.shellArg" $arg }} {{ end }}
{{- end -}}

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
