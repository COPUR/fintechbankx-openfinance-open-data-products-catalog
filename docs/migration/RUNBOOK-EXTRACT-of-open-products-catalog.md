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
| `sc_of_open_products_catalog.product_history` | this service | Flyway `V2__product_history_and_roles.sql` (append-only audit trail), `V3` (operator identity), `V4` (written only by its trigger; product deletes recorded), `V5` (TRUNCATE of `product` refused; only the history writer inserts) |

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
triggers that, once armed, refuse any DDL on the history table, its
functions or the triggers on either table. They also refuse any table that
inherits from `product` or `product_history`, or takes either as a
partition. A child's rows are read through its parent without its triggers
firing, so a child would carry forged history or products without history.
The service also reads `ONLY product`. Refusals, disarming and any DDL that
reaches those objects (pgaudit) raise the
`<env>-open-products-catalog-service-history-tamper` alarm (ADR-0001, section
2.3).

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
   `DISARMED` until step 3. The bootstrap also creates the history writer,
   `open_products_catalog_history_writer` (NOLOGIN), as the admin. It only
   creates the role: `arm()` (step 3) moves `product_history_record()` and
   INSERT on `product_history` from the schema owner to it.

   The admin creates every one of these roles itself (the block above and the
   bootstrap), in the same session. On Aurora, `rds_superuser` can
   `GRANT r TO x WITH INHERIT TRUE, SET TRUE` only for roles it holds ADMIN
   OPTION on, which means roles it created or holds `WITH ADMIN`. `arm()`
   needs exactly that for the owner and the writer. It grants the two
   memberships to the admin only for the transfer and revokes them before it
   returns, so the admin keeps ADMIN OPTION only and cannot `SET ROLE` to
   the writer. `arm()` refuses while any role can act as the writer. Do not
   create the roles with another login, and do not assume the admin can grant
   a role it does not administer (platform, round 3). The rehearsal runs this
   path as a non-superuser CREATEROLE role on PostgreSQL 16; on Aurora it is
   *to be verified in the terraform-modules Aurora 16 drill*.

   Object audit: terraform-modules #11 creates only the `rds_pgaudit` role and
   sets `pgaudit.role`. It grants nothing on any table. The guard issues the
   object-audit grants itself: the bootstrap grants INSERT, UPDATE and DELETE
   on `fbx_history_guard.armed` and `.event`, so every arm, disarm and
   hand-back logs an `AUDIT: OBJECT` line, and `arm()` grants UPDATE and
   DELETE on `product_history`, so attempted rewrites are logged. It grants no
   INSERT on the history (every product change writes one, and V5's insert
   guard already refuses every inserter but the writer) and no SELECT
   (the scheduled `verify()` and every read would log). Whether these grants
   produce `AUDIT: OBJECT` lines on Aurora 16 is *to be verified in the
   terraform-modules Aurora 16 drill*.

   The roles must exist before the first deploy: migration V2 grants the
   runtime and import privileges only to roles that exist when it runs (it
   logs a NOTICE otherwise). If a role was created late, re-run the two grants
   from `V2__product_history_and_roles.sql` as the owner.
