-- Sample catalogue for dev and CI only. Flyway reads this location only when
-- OPEN_PRODUCTS_SEED_ENABLED=true; staging and production load the real
-- catalogue with db/import/import-products.sh.
-- An afterMigrate callback, not a migration: it runs after every migrate and
-- leaves no flyway_schema_history row, so turning the seed off later keeps the
-- schema history valid. Idempotent upsert: a re-run changes only rows whose
-- values below differ.

INSERT INTO product (product_id, product_type, segment, name, currency,
                     monthly_fee_amount, monthly_fee_currency, annual_rate_percent,
                     status, effective_from, updated_at)
VALUES
    ('PCA-001',     'PCA',     'RETAIL', 'Everyday Current', 'AED',  0.00, 'AED', 0.00, 'ACTIVE', '2026-03-01T00:00:00Z', '2026-03-01T00:00:00Z'),
    ('SAV-001',     'SAVINGS', 'RETAIL', 'Smart Saver',      'AED',  0.00, 'AED', 1.25, 'ACTIVE', '2026-03-02T00:00:00Z', '2026-03-02T00:00:00Z'),
    ('SME-LOAN-01', 'LOAN',    'SME',    'SME Growth Loan',  'AED',  0.00, 'AED', 6.75, 'ACTIVE', '2026-03-03T00:00:00Z', '2026-03-03T00:00:00Z'),
    ('SME-PCA-01',  'PCA',     'SME',    'SME Current',      'AED', 35.00, 'AED', 0.00, 'ACTIVE', '2026-03-04T00:00:00Z', '2026-03-04T00:00:00Z')
ON CONFLICT (product_id) DO UPDATE SET
    product_type         = EXCLUDED.product_type,
    segment              = EXCLUDED.segment,
    name                 = EXCLUDED.name,
    currency             = EXCLUDED.currency,
    monthly_fee_amount   = EXCLUDED.monthly_fee_amount,
    monthly_fee_currency = EXCLUDED.monthly_fee_currency,
    annual_rate_percent  = EXCLUDED.annual_rate_percent,
    status               = EXCLUDED.status,
    effective_from       = EXCLUDED.effective_from,
    updated_at           = EXCLUDED.updated_at,
    version              = product.version + 1
WHERE (product.product_type, product.segment, product.name, product.currency,
       product.monthly_fee_amount, product.annual_rate_percent, product.status,
       product.effective_from, product.updated_at)
      IS DISTINCT FROM
      (EXCLUDED.product_type, EXCLUDED.segment, EXCLUDED.name, EXCLUDED.currency,
       EXCLUDED.monthly_fee_amount, EXCLUDED.annual_rate_percent, EXCLUDED.status,
       EXCLUDED.effective_from, EXCLUDED.updated_at);
