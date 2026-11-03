{{- define "demo.labels" -}}
app.kubernetes.io/name: demo
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: fleet-demo
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{- define "demo.selectorLabels" -}}
app.kubernetes.io/name: demo
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Container image reference. With image.digest set (the published chart sets it at release time)
the image is pinned by digest: <repository>@<digest>; otherwise <repository>:<tag>.
*/}}
{{- define "demo.image" -}}
{{- $img := .Values.image -}}
{{- $repo := required "image.repository is required" $img.repository -}}
{{- if $img.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $img.digest) -}}
{{- fail (printf "image.digest must look like sha256:<64 hex>, got %q" $img.digest) -}}
{{- end -}}
{{- printf "%s@%s" $repo $img.digest -}}
{{- else -}}
{{- $tag := toString (required "image.tag is required when image.digest is empty" $img.tag) -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must be a version, not latest" -}}
{{- end -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end }}
