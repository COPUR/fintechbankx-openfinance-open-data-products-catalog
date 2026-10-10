#!/usr/bin/env bash
# Rehearses svc-of-open-products-catalog's data path on a scratch PostgreSQL,
# with the same three roles as production (runbook section 2):
#   1. DBA bootstrap: owner, runtime and import roles; the owner applies the
#      Flyway schema migrations (V*.sql) to a fresh database,
#   2. applies the dev/CI seed callback twice (insert-only, SAMPLE- ids),
#   3. imports db/import/products.example.csv twice as the import role
#      (second run changes nothing),
#   4. imports a changed CSV (one product updated, version and updated_at move),
#   5. checks a bad CSV is rejected as a whole, SAMPLE- ids are refused and only
#      the import role may import,
#   6. imports, then seeds, and checks every imported value survives the seed,
#   7. checks timestamps need a UTC offset, and that a full import withdraws
#      ACTIVE products missing from the file (a --delta import does not),
#   8. checks the role privileges and the append-only product_history,
#   9. checks every import change records the operator's AWS caller identity
#      (aws sts get-caller-identity, stubbed here) and that the import role
#      cannot change products without one,
#  10. checks the schema owner cannot disable, drop or replace the history's
#      triggers, functions or table, however the DDL is spelled or nested
#      (review probes), and that the triggers and function bodies are intact,
#  11. checks the history cannot be forged or bypassed by the owner: direct
#      inserts into product_history are refused, deleting a product is
#      recorded, no new trigger on product may write the history, and no
#      table may inherit from product or product_history or take either as
#      a partition (CREATE TABLE ... INHERITS, ALTER TABLE ... INHERIT,
#      ATTACH PARTITION),
#  12. checks TRUNCATE of product is refused for every role, the admin
#      included, also in replica mode (V5), and that only the NOLOGIN history
#      writer may insert history rows (V5's insert guard, a superuser's
#      trigger included),
#  13. checks the guard covers table and column privileges, its own state is
#      append-only, and arm/disarm/hand-back/re-arm keep the owner without
#      INSERT on the history, column grants included (has_any_column_privilege),
#  14. checks a non-superuser CREATEROLE admin (the Aurora rds_superuser
#      stand-in) can hand back and arm, and keeps no SET or INHERIT
#      membership in the history writer afterwards (review 5).
# There is no monolith data to backfill (ADR-0001), so there is no source DB.
#
# Needs psql and a superuser (it creates roles and a database), via the usual
# PG* env vars (PGHOST, PGPORT, PGUSER, PGPASSWORD) and a TCP connection with
# password authentication for the three rehearsal roles.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
db="of_open_products_rehearsal"
schema="sc_of_open_products_catalog"
owner="open_products_catalog_owner"
app="open_products_catalog_app"
importer="open_products_catalog_import"
writer="open_products_catalog_history_writer"
# Stand-in for the Aurora admin (rds_superuser): CREATEROLE, not a superuser.
admin="open_products_rehearsal_admin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Throwaway credentials for this run only.
owner_secret="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
app_secret="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
import_secret="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
admin_secret="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
as_owner() { PGUSER="$owner" PGPASSWORD="$owner_secret" "$@"; }
as_app() { PGUSER="$app" PGPASSWORD="$app_secret" "$@"; }
as_admin() { PGUSER="$admin" PGPASSWORD="$admin_secret" "$@"; }
# Stand-in for the AWS CLI: the import asks STS who the operator is.
operator_arn="arn:aws:sts::111122223333:assumed-role/CatalogueOperator/rehearsal"
mkdir -p "$work/bin"
cat > "$work/bin/aws" <<'STUB'
#!/bin/sh
[ "$*" = "sts get-caller-identity --query Arn --output text" ] || { echo "unexpected aws call: $*" >&2; exit 2; }
[ -n "${FAKE_AWS_ARN:-}" ] || { echo "Unable to locate credentials" >&2; exit 255; }
echo "$FAKE_AWS_ARN"
STUB
chmod +x "$work/bin/aws"
with_aws() { PATH="$work/bin:$PATH" FAKE_AWS_ARN="$operator_arn" "$@"; }
as_importer() { PGUSER="$importer" PGPASSWORD="$import_secret" IMPORT_OPERATOR=rehearsal with_aws "$@"; }
# import [--full|--delta] <csv>: runs the import script as the import role.
import() {
  local mode=()
  case "${1:-}" in --full|--delta) mode=("$1"); shift ;; esac
  as_importer "$root/db/import/import-products.sh" "${mode[@]}" "dbname=$db" "$@"
}

check() {
  local label="$1" sql="$2" expected="$3" actual
  actual="$(psql -X -At -d "$db" -c "$sql")"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL $label: expected '$expected', got '$actual'" >&2
    exit 1
  fi
  echo "ok   $label"
}

# Runs SQL as the schema owner and expects the history guard to refuse it.
# An optional third argument is a pattern the refusal must also match.
refused() {
  local label="$1" sql="$2" reason="${3:-product_history guard}"
  if as_owner psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET search_path = $schema" -c "$sql" 2> "$work/refused.err"; then
    echo "FAIL $label: the schema owner was allowed to run it" >&2
    exit 1
  fi
  grep -q "product_history guard" "$work/refused.err" && grep -q "$reason" "$work/refused.err" || { cat "$work/refused.err" >&2; exit 1; }
  echo "ok   $label"
}

# Runs SQL as a role and expects PostgreSQL to refuse it.
denied() {
  local label="$1" role_cmd="$2" sql="$3"
  if "$role_cmd" psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET search_path = $schema" -c "$sql" 2> "$work/denied.err"; then
    echo "FAIL $label: statement was allowed" >&2
    exit 1
  fi
  grep -qE "permission denied|must be owner|append-only" "$work/denied.err" || { cat "$work/denied.err" >&2; exit 1; }
  echo "ok   $label"
}

echo "--- DBA bootstrap (runbook section 2)"
psql_q -d postgres -c "DROP DATABASE IF EXISTS $db"
# A previous run's admin stand-in, and any membership it granted, go first.
psql_q -d postgres -v admin="$admin" <<'SQL'
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'admin') AS admin_left \gset
\if :admin_left
DO $$
DECLARE
    m record;
BEGIN
    FOR m IN SELECT r.rolname AS role_name, u.rolname AS member_name
               FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles u ON u.oid = a.member
              WHERE a.grantor = (SELECT oid FROM pg_roles WHERE rolname = 'open_products_rehearsal_admin') LOOP
        EXECUTE format('REVOKE %I FROM %I GRANTED BY open_products_rehearsal_admin', m.role_name, m.member_name);
    END LOOP;
