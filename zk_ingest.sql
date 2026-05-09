-- =============================================================================
--  ZK Ingest  v1.0
--  Builds a shadow "zk" schema that replays pg_audit reports against
--  offline JSON bundles (catalog_snapshot.json + stat_snapshot.json).
--
--  Usage (called by zk_replay.ps1):
--    1. CREATE TABLE _zk_catalog(data jsonb); INSERT INTO _zk_catalog ...
--    2. CREATE TABLE _zk_stat(data jsonb);    INSERT INTO _zk_stat ...
--    3. \i zk_ingest.sql
--    4. SET search_path = zk, pg_catalog, public;
--    5. \i ultimate_report.sql / pg_perf_report.sql
--
--  Shadow strategy:
--    - OID-fabricated tables (_zk_ns, _zk_tables, _zk_indexes) back pg_* catalog views
--    - Shadow functions (pg_is_in_recovery, pg_current_wal_lsn, etc.) return JSON values
--    - pg_stat_statements view surfaces all version-variant column names via COALESCE
--    - search_path = zk, pg_catalog resolves zk.* before pg_catalog.* transparently
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

SET client_min_messages = WARNING;
DROP SCHEMA IF EXISTS zk CASCADE;
CREATE SCHEMA zk;

-- ---------------------------------------------------------------------------
-- Staging table aliases (must exist before this script runs)
-- These are created and populated by zk_replay.ps1 before calling \i zk_ingest.sql
-- ---------------------------------------------------------------------------

-- Verify staging tables exist
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = '_zk_catalog' AND relkind = 'r') THEN
    RAISE EXCEPTION '_zk_catalog staging table not found — run zk_replay.ps1 to load bundle';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = '_zk_stat' AND relkind = 'r') THEN
    RAISE EXCEPTION '_zk_stat staging table not found — run zk_replay.ps1 to load bundle';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- OID-fabrication tables — gives catalog views real join targets
-- Namespace OIDs start at 900000, table OIDs at 800000, index OIDs at 700000
-- ---------------------------------------------------------------------------

-- NOTE: NULLIF + COALESCE pattern handles both SQL NULL and JSON null.
-- json_agg() over zero rows returns SQL NULL; json_build_object wraps it as JSON null
-- (the literal 'null'::jsonb). jsonb_array_elements(JSON null) throws
-- "cannot extract elements from a scalar". NULLIF converts JSON null → SQL NULL;
-- COALESCE converts SQL NULL → '[]'::jsonb so the SRF returns zero rows safely.
-- In CREATE TABLE AS the WHERE clause cannot be pushed down (it references elem),
-- so the guard must live inside the jsonb_array_elements argument.

CREATE TABLE zk._zk_ns AS
  SELECT
    nspname,
    (900000 + row_number() OVER (ORDER BY nspname))::oid AS ns_oid
  FROM (
    SELECT DISTINCT elem->>'schema' AS nspname
    FROM _zk_catalog,
         jsonb_array_elements(COALESCE(NULLIF(data->'tables','null'::jsonb),'[]'::jsonb)) elem
    WHERE elem->>'schema' IS NOT NULL
  ) t;

CREATE TABLE zk._zk_tables AS
  SELECT
    elem->>'schema'    AS schemaname,
    elem->>'table'     AS tablename,
    (800000 + row_number() OVER (ORDER BY elem->>'schema', elem->>'table'))::oid AS reloid,
    ns.ns_oid          AS relnamespace,
    COALESCE((elem->>'relpages')::int, 0)         AS relpages,
    COALESCE((elem->>'row_estimate')::float8, 0)  AS reltuples,
    COALESCE((elem->>'total_bytes')::bigint, 0)   AS total_bytes
  FROM _zk_catalog,
       jsonb_array_elements(COALESCE(NULLIF(data->'tables','null'::jsonb),'[]'::jsonb)) elem
  LEFT JOIN zk._zk_ns ns ON ns.nspname = elem->>'schema';

CREATE TABLE zk._zk_indexes AS
  SELECT
    elem->>'schema'      AS schemaname,
    elem->>'table'       AS tablename,
    elem->>'index_name'  AS indexname,
    (700000 + row_number() OVER (ORDER BY elem->>'schema', elem->>'table', elem->>'index_name'))::oid AS indexrelid,
    t.reloid             AS indrelid,
    COALESCE((elem->>'size_bytes')::bigint, 0) AS size_bytes,
    COALESCE((elem->>'idx_scan')::bigint, 0)   AS idx_scan,
    COALESCE((elem->>'is_unique')::boolean, false) AS indisunique,
    COALESCE((elem->>'is_primary')::boolean, false) AS indisprimary,
    COALESCE((elem->>'is_valid')::boolean, true)    AS indisvalid
  FROM _zk_catalog,
       jsonb_array_elements(COALESCE(NULLIF(data->'indexes','null'::jsonb),'[]'::jsonb)) elem
  LEFT JOIN zk._zk_tables t ON t.schemaname = elem->>'schema' AND t.tablename = elem->>'table';

-- ---------------------------------------------------------------------------
-- _zk_langs: language OID map for pg_language shadow
-- ---------------------------------------------------------------------------

CREATE TABLE zk._zk_langs AS
  SELECT DISTINCT ON (lanname) lanname,
    (600000 + row_number() OVER (ORDER BY lanname))::oid AS lang_oid
  FROM (
    SELECT elem->>'language' AS lanname
    FROM _zk_catalog,
         jsonb_array_elements(COALESCE(NULLIF(data->'functions','null'::jsonb),'[]'::jsonb)) elem
    WHERE elem->>'language' IS NOT NULL
  ) t;

-- ---------------------------------------------------------------------------
-- _zk_funcs: function/procedure metadata
-- ---------------------------------------------------------------------------

