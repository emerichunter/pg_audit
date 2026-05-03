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
  SELECT 
    CASE WHEN NOT has_table_privilege('pg_stat_archiver', 'select') THEN 'PERMISSION_DENIED' 
         WHEN archived_count IS NULL THEN 'ARCHIVING_DISABLED'
         WHEN failed_count > 0 THEN 'FAILURES'
         ELSE 'OK'
    END as status,
    COALESCE(archived_count, 0) as archived_count,
    COALESCE(failed_count, 0) as failed_count,
    COALESCE(to_char(last_failed_time, 'DD/MM HH24:MI'), 'N/A') as last_fail
  FROM (
    SELECT * FROM pg_stat_archiver 
    WHERE has_table_privilege('pg_stat_archiver', 'select')
    UNION ALL
    SELECT 0, 0, NULL WHERE NOT has_table_privilege('pg_stat_archiver', 'select')
  ) a
),

v_repl AS (
  SELECT 
    CASE 
      WHEN pg_is_in_recovery() THEN 'STANDBY_MODE'
      WHEN (SELECT COUNT(*) FROM pg_stat_replication) = 0 THEN 'PRIMARY_NO_REPLICAS'
      ELSE 'PRIMARY_WITH_REPLICAS'
    END as status,
    CASE 
      WHEN pg_is_in_recovery() THEN 'Server is in recovery/standby mode'
      ELSE (
        SELECT COALESCE(
          STRING_AGG(application_name || ' (' || state || ') lag=' || 
            pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), ', '),
          'No replicas connected'
        )
        FROM pg_stat_replication
      )
    END as details
),

v_slots AS (
  SELECT 
    slot_name,
    slot_type,
    CASE WHEN active THEN 'ACTIVE' ELSE 'INACTIVE' END as status,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as wal_retained,
    CASE WHEN NOT active AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824 THEN '🔴 CRITICAL'
         WHEN NOT active THEN '🟡 WARNING'
         ELSE 'OK'
    END as risk
  FROM pg_replication_slots
  WHERE (SELECT has_table_privilege('pg_replication_slots', 'select'))
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

v_idx_duplicate AS (
    SELECT n.nspname || '.' || c.relname as tbl, array_agg(indexrelid::regclass)::text as indexes, pg_size_pretty(SUM(pg_relation_size(indexrelid))::bigint) as size
    FROM pg_index i 
    JOIN pg_class c ON c.oid = i.indrelid 
    JOIN pg_namespace n ON n.oid = c.relnamespace
    GROUP BY n.nspname, c.relname, indrelid, indkey, indclass, indoption, indexprs, indpred HAVING count(*) > 1
),

v_idx_ineff AS (
  SELECT schemaname, relname, indexrelname, idx_scan, 
    ROUND((idx_tup_read::numeric / NULLIF(idx_tup_fetch,0)), 2) as ratio,
    pg_size_pretty(pg_relation_size(indexrelid)) as idx_size
  FROM pg_stat_user_indexes 
  WHERE idx_scan > 50 AND (idx_tup_read::numeric / NULLIF(idx_tup_fetch,0)) > 100
),

v_missing_idx AS (
  SELECT schemaname, relname, 
    pg_size_pretty(pg_total_relation_size(relid)) as table_size,
    seq_scan, seq_tup_read, idx_scan
  FROM pg_stat_user_tables 
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    AND pg_total_relation_size(relid) > 10485760 -- 10MB
    AND seq_scan > 100 
    AND seq_tup_read > 1000000
),

v_fk_unindexed AS (
    SELECT n1.nspname || '.' || c1.relname as tbl, a1.attname as col 
    FROM pg_constraint t 
    JOIN pg_attribute a1 ON a1.attrelid=t.conrelid AND a1.attnum=t.conkey[1] 
    JOIN pg_class c1 ON c1.oid=t.conrelid
    JOIN pg_namespace n1 ON n1.oid=c1.relnamespace
    WHERE t.contype='f' AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=t.conrelid AND i.indkey[0]=t.conkey[1])
),

v_wrap AS (
  SELECT datname, age(datfrozenxid) as xid_age, 
    ROUND((100 * age(datfrozenxid) / NULLIF(current_setting('autovacuum_freeze_max_age')::bigint, 0))::numeric, 1) as pct,
    CASE WHEN age(datfrozenxid) > (0.9 * current_setting('autovacuum_freeze_max_age')::bigint) THEN '🔴 CRITICAL'
         WHEN age(datfrozenxid) > (0.75 * current_setting('autovacuum_freeze_max_age')::bigint) THEN '🟠 WARNING'
         ELSE 'OK'
    END as status
  FROM pg_database 
  WHERE datallowconn AND age(datfrozenxid) > 50000000
),