END
$$;
DROP ROLE :"admin";
\endif
SQL
for role in "$owner:$owner_secret" "$app:$app_secret" "$importer:$import_secret"; do
  name="${role%%:*}" secret="${role#*:}"
  psql_q -d postgres -v name="$name" -v secret="$secret" <<'SQL'
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'name') AS missing \gset
\if :missing
CREATE ROLE :"name" LOGIN;
\endif
ALTER ROLE :"name" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'secret';
SQL
done
psql_q -d postgres <<SQL
CREATE DATABASE $db;
REVOKE ALL ON DATABASE $db FROM PUBLIC;
GRANT CONNECT, CREATE ON DATABASE $db TO $owner;
GRANT CONNECT ON DATABASE $db TO $app;
GRANT CONNECT, TEMPORARY ON DATABASE $db TO $importer;
SQL
# Stand-in for the Aurora pgaudit object-audit role (pgaudit.role = rds_pgaudit).
psql_q -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_pgaudit') THEN CREATE ROLE rds_pgaudit NOLOGIN; END IF; END \$\$"
# The admin installs the history guard (event triggers), disarmed until the
# first deploy has created the history.
psql_q -d "$db" -v schema="$schema" -f "$root/db/bootstrap/history-guard.sql"

# What Flyway does at deploy time (create-schemas, default-schema), as the owner.
as_owner psql_q -d "$db" -c "CREATE SCHEMA $schema"
for migration in "$root"/src/main/resources/db/migration/V*.sql; do
  echo "--- migration $(basename "$migration") as $owner"
  PGOPTIONS="-c search_path=$schema" as_owner psql_q -d "$db" -f "$migration"
done

echo "--- admin arms the history guard after the first deploy"
psql_q -d "$db" -c "SELECT fbx_history_guard.arm('rehearsal: first deploy')" > /dev/null
check "history guard is armed and intact" "SELECT fbx_history_guard.verify()" "armed, intact"
check "object audit: rds_pgaudit holds UPDATE, DELETE on the history and INSERT, UPDATE, DELETE on the guard state" \
  "SELECT string_agg(table_schema || '.' || table_name || ':' || privilege_type, ',' ORDER BY 1) FROM (SELECT table_schema, table_name, privilege_type FROM information_schema.role_table_grants WHERE grantee = 'rds_pgaudit' ORDER BY 1, 2, 3) g" \
  "fbx_history_guard.armed:DELETE,fbx_history_guard.armed:INSERT,fbx_history_guard.armed:UPDATE,fbx_history_guard.event:DELETE,fbx_history_guard.event:INSERT,fbx_history_guard.event:UPDATE,$schema.product_history:DELETE,$schema.product_history:UPDATE"

for run in 1 2; do
  echo "--- seed run $run"
  PGOPTIONS="-c search_path=$schema" as_owner psql_q -d "$db" -f "$root/src/main/resources/db/seed/afterMigrate__sample_products.sql"
done
check "seed loads four SAMPLE- products at version 0" \
  "SELECT count(*) || ' ' || max(version) FROM $schema.product WHERE product_id LIKE 'SAMPLE-%'" "4 0"

# V5: TRUNCATE product is refused for every role, the admin included, also
# under session_replication_role = replica; clear the seed rows with DELETE
# (each removal is recorded).
if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "TRUNCATE $schema.product" 2> "$work/truncate.err"; then
  echo "FAIL the admin truncated product without history" >&2
  exit 1
fi
grep -q "TRUNCATE is refused" "$work/truncate.err" || { cat "$work/truncate.err" >&2; exit 1; }
echo "ok   TRUNCATE product is refused, also for the admin"
if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET session_replication_role = replica" -c "TRUNCATE $schema.product" 2> "$work/truncate.err"; then
  echo "FAIL the admin truncated product in replica mode" >&2
  exit 1
fi
grep -q "TRUNCATE is refused" "$work/truncate.err" || { cat "$work/truncate.err" >&2; exit 1; }
echo "ok   TRUNCATE product is refused in replica mode (trigger fires ALWAYS)"
psql_q -d "$db" -c "DELETE FROM $schema.product"
check "clearing the seed rows is recorded" \
  "SELECT count(*) FROM $schema.product_history WHERE operation = 'DELETE' AND product_id LIKE 'SAMPLE-%'" "4"

for run in 1 2; do
  echo "--- import run $run"
  import "$root/db/import/products.example.csv" | tee "$work/import-$run.log"
done
check "first import inserts every row" "SELECT count(*) FROM $schema.product" "5"
grep -q "inserted: 5, updated: 0, unchanged: 0" "$work/import-1.log" || { echo "FAIL first import summary" >&2; exit 1; }
grep -q "inserted: 0, updated: 0, unchanged: 5" "$work/import-2.log" || { echo "FAIL re-import is not a no-op" >&2; exit 1; }
check "re-import leaves versions untouched" "SELECT max(version) FROM $schema.product" "0"
check "money stored as amount + currency" \
  "SELECT monthly_fee_amount || ' ' || monthly_fee_currency FROM $schema.product WHERE product_id = 'SME-PCA-01'" "35.00 AED"
check "draft product is kept but not ACTIVE" \
  "SELECT status FROM $schema.product WHERE product_id = 'CC-001'" "DRAFT"

before="$(psql -X -At -d "$db" -c "SELECT updated_at FROM $schema.product WHERE product_id = 'SME-PCA-01'")"
sed 's/^SME-PCA-01,PCA,SME,SME Current,Business current account,AED,35.00/SME-PCA-01,pca,sme,SME Current,Business current account,AED,30.00/' \
  "$root/db/import/products.example.csv" > "$work/changed.csv"
import "$work/changed.csv" | tee "$work/import-3.log"
grep -q "inserted: 0, updated: 1, unchanged: 4" "$work/import-3.log" || { echo "FAIL changed row not upserted" >&2; exit 1; }
check "changed fee is upserted with a new version" \
  "SELECT monthly_fee_amount || ' v' || version FROM $schema.product WHERE product_id = 'SME-PCA-01'" "30.00 v1"
check "codes are normalised to upper case" \
  "SELECT product_type || '/' || segment FROM $schema.product WHERE product_id = 'SME-PCA-01'" "PCA/SME"
check "updated_at moves only for the changed row" \
  "SELECT (updated_at > '$before'::timestamptz)::text FROM $schema.product WHERE product_id = 'SME-PCA-01'" "true"

