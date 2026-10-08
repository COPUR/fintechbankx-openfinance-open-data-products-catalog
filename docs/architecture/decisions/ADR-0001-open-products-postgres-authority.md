# ADR-0001: The service's PostgreSQL database is the authority for the published product offer

- Status: Proposed (owning squad: Open Data Squad)
- Date: 2026-10-08
- Service: `svc-of-open-products-catalog`

## Context

`GET /open-finance/v1/products` served four hard-coded products from
`InMemoryProductCatalogAdapter`. A deployable, horizontally scaled service needs
one shared, durable source for the catalogue that every replica reads.

What exists in the monolith (`enterprise-loan-management-system`, master, Aug 2026):

- `services/openfinance-open-products-service` is a launcher shell (an empty
  `Application` class and a test); it has no catalogue code.
- `open-finance-context/.../productcatalog` holds the newer catalogue code: an
  in-memory catalogue of five sample products, an in-memory TTL cache port,
  `Cache-Control: public, max-age=60`, upper-cased filters, ordering by product id.
- No SQL migration in the monolith creates a product table. The open-finance
  migrations (`open-finance-infrastructure/src/main/resources/db/migration/openfinance/V1__create_outbox.sql`,
  `V2__create_payment_eventing_support.sql`) cover the outbox and payments only.

So there is **no monolith catalogue data to backfill**.

## Decision

1. `svc-of-open-products-catalog` is the authority for the **published
   offer**: what `GET /open-finance/v1/products` returns, and when. It is not
   the product master. Its named upstream is the catalogue file the **product
   owner signs off**; that file is the only input, loaded by the import below.
   The published offer lives in PostgreSQL (`db_of_open_products_catalog_<env>`,
   schema `sc_of_open_products_catalog`, table `product`). Flyway owns the
   schema (`V1__create_product_catalogue.sql`, `V2__product_history_and_roles.sql`,
   `V3__history_operator_identity.sql`);
   the service reads it through `JpaProductCatalogAdapter`, which implements
   the domain out-port `ProductCatalogPort`. Hibernate validates the mapping at startup.
2. Store class: **system of record** for the published offer (not a cache or
   a projection that can be rebuilt from elsewhere: the signed-off files are
   the input, the database is what was published). Recovery evidence is in
   `deploy/terraform/main.tf` (`aws_rds_cluster.database`): automated backups
   with point-in-time recovery for `backup_retention_days` (default 35, 7 to 35
   enforced in `variables.tf`), `deletion_protection`, a final snapshot,
   KMS-encrypted storage, and in prod a reader in a second AZ. Restores have
   not been rehearsed yet (see open questions).
3. The catalogue is loaded by an operator job: `db/import/import-products.sh`
   upserts a CSV in one transaction (new rows inserted, changed rows updated
   with `version + 1`, unchanged rows left alone). By default (`--full`) the
   file is the whole signed-off catalogue and `ACTIVE` products missing from it
   are withdrawn; `--delta` loads a partial file. Effective dates must carry a
   UTC offset. The four former in-memory
   rows are dev/CI sample data in `classpath:db/seed`, applied only when
   `OPEN_PRODUCTS_SEED_ENABLED=true`. The seed is insert-only and uses
   `SAMPLE-` ids, which the import refuses, so it can never change imported data.
4. The service has no write use case, so it raises no domain events. **No
   transactional outbox** and **no `evt.of.products.*` topics** for now. When a
   write or import use case exists in the service, add the outbox (shared brief,
   item 9) and publish compacted fact topics such as `evt.of.products.published.v1`
   keyed by product id, then write the AsyncAPI spec.
5. Caching: a strong `ETag` over the product content with `If-None-Match` ->
   `304`, and `Cache-Control: no-cache`, because every response echoes the
   caller's `X-FAPI-Interaction-ID` and must not be reused by a shared cache
   without revalidation. `Links.Self` is a relative path built from the filters.
   Inside each pod, `SnapshotProductCatalog` holds the offerable catalogue in
   memory and reloads it at most once per `OPEN_PRODUCTS_SNAPSHOT_REFRESH`
   (default 10 s), so request rate and filter values do not drive database
   load and a revalidation costs no database round trip. Filters are validated
   (`^[A-Z0-9_-]{2,30}$` once upper-cased, else `400`) before the catalogue is
   read. No Redis: the data is small and changes rarely. The monolith's TTL
   cache port is not ported.

## Consequences

- Every replica serves the same catalogue; a catalogue change is visible within
  one snapshot interval (10 s by default) without redeploying.
