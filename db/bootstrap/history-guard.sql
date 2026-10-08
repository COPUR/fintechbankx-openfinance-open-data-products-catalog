-- svc-of-open-products-catalog: guard for the append-only product_history.
--
-- Run by the DBA as the cluster admin (open_products_admin, rds_superuser),
-- connected to db_of_open_products_catalog_<env>, in the bootstrap (runbook
-- section 2.2, step 2). Not a Flyway migration on purpose: Flyway runs as the
-- schema owner, and the guard exists to stop the schema owner.
--
-- V2's triggers stop the runtime and import roles. The schema owner owns the
-- table and the trigger functions, so on its own it could disable or drop the
-- triggers, replace a function, drop or rename the table. An event trigger
-- owned by the admin refuses that: once armed, any DDL in the database that
--   - targets product_history, product_history_record(),
--     product_history_append_only() or product_history_insert_guard() (V4), or
--     drops one of them or a user trigger on product or product_history
--     (pg_event_trigger_ddl_commands / pg_event_trigger_dropped_objects), or
--   - adds a trigger on product or product_history (only the history trigger
--     on product may write the history, V4), or
--   - leaves the history's triggers, functions, columns or rules different
--     from the state recorded at arming (tgenabled, md5(prosrc), SECURITY
--     DEFINER, search_path, owner, ...),
-- raises an exception and the whole statement rolls back. The check is on
-- the resulting catalog state, so spelling, case and DDL built inside
-- DO/EXECUTE make no difference. Only a superuser (the admin) can alter or
-- drop an event trigger; the schema owner has no privilege on this schema.
--
-- Break-glass (runbook section 2.3), admin only, both recorded in
-- fbx_history_guard.event:
--   SELECT fbx_history_guard.disarm('<change ticket>');  -- before a migration that changes the history
--   SELECT fbx_history_guard.arm('<change ticket>');     -- after it: records the new state
-- Status, for anyone: SELECT fbx_history_guard.verify();
--
-- Idempotent: safe to run again (the arming state is kept).
\set ON_ERROR_STOP on
\if :{?schema}
\else
\set schema sc_of_open_products_catalog
\endif

CREATE SCHEMA IF NOT EXISTS fbx_history_guard;
REVOKE ALL ON SCHEMA fbx_history_guard FROM PUBLIC;
GRANT USAGE ON SCHEMA fbx_history_guard TO PUBLIC;

CREATE TABLE IF NOT EXISTS fbx_history_guard.settings (
    singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK (singleton),
    schema_name TEXT NOT NULL
);
INSERT INTO fbx_history_guard.settings (schema_name) VALUES (:'schema')
    ON CONFLICT (singleton) DO UPDATE SET schema_name = EXCLUDED.schema_name;

