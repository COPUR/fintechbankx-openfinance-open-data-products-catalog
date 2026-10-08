# Deployment and AWS Well-Architected notes: svc-of-open-products-catalog

The service is a stateless Spring Boot 3.3 application (Java 23) serving the
public product catalogue (`GET /open-finance/v1/products`) from its own Aurora
PostgreSQL database. It runs in EKS namespace `open-finance` behind the Istio
ingress gateway. Everything here is **Proposed** until the owning squad deploys it.

| Artefact | Path |
|---|---|
| Image | `Dockerfile` (layered jar, non-root `10001:10001`, ports 8080/8081) |
| Chart | `deploy/helm/open-products-catalog-service` (`values.yaml`, `values-dev.yaml`) |
| AWS resources | `deploy/terraform` (Aurora PostgreSQL Serverless v2, KMS, Secrets Manager, IRSA, alarms) |
| Schema | `src/main/resources/db/migration` (Flyway, schema `sc_of_open_products_catalog`) |
| Catalogue load | `db/import/import-products.sh` (CSV upsert); dev/CI seed in `src/main/resources/db/seed` |
| Gates | `.github/workflows/required-gates.yml`, `.github/workflows/deployability.yml` |

## Reliability

- At least 2 replicas, spread across zones (`topologySpreadConstraints`), PDB
  `minAvailable: 1`, rolling updates with `maxUnavailable: 0`, graceful
  shutdown (25 s) with a preStop delay.
- Readiness includes the database health check, so a pod without a database
  connection receives no traffic. Liveness does not, so a database outage does
  not cause restart loops.
- Aurora Serverless v2 with a reader in a second AZ in prod (`aurora_instance_count = 2`),
  35-day point-in-time recovery, deletion protection.
- Responses carry `Cache-Control: no-cache` and a strong `ETag`: they echo the
  caller's `X-FAPI-Interaction-ID`, so no shared cache may reuse them without
  revalidating, and `Links.Self` is a relative path that forwarded headers
  cannot change (the ingress also overwrites `X-Forwarded-*`).

## Security

- Public open data: the endpoint is anonymous by contract (`security: []`).
  Any `Authorization` header on it is ignored, never half-validated. Every other
  path is denied. The JWT resource server is configured against the platform
  Keycloak realm with issuer and audience (`svc-of-open-products-catalog`)
  validation, ready for future authenticated endpoints.
- Responses contain catalogue data only (no customer data); the table is
  classified `public`, while the database itself stays private.
- Pod: non-root, read-only root filesystem, all capabilities dropped,
  RuntimeDefault seccomp; Istio sidecar for mTLS; NetworkPolicy allows ingress
  from the gateway and Prometheus only, and egress to DNS, PostgreSQL, OIDC,
  OTLP and istiod.
- Credentials: `<env>/open-products-catalog-service/db-app` in Secrets Manager
  (KMS-encrypted), synced by External Secrets (`aws-secrets-manager`). The IRSA
  role can read only that secret, its KMS key and its SSM parameters. Aurora
  enforces TLS (`rds.force_ssl`).

## Performance efficiency

- One indexed query per request (partial indexes on `ACTIVE` rows by type and
  segment); strong ETags turn repeat reads into `304` without a body.
- Virtual threads for request handling; Hikari pool of 10 per pod.
- HPA on CPU (65 %) and memory, 2 to 8 replicas.

## Cost optimisation

- Aurora Serverless v2 at 0.5 ACU minimum (4 ACU max by default; dev 1 ACU,
  single instance). No Redis, no Kafka/MSK access until events exist (ADR-0001).
- Small pod requests (250m CPU / 512 MiB; dev 100m / 384 MiB).

## Operational excellence

- Metrics on the management port (`/actuator/prometheus`) tagged
  `service=svc-of-open-products-catalog`; OTLP traces to
  `otel-collector.observability.svc.cluster.local:4318` (sampling 10 % by default).
- CloudWatch alarms for Aurora ACU utilisation and connections.
- Deployability workflow builds the image, lints and renders the chart,
  validates Terraform and rehearses migration + seed + import on PostgreSQL.
- Catalogue changes are data operations (CSV import), not deployments.

## Sustainability

- Scale-to-low database capacity, small replica floor, HTTP caching that avoids
  repeated work, and a single read path with no background jobs.

## Not verified here

- `terraform validate` (registry blocked in the authoring environment; CI runs it).
- The container build (no Docker daemon in the authoring environment; CI builds it).
- Any deployment to AWS.
