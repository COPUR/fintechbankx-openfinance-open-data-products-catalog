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
| Depends on | its database; the gateway rate limit for `GET /open-finance/v1/products` (mesh PR #11, commit `5e756f0`: 100-token bucket refilled at 50/s per gateway pod, `429` with `Retry-After` and `x-fbx-rate-limited: true`), owned by `fintechbankx-platform-mesh-security-service-mesh` |

## 1. Data ownership split

| Monolith object | Owner after the split | Notes |
|---|---|---|
| `productcatalog` in-memory catalogue (5 sample rows) | not migrated | sample data; this service has its own dev seed |
| `productcatalog` in-memory TTL cache | dropped | replaced by HTTP caching (ETag, Cache-Control) |
| Product SQL tables | none exist | no monolith migration creates one, so there is nothing to backfill |
| `sc_of_open_products_catalog.product` | this service | Flyway `V1__create_product_catalogue.sql` |
| `sc_of_open_products_catalog.product_history` | this service | Flyway `V2__product_history_and_roles.sql` (append-only audit trail) |

The service never reads monolith tables; nothing else reads `sc_of_open_products_catalog`.

## 2. Loading the catalogue

The database has three login roles, each with its own Secrets Manager secret
(KMS key `alias/<env>-open-products-catalog-service-db`):

| Role | Secret | Used by | May |
|---|---|---|---|
| `open_products_catalog_owner` | `<env>/open-products-catalog-service/db-migrate` | Flyway, in the pod's `migrate` init container only | own the schema, run migrations |
| `open_products_catalog_app` | `<env>/open-products-catalog-service/db-app` | the serving container | `SELECT` on `product` (nothing on `product_history`) |
| `open_products_catalog_import` | `<env>/open-products-catalog-service/db-import` | operators running `import-products.sh` | `SELECT`, `INSERT`, `UPDATE` on `product`; no `DELETE` or `TRUNCATE` |

Every insert or update of `product` writes an append-only row to
`product_history` (old and new values, role, `application_name`, time; V2
migration). No role can update or delete history rows.

1. Terraform creates the cluster and the three empty secrets (outputs
   `app_db_secret_name`, `migrate_db_secret_name`, `import_db_secret_name`).
2. DBA bootstrap, once per environment, connected with the RDS-managed admin
   credential (output `master_user_secret_arn`) to `db_of_open_products_catalog_<env>`.
   Generate each password into the secret directly (never into a file or ticket):

   ```sql
   CREATE ROLE open_products_catalog_owner  LOGIN PASSWORD '<generated>';
   CREATE ROLE open_products_catalog_app    LOGIN PASSWORD '<generated>';
   CREATE ROLE open_products_catalog_import LOGIN PASSWORD '<generated>';
   REVOKE ALL ON DATABASE db_of_open_products_catalog_<env> FROM PUBLIC;
   GRANT CONNECT, CREATE    ON DATABASE db_of_open_products_catalog_<env> TO open_products_catalog_owner;
   GRANT CONNECT            ON DATABASE db_of_open_products_catalog_<env> TO open_products_catalog_app;
   GRANT CONNECT, TEMPORARY ON DATABASE db_of_open_products_catalog_<env> TO open_products_catalog_import;
   ```

   The roles must exist before the first deploy: migration V2 grants the
   runtime and import privileges only to roles that exist when it runs (it
   logs a NOTICE otherwise). If a role was created late, re-run the two grants
   from `V2__product_history_and_roles.sql` as the owner.
3. Deploy the chart with `externalSecret.remoteSecretName` (db-app) and
   `externalSecret.migrateRemoteSecretName` (db-migrate). The `migrate` init
   container runs Flyway as the owner and exits; the service then starts with
   the runtime role and Flyway disabled. Check:
   `SELECT grantee, privilege_type FROM information_schema.role_table_grants WHERE table_schema = 'sc_of_open_products_catalog' ORDER BY 1, 2;`
4. Import the catalogue the product owner signed off, as the import role and
   with your operator id (it becomes `product_history.application_name`):
   `IMPORT_OPERATOR=<your id> PGPASSWORD=... db/import/import-products.sh "host=<writer> dbname=db_of_open_products_catalog_<env> user=open_products_catalog_import sslmode=require" products.csv`
   It prints `inserted / updated / unchanged`; a second run of the same file
   must print `inserted: 0, updated: 0`. A bad row aborts the whole file. The
   script refuses any other role.
5. `OPEN_PRODUCTS_SEED_ENABLED` stays `false` outside dev and CI.

Rehearsal: `scripts/migration/verify-migration.sh` (CI job `deploy/data-migration-rehearsal`).

## 3. Cutover plan

| Step | Action | Rollback |
|---|---|---|
| 1 | Deploy the service, import the catalogue, compare `GET /open-finance/v1/products` with the monolith response for each type/segment | uninstall the release; drop the schema |
| 2 | Gateway: route `GET /open-finance/v1/products` to `open-products-catalog-service.open-finance.svc.cluster.local:8080` with a weighted route (10 % then 100 %) | set the weight back to the monolith |
| 3 | Monolith: remove the `productcatalog` controller after one release cycle at 100 % | redeploy the previous monolith release |

Response shape, headers and ETag semantics are unchanged; the new
`Cache-Control` header is additive.

## 4. Verification

- `./gradlew check` with `TEST_DB_URL` set: Flyway, Hibernate validation, seed,
  filtering, effective-window rules and ETag revalidation against PostgreSQL.
- `GET /actuator/health/readiness` on 8081 is `UP` (includes `db`).
- Product count per status after import:
  `SELECT status, count(*) FROM sc_of_open_products_catalog.product GROUP BY status;`

## 5. Acceptance checklist

- [x] Builds and tests standalone, including PostgreSQL integration tests (skipped without `TEST_DB_URL`)
- [x] Own schema and migrations; Hibernate validates the entity at startup
- [x] Idempotent catalogue import rehearsed in CI
- [x] Container image, Helm chart, Terraform checked in the Deployability workflow
- [ ] Real catalogue CSV signed off by the product owner
- [ ] Gateway route switched (platform)
- [ ] Monolith `productcatalog` controller removed (enterprise-loan-management-system)
