# ADR-0001: The service's PostgreSQL database is the authority for the published product offer

- Status: Proposed (owning squad: Open Data Squad)
- Date: 2026-10-08 (round-5 review fixes 2026-10-10)
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
   `V3__history_operator_identity.sql`, `V4__history_insert_guard_and_deletes.sql`);
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
- What protects `product_history`, stated as what the rehearsal
  (`scripts/migration/verify-migration.sh`, PostgreSQL 16, CI job
  `deploy/data-migration-rehearsal`) tests:
  - The runtime and import roles have no privilege on `product_history`;
    `UPDATE`, `DELETE` and `TRUNCATE` of it are rejected by triggers, also
    for the schema owner.
  - Only the NOLOGIN history writer (`open_products_catalog_history_writer`)
    may insert into `product_history`. The bootstrap creates it as the
    admin, and `arm()` gives it `product_history_record()` (SECURITY DEFINER)
    and the only INSERT on the history. The schema owner then holds no INSERT
    (column grants included) and no EXECUTE on the function, so it cannot
    replace the function, take it back, attach it to another table or become
    the writer. V4's insert guard refuses any insert that does not come from a
    trigger (`pg_trigger_depth()`). V5 adds a check of the inserting role: it
    must be the owner of `product_history_record()`. A trigger on any other
    table, a superuser's included, is refused. Before `arm()` the owner of
    the function is the schema owner (local, CI, first deploy).
  - Nobody can act as the writer. On a non-superuser admin (Aurora
    `rds_superuser`), `arm()` needs INHERIT and SET membership in the owner
    and the writer for the transfer. It grants them to itself and revokes
    them before it returns, keeping only the ADMIN OPTION the admin holds as
    the roles' creator. `arm()` refuses while any role is an INHERIT or SET
    member of the writer. ADMIN OPTION still lets the admin grant itself the
    writer again: that is not prevented, but it changes the writer's
    members, so `verify()` answers `CHANGED SINCE ARMED` (rehearsal step 14,
    with a non-superuser CREATEROLE admin standing in for `rds_superuser`).
    Until round 5 the membership stayed in place, a forge path that was
    neither prevented nor alarmed. The rehearsal also showed that the
    guard's `to_regclass()` lookups needed USAGE on the service schema,
    which a non-superuser admin lacks. The guard now looks its objects up in
    the catalogs.
  - TRUNCATE of `product` is refused for every role, the admin included
    (V5): it fires no row trigger and would remove products without history.
    Deleting a product writes a `DELETE` row with the old values (V4); the
    rehearsal clears rows with `DELETE` and checks each removal is recorded.
  - All six history triggers fire ALWAYS (V5), also under
    `session_replication_role = replica`, which a superuser or
    `rds_superuser` can set without DDL. TRUNCATE, history inserts and
    guard-state rewrites are refused in replica mode on PostgreSQL 16. On
    Aurora 16 this is *to be verified in the terraform-modules Aurora 16
    drill*.
  - The schema owner's DDL and grants on the history are **prevented** while
    the history guard (`db/bootstrap/history-guard.sql`, admin-owned event
    triggers installed by the DBA bootstrap, not by Flyway) is armed. The
    guard refuses any DDL that targets or drops a protected object, or that
    leaves a different fingerprint from the one recorded at arming. The
    fingerprint covers:
    - table and column privileges (`relacl`, `pg_attribute.attacl`) of
      `product` and `product_history`;
    - owner, ACL, SECURITY DEFINER, `search_path` and body of every function
      a protected trigger calls;
    - the history triggers and their enabled state, the history columns and
      rules;
    - the writer's attributes and members, and `rds_pgaudit` membership
      (GRANT ROLE fires no event trigger, so `verify()` reports it);
    - inheritance and partitioning of both tables: the `pg_inherits` rows
      with either table as parent or child, `relhassubclass` and
      `relispartition`.

    Until round 5 the guard did not look at inheritance. A child table's rows
    are read through its parent, but the parent's row triggers do not fire
    for them. So `CREATE TABLE ... INHERITS (product_history)` let the owner
    forge rows that are read through the history, and `INHERITS (product)`
    added products that the runtime role read with no history row, both with
    `verify()` answering `armed, intact` (review 5, comment 4237449949).
    While armed, the event trigger now refuses any DDL that leaves a
    `pg_inherits` row with either table as parent or child. That covers
    `CREATE TABLE ... INHERITS`, `ALTER TABLE ... INHERIT` and `ATTACH
    PARTITION` in either direction. `arm()` refuses while such a row exists,
    or while `relhassubclass` is still set from a dropped child. As a second
    layer, the service reads `ONLY product`, so a child's rows are never
    served even with the guard disarmed.

    Thirty-eight statements run as the owner are refused by the guard, and
    twelve more fail on privileges. They include the review's probes
    (replacing `product_history_append_only` to `RETURN OLD`, `DISABLE
    TRIGGER` built by concatenation inside `DO`/`EXECUTE`, spacing and case
    variants, and since round 5 a child of `product_history` with a forged
    row and a child of `product` the runtime role could read), disabling,
    dropping or replacing any history trigger or function, the TRUNCATE
    refusal included, turning an ALWAYS trigger back into an origin-only one,
    dropping or renaming the table or a column, a rule, a new trigger on
    `product` or the history, table- or column-level GRANTs or REVOKEs on
    either table, `ALTER TABLE ... INHERIT` on either table, and attaching
    either table as a partition. Afterwards no `pg_inherits` row involves
    either table, the six history triggers fire ALWAYS (`tgenabled` `A`)
    with unchanged function bodies, and `fbx_history_guard.verify()` returns
    `armed, intact`. Other owner DDL still runs. These are the statements
    the rehearsal tries; the guard is a fingerprint of named catalog state,
    not a proof that no other DDL can reach the history.
  - The guard state is append-only: `fbx_history_guard.armed` (one row per
    arm or disarm) and `fbx_history_guard.event` refuse UPDATE, DELETE and
    TRUNCATE for the admin too, also in replica mode. Only `arm()`,
    `disarm()` and `hand_back_history_writer()` may append. The owner cannot
    disarm the guard or alter its event triggers. `arm()` refuses while
    armed, and so does the bootstrap. Disarming and hand-back log a WARNING.
    The round-2 one-row state table is kept as `armed_v1`.
  - The scheduled `verify()` is a release blocker: any answer other than
    `armed, intact` pages, blocks promotion to that environment and opens
    an incident (runbook section 2.3). Since round 5 the chart runs it: the
    service image in a check mode (`OPEN_PRODUCTS_HISTORY_GUARD_CHECK`) runs
    `verify()` as the runtime role and exits non-zero unless the answer is
    `armed, intact`. A CronJob runs it every 15 minutes, and a pre-upgrade
    hook Job runs it before every upgrade, so `helm upgrade` fails and
    applies nothing. A break-glass release names its change ticket
    (`historyGuardCheck.breakGlassTicket`), which skips only that gate. The
    integration test proves the check fails against the real guard when it
    is disarmed or changed. It has not run in a cluster yet, because nothing
    is deployed. Paging on a failed CronJob relies on the platform's
    job-failure alert for the namespace.
