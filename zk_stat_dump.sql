-- =============================================================================
--  ZK Stat Dump  v1.0
--  Zero Knowledge statistics/activity snapshot — no user data collected
--
--  What it captures:
--    pg_stat_statements, pg_stat_all_tables, pg_statio_all_tables,
--    pg_stat_user_indexes, pg_stat_bgwriter, pg_stat_database,
--    pg_stat_replication, pg_replication_slots, pg_stat_activity (summary),
--    pg_locks (summary), autovacuum queue, bloat estimates
--
--  Usage:
--    psql -U <user> -d <db> -A -t -q -f zk_stat_dump.sql -o stat_snapshot.json
--
--  Output: single JSON document to stdout
--  Requires: pg_stat_statements extension loaded (optional — section omitted if absent)
-- =============================================================================

\pset format unaligned
\pset tuples_only on
\pset pager off

-- Detect version for conditional bgwriter/checkpointer branching
SELECT
  (current_setting('server_version_num')::int / 10000) AS major_ver,
  (current_setting('server_version_num')::int >= 170000) AS is_pg17
\gset

WITH

-- ---------------------------------------------------------------------------
meta AS (
  SELECT json_build_object(
    'type',           'zk_stat_dump',
    'version',        '1.0',
    'generated_at',   now(),
    'pg_version',     version(),
    'pg_version_num', current_setting('server_version_num')::int,
    'database',       current_database(),
    'pg_uptime',      now() - pg_postmaster_start_time(),
    'stats_reset_global', (SELECT stats_reset FROM pg_stat_bgwriter)
  ) AS v
),

-- ---------------------------------------------------------------------------
-- pg_stat_statements — query performance fingerprints
-- NOTE: query text is included; omit 'query' field if full anonymity is needed
-- PG17 renamed blk_read_time/blk_write_time → shared_blk_read_time/shared_blk_write_time
\if :is_pg17
stat_statements AS (
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
    THEN (
      SELECT json_agg(json_build_object(
        'queryid',             queryid,
        'query',               query,
        'calls',               calls,
        'total_exec_time',     round(total_exec_time::numeric, 2),
        'mean_exec_time',      round(mean_exec_time::numeric, 2),
        'stddev_exec_time',    round(stddev_exec_time::numeric, 2),
        'min_exec_time',       round(min_exec_time::numeric, 2),
        'max_exec_time',       round(max_exec_time::numeric, 2),
        'rows',                rows,
        'shared_blks_hit',     shared_blks_hit,
        'shared_blks_read',    shared_blks_read,
        'shared_blks_dirtied', shared_blks_dirtied,
        'shared_blks_written', shared_blks_written,
        'local_blks_hit',      local_blks_hit,
        'local_blks_read',     local_blks_read,
        'temp_blks_read',      temp_blks_read,
        'temp_blks_written',   temp_blks_written,
        'shared_blk_read_time',  round(shared_blk_read_time::numeric, 2),
        'shared_blk_write_time', round(shared_blk_write_time::numeric, 2),
        'local_blk_read_time',   round(local_blk_read_time::numeric, 2),
        'local_blk_write_time',  round(local_blk_write_time::numeric, 2),
        'temp_blk_read_time',    round(temp_blk_read_time::numeric, 2),
        'temp_blk_write_time',   round(temp_blk_write_time::numeric, 2),
        'wal_records',         wal_records,
        'wal_bytes',           wal_bytes,
        'total_plan_time',     round(total_plan_time::numeric, 2),
        'jit_functions',       jit_functions,
        'jit_generation_time', round(jit_generation_time::numeric, 2),
        'toplevel',            toplevel
      ) ORDER BY total_exec_time DESC)
      FROM pg_stat_statements
    )
    ELSE NULL
  END AS v
),
\else
stat_statements AS (
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
    THEN (
      SELECT json_agg(json_build_object(
        'queryid',           queryid,
        'query',             query,
        'calls',             calls,
        'total_exec_time',   round(total_exec_time::numeric, 2),
        'mean_exec_time',    round(mean_exec_time::numeric, 2),
        'stddev_exec_time',  round(stddev_exec_time::numeric, 2),
        'min_exec_time',     round(min_exec_time::numeric, 2),
        'max_exec_time',     round(max_exec_time::numeric, 2),
        'rows',              rows,
        'shared_blks_hit',   shared_blks_hit,
        'shared_blks_read',  shared_blks_read,
        'shared_blks_dirtied', shared_blks_dirtied,
        'shared_blks_written', shared_blks_written,
        'local_blks_hit',    local_blks_hit,
        'local_blks_read',   local_blks_read,
        'temp_blks_read',    temp_blks_read,
        'temp_blks_written', temp_blks_written,
        'blk_read_time',     round(blk_read_time::numeric, 2),
        'blk_write_time',    round(blk_write_time::numeric, 2),
        'wal_records',       wal_records,
        'wal_bytes',         wal_bytes,
        'total_plan_time',   CASE WHEN :major_ver >= 13 THEN round(total_plan_time::numeric, 2) END,
        'jit_functions',     CASE WHEN :major_ver >= 11 THEN jit_functions END,
        'jit_generation_time', CASE WHEN :major_ver >= 11 THEN round(jit_generation_time::numeric, 2) END,
        'toplevel',          CASE WHEN :major_ver >= 14 THEN toplevel END
      ) ORDER BY total_exec_time DESC)
      FROM pg_stat_statements
    )
    ELSE NULL
  END AS v
),
\endif