CREATE TABLE zk._zk_funcs AS
  SELECT
    ns.ns_oid                                             AS pronamespace,
    elem->>'name'                                         AS proname,
    elem->>'language'                                     AS lanname,
    (CASE elem->>'kind'
       WHEN 'function'  THEN 'f'
       WHEN 'procedure' THEN 'p'
       WHEN 'aggregate' THEN 'a'
       WHEN 'window'    THEN 'w'
       ELSE 'f' END)::char                                AS prokind,
    COALESCE((elem->>'security_definer')::boolean, false) AS prosecdef,
    (CASE elem->>'volatility'
       WHEN 'immutable' THEN 'i'
       WHEN 'stable'    THEN 's'
       ELSE 'v' END)::char                                AS provolatile,
    COALESCE((elem->>'strict')::boolean, false)           AS proisstrict,
    COALESCE(elem->>'return_type', '')                    AS return_type,
    COALESCE(elem->>'arguments', '')                      AS arguments,
    COALESCE(elem->>'definition', '')                     AS definition,
    (500000 + row_number() OVER (
      ORDER BY elem->>'schema', elem->>'name',
               COALESCE(elem->>'arguments', '')))::oid    AS func_oid
  FROM _zk_catalog,
       jsonb_array_elements(COALESCE(NULLIF(data->'functions','null'::jsonb),'[]'::jsonb)) elem
  LEFT JOIN zk._zk_ns ns ON ns.nspname = elem->>'schema';

-- ---------------------------------------------------------------------------
-- _zk_triggers: trigger metadata with fabricated OIDs
-- ---------------------------------------------------------------------------

CREATE TABLE zk._zk_triggers AS
  SELECT
    elem->>'schema'                                         AS schemaname,
    elem->>'table'                                          AS tablename,
    elem->>'trigger_name'                                   AS tgname,
    COALESCE((elem->>'enabled')::boolean, true)             AS tg_enabled,
    elem->>'timing'                                         AS timing,
    elem->'events'                                          AS events_json,
    elem->>'orientation'                                    AS orientation,
    elem->>'function_schema'                                AS func_schema,
    elem->>'function_name'                                  AS func_name,
    elem->>'condition'                                      AS tg_condition,
    COALESCE(t.reloid,  0::oid)                             AS tgrelid,
    COALESCE(f.func_oid, 0::oid)                            AS tgfoid,
    (450000 + row_number() OVER (
      ORDER BY elem->>'schema', elem->>'table',
               elem->>'trigger_name'))::oid                 AS tg_oid,
    -- Reconstruct tgtype bitfield from JSON strings
    (
      CASE WHEN (elem->>'orientation') = 'ROW'         THEN  1 ELSE 0 END
    + CASE WHEN (elem->>'timing') = 'BEFORE'           THEN  2 ELSE 0 END
    + CASE WHEN (elem->'events') @> '"INSERT"'::jsonb  THEN  4 ELSE 0 END
    + CASE WHEN (elem->'events') @> '"DELETE"'::jsonb  THEN  8 ELSE 0 END
    + CASE WHEN (elem->'events') @> '"UPDATE"'::jsonb  THEN 16 ELSE 0 END
    + CASE WHEN (elem->'events') @> '"TRUNCATE"'::jsonb THEN 32 ELSE 0 END
    + CASE WHEN (elem->>'timing') = 'INSTEAD OF'       THEN 64 ELSE 0 END
    )::int2                                                 AS tgtype
  FROM _zk_catalog,
       jsonb_array_elements(COALESCE(NULLIF(data->'triggers','null'::jsonb),'[]'::jsonb)) elem
  LEFT JOIN zk._zk_tables t
         ON t.schemaname = elem->>'schema' AND t.tablename = elem->>'table'
  LEFT JOIN zk._zk_funcs f
         ON f.proname = elem->>'function_name'
        AND f.pronamespace = (
          SELECT ns_oid FROM zk._zk_ns WHERE nspname = elem->>'function_schema' LIMIT 1
        );

-- ---------------------------------------------------------------------------
-- Shadow functions — return values from the captured JSON snapshots
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION zk.pg_is_in_recovery()
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT (data->'_meta'->>'is_in_recovery')::boolean
  FROM _zk_stat LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION zk.pg_current_wal_lsn()
RETURNS pg_lsn LANGUAGE sql STABLE AS $$
  SELECT (data->'_meta'->>'current_wal_lsn')::pg_lsn
  FROM _zk_stat LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION zk.version()
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT data->'_meta'->>'pg_version'
  FROM _zk_stat LIMIT 1;
$$;

-- pg_blocking_pids: no live blocking info in offline mode — return empty array
CREATE OR REPLACE FUNCTION zk.pg_blocking_pids(integer)
RETURNS integer[] LANGUAGE sql STABLE AS $$
  SELECT ARRAY[]::integer[];
$$;

-- pg_total_relation_size: look up pre-computed total_bytes from catalog
CREATE OR REPLACE FUNCTION zk.pg_total_relation_size(oid)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT total_bytes FROM zk._zk_tables WHERE reloid = $1),
    0
  );
$$;

-- text overload used by missing_index_candidates: schema.table string
CREATE OR REPLACE FUNCTION zk.pg_total_relation_size(text)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT total_bytes
     FROM zk._zk_tables
     WHERE schemaname || '.' || tablename = $1
        OR schemaname || '.' || quote_ident(tablename) = $1),
    0
  );
$$;

CREATE OR REPLACE FUNCTION zk.pg_relation_size(oid)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT total_bytes FROM zk._zk_tables WHERE reloid = $1),
    (SELECT size_bytes FROM zk._zk_indexes WHERE indexrelid = $1),
    0
  );
$$;

-- pg_wal_lsn_diff: compute from captured values when both are pg_lsn, else 0
CREATE OR REPLACE FUNCTION zk.pg_wal_lsn_diff(pg_lsn, pg_lsn)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN $1 IS NOT NULL AND $2 IS NOT NULL THEN $1 - $2
    ELSE 0::numeric
  END;
$$;

