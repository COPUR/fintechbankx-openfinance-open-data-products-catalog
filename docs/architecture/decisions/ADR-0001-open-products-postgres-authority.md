# ADR-0001: PostgreSQL is the authority for the open products catalogue

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

1. PostgreSQL (`db_of_open_products_catalog_<env>`, schema
   `sc_of_open_products_catalog`, table `product`) is the authority for the
   catalogue. Flyway owns the schema (`V1__create_product_catalogue.sql`); the
   service reads it through `JpaProductCatalogAdapter`, which implements the
   domain out-port `ProductCatalogPort`. Hibernate validates the mapping at startup.
2. The catalogue is loaded by an operator job: `db/import/import-products.sh`
   upserts a CSV in one transaction (new rows inserted, changed rows updated
   with `version + 1`, unchanged rows left alone). The four former in-memory
   rows are dev/CI sample data in `classpath:db/seed`, applied only when
   `OPEN_PRODUCTS_SEED_ENABLED=true`.
3. The service has no write use case, so it raises no domain events. **No
   transactional outbox** and **no `evt.of.products.*` topics** for now. When a
   write or import use case exists in the service, add the outbox (shared brief,
   item 9) and publish compacted fact topics such as `evt.of.products.published.v1`
   keyed by product id, then write the AsyncAPI spec.
4. Caching: a strong `ETag` over the product content with `If-None-Match` ->
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
- Products are withdrawn by status (`WITHDRAWN`) or `effective_to`, never deleted,
  which keeps an audit trail and lets the import stay idempotent.
- The service's database load is at most one indexed query per pod per
  snapshot interval; Aurora Serverless v2 can run at a low minimum capacity.
- Request-rate limiting (`429` with `Retry-After`) is the API gateway's job and
  is a dependency on the service-mesh repository, not on this service.
- Until the outbox exists, other services cannot subscribe to catalogue changes;
  they call the API (and can use the ETag).

## Reversibility

- Reversible: caching policy (header values), seed contents, import format.
- Costly to reverse once production data exists: the table shape. Change it
  with additive Flyway migrations only.
- Not chosen: Redis cache (revisit if p95 latency at the gateway misses its SLO
  with HTTP caching); event-carried state from a product master system
  (revisit when such a system is named).
