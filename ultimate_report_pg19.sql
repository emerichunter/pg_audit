\set QUIET on
\encoding UTF8
\pset format unaligned
\pset tuples_only on
\pset border 0
\pset footer off

WITH RECURSIVE 
constants AS (SELECT current_setting('block_size')::numeric AS bs, 8 AS chunk_size),

/* --- DATA GATHERING --- */
v_ver AS (
    SELECT current_setting('server_version') as ver, 
    substring(current_setting('server_version') from '^[0-9]+')::int as major_ver
),

v_ext AS (
    SELECT name, installed_version, default_version, 
    CASE WHEN installed_version <> default_version THEN 'UPDATE' ELSE 'OK' END as status
    FROM pg_available_extensions WHERE installed_version IS NOT NULL
),

v_db_info AS (
    SELECT datname, pg_encoding_to_char(encoding) as enc, datcollate, pg_size_pretty(pg_database_size(datname)) as size
    FROM pg_database WHERE datallowconn AND NOT datistemplate
),

v_archiving AS (
    SELECT * FROM (
        SELECT archived_count, failed_count, to_char(last_failed_time, 'DD/MM HH24:MI') as last_fail FROM pg_stat_archiver
    ) a WHERE (SELECT has_table_privilege('pg_stat_archiver', 'select'))
),

v_repl AS (
    SELECT * FROM (
        SELECT application_name, client_addr, state, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) as lag
        FROM pg_stat_replication
    ) r WHERE (SELECT has_table_privilege('pg_stat_replication', 'select'))
),

v_slots AS (
    SELECT * FROM (
        SELECT slot_name, active, restart_lsn FROM pg_replication_slots WHERE NOT active
    ) s WHERE (SELECT has_table_privilege('pg_replication_slots', 'select'))
),

/* PG19+ Specific: Standby Health */
v_recovery_state AS (
    SELECT redo_lsn, redo_wal_file, recovery_paused, 
    CASE WHEN recovery_paused THEN 'PAUSED' ELSE 'ACTIVE' END as status
    FROM pg_stat_recovery
),

v_bloat AS (
    SELECT schemaname, tablename, 
    ROUND((CASE WHEN otta=0 THEN 0.0 ELSE relpages::FLOAT/NULLIF(otta,0) END)::NUMERIC,1) AS tbloat,
    pg_size_pretty(((relpages-otta)*(SELECT bs FROM constants))::bigint) AS wasted
    FROM (
        SELECT schemaname, tablename, cc.relpages, CEIL((cc.reltuples*((23+8)+4))/NULLIF((SELECT bs FROM constants)-20, 0)) AS otta
        FROM pg_stats s JOIN pg_class cc ON cc.relname = s.tablename JOIN pg_namespace nn ON cc.relnamespace = nn.oid AND nn.nspname = s.schemaname
        WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema') 
        GROUP BY schemaname, tablename, cc.relpages, cc.reltuples
    ) foo WHERE relpages > otta
),

/* PG19+ Specific: Parallel Autovacuum */
v_autovacuum_parallel AS (
    SELECT schemaname, relname, num_workers_planned, num_workers_actual,
    ROUND((num_workers_actual::float / NULLIF(num_workers_planned,0)) * 100, 1) as utilization
    FROM pg_stat_autovacuum_parallel WHERE num_workers_planned > 0
),

v_locks AS (
    SELECT pid, usename, backend_type, wait_event_type, wait_event, pg_blocking_pids(pid) as blockers, substring(query, 1, 60) as q 
    FROM pg_stat_activity WHERE pg_blocking_pids(pid) <> '{}'
),

/* PG19+ Specific: Lock Statistics */
v_lock_stats AS (
    SELECT locktype, COUNT(*) as total_waits, AVG(waittime)::numeric(10,1) as avg_ms
    FROM pg_stat_lock GROUP BY locktype ORDER BY total_waits DESC
),

v_secu AS (
    SELECT rolname, rolsuper, CASE WHEN rolpassword IS NULL THEN 'WARNING' ELSE 'OK' END as pwd 
    FROM pg_roles WHERE rolname NOT LIKE 'pg_%'
),

v_seq AS (
    SELECT schemaname, sequencename, last_value, max_value, 
    round((last_value::numeric / NULLIF(max_value::numeric,0)) * 100, 2) as pct
    FROM pg_sequences WHERE (last_value::numeric / NULLIF(max_value::numeric,0)) > 0.5
),

/* PG19+ Specific: Checksum Toggle Status */
v_checksum_status AS (
    SELECT current_setting('data_checksums') as status, checksum_failures as fails
    FROM pg_stat_checksums
),