- Products are withdrawn by status (`WITHDRAWN`) or `effective_to`, never
  deleted (the import role has no `DELETE`), which lets the import stay
  idempotent. The audit trail is `product_history` (V2): an `AFTER INSERT OR
  UPDATE` trigger writes the old and new row, the role, `application_name`
  (the import sets it to `import-products/<operator>`), the time and, since
  V3, `operator_arn`, the importing operator's AWS caller identity.
- The history is **tamper-evident against the runtime and import roles
  only**: neither has any privilege on `product_history`, and its triggers
  reject `UPDATE`, `DELETE` and `TRUNCATE`. The **schema owner** is not
  stopped: it owns the table and can disable or drop those triggers, or
  replace the history function. That is **detected, not prevented**: Aurora
  logs every DDL statement (`log_statement=ddl` in the cluster parameter
  group, `deploy/terraform/main.tf`), the PostgreSQL log is exported to
  CloudWatch, and the `history-tamper` metric filter and alarm fire on a
  disabled or dropped trigger, a replaced `product_history_record` or a
  rejected history change. The filter is case-sensitive (upper- and
  lower-case DDL only); `pgaudit` with object auditing on `product_history`
  would close that gap and is the next step if the owner credential's
  exposure grows. The owner credential lives only in the `migrate` init
  container.
- Import attribution: `import-products.sh` takes the operator's identity from
  `aws sts get-caller-identity` (the same credentials that fetched the
  `db-import` secret) and the database rejects import-role changes without
  one. CloudTrail logs every `GetSecretValue` on `db-import` with the IAM
  principal and time, so a history row can be matched with the fetch
  (runbook section 2.1).
- Three database roles: the schema owner runs Flyway only (in the pod's
  migrate init container), the runtime role can only `SELECT` from `product`,
  and the import role can `SELECT`, `INSERT` and `UPDATE` it.
- The service's database load is at most one indexed query per pod per
  snapshot interval; Aurora Serverless v2 can run at a low minimum capacity.
- Request-rate limiting is the API gateway's job (mesh PR #11, `5e756f0`:
  100-token bucket refilled at 50/s per gateway pod, `429` with `Retry-After`
  and `x-fbx-rate-limited: true`), a dependency on the service-mesh repository.
- Until the outbox exists, other services cannot subscribe to catalogue changes;
  they call the API (and can use the ETag).

## Residual risk: one shared import credential

The import role `open_products_catalog_import` has one password in
`<env>/open-products-catalog-service/db-import`, which every operator
fetches. `operator_arn` in the history is what the script read from STS;
anyone who fetched the password can connect with plain `psql` and set any
ARN-shaped value. What bounds this:

- only principals with `GetSecretValue` on the secret and `kms:Decrypt` on
  the database key can obtain it, and CloudTrail names each of them;
- the import role cannot delete products, touch the history or change the
  schema, and every change it makes is in the history;
- the database is reachable only from the workload and the operator hosts in
  `operator_security_group_ids` (no public path);
- the password is rotated after each production import window (runbook).

Not chosen for now: per-operator database logins with IAM database
authentication (the cluster already has `iam_database_authentication_enabled`).
That would make `session_user` the operator and remove the shared password,
but needs one database role per operator and per-operator `rds-db:connect`
grants in the operators' IAM permission sets, which this repository does not
own. Revisit when the platform's operator access model provides them; the
import script would then `SET ROLE open_products_catalog_import` and the
history's `login_role` already records the login.

## Reversibility

- Reversible: caching policy (header values), seed contents, import format.
- Costly to reverse once production data exists: the table shape. Change it
  with additive Flyway migrations only.
- Not chosen: Redis cache (revisit if p95 latency at the gateway misses its SLO
  with HTTP caching).
- Not chosen: event-carried state from a product master. This is the exit
  path: when a product master is named, the service subscribes to its product
  events and the import (and the signed-off file) is retired; the table and
  the API stay as they are.

## Open questions

- For the Architecture Board: where does the product master live (which
  system owns product definitions, pricing and eligibility before they are
  published)? Until it is named, the product owner's signed-off file is the
  upstream and this service only holds what was published.
- For the owning squad: schedule a point-in-time restore rehearsal of the
  Aurora cluster and record its result as recovery evidence.
- For the platform: who provides the in-VPC operator host or CI agent per
  environment, and can operator permission sets carry per-operator
  `rds-db:connect` (to replace the shared import password)?
