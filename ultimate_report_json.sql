\set QUIET 1
\pset format unaligned
\pset tuples_only on
\pset footer off

-- Detect version
SELECT current_setting('server_version') as pg_version,
       (current_setting('server_version_num')::int / 10000) as major_ver \gset

SELECT (:major_ver >= 13) as is_pg13, (:major_ver >= 15) as is_pg15 \gset

\if :is_pg13
    \set total_exec_time total_exec_time
\else
    \set total_exec_time total_time
\endif

WITH RECURSIVE
constants AS (SELECT current_setting('block_size')::numeric AS bs),

v_ver AS (
    SELECT current_setting('server_version') AS ver,
           substring(current_setting('server_version') FROM '^[0-9]+')::int AS major_ver
),

v_ext AS (
    SELECT name, installed_version, default_version,
           CASE WHEN installed_version <> default_version THEN 'UPDATE' ELSE 'OK' END AS status
    FROM pg_available_extensions WHERE installed_version IS NOT NULL
),

v_db_info AS (
    SELECT datname, pg_encoding_to_char(encoding) AS enc, datcollate,
           pg_size_pretty(pg_database_size(datname)) AS size
    FROM pg_database WHERE datallowconn AND NOT datistemplate
),

v_archiving AS (
    SELECT
        CASE WHEN NOT has_table_privilege('pg_stat_archiver', 'select') THEN 'PERMISSION_DENIED'
             ELSE (SELECT CASE WHEN archived_count IS NULL THEN 'ARCHIVING_DISABLED'
                               WHEN failed_count > 0          THEN 'FAILURES'
                               ELSE 'OK' END FROM pg_stat_archiver) END AS status,
        CASE WHEN has_table_privilege('pg_stat_archiver', 'select')
             THEN (SELECT COALESCE(archived_count, 0) FROM pg_stat_archiver) ELSE 0 END AS archived_count,
        CASE WHEN has_table_privilege('pg_stat_archiver', 'select')
             THEN (SELECT COALESCE(failed_count, 0) FROM pg_stat_archiver) ELSE 0 END AS failed_count,
        CASE WHEN has_table_privilege('pg_stat_archiver', 'select')
             THEN (SELECT COALESCE(to_char(last_failed_time, 'DD/MM HH24:MI'), 'N/A') FROM pg_stat_archiver)
             ELSE 'N/A' END AS last_fail
),

v_repl AS (
    SELECT
        CASE WHEN pg_is_in_recovery() THEN 'STANDBY_MODE'
             WHEN (SELECT COUNT(*) FROM pg_stat_replication) = 0 THEN 'PRIMARY_NO_REPLICAS'
             ELSE 'PRIMARY_WITH_REPLICAS' END AS status,
        CASE WHEN pg_is_in_recovery() THEN 'Server is in recovery/standby mode'
             ELSE (SELECT COALESCE(
                     STRING_AGG(application_name || ' (' || state || ') lag=' ||
                       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), ', '),
                     'No replicas connected')
                   FROM pg_stat_replication) END AS details
),

v_slots AS (
    SELECT slot_name, slot_type,
           CASE WHEN active THEN 'ACTIVE' ELSE 'INACTIVE' END AS status,
           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained,
           CASE WHEN NOT active AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824 THEN 'CRITICAL'
                WHEN NOT active THEN 'WARNING' ELSE 'OK' END AS risk
    FROM pg_replication_slots
    WHERE (SELECT has_table_privilege('pg_replication_slots', 'select'))
),

v_bloat AS (
    SELECT schemaname, tablename,
           ROUND((CASE WHEN otta=0 THEN 0.0 ELSE relpages::FLOAT/NULLIF(otta,0) END)::NUMERIC, 1) AS tbloat,
           pg_size_pretty(((relpages - otta) * (SELECT bs FROM constants))::bigint) AS wasted
    FROM (
        SELECT schemaname, tablename, cc.relpages,
               CEIL((cc.reltuples * ((23+8)+4)) / NULLIF((SELECT bs FROM constants) - 20, 0)) AS otta
        FROM pg_stats s
        JOIN pg_class cc ON cc.relname = s.tablename
        JOIN pg_namespace nn ON cc.relnamespace = nn.oid AND nn.nspname = s.schemaname
        WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema')
        GROUP BY schemaname, tablename, cc.relpages, cc.reltuples
    ) foo WHERE relpages > otta
),