- Configured but not exercised by a test (plan-only Terraform tests check
  the configuration): pgaudit (`pgaudit.log=ddl,role`) and the
  `history-tamper` alarm. Its filter (a) ORs guard messages, the
  schema-qualified history name, rejected history changes and inserts,
  `fbx_history_guard`, `EVENT TRIGGER` and `AUDIT: OBJECT`. Filters (b) and
  (c) match pgaudit session DDL that names `product_history` or
  `fbx_history_guard`. Arm, disarm and Flyway releases that touch the
  history page by design. terraform-modules #11 creates only the
  `rds_pgaudit` role, so the guard issues the object-audit grants itself:
  INSERT, UPDATE and DELETE on its state tables, and UPDATE and DELETE on
  `product_history`. Whether these produce `AUDIT: OBJECT` lines on Aurora
  16 is *to be verified in the terraform-modules Aurora 16 drill*.
- Not covered:
  - The admin (`rds_superuser`) can disarm the guard (break-glass, recorded
    and alarmed). It can also drop or disable the guard's event triggers.
    That is logged and alarmed via the `EVENT TRIGGER` term, and `verify()`
    reports it, but it is not prevented.
  - The schema owner can still change `product` directly (every change is
    recorded with its role) and read the history.
  - Between the first deploy and `arm()`, the schema owner still holds the
    recording function and INSERT. The runbook keeps that window short.
  - The owner credential lives only in the `migrate` init container.
  - Some Aurora behaviour is documented by AWS or platform but has not been
    run here: creating event triggers as `rds_superuser`, and its
    `GRANT ... WITH INHERIT TRUE, SET TRUE` on the owner and writer roles.
    The latter works only for roles it holds ADMIN OPTION on, so the admin
    creates all of them. The rehearsal runs `arm()` and hand-back as a
    non-superuser CREATEROLE role on PostgreSQL 16, with the event triggers
    still superuser-owned. That role ends with ADMIN OPTION only, and SET
    ROLE to the writer is refused. All of this is *to be verified in the
    terraform-modules Aurora 16 drill*, together with the membership
    revoke at the end of `arm()`.
