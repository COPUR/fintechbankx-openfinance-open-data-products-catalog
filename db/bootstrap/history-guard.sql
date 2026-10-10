-- svc-of-open-products-catalog: guard for the append-only product_history.
--
-- Run by the DBA as the cluster admin (open_products_admin, rds_superuser),
-- connected to db_of_open_products_catalog_<env>, in the bootstrap (runbook
-- section 2.2, step 2). Not a Flyway migration on purpose: Flyway runs as the
-- schema owner, and the guard exists to stop the schema owner.
--
-- 1. The history writer. open_products_catalog_history_writer (NOLOGIN) owns
--    product_history_record() (SECURITY DEFINER, pinned search_path) and is
--    the only role with INSERT on product_history once armed. Flyway creates
--    both objects as the schema owner, so arm() (after migrate) moves them;
--    the owner keeps no INSERT and no EXECUTE, cannot attach the function to
--    another table, replace it or take it back. V5's insert guard also
--    refuses any insert not made as the function's owner.
-- 2. The event triggers (admin-owned). Once armed, any DDL in the database
--    that targets or drops a protected object (the history table, its
--    functions, every trigger on product or product_history and the
--    functions they call) or an object in fbx_history_guard, or that leaves
--    the fingerprint different from the one recorded at arming, raises an
--    exception and the statement rolls back. The fingerprint covers owners,
--    table and column privileges of product and product_history (so GRANTs
--    to the runtime, import or owner role are refused), function owners,
--    privileges, SECURITY DEFINER, search_path and bodies, triggers and
--    their enabled state, history columns and rules, and the history
--    writer's login flag and members.
-- 3. The guard's own state (armed, event) is append-only, also for the admin.
--
-- Break-glass (runbook section 2.3), admin only, recorded in
-- fbx_history_guard.event:
--   SELECT fbx_history_guard.disarm('<change ticket>');  -- before a migration that changes the history
--   SELECT fbx_history_guard.hand_back_history_writer('<change ticket>');  -- only if it replaces product_history_record()
--   SELECT fbx_history_guard.arm('<change ticket>');     -- after it: moves the writer back, records the new state
-- Status, for anyone: SELECT fbx_history_guard.verify();
--
-- Re-runnable while DISARMED (one transaction). While armed it refuses to
-- run: disarm first, re-run, arm.
\set ON_ERROR_STOP on
\if :{?schema}
\else
\set schema sc_of_open_products_catalog
\endif

BEGIN;

SELECT to_regprocedure('fbx_history_guard.verify()') IS NOT NULL AS guard_installed \gset
\if :guard_installed
SELECT fbx_history_guard.verify() IN ('armed, intact', 'CHANGED SINCE ARMED') AS guard_armed \gset
\if :guard_armed
DO $$ BEGIN
    RAISE EXCEPTION 'product_history guard: armed; run fbx_history_guard.disarm(<ticket>) before re-running the bootstrap, then arm again';
END $$;
\endif
\endif

-- Disarmed here, so dropping the event triggers changes nothing; the old
-- versions would otherwise run against the tables this script reshapes. They
-- are recreated at the end of this transaction.
DROP EVENT TRIGGER IF EXISTS fbx_history_guard_ddl;
DROP EVENT TRIGGER IF EXISTS fbx_history_guard_drop;

SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'open_products_catalog_history_writer') AS writer_missing \gset
\if :writer_missing
CREATE ROLE open_products_catalog_history_writer NOLOGIN;
\endif
ALTER ROLE open_products_catalog_history_writer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;

CREATE SCHEMA IF NOT EXISTS fbx_history_guard;
REVOKE ALL ON SCHEMA fbx_history_guard FROM PUBLIC;
GRANT USAGE ON SCHEMA fbx_history_guard TO PUBLIC;

