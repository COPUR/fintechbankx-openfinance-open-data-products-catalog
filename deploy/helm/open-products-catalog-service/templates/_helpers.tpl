{{- define "products.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{/*
The namespace every document is written to: .Values.namespace, else the release namespace.
It must be an RFC 1123 DNS label, as Kubernetes requires, so a value holding a newline or a
"---" document separator fails the render instead of closing its line and adding documents
the guard never sees. Every template writes it quoted as well.
*/}}
{{- define "products.namespace" -}}
{{- $ns := toString (.Values.namespace | default .Release.Namespace) -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$" $ns) -}}
{{- fail (printf "namespace must be an RFC 1123 DNS label (lower-case letters, digits and '-', at most 63 characters, starting and ending with a letter or digit), got %q" $ns) -}}
{{- end -}}
{{- $ns -}}
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
      image: {{ include "products.image" . | quote }}
      imagePullPolicy: {{ .Values.image.pullPolicy | quote }}
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

{{/*
Adapter to the vendored platform guard (products.guard): deployment.yaml and
history-guard-check.yaml call it as their first action, so every workload renders only after
the guard has passed.
Platform datasource/TLS guard, vendored whole and unchanged, without a header, as _fbx_helpers.tpl
(source repository, path, commit and sha256 are pinned in CI next to
scripts/ci/verify-vendored-guard.sh; platform chart README, "Vendoring the guard"). The adapter maps every
value of this chart that feeds one of the guard's routes; a key left out is never checked:
- config: .Values.config (ConfigMap, envFrom of the migrate init container, the service and
  the history guard check pods).
- extraEnv: .Values.extraEnv as a list ({name, value} entries; the map form is converted),
  refused whole by configmap.yaml since the chart renders none. No env value of the
  templates is interpolated from values (all literals or secretKeyRefs), so there is nothing
  else to pass. SPRING_PROFILES_ACTIVE (aws) is a chart-rendered literal and is not
  passed: the guard refuses every spring.profiles.* name it is given. The startup TLS
  assertion needs no chart-rendered switch: it is on by default (fintechbankx.tls.enforce,
  which the guard refuses).
- envFrom, extraEnvFrom: no such values; mapped so that a value set there (which no template
  renders) is refused rather than ignored.
- javaToolOptions: the chart has no such value and renders none; a value set there is refused
  below. JVM options can only come from config.*, where the guard checks JAVA_TOOL_OPTIONS,
  JDK_JAVA_OPTIONS and _JAVA_OPTIONS.
- externalSecret.data / extraData as values: the chart renders its own entries only; a value
  set there is refused below rather than ignored.
- databaseCa: databaseCaBundle (mountPath, key, configMapName: the values the pods mount),
  always mounted (enabled); the guard pins them to /etc/fintechbankx/rds-ca, global-bundle.pem
  and rds-ca-bundle, and DB_URL must carry sslrootcert=<mountPath>/<key>.
- kafka.runtime: "" (the service has no Kafka client; a Kafka protocol key in config then
  fails the render).
- externalSecret: data = the entries externalsecret.yaml renders (db and db-migration),
  dataFrom = any dataFrom it renders plus .Values.externalSecret.dataFrom (refused).
*/}}
{{- define "products.guard" -}}
{{- $extraEnv := list -}}
{{- if kindIs "map" .Values.extraEnv -}}
{{- range $name, $value := .Values.extraEnv -}}
{{- $extraEnv = append $extraEnv (dict "name" $name "value" (toString $value)) -}}
{{- end -}}
{{- else -}}
{{- $extraEnv = .Values.extraEnv | default list -}}
{{- end -}}
{{- $secrets := fromYaml (include "products.renderedSecretData" (dict "root" . "template" "externalsecret.yaml")) -}}
{{- if .Values.javaToolOptions -}}
{{- fail "javaToolOptions is not supported by this chart (it renders no JAVA_TOOL_OPTIONS of its own); set config.JAVA_TOOL_OPTIONS, which the guard checks" -}}
{{- end -}}
{{- range $k := list "data" "extraData" -}}
{{- if index ($.Values.externalSecret | default dict) $k -}}
{{- fail (printf "externalSecret.%s is not supported by this chart: it renders its own ExternalSecret entries (templates/externalsecret.yaml), which the guard checks" $k) -}}
{{- end -}}
{{- end -}}
{{- include "fbx.guard" (dict "Values" (dict
      "config" .Values.config
      "extraEnv" $extraEnv
      "envFrom" .Values.envFrom
      "extraEnvFrom" .Values.extraEnvFrom
      "javaToolOptions" ""
      "databaseCa" (dict "enabled" true "mountPath" .Values.databaseCaBundle.mountPath "key" .Values.databaseCaBundle.key
        "configMapName" .Values.databaseCaBundle.configMapName)
      "kafka" (dict "runtime" "")
      "externalSecret" (dict "enabled" true "data" ($secrets.data | default list)
        "dataFrom" (concat ($secrets.dataFrom | default list) (.Values.externalSecret.dataFrom | default list))))) -}}
{{- end -}}

{{/*
The image reference "<image.repository>@<image.digest>": the digest the pipeline built and cosign
verified (helm-deploy passes it as image.digest and its render guard refuses any other image form).
image.digest has no default and must be sha256:<64 hex>. image.tag is optional and only labels the
pods (the version); "latest" in any case is still refused there, since it would name another build.
*/}}
{{- define "products.image" -}}
{{- $repository := required "image.repository is required" .Values.image.repository -}}
{{- $tag := toString (.Values.image.tag | default "") -}}
{{- if eq (lower (trim $tag)) "latest" -}}
{{- fail (printf "image.tag %q is refused: use the immutable tag the pipeline built (the git SHA); a mutable tag lets a restarted pod run another build than the one released" $tag) -}}
{{- end -}}
{{- $digest := toString (required "image.digest is required: the chart renders images only as repository@digest" .Values.image.digest) -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail (printf "image.digest %q is refused: it must be sha256:<64 lowercase hex>, the digest the pipeline built and signed" $digest) -}}
{{- end -}}
{{- printf "%s@%s" $repository $digest -}}
{{- end -}}
