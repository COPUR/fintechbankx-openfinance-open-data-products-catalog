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
#   8. checks the role privileges and the append-only product_history.
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
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Throwaway credentials for this run only.
owner_secret="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
app_secret="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
import_secret="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
as_owner() { PGUSER="$owner" PGPASSWORD="$owner_secret" "$@"; }
as_app() { PGUSER="$app" PGPASSWORD="$app_secret" "$@"; }
as_importer() { PGUSER="$importer" PGPASSWORD="$import_secret" IMPORT_OPERATOR=rehearsal "$@"; }
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

# What Flyway does at deploy time (create-schemas, default-schema), as the owner.
as_owner psql_q -d "$db" -c "CREATE SCHEMA $schema"
for migration in "$root"/src/main/resources/db/migration/V*.sql; do
  echo "--- migration $(basename "$migration") as $owner"
  PGOPTIONS="-c search_path=$schema" as_owner psql_q -d "$db" -f "$migration"
done

for run in 1 2; do
  echo "--- seed run $run"
  PGOPTIONS="-c search_path=$schema" as_owner psql_q -d "$db" -f "$root/src/main/resources/db/seed/afterMigrate__sample_products.sql"
done
check "seed loads four SAMPLE- products at version 0" \
  "SELECT count(*) || ' ' || max(version) FROM $schema.product WHERE product_id LIKE 'SAMPLE-%'" "4 0"

psql_q -d "$db" -c "TRUNCATE $schema.product"

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

if IMPORT_OPERATOR=rehearsal as_owner "$root/db/import/import-products.sh" "dbname=$db" "$root/db/import/products.example.csv" 2> "$work/owner.err"; then
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
denied "history rejects updates even from the owner" as_owner "UPDATE product_history SET changed_by = 'x'"
denied "history rejects deletes even from the owner" as_owner "DELETE FROM product_history"
check "every import change is in the history with role and operator" \
  "SELECT count(*) || ' ' || string_agg(DISTINCT changed_by || '/' || application_name, ',') FROM $schema.product_history WHERE product_id = 'SME-PCA-01' AND application_name LIKE 'import-products/%'" \
  "3 $importer/import-products/rehearsal"
check "the history keeps old and new values of each update" \
  "SELECT string_agg((old_row->>'monthly_fee_amount') || '->' || (new_row->>'monthly_fee_amount'), ',' ORDER BY history_id) FROM $schema.product_history WHERE product_id = 'SME-PCA-01' AND operation = 'UPDATE'" \
  "35.00->30.00,30.00->25.00"

psql_q -d postgres -c "DROP DATABASE $db"
echo "Migration, seed and import rehearsal passed."