{ head -n 1 "$root/db/import/products.example.csv"
  echo "NEW-001,PCA,RETAIL,New Account,,AED,1.00,0.00,,ACTIVE,2026-05-01T00:00:00Z,"
  echo "BAD-001,PCA,RETAIL,Bad Fee,,AED,1.005,0.00,,ACTIVE,2026-05-01T00:00:00Z,"
} > "$work/bad.csv"
if import "$work/bad.csv" 2> "$work/bad.err"; then
  echo "FAIL import accepted an amount with three decimals" >&2
  exit 1
fi
grep -q "more than two decimals" "$work/bad.err" || { cat "$work/bad.err" >&2; exit 1; }
check "a rejected file changes nothing" "SELECT count(*) FROM $schema.product WHERE product_id = 'NEW-001'" "0"

{ head -n 1 "$root/db/import/products.example.csv"
  echo "sample-PCA-001,PCA,RETAIL,Not a sample,,AED,9.00,0.00,,ACTIVE,2026-05-01T00:00:00Z,"
} > "$work/sample.csv"
if import "$work/sample.csv" 2> "$work/sample.err"; then
  echo "FAIL import accepted a SAMPLE- product id" >&2
  exit 1
fi
grep -q "reserved SAMPLE- namespace" "$work/sample.err" || { cat "$work/sample.err" >&2; exit 1; }
echo "ok   import refuses SAMPLE- ids"

if IMPORT_OPERATOR=rehearsal as_owner with_aws "$root/db/import/import-products.sh" "dbname=$db" "$root/db/import/products.example.csv" 2> "$work/owner.err"; then
  echo "FAIL import ran as the owner role" >&2
  exit 1
fi
grep -q "refusing to import as $owner" "$work/owner.err" || { cat "$work/owner.err" >&2; exit 1; }
echo "ok   import refuses any role but the import role"

if PGUSER="$importer" PGPASSWORD="$import_secret" "$root/db/import/import-products.sh" "dbname=$db" "$root/db/import/products.example.csv" 2> "$work/nooperator.err"; then
  echo "FAIL import ran without IMPORT_OPERATOR" >&2
  exit 1
fi
echo "ok   import requires IMPORT_OPERATOR"

if PGUSER="$importer" PGPASSWORD="$import_secret" IMPORT_OPERATOR=rehearsal PATH="$work/bin:$PATH" \
     "$root/db/import/import-products.sh" "dbname=$db" "$root/db/import/products.example.csv" 2> "$work/nocaller.err"; then
  echo "FAIL import ran without an AWS caller identity" >&2
  exit 1
fi
grep -q "AWS caller identity" "$work/nocaller.err" || { cat "$work/nocaller.err" >&2; exit 1; }
echo "ok   import requires an AWS caller identity"
if PGUSER="$importer" PGPASSWORD="$import_secret" IMPORT_OPERATOR=rehearsal PATH="$work/bin:$PATH" FAKE_AWS_ARN="arn:aws:iam::111122223333:root" \
     "$root/db/import/import-products.sh" "dbname=$db" "$root/db/import/products.example.csv" 2> "$work/root.err"; then
  echo "FAIL import ran as the AWS account root" >&2
  exit 1
fi
grep -q "AWS caller identity" "$work/root.err" || { cat "$work/root.err" >&2; exit 1; }
echo "ok   import refuses an account-root or malformed caller identity"

# The dev seed must never revert an imported catalogue: import, then seed, then
# the imported values (and their version/updated_at) must be unchanged.
sed 's/^SME-PCA-01,PCA,SME,SME Current,Business current account,AED,35.00/SME-PCA-01,PCA,SME,SME Current,Business current account,AED,25.00/' \
  "$root/db/import/products.example.csv" > "$work/imported.csv"
import "$work/imported.csv" > /dev/null
imported="$(psql -X -At -d "$db" -c "SELECT string_agg(product_id || ':' || monthly_fee_amount || ':' || version || ':' || updated_at, ',' ORDER BY product_id) FROM $schema.product WHERE product_id NOT LIKE 'SAMPLE-%'")"
echo "--- seed after import"
PGOPTIONS="-c search_path=$schema" as_owner psql_q -d "$db" -f "$root/src/main/resources/db/seed/afterMigrate__sample_products.sql"
check "seed after import leaves every imported row as imported" \
  "SELECT string_agg(product_id || ':' || monthly_fee_amount || ':' || version || ':' || updated_at, ',' ORDER BY product_id) FROM $schema.product WHERE product_id NOT LIKE 'SAMPLE-%'" \
  "$imported"
check "imported fee survives the seed" \
  "SELECT monthly_fee_amount FROM $schema.product WHERE product_id = 'SME-PCA-01'" "25.00"

# Timestamps without an offset would be read in the session's time zone.
{ head -n 1 "$root/db/import/products.example.csv"
  echo "TZ-001,PCA,RETAIL,No Offset,,AED,1.00,0.00,,ACTIVE,2026-05-01T00:00:00,"
} > "$work/nooffset.csv"
if import --delta "$work/nooffset.csv" 2> "$work/nooffset.err"; then
  echo "FAIL import accepted effective_from without a UTC offset" >&2
  exit 1
fi
grep -q "without a UTC offset" "$work/nooffset.err" || { cat "$work/nooffset.err" >&2; exit 1; }
check "a timestamp without offset changes nothing" "SELECT count(*) FROM $schema.product WHERE product_id = 'TZ-001'" "0"
{ head -n 1 "$root/db/import/products.example.csv"
  echo "TZ-002,PCA,RETAIL,Offset,,AED,1.00,0.00,,ACTIVE,2026-05-01T04:00:00+04:00,"
} > "$work/offset.csv"
import --delta "$work/offset.csv" > /dev/null
check "an explicit offset is stored as UTC" \
  "SELECT to_char(effective_from AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') FROM $schema.product WHERE product_id = 'TZ-002'" "2026-05-01 00:00"
check "a delta import leaves products missing from the file alone" \
  "SELECT status FROM $schema.product WHERE product_id = 'PCA-001'" "ACTIVE"

# A full import (the default, for the signed-off catalogue) withdraws ACTIVE
# products that are missing from the file; seed rows are never touched.
PGOPTIONS="-c search_path=$schema" as_owner psql_q -d "$db" -f "$root/src/main/resources/db/seed/afterMigrate__sample_products.sql"
grep -v '^SAV-001,' "$work/imported.csv" > "$work/full.csv"
import "$work/full.csv" | tee "$work/import-full.log"
grep -q "withdrawn: 2" "$work/import-full.log" || { echo "FAIL full import did not withdraw SAV-001 and TZ-002" >&2; exit 1; }
check "full import withdraws ACTIVE products missing from the file" \
  "SELECT string_agg(product_id || ':' || status || ':v' || version, ',' ORDER BY product_id) FROM $schema.product WHERE product_id IN ('SAV-001', 'TZ-002', 'CC-001')" \
  "CC-001:DRAFT:v0,SAV-001:WITHDRAWN:v1,TZ-002:WITHDRAWN:v1"
