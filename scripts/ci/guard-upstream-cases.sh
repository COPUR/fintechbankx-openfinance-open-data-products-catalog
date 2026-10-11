#!/usr/bin/env bash
# guard-upstream-cases.sh <chart-dir> [options] -- <helm args of a rendering install>
#
# Every refusal case the platform repository added with the guard this chart vendors
# (fintechbankx-platform-delivery-iac-cicd-templates a4f0072..6b6c317: the helm-unittest suites
# database_ca_test, kafka_client_tls_names_test, kafka_runtime_required_test, documentdb_names_test and
# property_reading_names_test, and the must_fail cases scripts/ci/validate-chart.sh gained), run
# against this chart's adapter with the upstream error pattern, so a case cannot pass because the
# render failed for another reason. Upstream routes map to this chart's values:
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

# route|flags|name|value|expected (upstream errorPattern; "-" = must render)
while IFS='|' read -r route flags name value expect; do
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
      if [ "$extra_data" -eq 0 ]; then skipped=$((skipped + 1)); echo "not applicable (no externalSecret.data/extraData values): $name"; continue; fi
      expect="${expect/externalSecret.data /externalSecret.extraData }"
      check "externalSecret.extraData $name" "$expect" "${extra[@]}" \
        -f "$(file 'externalSecret:' '  extraData:' "    - secretKey: '$name'" "      property: '$value'" '      remoteSecretName: ci/other')" ;;
    jto)
      if [ "$jto" -eq 1 ]; then
        check "javaToolOptions $value" "$expect" --set-string "javaToolOptions=$value"
      else
        check "config.JAVA_TOOL_OPTIONS $value" "config[.]JAVA_TOOL_OPTIONS${expect#javaToolOptions}" -f "$(file 'config:' "  JAVA_TOOL_OPTIONS: '$value'")"
      fi ;;
    dbca)
      if [ "$dbca" -eq 0 ]; then skipped=$((skipped + 1)); echo "not applicable (databaseCa disabled in the adapter): databaseCaBundle.$name"; continue; fi
      if [ "$value" = null ]; then check "databaseCaBundle.$name=null" "$expect" --set "databaseCaBundle.$name=null"
      else check "databaseCaBundle.$name=$value" "$expect" --set-string "databaseCaBundle.$name=$value"; fi ;;
    *) echo "unknown route $route" >&2; exit 2 ;;
  esac
