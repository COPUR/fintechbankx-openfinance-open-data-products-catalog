# RUNBOOK-EXTRACT-of-open-products-catalog

Extraction of the product catalogue from `enterprise-loan-management-system`
(`open-finance-context/.../productcatalog`) into `svc-of-open-products-catalog`
(this repository).

| Field | Value |
|---|---|
| Context / service | `of` / `svc-of-open-products-catalog` (slug `open-products-catalog-service`) |
| Slice | Public product catalogue read model: `GET /open-finance/v1/products` |
| Owned data | `db_of_open_products_catalog_<env>`, schema `sc_of_open_products_catalog`: `product` |
| Events | none yet (ADR-0001); future namespace `evt.of.products.*` |
| Depends on | nothing at runtime besides its database (public endpoint) |

## 1. Data ownership split

| Monolith object | Owner after the split | Notes |
|---|---|---|
| `productcatalog` in-memory catalogue (5 sample rows) | not migrated | sample data; this service has its own dev seed |
| `productcatalog` in-memory TTL cache | dropped | replaced by HTTP caching (ETag, Cache-Control) |
| Product SQL tables | none exist | no monolith migration creates one, so there is nothing to backfill |
| `sc_of_open_products_catalog.product` | this service | Flyway `V1__create_product_catalogue.sql` |

The service never reads monolith tables; nothing else reads `sc_of_open_products_catalog`.

## 2. Loading the catalogue

1. Terraform creates the cluster and the empty `<env>/open-products-catalog-service/db-app` secret.
2. DBA bootstrap with the RDS-managed admin credential:
   `CREATE ROLE open_products_catalog_app LOGIN PASSWORD '<generated>'; GRANT CREATE ON DATABASE db_of_open_products_catalog_<env> TO open_products_catalog_app;`
   then write `{"username","password"}` to the secret (never to a file or ticket).
3. Deploy the chart; Flyway creates the schema and table at startup.
4. Import the catalogue the product owner signed off:
   `PGPASSWORD=... db/import/import-products.sh "host=<writer> dbname=db_of_open_products_catalog_<env> user=open_products_catalog_app sslmode=require" products.csv`
   It prints `inserted / updated / unchanged`; a second run of the same file
   must print `inserted: 0, updated: 0`. A bad row aborts the whole file.
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