check "full import leaves the SAMPLE- seed rows alone" \
  "SELECT count(*) FROM $schema.product WHERE product_id LIKE 'SAMPLE-%' AND status = 'ACTIVE'" "4"
check "the withdrawal is in the history" \
  "SELECT (old_row->>'status') || '->' || (new_row->>'status') FROM $schema.product_history WHERE product_id = 'SAV-001' ORDER BY history_id DESC LIMIT 1" \
  "ACTIVE->WITHDRAWN"
head -n 1 "$root/db/import/products.example.csv" > "$work/empty.csv"
if import "$work/empty.csv" 2> "$work/empty.err"; then
  echo "FAIL full import of an empty file was accepted" >&2
  exit 1
fi
grep -q "no products" "$work/empty.err" || { cat "$work/empty.err" >&2; exit 1; }
echo "ok   full import refuses an empty file"

echo "--- roles and audit trail"
check "runtime role reads the catalogue" \
  "SELECT has_table_privilege('$app', '$schema.product', 'SELECT')::text" "true"
denied "runtime role cannot update products" as_app "UPDATE product SET name = 'x' WHERE product_id = 'SME-PCA-01'"
denied "runtime role cannot insert products" as_app "INSERT INTO product (product_id) VALUES ('X-1')"
denied "runtime role cannot read the history" as_app "SELECT count(*) FROM product_history"
denied "import role cannot delete products" as_importer "DELETE FROM product WHERE product_id = 'SME-PCA-01'"
denied "import role cannot truncate products" as_importer "TRUNCATE product"
denied "import role cannot write the history directly" as_importer \
  "INSERT INTO product_history (product_id, operation, new_row, changed_by, login_role, application_name, transaction_id, changed_at) VALUES ('X', 'INSERT', '{}', 'x', 'x', 'x', 0, now())"
denied "import role cannot change the schema" as_importer "ALTER TABLE product ADD COLUMN x int"
# Bypassing the script: the import role's own writes need a caller identity.
if as_importer psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET search_path = $schema" \
     -c "UPDATE product SET name = name || ' x' WHERE product_id = 'SME-PCA-01'" 2> "$work/bypass.err"; then
  echo "FAIL import role changed a product without a recorded AWS caller identity" >&2
  exit 1
fi
grep -q "AWS caller identity" "$work/bypass.err" || { cat "$work/bypass.err" >&2; exit 1; }
echo "ok   import role cannot change products without an AWS caller identity"
denied "history rejects updates even from the owner" as_owner "UPDATE product_history SET changed_by = 'x'"
denied "history rejects deletes even from the owner" as_owner "DELETE FROM product_history"
check "every import change is in the history with role and operator" \
  "SELECT count(*) || ' ' || string_agg(DISTINCT changed_by || '/' || application_name, ',') FROM $schema.product_history WHERE product_id = 'SME-PCA-01' AND application_name LIKE 'import-products/%'" \
  "3 $importer/import-products/rehearsal"
check "every import change records the operator's AWS caller identity" \
  "SELECT count(*) || ' ' || string_agg(DISTINCT operator_arn, ',') FROM $schema.product_history WHERE product_id = 'SME-PCA-01' AND application_name LIKE 'import-products/%'" \
  "3 $operator_arn"
check "the history keeps old and new values of each update" \
  "SELECT string_agg((old_row->>'monthly_fee_amount') || '->' || (new_row->>'monthly_fee_amount'), ',' ORDER BY history_id) FROM $schema.product_history WHERE product_id = 'SME-PCA-01' AND operation = 'UPDATE'" \
  "35.00->30.00,30.00->25.00"

echo "--- schema owner cannot forge or bypass the history (V4)"
if as_owner psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET search_path = $schema" \
     -c "INSERT INTO product_history (product_id, operation, new_row, changed_by, login_role, application_name, transaction_id, changed_at) VALUES ('FORGED', 'INSERT', '{}', 'x', 'x', 'x', 0, now())" 2> "$work/forge.err"; then
  echo "FAIL the schema owner inserted a forged history row" >&2
  exit 1
fi
grep -qE "permission denied for table product_history|only the history trigger" "$work/forge.err" || { cat "$work/forge.err" >&2; exit 1; }
echo "ok   direct inserts into product_history are refused, also for the owner"
# Review probe forge_src: a row trigger on any other table runs at depth 2.
forge_src_sql='CREATE TABLE forge_src (id int);
CREATE FUNCTION forge_fn() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO product_history (product_id, operation, new_row, changed_by, login_role, application_name, transaction_id, changed_at)
  VALUES ('"'FORGED-SRC'"', '"'INSERT'"', '"'{}'"', '"'x'"', '"'x'"', '"'x'"', 0, now());
  RETURN NULL;
END $f$;
CREATE TRIGGER trg_forge_src AFTER INSERT ON forge_src FOR EACH ROW EXECUTE FUNCTION forge_fn();
INSERT INTO forge_src VALUES (1);'
if as_owner psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET search_path = $schema" -c "$forge_src_sql" 2> "$work/forge_src.err"; then
  echo "FAIL the schema owner forged history through a trigger on another table" >&2
  exit 1
fi
grep -q "permission denied for table product_history" "$work/forge_src.err" || { cat "$work/forge_src.err" >&2; exit 1; }
echo "ok   review probe forge_src: a trigger on another table cannot write the history"
if as_owner psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET search_path = $schema" \
     -c "CREATE TABLE forge_src2 (product_id text); CREATE TRIGGER trg_forge_src2 AFTER INSERT ON forge_src2 FOR EACH ROW EXECUTE FUNCTION product_history_record(); INSERT INTO forge_src2 VALUES ('FORGED-SRC2')" 2> "$work/forge_src2.err"; then
  echo "FAIL the schema owner reused the history function on another table" >&2
  exit 1
fi
grep -q "permission denied for function product_history_record" "$work/forge_src2.err" || { cat "$work/forge_src2.err" >&2; exit 1; }
echo "ok   the history function cannot be attached to another table"
check "no forged row reached the history" "SELECT count(*) FROM $schema.product_history WHERE product_id LIKE 'FORGED%'" "0"
check "the schema owner holds no INSERT on the history" \
  "SELECT has_any_column_privilege('$owner', '$schema.product_history', 'INSERT')::text" "false"
