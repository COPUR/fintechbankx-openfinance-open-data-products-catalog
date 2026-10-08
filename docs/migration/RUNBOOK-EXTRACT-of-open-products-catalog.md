# RUNBOOK-EXTRACT-of-open-products-catalog

Extraction of the product catalogue from `enterprise-loan-management-system`
(`open-finance-context/.../productcatalog`) into `svc-of-open-products-catalog`
(this repository).

| Field | Value |
|---|---|
| Context / service | `of` / `svc-of-open-products-catalog` (slug `open-products-catalog-service`) |
| Slice | Public product catalogue read model: `GET /open-finance/v1/products` |
| Owned data | `db_of_open_products_catalog_<env>`, schema `sc_of_open_products_catalog`: `product`, `product_history` |
| Events | none yet (ADR-0001); future namespace `evt.of.products.*` |
| Depends on | its database; ClusterSecretStore `aws-secrets-manager`; the gateway route and rate limit for `GET /open-finance/v1/products` (mesh PR #11, commit `5e756f0`: 100-token bucket refilled at 50/s per gateway pod, `429` with `Retry-After` and `x-fbx-rate-limited: true`), owned by `fintechbankx-platform-mesh-security-service-mesh` |

## 1. Data ownership split

| Monolith object | Owner after the split | Notes |
|---|---|---|
| `productcatalog` in-memory catalogue (5 sample rows) | not migrated | sample data; this service has its own dev seed |
| `productcatalog` in-memory TTL cache | dropped | replaced by HTTP caching (ETag, Cache-Control) |
| Product SQL tables | none exist | no monolith migration creates one, so there is nothing to backfill |
| `sc_of_open_products_catalog.product` | this service | Flyway `V1__create_product_catalogue.sql` |
| `sc_of_open_products_catalog.product_history` | this service | Flyway `V2__product_history_and_roles.sql` (append-only audit trail), `V3` (operator identity), `V4` (written only by its trigger; product deletes recorded) |

The service never reads monolith tables; nothing else reads `sc_of_open_products_catalog`.

## 2. Loading the catalogue

The database has three login roles, each with its own Secrets Manager secret
(KMS key `alias/<env>-open-products-catalog-service-db`):

| Role | Secret | Used by | May |
|---|---|---|---|
| `open_products_catalog_owner` | `<env>/open-products-catalog-service/db-migration` | Flyway, in the pod's `migrate` init container only | own the schema, run migrations |
| `open_products_catalog_app` | `<env>/open-products-catalog-service/db-app` | the serving container | `SELECT` on `product` (nothing on `product_history`) |
| `open_products_catalog_import` | `<env>/open-products-catalog-service/db-import` | operators running `import-products.sh` | `SELECT`, `INSERT`, `UPDATE` on `product`; no `DELETE` or `TRUNCATE` |

Every insert or update of `product` writes an append-only row to
`product_history` (old and new values, role, `application_name`, time; V2
migration; since V3 also `operator_arn`, the importing operator's AWS caller
identity). The runtime and import roles cannot update or delete history rows.
The schema owner, which owns the table and its trigger functions, is stopped
by the history guard (`db/bootstrap/history-guard.sql`): admin-owned event
triggers that refuse any DDL on the history table, its two functions or its
triggers once armed. Refusals, disarming and any DDL that reaches those
objects (pgaudit) raise the `<env>-open-products-catalog-service-history-tamper`
alarm (ADR-0001, section 2.3).

### 2.1 Where operator database work runs

The Aurora writer has no public path. Steps 2 and 4 run `psql` from one of:

- the **operator host** of the environment: an EC2 instance in a private
  subnet of the cluster's VPC, no public IP, no inbound rules, reached only
  through AWS Systems Manager Session Manager (no SSH, no port forwarding to a
  laptop);
- a **self-hosted CI agent** inside the same VPC, for a reviewed, scripted run.

Neither is created by this repository; the environment's platform stack
provides it.

Its security group must be in the Terraform variable
`operator_security_group_ids`; Terraform then adds one PostgreSQL (5432)
ingress rule per group to the database security group, by security-group
reference only (the variable refuses CIDRs and the workload group). The host
needs `psql` 16, AWS CLI v2 and `jq`.

**Credentials** come from the operator's own AWS identity (IAM Identity Center
session or a role assumed for the task), never from the cluster:

- the import credential `<env>/open-products-catalog-service/db-import` is not
  synced into Kubernetes (the chart's ExternalSecret maps only `db-app` and
  `db-migration`; keep it that way). The operator's permission set needs
  `secretsmanager:GetSecretValue` on that secret and `kms:Decrypt` on
  `alias/<env>-open-products-catalog-service-db`;