done <<'CASES'
# database_ca_test.yaml (a4f0072..6b6c317) and validate-chart.sh databaseCa must_fail
dbca||mountPath|/app/config|databaseCa.mountPath must be /etc/fintechbankx/rds-ca \(got "/app/config"\)
dbca||mountPath|/etc/fintechbankx/rds-ca/|databaseCa.mountPath must be /etc/fintechbankx/rds-ca
dbca||key|other-bundle.pem|databaseCa.key must be global-bundle.pem \(got "other-bundle.pem"\)
dbca||key|application.yml|databaseCa.key must be global-bundle.pem
dbca||configMapName|any-config|databaseCa.configMapName must be rds-ca-bundle \(got "any-config"\)
dbca||configMapName|null|databaseCa.configMapName is required while databaseCa.enabled
# kafka_client_tls_names_test.yaml
config||SPRING_KAFKA_SSL_TRUSTSTORE_LOCATION|file:/etc/other/any.jks|config.SPRING_KAFKA_SSL_TRUSTSTORE_LOCATION is not allowed: a Kafka client TLS setting
config||SPRING_KAFKA_SSL_TRUST_STORE_LOCATION|file:/etc/other/any.jks|config.SPRING_KAFKA_SSL_TRUST_STORE_LOCATION is not allowed: a Kafka client TLS setting
config||spring.kafka.ssl.trust-store-certificates|-----BEGIN CERTIFICATE-----|config.spring.kafka.ssl.trust-store-certificates is not allowed: a Kafka client TLS setting
config||spring.kafka.s-sl.trust-store-location|file:/etc/other/any.jks|config.spring.kafka.s-sl.trust-store-location is not allowed: a Kafka client TLS setting
config||SPRING_KAFKA_SSL_PROTOCOL|TLSv1|config.SPRING_KAFKA_SSL_PROTOCOL is not allowed: a Kafka client TLS setting
env||SPRING_KAFKA_PRODUCER_SSL_KEY_STORE_LOCATION|file:/etc/other/any.p12|extraEnv must not set SPRING_KAFKA_PRODUCER_SSL_KEY_STORE_LOCATION \(value or valueFrom\): a Kafka client TLS setting
envfrom||spring.kafka.consumer.ssl.trust-store-type|{configMapKeyRef: {name: other, key: type}}|extraEnv must not set spring.kafka.consumer.ssl.trust-store-type \(value or valueFrom\): a Kafka client TLS setting
config||SPRING_KAFKA_ADMIN_SSL_TRUST_STORE_CERTIFICATES|-----BEGIN CERTIFICATE-----|config.SPRING_KAFKA_ADMIN_SSL_TRUST_STORE_CERTIFICATES is not allowed: a Kafka client TLS setting
config||spring.kafka.streams.ssl.key-password|x|config.spring.kafka.streams.ssl.key-password is not allowed: a Kafka client TLS setting
config||spring.kafka.properties.ssl.truststore.location|/etc/other/any.jks|config.spring.kafka.properties.ssl.truststore.location is not allowed: a Kafka client TLS setting
config||SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_LOCATION|/etc/other/any.jks|config.SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_LOCATION is not allowed: a Kafka client TLS setting
config||spring.kafka.properties[ssl.truststore.type]|PEM|config.spring.kafka.properties\[ssl.truststore.type\] is not allowed: a Kafka client TLS setting
env||spring.kafka.properties[ssl.truststore.type]|PEM|extraEnv must not set spring.kafka.properties\[ssl.truststore.type\] \(value or valueFrom\): a Kafka client TLS setting
config||spring.kafka.pro-perties.ssl.truststore.location|/etc/other/any.jks|config.spring.kafka.pro-perties.ssl.truststore.location is not allowed: a Kafka client TLS setting
config||spring.kafka.streams.properties.ssl.keystore.location|/etc/other/any.p12|config.spring.kafka.streams.properties.ssl.keystore.location is not allowed: a Kafka client TLS setting
envfrom||SPRING_KAFKA_CONSUMER_PROPERTIES_SSL_TRUSTSTORE_TYPE|{secretKeyRef: {name: other, key: type}}|extraEnv must not set SPRING_KAFKA_CONSUMER_PROPERTIES_SSL_TRUSTSTORE_TYPE \(value or valueFrom\): a Kafka client TLS setting
es||SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_PASSWORD|truststore_password|externalSecret.data must not materialise SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_PASSWORD .*: a Kafka client TLS setting
es||spring.kafka.ssl.key-store-key|key|externalSecret.extraData must not materialise spring.kafka.ssl.key-store-key .*: a Kafka client TLS setting
jto|||-Dspring.kafka.ssl.trust-store-location=file:/etc/other/any.jks|javaToolOptions must not mention
env||JDK_JAVA_OPTIONS|-Dspring.kafka.properties.ssl.truststore.location=/etc/other/any.jks|extraEnv.JDK_JAVA_OPTIONS must not mention
config|strimzi|SPRING_KAFKA_SSL_TRUST_STORE_CERTIFICATES|-----BEGIN CERTIFICATE-----|config.SPRING_KAFKA_SSL_TRUST_STORE_CERTIFICATES is not allowed: a Kafka client TLS setting
env|strimzi|SPRING_KAFKA_PROPERTIES_SSL_KEYSTORE_LOCATION|/etc/other/any.p12|extraEnv must not set SPRING_KAFKA_PROPERTIES_SSL_KEYSTORE_LOCATION \(value or valueFrom\): a Kafka client TLS setting
config||SPRING_KAFKA_PROPERTIES_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM||config.SPRING_KAFKA_PROPERTIES_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM must be https
env|strimzi|KAFKA_TLS_CA|-----BEGIN CERTIFICATE-----|extraEnv KAFKA_TLS_CA must come from valueFrom.secretKeyRef
envfrom|strimzi|KAFKA_TLS_CERT|{configMapKeyRef: {name: other, key: user.crt}}|extraEnv KAFKA_TLS_CERT must come from valueFrom.secretKeyRef
envfrom|strimzi|KAFKA_TLS_KEY|{fieldRef: {fieldPath: metadata.name}}|extraEnv KAFKA_TLS_KEY must come from valueFrom.secretKeyRef
envboth|strimzi|KAFKA_TLS_CA|{secretKeyRef: {name: kafka-client-tls, key: ca.crt}}|extraEnv KAFKA_TLS_CA must come from valueFrom.secretKeyRef
config|strimzi|KAFKA_TLS_CA|-----BEGIN CERTIFICATE-----|config.KAFKA_TLS_CA is not allowed: .*Secret
config||KAFKA_TLS_KEY|x|config.KAFKA_TLS_KEY is not allowed: .*Secret
envfrom|strimzi|kafka.tls.ca|{secretKeyRef: {name: kafka-client-tls, key: ca.crt}}|extraEnv kafka.tls.ca is not allowed: .*KAFKA_TLS_CA
es||kafka-tls-cert|user_crt|externalSecret.data kafka-tls-cert is not allowed: .*KAFKA_TLS_CERT
config||Kafka_Tls_Cert|x|config.Kafka_Tls_Cert is not allowed
jto|||-DKAFKA_TLS_CA=/etc/other/any.pem|javaToolOptions must not mention
# kafka_runtime_required_test.yaml (a4f0072..6b6c317)
config||SPRING_KAFKA_SSL_KEY_STORE_KEY|x|config.SPRING_KAFKA_SSL_KEY_STORE_KEY is not allowed: a Kafka client TLS setting
env||spring.kafka.properties.ssl.truststore.certificates|-----BEGIN CERTIFICATE-----|extraEnv must not set spring.kafka.properties.ssl.truststore.certificates \(value or valueFrom\): a Kafka client TLS setting
env||KAFKA_TLS_CA|-----BEGIN CERTIFICATE-----|extraEnv KAFKA_TLS_CA must come from valueFrom.secretKeyRef
# documentdb_names_test.yaml
config||SPRING_DATA_MONGODB_URI|mongodb://docdb.example.internal:27017/db?tls=false|config.SPRING_DATA_MONGODB_URI is not allowed: a spring.data.mongodb.\* property
config||spring.data.mongodb.uri|mongodb://docdb.example.internal:27017/db?tls=false|config.spring.data.mongodb.uri is not allowed: a spring.data.mongodb.\* property
config||spring.data.mongo-db.uri|mongodb://docdb.example.internal:27017/db?tls=false|config.spring.data.mongo-db.uri is not allowed: a spring.data.mongodb.\* property
config||spring.data[mongodb].uri|mongodb://docdb.example.internal:27017/db?tls=false|config.spring.data\[mongodb\].uri is not allowed: a spring.data.mongodb.\* property
config||SPRING_DATA_MONGODB_SSL_ENABLED|false|config.SPRING_DATA_MONGODB_SSL_ENABLED is not allowed: a spring.data.mongodb.\* property
env||spring.data.mongodb.host|other.example.internal|extraEnv must not set spring.data.mongodb.host \(value or valueFrom\): a spring.data.mongodb.\* property
envfrom||SPRING_DATA_MONGODB_REPLICA_SET_NAME|{configMapKeyRef: {name: other, key: rs}}|extraEnv must not set SPRING_DATA_MONGODB_REPLICA_SET_NAME \(value or valueFrom\): a spring.data.mongodb.\* property
es||SPRING_DATA_MONGODB_URI|uri|externalSecret.data must not materialise SPRING_DATA_MONGODB_URI .*: a spring.data.mongodb.\* property
es||spring.data.mongodb.database|database|externalSecret.extraData must not materialise spring.data.mongodb.database
config||spring.data.mongodb.password|x|config.spring.data.mongodb.password is not allowed: a spring.data.mongodb.\* property
config||MONGODB_URI|mongodb://docdb.example.internal:27017/db?tls=false|config.MONGODB_URI is not allowed: MONGODB_URI is the DocumentDB connection string
env||MONGODB_URI|mongodb://docdb.example.internal:27017/db?tlsAllowInvalidCertificates=true|extraEnv MONGODB_URI must come from valueFrom.secretKeyRef
envfrom||MONGODB_URI|{configMapKeyRef: {name: other, key: uri}}|extraEnv MONGODB_URI must come from valueFrom.secretKeyRef
envfrom||mongodb.uri|{secretKeyRef: {name: docdb-app, key: uri}}|extraEnv mongodb.uri is not allowed: MONGODB_URI is the DocumentDB connection string
es||mongodb-uri|uri|externalSecret.data mongodb-uri is not allowed: MONGODB_URI is the DocumentDB connection string
es||mongodb.uri|uri|externalSecret.data mongodb.uri is not allowed
jto|||-DMONGODB_URI=mongodb://other.example.internal:27017/db|javaToolOptions must not mention .*mongodb
jto|||-Dspring.data.mongo-db.uri=mongodb://other.example.internal:27017/db|javaToolOptions must not mention .*mongodb
jto|||-Dspring.kafka.bootstrap-servers=other.example.internal:9092|javaToolOptions must not mention .*kafka
config||JDK_JAVA_OPTIONS|-Dspring.Kaf_ka.producer.acks=0|config.JDK_JAVA_OPTIONS must not mention .*kafka
env||_JAVA_OPTIONS|-Dlogging.level.org.apache.kafka=DEBUG|extraEnv._JAVA_OPTIONS must not mention .*kafka
# property_reading_names_test.yaml
config|strimzi|spring.kafka.s_sl.trust-store-type|PKCS12|config.spring.kafka.s_sl.trust-store-type is not allowed: a Kafka client TLS setting
envfrom||spring.kafka.consumer.s_sl.trust-store-type|{secretKeyRef: {name: other, key: type}}|extraEnv must not set spring.kafka.consumer.s_sl.trust-store-type \(value or valueFrom\): a Kafka client TLS setting
es||spring.kafka.s_sl.trust-store-location|location|externalSecret.extraData must not materialise spring.kafka.s_sl.trust-store-location .*a Kafka client TLS setting
config||spring.kafka.con_sumer.ssl.trust-store-type|PKCS12|config.spring.kafka.con_sumer.ssl.trust-store-type is not allowed: a Kafka client TLS setting
config||spring.kafka.streams.pro_perties.ssl.truststore.location|/etc/other/any.jks|config.spring.kafka.streams.pro_perties.ssl.truststore.location is not allowed: a Kafka client TLS setting
config||spring.kafka.security.pro_tocol|PLAINTEXT|config.spring.kafka.security.pro_tocol must be SASL_SSL or SSL
envfrom||spring.kafka.secu_rity.protocol|{configMapKeyRef: {name: other, key: protocol}}|extraEnv spring.kafka.secu_rity.protocol must set a literal value
config||spring.data.mongo_db.host|placeholder-host|config.spring.data.mongo_db.host is not allowed: a spring.data.mongodb.\* property
es||spring.data.mongo_db.host|host|externalSecret.extraData must not materialise spring.data.mongo_db.host .*a spring.data.mongodb.\* property
envfrom||spring.data.mongo_db.uri|{secretKeyRef: {name: other, key: uri}}|extraEnv must not set spring.data.mongo_db.uri \(value or valueFrom\): a spring.data.mongodb.\* property
config||spring.da_ta.mongodb.port|27018|config.spring.da_ta.mongodb.port is not allowed: a spring.data.mongodb.\* property
config||spring.pro_files.active|local|config.spring.pro_files.active is not allowed: a profile can activate
env||spring.pro_files.default|local|extraEnv must not set spring.pro_files.default \(value or valueFrom\): a profile can activate
es||spring.pro_files.include|profile|externalSecret.data must not materialise spring.pro_files.include .*a profile can activate
env||s_pring.profiles.active|local|extraEnv must not set s_pring.profiles.active \(value or valueFrom\): a profile can activate
config||spring.con_fig.import|optional:file:/etc/other/override.yml|config.spring.con_fig.import is not allowed: a spring.config.\* property
env||spring.applica_tion.json|{"spring":{"datasource":{"url":"jdbc:h2:mem:x"}}}|extraEnv must not set spring.applica_tion.json \(value or valueFrom\): it can redirect or override the datasource
config||spring.s_sl.bundle.pem.documentdb.truststore.certificate|file:/etc/other/any-ca.pem|config.spring.s_sl.bundle.pem.documentdb.truststore.certificate is not allowed: an SSL bundle property
config||fintech_bankx.tls.enforce|false|config.fintech_bankx.tls.enforce is not allowed: it can switch off the service's startup TLS assertion
envfrom||fintechbankx.t_ls.enforce|{configMapKeyRef: {name: other, key: enforce}}|extraEnv must not set fintechbankx.t_ls.enforce \(value or valueFrom\): it can switch off
config||spring.data_source.url|jdbc:h2:mem:x|config.spring.data_source.url is not allowed: it can redirect or override the datasource
config||spring.data_source.driver-class-name|org.h2.Driver|config.spring.data_source.driver-class-name is not allowed: it can redirect or override the datasource
config||spring.fly_way.url|jdbc:h2:mem:x|config.spring.fly_way.url is not allowed: it can redirect or override the datasource
pass||app.feature_flags.new_ui|true|-
pass||logging.level.com_example_loan|DEBUG|-
# validate-chart.sh must_fail (a4f0072..6b6c317) not already above
envfrom||SPRING_KAFKA_PRODUCER_PROPERTIES_SSL_TRUSTSTORE_CERTIFICATES|{configMapKeyRef: {name: other, key: ca}}|extraEnv must not set SPRING_KAFKA_PRODUCER_PROPERTIES_SSL_TRUSTSTORE_CERTIFICATES
config|strimzi|KAFKA_TLS_CERT|-----BEGIN CERTIFICATE-----|config.KAFKA_TLS_CERT is not allowed
envfrom|strimzi|KAFKA_TLS_KEY|{configMapKeyRef: {name: other, key: user.key}}|extraEnv KAFKA_TLS_KEY must come from valueFrom.secretKeyRef
CASES

echo "guard-upstream-cases: $passed passed, $failed failed, $skipped not applicable"
[ "$failed" -eq 0 ]