-- has_table_privilege: always true in replay mode (read-only snapshot)
CREATE OR REPLACE FUNCTION zk.has_table_privilege(text, text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT true;
$$;

CREATE OR REPLACE FUNCTION zk.has_table_privilege(oid, text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT true;
$$;

-- pg_postmaster_start_time: derive from pg_uptime in meta if present
CREATE OR REPLACE FUNCTION zk.pg_postmaster_start_time()
RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT (data->'_meta'->>'generated_at')::timestamptz
       - (data->'_meta'->>'pg_uptime')::interval
  FROM _zk_stat LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- pg_language shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_language AS
  SELECT lang_oid AS oid, lanname
  FROM zk._zk_langs;

-- ---------------------------------------------------------------------------
-- pg_proc shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_proc AS
  SELECT
    f.func_oid      AS oid,
    f.proname,
    f.pronamespace,
    COALESCE(l.lang_oid, 0::oid) AS prolang,
    f.prokind,
    f.prosecdef,
    f.provolatile,
    f.proisstrict,
    'u'::char       AS proparallel,
    0::oid          AS prorettype,
    100::float4     AS procost,
    0::float4       AS prorows
  FROM zk._zk_funcs f
  LEFT JOIN zk._zk_langs l USING (lanname);

-- ---------------------------------------------------------------------------
-- pg_trigger shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_trigger AS
  SELECT
    tg_oid          AS oid,
    tgrelid,
    tgname,
    tgfoid,
    tgtype,
    CASE WHEN tg_enabled THEN 'O'::char ELSE 'D'::char END AS tgenabled,
    false           AS tgisinternal,
    tg_condition    AS tgqual
  FROM zk._zk_triggers;

-- ---------------------------------------------------------------------------
-- pg_matviews shadow view (mirrors information_schema view columns)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_matviews AS
  SELECT
    elem->>'schema'       AS schemaname,
    elem->>'name'         AS matviewname,
    elem->>'owner'        AS matviewowner,
    elem->>'tablespace'   AS tablespace,
    COALESCE((elem->>'is_populated')::boolean, false) AS ispopulated,
    elem->>'definition'   AS definition
  FROM _zk_catalog,
       jsonb_array_elements(COALESCE(NULLIF(data->'mat_views','null'::jsonb),'[]'::jsonb)) elem;

-- ---------------------------------------------------------------------------
-- pg_policy shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_policy AS
  SELECT
    (400000 + row_number() OVER (ORDER BY elem->>'schema', elem->>'table', elem->>'name'))::oid AS oid,
    elem->>'name'           AS polname,
    COALESCE(t.reloid, 0::oid) AS polrelid,
    (CASE elem->>'cmd'
       WHEN 'SELECT' THEN 'r'
       WHEN 'INSERT' THEN 'a'
       WHEN 'UPDATE' THEN 'w'
       WHEN 'DELETE' THEN 'd'
       ELSE '*' END)::char  AS polcmd,
    COALESCE((elem->>'permissive')::boolean, true) AS polpermissive,
    '{0}'::oid[]            AS polroles,   -- simplified: roles not queryable offline
    elem->>'qual'           AS polqual_text,
    elem->>'with_check'     AS polwithcheck_text,
    COALESCE((elem->>'rls_enabled')::boolean, false) AS rls_enabled,
    COALESCE((elem->>'rls_forced')::boolean, false)  AS rls_forced,
    elem->>'schema'         AS schemaname,
    elem->>'table'          AS tablename
  FROM _zk_catalog,
       jsonb_array_elements(COALESCE(NULLIF(data->'policies','null'::jsonb),'[]'::jsonb)) elem
  LEFT JOIN zk._zk_tables t
         ON t.schemaname = elem->>'schema' AND t.tablename = elem->>'table';

-- ---------------------------------------------------------------------------
-- pg_rules shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_rules AS
  SELECT
    elem->>'schema'      AS schemaname,
    elem->>'table'       AS tablename,
    elem->>'rule_name'   AS rulename,
    elem->>'event'       AS event,
    COALESCE((elem->>'do_instead')::boolean, false) AS do_instead,
    elem->>'definition'  AS definition
  FROM _zk_catalog,
       jsonb_array_elements(COALESCE(NULLIF(data->'rules','null'::jsonb),'[]'::jsonb)) elem;

-- ---------------------------------------------------------------------------
-- pg_namespace shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_namespace AS
  SELECT ns_oid AS oid, nspname
  FROM zk._zk_ns;

-- ---------------------------------------------------------------------------
-- pg_class shadow view — tables only (indexes backed separately)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_class AS
  SELECT
    reloid          AS oid,
    tablename       AS relname,
    relnamespace,
    relpages,
    reltuples,
    total_bytes     AS relpages_bytes,  -- convenience alias
    'r'::text       AS relkind,
    false::boolean  AS relrowsecurity,
    false::boolean  AS relforcerowsecurity
  FROM zk._zk_tables
  UNION ALL
  SELECT
    indexrelid      AS oid,
    indexname       AS relname,
    (SELECT relnamespace FROM zk._zk_tables t WHERE t.reloid = i.indrelid LIMIT 1),
    0               AS relpages,
    0               AS reltuples,
    size_bytes      AS relpages_bytes,
    'i'::text       AS relkind,
    false::boolean  AS relrowsecurity,
    false::boolean  AS relforcerowsecurity
  FROM zk._zk_indexes i;

-- ---------------------------------------------------------------------------
-- pg_index shadow view — empty stub with all required columns
-- Duplicate index and FK detection queries reference this view; returning no
-- rows means those sections show empty results in offline mode. The
-- precomputed dup_indexes and unindexed_fks views carry the real data.
-- The ::regclass cast in v_idx_duplicate (ultimate_report) would fail on
-- fabricated OIDs at runtime, so keeping this empty avoids that path.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_index AS
  SELECT
    NULL::oid     AS indexrelid,
    NULL::oid     AS indrelid,
    NULL::boolean AS indisunique,
    NULL::boolean AS indisprimary,
    NULL::boolean AS indisvalid,
    NULL::int2[]  AS indkey,       -- real type: int2vector; int2[] supports [n] subscript
    NULL::text    AS indclass,     -- real type: oidvector
    NULL::text    AS indoption,    -- real type: int2vector
    NULL::text    AS indexprs,
    NULL::text    AS indpred
  WHERE false;

-- ---------------------------------------------------------------------------
-- pg_stat_user_indexes shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_user_indexes AS
  SELECT
    i.indrelid                            AS relid,
    i.indexrelid,
    i.schemaname,
    i.tablename                           AS relname,
    i.indexname                           AS indexrelname,
    i.idx_scan,
    0::bigint                             AS idx_tup_read,
    0::bigint                             AS idx_tup_fetch
  FROM zk._zk_indexes i;

-- ---------------------------------------------------------------------------
-- pg_stat_user_tables shadow view (from stat_tables JSON)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_user_tables AS
  SELECT
    t.reloid                                          AS relid,
    elem->>'schema'                                   AS schemaname,
    elem->>'table'                                    AS relname,
    COALESCE((elem->>'seq_scan')::bigint, 0)          AS seq_scan,
    COALESCE((elem->>'seq_tup_read')::bigint, 0)      AS seq_tup_read,
    COALESCE((elem->>'idx_scan')::bigint, 0)          AS idx_scan,
    COALESCE((elem->>'idx_tup_fetch')::bigint, 0)     AS idx_tup_fetch,
    COALESCE((elem->>'n_tup_ins')::bigint, 0)         AS n_tup_ins,
    COALESCE((elem->>'n_tup_upd')::bigint, 0)         AS n_tup_upd,
    COALESCE((elem->>'n_tup_del')::bigint, 0)         AS n_tup_del,
    COALESCE((elem->>'n_tup_hot_upd')::bigint, 0)     AS n_tup_hot_upd,
    COALESCE((elem->>'n_live_tup')::bigint, 0)        AS n_live_tup,
    COALESCE((elem->>'n_dead_tup')::bigint, 0)        AS n_dead_tup,
    COALESCE((elem->>'n_mod_since_analyze')::bigint, 0) AS n_mod_since_analyze,
    (elem->>'n_ins_since_vacuum')::bigint             AS n_ins_since_vacuum,
    (elem->>'last_vacuum')::timestamptz               AS last_vacuum,
    (elem->>'last_autovacuum')::timestamptz           AS last_autovacuum,
    (elem->>'last_analyze')::timestamptz              AS last_analyze,
    (elem->>'last_autoanalyze')::timestamptz          AS last_autoanalyze,
    COALESCE((elem->>'vacuum_count')::bigint, 0)      AS vacuum_count,
    COALESCE((elem->>'autovacuum_count')::bigint, 0)  AS autovacuum_count,
    COALESCE((elem->>'analyze_count')::bigint, 0)     AS analyze_count,
    COALESCE((elem->>'autoanalyze_count')::bigint, 0) AS autoanalyze_count
  FROM _zk_stat, jsonb_array_elements(data->'stat_tables') elem
  JOIN zk._zk_tables t ON t.schemaname = elem->>'schema' AND t.tablename = elem->>'table'
  WHERE data->'stat_tables' IS NOT NULL AND data->>'stat_tables' != 'null';

-- ---------------------------------------------------------------------------
-- pg_statio_user_tables shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_statio_user_tables AS
  SELECT
    t.reloid                                              AS relid,
    elem->>'schema'                                       AS schemaname,
    elem->>'table'                                        AS relname,
    COALESCE((elem->>'heap_blks_read')::bigint, 0)        AS heap_blks_read,
    COALESCE((elem->>'heap_blks_hit')::bigint, 0)         AS heap_blks_hit,
    COALESCE((elem->>'idx_blks_read')::bigint, 0)         AS idx_blks_read,
    COALESCE((elem->>'idx_blks_hit')::bigint, 0)          AS idx_blks_hit,
    COALESCE((elem->>'toast_blks_read')::bigint, 0)       AS toast_blks_read,
    COALESCE((elem->>'toast_blks_hit')::bigint, 0)        AS toast_blks_hit,
    COALESCE((elem->>'tidx_blks_read')::bigint, 0)        AS tidx_blks_read,
    COALESCE((elem->>'tidx_blks_hit')::bigint, 0)         AS tidx_blks_hit
  FROM _zk_stat, jsonb_array_elements(data->'statio_tables') elem
  JOIN zk._zk_tables t ON t.schemaname = elem->>'schema' AND t.tablename = elem->>'table'
  WHERE data->'statio_tables' IS NOT NULL AND data->>'statio_tables' != 'null';

-- ---------------------------------------------------------------------------
-- pg_stat_statements shadow view
-- All version-variant column names exposed; COALESCE normalises old/new names.
-- The ingest layer is version-agnostic: pg_perf_report / ultimate_report pick
-- whichever column they need and it resolves correctly.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_statements AS
  SELECT
    COALESCE((elem->>'queryid')::bigint, 0)                   AS queryid,
    elem->>'query'                                             AS query,
    COALESCE((elem->>'calls')::bigint, 0)                     AS calls,
    COALESCE((elem->>'rows')::bigint, 0)                      AS rows,
    -- exec time (normalised; PG12 stored as total_exec_time from dump)
    COALESCE((elem->>'total_exec_time')::float8, 0)           AS total_exec_time,
    COALESCE((elem->>'total_exec_time')::float8, 0)           AS total_time,      -- PG12 alias
    COALESCE((elem->>'mean_exec_time')::float8, 0)            AS mean_exec_time,
    COALESCE((elem->>'mean_exec_time')::float8, 0)            AS mean_time,       -- PG12 alias
    COALESCE((elem->>'stddev_exec_time')::float8, 0)          AS stddev_exec_time,
    COALESCE((elem->>'stddev_exec_time')::float8, 0)          AS stddev_time,     -- PG12 alias
    COALESCE((elem->>'min_exec_time')::float8, 0)             AS min_exec_time,
    COALESCE((elem->>'max_exec_time')::float8, 0)             AS max_exec_time,
    -- plan time (PG13+; NULL for PG12)
    (elem->>'total_plan_time')::float8                        AS total_plan_time,
    (elem->>'mean_plan_time')::float8                         AS mean_plan_time,
    (elem->>'plans')::bigint                                  AS plans,
    -- block stats
    COALESCE((elem->>'shared_blks_hit')::bigint, 0)           AS shared_blks_hit,
    COALESCE((elem->>'shared_blks_read')::bigint, 0)          AS shared_blks_read,
    COALESCE((elem->>'shared_blks_dirtied')::bigint, 0)       AS shared_blks_dirtied,
    COALESCE((elem->>'shared_blks_written')::bigint, 0)       AS shared_blks_written,
    COALESCE((elem->>'local_blks_hit')::bigint, 0)            AS local_blks_hit,
    COALESCE((elem->>'local_blks_read')::bigint, 0)           AS local_blks_read,
    COALESCE((elem->>'local_blks_dirtied')::bigint, 0)        AS local_blks_dirtied,
    COALESCE((elem->>'local_blks_written')::bigint, 0)        AS local_blks_written,
    COALESCE((elem->>'temp_blks_read')::bigint, 0)            AS temp_blks_read,
    COALESCE((elem->>'temp_blks_written')::bigint, 0)         AS temp_blks_written,
    -- block timing: PG17+ uses shared_blk_read_time; PG12-16 uses blk_read_time
    COALESCE(
      (elem->>'shared_blk_read_time')::float8,
      (elem->>'blk_read_time')::float8, 0)                    AS shared_blk_read_time,
    COALESCE(
      (elem->>'shared_blk_write_time')::float8,
      (elem->>'blk_write_time')::float8, 0)                   AS shared_blk_write_time,
    COALESCE((elem->>'local_blk_read_time')::float8, 0)       AS local_blk_read_time,
    COALESCE((elem->>'local_blk_write_time')::float8, 0)      AS local_blk_write_time,
    COALESCE((elem->>'temp_blk_read_time')::float8, 0)        AS temp_blk_read_time,
    COALESCE((elem->>'temp_blk_write_time')::float8, 0)       AS temp_blk_write_time,
    -- old-name aliases (PG12-16): reports that reference blk_read_time directly
    COALESCE(
      (elem->>'blk_read_time')::float8,
      (elem->>'shared_blk_read_time')::float8, 0)             AS blk_read_time,
    COALESCE(
      (elem->>'blk_write_time')::float8,
      (elem->>'shared_blk_write_time')::float8, 0)            AS blk_write_time,
    -- WAL (PG13+)
    (elem->>'wal_records')::bigint                            AS wal_records,
    (elem->>'wal_bytes')::bigint                              AS wal_bytes,
    -- JIT basic (PG14+)
    COALESCE((elem->>'jit_functions')::bigint, 0)             AS jit_functions,
    COALESCE((elem->>'jit_generation_time')::float8, 0)       AS jit_generation_time,
    -- JIT extended (PG15+)
    COALESCE((elem->>'jit_inlining_time')::float8, 0)         AS jit_inlining_time,
    COALESCE((elem->>'jit_optimization_time')::float8, 0)     AS jit_optimization_time,
    COALESCE((elem->>'jit_emission_time')::float8, 0)         AS jit_emission_time,
    -- misc
    (elem->>'toplevel')::boolean                              AS toplevel,
    (elem->>'stats_since')::timestamptz                       AS stats_since
  FROM _zk_stat, jsonb_array_elements(data->'stat_statements') elem
  WHERE data->'stat_statements' IS NOT NULL AND data->>'stat_statements' != 'null';

-- ---------------------------------------------------------------------------
-- pg_stat_statements_info (PG14+)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_statements_info AS
  SELECT
    (data->'stat_statements_info'->>'dealloc')::bigint      AS dealloc,
    (data->'stat_statements_info'->>'stats_reset')::timestamptz AS stats_reset
  FROM _zk_stat
  WHERE data->'stat_statements_info' IS NOT NULL
    AND data->>'stat_statements_info' != 'null';

-- ---------------------------------------------------------------------------
-- pg_stat_bgwriter / pg_stat_checkpointer shadow views
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_bgwriter AS
  SELECT
    COALESCE((data->'stat_bgwriter'->>'buffers_clean')::bigint, 0)     AS buffers_clean,
    COALESCE((data->'stat_bgwriter'->>'maxwritten_clean')::bigint, 0)  AS maxwritten_clean,
    COALESCE((data->'stat_bgwriter'->>'buffers_alloc')::bigint, 0)     AS buffers_alloc,
    (data->'stat_bgwriter'->>'stats_reset')::timestamptz               AS stats_reset,
    -- PG16 and below also had these columns directly:
    COALESCE((data->'stat_bgwriter'->>'checkpoints_timed')::bigint, 0)   AS checkpoints_timed,
    COALESCE((data->'stat_bgwriter'->>'checkpoints_req')::bigint, 0)     AS checkpoints_req,
    COALESCE((data->'stat_bgwriter'->>'checkpoint_write_time')::float8,0) AS checkpoint_write_time,
    COALESCE((data->'stat_bgwriter'->>'checkpoint_sync_time')::float8, 0) AS checkpoint_sync_time,
    COALESCE((data->'stat_bgwriter'->>'buffers_checkpoint')::bigint, 0)  AS buffers_checkpoint,
    COALESCE((data->'stat_bgwriter'->>'buffers_backend')::bigint, 0)     AS buffers_backend,
    COALESCE((data->'stat_bgwriter'->>'buffers_backend_fsync')::bigint,0) AS buffers_backend_fsync
  FROM _zk_stat;

-- PG17+ split view — backed by same JSON object
CREATE OR REPLACE VIEW zk.pg_stat_checkpointer AS
  SELECT
    COALESCE((data->'stat_bgwriter'->>'checkpoints_timed')::bigint, 0)    AS num_timed,
    COALESCE((data->'stat_bgwriter'->>'checkpoints_req')::bigint, 0)      AS num_requested,
    COALESCE((data->'stat_bgwriter'->>'checkpoint_write_time')::float8,0) AS write_time,
    COALESCE((data->'stat_bgwriter'->>'checkpoint_sync_time')::float8, 0) AS sync_time,
    COALESCE((data->'stat_bgwriter'->>'buffers_checkpoint')::bigint, 0)   AS buffers_written,
    (data->'stat_bgwriter'->>'checkpointer_reset')::timestamptz           AS stats_reset
  FROM _zk_stat;

-- ---------------------------------------------------------------------------
-- pg_stat_database shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_database AS
  SELECT
    elem->>'datname'                                         AS datname,
    COALESCE((elem->>'numbackends')::int, 0)                 AS numbackends,
    COALESCE((elem->>'xact_commit')::bigint, 0)              AS xact_commit,
    COALESCE((elem->>'xact_rollback')::bigint, 0)            AS xact_rollback,
    COALESCE((elem->>'blks_read')::bigint, 0)                AS blks_read,
    COALESCE((elem->>'blks_hit')::bigint, 0)                 AS blks_hit,
    COALESCE((elem->>'tup_returned')::bigint, 0)             AS tup_returned,
    COALESCE((elem->>'tup_fetched')::bigint, 0)              AS tup_fetched,
    COALESCE((elem->>'tup_inserted')::bigint, 0)             AS tup_inserted,
    COALESCE((elem->>'tup_updated')::bigint, 0)              AS tup_updated,
    COALESCE((elem->>'tup_deleted')::bigint, 0)              AS tup_deleted,
    COALESCE((elem->>'conflicts')::bigint, 0)                AS conflicts,
    COALESCE((elem->>'temp_files')::bigint, 0)               AS temp_files,
    COALESCE((elem->>'temp_bytes')::bigint, 0)               AS temp_bytes,
    COALESCE((elem->>'deadlocks')::bigint, 0)                AS deadlocks,
    COALESCE((elem->>'checksum_failures')::bigint, 0)        AS checksum_failures,
    COALESCE((elem->>'blk_read_time')::float8, 0)            AS blk_read_time,
    COALESCE((elem->>'blk_write_time')::float8, 0)           AS blk_write_time,
    (elem->>'stats_reset')::timestamptz                      AS stats_reset
  FROM _zk_stat, jsonb_array_elements(data->'stat_database') elem
  WHERE data->'stat_database' IS NOT NULL AND data->>'stat_database' != 'null';

-- ---------------------------------------------------------------------------
-- pg_stat_replication shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_replication AS
  SELECT
    elem->>'application_name'                     AS application_name,
    (elem->>'client_addr')::inet                  AS client_addr,
    elem->>'state'                                AS state,
    (elem->>'sent_lsn')::pg_lsn                   AS sent_lsn,
    (elem->>'write_lsn')::pg_lsn                  AS write_lsn,
    (elem->>'flush_lsn')::pg_lsn                  AS flush_lsn,
    (elem->>'replay_lsn')::pg_lsn                 AS replay_lsn,
    (elem->>'write_lag')::interval                AS write_lag,
    (elem->>'flush_lag')::interval                AS flush_lag,
    (elem->>'replay_lag')::interval               AS replay_lag,
    elem->>'sync_state'                           AS sync_state,
    (elem->>'backend_start')::timestamptz         AS backend_start
  FROM _zk_stat, jsonb_array_elements(data->'stat_replication') elem
  WHERE data->'stat_replication' IS NOT NULL
    AND data->>'stat_replication' != 'null';

-- ---------------------------------------------------------------------------
-- pg_replication_slots shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_replication_slots AS
  SELECT
    elem->>'slot_name'                              AS slot_name,
    elem->>'plugin'                                 AS plugin,
    elem->>'slot_type'                              AS slot_type,
    elem->>'database'                               AS database,
    (elem->>'active')::boolean                      AS active,
    (elem->>'active_pid')::int                      AS active_pid,
    (elem->>'xmin')::xid                            AS xmin,
    (elem->>'catalog_xmin')::xid                    AS catalog_xmin,
    (elem->>'restart_lsn')::pg_lsn                  AS restart_lsn,
    (elem->>'confirmed_flush_lsn')::pg_lsn          AS confirmed_flush_lsn,
    (elem->>'temporary')::boolean                   AS temporary
  FROM _zk_stat, jsonb_array_elements(data->'replication_slots') elem
  WHERE data->'replication_slots' IS NOT NULL
    AND data->>'replication_slots' != 'null';

-- ---------------------------------------------------------------------------
-- pg_stat_activity shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_activity AS
  SELECT
    (elem->>'pid')::int                            AS pid,
    elem->>'usename'                               AS usename,
    elem->>'backend_type'                          AS backend_type,
    elem->>'wait_event_type'                       AS wait_event_type,
    elem->>'wait_event'                            AS wait_event,
    elem->>'state'                                 AS state,
    (elem->>'wait_secs')::int                      AS query_start_age_secs,
    (elem->>'xact_age_secs')::int                  AS xact_start_age_secs,
    -- Reconstruct approximate timestamps from captured ages
    now() - ((elem->>'wait_secs')::int * interval '1 second')  AS query_start,
    now() - ((elem->>'xact_age_secs')::int * interval '1 second') AS xact_start,
    now()                                          AS state_change,
    NULL::text                                     AS query,
    pg_backend_pid() + 1                           AS fake_other_pid  -- never matches pg_backend_pid()
  FROM _zk_stat, jsonb_array_elements(data->'blocking_sessions') elem
  WHERE data->'blocking_sessions' IS NOT NULL
    AND data->>'blocking_sessions' != 'null';

-- ---------------------------------------------------------------------------
-- pg_locks shadow view — empty (no live lock data in offline snapshot)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_locks AS
  SELECT
    NULL::text    AS locktype,
    NULL::oid     AS relation,
    NULL::text    AS mode,
    NULL::boolean AS granted,
    NULL::int     AS pid
  WHERE false;

-- ---------------------------------------------------------------------------
-- pg_stat_archiver shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_archiver AS
  SELECT
    (data->'stat_archiver'->>'archived_count')::bigint    AS archived_count,
    data->'stat_archiver'->>'last_archived_wal'           AS last_archived_wal,
    (data->'stat_archiver'->>'last_archived_time')::timestamptz AS last_archived_time,
    (data->'stat_archiver'->>'failed_count')::bigint      AS failed_count,
    data->'stat_archiver'->>'last_failed_wal'             AS last_failed_wal,
    (data->'stat_archiver'->>'last_failed_time')::timestamptz  AS last_failed_time,
    (data->'stat_archiver'->>'stats_reset')::timestamptz  AS stats_reset
  FROM _zk_stat
  WHERE data->'stat_archiver' IS NOT NULL;

-- ---------------------------------------------------------------------------
-- pg_stat_progress_vacuum shadow view — empty (in-flight at collection time)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stat_progress_vacuum AS
  SELECT
    NULL::int     AS pid,
    NULL::text    AS datname,
    NULL::oid     AS relid,
    NULL::text    AS phase,
    NULL::bigint  AS heap_blks_total,
    NULL::bigint  AS heap_blks_scanned,
    NULL::bigint  AS heap_blks_vacuumed,
    NULL::bigint  AS index_vacuum_count,
    NULL::bigint  AS indexes_total,
    NULL::bigint  AS indexes_processed,
    NULL::bigint  AS max_dead_tuples,
    NULL::bigint  AS num_dead_tuples
  WHERE false;

-- ---------------------------------------------------------------------------
-- pg_database shadow view (from catalog_snapshot databases section)
-- Note: catalog stores key as 'name' (not 'datname'), encoding as text name
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_database AS
  SELECT
    elem->>'name'                                       AS datname,
    -- encoding: convert stored text name back to integer for pg_encoding_to_char() compat
    pg_char_to_encoding(elem->>'encoding')              AS encoding,
    elem->>'datcollate'                                 AS datcollate,
    elem->>'datctype'                                   AS datctype,
    COALESCE((elem->>'size_bytes')::bigint, 0)          AS pg_database_size_bytes,
    -- datfrozenxid: fabricate from stored xid_age
    ((txid_current()::bigint - COALESCE((elem->>'xid_age')::bigint, 0)) % 4294967296)::text::xid AS datfrozenxid,
    COALESCE((elem->>'xid_age')::int, 0)                AS xid_age_computed,
    true::boolean                                       AS datallowconn,
    false::boolean                                      AS datistemplate
  FROM _zk_catalog, jsonb_array_elements(data->'databases') elem
  WHERE data->'databases' IS NOT NULL;

-- pg_database_size shadow: look up from catalog (text datname arg)
CREATE OR REPLACE FUNCTION zk.pg_database_size(text)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT COALESCE((elem->>'size_bytes')::bigint, 0)
     FROM _zk_catalog, jsonb_array_elements(data->'databases') elem
     WHERE elem->>'name' = $1
     LIMIT 1),
    0
  );