- the DBA bootstrap uses the RDS-managed admin secret (output
  `master_user_secret_arn`), fetched the same way by the DBA's principal.

Read the value into the environment of the one command that needs it, never
into a file, ticket or shell history:

```sh
export PGPASSWORD="$(aws secretsmanager get-secret-value \
  --secret-id <env>/open-products-catalog-service/db-import \
  --query SecretString --output text | jq -r .password)"
# ... run the step, then:
unset PGPASSWORD
```

**TLS**: connect with `sslmode=verify-full` against the Amazon RDS CA bundle,
the same `global-bundle.pem` that trust-manager publishes to the pods as
ConfigMap `rds-ca-bundle`. On the host, download it once from the public AWS
trust store:

```sh
mkdir -p "$HOME/rds-ca"
curl -fsS -o "$HOME/rds-ca/global-bundle.pem" https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

**Attribution**: CloudTrail records every `GetSecretValue` on `db-import`
(and on the admin secret) with the caller's IAM principal
(`userIdentity.arn`) and time. `import-products.sh` writes the same
principal, from `aws sts get-caller-identity`, into
`product_history.operator_arn` for every row it changes. To tie a change to a
fetch: take `operator_arn` and `changed_at` from the history row and find the
matching event:

```sh
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue \
  --start-time <changed_at minus 12 h> --end-time <changed_at> \
  --query 'Events[].CloudTrailEvent' --output text | jq -c 'select(.requestParameters.secretId | test("open-products-catalog-service/db-import")) | {time: .eventTime, who: .userIdentity.arn}'