/* --- HTML TEMPLATE --- */
html AS (
    SELECT '
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Ultimate PostgreSQL Audit Report (PG19+)</title>
<style>
    @import url(''https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap'');
    :root {
        --bg: #0f172a; --card-bg: #1e293b; --primary: #38bdf8; --secondary: #64748b;
        --text: #f8fafc; --text-muted: #94a3b8; --border: #334155;
        --danger: #ef4444; --warning: #f59e0b; --info: #0ea5e9; --success: #10b981;
    }
    body.light-mode {
        --bg: #f8fafc; --card-bg: #ffffff; --primary: #2563eb; --secondary: #475569;
        --text: #1e293b; --text-muted: #64748b; --border: #e2e8f0;
    }
    body { font-family: ''Inter'', sans-serif; background-color: var(--bg); color: var(--text); margin: 0; padding: 40px; line-height: 1.6; transition: background-color 0.3s; }
    .container { max-width: 1400px; margin: 0 auto; }
    header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 50px; }
    h1 { background: linear-gradient(135deg, #38bdf8, #818cf8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; margin: 0; font-weight: 800; font-size: 2.8rem; }
    .meta { color: var(--text-muted); font-size: 0.9rem; margin-top: 8px; font-weight: 500; display: flex; align-items: center; gap: 15px; }
    .pg-badge { background: var(--primary); color: #000; padding: 2px 8px; border-radius: 4px; font-weight: 700; font-size: 0.75rem; }
    .theme-switch { background: var(--card-bg); border: 1px solid var(--border); padding: 8px 16px; border-radius: 50px; cursor: pointer; display: flex; align-items: center; gap: 8px; font-weight: 600; font-size: 0.85rem; color: var(--text); transition: all 0.2s; }
    .theme-switch:hover { border-color: var(--primary); transform: translateY(-2px); }
    .nav-bar { background: var(--card-bg); padding: 15px; border-radius: 12px; border: 1px solid var(--border); margin-bottom: 40px; display: flex; justify-content: center; gap: 10px; flex-wrap: wrap; position: sticky; top: 20px; z-index: 100; box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); }
    .nav-bar a { text-decoration: none; color: var(--text); font-weight: 600; font-size: 0.85rem; padding: 8px 16px; border-radius: 8px; transition: all 0.2s; display: flex; align-items: center; gap: 8px; }
    .nav-bar a:hover { background-color: var(--primary); color: #fff; transform: translateY(-2px); }
    .card { background: var(--card-bg); border-radius: 16px; border: 1px solid var(--border); margin-bottom: 40px; overflow: hidden; box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); }
    .card-header { background: rgba(255,255,255,0.02); padding: 15px 25px; font-size: 1.1rem; font-weight: 700; border-bottom: 1px solid var(--border); display: flex; align-items: center; gap: 10px; }
    table { width: 100%; border-spacing: 0; }
    th { color: var(--text-muted); font-size: 0.75rem; text-transform: uppercase; padding: 12px 25px; text-align: left; border-bottom: 1px solid var(--border); }
    td { padding: 12px 25px; border-bottom: 1px solid var(--border); font-size: 0.9rem; }
    .badge { padding: 4px 10px; border-radius: 6px; font-size: 0.7rem; font-weight: 700; text-transform: uppercase; }
    .b-red { background: rgba(239,68,68,0.1); color: #fca5a5; border: 1px solid rgba(239,68,68,0.2); }
    .b-orange { background: rgba(245,158,11,0.1); color: #fcd34d; border: 1px solid rgba(245,158,11,0.2); }
    .b-blue { background: rgba(14,165,233,0.1); color: #7dd3fc; border: 1px solid rgba(14,165,233,0.2); }
    .b-gray { background: rgba(148,163,184,0.1); color: #cbd5e1; border: 1px solid rgba(148,163,184,0.2); }
    .code { font-family: ''JetBrains Mono'', monospace; color: var(--primary); }
    .icon { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
</style>
</head>
<body>
<div class="container">
    <header>
        <div>
            <h1>PostgreSQL Ultimate Audit <span style="font-size:1.2rem;opacity:0.7">PG19+ Enhanced</span></h1>
            <div class="meta">
                <span>G&eacute;n&eacute;r&eacute; le ' || to_char(now(), 'DD/MM/YYYY') || ' &agrave; ' || to_char(now(), 'HH24:MI') || '</span>
                <span class="pg-badge">PG ' || (SELECT ver FROM v_ver) || '</span>
                <span class="badge b-blue">PG19 NATIVE EXPLOITATION</span>
            </div>
        </div>
    </header>

    <div class="nav-bar">
        <a href="#global">Global</a> <a href="#infra">Infra</a> <a href="#storage">Storage</a> <a href="#index">Index</a> <a href="#maint">Maint</a> <a href="#activity">Activity</a>
    </div>

    <div class="card" id="infra">
        <div class="card-header">Infrastructure & Replication (PG19+ Enhancements)</div>
        <table>
            <tr><th>Status</th><th>Metric</th><th>Details</th></tr>
            ' || COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">RECOVERY</span></td><td>Standby State</td><td>Status: <span class="code">'||status||'</span> | File: '||redo_wal_file||'</td></tr>','') FROM v_recovery_state),'<tr><td colspan="3">N/A</td></tr>') || '
            ' || COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue">CHECKSUM</span></td><td>Data Integrity</td><td>Status: <span class="code">'||status||'</span> | Failures: '||fails||'</td></tr>','') FROM v_checksum_status),'<tr><td colspan="3">N/A</td></tr>') || '
        </table>
    </div>

    <div class="card" id="maint">
        <div class="card-header">Maintenance & Parallelization (PG19+)</div>
        <table>
            <tr><th>Alert</th><th>Object</th><th>Metric</th></tr>
            ' || COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue">PARALLEL AV</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>Utilization: <span class="code">'||utilization||'%</span></td></tr>','') FROM v_autovacuum_parallel),'<tr><td colspan="3">No parallel autovacuum active</td></tr>') || '
        </table>
    </div>

    <div class="card" id="activity">
        <div class="card-header">Real-time Activity & Lock Contention (PG19+)</div>
        <table>
            <tr><th>Type</th><th>Total Waits</th><th>Avg Latency</th></tr>
            ' || COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">'||locktype||'</span></td><td class="code">'||total_waits||'</td><td>'||avg_ms||'ms</td></tr>','') FROM v_lock_stats LIMIT 10),'<tr><td colspan="3">No lock contention recorded</td></tr>') || '
        </table>
    </div>

    <script>
    function toggleTheme() { document.body.classList.toggle(''light-mode''); }
    </script>
</div>
</body>
</html>' as val
)
SELECT string_agg(val, '') FROM html;
