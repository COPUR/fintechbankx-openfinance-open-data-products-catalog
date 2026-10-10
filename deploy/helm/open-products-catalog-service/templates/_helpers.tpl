{{- define "products.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "products.namespace" -}}
{{- .Values.namespace | default .Release.Namespace -}}
{{- end -}}

{{/*
Selector labels of the serving pods (cicd-templates 335a345). component=service
keeps the Service, PDB, NetworkPolicy, topology spread and the Deployment
selector on the serving pods only. The Deployment selector is immutable: a
release installed without it must be deleted and installed again.
*/}}
{{- define "products.selectorLabels" -}}
app.kubernetes.io/name: {{ include "products.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: service
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

{{- define "products.migrationSecretName" -}}
{{ include "products.name" . }}-db-migration
{{- end -}}