3. Deploy the chart with `externalSecret.remoteSecretName` (db-app),
   `externalSecret.migrationRemoteSecretName` (db-migration) and
   `config.DB_URL` from the Terraform output `jdbc_url`
   (`sslmode=verify-full`, `sslrootcert` on the mounted `rds-ca-bundle`; the
   chart refuses any other URL). Every container runs under the `aws`
   profile, and under it the service also refuses to start with any other
   URL. The chart refuses Spring config locations (`spring.config.import`,
   `.location`, `.additional-location`, `SPRING_APPLICATION_JSON`) in
   `config` and any `extraEnv`. It also refuses any Spring profile from
   values (`SPRING_PROFILES_*` in any relaxed-binding spelling, or
   `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS` or `JAVA_OPTS` mentioning
   `spring.profiles`), so a `local` profile cannot reach the pods. The `migrate` init
   container runs Flyway as the owner and exits; the service then starts with
   the runtime role and Flyway disabled. The pods are selected by
   `app.kubernetes.io/name`, `instance` and `component=service`. The
   Deployment selector is immutable. No release is installed yet, so the
   first install creates it with the component label. A release installed
   before round 5 would have to be deleted and installed again. The history
   guard check CronJob (section 2.3) also starts at install and fails
   until the guard is armed below. Check:
   `SELECT grantee, privilege_type FROM information_schema.role_table_grants WHERE table_schema = 'sc_of_open_products_catalog' ORDER BY 1, 2;`
   Then the admin arms the history guard, from the operator host:
   `SELECT fbx_history_guard.arm('<change ticket>: first deploy');` must
   return `armed, intact`. `arm()` performs the transfer to the history
   writer. Until then the schema owner still owns `product_history_record()`
   and holds INSERT on the history, and the guard refuses nothing. Keep this
   pre-arm window short: arm in the same change as the first deploy, before
   the import (step 4) and before anyone else gets access.
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
  return `armed, intact`. Any other answer is an incident: `DISARMED`,
  `CHANGED SINCE ARMED`, `EVENT TRIGGERS MISSING OR DISABLED` or
  `GUARD STATE NOT APPEND-ONLY`. It pages on any answer other than
  `armed, intact` and blocks releases: nothing is promoted to an
  environment whose last check failed, and an incident is opened. Run it by
  hand after every release and before each catalogue import. The rehearsal
  checks it too, plus `pg_trigger.tgenabled` (all six history triggers `A`,
  ALWAYS) and `md5(prosrc)` of the history functions.
- **Scheduled check and release gate** (built in round 5, not yet run in a
  cluster): the chart runs the service image in check mode
  (`OPEN_PRODUCTS_HISTORY_GUARD_CHECK=true`). It calls `verify()` as the
  runtime role, with the `db-app` credential and verified TLS, and exits
  non-zero unless the answer is `armed, intact`. It runs in two places:
  - CronJob `open-products-catalog-service-history-guard-check`, every 15
    minutes (`historyGuardCheck.schedule`). A failed Job pages through
    `OpenProductsHistoryGuardCheckFailed`, a missing run through
    `OpenProductsHistoryGuardCheckNotRunning` (alerts, below).
  - Job `open-products-catalog-service-history-guard-gate`, a Helm
    `pre-upgrade` hook. If the check fails, `helm upgrade` fails before
    anything is applied, and the failed Job stays for inspection. It is not a
    `pre-install` hook, because the guard is armed after the first install.

- **Alerts** (platform observability commit 6e66584 defines them and routes
  both to the Open Data Squad; the rule expressions live there and are not
  checked from this repository):
  - `OpenProductsHistoryGuardCheckFailed`: a check Job failed, from the
    CronJob or the pre-upgrade gate. Either `verify()` did not answer
    `armed, intact`, or the check could not get an answer (no connection,
    TLS refused, credential, image). Response: read the failed Job's log
    (`kubectl -n open-finance logs job/<job>`; the gate's Job stays for
    inspection). If it names an answer, treat it as the integrity incident
    above: open an incident, block releases to the environment, compare
    `fbx_history_guard.event` and `fbx_history_guard.armed` with the change
    tickets, and re-arm only under a ticket (break-glass, below). If it
    names a connection, TLS or credential failure, fix that and re-run the
    check by hand (`kubectl -n open-finance create job --from=cronjob/open-products-catalog-service-history-guard-check <name>`);
    the alert clears on the next successful run. During a break-glass
    release it keeps firing until step 4 (`arm`), by design.
  - `OpenProductsHistoryGuardCheckNotRunning`: no check has run when it
    should have, so the history is unwatched. Causes: the CronJob was
    deleted or suspended, its schedule changed, its pods cannot start
    (scheduling, image pull, egress) or `externalSecret.enabled=false`
    removed it. Response: restore the CronJob from the chart
    (`helm upgrade` of the current release), check
    `kubectl -n open-finance get cronjob open-products-catalog-service-history-guard-check`
    shows `SUSPEND False` and a recent `LAST SCHEDULE`, then run one check
    by hand as above.
  - The CronJob is never suspended in normal operation: the chart renders
    no `spec.suspend` and has no value for it (the deploy/helm job asserts
    this). Suspending it by hand (`kubectl patch ... suspend: true`) stops
    the integrity check and is expected to page through
    `OpenProductsHistoryGuardCheckNotRunning`; do it only under a change
    ticket, and a `helm upgrade` resets it.

  Why this mechanism: it is the most reversible one that can reach the
  database. It is one chart template and one check mode in the service. It
  needs no new image, credential, IAM role, network path or Terraform, and
  a revert or `helm rollback` removes it. A CI or Deployability step cannot
  do the job, because GitHub runners have no path to Aurora (section 2.1).
  A Terraform scheduled task would need its own IAM role, network access
  and secret wiring. The Deployability `deploy/helm` job checks the rendered
  CronJob and gate: the `aws` profile, the runtime credential only, the CA
  bundle, no sidecar, no retry, no app selector matching their pods, both
  pods keeping `app.kubernetes.io/name` and `app.kubernetes.io/component`
  (the mesh selects their Aurora egress on them, mesh d2ccacc), and no
  `spec.suspend` on the CronJob.
  `OpenProductsPostgresIT` proves the check fails against the real guard
  when it is disarmed or changed.