$$;

-- oid overload (not typically used, but guards against accidental calls)
CREATE OR REPLACE FUNCTION zk.pg_database_size(oid)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT 0::bigint;
$$;

-- ---------------------------------------------------------------------------
-- pg_available_extensions / pg_extension shadow views
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_available_extensions AS
  SELECT
    elem->>'name'            AS name,
    elem->>'default_version' AS default_version,
    elem->>'installed_version' AS installed_version,
    elem->>'comment'         AS comment
  FROM _zk_catalog, jsonb_array_elements(data->'available_extensions') elem
  WHERE data->'available_extensions' IS NOT NULL;

CREATE OR REPLACE VIEW zk.pg_extension AS
  SELECT
    elem->>'extname'    AS extname,
    elem->>'extversion' AS extversion
  FROM _zk_catalog, jsonb_array_elements(data->'extensions') elem
  WHERE data->'extensions' IS NOT NULL;

-- ---------------------------------------------------------------------------
-- pg_roles shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_roles AS
  SELECT
    elem->>'rolname'                              AS rolname,
    COALESCE((elem->>'rolsuper')::boolean, false) AS rolsuper,
    COALESCE((elem->>'rolcreaterole')::boolean, false) AS rolcreaterole,
    COALESCE((elem->>'rolcreatedb')::boolean, false)   AS rolcreatedb,
    COALESCE((elem->>'rolcanlogin')::boolean, false)   AS rolcanlogin,
    COALESCE((elem->>'rolreplication')::boolean, false) AS rolreplication,
    elem->>'pwd_type'                             AS rolpassword,
    (elem->>'rolvaliduntil')::timestamptz         AS rolvaliduntil,
    COALESCE((elem->>'rolconnlimit')::int, -1)    AS rolconnlimit
  FROM _zk_catalog, jsonb_array_elements(data->'roles') elem
  WHERE data->'roles' IS NOT NULL;

