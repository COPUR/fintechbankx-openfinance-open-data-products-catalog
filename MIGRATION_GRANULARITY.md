# Migration Granularity Notes

- Repository: `fintechbankx-openfinance-open-products-catalog-service`
- Source monorepo: `enterprise-loan-management-system`
- Sync date: `2026-03-15`
- Sync branch: `chore/granular-source-sync-20260313`

## Applied Rules

- dir: `services/openfinance-open-products-service` -> `.`
- file: `api/openapi/open-products-service.yaml` -> `api/openapi/open-products-service.yaml`
- dir: `infra/terraform/services/open-products-service` -> `infra/terraform/open-products-service`
- file: `docs/architecture/open-finance/capabilities/hld/open-finance-capability-overview.md` -> `docs/hld/open-finance-capability-overview.md`
- file: `docs/architecture/open-finance/capabilities/test-suites/open-data-test-suite.md` -> `docs/test-suites/open-data-test-suite.md`

## Notes

- This is an extraction seed for bounded-context split migration.
- Follow-up refactoring may be needed to remove residual cross-context coupling.
- Build artifacts and local machine files are excluded by policy.
- 2026-10-08: seed turned into a deployable service. The service owns `sc_of_open_products_catalog` (PostgreSQL authority, ADR-0001) with its own Flyway migrations; the monolith has no product tables, so there is no backfill and the catalogue is loaded with `db/import/import-products.sh` (see `docs/migration/RUNBOOK-EXTRACT-of-open-products-catalog.md`). Old `infrastructure/` and `infra/terraform/` bootstrap paths replaced by `Dockerfile` and `deploy/`.