v_idx_duplicate AS (
    SELECT n.nspname || '.' || c.relname AS tbl,
           array_agg(indexrelid::regclass)::text AS indexes,
           pg_size_pretty(SUM(pg_relation_size(indexrelid))::bigint) AS size
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    GROUP BY n.nspname, c.relname, indrelid, indkey, indclass, indoption, indexprs, indpred
    HAVING count(*) > 1
),

v_idx_ineff AS (
    SELECT schemaname, relname, indexrelname, idx_scan,
           ROUND((idx_tup_read::numeric / NULLIF(idx_tup_fetch, 0)), 2) AS ratio,
           pg_size_pretty(pg_relation_size(indexrelid)) AS idx_size
    FROM pg_stat_user_indexes
    WHERE idx_scan > 50 AND (idx_tup_read::numeric / NULLIF(idx_tup_fetch, 0)) > 100
),

v_missing_idx AS (
    SELECT schemaname, relname,
           pg_size_pretty(pg_total_relation_size(relid)) AS table_size,
           seq_scan, seq_tup_read, idx_scan
    FROM pg_stat_user_tables
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
      AND pg_total_relation_size(relid) > 10485760
      AND seq_scan > 100
      AND seq_tup_read > 1000000
),

v_fk_unindexed AS (
    SELECT n1.nspname || '.' || c1.relname AS tbl, a1.attname AS col
    FROM pg_constraint t
    JOIN pg_attribute a1 ON a1.attrelid = t.conrelid AND a1.attnum = t.conkey[1]
    JOIN pg_class c1 ON c1.oid = t.conrelid
    JOIN pg_namespace n1 ON n1.oid = c1.relnamespace
    WHERE t.contype = 'f'
      AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = t.conrelid AND i.indkey[0] = t.conkey[1])
),

v_wrap AS (
    SELECT datname, age(datfrozenxid) AS xid_age,
           ROUND((100 * age(datfrozenxid) / NULLIF(current_setting('autovacuum_freeze_max_age')::bigint, 0))::numeric, 1) AS pct,
           CASE WHEN age(datfrozenxid) > (0.9 * current_setting('autovacuum_freeze_max_age')::bigint) THEN 'CRITICAL'
                WHEN age(datfrozenxid) > (0.75 * current_setting('autovacuum_freeze_max_age')::bigint) THEN 'WARNING'
                ELSE 'OK' END AS status
    FROM pg_database
    WHERE datallowconn AND age(datfrozenxid) > 50000000
),

v_locks AS (
    SELECT pid, usename, backend_type,
           pg_blocking_pids(pid)::text AS blockers,
           wait_event_type, wait_event,
           CASE WHEN state = 'idle in transaction' THEN 'IDLE_IN_XACT_RISK'
                WHEN wait_event_type IS NOT NULL     THEN 'BLOCKED'
                ELSE state END AS actual_status,
           EXTRACT(EPOCH FROM (now() - query_start))::int AS wait_secs,
           substring(query, 1, 200) AS query_snippet
    FROM pg_stat_activity
    WHERE pg_blocking_pids(pid) <> '{}'
       OR (state = 'idle in transaction' AND (now() - xact_start) > interval '5 minutes')
),

v_secu AS (
    SELECT rolname,
           CASE WHEN rolsuper THEN 'SUPERUSER' ELSE 'NORMAL' END AS role_type,
           CASE WHEN NOT rolcanlogin THEN 'NO_LOGIN'
                WHEN rolpassword IS NULL THEN 'NOPASS_UNSAFE'
                WHEN rolpassword LIKE '%SCRAM%' THEN 'SCRAM_HASHED'
                WHEN rolpassword LIKE '%md5%'   THEN 'MD5_WEAK'
                ELSE 'OTHER' END AS pwd_status,
           CASE WHEN rolsuper OR rolcreaterole OR rolreplication THEN 'HIGH' ELSE 'OK' END AS risk
    FROM pg_roles WHERE rolname NOT LIKE 'pg_%'
),