check "the history writer (NOLOGIN) owns the recording function and alone may insert" \
  "SELECT pg_get_userbyid(p.proowner) || ':' || p.prosecdef || ':' || r.rolcanlogin || ':' || has_table_privilege(r.rolname, '$schema.product_history', 'INSERT') FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner WHERE p.oid = '$schema.product_history_record()'::regprocedure" \
  "open_products_catalog_history_writer:true:false:true"
as_owner psql_q -d "$db" -c "SET search_path = $schema" \
  -c "INSERT INTO product (product_id, product_type, segment, name, currency, monthly_fee_amount, monthly_fee_currency, annual_rate_percent, status, effective_from, updated_at) VALUES ('DEL-001', 'PCA', 'RETAIL', 'To delete', 'AED', 1.00, 'AED', 0.00, 'ACTIVE', '2026-05-01T00:00:00Z', now())" \
  -c "DELETE FROM product WHERE product_id = 'DEL-001'"
check "deleting a product is recorded with its last values" \
  "SELECT string_agg(operation || ':' || coalesce(old_row->>'name', '-') || ':' || coalesce(new_row->>'name', '-') || ':' || changed_by, ',' ORDER BY history_id) FROM $schema.product_history WHERE product_id = 'DEL-001'" \
  "INSERT:-:To delete:$owner,DELETE:To delete:-:$owner"
# Review probes (round 5): a child table is read through its parent, and the
# parent's row triggers do not fire for rows inserted into the child.
history_cols="product_id, operation, new_row, changed_by, login_role, application_name, transaction_id, changed_at"
refused "review probe: a child of product_history carries forged rows visible through the history" \
  "CREATE TABLE forge_hist_child () INHERITS (product_history); INSERT INTO forge_hist_child (history_id, $history_cols) VALUES (900000001, 'FORGED-CHILD', 'INSERT', '{}', 'x', 'x', 'x', 0, now())" "inherits from"
refused "review probe: a child of product adds rows the runtime role sees without history" \
  "CREATE TABLE product_shadow () INHERITS (product); GRANT SELECT ON product_shadow TO $app; INSERT INTO product_shadow (product_id, product_type, segment, name, currency, monthly_fee_amount, monthly_fee_currency, annual_rate_percent, status, effective_from) VALUES ('SHADOW-001', 'PCA', 'RETAIL', 'Shadow', 'AED', 0.00, 'AED', 0.00, 'ACTIVE', '2026-05-01T00:00:00Z')" "inherits from"
refused "ALTER TABLE ... INHERIT product_history on an existing table" \
  "CREATE TABLE forge_inherit (LIKE product_history INCLUDING CONSTRAINTS); ALTER TABLE forge_inherit INHERIT product_history" "inherits from"
refused "ALTER TABLE ... INHERIT product on an existing table" \
  "CREATE TABLE shadow_inherit (LIKE product INCLUDING CONSTRAINTS); ALTER TABLE shadow_inherit INHERIT product" "inherits from"
refused "attach product_history as a partition of another table" \
  "CREATE TABLE forge_parent (LIKE product_history) PARTITION BY LIST (operation); ALTER TABLE forge_parent ATTACH PARTITION product_history DEFAULT" "inherits from"
refused "attach product as a partition of another table" \
  "CREATE TABLE shadow_parent (LIKE product) PARTITION BY LIST (status); ALTER TABLE shadow_parent ATTACH PARTITION product DEFAULT" "inherits from"
check "no table inherits from or contains product or product_history" \
  "SELECT count(*) FROM pg_inherits WHERE inhparent IN ('$schema.product'::regclass, '$schema.product_history'::regclass) OR inhrelid IN ('$schema.product'::regclass, '$schema.product_history'::regclass)" "0"
check "every row read through product has a history row (none came through a child)" \
  "SELECT count(*) FROM $schema.product p WHERE NOT EXISTS (SELECT 1 FROM $schema.product_history h WHERE h.product_id = p.product_id)" "0"
check "no forged child row is visible through the history" \
  "SELECT count(*) FROM $schema.product_history WHERE product_id = 'FORGED-CHILD' OR tableoid <> '$schema.product_history'::regclass" "0"

echo "--- schema owner cannot tamper with the history (review probes)"
integrity_sql="SELECT string_agg(t.tgname || ':' || t.tgenabled::text || ':' || md5(p.prosrc), ',' ORDER BY t.tgname)
  FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
 WHERE t.tgrelid IN ('$schema.product'::regclass, '$schema.product_history'::regclass) AND NOT t.tgisinternal"
intact="$(psql -X -At -d "$db" -c "$integrity_sql")"
case "$intact" in
  trg_product_history:A:*,trg_product_history_delete:A:*,trg_product_history_insert_guard:A:*,trg_product_history_no_change:A:*,trg_product_history_no_truncate:A:*,trg_product_no_truncate:A:*) ;;
  *) echo "FAIL history triggers before the probes: $intact" >&2; exit 1 ;;
esac
refused "probe 1: replace the append-only function to return OLD" \
  'CREATE OR REPLACE FUNCTION product_history_append_only() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN RETURN OLD; END $f$'
denied "probe 1: history deletes are still rejected afterwards" as_owner "DELETE FROM product_history"
refused "probe 2: DISABLE TRIGGER built by string concatenation inside DO/EXECUTE" \
  "DO \$d\$ BEGIN EXECUTE 'ALTER TABLE product DIS' || 'ABLE TRIGGER trg_product_history'; END \$d\$"
refused "probe 3: spacing and case variants of DISABLE TRIGGER" \
  "alter   table   product   Disable   Trigger   trg_product_history"
refused "disable every user trigger on the history" "ALTER TABLE product_history DISABLE TRIGGER USER"
refused "disable all triggers on the history" "ALTER TABLE product_history DISABLE TRIGGER ALL"
refused "turn a history trigger into a replica-only trigger" \
  "ALTER TABLE product_history ENABLE REPLICA TRIGGER trg_product_history_no_change"
refused "drop the history-recording trigger" "DROP TRIGGER trg_product_history ON product"
refused "drop an append-only trigger" "DROP TRIGGER trg_product_history_no_truncate ON product_history"
refused "drop the append-only function with its triggers" "DROP FUNCTION product_history_append_only() CASCADE"
denied "make the recording function SECURITY INVOKER (owned by the history writer)" as_owner \
  "ALTER FUNCTION product_history_record() SECURITY INVOKER"