-- ---------------------------------------------------------------------------
stat_tables AS (
  SELECT json_agg(json_build_object(
    'schema',              schemaname,
    'table',               relname,
    'seq_scan',            seq_scan,
    'seq_tup_read',        seq_tup_read,
    'idx_scan',            idx_scan,
    'idx_tup_fetch',       idx_tup_fetch,
    'n_tup_ins',           n_tup_ins,
    'n_tup_upd',           n_tup_upd,
    'n_tup_del',           n_tup_del,
    'n_tup_hot_upd',       n_tup_hot_upd,
    'n_live_tup',          n_live_tup,
    'n_dead_tup',          n_dead_tup,
    'n_mod_since_analyze', n_mod_since_analyze,
    'n_ins_since_vacuum',  n_ins_since_vacuum,
    'last_vacuum',         last_vacuum,
    'last_autovacuum',     last_autovacuum,
    'last_analyze',        last_analyze,
    'last_autoanalyze',    last_autoanalyze,
    'vacuum_count',        vacuum_count,
    'autovacuum_count',    autovacuum_count,
    'analyze_count',       analyze_count,
    'autoanalyze_count',   autoanalyze_count
  ) ORDER BY schemaname, relname) AS v
  FROM pg_stat_all_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
statio_tables AS (
  SELECT json_agg(json_build_object(
    'schema',            schemaname,
    'table',             relname,
    'heap_blks_read',    heap_blks_read,
    'heap_blks_hit',     heap_blks_hit,
    'idx_blks_read',     idx_blks_read,
    'idx_blks_hit',      idx_blks_hit,
    'toast_blks_read',   toast_blks_read,
    'toast_blks_hit',    toast_blks_hit,
    'tidx_blks_read',    tidx_blks_read,
    'tidx_blks_hit',     tidx_blks_hit,
    'cache_hit_ratio',   CASE WHEN (heap_blks_read + heap_blks_hit) > 0
                           THEN round(100.0 * heap_blks_hit / (heap_blks_read + heap_blks_hit), 2)
                         END
  ) ORDER BY schemaname, relname) AS v
  FROM pg_statio_all_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
stat_indexes AS (
  SELECT json_agg(json_build_object(
    'schema',        schemaname,
    'table',         relname,
    'index',         indexrelname,
    'idx_scan',      idx_scan,
    'idx_tup_read',  idx_tup_read,
    'idx_tup_fetch', idx_tup_fetch,
    'size_bytes',    pg_relation_size(si.indexrelid),
    'is_unique',     ix.indisunique,
    'is_primary',    ix.indisprimary,
    'is_valid',      ix.indisvalid
  ) ORDER BY schemaname, relname, indexrelname) AS v
  FROM pg_stat_user_indexes si
  JOIN pg_index ix ON ix.indexrelid = si.indexrelid
),

-- ---------------------------------------------------------------------------
-- pg_stat_bgwriter: PG17 split bgwriter — checkpointer stats moved to
-- pg_stat_checkpointer. psql \if selects the right branch at parse time.
\if :is_pg17
stat_bgwriter AS (
  SELECT json_build_object(
    'pg17_split',          true,
    'buffers_clean',       b.buffers_clean,
    'maxwritten_clean',    b.maxwritten_clean,
    'buffers_alloc',       b.buffers_alloc,
    'stats_reset',         b.stats_reset,
    'checkpoints_timed',   c.num_timed,
    'checkpoints_req',     c.num_requested,
    'checkpoint_write_time', c.write_time,
    'checkpoint_sync_time',  c.sync_time,
    'buffers_checkpoint',  c.buffers_written,
    'checkpointer_reset',  c.stats_reset
  ) AS v
  FROM pg_stat_bgwriter b, pg_stat_checkpointer c
),
\else
stat_bgwriter AS (
  SELECT json_build_object(
    'pg17_split',          false,
    'checkpoints_timed',   checkpoints_timed,
    'checkpoints_req',     checkpoints_req,
    'checkpoint_write_time', checkpoint_write_time,
    'checkpoint_sync_time',  checkpoint_sync_time,
    'buffers_checkpoint',  buffers_checkpoint,
    'buffers_clean',       buffers_clean,
    'maxwritten_clean',    maxwritten_clean,
    'buffers_backend',     buffers_backend,
    'buffers_backend_fsync', buffers_backend_fsync,
    'buffers_alloc',       buffers_alloc,
    'stats_reset',         stats_reset,
    'checkpoint_req_ratio', CASE WHEN (checkpoints_timed + checkpoints_req) > 0
      THEN round(100.0 * checkpoints_req / (checkpoints_timed + checkpoints_req), 2)
    END
  ) AS v
  FROM pg_stat_bgwriter
),
\endif

-- ---------------------------------------------------------------------------
stat_database AS (
  SELECT json_agg(json_build_object(
    'datname',         datname,
    'numbackends',     numbackends,
    'xact_commit',     xact_commit,
    'xact_rollback',   xact_rollback,
    'blks_read',       blks_read,
    'blks_hit',        blks_hit,
    'cache_hit_ratio', CASE WHEN (blks_read + blks_hit) > 0
                         THEN round(100.0 * blks_hit / (blks_read + blks_hit), 2)
                       END,
    'tup_returned',    tup_returned,
    'tup_fetched',     tup_fetched,
    'tup_inserted',    tup_inserted,
    'tup_updated',     tup_updated,
    'tup_deleted',     tup_deleted,
    'conflicts',       conflicts,
    'temp_files',      temp_files,
    'temp_bytes',      temp_bytes,
    'deadlocks',       deadlocks,
    'checksum_failures', checksum_failures,
    'blk_read_time',   round(blk_read_time::numeric, 2),
    'blk_write_time',  round(blk_write_time::numeric, 2),
    'stats_reset',     stats_reset
  ) ORDER BY datname) AS v
  FROM pg_stat_database
),

-- ---------------------------------------------------------------------------
stat_replication AS (
  SELECT json_agg(json_build_object(
    'client_addr',     client_addr,
    'state',           state,
    'sent_lsn',        sent_lsn,
    'write_lsn',       write_lsn,
    'flush_lsn',       flush_lsn,
    'replay_lsn',      replay_lsn,
    'write_lag',       write_lag,
    'flush_lag',       flush_lag,
    'replay_lag',      replay_lag,
    'sync_state',      sync_state,
    'backend_start',   backend_start
  ) ORDER BY client_addr) AS v
  FROM pg_stat_replication
),

-- ---------------------------------------------------------------------------
replication_slots AS (
  SELECT json_agg(json_build_object(
    'slot_name',      slot_name,
    'plugin',         plugin,
    'slot_type',      slot_type,
    'database',       database,
    'active',         active,
    'active_pid',     active_pid,
    'xmin',           xmin,
    'catalog_xmin',   catalog_xmin,
    'restart_lsn',    restart_lsn,
    'confirmed_flush_lsn', confirmed_flush_lsn,
    'wal_lag_bytes',  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn),
    'temporary',      temporary
  ) ORDER BY slot_name) AS v
  FROM pg_replication_slots
),

-- ---------------------------------------------------------------------------
-- Activity summary — NO query text, just session counts by state
activity_summary AS (
  SELECT json_build_object(
    'total_connections',  count(*),
    'active',             count(*) FILTER (WHERE state = 'active'),
    'idle',               count(*) FILTER (WHERE state = 'idle'),
    'idle_in_transaction',count(*) FILTER (WHERE state = 'idle in transaction'),
    'waiting_on_lock',    count(*) FILTER (WHERE wait_event_type = 'Lock'),
    'oldest_xact_sec',    round(extract(epoch FROM max(now() - xact_start))::numeric, 1),
    'oldest_client_sec',  round(extract(epoch FROM max(now() - state_change))::numeric, 1),
    'max_idle_in_tx_sec', round(extract(epoch FROM max(
                            CASE WHEN state = 'idle in transaction' THEN now() - state_change END
                          ))::numeric, 1),
    'by_application',     (
                            SELECT json_object_agg(app, cnt)
                            FROM (
                              SELECT COALESCE(application_name, '<unknown>') AS app, count(*) AS cnt
                              FROM pg_stat_activity
                              WHERE pid != pg_backend_pid()
                              GROUP BY application_name
                            ) sub
                          )
  ) AS v
  FROM pg_stat_activity
  WHERE pid != pg_backend_pid()
),

-- ---------------------------------------------------------------------------
locks_summary AS (
  SELECT json_build_object(
    'total',   total,
    'granted', granted,
    'waiting', waiting,
    'by_type', by_type,
    'by_mode', by_mode
  ) AS v
  FROM (
    SELECT
      count(*)                              AS total,
      count(*) FILTER (WHERE granted)       AS granted,
      count(*) FILTER (WHERE NOT granted)   AS waiting,
      (SELECT json_object_agg(locktype, cnt)
       FROM (SELECT locktype, count(*) AS cnt FROM pg_locks GROUP BY locktype) t) AS by_type,
      (SELECT json_object_agg(mode, cnt)
       FROM (SELECT mode, count(*) AS cnt FROM pg_locks GROUP BY mode) m) AS by_mode
    FROM pg_locks
  ) sub
),

-- ---------------------------------------------------------------------------
-- Bloat estimate using pgstattuple approximation via catalog heuristics
-- (no actual table scan — purely statistical)
bloat_estimate AS (
  SELECT json_agg(json_build_object(
    'schema',         schemaname,
    'table',          relname,
    'n_live_tup',     n_live_tup,
    'n_dead_tup',     n_dead_tup,
    'dead_ratio',     CASE WHEN (n_live_tup + n_dead_tup) > 0
                        THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2)
                      END,
    'last_vacuum',    last_vacuum,
    'last_autovacuum',last_autovacuum
  ) ORDER BY n_dead_tup DESC NULLS LAST) AS v
  FROM pg_stat_user_tables
  WHERE (n_live_tup + n_dead_tup) > 0
),

