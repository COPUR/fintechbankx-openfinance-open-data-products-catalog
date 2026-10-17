#!/usr/bin/env bash
# guard-upstream-cases.sh <chart-dir> [options] -- <helm args of a rendering install>
#
# Reproduces, against this chart's adapter, the refusal cases that the platform repository
# fintechbankx-platform-delivery-iac-cicd-templates added with the guard this chart vendors
# (commits a4f0072..6b6c317), each with the upstream error pattern so a case cannot pass because the
# render failed for another reason. It does NOT run every upstream case: the case table below names,
# per row, the upstream suite file and `it:` title (or validate-chart.sh must_fail / vendored_must_fail
# case) the row reproduces, and the list "Not reproduced" says which upstream cases are left out and why.
#
# Upstream sources (path under charts/fintechbankx-service/tests/ unless noted, at 6b6c317):
#   database_ca_test.yaml             new in the range; rows reproduce its mountPath/key/configMapName rejections
#   kafka_client_tls_names_test.yaml  new in the range; rows reproduce its rejections (not its accept cases)
#   kafka_runtime_required_test.yaml  new in the range; rows reproduce its three "without kafka.runtime" rejections
#   documentdb_names_test.yaml        new in the range; rows reproduce its rejections (not its accept cases)
#   property_reading_names_test.yaml  new in the range; rows reproduce its rejections and its one control
#   scripts/ci/validate-chart.sh      must_fail and vendored_must_fail cases added in the range
# Each row ends with the field upstream = "<suite file>: it: <title>" or "validate-chart.sh: must_fail:
# <name>" (several sources joined by " ; " where one row reproduces more than one).
#
# Not reproduced (a claim of "every case" would be wrong; these are the omissions and the reason):
#   1. database_ca_test.yaml: the render/default/disabled cases (mounts ConfigMap rds-ca-bundle read-only,
#      exposes DB_SSL_ROOT_CERT, fails closed when the ConfigMap is missing, can be turned off, does not
#      check the mount while databaseCa is disabled) and every DB_URL / SPRING_DATASOURCE_URL / Flyway /
#      SPRING_APPLICATION_JSON case (sslmode, sslrootcert, sslfactory, sslhostnameverifier, service=,
#      percent-encoding, case, wrapped drivers, externalSecret and extraEnv spellings, sslpasswordcallback,
#      the accepts-verify-full controls). Reason: they assert the upstream chart's own templates and the
#      JDBC URL parser; this script drives only name/value rows through helm template, and the DB_URL
#      value is supplied by the caller's --set, so they are not reproduced here (still exercised upstream).
#   2. kafka_client_tls_names_test.yaml: the accept/control cases (https endpoint identification, non-ssl
#      MSK IAM names, rendering KAFKA_TLS_CERT/KEY/CA from secretKeyRef, KAFKA_TLS_CA as extraData).
#      Reason: they assert upstream rendered output (env entries, profile), not a refusal.
#   3. kafka_runtime_required_test.yaml: the default-profile cases (kafka.runtime "" or the block absent,
#      https endpoint identification) and the strimzi control. Reason: render assertions on the upstream
#      chart. Its three "rejects ... without kafka.runtime" cases for KAFKA_SECURITY_PROTOCOL,
#      spring.kafka.streams.security.protocol and spring.kafka.properties[security.protocol] are covered
#      only through --no-kafka-runtime, which rewrites the expected message of the protocol-value rows
#      (one row here: spring.kafka.security.pro_tocol); those three names themselves are not rows.
#   4. documentdb_names_test.yaml: the accept/control cases (DocumentDB credentials in config, extraEnv
#      and the secret; MONGODB_URI as extraData; MONGODB_URI from secretKeyRef). Reason: render assertions.
#   5. property_reading_names_test.yaml: "accepts spring.kafka.properties.ssl.endpoint_identification.algorithm
#      https (control)". Reason: a render assertion; its other control ("accepts other names with '_'") is
#      reproduced by the two pass rows.
#   6. relaxed_binding_names_test.yaml (changed in a4f0072..6b6c317, 7 lines) and scripts/ci/test/
#      verify-vendored-guard.test.mjs / scripts/ci/verify-vendored-guard.sh: tests of the vendoring
#      check itself, not guard refusal cases; not part of this script.
#   7. validate-chart.sh: the fixture check "adapter without databaseCa.configMapName" (it edits the
#      fixture adapter with sed). Reason: it tests the fixture's adapter, not this chart's.
#   8. Rows whose route this chart does not have are counted "not applicable" (see below), not passed.
#
# Upstream routes map to this chart's values:
#   config.*, extraEnv (value or valueFrom)   as upstream (every adapter passes both to fbx.guard);
#   externalSecret.data / extraData           externalSecret.extraData with --extra-data, else not
#                                             applicable (the chart renders its own entries only);
#   javaToolOptions                           javaToolOptions with --java-tool-options, else
#                                             config.JAVA_TOOL_OPTIONS (the chart has no such value);
#   databaseCa.*                              databaseCaBundle.* with --database-ca, else not applicable
#                                             (the adapter passes databaseCa {enabled: false});
#   kafka.runtime strimzi                     --strimzi <the --set that selects it>, else the case runs
#                                             without it (the name rules apply whatever the runtime);
#   kafka.runtime ""                          --no-kafka-runtime (no Kafka client): a protocol value
#                                             check answers "<key> is set but kafka.runtime is empty"
#                                             first (kafka_runtime_required_test.yaml).
# A row is "not applicable" only when the chart lacks that route. If the chart has it (values.yaml defines
# externalSecret.extraData / javaToolOptions / databaseCaBundle, or the chart's templates hand the value
# to the guard) and the matching flag was not passed, the row counts as FAILED and the message names
# the flag to pass, so a forgotten flag cannot turn a case into a silent skip.
# Exits 0 when every applicable case passes, 1 otherwise (each failure is printed).
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <chart-dir> [--strimzi <set>] [--extra-data] [--java-tool-options] [--database-ca] [--no-kafka-runtime] -- <helm args>" >&2; exit 2; }
chart="$1"; shift
strimzi=""; extra_data=0; jto=0; dbca=0; no_kafka=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strimzi) strimzi="$2"; shift 2 ;;
    --extra-data) extra_data=1; shift ;;
    --java-tool-options) jto=1; shift ;;
    --database-ca) dbca=1; shift ;;
    --no-kafka-runtime) no_kafka=1; shift ;;
    --) shift; break ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