v_locks AS (
  SELECT pid, usename, backend_type, 
    pg_blocking_pids(pid)::text as blockers,
    wait_event_type, wait_event,
    CASE WHEN state = 'idle in transaction' THEN 'IDLE_IN_XACT_RISK'
         WHEN wait_event_type IS NOT NULL THEN 'BLOCKED'
         ELSE state
    END as actual_status,
    EXTRACT(EPOCH FROM (now() - query_start))::int as wait_secs,
    substring(query, 1, 200) as query_snippet
  FROM pg_stat_activity 
  WHERE pg_blocking_pids(pid) <> '{}' OR (state = 'idle in transaction' AND (now() - xact_start) > interval '5 minutes')
),

v_secu AS (
  SELECT rolname,
    CASE WHEN rolsuper THEN 'SUPERUSER' ELSE 'NORMAL' END as role_type,
    CASE WHEN NOT rolcanlogin THEN 'NO_LOGIN' 
         WHEN rolpassword IS NULL THEN 'NOPASS_UNSAFE'
         WHEN rolpassword LIKE '%SCRAM%' THEN 'SCRAM_HASHED'
         WHEN rolpassword LIKE '%md5%' THEN 'MD5_WEAK'
         ELSE 'OTHER'
    END as pwd_status,
    CASE WHEN rolsuper OR rolcreaterole OR rolreplication THEN '⚠️ HIGH' ELSE 'OK' END as risk
  FROM pg_roles 
  WHERE rolname NOT LIKE 'pg_%'
),

v_seq AS (
  SELECT schemaname, sequencename, last_value, max_value, 
    ROUND((last_value::numeric / NULLIF(max_value::numeric,0)) * 100, 1) as pct_used,
    CASE WHEN last_value::numeric / NULLIF(max_value::numeric, 0) > 0.95 THEN '🔴 CRITICAL'
         ELSE 'OK'
    END as status
  FROM pg_sequences 
  WHERE (last_value::numeric / NULLIF(max_value::numeric,0)) > 0.5
),

v_settings AS (
  SELECT name, setting, unit,
    CASE WHEN name = 'fsync' AND setting = 'off' THEN '🔴 CRITICAL: DATA LOSS'
         WHEN name = 'full_page_writes' AND setting = 'off' THEN '🔴 CRITICAL: CORRUPTION'
         ELSE 'OK'
    END as risk
  FROM pg_settings
  WHERE name IN ('fsync', 'full_page_writes', 'wal_level', 'max_connections', 'password_encryption')
),

v_buffer_health AS (
  SELECT 
    ROUND(sum(heap_blks_hit)::numeric / NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0) * 100, 1) as hit_ratio_pct
  FROM pg_statio_user_tables
),

