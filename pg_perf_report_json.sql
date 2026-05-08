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
    \set mean_exec_time  mean_exec_time
    \set stddev_exec_time stddev_exec_time
\else
    \set total_exec_time total_time
    \set mean_exec_time  mean_time
    \set stddev_exec_time stddev_time
\endif

-- =============================================================================
-- PG 13+ path: includes planning time
-- =============================================================================
\if :is_pg13

WITH
top_cpu AS (
    SELECT query, calls,
           round(:total_exec_time::numeric, 2) AS total_ms,
           round((:total_exec_time - (shared_blk_read_time + shared_blk_write_time +
                  local_blk_read_time + local_blk_write_time +
                  temp_blk_read_time  + temp_blk_write_time))::numeric, 2) AS cpu_time_ms,
           round((100 * (:total_exec_time - (shared_blk_read_time + shared_blk_write_time +
                  local_blk_read_time + local_blk_write_time +
                  temp_blk_read_time  + temp_blk_write_time)) /
                  NULLIF(:total_exec_time, 0))::numeric, 1) AS pct_cpu
    FROM pg_stat_statements WHERE calls > 50
    ORDER BY (:total_exec_time - (shared_blk_read_time + shared_blk_write_time +
              local_blk_read_time + local_blk_write_time +
              temp_blk_read_time  + temp_blk_write_time)) DESC LIMIT 10
),
top_io AS (
    SELECT query, calls,
           round(:mean_exec_time::numeric, 2) AS mean_ms,
           round((shared_blk_read_time + shared_blk_write_time +
                  local_blk_read_time + local_blk_write_time +
                  temp_blk_read_time  + temp_blk_write_time)::numeric, 2) AS io_wait_ms,
           round((100 * (shared_blk_read_time + shared_blk_write_time +
                  local_blk_read_time + local_blk_write_time +
                  temp_blk_read_time  + temp_blk_write_time) /
                  NULLIF(:total_exec_time, 0))::numeric, 1) AS pct_io
    FROM pg_stat_statements
    WHERE (shared_blk_read_time + shared_blk_write_time + local_blk_read_time +
           local_blk_write_time + temp_blk_read_time + temp_blk_write_time) > 0
    ORDER BY (shared_blk_read_time + shared_blk_write_time + local_blk_read_time +
              local_blk_write_time + temp_blk_read_time + temp_blk_write_time) DESC LIMIT 10
),
top_planning AS (
    SELECT query, calls,
           round(total_plan_time::numeric, 2)  AS total_plan_ms,
           round(mean_plan_time::numeric, 2)   AS mean_plan_ms,
           round((:total_exec_time / NULLIF(:total_exec_time + total_plan_time, 0) * 100)::numeric, 1) AS pct_planning
    FROM pg_stat_statements WHERE plans > 0
    ORDER BY total_plan_time DESC LIMIT 10
),
top_wal AS (
    SELECT query, calls,
           pg_size_pretty(wal_bytes) AS wal_total,
           round((wal_bytes::numeric / NULLIF(calls, 0)), 0) AS bytes_per_call,
           wal_records
    FROM pg_stat_statements ORDER BY wal_bytes DESC LIMIT 10
),
top_freq AS (
    SELECT query, calls,
           round(:mean_exec_time::numeric, 2) AS mean_ms,
           round(:total_exec_time::numeric, 2) AS total_ms,
           round((100.0 * :total_exec_time / SUM(:total_exec_time) OVER())::numeric, 2) AS pct_load
    FROM pg_stat_statements ORDER BY calls DESC LIMIT 10
),
top_heavy AS (
    SELECT query, calls,
           round(:total_exec_time::numeric, 2) AS total_ms,
           round(:mean_exec_time::numeric, 2)  AS mean_ms,
           rows
    FROM pg_stat_statements ORDER BY :total_exec_time DESC LIMIT 10
),
top_jitter AS (
    SELECT query, calls,
           round(:mean_exec_time::numeric, 2)   AS mean_ms,
           round(:stddev_exec_time::numeric, 2) AS stddev_ms,
           round((:stddev_exec_time / NULLIF(:mean_exec_time, 0))::numeric, 2) AS var_ratio
    FROM pg_stat_statements
    WHERE calls > 10 AND :stddev_exec_time > :mean_exec_time
    ORDER BY :stddev_exec_time DESC LIMIT 10
),
top_temp AS (
    SELECT query, calls,
           temp_blks_written,
           pg_size_pretty(temp_blks_written * 8192) AS temp_size,
           round((temp_blks_written::numeric / NULLIF(calls, 0)), 2) AS blks_per_call
    FROM pg_stat_statements WHERE temp_blks_written > 0
    ORDER BY temp_blks_written DESC LIMIT 10
),
top_cache_miss AS (
    SELECT query, calls,
           round((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0)), 2) AS cache_hit_pct,
           (shared_blks_dirtied + local_blks_dirtied) AS blocks_dirtied
    FROM pg_stat_statements
    ORDER BY (shared_blks_hit + shared_blks_read) DESC LIMIT 10
),
stats_meta AS (
    SELECT dealloc, stats_reset FROM pg_stat_statements_info
)
SELECT json_build_object(
  'report',           'performance',
  'pg_version',       current_setting('server_version'),
  'generated_at',     now(),
  'top_cpu',          (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_cpu) t),
  'top_io',           (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_io) t),
  'top_planning',     (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_planning) t),
  'top_wal',          (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_wal) t),
  'top_freq',         (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_freq) t),
  'top_heavy',        (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_heavy) t),
  'top_jitter',       (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_jitter) t),
  'top_temp_files',   (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_temp) t),
  'top_cache_miss',   (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_cache_miss) t),
  'stats_meta',       (SELECT row_to_json(s) FROM (SELECT * FROM stats_meta) s)
);