-- ---------------------------------------------------------------------------
-- pg_settings shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_settings AS
  SELECT
    elem->>'name'        AS name,
    elem->>'setting'     AS setting,
    elem->>'unit'        AS unit,
    elem->>'category'    AS category,
    elem->>'short_desc'  AS short_desc,
    elem->>'source'      AS source,
    elem->>'sourcefile'  AS sourcefile
  FROM _zk_catalog, jsonb_array_elements(data->'settings_key') elem
  WHERE data->'settings_key' IS NOT NULL;

-- current_setting shadow: look up from settings_key
CREATE OR REPLACE FUNCTION zk.current_setting(text)
RETURNS text LANGUAGE sql STABLE AS $$
  -- server_version_num and server_version come from stat meta (not in settings_key)
  SELECT CASE $1
    WHEN 'server_version_num' THEN
      (SELECT data->'_meta'->>'pg_version_num' FROM _zk_stat LIMIT 1)
    WHEN 'server_version' THEN
      (SELECT regexp_replace(data->'_meta'->>'pg_version', '^PostgreSQL ([0-9]+\.[0-9]+).*', '\1')
       FROM _zk_stat LIMIT 1)
    ELSE
      (SELECT elem->>'setting'
       FROM _zk_catalog, jsonb_array_elements(data->'settings_key') elem
       WHERE elem->>'name' = $1
       LIMIT 1)
  END;
