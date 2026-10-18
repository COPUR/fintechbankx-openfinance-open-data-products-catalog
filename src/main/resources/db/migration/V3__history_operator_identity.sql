-- svc-of-open-products-catalog: attribute catalogue imports to an AWS principal.
-- Additive: V1 and V2 are unchanged (Flyway checksums).
--
-- The import role is one credential (<env>/open-products-catalog-service/db-import)
-- shared by every operator, and application_name ("import-products/<operator>")
-- is whatever the operator typed. import-products.sh now asks STS for the
-- caller's identity (aws sts get-caller-identity) and sets it for the
-- transaction as fbx.operator_arn; the history trigger records it in
-- operator_arn and refuses any change made as the import role without one.
--
-- This makes bypassing the script deliberate, not accidental: whoever holds
-- the import password can still set any ARN-shaped value by hand. The ARN is
-- corroborated outside the database by CloudTrail, which logs every
-- GetSecretValue on db-import with the IAM principal and time (ADR-0001,
-- residual risk).

ALTER TABLE product_history ADD COLUMN operator_arn TEXT;

COMMENT ON COLUMN product_history.operator_arn IS
    'AWS caller identity (STS ARN) of the operator who ran import-products.sh; NULL for owner or seed changes and rows before V3';

CREATE OR REPLACE FUNCTION product_history_record() RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    caller text := coalesce(nullif(current_setting('role'), 'none'), session_user);
    operator_arn text := nullif(current_setting('fbx.operator_arn', true), '');
BEGIN
    IF 'open_products_catalog_import' IN (caller, session_user::text)
       AND (operator_arn IS NULL
            OR operator_arn !~ '^arn:aws[a-z-]*:(sts|iam)::[0-9]{12}:(assumed-role|user|federated-user)/[A-Za-z0-9+=,.@_/-]+$') THEN
        RAISE EXCEPTION 'changes as open_products_catalog_import must record the operator''s AWS caller identity (fbx.operator_arn); run db/import/import-products.sh';
    END IF;
    EXECUTE format(
        'INSERT INTO %I.product_history (product_id, operation, old_row, new_row, changed_by, login_role,'
        || ' application_name, transaction_id, changed_at, operator_arn) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)',
        TG_TABLE_SCHEMA)
    USING NEW.product_id, TG_OP,
          CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) END, to_jsonb(NEW),
          caller, session_user::text, current_setting('application_name'),
          txid_current(), clock_timestamp(), operator_arn;
    RETURN NULL;
END
$$;

REVOKE ALL ON FUNCTION product_history_record() FROM PUBLIC;
