-- =============================================================================
--  ZK Catalog Dump  v1.0
--  Zero Knowledge schema/structure snapshot — no user data collected
--
--  What it captures:
--    databases, schemas, tables (sizes + row estimates), columns (types only),
--    indexes, constraints (type + count, no expressions), sequences,
--    views (count), functions (count), extensions, tablespaces
--
--  Usage:
--    psql -U <user> -d <db> -A -t -q -f zk_catalog_dump.sql -o catalog_snapshot.json
--
--  Output: single JSON document to stdout
-- =============================================================================

\pset format unaligned
\pset tuples_only on
\pset pager off

WITH

-- ---------------------------------------------------------------------------
meta AS (
  SELECT json_build_object(
    'type',           'zk_catalog_dump',
    'version',        '1.0',
    'generated_at',   now(),
    'pg_version',     version(),
    'pg_version_num', current_setting('server_version_num')::int,
    'database',       current_database(),
    'server_encoding',pg_encoding_to_char((SELECT encoding FROM pg_database WHERE datname = current_database()))
  ) AS v
),

-- ---------------------------------------------------------------------------
databases AS (
  SELECT json_agg(json_build_object(
    'name',     datname,
    'owner',    pg_get_userbyid(datdba),
    'encoding', pg_encoding_to_char(encoding),
    'collate',  datcollate,
    'ctype',    datctype,
    'size_bytes', pg_database_size(datname),
    'connlimit', datconnlimit,
    'is_template', datistemplate
  ) ORDER BY datname) AS v
  FROM pg_database
),

-- ---------------------------------------------------------------------------
schemas AS (
  SELECT json_agg(json_build_object(
    'name',  nspname,
    'owner', pg_get_userbyid(nspowner)
  ) ORDER BY nspname) AS v
  FROM pg_namespace
  WHERE nspname NOT LIKE 'pg_toast%'
    AND nspname NOT LIKE 'pg_temp%'
),

-- ---------------------------------------------------------------------------
extensions AS (
  SELECT json_agg(json_build_object(
    'name',    extname,
    'version', extversion,
    'schema',  n.nspname,
    'relocatable', extrelocatable
  ) ORDER BY extname) AS v
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
),

-- ---------------------------------------------------------------------------
tablespaces AS (
  SELECT json_agg(json_build_object(
    'name',       spcname,
    'owner',      pg_get_userbyid(spcowner),
    'location',   pg_tablespace_location(oid),
    'size_bytes', pg_tablespace_size(oid)
  ) ORDER BY spcname) AS v
  FROM pg_tablespace
),

-- ---------------------------------------------------------------------------
tables AS (
  SELECT json_agg(json_build_object(
    'schema',        schemaname,
    'table',         tablename,
    'owner',         tableowner,
    'tablespace',    tablespace,
    'has_oids',      false,
    'total_bytes',   pg_total_relation_size(schemaname || '.' || quote_ident(tablename)),
    'table_bytes',   pg_relation_size(schemaname || '.' || quote_ident(tablename)),
    'index_bytes',   pg_indexes_size(schemaname || '.' || quote_ident(tablename)),
    'toast_bytes',   COALESCE(
                       pg_total_relation_size(schemaname || '.' || quote_ident(tablename))
                       - pg_relation_size(schemaname || '.' || quote_ident(tablename))
                       - pg_indexes_size(schemaname || '.' || quote_ident(tablename)), 0),
    'row_estimate',  (SELECT reltuples::bigint
                      FROM pg_class c
                      JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE c.relname = tablename AND n.nspname = schemaname),
    'fillfactor',    (SELECT (regexp_match(reloptions::text, 'fillfactor=(\d+)'))[1]::int
                      FROM pg_class c
                      JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE c.relname = tablename AND n.nspname = schemaname)
  ) ORDER BY schemaname, tablename) AS v
  FROM pg_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
),

