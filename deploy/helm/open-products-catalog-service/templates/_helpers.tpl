{{- define "products.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "products.namespace" -}}
{{- .Values.namespace | default .Release.Namespace -}}
{{- end -}}

{{- define "products.selectorLabels" -}}
app.kubernetes.io/name: {{ include "products.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "products.labels" -}}
{{ include "products.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: fintechbankx-open-finance
app.kubernetes.io/managed-by: {{ .Release.Service }}
fintechbankx.io/service-id: svc-of-open-products-catalog
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "products.dbSecretName" -}}
{{ include "products.name" . }}-db
{{- end -}}

{{- define "products.oidcSecretName" -}}
{{ include "products.name" . }}-oidc-client
{{- end -}}
