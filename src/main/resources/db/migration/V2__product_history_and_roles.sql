-- svc-of-open-products-catalog: audit trail and least-privilege grants (ADR-0001).
-- Additive: V1 is unchanged.
--
-- product_history is append-only: an AFTER INSERT OR UPDATE trigger on product
-- writes one row per change with the old and new values, the database role
-- that made the change, its application_name (import-products.sh sets it to
-- the operator) and the time. No role is granted any privilege on it; the
-- trigger function runs as the schema owner, and UPDATE, DELETE and TRUNCATE
-- on the history are rejected by triggers, also for the owner.
--
-- Roles (created by the DBA bootstrap in docs/migration before the first
-- deploy; see the runbook):
--   open_products_catalog_owner   owns the schema, runs Flyway only
--   open_products_catalog_app     runtime: SELECT on product, nothing else
--   open_products_catalog_import  import-products.sh: SELECT, INSERT, UPDATE on product
--                                 (SELECT because ON CONFLICT ... WHERE and the
--                                 full-import withdrawal read existing rows); no DELETE
-- Grants are skipped for a role that does not exist (local and CI databases).

CREATE TABLE product_history (
    history_id       BIGINT       GENERATED ALWAYS AS IDENTITY,
    product_id       VARCHAR(64)  NOT NULL,
    operation        VARCHAR(6)   NOT NULL,
    old_row          JSONB,
    new_row          JSONB        NOT NULL,
    changed_by       TEXT         NOT NULL,
    login_role       TEXT         NOT NULL,
    application_name TEXT         NOT NULL,
    transaction_id   BIGINT       NOT NULL,
    changed_at       TIMESTAMPTZ  NOT NULL,
    CONSTRAINT pk_product_history PRIMARY KEY (history_id),
    CONSTRAINT ck_product_history_operation CHECK (operation IN ('INSERT', 'UPDATE')),
    CONSTRAINT ck_product_history_old_row CHECK ((operation = 'INSERT') = (old_row IS NULL))
);

COMMENT ON TABLE product_history IS 'Append-only change history of product, written by trg_product_history';
COMMENT ON COLUMN product_history.changed_by IS 'Role that made the change (current_user of the writing session)';
COMMENT ON COLUMN product_history.login_role IS 'Role the session logged in as (session_user)';

CREATE INDEX ix_product_history_product ON product_history (product_id, history_id);

-- SECURITY DEFINER so that only this function can write the history. Inside it
-- current_user is the owner, so the caller's current_user is rebuilt from the
-- session's role setting (SET ROLE) and falls back to session_user.
CREATE FUNCTION product_history_record() RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    caller text := coalesce(nullif(current_setting('role'), 'none'), session_user);
BEGIN
    EXECUTE format(
        'INSERT INTO %I.product_history (product_id, operation, old_row, new_row, changed_by, login_role,'
        || ' application_name, transaction_id, changed_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)',
        TG_TABLE_SCHEMA)
    USING NEW.product_id, TG_OP,
          CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) END, to_jsonb(NEW),
          caller, session_user::text, current_setting('application_name'),
          txid_current(), clock_timestamp();
    RETURN NULL;
END
$$;

CREATE TRIGGER trg_product_history
    AFTER INSERT OR UPDATE ON product
    FOR EACH ROW EXECUTE FUNCTION product_history_record();

CREATE FUNCTION product_history_append_only() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'product_history is append-only (% rejected)', TG_OP;
END
$$;

CREATE TRIGGER trg_product_history_no_change
    BEFORE UPDATE OR DELETE ON product_history
    FOR EACH ROW EXECUTE FUNCTION product_history_append_only();

CREATE TRIGGER trg_product_history_no_truncate
    BEFORE TRUNCATE ON product_history
    FOR EACH STATEMENT EXECUTE FUNCTION product_history_append_only();

REVOKE ALL ON product_history FROM PUBLIC;
REVOKE ALL ON FUNCTION product_history_record() FROM PUBLIC;
REVOKE ALL ON FUNCTION product_history_append_only() FROM PUBLIC;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'open_products_catalog_app') THEN
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO open_products_catalog_app', current_schema());
        GRANT SELECT ON product TO open_products_catalog_app;
    ELSE
        RAISE NOTICE 'role open_products_catalog_app does not exist; runtime grants skipped';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'open_products_catalog_import') THEN
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO open_products_catalog_import', current_schema());
        GRANT SELECT, INSERT, UPDATE ON product TO open_products_catalog_import;
    ELSE
        RAISE NOTICE 'role open_products_catalog_import does not exist; import grants skipped';
    END IF;
END
$$;