- **Releases**: migrations that do not touch `product_history`, its
  functions (`product_history_record`, `product_history_append_only`,
  `product_history_insert_guard`, `product_truncate_refused`), any trigger on
  `product` or `product_history`, the privileges on either table or
  `fbx_history_guard` run with the guard armed. A migration that does touch
  one of these, or makes a table inherit from or partition either table, is
  refused, so the `migrate` init container fails and the rollout stops with
  the old pods serving (`maxUnavailable: 0`). An upgrade of an environment
  whose guard is not `armed, intact` stops earlier, at the pre-upgrade
  gate. The
  history-tamper alarm (section 2, Terraform) pages on arm, on disarm and on
  every Flyway release whose DDL names `product_history` or
  `fbx_history_guard`. This is by design: such a release only happens under a
  change ticket.
- **Break-glass** for such a migration, by the admin only, with a change
  ticket, in this order:
  1. `SELECT fbx_history_guard.disarm('<ticket>');` logs a WARNING and fires
     the alarm. The history writer keeps the recording function.
  2. `SELECT fbx_history_guard.hand_back_history_writer('<ticket>');`, **only
     if** the migration replaces `product_history_record()`. It gives the
     function and INSERT back to the schema owner, which Flyway runs as.
  3. Deploy with `--set historyGuardCheck.breakGlassTicket=<ticket>`. This
     skips the pre-upgrade gate for this release only, which would otherwise
     refuse because the guard is disarmed, and records the ticket on the
     Deployment. The CronJob keeps paging until step 4. Then check the
     history objects.
  4. `SELECT fbx_history_guard.arm('<ticket>');` moves the writer back,
     clears the owner's INSERT (column grants included) and records the new
     state.

  `arm()` refuses while the guard is armed, and the bootstrap refuses to
  re-run while armed: disarm first. Every step is appended to
  `fbx_history_guard.event` and `fbx_history_guard.armed` (who, when, why).
  Both are append-only, also for the admin. The schema owner can neither
  disarm the guard nor alter its event triggers.
- **Upgrade of an armed environment to round 3** (V5 and the new
  bootstrap): disarm, deploy V5, re-run `db/bootstrap/history-guard.sql`,
  then arm. No hand-back is needed. The round-2 `fbx_history_guard.armed`
  table is kept as `armed_v1`.
- **Upgrade of an armed environment to round 5** (new bootstrap only, no
  migration): `SELECT fbx_history_guard.disarm('<ticket>');`, re-run
  `db/bootstrap/history-guard.sql`, then
  `SELECT fbx_history_guard.arm('<ticket>');`, which must return
  `armed, intact`. The fingerprint now also covers inheritance, so the old
  recorded fingerprint does not match the new formula. The bootstrap refuses
  to run while armed. `arm()` refuses if a table inherits from `product` or
  `product_history`; detach or drop it first, then `ANALYZE` the parent to
  clear `relhassubclass`. On a non-superuser admin, the new `arm()` also
  revokes the writer and owner memberships a round-3 `arm()` left. `armed`,
  `event` and `armed_v1` are kept. This was rehearsed locally from the
  round-2 and round-3 bootstraps. No environment is armed today, because
  nothing is deployed; the first deploy follows section 2.2.