denied "replace the recording function (owned by the history writer)" as_owner \
  'CREATE OR REPLACE FUNCTION product_history_record() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$ BEGIN RETURN NULL; END $f$'
denied "the owner cannot grant itself EXECUTE on the recording function" as_owner \
  "GRANT EXECUTE ON FUNCTION product_history_record() TO $owner"
denied "the owner cannot become the history writer" as_owner "SET ROLE open_products_catalog_history_writer"
refused "drop the history table" "DROP TABLE product_history"
refused "rename the history table" "ALTER TABLE product_history RENAME TO product_history_old"
refused "drop a history column" "ALTER TABLE product_history DROP COLUMN operator_arn"
refused "a rule that swallows history inserts" "CREATE RULE skip_history AS ON INSERT TO product_history DO INSTEAD NOTHING"
refused "a new trigger on the history" \
  'CREATE FUNCTION skip_row() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN RETURN NULL; END $f$; CREATE TRIGGER trg_skip BEFORE INSERT ON product_history FOR EACH ROW EXECUTE FUNCTION skip_row()'
refused "a new trigger on product that could write forged history" \
  'CREATE FUNCTION forge_row() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN RETURN NULL; END $f$; CREATE TRIGGER trg_forge AFTER UPDATE ON product FOR EACH ROW EXECUTE FUNCTION forge_row()'
refused "review probe: the owner grants itself INSERT on the history" \
  "GRANT INSERT ON product_history TO $owner"
refused "grant the import role DELETE on product" "GRANT DELETE ON product TO $importer"
refused "grant the runtime role SELECT on the history" "GRANT SELECT ON product_history TO $app"
refused "grant the runtime role UPDATE on product" "GRANT UPDATE ON product TO $app"
denied "the owner cannot take back or replace the recording function" as_owner \
  "ALTER FUNCTION product_history_record() OWNER TO $owner"
refused "review probe: column-level INSERT on the history to the owner" \
  "GRANT INSERT (product_id, operation, new_row, changed_by, login_role, application_name, transaction_id, changed_at) ON product_history TO $owner"
refused "column-level UPDATE on product to the runtime role" "GRANT UPDATE (name) ON product TO $app"
refused "column-level INSERT on product to the runtime role" "GRANT INSERT (product_id) ON product TO $app"
refused "the owner revokes the history writer's INSERT" "REVOKE INSERT ON product_history FROM open_products_catalog_history_writer"
refused "the owner revokes the runtime role's SELECT on product" "REVOKE SELECT ON product FROM $app"
denied "the owner cannot truncate product" as_owner "TRUNCATE product"
refused "drop the TRUNCATE refusal on product" "DROP TRIGGER trg_product_no_truncate ON product"
refused "turn the TRUNCATE refusal into an origin-only trigger" "ALTER TABLE product ENABLE TRIGGER trg_product_no_truncate"
refused "replace the TRUNCATE refusal function" \
  'CREATE OR REPLACE FUNCTION product_truncate_refused() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN RETURN NULL; END $f$'
if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET search_path = $schema" -c "SET session_replication_role = replica" \
     -c "CREATE TABLE forge_su (id int); CREATE FUNCTION forge_su_fn() RETURNS trigger LANGUAGE plpgsql AS \$f\$ BEGIN INSERT INTO product_history (product_id, operation, new_row, changed_by, login_role, application_name, transaction_id, changed_at) VALUES ('FORGED-SU', 'INSERT', '{}', 'x', 'x', 'x', 0, now()); RETURN NULL; END \$f\$; CREATE TRIGGER trg_forge_su AFTER INSERT ON forge_su FOR EACH ROW EXECUTE FUNCTION forge_su_fn(); ALTER TABLE forge_su ENABLE ALWAYS TRIGGER trg_forge_su; INSERT INTO forge_su VALUES (1)" 2> "$work/forge_su.err"; then
  echo "FAIL a superuser forged history through a trigger in replica mode" >&2
  exit 1
fi
grep -q "only the history trigger" "$work/forge_su.err" || { cat "$work/forge_su.err" >&2; exit 1; }
echo "ok   the insert guard refuses any inserter but the history writer, also a superuser in replica mode"
for stmt in "DELETE FROM fbx_history_guard.event" "UPDATE fbx_history_guard.armed SET by_role = 'x'" \
            "TRUNCATE fbx_history_guard.event" "TRUNCATE fbx_history_guard.armed"; do
  if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET session_replication_role = replica" -c "$stmt" 2> "$work/state.err"; then
    echo "FAIL the admin rewrote the guard state: $stmt" >&2
    exit 1
  fi
  grep -qE "fbx_history_guard\.(event|armed) is append-only" "$work/state.err" || { cat "$work/state.err" >&2; exit 1; }
done
echo "ok   the guard state (armed, event) is append-only, also for the admin in replica mode"
if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "UPDATE fbx_history_guard.armed SET is_armed = false" 2> "$work/state.err"; then
  echo "FAIL the admin updated the arming log" >&2; exit 1
fi
grep -q "fbx_history_guard.armed is append-only" "$work/state.err" || { cat "$work/state.err" >&2; exit 1; }
echo "ok   the arming log refuses updates"
if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "ALTER TABLE fbx_history_guard.event DISABLE TRIGGER trg_event_append_only" 2> "$work/state.err"; then
  echo "FAIL the admin disabled the event log's append-only trigger while armed" >&2; exit 1
fi
grep -q "product_history guard" "$work/state.err" || { cat "$work/state.err" >&2; exit 1; }
echo "ok   DDL on the guard's own schema is refused while armed, also for the admin"
if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -v schema="$schema" -f "$root/db/bootstrap/history-guard.sql" > /dev/null 2> "$work/rerun.err"; then
  echo "FAIL the bootstrap re-ran while armed" >&2; exit 1
fi
grep -q "disarm(<ticket>) before re-running the bootstrap" "$work/rerun.err" || { cat "$work/rerun.err" >&2; exit 1; }
echo "ok   the bootstrap refuses to re-run while armed"
if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SELECT fbx_history_guard.arm('re-arm while armed')" 2> "$work/rearm.err"; then
  echo "FAIL arm() ran while armed" >&2; exit 1
fi
grep -q "already armed" "$work/rearm.err" || { cat "$work/rearm.err" >&2; exit 1; }
echo "ok   arm() refuses while armed (disarm first)"
# GRANT ROLE fires no event trigger: verify() must see it, and the guard state stays closed to the member.
psql_q -d "$db" -c "GRANT rds_pgaudit TO $owner"
check "a new member of the audit role is reported" "SELECT fbx_history_guard.verify()" "CHANGED SINCE ARMED"
if as_owner psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "INSERT INTO fbx_history_guard.armed (is_armed) VALUES (false)" 2> "$work/state.err"; then
  echo "FAIL a member of rds_pgaudit disarmed the guard by inserting a state row" >&2; exit 1