base=("$@")
# Which optional routes does the chart have? values.yaml top-level keys, or a template that hands the value
# to the guard (a template that only refuses it, `if .Values.x ... fail`, is not a route).
vals="$chart/values.yaml"
has_es_extra=0; has_jto=0; has_dbca=0
if [ -f "$vals" ]; then
  awk '/^externalSecret:/{f=1;next} /^[^ #]/{f=0} f&&/^  extraData:/{found=1} END{exit !found}' "$vals" && has_es_extra=1
  grep -qE '^javaToolOptions:' "$vals" && has_jto=1
  grep -qE '^databaseCaBundle:' "$vals" && has_dbca=1
fi
if [ -d "$chart/templates" ]; then
  grep -rqE '"extraData"[[:space:]]+[$.A-Za-z]*[.]extraData' "$chart/templates" && has_es_extra=1
  grep -rqE '"javaToolOptions"[[:space:]]+[.]Values[.]javaToolOptions' "$chart/templates" && has_jto=1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
n=0; passed=0; failed=0; skipped=0

check() {  # <description> <expected ERE or "-" for must render> <helm args...>
  local desc="$1" expect="$2" out; shift 2
  if out="$(helm template ci "$chart" "${base[@]}" "$@" 2>&1)"; then
    if [ "$expect" = "-" ]; then passed=$((passed + 1)); echo "renders as expected: $desc"; return; fi
    echo "FAIL: $desc must be refused"; failed=$((failed + 1)); return
  fi
  if [ "$expect" = "-" ]; then echo "FAIL: $desc must render: $out"; failed=$((failed + 1)); return; fi
  if ! grep -qE -- "$expect" <<< "$out"; then
    echo "FAIL: $desc failed for another reason (expected /$expect/): $out"; failed=$((failed + 1)); return
  fi
  passed=$((passed + 1)); echo "refused as expected: $desc"
}
file() { n=$((n + 1)); printf '%s\n' "$@" > "$work/v$n.yaml"; echo "$work/v$n.yaml"; }