$$;

-- two-arg variant (missing_ok)
CREATE OR REPLACE FUNCTION zk.current_setting(text, boolean)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE $1
    WHEN 'server_version_num' THEN
      (SELECT data->'_meta'->>'pg_version_num' FROM _zk_stat LIMIT 1)
    WHEN 'server_version' THEN
      (SELECT regexp_replace(data->'_meta'->>'pg_version', '^PostgreSQL ([0-9]+\.[0-9]+).*', '\1')
       FROM _zk_stat LIMIT 1)
    ELSE
      (SELECT elem->>'setting'
       FROM _zk_catalog, jsonb_array_elements(data->'settings_key') elem
       WHERE elem->>'name' = $1
       LIMIT 1)
  END;
$$;

-- ---------------------------------------------------------------------------
-- pg_sequences shadow view
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_sequences AS
  SELECT
    elem->>'schema'         AS schemaname,
    elem->>'sequence_name'  AS sequencename,
    (elem->>'last_value')::bigint  AS last_value,
    (elem->>'min_value')::bigint   AS min_value,
    (elem->>'max_value')::bigint   AS max_value,
    (elem->>'increment_by')::bigint AS increment_by,
    (elem->>'cycle')::boolean      AS cycle_option,
    (elem->>'cache_size')::bigint  AS cache_size,
    (elem->>'data_type')::regtype  AS data_type
  FROM _zk_catalog, jsonb_array_elements(data->'sequences') elem
  WHERE data->'sequences' IS NOT NULL AND data->>'sequences' != 'null';