```

The import role is still one shared password: the ARN in the history is
what the script read from STS, and someone who fetched the password could
connect without the script and type another ARN. The database refuses import
changes without an ARN, and CloudTrail shows who fetched the password; see
ADR-0001 (residual risk). Rotate the `db-import` password after each
production import window (step 2's `\password`, then `put-secret-value`).

### 2.2 Steps

1. Terraform creates the cluster and the three empty secrets (outputs
   `app_db_secret_name`, `migration_db_secret_name`, `import_db_secret_name`),
   with `operator_security_group_ids` set to the operator host's or CI agent's
   security group (section 2.1).
2. DBA bootstrap, once per environment, from the operator host (section 2.1),
   connected with the RDS-managed admin credential to
   `db_of_open_products_catalog_<env>`:
   `psql "host=<writer> dbname=db_of_open_products_catalog_<env> user=open_products_admin sslmode=verify-full sslrootcert=$HOME/rds-ca/global-bundle.pem"`.
   Generate each password straight into its secret
   (`aws secretsmanager get-random-password` piped into `put-secret-value`, never
   into a file or ticket). Aurora logs DDL (`log_statement=ddl`) and pgaudit
   logs role statements (`pgaudit.log=ddl,role`), so never write
   `PASSWORD '...'`: create the roles without one and set it with psql's
   `\password`, which sends only a salted SCRAM verifier (paste the value from
   the secret at the prompt). Do not try to switch logging off for the
   session: `log_statement` is a superuser setting that the RDS admin
   (`rds_superuser`) cannot change per session, and audit stays in the
   parameter group (platform, 2026-10-08). The verifier therefore reaches the
   PostgreSQL log group. That is accepted: the passwords are 32 random
   characters from `get-random-password`, so a salted SCRAM verifier cannot be
   reversed in practice, and read access to the log group is limited to this
   service's operator role (terraform-modules eb31670) and the security team's
   permission set. The same rule applies to every later rotation.

   ```sql
   CREATE ROLE open_products_catalog_owner  LOGIN;
   CREATE ROLE open_products_catalog_app    LOGIN;
   CREATE ROLE open_products_catalog_import LOGIN;
   \password open_products_catalog_owner
   \password open_products_catalog_app
   \password open_products_catalog_import
   REVOKE ALL ON DATABASE db_of_open_products_catalog_<env> FROM PUBLIC;
   GRANT CONNECT, CREATE    ON DATABASE db_of_open_products_catalog_<env> TO open_products_catalog_owner;
   GRANT CONNECT            ON DATABASE db_of_open_products_catalog_<env> TO open_products_catalog_app;
   GRANT CONNECT, TEMPORARY ON DATABASE db_of_open_products_catalog_<env> TO open_products_catalog_import;
   ```

   Run `CREATE EXTENSION IF NOT EXISTS pgaudit;` before the block above (the
   parameter group preloads the library; the instances need one reboot after
   the parameter group change). Then install the history guard, still as the
   admin: `psql "<same conninfo>" -f db/bootstrap/history-guard.sql`. It is
   installed disarmed; `SELECT fbx_history_guard.verify();` returns
   `DISARMED` until step 3.

   The roles must exist before the first deploy: migration V2 grants the
   runtime and import privileges only to roles that exist when it runs (it
   logs a NOTICE otherwise). If a role was created late, re-run the two grants
   from `V2__product_history_and_roles.sql` as the owner.
3. Deploy the chart with `externalSecret.remoteSecretName` (db-app),
   `externalSecret.migrationRemoteSecretName` (db-migration) and
   `config.DB_URL` from the Terraform output `jdbc_url`
   (`sslmode=verify-full`, `sslrootcert` on the mounted `rds-ca-bundle`; the
   chart refuses any other URL). The `migrate` init
   container runs Flyway as the owner and exits; the service then starts with
   the runtime role and Flyway disabled. Check:
   `SELECT grantee, privilege_type FROM information_schema.role_table_grants WHERE table_schema = 'sc_of_open_products_catalog' ORDER BY 1, 2;`
   Then the admin arms the history guard, from the operator host:
   `SELECT fbx_history_guard.arm('<change ticket>: first deploy');` must
   return `armed, intact`.
4. Import the catalogue the product owner signed off, from the operator host
   (section 2.1), as the import role, signed in to AWS as yourself. The script
   records your AWS caller identity in `product_history.operator_arn` (it
   refuses to run without one, or as the account root) and your operator id
   in `application_name`; with `PGPASSWORD` exported from `db-import` as in
   section 2.1:
   `IMPORT_OPERATOR=<your id> db/import/import-products.sh --full "host=<writer> dbname=db_of_open_products_catalog_<env> user=open_products_catalog_import sslmode=verify-full sslrootcert=$HOME/rds-ca/global-bundle.pem" products.csv`
   `--full` (the default) treats the file as the whole catalogue and withdraws
   `ACTIVE` products missing from it; use `--delta` only for a partial file.
   It prints `inserted / updated / unchanged / withdrawn`; a second run of the
   same file must print `inserted: 0, updated: 0` and `withdrawn: 0`. A bad
   row aborts the whole file; `effective_from`/`effective_to` must carry an
   offset (`Z` or `+04:00`). The script refuses any other role.
5. `OPEN_PRODUCTS_SEED_ENABLED` stays `false` outside dev and CI.

Rehearsal: `scripts/migration/verify-migration.sh` (CI job `deploy/data-migration-rehearsal`).

### 2.3 History guard: integrity check and break-glass

- **Integrity check**: `SELECT fbx_history_guard.verify();` (any role) must
  return `armed, intact`. Anything else (`DISARMED`, `CHANGED SINCE ARMED`,
  `EVENT TRIGGERS MISSING OR DISABLED`) is an incident. Run it after every
  release and before each catalogue import; the rehearsal checks it, plus
  `pg_trigger.tgenabled` and `md5(prosrc)` of the history functions. It is
  **not scheduled yet**: a scheduled check (a Kubernetes CronJob or an
  application metric with an alert) is a go-live item owned by the Open Data
  Squad (section 3).
- **Releases**: migrations that do not touch `product_history`, its three
  functions (`product_history_record`, `product_history_append_only`,
  `product_history_insert_guard`) or any trigger on `product` or
  `product_history` run with the guard armed. A migration that does
  is refused, the `migrate` init container fails and the rollout stops with
  the old pods serving (`maxUnavailable: 0`).
- **Break-glass** for such a migration, by the admin only, with a change
  ticket: `SELECT fbx_history_guard.disarm('<ticket>');` (logs a WARNING and
  fires the history-tamper alarm), deploy, check the history objects, then
  `SELECT fbx_history_guard.arm('<ticket>');` to record the new state. Both
  calls are kept in `fbx_history_guard.event` (who, when, why). The schema
  owner can neither disarm the guard nor alter its event triggers. An
  environment armed before V4 applies V4 this way and re-arms, because the
  guard's fingerprint now also covers the V4 trigger and function.
- **Log access**: the PostgreSQL log group (output
  `postgresql_log_group_arn`) holds pgaudit lines. Read access belongs to the
  security and DBA roles only. This stack owns no IAM policy that grants
  reads; the platform's permission sets must scope `logs:GetLogEvents`,
  `logs:FilterLogEvents` and `logs:StartQuery` on that ARN to those roles.

## 3. Go-live (one way)

There is no data to move and no dual run: the monolith only serves sample
rows from memory, so the service goes live in one step once the signed-off
catalogue is verified on staging. Rolling back means rolling back this
service, not returning traffic to the monolith.

**Depends on**

- Gateway route and rate limit for `GET /open-finance/v1/products`: mesh PR #11
  (`fintechbankx-platform-mesh-security-service-mesh`, commit `5e756f0`),
  merged and applied in the target environment.
- `ClusterSecretStore` `aws-secrets-manager` (platform External Secrets),
  able to read `<env>/open-products-catalog-service/db-app` and `db-migration`
  and decrypt with the service's tagged KMS key.
- ConfigMap `rds-ca-bundle` (key `global-bundle.pem`) in `open-finance`,
  published by the platform's trust-manager (mesh repo,
  `k8s/platform/cert-manager/bundle-rds-ca.yaml`); without it the pods do not
  start.
- The operator host or in-VPC CI agent, with its security group in
  `operator_security_group_ids` (section 2.1).
- The DBA bootstrap in section 2 (three roles) done before the first deploy.
- A scheduled history-guard integrity check (`fbx_history_guard.verify()` must
  return `armed, intact`), as a Kubernetes CronJob or an application metric
  with an alert. Owner: Open Data Squad. Not built yet.

**Steps**

| Step | Action | Done when |
|---|---|---|
| 1 | Staging: deploy the release, run the import with the product owner's signed-off CSV (section 2, step 4), import it a second time | second run prints `inserted: 0, updated: 0`; row count per status equals the CSV's (section 4) |
| 2 | Staging: verify (section 4) and compare with the monolith on **response shape and headers only**, not rows: same JSON structure (`Data.Product[]`, `Links.Self`, `Meta.TotalRecords`), `X-FAPI-Interaction-ID` echoed, `ETag` present, `If-None-Match` gives `304`, missing interaction id or invalid filter gives `400` | all checks pass; differences match the list below |
| 3 | Production: deploy the same image, run the same CSV import, verify as in step 2 | as step 2 |
| 4 | Switch the gateway route (mesh PR #11) to `open-products-catalog-service.open-finance.svc.cluster.local:8080` in one step | 100 % of the route on the service |
| 5 | Watch for 60 minutes against the rollback triggers below | no trigger fired |
| 6 | Monolith: remove the `productcatalog` controller in its next release | merged in enterprise-loan-management-system |

**Known differences from the monolith** (the response is not identical):

- Data: the imported catalogue, not the monolith's in-memory sample rows.
- `ETag`: hex SHA-256 over every published field; the monolith hashes the
  count, ids and `updatedAt` and encodes base64url. Clients' stored ETags do
  not match after the switch, so their first request is a `200`.
- `Cache-Control: no-cache` instead of `public, max-age=60`.
- Invalid `type`/`segment`: both return `400` for values outside
  `^[A-Za-z0-9_-]{2,30}$`; the error message text differs.
- `Authorization`: the monolith rejects a header that is not `Bearer`/`DPoP`
  with `400`; the service ignores it (public data, `security: []`).
- `429` with `Retry-After` and `x-fbx-rate-limited: true` comes from the gateway.

**Rollback triggers** (any one, measured at the gateway for this route over 5 minutes, or as stated):

| Trigger | Threshold |
|---|---|
| 5xx rate | above 1 % of requests |
| p95 latency | above 300 ms |
| Readiness | fewer than 2 ready pods for 2 minutes (`/actuator/health/readiness`) |
| Row count | `ACTIVE` rows in `product` differ from the signed-off CSV's `ACTIVE` rows |

**Rollback**

- Release problem (5xx, latency, readiness): `helm rollback open-products-catalog-service <previous revision> -n open-finance`.
  Migrations are additive, so the previous release runs on the current schema.
- Catalogue problem (row count, wrong values): re-import the previous signed-off
  CSV with `--full` (section 2, step 4), which also withdraws products the bad
  file added; every change is in `product_history`.
- Returning the route to the monolith is not a rollback: it serves sample data
  only. Use it only if the service cannot serve at all, and treat it as an incident.

## 4. Verification

- `./gradlew check` with `TEST_DB_URL` set: Flyway, Hibernate validation, seed,
  filtering, effective-window rules and ETag revalidation against PostgreSQL.
- `GET /actuator/health/readiness` on 8081 is `UP` (includes `db`).
- Product count per status after import:
  `SELECT status, count(*) FROM sc_of_open_products_catalog.product GROUP BY status;`

## 5. Acceptance checklist

- [x] Builds and tests standalone, including PostgreSQL integration tests (skipped locally without `TEST_DB_URL`; they fail in CI and Jenkins without it)
- [x] Own schema and migrations; Hibernate validates the entity at startup
- [x] Idempotent catalogue import rehearsed in CI
- [x] Container image, Helm chart, Terraform checked in the Deployability workflow
- [ ] Real catalogue CSV signed off by the product owner
- [ ] Scheduled history-guard integrity check (CronJob or app metric, alerting; owner: Open Data Squad)
- [ ] Gateway route switched (platform)
- [ ] Monolith `productcatalog` controller removed (enterprise-loan-management-system)