v_seq AS (
    SELECT schemaname, sequencename, last_value, max_value,
           ROUND((last_value::numeric / NULLIF(max_value::numeric, 0)) * 100, 1) AS pct_used,
           CASE WHEN last_value::numeric / NULLIF(max_value::numeric, 0) > 0.95 THEN 'CRITICAL'
                ELSE 'OK' END AS status
    FROM pg_sequences
    WHERE (last_value::numeric / NULLIF(max_value::numeric, 0)) > 0.5
),

v_settings AS (
    SELECT name, setting, unit,
           CASE WHEN name = 'fsync'           AND setting = 'off' THEN 'CRITICAL: DATA LOSS'
                WHEN name = 'full_page_writes' AND setting = 'off' THEN 'CRITICAL: CORRUPTION'
                ELSE 'OK' END AS risk
    FROM pg_settings
    WHERE name IN ('fsync', 'full_page_writes', 'wal_level', 'max_connections', 'password_encryption')
),

v_buffer_health AS (
    SELECT ROUND(sum(heap_blks_hit)::numeric /
                 NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0) * 100, 1) AS hit_ratio_pct
    FROM pg_statio_user_tables
),

-- Functions/procedures with security risk flags
v_functions AS (
  SELECT n.nspname AS schema, p.proname AS name,
    l.lanname AS language,
    CASE p.prokind
      WHEN 'f' THEN 'FUNCTION'
      WHEN 'p' THEN 'PROCEDURE'
      WHEN 'a' THEN 'AGGREGATE'
      WHEN 'w' THEN 'WINDOW'
      ELSE 'FUNCTION' END                                         AS kind,
    p.prosecdef                                                   AS security_definer,
    CASE p.provolatile
      WHEN 'i' THEN 'immutable'
      WHEN 's' THEN 'stable'
      ELSE 'volatile' END                                         AS volatility,
    CASE
      WHEN p.prosecdef                        THEN 'HIGH'
      WHEN p.provolatile = 'v'
           AND l.lanname NOT IN ('internal','c') THEN 'WATCH'
      ELSE 'OK' END                                               AS risk
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l  ON l.oid = p.prolang
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  ORDER BY p.prosecdef DESC, l.lanname, n.nspname, p.proname
),

-- Trigger inventory
v_triggers AS (
  SELECT
    n.nspname                                                     AS schema,
    c.relname                                                     AS table_name,
    t.tgname                                                      AS trigger_name,
    t.tgenabled <> 'D'                                            AS enabled,
    CASE
      WHEN (t.tgtype &  2) <> 0 THEN 'BEFORE'
      WHEN (t.tgtype & 64) <> 0 THEN 'INSTEAD OF'
      ELSE 'AFTER' END                                            AS timing,
    array_to_string(array_remove(ARRAY[
      CASE WHEN (t.tgtype &  4) <> 0 THEN 'INSERT'   END,
      CASE WHEN (t.tgtype &  8) <> 0 THEN 'DELETE'   END,
      CASE WHEN (t.tgtype & 16) <> 0 THEN 'UPDATE'   END,
      CASE WHEN (t.tgtype & 32) <> 0 THEN 'TRUNCATE' END
    ], NULL), '/')                                                AS events,
    CASE WHEN (t.tgtype & 1) <> 0 THEN 'ROW' ELSE 'STATEMENT' END AS orientation,
    fn.nspname || '.' || p.proname                                AS trigger_function
  FROM pg_trigger t
  JOIN pg_class c       ON c.oid = t.tgrelid
  JOIN pg_namespace n   ON n.oid = c.relnamespace
  JOIN pg_proc p        ON p.oid = t.tgfoid
  JOIN pg_namespace fn  ON fn.oid = p.pronamespace
  WHERE NOT t.tgisinternal
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  ORDER BY n.nspname, c.relname, t.tgname
),

-- Materialized views
v_mat_views AS (
  SELECT
    schemaname AS schema,
    matviewname AS name,
    matviewowner AS owner,
    ispopulated,
    CASE WHEN NOT ispopulated THEN 'STALE' ELSE 'OK' END AS status
  FROM pg_matviews
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  ORDER BY schemaname, matviewname
),

