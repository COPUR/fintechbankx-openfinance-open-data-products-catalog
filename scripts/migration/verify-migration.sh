#!/usr/bin/env bash
# Rehearses svc-of-open-products-catalog's data path on a scratch PostgreSQL:
#   1. applies the Flyway schema migration(s) to a fresh database,
#   2. applies the dev/CI seed callback twice (idempotent),
#   3. imports db/import/products.example.csv twice (second run changes nothing),
#   4. imports a changed CSV (one product updated, version and updated_at move),
#   5. checks a bad CSV is rejected as a whole.
# There is no monolith data to backfill (ADR-0001), so there is no source DB.
#
# Needs psql and a role that can create databases, via the usual PG* env vars
# (PGHOST, PGPORT, PGUSER, PGPASSWORD).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
db="of_open_products_rehearsal"
schema="sc_of_open_products_catalog"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

psql_q -d postgres -c "DROP DATABASE IF EXISTS $db" -c "CREATE DATABASE $db"
psql_q -d "$db" -c "CREATE SCHEMA $schema"
for migration in "$root"/src/main/resources/db/migration/V*.sql; do
  echo "--- migration $(basename "$migration")"
  PGOPTIONS="-c search_path=$schema" psql_q -d "$db" -f "$migration"
done

check() {
  local label="$1" sql="$2" expected="$3" actual
  actual="$(psql -X -At -d "$db" -c "$sql")"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL $label: expected '$expected', got '$actual'" >&2
    exit 1
  fi
  echo "ok   $label"
}

for run in 1 2; do
  echo "--- seed run $run"
  PGOPTIONS="-c search_path=$schema" psql_q -d "$db" -f "$root/src/main/resources/db/seed/afterMigrate__sample_products.sql"
done
check "seed loads four sample products at version 0" \
  "SELECT count(*) || ' ' || max(version) FROM $schema.product" "4 0"

psql_q -d "$db" -c "TRUNCATE $schema.product"

for run in 1 2; do
  echo "--- import run $run"
  "$root/db/import/import-products.sh" "dbname=$db" "$root/db/import/products.example.csv" | tee "$work/import-$run.log"
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
"$root/db/import/import-products.sh" "dbname=$db" "$work/changed.csv" | tee "$work/import-3.log"
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
if "$root/db/import/import-products.sh" "dbname=$db" "$work/bad.csv" 2> "$work/bad.err"; then
  echo "FAIL import accepted an amount with three decimals" >&2
  exit 1
fi
grep -q "more than two decimals" "$work/bad.err" || { cat "$work/bad.err" >&2; exit 1; }
check "a rejected file changes nothing" "SELECT count(*) FROM $schema.product WHERE product_id = 'NEW-001'" "0"

psql_q -d postgres -c "DROP DATABASE $db"
echo "Migration, seed and import rehearsal passed."