# route|flags|name|value|expected|upstream
# expected = upstream errorPattern ("-" = must render); upstream = suite file and it: title, or validate-chart.sh case
# (the field is documentation; it must not contain '|')
while IFS='|' read -r route flags name value expect upstream; do
  case "$route" in ''|'#'*) continue ;; esac
  extra=()
  if [ "$no_kafka" -eq 1 ] && [[ "$expect" == *"must be SASL_SSL or SSL"* ]]; then
    expect="config[.]$(sed -e 's/[][\.*^$(){}+?|]/\\&/g' <<< "$name") is set but kafka[.]runtime is empty"
  fi
  if [ "$flags" = strimzi ] && [ -n "$strimzi" ]; then extra=(--set "$strimzi"); fi
  case "$route" in
    config)
      check "config.$name" "$expect" "${extra[@]}" -f "$(file 'config:' "  '$name': '$value'")" ;;
    pass)
      check "config.$name (control)" - -f "$(file 'config:' "  '$name': '$value'")" ;;
    env)
      check "extraEnv $name (value)" "$expect" "${extra[@]}" -f "$(file 'extraEnv:' "  - name: '$name'" "    value: '$value'")" ;;
    envfrom)
      check "extraEnv $name (valueFrom $value)" "$expect" "${extra[@]}" -f "$(file 'extraEnv:' "  - name: '$name'" "    valueFrom: $value")" ;;
    envboth)
      check "extraEnv $name (empty value next to valueFrom)" "$expect" "${extra[@]}" \
        -f "$(file 'extraEnv:' "  - name: '$name'" "    value: ''" "    valueFrom: $value")" ;;
    es)
      if [ "$extra_data" -eq 0 ]; then
        if [ "$has_es_extra" -eq 1 ]; then failed=$((failed + 1)); echo "FAIL: externalSecret.extraData $name skipped as not applicable, but $chart has externalSecret.extraData: pass --extra-data"; continue; fi
        skipped=$((skipped + 1)); echo "not applicable (no externalSecret.data/extraData values): $name"; continue
      fi
      expect="${expect/externalSecret.data /externalSecret.extraData }"
      check "externalSecret.extraData $name" "$expect" "${extra[@]}" \
        -f "$(file 'externalSecret:' '  extraData:' "    - secretKey: '$name'" "      property: '$value'" '      remoteSecretName: ci/other')" ;;
    jto)
      if [ "$jto" -eq 0 ] && [ "$has_jto" -eq 1 ]; then
        failed=$((failed + 1)); echo "FAIL: javaToolOptions $value checked as config.JAVA_TOOL_OPTIONS, but $chart has javaToolOptions: pass --java-tool-options"; continue
      fi
      if [ "$jto" -eq 1 ]; then
        check "javaToolOptions $value" "$expect" --set-string "javaToolOptions=$value"
      else
        check "config.JAVA_TOOL_OPTIONS $value" "config[.]JAVA_TOOL_OPTIONS${expect#javaToolOptions}" -f "$(file 'config:' "  JAVA_TOOL_OPTIONS: '$value'")"
      fi ;;
    dbca)
      if [ "$dbca" -eq 0 ]; then
        if [ "$has_dbca" -eq 1 ]; then failed=$((failed + 1)); echo "FAIL: databaseCaBundle.$name skipped as not applicable, but $chart has databaseCaBundle: pass --database-ca"; continue; fi
        skipped=$((skipped + 1)); echo "not applicable (databaseCa disabled in the adapter): databaseCaBundle.$name"; continue
      fi
      if [ "$value" = null ]; then check "databaseCaBundle.$name=null" "$expect" --set "databaseCaBundle.$name=null"
      else check "databaseCaBundle.$name=$value" "$expect" --set-string "databaseCaBundle.$name=$value"; fi ;;
    *) echo "unknown route $route" >&2; exit 2 ;;
  esac