-- ---------------------------------------------------------------------------
columns AS (
  SELECT json_agg(json_build_object(
    'schema',       table_schema,
    'table',        table_name,
    'column',       column_name,
    'position',     ordinal_position,
    'data_type',    udt_name,
    'full_type',    data_type,
    'char_max_len', character_maximum_length,
    'num_precision',numeric_precision,
    'num_scale',    numeric_scale,
    'nullable',     is_nullable = 'YES',
    'has_default',  column_default IS NOT NULL,
    'is_identity',  is_identity = 'YES',
    'is_generated', is_generated != 'NEVER'
  ) ORDER BY table_schema, table_name, ordinal_position) AS v
  FROM information_schema.columns
  WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
indexes AS (
  SELECT json_agg(json_build_object(
    'schema',       schemaname,
    'table',        tablename,
    'index_name',   indexname,
    'tablespace',   tablespace,
    'index_def',    indexdef,
    'size_bytes',   pg_relation_size(schemaname || '.' || quote_ident(indexname)),
    'is_unique',    ix.indisunique,
    'is_primary',   ix.indisprimary,
    'is_exclusion', ix.indisexclusion,
    'is_valid',     ix.indisvalid,
    'is_ready',     ix.indisready,
    'num_cols',     array_length(ix.indkey, 1)
  ) ORDER BY schemaname, tablename, indexname) AS v
  FROM pg_indexes i
  JOIN pg_class c   ON c.relname = indexname
  JOIN pg_index ix  ON ix.indexrelid = c.oid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
constraints AS (
  SELECT json_agg(json_build_object(
    'schema',       n.nspname,
    'table',        cl.relname,
    'name',         conname,
    'type',         CASE contype
                      WHEN 'p' THEN 'PRIMARY KEY'
                      WHEN 'u' THEN 'UNIQUE'
                      WHEN 'f' THEN 'FOREIGN KEY'
                      WHEN 'c' THEN 'CHECK'
                      WHEN 'x' THEN 'EXCLUSION'
                      WHEN 't' THEN 'TRIGGER'
                      ELSE contype::text END,
    'is_deferrable',condeferrable,
    'is_deferred',  condeferred,
    'is_validated', convalidated,
    'num_cols',     array_length(conkey, 1),
    'fk_schema',    fn.nspname,
    'fk_table',     fc.relname
  ) ORDER BY n.nspname, cl.relname, conname) AS v
  FROM pg_constraint co
  JOIN pg_class     cl ON cl.oid = co.conrelid
  JOIN pg_namespace n  ON n.oid = cl.relnamespace
  LEFT JOIN pg_class     fc ON fc.oid = co.confrelid
  LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
sequences AS (
  SELECT json_agg(json_build_object(
    'schema',       n.nspname,
    'name',         c.relname,
    'data_type',    t.typname,
    'start',        s.seqstart,
    'increment',    s.seqincrement,
    'min',          s.seqmin,
    'max',          s.seqmax,
    'cache',        s.seqcache,
    'cycle',        s.seqcycle,
    'last_value',   (SELECT last_value FROM pg_sequences WHERE schemaname = n.nspname AND sequencename = c.relname),
    'exhausted_pct',CASE WHEN s.seqmax > s.seqmin
                      THEN round(100.0 * (
                        COALESCE((SELECT last_value FROM pg_sequences WHERE schemaname = n.nspname AND sequencename = c.relname), s.seqmin) - s.seqmin
                      ) / NULLIF(s.seqmax - s.seqmin, 0), 2)
                    END
  ) ORDER BY n.nspname, c.relname) AS v
  FROM pg_sequence s
  JOIN pg_class c     ON c.oid = s.seqrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_type t      ON t.oid = s.seqtypid
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
views AS (
  SELECT json_agg(json_build_object(
    'schema',   table_schema,
    'name',     table_name,
    'is_updatable', is_updatable = 'YES',
    'is_insertable', is_insertable_into = 'YES'
  ) ORDER BY table_schema, table_name) AS v
  FROM information_schema.views
  WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
),

-- ---------------------------------------------------------------------------
functions_summary AS (
  SELECT json_build_object(
    'total',             count(*),
    'languages',         json_object_agg(lanname, cnt)
  ) AS v
  FROM (
    SELECT l.lanname, count(*) AS cnt
    FROM pg_proc p
    JOIN pg_language l ON l.oid = p.prolang
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    GROUP BY l.lanname
  ) sub
),

-- ---------------------------------------------------------------------------
roles AS (
  SELECT json_agg(json_build_object(
    'name',         rolname,
    'superuser',    rolsuper,
    'inherit',      rolinherit,
    'createrole',   rolcreaterole,
    'createdb',     rolcreatedb,
    'login',        rolcanlogin,
    'replication',  rolreplication,
    'bypassrls',    rolbypassrls,
    'connlimit',    rolconnlimit,
    'valid_until',  rolvaliduntil,
    'has_password', rolpassword IS NOT NULL
  ) ORDER BY rolname) AS v
  FROM pg_roles
  WHERE rolname NOT LIKE 'pg_%'
),

-- ---------------------------------------------------------------------------
settings_key AS (
  SELECT json_agg(json_build_object(
    'name',     name,
    'setting',  setting,
    'unit',     unit,
    'source',   source,
    'min_val',  min_val,
    'max_val',  max_val
  ) ORDER BY name) AS v
  FROM pg_settings
  WHERE name IN (
    'max_connections','shared_buffers','work_mem','maintenance_work_mem',
    'effective_cache_size','wal_level','max_wal_size','min_wal_size',
    'checkpoint_completion_target','checkpoint_timeout',
    'max_worker_processes','max_parallel_workers','max_parallel_workers_per_gather',
    'autovacuum','autovacuum_max_workers','autovacuum_vacuum_cost_delay',
    'fsync','full_page_writes','synchronous_commit','wal_compression',
    'log_min_duration_statement','log_checkpoints','log_lock_waits',
    'random_page_cost','seq_page_cost','effective_io_concurrency',
    'jit','enable_partitionwise_join','enable_partitionwise_aggregate',
    'track_counts','track_io_timing','track_functions','pg_stat_statements.max',
    'default_statistics_target','constraint_exclusion','enable_bitmapscan'
  )
)

-- ---------------------------------------------------------------------------
SELECT json_build_object(
  '_meta',             (SELECT v FROM meta),
  'databases',         (SELECT v FROM databases),
  'schemas',           (SELECT v FROM schemas),
  'extensions',        (SELECT v FROM extensions),
  'tablespaces',       (SELECT v FROM tablespaces),
  'tables',            (SELECT v FROM tables),
  'columns',           (SELECT v FROM columns),
  'indexes',           (SELECT v FROM indexes),
  'constraints',       (SELECT v FROM constraints),
  'sequences',         (SELECT v FROM sequences),
  'views',             (SELECT v FROM views),
  'functions_summary', (SELECT v FROM functions_summary),
  'roles',             (SELECT v FROM roles),
  'settings_key',      (SELECT v FROM settings_key)
);