- **Replica mode**: on Aurora 16, `rds_superuser` can set
  `session_replication_role = replica` without any DDL. That is documented,
  not drilled. In replica mode ordinary triggers do not fire, so V5 sets the
  six history triggers, and the bootstrap sets the guard-state triggers, to
  fire ALWAYS. The
  rehearsal proves that TRUNCATE, history inserts and guard-state rewrites
  are still refused in replica mode on PostgreSQL 16. On Aurora this is *to
  be verified in the terraform-modules Aurora 16 drill*.
- **Not prevented, only detected**: the admin (`rds_superuser`) can drop or
  disable the guard's event triggers. That DDL is logged, and filter (a) of
  the history-tamper alarm pages on `EVENT TRIGGER`. `verify()` then returns
  `EVENT TRIGGERS MISSING OR DISABLED`.
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
- The scheduled history-guard integrity check (`fbx_history_guard.verify()`
  must return `armed, intact`) is a **release blocker**. The chart's CronJob
  and pre-upgrade gate (section 2.3) are built; they page through
  `OpenProductsHistoryGuardCheckFailed` and
  `OpenProductsHistoryGuardCheckNotRunning` (platform observability 6e66584
  routes both to the Open Data Squad; section 2.3 says what each means and
  the response). If a namespace default-deny is in place, the
  check pods need the same Aurora egress as the service. They share its
  `app.kubernetes.io/name` and service account but run without a sidecar.
  Owner: Open Data Squad; the alert routing is a platform dependency.
- The guard armed in each environment right after its first deploy (section
  2.2, step 3). An environment armed before round 3 is upgraded with disarm,
  V5, bootstrap, arm (section 2.3). No environment is armed today, because
  nothing is deployed.
- The terraform-modules Aurora 16 drill (tell platform about the new item):
  - `rds_superuser` grants on the roles it created;
  - `session_replication_role` refused by the ALWAYS triggers;
  - `AUDIT: OBJECT` lines from the guard's `rds_pgaudit` grants;
  - new in round 5: `arm()` and hand-back as `rds_superuser` (a
    non-superuser) leave it with ADMIN OPTION only on the owner and the
    writer, `SET ROLE open_products_catalog_history_writer` is refused
    afterwards, and the guard's catalog lookups work without USAGE on the
    service schema.

  All four are unverified on a real instance. The last is rehearsed on
  PostgreSQL 16 with a non-superuser CREATEROLE role.

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

- `./gradlew check` with `TEST_DB_URL` set (a superuser login, as in CI: the
  tests create roles and install the history guard's event triggers from
  `db/bootstrap/history-guard.sql`): Flyway, Hibernate validation, seed,
  filtering, effective-window rules, ETag revalidation, the guard's
  inheritance refusals and the history guard check against PostgreSQL.
- `GET /actuator/health/readiness` on 8081 is `UP` (includes `db`).
- Product count per status after import:
  `SELECT status, count(*) FROM sc_of_open_products_catalog.product GROUP BY status;`

## 5. Acceptance checklist

- [x] Builds and tests standalone, including PostgreSQL integration tests (skipped locally without `TEST_DB_URL`; they fail in CI and Jenkins without it)
- [x] Own schema and migrations; Hibernate validates the entity at startup
- [x] Idempotent catalogue import rehearsed in CI
- [x] Container image, Helm chart, Terraform checked in the Deployability workflow
- [ ] Real catalogue CSV signed off by the product owner
- [x] Scheduled history-guard integrity check built: chart CronJob plus pre-upgrade release gate (section 2.3); proved red against a disarmed or changed guard in `OpenProductsPostgresIT`
- [ ] The check running and paging in each environment (`OpenProductsHistoryGuardCheckFailed` and `OpenProductsHistoryGuardCheckNotRunning`, routed to the Open Data Squad by platform observability 6e66584); a failed `verify()` blocks every release to that environment
- [ ] Guard armed after the first deploy in each environment (`verify()` returns `armed, intact`); none armed today, nothing is deployed
- [ ] terraform-modules Aurora 16 drill: role grants by `rds_superuser`, replica-mode refusal, pgaudit object audit, no writer membership left after `arm()` by `rds_superuser`
- [ ] Gateway route switched (platform)
- [ ] Monolith `productcatalog` controller removed (enterprise-loan-management-system)
