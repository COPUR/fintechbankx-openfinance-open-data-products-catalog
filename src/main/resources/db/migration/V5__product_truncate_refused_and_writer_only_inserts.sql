-- svc-of-open-products-catalog: no history-free removal of products, and only
-- the history writer may insert history rows. Additive: V1-V4 are unchanged.
--
-- 1. trg_product_no_truncate (BEFORE TRUNCATE on product) refuses TRUNCATE for
--    every role, the owner and the admin included: TRUNCATE fires no row
--    triggers, so it would remove products without a DELETE row in
--    product_history. Delete rows instead; each removal is recorded (V4).
-- 2. product_history_insert_guard() also requires the inserting role to be the
--    owner of product_history_record(): the history writer
--    (open_products_catalog_history_writer) once the history guard is armed,
--    the schema owner before that (local, CI, first deploy). A trigger the
--    owner adds to any other table runs as the owner and is refused, even if
--    INSERT on product_history were granted back to it.
-- 3. The history triggers fire ALWAYS, also under session_replication_role =
--    replica, which a superuser (or rds_superuser) can set without any DDL.
--
-- An environment whose history guard is already armed applies this under the
-- admin's break-glass (runbook section 2.3): disarm, deploy, arm. It does not
-- need product_history_record() back.

CREATE FUNCTION product_truncate_refused() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'product: TRUNCATE is refused because product_history is append-only and must record every removal; delete the rows instead';
END
$$;

CREATE TRIGGER trg_product_no_truncate
    BEFORE TRUNCATE ON product
    FOR EACH STATEMENT EXECUTE FUNCTION product_truncate_refused();

CREATE OR REPLACE FUNCTION product_history_insert_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    writer name := (SELECT pg_get_userbyid(p.proowner) FROM pg_proc p
                     WHERE p.oid = to_regprocedure(format('%I.product_history_record()', TG_TABLE_SCHEMA)));
BEGIN
    IF pg_trigger_depth() < 2 OR current_user IS DISTINCT FROM writer THEN
        RAISE EXCEPTION 'product_history: only the history trigger on product may write it (% as % refused)', TG_OP, current_user;
    END IF;
    RETURN NEW;
END
$$;

ALTER TABLE product ENABLE ALWAYS TRIGGER trg_product_history;
ALTER TABLE product ENABLE ALWAYS TRIGGER trg_product_history_delete;
ALTER TABLE product ENABLE ALWAYS TRIGGER trg_product_no_truncate;
ALTER TABLE product_history ENABLE ALWAYS TRIGGER trg_product_history_no_change;
ALTER TABLE product_history ENABLE ALWAYS TRIGGER trg_product_history_no_truncate;
ALTER TABLE product_history ENABLE ALWAYS TRIGGER trg_product_history_insert_guard;

REVOKE ALL ON FUNCTION product_truncate_refused() FROM PUBLIC;
REVOKE ALL ON FUNCTION product_history_insert_guard() FROM PUBLIC;