fi
grep -q "fbx_history_guard.armed is written only by arm()" "$work/state.err" || { cat "$work/state.err" >&2; exit 1; }
echo "ok   a member of rds_pgaudit cannot append to the guard state"
psql_q -d "$db" -c "REVOKE rds_pgaudit FROM $owner"
check "guard intact again once the membership is gone" "SELECT fbx_history_guard.verify()" "armed, intact"
refused "drop the insert guard on the history" "DROP TRIGGER trg_product_history_insert_guard ON product_history"
refused "replace the insert-guard function" \
  'CREATE OR REPLACE FUNCTION product_history_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN RETURN NEW; END $f$'
refused "drop the delete-recording trigger" "DROP TRIGGER trg_product_history_delete ON product"
refused "disable the delete-recording trigger" "ALTER TABLE product DISABLE TRIGGER trg_product_history_delete"
check "history triggers enabled and function bodies unchanged after the probes" "$integrity_sql" "$intact"
as_owner psql_q -d "$db" -c "SET search_path = $schema" -c "ALTER TABLE product ADD COLUMN guard_probe int" -c "ALTER TABLE product DROP COLUMN guard_probe"
echo "ok   other DDL by the schema owner (future migrations) still runs"
check "history guard still armed and intact after the probes" "SELECT fbx_history_guard.verify()" "armed, intact"
denied "the schema owner cannot disarm the guard" as_owner "SELECT fbx_history_guard.disarm('owner')"
denied "the schema owner cannot disable the guard's event trigger" as_owner "ALTER EVENT TRIGGER fbx_history_guard_ddl DISABLE"
denied "the schema owner cannot rewrite the guard's armed state" as_owner "DELETE FROM fbx_history_guard.armed"

echo "--- break-glass: the admin disarms, the owner changes the history, the admin re-arms"
psql_q -d "$db" -c "SELECT fbx_history_guard.disarm('rehearsal: break-glass')" > /dev/null 2> "$work/disarm.err"
# The warning reaches the PostgreSQL log, where the history-tamper alarm matches it.
grep -q "WARNING:  product_history guard: DISARMED" "$work/disarm.err" || { echo "FAIL disarming logged no warning" >&2; cat "$work/disarm.err" >&2; exit 1; }
echo "ok   disarming the guard logs a warning for the alarm"
check "disarmed guard reports it" "SELECT fbx_history_guard.verify()" "DISARMED"
check "disarming keeps the history writer" \
  "SELECT pg_get_userbyid(proowner) || ':' || has_any_column_privilege('$owner', '$schema.product_history', 'INSERT') FROM pg_proc WHERE oid = '$schema.product_history_record()'::regprocedure" \
  "open_products_catalog_history_writer:false"
# Disarmed: a column grant to the owner goes through, but the V5 insert guard still refuses its inserts.
as_owner psql_q -d "$db" -c "SET search_path = $schema" \
  -c "GRANT INSERT (product_id, operation, new_row, changed_by, login_role, application_name, transaction_id, changed_at) ON product_history TO $owner"
