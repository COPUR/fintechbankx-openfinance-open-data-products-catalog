-- svc-of-open-products-catalog: the history can be written only by its
-- trigger, and deleting a product is recorded. Additive: V1-V3 are unchanged.
--
-- 1. trg_product_history_insert_guard (BEFORE INSERT on product_history)
--    refuses any insert that does not come from a trigger on product
--    (pg_trigger_depth() < 2): a direct INSERT, INSERT ... SELECT, COPY or a
--    rule, by any role including the schema owner. The history guard
--    (db/bootstrap/history-guard.sql) refuses new triggers on product while
--    armed, so the only trigger on product that can write the history is
--    product_history_record.
-- 2. trg_product_history_delete (AFTER DELETE on product) writes a DELETE row
--    with the old values and no new_row. No runtime or import role may delete
--    products; this records a delete by the owner or an admin.
--
-- An environment whose history guard is already armed applies this under the
-- admin's break-glass (runbook section 2.3).

ALTER TABLE product_history DROP CONSTRAINT ck_product_history_operation;
ALTER TABLE product_history ADD CONSTRAINT ck_product_history_operation
    CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE'));
ALTER TABLE product_history ALTER COLUMN new_row DROP NOT NULL;
ALTER TABLE product_history ADD CONSTRAINT ck_product_history_new_row
    CHECK ((operation = 'DELETE') = (new_row IS NULL));

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
    USING CASE WHEN TG_OP = 'DELETE' THEN OLD.product_id ELSE NEW.product_id END, TG_OP,
          CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END,
          caller, session_user::text, current_setting('application_name'),
          txid_current(), clock_timestamp(), operator_arn;
    RETURN NULL;
END
$$;

CREATE TRIGGER trg_product_history_delete
    AFTER DELETE ON product
    FOR EACH ROW EXECUTE FUNCTION product_history_record();

CREATE FUNCTION product_history_insert_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION 'product_history: only the history trigger on product may write it (direct % refused)', TG_OP;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_product_history_insert_guard
    BEFORE INSERT ON product_history
    FOR EACH ROW EXECUTE FUNCTION product_history_insert_guard();

REVOKE ALL ON FUNCTION product_history_record() FROM PUBLIC;
REVOKE ALL ON FUNCTION product_history_insert_guard() FROM PUBLIC;