-- RLS policies
v_policies AS (
  SELECT
    n.nspname                                                     AS schema,
    c.relname                                                     AS table_name,
    c.relrowsecurity                                              AS rls_enabled,
    c.relforcerowsecurity                                         AS rls_forced,
    p.polname                                                     AS policy_name,
    CASE p.polcmd
      WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT'
      WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE'
      ELSE 'ALL' END                                              AS cmd,
    p.polpermissive                                               AS permissive
  FROM pg_policy p
  JOIN pg_class c     ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  ORDER BY n.nspname, c.relname, p.polname
),

-- Rules (excluding default view _RETURN rules)
v_rules AS (
  SELECT n.nspname AS schema, c.relname AS tablename, r.rulename,
    CASE r.ev_type
      WHEN '1' THEN 'SELECT'
      WHEN '2' THEN 'UPDATE'
      WHEN '3' THEN 'INSERT'
      WHEN '4' THEN 'DELETE'
      ELSE r.ev_type::text END AS event,
    r.is_instead AS do_instead,
    pg_get_ruledef(r.oid) AS definition
  FROM pg_rewrite r
  JOIN pg_class c     ON c.oid = r.ev_class
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND r.rulename <> '_RETURN'
  ORDER BY n.nspname, c.relname, r.rulename
)

SELECT json_build_object(
  'report',              'ultimate_audit',
  'pg_version',          (SELECT ver FROM v_ver),
  'generated_at',        now(),
  'buffer_hit_ratio_pct',(SELECT hit_ratio_pct FROM v_buffer_health),
  'extensions',          (SELECT COALESCE(json_agg(row_to_json(e)), '[]'::json) FROM (SELECT * FROM v_ext) e),
  'databases',           (SELECT COALESCE(json_agg(row_to_json(d)), '[]'::json) FROM (SELECT * FROM v_db_info) d),
  'archiving',           (SELECT row_to_json(a) FROM (SELECT * FROM v_archiving) a),
  'replication',         (SELECT row_to_json(r) FROM (SELECT * FROM v_repl) r),
  'replication_slots',   (SELECT COALESCE(json_agg(row_to_json(s)), '[]'::json) FROM (SELECT * FROM v_slots) s),
  'bloat',               (SELECT COALESCE(json_agg(row_to_json(b)), '[]'::json) FROM (SELECT * FROM v_bloat LIMIT 20) b),
  'duplicate_indexes',   (SELECT COALESCE(json_agg(row_to_json(i)), '[]'::json) FROM (SELECT * FROM v_idx_duplicate) i),
  'inefficient_indexes', (SELECT COALESCE(json_agg(row_to_json(i)), '[]'::json) FROM (SELECT * FROM v_idx_ineff) i),
  'missing_indexes',     (SELECT COALESCE(json_agg(row_to_json(m)), '[]'::json) FROM (SELECT * FROM v_missing_idx LIMIT 10) m),
  'unindexed_fk',        (SELECT COALESCE(json_agg(row_to_json(f)), '[]'::json) FROM (SELECT * FROM v_fk_unindexed) f),
  'wraparound_risk',     (SELECT COALESCE(json_agg(row_to_json(w)), '[]'::json) FROM (SELECT * FROM v_wrap) w),
  'blocking_locks',      (SELECT COALESCE(json_agg(row_to_json(l)), '[]'::json) FROM (SELECT * FROM v_locks) l),
  'roles_security',      (SELECT COALESCE(json_agg(row_to_json(s)), '[]'::json) FROM (SELECT * FROM v_secu) s),
  'sequences_at_risk',   (SELECT COALESCE(json_agg(row_to_json(s)), '[]'::json) FROM (SELECT * FROM v_seq) s),
  'critical_settings',   (SELECT COALESCE(json_agg(row_to_json(s)), '[]'::json) FROM (SELECT * FROM v_settings) s),
  'functions',           (SELECT COALESCE(json_agg(row_to_json(f)), '[]'::json) FROM (SELECT * FROM v_functions) f),
  'triggers',            (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM v_triggers) t),
  'mat_views',           (SELECT COALESCE(json_agg(row_to_json(m)), '[]'::json) FROM (SELECT * FROM v_mat_views) m),
  'policies',            (SELECT COALESCE(json_agg(row_to_json(p)), '[]'::json) FROM (SELECT * FROM v_policies) p),
  'rules',               (SELECT COALESCE(json_agg(row_to_json(r)), '[]'::json) FROM (SELECT * FROM v_rules) r)
);