-- ---------------------------------------------------------------------------
-- pg_stats shadow view (planner stats, for bloat estimates)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_stats AS
  SELECT
    elem->>'schema'                                AS schemaname,
    elem->>'table'                                 AS tablename,
    elem->>'column'                                AS attname,
    COALESCE((elem->>'null_frac')::float4, 0)      AS null_frac,
    COALESCE((elem->>'avg_width')::int, 0)         AS avg_width,
    COALESCE((elem->>'n_distinct')::float4, 0)     AS n_distinct,
    COALESCE((elem->>'correlation')::float4, 0)    AS correlation
  FROM _zk_catalog, jsonb_array_elements(data->'planner_stats') elem
  WHERE data->'planner_stats' IS NOT NULL AND data->>'planner_stats' != 'null';

-- ---------------------------------------------------------------------------
-- pg_constraint / pg_attribute — empty (complex joins use pre-computed JSON)
-- Queries needing FK+index cross-join will use dup_indexes / unindexed_fks
-- from the catalog JSON directly via the pre-computed views below.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.pg_constraint AS
  SELECT
    NULL::oid    AS oid,
    NULL::text   AS conname,
    NULL::oid    AS conrelid,
    NULL::char   AS contype,
    NULL::int2[] AS conkey,
    NULL::int2[] AS confkey,
    NULL::oid    AS confrelid
  WHERE false;