-- ---------------------------------------------------------------------------
-- Duplicate index candidates (same table + same columns)
dup_indexes AS (
  SELECT json_agg(json_build_object(
    'schema',     schema,
    'table',      tbl,
    'index_cols', index_cols,
    'indexes',    index_names
  ) ORDER BY schema, tbl) AS v
  FROM (
    SELECT
      n.nspname                                    AS schema,
      c.relname                                    AS tbl,
      array_to_string(ix.indkey::int2[], ',')      AS index_cols,
      json_agg(i.relname ORDER BY i.relname)       AS index_names
    FROM pg_index ix
    JOIN pg_class i  ON i.oid = ix.indexrelid
    JOIN pg_class c  ON c.oid = ix.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY n.nspname, c.relname, ix.indkey::int2[]
    HAVING count(*) > 1
  ) sub
),

-- ---------------------------------------------------------------------------
-- Unused indexes (zero scans since last stats reset)
unused_indexes AS (
  SELECT json_agg(json_build_object(
    'schema',      schemaname,
    'table',       relname,
    'index',       indexrelname,
    'size_bytes',  pg_relation_size(si.indexrelid),
    'idx_scan',    idx_scan,
    'is_primary',  ix.indisprimary,
    'is_unique',   ix.indisunique
  ) ORDER BY pg_relation_size(si.indexrelid) DESC) AS v
  FROM pg_stat_user_indexes si
  JOIN pg_index ix ON ix.indexrelid = si.indexrelid
  WHERE idx_scan = 0
    AND NOT ix.indisprimary
    AND NOT ix.indisunique
),