-- One row while armed: the protected objects and the state they must keep.
CREATE TABLE IF NOT EXISTS fbx_history_guard.armed (
    singleton      BOOLEAN PRIMARY KEY DEFAULT true CHECK (singleton),
    armed_at       TIMESTAMPTZ NOT NULL,
    armed_by       TEXT NOT NULL,
    protected_oids OID[] NOT NULL,
    fingerprint    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS fbx_history_guard.event (
    event_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at        TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    by_role   TEXT NOT NULL DEFAULT session_user,
    action    TEXT NOT NULL CHECK (action IN ('arm', 'disarm')),
    reason    TEXT NOT NULL CHECK (length(btrim(reason)) > 0)
);
REVOKE ALL ON ALL TABLES IN SCHEMA fbx_history_guard FROM PUBLIC;

-- The protected objects and a digest of everything that keeps the history
-- append-only. NULLs when any of them is missing.
CREATE OR REPLACE FUNCTION fbx_history_guard.current_state(OUT protected_oids oid[], OUT fingerprint text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    s    text := (SELECT schema_name FROM fbx_history_guard.settings);
    hist oid := to_regclass(format('%I.product_history', s));
    prod oid := to_regclass(format('%I.product', s));
    rec  oid := to_regprocedure(format('%I.product_history_record()', s));
    app  oid := to_regprocedure(format('%I.product_history_append_only()', s));
    ins  oid := to_regprocedure(format('%I.product_history_insert_guard()', s));
    trgs oid[];
BEGIN
    IF hist IS NULL OR prod IS NULL OR rec IS NULL OR app IS NULL OR ins IS NULL THEN
        RETURN;
    END IF;
    SELECT array_agg(t.oid ORDER BY t.oid) INTO trgs
      FROM pg_trigger t
     WHERE NOT t.tgisinternal
       AND t.tgrelid IN (hist, prod);
    protected_oids := ARRAY[hist, rec, app, ins] || coalesce(trgs, '{}');
    fingerprint := md5(concat_ws(' | ',
        (SELECT concat_ws(':', c.relname, c.relnamespace, c.relowner, c.relkind, c.relpersistence,
                          c.relrowsecurity, c.relforcerowsecurity, c.relhasrules)
           FROM pg_class c WHERE c.oid = hist),
        (SELECT string_agg(concat_ws(':', a.attname, a.atttypid, a.attnotnull), ',' ORDER BY a.attnum)
           FROM pg_attribute a WHERE a.attrelid = hist AND a.attnum > 0 AND NOT a.attisdropped),
        (SELECT string_agg(concat_ws(':', t.tgrelid, t.tgname, t.tgfoid, t.tgenabled, t.tgtype), ',' ORDER BY t.tgname)
           FROM pg_trigger t WHERE t.oid = ANY (trgs)),
        (SELECT count(*) FROM pg_rewrite r WHERE r.ev_class = hist),
        (SELECT string_agg(concat_ws(':', p.proname, p.pronamespace, p.proowner, md5(p.prosrc), p.prosecdef,
                                     p.provolatile, coalesce(p.proconfig::text, '')), ',' ORDER BY p.proname)
           FROM pg_proc p WHERE p.oid IN (rec, app, ins))));
END
$$;

CREATE OR REPLACE FUNCTION fbx_history_guard.on_ddl_command_end() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    a   fbx_history_guard.armed;
    cur record;
    hit record;
BEGIN
    SELECT * INTO a FROM fbx_history_guard.armed;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    FOR hit IN SELECT command_tag, object_identity FROM pg_event_trigger_ddl_commands()
                WHERE objid = ANY (a.protected_oids) LOOP
        RAISE EXCEPTION 'product_history guard: % on % is refused while the guard is armed', hit.command_tag, hit.object_identity
            USING HINT = 'Break-glass: the admin runs fbx_history_guard.disarm(<ticket>), see the runbook.';
    END LOOP;
    SELECT * INTO cur FROM fbx_history_guard.current_state();
    IF cur.fingerprint IS DISTINCT FROM a.fingerprint THEN
        RAISE EXCEPTION 'product_history guard: % would change the history''s triggers, functions, columns or rules', tg_tag
            USING HINT = 'Break-glass: the admin runs fbx_history_guard.disarm(<ticket>), see the runbook.';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION fbx_history_guard.on_sql_drop() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    a   fbx_history_guard.armed;
    hit record;
BEGIN
    SELECT * INTO a FROM fbx_history_guard.armed;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    FOR hit IN SELECT object_type, object_identity FROM pg_event_trigger_dropped_objects()
                WHERE objid = ANY (a.protected_oids) LOOP
        RAISE EXCEPTION 'product_history guard: dropping % % is refused while the guard is armed', hit.object_type, hit.object_identity
            USING HINT = 'Break-glass: the admin runs fbx_history_guard.disarm(<ticket>), see the runbook.';
    END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION fbx_history_guard.arm(reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    cur record;
BEGIN
    SELECT * INTO cur FROM fbx_history_guard.current_state();
    IF cur.fingerprint IS NULL THEN
        RAISE EXCEPTION 'product_history guard: cannot arm, the history table, its functions or triggers are missing (deploy first)';
    END IF;
    INSERT INTO fbx_history_guard.event (action, reason) VALUES ('arm', reason);
    INSERT INTO fbx_history_guard.armed (armed_at, armed_by, protected_oids, fingerprint)
         VALUES (clock_timestamp(), session_user, cur.protected_oids, cur.fingerprint)
    ON CONFLICT (singleton) DO UPDATE
        SET armed_at = EXCLUDED.armed_at, armed_by = EXCLUDED.armed_by,
            protected_oids = EXCLUDED.protected_oids, fingerprint = EXCLUDED.fingerprint;
    RETURN fbx_history_guard.verify();
END
$$;

CREATE OR REPLACE FUNCTION fbx_history_guard.disarm(reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    INSERT INTO fbx_history_guard.event (action, reason) VALUES ('disarm', reason);
    DELETE FROM fbx_history_guard.armed;
    -- Logged by the server (log_min_messages warning); the history-tamper alarm matches it.
    RAISE WARNING 'product_history guard: DISARMED by % (%)', session_user, reason;
    RETURN fbx_history_guard.verify();
END
$$;

-- 'armed, intact' is the only healthy answer (integrity check, any role).
CREATE OR REPLACE FUNCTION fbx_history_guard.verify() RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    a   fbx_history_guard.armed;
    cur record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_event_trigger
                    WHERE evtname IN ('fbx_history_guard_ddl', 'fbx_history_guard_drop') AND evtenabled = 'O'
                   HAVING count(*) = 2) THEN
        RETURN 'EVENT TRIGGERS MISSING OR DISABLED';
    END IF;
    SELECT * INTO a FROM fbx_history_guard.armed;
    IF NOT FOUND THEN
        RETURN 'DISARMED';
    END IF;
    SELECT * INTO cur FROM fbx_history_guard.current_state();
    IF cur.fingerprint IS DISTINCT FROM a.fingerprint THEN
        RETURN 'CHANGED SINCE ARMED';
    END IF;
    RETURN 'armed, intact';
END
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fbx_history_guard FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fbx_history_guard.verify() TO PUBLIC;

DROP EVENT TRIGGER IF EXISTS fbx_history_guard_ddl;
DROP EVENT TRIGGER IF EXISTS fbx_history_guard_drop;
CREATE EVENT TRIGGER fbx_history_guard_ddl ON ddl_command_end
    EXECUTE FUNCTION fbx_history_guard.on_ddl_command_end();
CREATE EVENT TRIGGER fbx_history_guard_drop ON sql_drop
    EXECUTE FUNCTION fbx_history_guard.on_sql_drop();