if as_owner psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SET search_path = $schema" -c "${forge_src_sql//forge_src/forge_col}" 2> "$work/forge_col.err"; then
  echo "FAIL the owner forged history with a column grant" >&2; exit 1
fi
grep -q "only the history trigger" "$work/forge_col.err" || { cat "$work/forge_col.err" >&2; exit 1; }
echo "ok   with a column grant the owner's trigger is still refused by the insert guard"
# Disarmed, the owner can add a child; arm() then refuses until it is gone and relhassubclass is cleared.
as_owner psql_q -d "$db" -c "SET search_path = $schema" -c "CREATE TABLE forge_disarmed () INHERITS (product_history)"
if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SELECT fbx_history_guard.arm('rehearsal: child present')" 2> "$work/arm.err"; then
  echo "FAIL arm() armed with a child of product_history" >&2; exit 1
fi
grep -q "cannot arm, $schema.forge_disarmed inherits from $schema.product_history" "$work/arm.err" || { cat "$work/arm.err" >&2; exit 1; }
echo "ok   arm() refuses while a table inherits from product_history"
as_owner psql_q -d "$db" -c "SET search_path = $schema" -c "DROP TABLE forge_disarmed"
if psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "SELECT fbx_history_guard.arm('rehearsal: stale relhassubclass')" 2> "$work/arm.err"; then
  echo "FAIL arm() armed with relhassubclass still set" >&2; exit 1
fi
grep -q "relhassubclass" "$work/arm.err" || { cat "$work/arm.err" >&2; exit 1; }
echo "ok   arm() refuses until relhassubclass is cleared (ANALYZE)"
psql_q -d "$db" -c "ANALYZE $schema.product_history"
# Upgrade path of an armed environment (runbook section 2.3): disarm, re-run the bootstrap, arm.
psql_q -d "$db" -v schema="$schema" -f "$root/db/bootstrap/history-guard.sql" > /dev/null
check "the bootstrap re-runs while disarmed and keeps the guard state" \
  "SELECT fbx_history_guard.verify() || ':' || (SELECT string_agg(action, ',' ORDER BY event_id) FROM fbx_history_guard.event)" "DISARMED:arm,disarm"
psql_q -d "$db" -c "SELECT fbx_history_guard.hand_back_history_writer('rehearsal: migration replaces the recording function')" > /dev/null 2> "$work/handback.err"
grep -q "WARNING:  product_history guard: history writer HANDED BACK" "$work/handback.err" || { cat "$work/handback.err" >&2; exit 1; }
check "hand-back returns the function and INSERT to the owner" \
  "SELECT pg_get_userbyid(proowner) || ':' || has_any_column_privilege('$owner', '$schema.product_history', 'INSERT') FROM pg_proc WHERE oid = '$schema.product_history_record()'::regprocedure" \
  "$owner:true"
as_owner psql_q -d "$db" -c "SET search_path = $schema" -c "COMMENT ON TABLE product_history IS 'Append-only change history of product (break-glass rehearsal)'"
psql_q -d "$db" -c "SELECT fbx_history_guard.arm('rehearsal: re-arm after break-glass')" > /dev/null
check "re-armed guard is intact" "SELECT fbx_history_guard.verify()" "armed, intact"
check "re-arming takes the writer back and clears the owner's column grants" \
  "SELECT pg_get_userbyid(proowner) || ':' || has_any_column_privilege('$owner', '$schema.product_history', 'INSERT') FROM pg_proc WHERE oid = '$schema.product_history_record()'::regprocedure" \
  "open_products_catalog_history_writer:false"
check "every break-glass step is recorded" \
  "SELECT string_agg(action, ',' ORDER BY event_id) FROM fbx_history_guard.event" "arm,disarm,hand_back,arm"
check "the arming log keeps every state" \
  "SELECT string_agg(is_armed::text, ',' ORDER BY armed_id) FROM fbx_history_guard.armed" "true,false,true"
refused "re-armed guard refuses history DDL again" "COMMENT ON TABLE product_history IS 'x'"

echo "--- the admin as a non-superuser (Aurora rds_superuser stand-in) arms the guard"
# On Aurora the admin is not a superuser: it runs the bootstrap, so it owns the
# guard's functions and tables, and it created the owner and writer roles, so it
# holds ADMIN OPTION on them (PG16: INHERIT FALSE, SET FALSE). Vanilla
# PostgreSQL keeps event triggers superuser-owned; they call the admin's functions.
psql_q -d postgres -v admin="$admin" -v secret="$admin_secret" <<'SQL'
CREATE ROLE :"admin" LOGIN CREATEROLE NOSUPERUSER PASSWORD :'secret';
GRANT open_products_catalog_owner TO :"admin" WITH ADMIN OPTION, INHERIT FALSE, SET FALSE;
GRANT open_products_catalog_history_writer TO :"admin" WITH ADMIN OPTION, INHERIT FALSE, SET FALSE;
SQL
psql_q -d "$db" -v admin="$admin" <<'SQL'
GRANT CONNECT, CREATE ON DATABASE of_open_products_rehearsal TO :"admin";
SELECT fbx_history_guard.disarm('rehearsal: hand the guard to a non-superuser admin') IS NOT NULL AS disarmed \gset
SELECT set_config('fbx.rehearsal_admin', :'admin', false) IS NOT NULL AS ok \gset
DO $$
DECLARE
    adm text := current_setting('fbx.rehearsal_admin');
    o record;
BEGIN
    EXECUTE format('ALTER SCHEMA fbx_history_guard OWNER TO %I', adm);
    FOR o IN SELECT c.oid::regclass AS rel FROM pg_class c
              WHERE c.relnamespace = 'fbx_history_guard'::regnamespace AND c.relkind = 'r' LOOP
        EXECUTE format('ALTER TABLE %s OWNER TO %I', o.rel, adm);
    END LOOP;
    FOR o IN SELECT p.oid::regprocedure AS fn FROM pg_proc p WHERE p.pronamespace = 'fbx_history_guard'::regnamespace LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO %I', o.fn, adm);
    END LOOP;
END
$$;
SQL
# hand-back and arm both move product_history_record() between owner and writer as the admin.
as_admin psql_q -d "$db" -c "SELECT fbx_history_guard.hand_back_history_writer('rehearsal: non-superuser hand-back')" > /dev/null 2> "$work/admin.err" \
  || { cat "$work/admin.err" >&2; exit 1; }
check "the non-superuser admin handed the recording function back" \
  "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = '$schema.product_history_record()'::regprocedure" "$owner"
as_admin psql_q -d "$db" -c "SELECT fbx_history_guard.arm('rehearsal: non-superuser admin arms')" > /dev/null 2> "$work/admin.err" \
  || { cat "$work/admin.err" >&2; exit 1; }
check "the non-superuser admin armed the guard" "SELECT fbx_history_guard.verify()" "armed, intact"
check "arm() moved the recording function to the writer" \
  "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = '$schema.product_history_record()'::regprocedure" "$writer"
# Review probe (round 5): set_history_writer() made the admin a SET-capable
# member of the writer and left it so; the admin could then write history
# rows as the writer from a trigger on any table, and verify() stayed intact.
admin_forge_sql="CREATE SCHEMA IF NOT EXISTS admin_forge;
GRANT USAGE ON SCHEMA admin_forge TO $writer;
CREATE TABLE admin_forge.src (id int);
GRANT INSERT ON admin_forge.src TO $writer;
CREATE FUNCTION admin_forge.forge() RETURNS trigger LANGUAGE plpgsql AS \$f\$
BEGIN
  INSERT INTO $schema.product_history ($history_cols) VALUES ('FORGED-ADMIN', 'INSERT', '{}', 'x', 'x', 'x', 0, now());
  RETURN NULL;
END \$f\$;
CREATE TRIGGER trg_forge AFTER INSERT ON admin_forge.src FOR EACH ROW EXECUTE FUNCTION admin_forge.forge();
SET ROLE $writer;
INSERT INTO admin_forge.src VALUES (1);"
if as_admin psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "$admin_forge_sql" 2> "$work/admin_forge.err"; then
  echo "FAIL review probe: the admin wrote a history row as the history writer after arm()" >&2; exit 1
fi
grep -q "permission denied to set role \"$writer\"" "$work/admin_forge.err" || { cat "$work/admin_forge.err" >&2; exit 1; }
echo "ok   review probe: after arm() the admin cannot act as the history writer"
check "no forged admin row reached the history" "SELECT count(*) FROM $schema.product_history WHERE product_id = 'FORGED-ADMIN'" "0"
check "the writer has no INHERIT or SET member after arm()" \
  "SELECT count(*) FROM pg_auth_members WHERE roleid = '$writer'::regrole AND (inherit_option OR set_option)" "0"
check "the admin keeps only ADMIN OPTION on the owner and the writer" \
  "SELECT string_agg(roleid::regrole || ':' || admin_option || ':' || inherit_option || ':' || set_option, ',' ORDER BY roleid::regrole::text) FROM pg_auth_members WHERE member = '$admin'::regrole" \
  "$owner:true:false:false,$writer:true:false:false"
# ADMIN OPTION lets the admin grant itself the writer again: not prevented, but verify() reports it.
as_admin psql_q -d "$db" -c "GRANT $writer TO $admin WITH INHERIT FALSE, SET TRUE"
check "the admin re-granting itself the writer is reported" "SELECT fbx_history_guard.verify()" "CHANGED SINCE ARMED"
as_admin psql_q -d "$db" -c "REVOKE $writer FROM $admin"
check "guard intact again once the admin's grant is gone" "SELECT fbx_history_guard.verify()" "armed, intact"

psql_q -d postgres -c "DROP DATABASE $db"
echo "Migration, seed and import rehearsal passed."
