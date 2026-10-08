#!/usr/bin/env bash
# Loads the product catalogue from a CSV into svc-of-open-products-catalog's
# own database (sc_of_open_products_catalog.product). Idempotent upsert:
#   - new product_id            -> inserted (version 0)
#   - existing, values changed  -> updated, updated_at = now(), version + 1
#   - existing, values the same -> untouched (ETag stays stable)
# Ids starting with SAMPLE- are reserved for the dev/CI seed and rejected.
# Products missing from the CSV are left as they are; withdraw a product by
# importing it with status WITHDRAWN (or an effective_to), never by deleting.
# The whole file is applied in one transaction: any bad row aborts the import.
#
#   db/import/import-products.sh <conninfo> <products.csv>
#
# Example conninfo: "host=<aurora-writer> dbname=db_of_open_products_catalog_prod user=open_products_catalog_app sslmode=require".
# Passwords come from PGPASSWORD or ~/.pgpass, never from arguments.
# CSV header (see products.example.csv):
#   product_id,product_type,segment,name,description,currency,monthly_fee_amount,
#   annual_rate_percent,eligibility,status,effective_from,effective_to
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <conninfo> <products.csv>" >&2
  exit 2
fi

target_db="$1"
csv="$2"
schema="${OPEN_PRODUCTS_SCHEMA:-sc_of_open_products_catalog}"

if [ ! -r "$csv" ]; then
  echo "cannot read $csv" >&2
  exit 2
fi
if ! [[ "$schema" =~ ^[a-z_][a-z0-9_]*$ ]]; then
  echo "invalid schema name '$schema'" >&2
  exit 2
fi
expected_header="product_id,product_type,segment,name,description,currency,monthly_fee_amount,annual_rate_percent,eligibility,status,effective_from,effective_to"
if [ "$(head -n 1 "$csv" | tr -d '\r')" != "$expected_header" ]; then
  echo "unexpected CSV header; expected: $expected_header" >&2
  exit 2
fi

# psql reads the CSV client-side (\copy), so the file never has to be on the DB host.
csv_literal="${csv//\'/\'\'}"
psql -X -q -v ON_ERROR_STOP=1 "$target_db" <<SQL
\set QUIET on
BEGIN;
SET LOCAL search_path = $schema;

CREATE TEMP TABLE product_import (
    product_id          text,
    product_type        text,
    segment             text,
    name                text,
    description         text,
    currency            text,
    monthly_fee_amount  numeric,
    annual_rate_percent numeric,
    eligibility         text,
    status              text,
    effective_from      timestamptz,
    effective_to        timestamptz
) ON COMMIT DROP;

\copy product_import FROM '$csv_literal' WITH (FORMAT csv, HEADER true)

-- Codes are stored upper-case (filters match case-insensitively); blanks become NULL.
UPDATE product_import SET
    product_id   = btrim(product_id),
    product_type = upper(btrim(product_type)),
    segment      = upper(btrim(segment)),
    name         = btrim(name),
    description  = nullif(btrim(description), ''),
    currency     = upper(btrim(currency)),
    eligibility  = nullif(btrim(eligibility), ''),
    status       = upper(btrim(coalesce(nullif(status, ''), 'ACTIVE')));

DO \$\$
DECLARE
    dup text;
BEGIN
    SELECT string_agg(product_id, ', ') INTO dup
      FROM (SELECT product_id FROM product_import GROUP BY product_id HAVING count(*) > 1) d;
    IF dup IS NOT NULL THEN
        RAISE EXCEPTION 'duplicate product_id in CSV: %', dup;
    END IF;
    -- SAMPLE- ids belong to the dev/CI seed; the real catalogue never uses them.
    SELECT string_agg(product_id, ', ') INTO dup
      FROM product_import
     WHERE upper(product_id) LIKE 'SAMPLE-%';
    IF dup IS NOT NULL THEN
        RAISE EXCEPTION 'product_id in the reserved SAMPLE- namespace: %', dup;
    END IF;
    -- Money is never rounded on import: more than two decimals is an error.
    SELECT string_agg(product_id, ', ') INTO dup
      FROM product_import
     WHERE scale(monthly_fee_amount) > 2 OR scale(annual_rate_percent) > 2;
    IF dup IS NOT NULL THEN
        RAISE EXCEPTION 'amounts with more than two decimals for: %', dup;
    END IF;
END
\$\$;

-- Table CHECK constraints validate codes, currency, amounts, status and dates.
WITH upserted AS (
    INSERT INTO product AS p (product_id, product_type, segment, name, description, currency,
                              monthly_fee_amount, monthly_fee_currency, annual_rate_percent,
                              eligibility, status, effective_from, effective_to, updated_at)
    SELECT product_id, product_type, segment, name, description, currency,
           monthly_fee_amount, currency, annual_rate_percent,
           eligibility, status, effective_from, effective_to, now()
      FROM product_import
    ON CONFLICT (product_id) DO UPDATE SET
        product_type         = EXCLUDED.product_type,
        segment              = EXCLUDED.segment,
        name                 = EXCLUDED.name,
        description          = EXCLUDED.description,
        currency             = EXCLUDED.currency,
        monthly_fee_amount   = EXCLUDED.monthly_fee_amount,
        monthly_fee_currency = EXCLUDED.monthly_fee_currency,
        annual_rate_percent  = EXCLUDED.annual_rate_percent,
        eligibility          = EXCLUDED.eligibility,
        status               = EXCLUDED.status,
        effective_from       = EXCLUDED.effective_from,
        effective_to         = EXCLUDED.effective_to,
        updated_at           = now(),
        version              = p.version + 1
    WHERE (p.product_type, p.segment, p.name, p.description, p.currency, p.monthly_fee_amount,
           p.annual_rate_percent, p.eligibility, p.status, p.effective_from, p.effective_to)
          IS DISTINCT FROM
          (EXCLUDED.product_type, EXCLUDED.segment, EXCLUDED.name, EXCLUDED.description, EXCLUDED.currency,
           EXCLUDED.monthly_fee_amount, EXCLUDED.annual_rate_percent, EXCLUDED.eligibility, EXCLUDED.status,
           EXCLUDED.effective_from, EXCLUDED.effective_to)
    RETURNING (xmax = 0) AS inserted
)
SELECT format('rows in file: %s, inserted: %s, updated: %s, unchanged: %s',
              (SELECT count(*) FROM product_import),
              count(*) FILTER (WHERE inserted),
              count(*) FILTER (WHERE NOT inserted),
              (SELECT count(*) FROM product_import) - count(*)) AS import_summary
  FROM upserted \gset
\echo :import_summary
COMMIT;
SQL