\else
-- =============================================================================
-- PG < 13 path: no planning time columns
-- =============================================================================

WITH
top_cpu AS (
    SELECT query, calls,
           round(:total_exec_time::numeric, 2) AS total_ms,
           round((:total_exec_time - (shared_blk_read_time + shared_blk_write_time +
                  local_blk_read_time + local_blk_write_time +
                  temp_blk_read_time  + temp_blk_write_time))::numeric, 2) AS cpu_time_ms,
           round((100 * (:total_exec_time - (shared_blk_read_time + shared_blk_write_time +
                  local_blk_read_time + local_blk_write_time +
                  temp_blk_read_time  + temp_blk_write_time)) /
                  NULLIF(:total_exec_time, 0))::numeric, 1) AS pct_cpu
    FROM pg_stat_statements WHERE calls > 50
    ORDER BY (:total_exec_time - (shared_blk_read_time + shared_blk_write_time +
              local_blk_read_time + local_blk_write_time +
              temp_blk_read_time  + temp_blk_write_time)) DESC LIMIT 10
),
top_io AS (
    SELECT query, calls,
           round(:mean_exec_time::numeric, 2) AS mean_ms,
           round((shared_blk_read_time + shared_blk_write_time +
                  local_blk_read_time + local_blk_write_time +
                  temp_blk_read_time  + temp_blk_write_time)::numeric, 2) AS io_wait_ms,
           round((100 * (shared_blk_read_time + shared_blk_write_time +
                  local_blk_read_time + local_blk_write_time +
                  temp_blk_read_time  + temp_blk_write_time) /
                  NULLIF(:total_exec_time, 0))::numeric, 1) AS pct_io
    FROM pg_stat_statements
    WHERE (shared_blk_read_time + shared_blk_write_time + local_blk_read_time +
           local_blk_write_time + temp_blk_read_time + temp_blk_write_time) > 0
    ORDER BY (shared_blk_read_time + shared_blk_write_time + local_blk_read_time +
              local_blk_write_time + temp_blk_read_time + temp_blk_write_time) DESC LIMIT 10
),
top_wal AS (
    SELECT query, calls,
           pg_size_pretty(wal_bytes) AS wal_total,
           round((wal_bytes::numeric / NULLIF(calls, 0)), 0) AS bytes_per_call,
           wal_records
    FROM pg_stat_statements ORDER BY wal_bytes DESC LIMIT 10
),
top_freq AS (
    SELECT query, calls,
           round(:mean_exec_time::numeric, 2) AS mean_ms,
           round(:total_exec_time::numeric, 2) AS total_ms,
           round((100.0 * :total_exec_time / SUM(:total_exec_time) OVER())::numeric, 2) AS pct_load
    FROM pg_stat_statements ORDER BY calls DESC LIMIT 10
),
top_heavy AS (
    SELECT query, calls,
           round(:total_exec_time::numeric, 2) AS total_ms,
           round(:mean_exec_time::numeric, 2)  AS mean_ms,
           rows
    FROM pg_stat_statements ORDER BY :total_exec_time DESC LIMIT 10
),
top_jitter AS (
    SELECT query, calls,
           round(:mean_exec_time::numeric, 2)   AS mean_ms,
           round(:stddev_exec_time::numeric, 2) AS stddev_ms,
           round((:stddev_exec_time / NULLIF(:mean_exec_time, 0))::numeric, 2) AS var_ratio
    FROM pg_stat_statements
    WHERE calls > 10 AND :stddev_exec_time > :mean_exec_time
    ORDER BY :stddev_exec_time DESC LIMIT 10
),
top_temp AS (
    SELECT query, calls,
           temp_blks_written,
           pg_size_pretty(temp_blks_written * 8192) AS temp_size,
           round((temp_blks_written::numeric / NULLIF(calls, 0)), 2) AS blks_per_call
    FROM pg_stat_statements WHERE temp_blks_written > 0
    ORDER BY temp_blks_written DESC LIMIT 10
),
top_cache_miss AS (
    SELECT query, calls,
           round((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0)), 2) AS cache_hit_pct,
           (shared_blks_dirtied + local_blks_dirtied) AS blocks_dirtied
    FROM pg_stat_statements
    ORDER BY (shared_blks_hit + shared_blks_read) DESC LIMIT 10
),
stats_meta AS (
    SELECT dealloc, stats_reset FROM pg_stat_statements_info
)
SELECT json_build_object(
  'report',           'performance',
  'pg_version',       current_setting('server_version'),
  'generated_at',     now(),
  'top_cpu',          (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_cpu) t),
  'top_io',           (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_io) t),
  'top_planning',     NULL,
  'top_wal',          (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_wal) t),
  'top_freq',         (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_freq) t),
  'top_heavy',        (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_heavy) t),
  'top_jitter',       (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_jitter) t),
  'top_temp_files',   (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_temp) t),
  'top_cache_miss',   (SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (SELECT * FROM top_cache_miss) t),
  'stats_meta',       (SELECT row_to_json(s) FROM (SELECT * FROM stats_meta) s)
);

\endif
