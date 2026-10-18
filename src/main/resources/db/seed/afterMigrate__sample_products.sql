-- Sample catalogue for dev and CI only. Flyway reads this location only when
-- OPEN_PRODUCTS_SEED_ENABLED=true; staging and production load the real
-- catalogue with db/import/import-products.sh.
-- An afterMigrate callback, not a migration: it runs after every migrate and
-- leaves no flyway_schema_history row, so turning the seed off later keeps the
-- schema history valid.
-- Insert-only, with ids in the SAMPLE- namespace that import-products.sh
-- refuses: the seed can never overwrite or revert an imported product, and an
-- existing sample row is left exactly as it is.

INSERT INTO product (product_id, product_type, segment, name, currency,
                     monthly_fee_amount, monthly_fee_currency, annual_rate_percent,
                     status, effective_from, updated_at)
VALUES
    ('SAMPLE-PCA-001',     'PCA',     'RETAIL', 'Everyday Current', 'AED',  0.00, 'AED', 0.00, 'ACTIVE', '2026-03-01T00:00:00Z', '2026-03-01T00:00:00Z'),
    ('SAMPLE-SAV-001',     'SAVINGS', 'RETAIL', 'Smart Saver',      'AED',  0.00, 'AED', 1.25, 'ACTIVE', '2026-03-02T00:00:00Z', '2026-03-02T00:00:00Z'),
    ('SAMPLE-SME-LOAN-01', 'LOAN',    'SME',    'SME Growth Loan',  'AED',  0.00, 'AED', 6.75, 'ACTIVE', '2026-03-03T00:00:00Z', '2026-03-03T00:00:00Z'),
    ('SAMPLE-SME-PCA-01',  'PCA',     'SME',    'SME Current',      'AED', 35.00, 'AED', 0.00, 'ACTIVE', '2026-03-04T00:00:00Z', '2026-03-04T00:00:00Z')
ON CONFLICT (product_id) DO NOTHING;