CREATE TABLE IF NOT EXISTS fbx_history_guard.settings (
    singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK (singleton),
    schema_name TEXT NOT NULL
);
INSERT INTO fbx_history_guard.settings (schema_name) VALUES (:'schema')
    ON CONFLICT (singleton) DO UPDATE SET schema_name = EXCLUDED.schema_name;

-- Before round 3, armed was a one-row table that disarm() emptied. It is kept
-- as armed_v1 (read-only evidence) and replaced by an append-only log.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_attribute
                WHERE attrelid = to_regclass('fbx_history_guard.armed') AND attname = 'singleton' AND NOT attisdropped) THEN
        ALTER TABLE fbx_history_guard.armed RENAME TO armed_v1;
    END IF;
END
$$;

-- Append-only: one row per arm or disarm. The latest row is the state.
CREATE TABLE IF NOT EXISTS fbx_history_guard.armed (
    armed_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at             TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    by_role        TEXT NOT NULL DEFAULT session_user,
    is_armed       BOOLEAN NOT NULL,
    protected_oids OID[],
    fingerprint    TEXT,
    CONSTRAINT armed_state CHECK (is_armed = (protected_oids IS NOT NULL AND fingerprint IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS fbx_history_guard.event (
    event_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at        TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    by_role   TEXT NOT NULL DEFAULT session_user,
    action    TEXT NOT NULL,
    reason    TEXT NOT NULL CHECK (length(btrim(reason)) > 0)
);
ALTER TABLE fbx_history_guard.event DROP CONSTRAINT IF EXISTS event_action_check;
ALTER TABLE fbx_history_guard.event ADD CONSTRAINT event_action_check
    CHECK (action IN ('arm', 'disarm', 'hand_back'));

CREATE OR REPLACE FUNCTION fbx_history_guard.append_only() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'fbx_history_guard.% is append-only (% refused)', TG_TABLE_NAME, TG_OP;
END
$$;
CREATE OR REPLACE TRIGGER trg_armed_append_only BEFORE UPDATE OR DELETE ON fbx_history_guard.armed
    FOR EACH ROW EXECUTE FUNCTION fbx_history_guard.append_only();
CREATE OR REPLACE TRIGGER trg_armed_no_truncate BEFORE TRUNCATE ON fbx_history_guard.armed
    FOR EACH STATEMENT EXECUTE FUNCTION fbx_history_guard.append_only();
CREATE OR REPLACE TRIGGER trg_event_append_only BEFORE UPDATE OR DELETE ON fbx_history_guard.event
    FOR EACH ROW EXECUTE FUNCTION fbx_history_guard.append_only();
CREATE OR REPLACE TRIGGER trg_event_no_truncate BEFORE TRUNCATE ON fbx_history_guard.event
    FOR EACH STATEMENT EXECUTE FUNCTION fbx_history_guard.append_only();
-- Fire also under session_replication_role = replica.
ALTER TABLE fbx_history_guard.armed ENABLE ALWAYS TRIGGER trg_armed_append_only;
ALTER TABLE fbx_history_guard.armed ENABLE ALWAYS TRIGGER trg_armed_no_truncate;
ALTER TABLE fbx_history_guard.event ENABLE ALWAYS TRIGGER trg_event_append_only;
ALTER TABLE fbx_history_guard.event ENABLE ALWAYS TRIGGER trg_event_no_truncate;
-- Only arm(), disarm() and hand_back_history_writer() (SECURITY DEFINER, run
-- as the tables' owner) append; a member of rds_pgaudit, which holds INSERT
-- for object auditing, is refused.
CREATE OR REPLACE FUNCTION fbx_history_guard.insert_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF current_user IS DISTINCT FROM (SELECT pg_get_userbyid(c.relowner) FROM pg_class c WHERE c.oid = TG_RELID) THEN
        RAISE EXCEPTION 'fbx_history_guard.% is written only by arm(), disarm() and hand_back_history_writer() (INSERT as % refused)',
            TG_TABLE_NAME, current_user;
    END IF;
    RETURN NEW;
END
$$;
CREATE OR REPLACE TRIGGER trg_armed_insert_guard BEFORE INSERT ON fbx_history_guard.armed
    FOR EACH ROW EXECUTE FUNCTION fbx_history_guard.insert_guard();
CREATE OR REPLACE TRIGGER trg_event_insert_guard BEFORE INSERT ON fbx_history_guard.event
    FOR EACH ROW EXECUTE FUNCTION fbx_history_guard.insert_guard();
ALTER TABLE fbx_history_guard.armed ENABLE ALWAYS TRIGGER trg_armed_insert_guard;
ALTER TABLE fbx_history_guard.event ENABLE ALWAYS TRIGGER trg_event_insert_guard;
REVOKE ALL ON ALL TABLES IN SCHEMA fbx_history_guard FROM PUBLIC;

-- pgaudit object auditing (pgaudit.role = rds_pgaudit, terraform-modules #11):
-- every write to the guard state logs an "AUDIT: OBJECT" line. No SELECT, so
-- the scheduled verify() does not log. product_history gets its grant in
-- set_history_writer(), before arm() records the fingerprint.
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_pgaudit') AS has_pgaudit_role \gset
\if :has_pgaudit_role
GRANT INSERT, UPDATE, DELETE ON fbx_history_guard.armed, fbx_history_guard.event TO rds_pgaudit;
\else
\warn 'role rds_pgaudit does not exist: object auditing of the guard state is not set up'
\endif

-- Latest arming state; is_armed false when there is none.
CREATE OR REPLACE FUNCTION fbx_history_guard.state() RETURNS fbx_history_guard.armed
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
    SELECT a FROM fbx_history_guard.armed a ORDER BY a.armed_id DESC LIMIT 1
$$;

-- The protected objects and a digest of everything that keeps the history
-- append-only. NULLs when any of them is missing or a history trigger is off.
CREATE OR REPLACE FUNCTION fbx_history_guard.current_state(OUT protected_oids oid[], OUT fingerprint text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    s      text := (SELECT schema_name FROM fbx_history_guard.settings);
    hist   oid := to_regclass(format('%I.product_history', s));
    prod   oid := to_regclass(format('%I.product', s));
    rec    oid := to_regprocedure(format('%I.product_history_record()', s));
    app    oid := to_regprocedure(format('%I.product_history_append_only()', s));
    ins    oid := to_regprocedure(format('%I.product_history_insert_guard()', s));
    trn    oid := to_regprocedure(format('%I.product_truncate_refused()', s));
    writer oid := (SELECT oid FROM pg_roles WHERE rolname = 'open_products_catalog_history_writer');
    trgs   oid[];
    funcs  oid[];
BEGIN
    IF hist IS NULL OR prod IS NULL OR rec IS NULL OR app IS NULL OR ins IS NULL OR trn IS NULL OR writer IS NULL THEN
        RETURN;
    END IF;
    -- The six history triggers (V2, V4, V5) must exist and fire.
    IF (SELECT count(*) FROM pg_trigger t
         WHERE t.tgrelid IN (hist, prod) AND t.tgenabled IN ('O', 'A')
           AND t.tgname IN ('trg_product_history', 'trg_product_history_delete', 'trg_product_no_truncate',
                            'trg_product_history_no_change', 'trg_product_history_no_truncate',
                            'trg_product_history_insert_guard')) <> 6 THEN
        RETURN;
    END IF;
    SELECT array_agg(t.oid ORDER BY t.oid) INTO trgs
      FROM pg_trigger t
     WHERE NOT t.tgisinternal
       AND t.tgrelid IN (hist, prod);
    -- The named history functions plus every function a protected trigger calls.
    SELECT array_agg(DISTINCT f ORDER BY f) INTO funcs
      FROM unnest(ARRAY[rec, app, ins, trn]
                  || coalesce((SELECT array_agg(t.tgfoid) FROM pg_trigger t WHERE t.oid = ANY (trgs)), '{}')) AS f;
    protected_oids := ARRAY[hist] || funcs || coalesce(trgs, '{}');
    fingerprint := md5(concat_ws(' | ',
        (SELECT concat_ws(':', c.relname, c.relnamespace, c.relowner, c.relkind, c.relpersistence,
                          c.relrowsecurity, c.relforcerowsecurity, c.relhasrules, coalesce(c.relacl::text, ''))
           FROM pg_class c WHERE c.oid = hist),
        -- Grants on product too: no new privileges for the runtime, import or owner role.
        (SELECT concat_ws(':', c.relname, c.relnamespace, c.relowner, coalesce(c.relacl::text, ''),
                          c.relrowsecurity, c.relforcerowsecurity, c.relhasrules)
           FROM pg_class c WHERE c.oid = prod),
        -- History columns, with their column privileges (GRANT INSERT (cols) ...).
        (SELECT string_agg(concat_ws(':', a.attname, a.atttypid, a.attnotnull, coalesce(a.attacl::text, '')), ',' ORDER BY a.attnum)
           FROM pg_attribute a WHERE a.attrelid = hist AND a.attnum > 0 AND NOT a.attisdropped),
        -- Column privileges on product (GRANT UPDATE (col) ...).
        (SELECT string_agg(concat_ws(':', a.attname, a.attacl::text), ',' ORDER BY a.attnum)
           FROM pg_attribute a WHERE a.attrelid = prod AND a.attnum > 0 AND NOT a.attisdropped AND a.attacl IS NOT NULL),
        (SELECT string_agg(concat_ws(':', t.tgrelid, t.tgname, t.tgfoid, t.tgenabled, t.tgtype), ',' ORDER BY t.tgname)
           FROM pg_trigger t WHERE t.oid = ANY (trgs)),
        (SELECT count(*) FROM pg_rewrite r WHERE r.ev_class IN (hist, prod)),
        (SELECT string_agg(concat_ws(':', p.proname, p.pronamespace, p.proowner, md5(p.prosrc), p.prosecdef,
                                     p.provolatile, coalesce(p.proconfig::text, ''), coalesce(p.proacl::text, '')),
                           ',' ORDER BY p.oid)
           FROM pg_proc p WHERE p.oid = ANY (funcs)),
        -- The writer stays NOLOGIN and nobody new becomes it (GRANT ROLE fires no event trigger).
        (SELECT concat_ws(':', r.rolcanlogin, r.rolsuper, r.rolinherit, r.rolbypassrls)
           FROM pg_roles r WHERE r.oid = writer),
        (SELECT string_agg(concat_ws(':', m.member::regrole::text, m.set_option, m.inherit_option, m.admin_option),
                           ',' ORDER BY m.member::regrole::text)
           FROM pg_auth_members m WHERE m.roleid = writer),
        -- Members of the pgaudit object-audit role hold its UPDATE/DELETE on the history.
        (SELECT string_agg(m.member::regrole::text, ',' ORDER BY m.member::regrole::text)
           FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid WHERE r.rolname = 'rds_pgaudit')));
END
$$;

CREATE OR REPLACE FUNCTION fbx_history_guard.on_ddl_command_end() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    a   fbx_history_guard.armed := fbx_history_guard.state();
    cur record;
    hit record;
BEGIN
    IF a.is_armed IS NOT TRUE THEN
        RETURN;
    END IF;
    FOR hit IN SELECT command_tag, object_identity FROM pg_event_trigger_ddl_commands()
                WHERE objid = ANY (a.protected_oids) OR schema_name = 'fbx_history_guard' LOOP
        RAISE EXCEPTION 'product_history guard: % on % is refused while the guard is armed', hit.command_tag, hit.object_identity
            USING HINT = 'Break-glass: the admin runs fbx_history_guard.disarm(<ticket>), see the runbook.';
    END LOOP;
    SELECT * INTO cur FROM fbx_history_guard.current_state();
    IF cur.fingerprint IS DISTINCT FROM a.fingerprint THEN
        RAISE EXCEPTION 'product_history guard: % would change the history''s triggers, functions, columns, rules or privileges', tg_tag
            USING HINT = 'Break-glass: the admin runs fbx_history_guard.disarm(<ticket>), see the runbook.';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION fbx_history_guard.on_sql_drop() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    a   fbx_history_guard.armed := fbx_history_guard.state();
    hit record;
BEGIN
    IF a.is_armed IS NOT TRUE THEN
        RETURN;
    END IF;
    FOR hit IN SELECT object_type, object_identity FROM pg_event_trigger_dropped_objects()
                WHERE objid = ANY (a.protected_oids) OR schema_name = 'fbx_history_guard' LOOP
        RAISE EXCEPTION 'product_history guard: dropping % % is refused while the guard is armed', hit.object_type, hit.object_identity
            USING HINT = 'Break-glass: the admin runs fbx_history_guard.disarm(<ticket>), see the runbook.';
    END LOOP;
END
$$;

-- Moves product_history_record() and INSERT on product_history from the schema
-- owner to the history writer (secure = true), or back (secure = false, only
-- for a break-glass migration that replaces the function).
CREATE OR REPLACE FUNCTION fbx_history_guard.set_history_writer(secure boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    s      text := (SELECT schema_name FROM fbx_history_guard.settings);
    writer text := 'open_products_catalog_history_writer';
    owner  text;
BEGIN
    SELECT pg_get_userbyid(c.relowner) INTO owner
      FROM pg_class c WHERE c.oid = to_regclass(format('%I.product_history', s));
    IF owner IS NULL THEN
        RAISE EXCEPTION 'product_history guard: %.product_history does not exist (deploy first)', s;
    END IF;
    -- A non-superuser admin (rds_superuser) must own the function through
    -- membership (INHERIT) and be able to SET ROLE to the new owner.
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        EXECUTE format('GRANT %I TO %I WITH INHERIT TRUE, SET TRUE', owner, current_user);
        EXECUTE format('GRANT %I TO %I WITH INHERIT TRUE, SET TRUE', writer, current_user);
    END IF;
    IF secure THEN
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', s, writer);
        EXECUTE format('GRANT CREATE ON SCHEMA %I TO %I', s, writer);  -- the new owner needs CREATE
        EXECUTE format('ALTER FUNCTION %I.product_history_record() OWNER TO %I', s, writer);
        EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM %I', s, writer);
        EXECUTE format('REVOKE ALL ON FUNCTION %I.product_history_record() FROM PUBLIC', s);
        -- Table-level REVOKE also clears column privileges.
        EXECUTE format('REVOKE INSERT ON %I.product_history FROM %I', s, owner);
        EXECUTE format('GRANT INSERT ON %I.product_history TO %I', s, writer);
        -- Object audit of attempted UPDATE/DELETE (refused by the V2 triggers).
        -- Not INSERT: every product change writes one, and the V5 insert guard
        -- refuses any inserter but the writer.
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_pgaudit') THEN
            EXECUTE format('GRANT UPDATE, DELETE ON %I.product_history TO rds_pgaudit', s);
        END IF;
    ELSE
        EXECUTE format('GRANT CREATE ON SCHEMA %I TO %I', s, writer);
        EXECUTE format('ALTER FUNCTION %I.product_history_record() OWNER TO %I', s, owner);
        EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM %I', s, writer);
        EXECUTE format('REVOKE ALL ON FUNCTION %I.product_history_record() FROM PUBLIC', s);
        EXECUTE format('GRANT INSERT ON %I.product_history TO %I', s, owner);
        EXECUTE format('REVOKE INSERT ON %I.product_history FROM %I', s, writer);
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION fbx_history_guard.arm(reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    cur record;
BEGIN
    IF (fbx_history_guard.state()).is_armed THEN
        RAISE EXCEPTION 'product_history guard: already armed (verify: %); disarm first to record a new state', fbx_history_guard.verify();
    END IF;
    IF (SELECT fingerprint FROM fbx_history_guard.current_state()) IS NULL THEN
        RAISE EXCEPTION 'product_history guard: cannot arm, the history table, its functions or triggers (V2-V5) are missing or disabled (deploy first)';
    END IF;
    -- Still disarmed here, so the guard does not refuse the transfer's DDL.
    PERFORM fbx_history_guard.set_history_writer(true);
    SELECT * INTO cur FROM fbx_history_guard.current_state();
    INSERT INTO fbx_history_guard.event (action, reason) VALUES ('arm', reason);
    INSERT INTO fbx_history_guard.armed (is_armed, protected_oids, fingerprint)
         VALUES (true, cur.protected_oids, cur.fingerprint);
    RETURN fbx_history_guard.verify();
END
$$;

-- Keeps the history writer: a migration that only adds or changes triggers
-- (V5) does not need product_history_record() back.
CREATE OR REPLACE FUNCTION fbx_history_guard.disarm(reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    INSERT INTO fbx_history_guard.event (action, reason) VALUES ('disarm', reason);
    INSERT INTO fbx_history_guard.armed (is_armed) VALUES (false);
    -- Logged by the server (log_min_messages warning); the history-tamper alarm matches it.
    RAISE WARNING 'product_history guard: DISARMED by % (%)', session_user, reason;
    RETURN fbx_history_guard.verify();
END
$$;

-- Break-glass only, while disarmed: the schema owner gets
-- product_history_record() and INSERT back so a migration can replace the
-- function. arm() takes both back.
CREATE OR REPLACE FUNCTION fbx_history_guard.hand_back_history_writer(reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF (fbx_history_guard.state()).is_armed THEN
        RAISE EXCEPTION 'product_history guard: armed; disarm first';
    END IF;
    INSERT INTO fbx_history_guard.event (action, reason) VALUES ('hand_back', reason);
    PERFORM fbx_history_guard.set_history_writer(false);
    RAISE WARNING 'product_history guard: history writer HANDED BACK to the schema owner by % (%)', session_user, reason;
    RETURN fbx_history_guard.verify();
END
$$;

-- 'armed, intact' is the only healthy answer (integrity check, any role).
CREATE OR REPLACE FUNCTION fbx_history_guard.verify() RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    a   fbx_history_guard.armed := fbx_history_guard.state();
    cur record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_event_trigger
                    WHERE evtname IN ('fbx_history_guard_ddl', 'fbx_history_guard_drop') AND evtenabled = 'O'
                   HAVING count(*) = 2) THEN
        RETURN 'EVENT TRIGGERS MISSING OR DISABLED';
    END IF;
    IF (SELECT count(*) FROM pg_trigger
         WHERE tgrelid IN ('fbx_history_guard.armed'::regclass, 'fbx_history_guard.event'::regclass)
           AND tgenabled = 'A'
           AND tgname IN ('trg_armed_append_only', 'trg_armed_no_truncate', 'trg_armed_insert_guard',
                          'trg_event_append_only', 'trg_event_no_truncate', 'trg_event_insert_guard')) <> 6 THEN
        RETURN 'GUARD STATE NOT APPEND-ONLY';
    END IF;
    IF a.is_armed IS NOT TRUE THEN
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

CREATE EVENT TRIGGER fbx_history_guard_ddl ON ddl_command_end
    EXECUTE FUNCTION fbx_history_guard.on_ddl_command_end();
CREATE EVENT TRIGGER fbx_history_guard_drop ON sql_drop
    EXECUTE FUNCTION fbx_history_guard.on_sql_drop();

COMMIT;