CREATE OR REPLACE VIEW zk.pg_attribute AS
  SELECT
    NULL::oid   AS attrelid,
    NULL::text  AS attname,
    NULL::int2  AS attnum,
    NULL::bool  AS attnotnull
  WHERE false;

-- ---------------------------------------------------------------------------
-- Pre-computed analysis views (avoid needing complex OID joins)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW zk.v_dup_indexes_precomputed AS
  SELECT
    elem->>'schema'      AS schema,
    elem->>'table'       AS tbl,
    elem->>'index_cols'  AS index_cols,
    elem->'indexes'      AS index_names
  FROM _zk_stat, jsonb_array_elements(data->'dup_indexes') elem
  WHERE data->'dup_indexes' IS NOT NULL
    AND data->>'dup_indexes' != 'null';

CREATE OR REPLACE VIEW zk.v_unindexed_fks_precomputed AS
  SELECT
    elem->>'schema'           AS schema,
    elem->>'table'            AS tbl,
    elem->>'constraint_name'  AS constraint_name,
    elem->>'fk_columns'       AS fk_columns,
    elem->>'ref_table'        AS ref_table
  FROM _zk_catalog, jsonb_array_elements(data->'unindexed_fks') elem
  WHERE data->'unindexed_fks' IS NOT NULL
    AND data->>'unindexed_fks' != 'null';

CREATE OR REPLACE VIEW zk.v_bloat_precomputed AS
  SELECT
    elem->>'schema'                               AS schemaname,
    elem->>'table'                                AS tablename,
    COALESCE((elem->>'tbloat')::numeric, 0)       AS tbloat,
    COALESCE((elem->>'wasted_bytes')::bigint, 0)  AS wasted_bytes,
    COALESCE((elem->>'ibloat')::numeric, 0)       AS ibloat,
    COALESCE((elem->>'wasted_ibytes')::bigint, 0) AS wasted_ibytes
  FROM _zk_catalog, jsonb_array_elements(data->'bloat_computed') elem
  WHERE data->'bloat_computed' IS NOT NULL
    AND data->>'bloat_computed' != 'null';

-- ---------------------------------------------------------------------------
-- Verify shadow schema is complete
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_ver text;
  v_db  text;
BEGIN
  SELECT zk.version()                          INTO v_ver;
  SELECT data->'_meta'->>'database'
  FROM _zk_stat LIMIT 1                        INTO v_db;
  RAISE NOTICE 'ZK ingest complete. Replaying bundle: % / DB: %', v_ver, v_db;
END $$;