- Import attribution: `import-products.sh` takes the operator's identity from
  `aws sts get-caller-identity` (the same credentials that fetched the
  `db-import` secret) and the database rejects import-role changes without
  one. CloudTrail logs every `GetSecretValue` on `db-import` with the IAM
  principal and time, so a history row can be matched with the fetch
  (runbook section 2.1).
- Three database roles: the schema owner runs Flyway only (in the pod's
  migrate init container), the runtime role can only `SELECT` from `product`,
  and the import role can `SELECT`, `INSERT` and `UPDATE` it.
- Database TLS: the chart refuses a JDBC URL that does not verify Aurora's
  certificate. Every container it renders runs under the `aws` profile, and
  under that profile the service refuses to start unless the URL has exactly
  one `sslmode=verify-full` and the platform RDS CA bundle as `sslrootcert`
  (no other `ssl*` parameter, no `service`). Tests and local runs have no
  profile and are not checked. The chart also refuses any Spring config
  location (`spring.config.import`, `.location`, `.additional-location`, in
  any relaxed-binding spelling, or `SPRING_APPLICATION_JSON`) in `config`
  and any `extraEnv`. It renders no configtree. Values cannot change the
  `aws` profile either (round 6): `SPRING_PROFILES_*` in any relaxed-binding
  spelling, and `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS` or `JAVA_OPTS`
  mentioning `spring.profiles`, are refused in `config` and `extraEnv`.
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

### Risk acceptance (Proposed, awaiting sign-off)

| Field | Value |
|---|---|
| Risk | Catalogue changes made with the shared import password can carry a self-declared `operator_arn`; the database cannot prove which operator connected. |
| Likelihood / impact | Low / medium: needs an operator with access to the secret acting outside the script; the change itself is still recorded, attributed to the import role and bounded to `SELECT`, `INSERT`, `UPDATE` on `product`. |
| Controls in place | STS caller identity required by the script and by the history trigger (V3); CloudTrail `GetSecretValue` per principal; no public network path; import role cannot delete or touch the history. |
| Interim rule | The `db-import` password is rotated after every production import window (runbook section 2.1). The platform has accepted rotation as the interim rule. |
| Target | Per-operator database logins with IAM database authentication: per-operator `rds-db:connect` granted through the platform's operator role and operator-access module (platform has confirmed it provides both); the shared password is then retired. |
| Accepted by | Security: _pending_. Product owner (Open Data Squad): _pending_. |
| Review | At the latest when the operator-access module is released, or six months after acceptance. |

Not chosen for now: per-operator database logins with IAM database
authentication (the cluster already has `iam_database_authentication_enabled`).
That would make `session_user` the operator and remove the shared password,
but needs one database role per operator and per-operator `rds-db:connect`
grants in the operators' IAM permission sets, which this repository does not
own. Revisit when the platform's operator access model provides them; the
import script would then `SET ROLE open_products_catalog_import` and the
history's `login_role` already records the login.

## Reversibility

- Reversible: caching policy (header values), seed contents, import format,
  the history guard check (a chart template and one check mode in the
  service; a single release can skip the gate with a break-glass ticket).
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
