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
fintechbankx.io/service-id: "svc-of-open-products-catalog"
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "products.dbSecretName" -}}
{{ include "products.name" . }}-db
{{- end -}}

{{- define "products.migrationSecretName" -}}
{{ include "products.name" . }}-db-migration
{{- end -}}


{{/*
Pod of the history guard check (CronJob and pre-upgrade gate): the service in check
mode runs fbx_history_guard.verify() as the runtime role and exits non-zero unless it
answers 'armed, intact'. component=history-guard-check keeps it out of every app
selector; no sidecar, or the Job would never complete.
*/}}
{{- define "products.historyGuardCheckLabels" -}}
app.kubernetes.io/name: {{ include "products.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: history-guard-check
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: fintechbankx-open-finance
app.kubernetes.io/managed-by: {{ .Release.Service }}
fintechbankx.io/service-id: "svc-of-open-products-catalog"
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "products.historyGuardCheckPod" -}}
metadata:
  labels:
    {{- include "products.historyGuardCheckLabels" . | nindent 4 }}
    sidecar.istio.io/inject: "false"
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  serviceAccountName: {{ .Values.serviceAccount.name | quote }}
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: history-guard-check
      image: {{ printf "%s:%s" (required "image.repository is required" .Values.image.repository) (required "image.tag is required" .Values.image.tag) | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy | quote }}
      envFrom:
        - configMapRef:
            name: {{ include "products.name" . }}
        - secretRef:
            name: {{ include "products.dbSecretName" . }}
      env:
        - name: SPRING_PROFILES_ACTIVE
          value: aws
        # Chart-owned deployment marker (never from values; config.FBX_DEPLOYED is refused):
        # with it DatabaseTlsEnvironmentPostProcessor is enforced whatever the profiles, and
        # refuses to start without the aws profile or with a local profile.
        - name: FBX_DEPLOYED
          value: "true"
        - name: OPEN_PRODUCTS_HISTORY_GUARD_CHECK
          value: "true"
        - name: SPRING_MAIN_WEB_APPLICATION_TYPE
          value: none
        - name: SPRING_FLYWAY_ENABLED
          value: "false"
        - name: DB_POOL_MIN_IDLE
          value: "0"
      resources:
        {{- toYaml .Values.historyGuardCheck.resources | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: rds-ca-bundle
          mountPath: {{ .Values.databaseCaBundle.mountPath | quote }}
          readOnly: true
  volumes:
    - name: tmp
      emptyDir: {}
    - name: rds-ca-bundle
      configMap:
        name: {{ .Values.databaseCaBundle.configMapName | quote }}
        items:
          - key: {{ .Values.databaseCaBundle.key | quote }}
            path: {{ .Values.databaseCaBundle.key | quote }}
{{- end -}}

{{/*
ExternalSecret entries exactly as <template> renders them, in the shape fbx.guard reads
(secretKey, property, remoteSecretName), plus any dataFrom: the adapter in deployment.yaml
passes what the chart writes, so a secretKey or remote key added to a template is checked
without a second list to keep in step. A document that does not parse fails the render.
Arguments: dict "root" (.), "template" (file name under templates/). Returns YAML
{data: [...], dataFrom: [...]}.
*/}}
{{- define "products.renderedSecretData" -}}
{{- $data := list -}}
{{- $dataFrom := list -}}
{{- range $doc := splitList "\n---" (include (print .root.Template.BasePath "/" .template) .root) -}}
{{- if regexMatch "(?m)^[^#\\s]" $doc -}}
{{- $o := fromYaml $doc -}}
{{- if hasKey $o "Error" -}}
{{- fail (printf "%s does not render as YAML: %s" $.template $o.Error) -}}
{{- end -}}
{{- if eq (toString $o.kind) "ExternalSecret" -}}
{{- $spec := $o.spec | default dict -}}
{{- range $e := ($spec.data | default list) -}}
{{- $ref := $e.remoteRef | default dict -}}
{{- $data = append $data (dict "secretKey" $e.secretKey "property" $ref.property "remoteSecretName" $ref.key) -}}
{{- end -}}
{{- $dataFrom = concat $dataFrom ($spec.dataFrom | default list) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml (dict "data" $data "dataFrom" $dataFrom) -}}
{{- end -}}