-- ---------------------------------------------------------------------------
-- Missing index candidates (high seq_scan on large tables)
missing_index_candidates AS (
  SELECT json_agg(json_build_object(
    'schema',     schemaname,
    'table',      relname,
    'seq_scan',   seq_scan,
    'n_live_tup', n_live_tup,
    'size_bytes', pg_total_relation_size(schemaname || '.' || quote_ident(relname))
  ) ORDER BY seq_scan DESC) AS v
  FROM pg_stat_user_tables
  WHERE seq_scan > 100
    AND n_live_tup > 10000
    AND (idx_scan IS NULL OR seq_scan > idx_scan)
)

-- ---------------------------------------------------------------------------
SELECT json_build_object(
  '_meta',                   (SELECT v FROM meta),
  'stat_statements',         (SELECT v FROM stat_statements),
  'stat_tables',             (SELECT v FROM stat_tables),
  'statio_tables',           (SELECT v FROM statio_tables),
  'stat_indexes',            (SELECT v FROM stat_indexes),
  'stat_bgwriter',           (SELECT v FROM stat_bgwriter),
  'stat_database',           (SELECT v FROM stat_database),
  'stat_replication',        (SELECT v FROM stat_replication),
  'replication_slots',       (SELECT v FROM replication_slots),
  'activity_summary',        (SELECT v FROM activity_summary),
  'locks_summary',           (SELECT v FROM locks_summary),
  'bloat_estimate',          (SELECT v FROM bloat_estimate),
  'dup_indexes',             (SELECT v FROM dup_indexes),
  'unused_indexes',          (SELECT v FROM unused_indexes),
  'missing_index_candidates',(SELECT v FROM missing_index_candidates)
);