done <<'CASES'
dbca||mountPath|/app/config|databaseCa.mountPath must be /etc/fintechbankx/rds-ca \(got "/app/config"\)|database_ca_test.yaml: it: rejects a mountPath other than /etc/fintechbankx/rds-ca (e.g. /app/config, where Spring Boot reads config files) ; validate-chart.sh: must_fail: databaseCa.mountPath /app/config (a ConfigMap where Spring Boot reads config files) ; validate-chart.sh: vendored_must_fail: databaseCaBundle.mountPath /app/config with key application.yml (a Spring Boot config file)
dbca||mountPath|/etc/fintechbankx/rds-ca/|databaseCa.mountPath must be /etc/fintechbankx/rds-ca|database_ca_test.yaml: it: rejects a mountPath with a trailing slash (the pinned path is written once)
dbca||key|other-bundle.pem|databaseCa.key must be global-bundle.pem \(got "other-bundle.pem"\)|database_ca_test.yaml: it: rejects a key other than global-bundle.pem ; validate-chart.sh: must_fail: databaseCa.key other than global-bundle.pem
dbca||key|application.yml|databaseCa.key must be global-bundle.pem|validate-chart.sh: vendored_must_fail: databaseCaBundle.key application.yml
dbca||configMapName|any-config|databaseCa.configMapName must be rds-ca-bundle \(got "any-config"\)|database_ca_test.yaml: it: rejects a ConfigMap other than rds-ca-bundle (replaces the database trust anchor) ; validate-chart.sh: must_fail: databaseCa.configMapName other than rds-ca-bundle (replaces the trust anchor) ; validate-chart.sh: vendored_must_fail: databaseCaBundle.configMapName other than rds-ca-bundle
dbca||configMapName|null|databaseCa.configMapName is required while databaseCa.enabled|database_ca_test.yaml: it: rejects a null configMapName (Helm deletes the key; the volume would name no ConfigMap) ; validate-chart.sh: must_fail: databaseCa.configMapName null (Helm deletes the key; the volume would name no ConfigMap) ; validate-chart.sh: vendored_must_fail: databaseCaBundle.configMapName null (the adapter passes the key, so the guard sees it)
config||SPRING_KAFKA_SSL_TRUSTSTORE_LOCATION|file:/etc/other/any.jks|config.SPRING_KAFKA_SSL_TRUSTSTORE_LOCATION is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config SPRING_KAFKA_SSL_TRUSTSTORE_LOCATION (kafka.runtime msk)
config||SPRING_KAFKA_SSL_TRUST_STORE_LOCATION|file:/etc/other/any.jks|config.SPRING_KAFKA_SSL_TRUST_STORE_LOCATION is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config SPRING_KAFKA_SSL_TRUST_STORE_LOCATION (binds spring.kafka.ssl.trust-store-location) ; validate-chart.sh: must_fail: config SPRING_KAFKA_SSL_TRUST_STORE_LOCATION (Kafka trust store)
config||spring.kafka.ssl.trust-store-certificates|-----BEGIN CERTIFICATE-----|config.spring.kafka.ssl.trust-store-certificates is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config spring.kafka.ssl.trust-store-certificates (dotted)
config||spring.kafka.s-sl.trust-store-location|file:/etc/other/any.jks|config.spring.kafka.s-sl.trust-store-location is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config spring.kafka.s-sl.trust-store-location (relaxed binding reads s-sl as ssl)
config||SPRING_KAFKA_SSL_PROTOCOL|TLSv1|config.SPRING_KAFKA_SSL_PROTOCOL is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config SPRING_KAFKA_SSL_PROTOCOL (TLS protocol version)
env||SPRING_KAFKA_PRODUCER_SSL_KEY_STORE_LOCATION|file:/etc/other/any.p12|extraEnv must not set SPRING_KAFKA_PRODUCER_SSL_KEY_STORE_LOCATION \(value or valueFrom\): a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects extraEnv SPRING_KAFKA_PRODUCER_SSL_KEY_STORE_LOCATION (per-client ssl)
envfrom||spring.kafka.consumer.ssl.trust-store-type|{configMapKeyRef: {name: other, key: type}}|extraEnv must not set spring.kafka.consumer.ssl.trust-store-type \(value or valueFrom\): a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects extraEnv spring.kafka.consumer.ssl.trust-store-type from valueFrom
config||SPRING_KAFKA_ADMIN_SSL_TRUST_STORE_CERTIFICATES|-----BEGIN CERTIFICATE-----|config.SPRING_KAFKA_ADMIN_SSL_TRUST_STORE_CERTIFICATES is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config SPRING_KAFKA_ADMIN_SSL_TRUST_STORE_CERTIFICATES
config||spring.kafka.streams.ssl.key-password|x|config.spring.kafka.streams.ssl.key-password is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config spring.kafka.streams.ssl.key-password
config||spring.kafka.properties.ssl.truststore.location|/etc/other/any.jks|config.spring.kafka.properties.ssl.truststore.location is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config spring.kafka.properties.ssl.truststore.location ; validate-chart.sh: vendored_must_fail: env spring.kafka.properties.ssl.truststore.location
config||SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_LOCATION|/etc/other/any.jks|config.SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_LOCATION is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_LOCATION
config||spring.kafka.properties[ssl.truststore.type]|PEM|config.spring.kafka.properties\[ssl.truststore.type\] is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config spring.kafka.properties[ssl.truststore.type] (bracket form)
env||spring.kafka.properties[ssl.truststore.type]|PEM|extraEnv must not set spring.kafka.properties\[ssl.truststore.type\] \(value or valueFrom\): a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects extraEnv spring.kafka.properties[ssl.truststore.type] (bracket form)
config||spring.kafka.pro-perties.ssl.truststore.location|/etc/other/any.jks|config.spring.kafka.pro-perties.ssl.truststore.location is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config spring.kafka.pro-perties.ssl.truststore.location (relaxed binding)
config||spring.kafka.streams.properties.ssl.keystore.location|/etc/other/any.p12|config.spring.kafka.streams.properties.ssl.keystore.location is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config spring.kafka.streams.properties.ssl.keystore.location (per-client properties)
envfrom||SPRING_KAFKA_CONSUMER_PROPERTIES_SSL_TRUSTSTORE_TYPE|{secretKeyRef: {name: other, key: type}}|extraEnv must not set SPRING_KAFKA_CONSUMER_PROPERTIES_SSL_TRUSTSTORE_TYPE \(value or valueFrom\): a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects extraEnv SPRING_KAFKA_CONSUMER_PROPERTIES_SSL_TRUSTSTORE_TYPE from secretKeyRef
es||SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_PASSWORD|truststore_password|externalSecret.data must not materialise SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_PASSWORD .*: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects externalSecret.data materialising SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_PASSWORD
es||spring.kafka.ssl.key-store-key|key|externalSecret.extraData must not materialise spring.kafka.ssl.key-store-key .*: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects externalSecret.extraData materialising spring.kafka.ssl.key-store-key
jto|||-Dspring.kafka.ssl.trust-store-location=file:/etc/other/any.jks|javaToolOptions must not mention|kafka_client_tls_names_test.yaml: it: rejects javaToolOptions with -Dspring.kafka.ssl.trust-store-location (ssl mention)
env||JDK_JAVA_OPTIONS|-Dspring.kafka.properties.ssl.truststore.location=/etc/other/any.jks|extraEnv.JDK_JAVA_OPTIONS must not mention|kafka_client_tls_names_test.yaml: it: rejects extraEnv JDK_JAVA_OPTIONS with -Dspring.kafka.properties.ssl.truststore.location (ssl mention)
config|strimzi|SPRING_KAFKA_SSL_TRUST_STORE_CERTIFICATES|-----BEGIN CERTIFICATE-----|config.SPRING_KAFKA_SSL_TRUST_STORE_CERTIFICATES is not allowed: a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects config SPRING_KAFKA_SSL_TRUST_STORE_CERTIFICATES with kafka.runtime strimzi
env|strimzi|SPRING_KAFKA_PROPERTIES_SSL_KEYSTORE_LOCATION|/etc/other/any.p12|extraEnv must not set SPRING_KAFKA_PROPERTIES_SSL_KEYSTORE_LOCATION \(value or valueFrom\): a Kafka client TLS setting|kafka_client_tls_names_test.yaml: it: rejects extraEnv SPRING_KAFKA_PROPERTIES_SSL_KEYSTORE_LOCATION with kafka.runtime strimzi
config||SPRING_KAFKA_PROPERTIES_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM||config.SPRING_KAFKA_PROPERTIES_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM must be https|kafka_client_tls_names_test.yaml: it: still rejects SPRING_KAFKA_PROPERTIES_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM empty (value check)
env|strimzi|KAFKA_TLS_CA|-----BEGIN CERTIFICATE-----|extraEnv KAFKA_TLS_CA must come from valueFrom.secretKeyRef|kafka_client_tls_names_test.yaml: it: rejects extraEnv KAFKA_TLS_CA with a literal value (kafka.runtime strimzi) ; validate-chart.sh: must_fail: extraEnv KAFKA_TLS_CA as a literal (kafka.runtime strimzi)
envfrom|strimzi|KAFKA_TLS_CERT|{configMapKeyRef: {name: other, key: user.crt}}|extraEnv KAFKA_TLS_CERT must come from valueFrom.secretKeyRef|kafka_client_tls_names_test.yaml: it: rejects extraEnv KAFKA_TLS_CERT from configMapKeyRef (kafka.runtime strimzi)
envfrom|strimzi|KAFKA_TLS_KEY|{fieldRef: {fieldPath: metadata.name}}|extraEnv KAFKA_TLS_KEY must come from valueFrom.secretKeyRef|kafka_client_tls_names_test.yaml: it: rejects extraEnv KAFKA_TLS_KEY from fieldRef (kafka.runtime strimzi)
envboth|strimzi|KAFKA_TLS_CA|{secretKeyRef: {name: kafka-client-tls, key: ca.crt}}|extraEnv KAFKA_TLS_CA must come from valueFrom.secretKeyRef|kafka_client_tls_names_test.yaml: it: rejects extraEnv KAFKA_TLS_CA with an empty value next to secretKeyRef
config|strimzi|KAFKA_TLS_CA|-----BEGIN CERTIFICATE-----|config.KAFKA_TLS_CA is not allowed: .*Secret|kafka_client_tls_names_test.yaml: it: rejects config KAFKA_TLS_CA (kafka.runtime strimzi)
config||KAFKA_TLS_KEY|x|config.KAFKA_TLS_KEY is not allowed: .*Secret|kafka_client_tls_names_test.yaml: it: rejects config KAFKA_TLS_KEY (kafka.runtime msk)
envfrom|strimzi|kafka.tls.ca|{secretKeyRef: {name: kafka-client-tls, key: ca.crt}}|extraEnv kafka.tls.ca is not allowed: .*KAFKA_TLS_CA|kafka_client_tls_names_test.yaml: it: rejects extraEnv kafka.tls.ca (another spelling) even from secretKeyRef
es||kafka-tls-cert|user_crt|externalSecret.data kafka-tls-cert is not allowed: .*KAFKA_TLS_CERT|kafka_client_tls_names_test.yaml: it: rejects externalSecret.data key kafka-tls-cert (another spelling)
config||Kafka_Tls_Cert|x|config.Kafka_Tls_Cert is not allowed|kafka_client_tls_names_test.yaml: it: rejects config Kafka_Tls_Cert (another spelling)
jto|||-DKAFKA_TLS_CA=/etc/other/any.pem|javaToolOptions must not mention|kafka_client_tls_names_test.yaml: it: rejects javaToolOptions with -DKAFKA_TLS_CA (a system property wins over the environment)
config||SPRING_KAFKA_SSL_KEY_STORE_KEY|x|config.SPRING_KAFKA_SSL_KEY_STORE_KEY is not allowed: a Kafka client TLS setting|kafka_runtime_required_test.yaml: it: rejects config SPRING_KAFKA_SSL_KEY_STORE_KEY without kafka.runtime
env||spring.kafka.properties.ssl.truststore.certificates|-----BEGIN CERTIFICATE-----|extraEnv must not set spring.kafka.properties.ssl.truststore.certificates \(value or valueFrom\): a Kafka client TLS setting|kafka_runtime_required_test.yaml: it: rejects extraEnv spring.kafka.properties.ssl.truststore.certificates without kafka.runtime
env||KAFKA_TLS_CA|-----BEGIN CERTIFICATE-----|extraEnv KAFKA_TLS_CA must come from valueFrom.secretKeyRef|kafka_runtime_required_test.yaml: it: rejects extraEnv KAFKA_TLS_CA as a literal without kafka.runtime
config||SPRING_DATA_MONGODB_URI|mongodb://docdb.example.internal:27017/db?tls=false|config.SPRING_DATA_MONGODB_URI is not allowed: a spring.data.mongodb.\* property|documentdb_names_test.yaml: it: rejects config SPRING_DATA_MONGODB_URI ; validate-chart.sh: must_fail: config SPRING_DATA_MONGODB_URI (DocumentDB URI override)
config||spring.data.mongodb.uri|mongodb://docdb.example.internal:27017/db?tls=false|config.spring.data.mongodb.uri is not allowed: a spring.data.mongodb.\* property|documentdb_names_test.yaml: it: rejects config spring.data.mongodb.uri (dotted) ; validate-chart.sh: vendored_must_fail: env spring.data.mongodb.uri
config||spring.data.mongo-db.uri|mongodb://docdb.example.internal:27017/db?tls=false|config.spring.data.mongo-db.uri is not allowed: a spring.data.mongodb.\* property|documentdb_names_test.yaml: it: rejects config spring.data.mongo-db.uri (relaxed binding)
config||spring.data[mongodb].uri|mongodb://docdb.example.internal:27017/db?tls=false|config.spring.data\[mongodb\].uri is not allowed: a spring.data.mongodb.\* property|documentdb_names_test.yaml: it: rejects config spring.data[mongodb].uri (bracket form)
config||SPRING_DATA_MONGODB_SSL_ENABLED|false|config.SPRING_DATA_MONGODB_SSL_ENABLED is not allowed: a spring.data.mongodb.\* property|documentdb_names_test.yaml: it: rejects config SPRING_DATA_MONGODB_SSL_ENABLED=false
env||spring.data.mongodb.host|other.example.internal|extraEnv must not set spring.data.mongodb.host \(value or valueFrom\): a spring.data.mongodb.\* property|documentdb_names_test.yaml: it: rejects extraEnv spring.data.mongodb.host
envfrom||SPRING_DATA_MONGODB_REPLICA_SET_NAME|{configMapKeyRef: {name: other, key: rs}}|extraEnv must not set SPRING_DATA_MONGODB_REPLICA_SET_NAME \(value or valueFrom\): a spring.data.mongodb.\* property|documentdb_names_test.yaml: it: rejects extraEnv SPRING_DATA_MONGODB_REPLICA_SET_NAME from valueFrom
es||SPRING_DATA_MONGODB_URI|uri|externalSecret.data must not materialise SPRING_DATA_MONGODB_URI .*: a spring.data.mongodb.\* property|documentdb_names_test.yaml: it: rejects externalSecret.data materialising SPRING_DATA_MONGODB_URI
es||spring.data.mongodb.database|database|externalSecret.extraData must not materialise spring.data.mongodb.database|documentdb_names_test.yaml: it: rejects externalSecret.extraData materialising spring.data.mongodb.database
config||spring.data.mongodb.password|x|config.spring.data.mongodb.password is not allowed: a spring.data.mongodb.\* property|documentdb_names_test.yaml: it: rejects config spring.data.mongodb.password (credentials only in the env spelling, like the datasource)
config||MONGODB_URI|mongodb://docdb.example.internal:27017/db?tls=false|config.MONGODB_URI is not allowed: MONGODB_URI is the DocumentDB connection string|documentdb_names_test.yaml: it: rejects config MONGODB_URI
env||MONGODB_URI|mongodb://docdb.example.internal:27017/db?tlsAllowInvalidCertificates=true|extraEnv MONGODB_URI must come from valueFrom.secretKeyRef|documentdb_names_test.yaml: it: rejects extraEnv MONGODB_URI with a literal value ; validate-chart.sh: must_fail: extraEnv MONGODB_URI as a literal
envfrom||MONGODB_URI|{configMapKeyRef: {name: other, key: uri}}|extraEnv MONGODB_URI must come from valueFrom.secretKeyRef|documentdb_names_test.yaml: it: rejects extraEnv MONGODB_URI from configMapKeyRef
envfrom||mongodb.uri|{secretKeyRef: {name: docdb-app, key: uri}}|extraEnv mongodb.uri is not allowed: MONGODB_URI is the DocumentDB connection string|documentdb_names_test.yaml: it: rejects extraEnv mongodb.uri (another spelling) even from secretKeyRef
es||mongodb-uri|uri|externalSecret.data mongodb-uri is not allowed: MONGODB_URI is the DocumentDB connection string|documentdb_names_test.yaml: it: rejects externalSecret.data key mongodb-uri (another spelling)
es||mongodb.uri|uri|externalSecret.data mongodb.uri is not allowed|validate-chart.sh: vendored_must_fail: secret key mongodb.uri (MONGODB_URI in another spelling)
jto|||-DMONGODB_URI=mongodb://other.example.internal:27017/db|javaToolOptions must not mention .*mongodb|documentdb_names_test.yaml: it: rejects javaToolOptions with -DMONGODB_URI ; validate-chart.sh: vendored_must_fail: jvmOptions with -DMONGODB_URI (mongodb mention)
jto|||-Dspring.data.mongo-db.uri=mongodb://other.example.internal:27017/db|javaToolOptions must not mention .*mongodb|documentdb_names_test.yaml: it: rejects javaToolOptions with -Dspring.data.mongo-db.uri (separator inside the word)
jto|||-Dspring.kafka.bootstrap-servers=other.example.internal:9092|javaToolOptions must not mention .*kafka|documentdb_names_test.yaml: it: rejects javaToolOptions with -Dspring.kafka.bootstrap-servers ; validate-chart.sh: must_fail: javaToolOptions with -Dspring.kafka.bootstrap-servers (kafka mention)
config||JDK_JAVA_OPTIONS|-Dspring.Kaf_ka.producer.acks=0|config.JDK_JAVA_OPTIONS must not mention .*kafka|documentdb_names_test.yaml: it: rejects config JDK_JAVA_OPTIONS with -Dspring.Kaf_ka.producer.acks (case and separators)
env||_JAVA_OPTIONS|-Dlogging.level.org.apache.kafka=DEBUG|extraEnv._JAVA_OPTIONS must not mention .*kafka|documentdb_names_test.yaml: it: rejects extraEnv _JAVA_OPTIONS with -Dlogging.level.org.apache.kafka
config|strimzi|spring.kafka.s_sl.trust-store-type|PKCS12|config.spring.kafka.s_sl.trust-store-type is not allowed: a Kafka client TLS setting|property_reading_names_test.yaml: it: rejects config spring.kafka.s_sl.trust-store-type (kafka.runtime strimzi) ; validate-chart.sh: must_fail: config spring.kafka.s_sl.trust-store-type ('_' inside an element binds as ssl)
envfrom||spring.kafka.consumer.s_sl.trust-store-type|{secretKeyRef: {name: other, key: type}}|extraEnv must not set spring.kafka.consumer.s_sl.trust-store-type \(value or valueFrom\): a Kafka client TLS setting|property_reading_names_test.yaml: it: rejects extraEnv spring.kafka.consumer.s_sl.trust-store-type from valueFrom.secretKeyRef ; validate-chart.sh: vendored_must_fail: additionalEnv spring.kafka.consumer.s_sl.trust-store-type from valueFrom ('_' inside an element)
es||spring.kafka.s_sl.trust-store-location|location|externalSecret.extraData must not materialise spring.kafka.s_sl.trust-store-location .*a Kafka client TLS setting|property_reading_names_test.yaml: it: rejects externalSecret.extraData materialising spring.kafka.s_sl.trust-store-location
config||spring.kafka.con_sumer.ssl.trust-store-type|PKCS12|config.spring.kafka.con_sumer.ssl.trust-store-type is not allowed: a Kafka client TLS setting|property_reading_names_test.yaml: it: rejects config spring.kafka.con_sumer.ssl.trust-store-type ('_' inside the client element)
config||spring.kafka.streams.pro_perties.ssl.truststore.location|/etc/other/any.jks|config.spring.kafka.streams.pro_perties.ssl.truststore.location is not allowed: a Kafka client TLS setting|property_reading_names_test.yaml: it: rejects config spring.kafka.streams.pro_perties.ssl.truststore.location ('_' inside properties)
config||spring.kafka.security.pro_tocol|PLAINTEXT|config.spring.kafka.security.pro_tocol must be SASL_SSL or SSL|property_reading_names_test.yaml: it: rejects config spring.kafka.security.pro_tocol PLAINTEXT (value check)
envfrom||spring.kafka.secu_rity.protocol|{configMapKeyRef: {name: other, key: protocol}}|extraEnv spring.kafka.secu_rity.protocol must set a literal value|property_reading_names_test.yaml: it: rejects extraEnv spring.kafka.secu_rity.protocol from valueFrom (the value cannot be checked)
config||spring.data.mongo_db.host|placeholder-host|config.spring.data.mongo_db.host is not allowed: a spring.data.mongodb.\* property|property_reading_names_test.yaml: it: rejects config spring.data.mongo_db.host
es||spring.data.mongo_db.host|host|externalSecret.extraData must not materialise spring.data.mongo_db.host .*a spring.data.mongodb.\* property|property_reading_names_test.yaml: it: rejects externalSecret.extraData materialising spring.data.mongo_db.host ; validate-chart.sh: must_fail: externalSecret.extraData spring.data.mongo_db.host ('_' inside an element binds as mongodb)
envfrom||spring.data.mongo_db.uri|{secretKeyRef: {name: other, key: uri}}|extraEnv must not set spring.data.mongo_db.uri \(value or valueFrom\): a spring.data.mongodb.\* property|property_reading_names_test.yaml: it: rejects extraEnv spring.data.mongo_db.uri from valueFrom.secretKeyRef ; validate-chart.sh: vendored_must_fail: env spring.data.mongo_db.uri ('_' inside an element)
config||spring.da_ta.mongodb.port|27018|config.spring.da_ta.mongodb.port is not allowed: a spring.data.mongodb.\* property|property_reading_names_test.yaml: it: rejects config spring.da_ta.mongodb.port ('_' inside data)
config||spring.pro_files.active|local|config.spring.pro_files.active is not allowed: a profile can activate|property_reading_names_test.yaml: it: rejects config spring.pro_files.active ; validate-chart.sh: must_fail: config spring.pro_files.active ('_' inside an element binds as profiles)
env||spring.pro_files.default|local|extraEnv must not set spring.pro_files.default \(value or valueFrom\): a profile can activate|property_reading_names_test.yaml: it: rejects extraEnv spring.pro_files.default
es||spring.pro_files.include|profile|externalSecret.data must not materialise spring.pro_files.include .*a profile can activate|property_reading_names_test.yaml: it: rejects externalSecret.data materialising spring.pro_files.include
env||s_pring.profiles.active|local|extraEnv must not set s_pring.profiles.active \(value or valueFrom\): a profile can activate|property_reading_names_test.yaml: it: rejects extraEnv s_pring.profiles.active ('_' inside the first element)
config||spring.con_fig.import|optional:file:/etc/other/override.yml|config.spring.con_fig.import is not allowed: a spring.config.\* property|property_reading_names_test.yaml: it: rejects config spring.con_fig.import
env||spring.applica_tion.json|{"spring":{"datasource":{"url":"jdbc:h2:mem:x"}}}|extraEnv must not set spring.applica_tion.json \(value or valueFrom\): it can redirect or override the datasource|property_reading_names_test.yaml: it: rejects extraEnv spring.applica_tion.json
config||spring.s_sl.bundle.pem.documentdb.truststore.certificate|file:/etc/other/any-ca.pem|config.spring.s_sl.bundle.pem.documentdb.truststore.certificate is not allowed: an SSL bundle property|property_reading_names_test.yaml: it: rejects config spring.s_sl.bundle.pem.documentdb.truststore.certificate
config||fintech_bankx.tls.enforce|false|config.fintech_bankx.tls.enforce is not allowed: it can switch off the service's startup TLS assertion|property_reading_names_test.yaml: it: rejects config fintech_bankx.tls.enforce
envfrom||fintechbankx.t_ls.enforce|{configMapKeyRef: {name: other, key: enforce}}|extraEnv must not set fintechbankx.t_ls.enforce \(value or valueFrom\): it can switch off|property_reading_names_test.yaml: it: rejects extraEnv fintechbankx.t_ls.enforce from valueFrom
config||spring.data_source.url|jdbc:h2:mem:x|config.spring.data_source.url is not allowed: it can redirect or override the datasource|property_reading_names_test.yaml: it: rejects config spring.data_source.url with a non-PostgreSQL URL (no JDBC parse applies)
config||spring.data_source.driver-class-name|org.h2.Driver|config.spring.data_source.driver-class-name is not allowed: it can redirect or override the datasource|property_reading_names_test.yaml: it: rejects config spring.data_source.driver-class-name
config||spring.fly_way.url|jdbc:h2:mem:x|config.spring.fly_way.url is not allowed: it can redirect or override the datasource|property_reading_names_test.yaml: it: rejects config spring.fly_way.url
pass||app.feature_flags.new_ui|true|-|property_reading_names_test.yaml: it: accepts other names with '_' inside an element and the credential names (control) (control, first name)
pass||logging.level.com_example_loan|DEBUG|-|property_reading_names_test.yaml: it: accepts other names with '_' inside an element and the credential names (control) (control, second name)
envfrom||SPRING_KAFKA_PRODUCER_PROPERTIES_SSL_TRUSTSTORE_CERTIFICATES|{configMapKeyRef: {name: other, key: ca}}|extraEnv must not set SPRING_KAFKA_PRODUCER_PROPERTIES_SSL_TRUSTSTORE_CERTIFICATES|validate-chart.sh: must_fail: extraEnv SPRING_KAFKA_PRODUCER_PROPERTIES_SSL_TRUSTSTORE_CERTIFICATES from valueFrom
config|strimzi|KAFKA_TLS_CERT|-----BEGIN CERTIFICATE-----|config.KAFKA_TLS_CERT is not allowed|validate-chart.sh: must_fail: config KAFKA_TLS_CERT (kafka.runtime strimzi)
envfrom|strimzi|KAFKA_TLS_KEY|{configMapKeyRef: {name: other, key: user.key}}|extraEnv KAFKA_TLS_KEY must come from valueFrom.secretKeyRef|validate-chart.sh: vendored_must_fail: additionalEnv KAFKA_TLS_KEY from configMapKeyRef (strimzi)
CASES

echo "guard-upstream-cases: $passed passed, $failed failed, $skipped not applicable"
[ "$failed" -eq 0 ]