/* --- HTML TEMPLATE --- */
html AS (
    SELECT '
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Ultimate PostgreSQL Audit Report (PG ' || (SELECT ver FROM v_ver) || ')</title>
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
    #backToTop { position: fixed; bottom: 30px; right: 30px; width: 45px; height: 45px; background: var(--primary); color: #fff; border: none; border-radius: 50%; cursor: pointer; display: none; align-items: center; justify-content: center; z-index: 1000; box-shadow: 0 4px 15px rgba(0,0,0,0.3); }
</style>
</head>
<body>
<div class="container">
    <header>
        <div>
            <h1 data-i18n="title">PostgreSQL Ultimate Audit</h1>
            <div class="meta">
                <span><span data-i18n="gen_on">G&eacute;n&eacute;r&eacute; le</span> ' || to_char(now(), 'DD/MM/YYYY') || ' &agrave; ' || to_char(now(), 'HH24:MI') || '</span>
                <span class="pg-badge">PG ' || (SELECT ver FROM v_ver) || '</span>
            </div>
        </div>
        <div style="display: flex; gap: 10px;">
            <button class="theme-switch" onclick="toggleLanguage()">
                <svg class="icon"><circle cx="12" cy="12" r="10"></circle><line x1="2" y1="12" x2="22" y2="12"></line><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"></path></svg>
                <span id="lang-text">EN</span>
            </button>
            <button class="theme-switch" onclick="toggleTheme()" id="theme-btn">
                <span id="theme-icon-svg"><svg class="icon"><circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line></svg></span>
            </button>
        </div>
    </header>

    <div class="nav-bar">
        <a href="#global"><svg class="icon"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"></path></svg> <span data-i18n="nav_global">Global</span></a>
        <a href="#infra"><svg class="icon"><path d="M15 3s-3.3 0-6 3c-2 2.5-3 6-3 6l5 5s3.5-1 6-3c3-2.7 3-6 3-6l-5 5z"></path></svg> <span data-i18n="nav_infra">Infra</span></a>
        <a href="#storage"><svg class="icon"><ellipse cx="12" cy="5" rx="9" ry="3"></ellipse><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"></path><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"></path></svg> <span data-i18n="nav_storage">Stockage</span></a>
        <a href="#index"><svg class="icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg> <span data-i18n="nav_index">Index</span></a>
        <a href="#maint"><svg class="icon"><path d="M3 13h18M6 13v6a2 2 0 002 2h8a2 2 0 002-2v-6M12 3v10"></path></svg> <span data-i18n="nav_maint">Maint</span></a>
        <a href="#activity"><svg class="icon"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"></path></svg> <span data-i18n="nav_activity">Activit&eacute;</span></a>
        <a href="#secu"><svg class="icon"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg> <span data-i18n="nav_secu">S&eacute;cu</span></a>
    </div>
    ' as val
    
    UNION ALL SELECT '<div class="card" id="global"><div class="card-header"><svg class="icon"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"></path></svg> <span data-i18n="h_global">Global Overview</span></div><table><tr><th>Type</th><th>Object</th><th>Details / Status</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue">EXTENSION</span></td><td class="code">'||name||'</td><td>v'||installed_version||' ('||status||')</td></tr>','') FROM v_ext),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-gray">DATABASE</span></td><td class="code">'||datname||'</td><td>Size: <span class="code">'||size||'</span> | Enc: '||enc||'</td></tr>','') FROM v_db_info),'')
    UNION ALL SELECT '<tr><td><span class="badge b-blue">CACHE</span></td><td>Buffer Hit Ratio</td><td><span class="code">'||hit_ratio_pct||'%</span></td></tr>' FROM v_buffer_health
    UNION ALL SELECT '</table></div>'
    
    UNION ALL SELECT '<div class="card" id="infra"><div class="card-header"><svg class="icon"><path d="M15 3s-3.3 0-6 3c-2 2.5-3 6-3 6l5 5s3.5-1 6-3c3-2.7 3-6 3-6l-5 5z"></path></svg> <span data-i18n="h_infra">Infrastructure & Replication</span></div><table><tr><th>Status</th><th>Component</th><th>Metric / Details</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge '||CASE WHEN status='OK' THEN 'b-blue' ELSE 'b-red' END||'">'||status||'</span></td><td>Archiver</td><td>Archived: '||archived_count||' | Failed: '||failed_count||'</td></tr>','') FROM v_archiving),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue">'||status||'</span></td><td>Replication</td><td>'||details||'</td></tr>','') FROM v_repl),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge '||CASE WHEN risk='OK' THEN 'b-blue' ELSE 'b-red' END||'">'||status||'</span></td><td class="code">'||slot_name||'</td><td>Retained: '||wal_retained||' ('||risk||')</td></tr>','') FROM v_slots),'')
    UNION ALL SELECT '</table></div>'
    
    UNION ALL SELECT '<div class="card" id="storage"><div class="card-header"><svg class="icon"><ellipse cx="12" cy="5" rx="9" ry="3"></ellipse><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"></path></svg> <span data-i18n="h_storage">Tables & Storage</span></div><table><tr><th>Status</th><th>Object</th><th>Details / Impact</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">BLOAT</span></td><td class="code">'||schemaname||'.'||tablename||'</td><td>Wasted: <span class="code">'||wasted||'</span> (Ratio: '||tbloat||')</td></tr>','') FROM v_bloat LIMIT 10),'')
    UNION ALL SELECT '</table></div>'
    
    UNION ALL SELECT '<div class="card" id="index"><div class="card-header"><svg class="icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg> <span data-i18n="h_index">Index Health</span></div><table><tr><th>Alert</th><th>Table / Index</th><th>Analysis</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">DUPLICATE</span></td><td class="code">'||tbl||'</td><td>'||indexes||' ('||size||')</td></tr>','') FROM v_idx_duplicate),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue">INEFFICIENT</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>Ratio: <span class="code">'||ratio||'</span> | Size: '||idx_size||'</td></tr>','') FROM v_idx_ineff),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">MISSING</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>SeqScan: <span class="code">'||seq_scan||'</span> | Size: '||table_size||'</td></tr>','') FROM v_missing_idx LIMIT 10),'')
    UNION ALL SELECT '</table></div>'
    
    UNION ALL SELECT '<div class="card" id="maint"><div class="card-header"><svg class="icon"><path d="M3 13h18M6 13v6a2 2 0 002 2h8a2 2 0 002-2v-6M12 3v10"></path></svg> <span data-i18n="h_maint">Maintenance & Capacity</span></div><table><tr><th>Alert</th><th>Object</th><th>Metric / Status</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge '||CASE WHEN status='OK' THEN 'b-blue' ELSE 'b-red' END||'">WRAPAROUND</span></td><td class="code">'||datname||'</td><td>Usage: <span class="code">'||pct||'%</span> ('||status||')</td></tr>','') FROM v_wrap),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge '||CASE WHEN status='OK' THEN 'b-blue' ELSE 'b-red' END||'">SEQ FULL</span></td><td class="code">'||schemaname||'.'||sequencename||'</td><td>Usage: <span class="code">'||pct_used||'%</span></td></tr>','') FROM v_seq),'')
    UNION ALL SELECT '</table></div>'
    
    UNION ALL SELECT '<div class="card" id="activity"><div class="card-header"><svg class="icon"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"></path></svg> <span data-i18n="h_activity">Real-time Activity</span></div><table><tr><th>PID</th><th>Status</th><th>Wait / Blocker</th><th>Query Snippet</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="code">'||pid||'</span> ('||usename||')</td><td><span class="badge b-gray">'||actual_status||'</span></td><td>Wait: '||wait_secs||'s | Blk: '||blockers||'</td><td class="code">'||query_snippet||'</td></tr>','') FROM v_locks),'<tr><td colspan="4" style="text-align:center;color:var(--text-muted)">No blocking or long idle sessions detected</td></tr>')
    UNION ALL SELECT '</table></div>'
    
    UNION ALL SELECT '<div class="card" id="secu"><div class="card-header"><svg class="icon"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg> <span data-i18n="h_secu">Security & Governance</span></div><table><tr><th>Type</th><th>Name</th><th>Status / Risk</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue">'||role_type||'</span></td><td class="code">'||rolname||'</td><td>Auth: '||pwd_status||' | Risk: '||risk||'</td></tr>','') FROM v_secu),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-gray">SETTING</span></td><td class="code">'||name||'</td><td>Value: '||setting||' | Risk: '||risk||'</td></tr>','') FROM v_settings),'')
    UNION ALL SELECT '</table></div>'
    
    UNION ALL SELECT '
    <button id="backToTop" onclick="window.scrollTo({top:0, behavior:''smooth''})">↑</button>
    <script>
    const icons = {
        sun: `<svg class="icon"><circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line></svg>`,
        moon: `<svg class="icon"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>`
    };
    let currentLang = ''fr'';
    const translations = {
        fr: {
            title: "PostgreSQL Ultimate Audit", gen_on: "G&eacute;n&eacute;r&eacute; le",
            nav_global: "Global", nav_infra: "Infra", nav_storage: "Stockage", nav_index: "Index", 
            nav_maint: "Maint", nav_activity: "Activit&eacute;", nav_secu: "S&eacute;cu",
            h_global: "Vue d''ensemble Globale", h_infra: "Infrastructure & Replication", h_storage: "Tables & Stockage",
            h_index: "Sant&eacute; des Index", h_maint: "Maintenance & Capacit&eacute;",
            h_activity: "Activit&eacute; Temps R&eacute;el", h_secu: "S&eacute;curit&eacute; & Gouvernance"
        },
        en: {
            title: "PostgreSQL Ultimate Audit", gen_on: "Generated on",
            nav_global: "Global", nav_infra: "Infra", nav_storage: "Storage", nav_index: "Index", 
            nav_maint: "Maint", nav_activity: "Activity", nav_secu: "Security",
            h_global: "Global Overview", h_infra: "Infrastructure & Replication", h_storage: "Tables & Storage",
            h_index: "Index Health", h_maint: "Maintenance & Capacity",
            h_activity: "Real-time Activity", h_secu: "Security & Governance"
        }
    };
    function toggleLanguage() {
        currentLang = currentLang === ''fr'' ? ''en'' : ''fr'';
        document.getElementById(''lang-text'').innerText = currentLang === ''fr'' ? ''EN'' : ''FR'';
        updateUI();
    }
    function updateUI() {
        document.querySelectorAll(''[data-i18n]'').forEach(el => {
            const key = el.getAttribute(''data-i18n'');
            if (translations[currentLang][key]) el.innerHTML = translations[currentLang][key];
        });
    }
    function toggleTheme() {
        document.body.classList.toggle(''light-mode'');
        document.getElementById(''theme-icon-svg'').innerHTML = document.body.classList.contains(''light-mode'') ? icons.moon : icons.sun;
    }
    window.onscroll = function() {
        document.getElementById("backToTop").style.display = window.scrollY > 500 ? "flex" : "none";
    };
    document.addEventListener(''DOMContentLoaded'', updateUI);
    </script>
    </div></body></html>'
)
SELECT string_agg(val, '') FROM html;