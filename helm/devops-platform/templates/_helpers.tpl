{{/*
=============================================================================
_helpers.tpl — Shared Template Helpers
=============================================================================

WHAT IS _helpers.tpl?
This file defines reusable "named templates" (also called partials or macros).
Any file starting with _ is NOT rendered as a K8s resource — it's purely for
helper functions that other templates can call.

WHY USE HELPERS?
Without helpers, you'd have to repeat things like label blocks or image names
in every template file. Helpers let you define them once and reuse everywhere.

HOW TO CALL A HELPER from another template:
  {{ include "devops-platform.labels" . }}
           ^                          ^
           helper name         "dot" = current context (passes all values through)

HOW TO DEFINE A HELPER:
  {{- define "helper-name" -}}
    ... content ...
  {{- end }}

The dash (-) inside {{- and -}} trims whitespace/newlines, keeping YAML clean.
=============================================================================
*/}}

{{/*
Standard Kubernetes labels applied to every resource.
These follow the official k8s recommended label schema.

Usage in a template:
  labels:
    {{- include "devops-platform.labels" . | nindent 4 }}

"nindent 4" = add the output indented by 4 spaces (for proper YAML nesting)
*/}}
{{- define "devops-platform.labels" -}}
app.kubernetes.io/part-of: devops-stack
app.kubernetes.io/managed-by: helm
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Component-specific labels. Each resource also gets these.

Usage:
  labels:
    {{- include "devops-platform.componentLabels" "jenkins" | nindent 4 }}

Note: this helper takes a string, not the full dot context.
*/}}
{{- define "devops-platform.componentLabels" -}}
app.kubernetes.io/name: {{ . }}
{{- end }}

{{/*
Full image reference builder.
Combines repository + tag into a full image string.

Usage:
  image: {{ include "devops-platform.image" (dict "repo" .Values.jenkins.repository "tag" .Values.jenkins.tag) }}

Output example: jenkins/jenkins:2.504.1-lts-jdk21
*/}}
{{- define "devops-platform.image" -}}
{{ .repo }}:{{ .tag }}
{{- end }}

{{/*
Namespace shortcut — always reads from values.yaml global.namespace
*/}}
{{- define "devops-platform.namespace" -}}
{{ .Values.global.namespace }}
{{- end }}
