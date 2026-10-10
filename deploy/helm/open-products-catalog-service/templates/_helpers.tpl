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
fintechbankx.io/service-id: svc-of-open-products-catalog
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
  serviceAccountName: {{ .Values.serviceAccount.name }}
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
      image: "{{ required "image.repository is required" .Values.image.repository }}:{{ required "image.tag is required" .Values.image.tag }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      envFrom:
        - configMapRef:
            name: {{ include "products.name" . }}
        - secretRef:
            name: {{ include "products.dbSecretName" . }}
      env:
        - name: SPRING_PROFILES_ACTIVE
          value: aws
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
          mountPath: {{ .Values.databaseCaBundle.mountPath }}
          readOnly: true
  volumes:
    - name: tmp
      emptyDir: {}
    - name: rds-ca-bundle
      configMap:
        name: {{ .Values.databaseCaBundle.configMapName }}
        items:
          - key: {{ .Values.databaseCaBundle.key }}
            path: {{ .Values.databaseCaBundle.key }}
{{- end -}}
