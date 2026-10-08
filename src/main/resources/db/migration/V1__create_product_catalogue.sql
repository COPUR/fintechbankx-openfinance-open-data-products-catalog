-- svc-of-open-products-catalog: the product catalogue (ADR-0001).
-- PostgreSQL is the authority; rows are loaded by db/import/import-products.sh
-- (dev/CI may add the sample rows from classpath:db/seed).
-- Runs in schema sc_of_open_products_catalog (Flyway default-schema).

CREATE TABLE product (
    product_id           VARCHAR(64)   NOT NULL,
    product_type         VARCHAR(30)   NOT NULL,
    segment              VARCHAR(30)   NOT NULL,
    name                 VARCHAR(200)  NOT NULL,
    description          VARCHAR(2000),
    currency             VARCHAR(3)    NOT NULL,
    -- Money: amount + currency. The fee currency must equal the product currency.
    monthly_fee_amount   NUMERIC(19,2) NOT NULL,
    monthly_fee_currency VARCHAR(3)    NOT NULL,
    -- Nominal annual rate in percent (6.75 = 6.75 %).
    annual_rate_percent  NUMERIC(7,2)  NOT NULL,
    -- Free-text eligibility criteria as published by the product owner.
    eligibility          VARCHAR(2000),
    status               VARCHAR(16)   NOT NULL,
    effective_from       TIMESTAMPTZ   NOT NULL,
    effective_to         TIMESTAMPTZ,
    created_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),
    version              BIGINT        NOT NULL DEFAULT 0,
    CONSTRAINT pk_product PRIMARY KEY (product_id),
    CONSTRAINT ck_product_id CHECK (product_id ~ '^[A-Za-z0-9_-]{1,64}$'),
    -- Filters are matched case-insensitively by upper-casing the query, so codes are stored upper-case.
    CONSTRAINT ck_product_type CHECK (product_type ~ '^[A-Z0-9_-]{2,30}$'),
    CONSTRAINT ck_product_segment CHECK (segment ~ '^[A-Z0-9_-]{2,30}$'),
    CONSTRAINT ck_product_name CHECK (btrim(name) <> ''),
    CONSTRAINT ck_product_currency CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT ck_product_fee_currency CHECK (monthly_fee_currency = currency),
    CONSTRAINT ck_product_fee_amount CHECK (monthly_fee_amount >= 0),
    CONSTRAINT ck_product_rate CHECK (annual_rate_percent >= 0),
    CONSTRAINT ck_product_status CHECK (status IN ('DRAFT', 'ACTIVE', 'WITHDRAWN')),
    CONSTRAINT ck_product_effective CHECK (effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT ck_product_version CHECK (version >= 0)
);

COMMENT ON TABLE product IS 'Open Finance product catalogue; authority for svc-of-open-products-catalog';

-- GET /open-finance/v1/products only reads ACTIVE rows, filtered by type and/or
-- segment and ordered by product_id; partial indexes keep drafts and withdrawn
-- products out of the scanned set.
CREATE INDEX ix_product_active_type_segment
    ON product (product_type, segment, product_id)
    WHERE status = 'ACTIVE';

CREATE INDEX ix_product_active_segment
    ON product (segment, product_id)
    WHERE status = 'ACTIVE';
