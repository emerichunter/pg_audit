\set quiet on
\pset format unaligned
\pset tuples_only on
\pset border 0
\pset footer off

WITH RECURSIVE 
constants AS (SELECT current_setting('block_size')::numeric AS bs, 8 AS chunk_size),


v_unlogged AS (
    SELECT n.nspname || '.' || c.relname as object_name, 
    CASE WHEN c.relkind='r' THEN 'Table' WHEN c.relkind='i' THEN 'Index' ELSE 'Autre' END as kind,
    pg_size_pretty(c.relpages::bigint*8*1024) as size
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relpersistence = 'u'
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

v_idx_redundant AS (
    SELECT i.indexrelid::regclass::text as idx_candidate, j.indexrelid::regclass::text as idx_keep,
    pg_size_pretty(pg_relation_size(i.indexrelid)) as size_saved
    FROM pg_index i JOIN pg_index j ON i.indrelid = j.indrelid AND i.indexrelid <> j.indexrelid
    WHERE string_to_array(i.indkey::text, ' ')::int2[] <@ string_to_array(j.indkey::text, ' ')::int2[]
    AND NOT i.indisunique AND NOT i.indisprimary
),

v_idx_duplicate AS (
    SELECT n.nspname || '.' || c.relname as tbl, array_agg(indexrelid::regclass)::text as indexes, pg_size_pretty(SUM(pg_relation_size(indexrelid))::bigint) as size
    FROM pg_index i 
    JOIN pg_class c ON c.oid = i.indrelid 
    JOIN pg_namespace n ON n.oid = c.relnamespace
    GROUP BY n.nspname, c.relname, indrelid, indkey, indclass, indoption, indexprs, indpred HAVING count(*) > 1
),

v_idx_unused AS (
    SELECT schemaname, relname, indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) as size
    FROM pg_stat_user_indexes WHERE idx_scan = 0 AND idx_tup_read = 0 AND schemaname NOT IN ('pg_catalog', 'information_schema')
),

v_idx_ineff AS (
    SELECT schemaname, relname, indexrelname, idx_scan, idx_tup_fetch, (idx_tup_read::numeric / NULLIF(idx_tup_fetch,0))::numeric(10,1) as ratio
    FROM pg_stat_user_indexes WHERE idx_scan > 50 AND (idx_tup_read::numeric / NULLIF(idx_tup_fetch,0)) > 100
),

v_idx_invalid AS (
    SELECT n.nspname, c.relname FROM pg_index i JOIN pg_class c ON i.indexrelid=c.oid JOIN pg_namespace n ON c.relnamespace=n.oid
    WHERE NOT i.indisvalid
),

v_missing_idx AS (
    SELECT schemaname, relname, seq_scan, seq_tup_read, idx_scan, 
    (seq_tup_read::numeric / NULLIF(idx_tup_fetch, 0))::numeric(10,2) as ratio
    FROM pg_stat_user_tables WHERE seq_scan > 100 AND (seq_tup_read::numeric / NULLIF(idx_tup_fetch, 0)) > 1000
),

v_fk_unindexed AS (
    SELECT n1.nspname || '.' || c1.relname as tbl, a1.attname as col 
    FROM pg_constraint t 
    JOIN pg_attribute a1 ON a1.attrelid=t.conrelid AND a1.attnum=t.conkey[1] 
    JOIN pg_class c1 ON c1.oid=t.conrelid
    JOIN pg_namespace n1 ON n1.oid=c1.relnamespace
    WHERE t.contype='f' AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=t.conrelid AND i.indkey[0]=t.conkey[1])
),

v_fk_dup AS (
    SELECT conname, n.nspname || '.' || c.relname as tbl
    FROM pg_constraint t1 
    JOIN pg_class c ON t1.conrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE EXISTS (SELECT 1 FROM pg_constraint t2 WHERE t1.conrelid=t2.conrelid AND t1.conkey=t2.conkey AND t1.oid <> t2.oid AND t2.contype='f') AND t1.contype='f'
),

v_secu AS (
    SELECT rolname, rolsuper, CASE WHEN rolpassword IS NULL THEN '⚠️ NO PASSWORD' ELSE 'OK' END as pwd 
    FROM pg_roles WHERE rolname NOT LIKE 'pg_%'
),

v_funcs AS (
    SELECT n.nspname, p.proname, l.lanname, CASE WHEN p.prosecdef THEN 'SECURITY DEFINER' ELSE 'INVOKER' END as sec
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid JOIN pg_language l ON p.prolang=l.oid
    WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND p.prosecdef
),

v_seq AS (
    SELECT schemaname, sequencename, last_value, max_value, 
    round((last_value::numeric / NULLIF(max_value::numeric,0)) * 100, 2) as pct
    FROM pg_sequences WHERE (last_value::numeric / NULLIF(max_value::numeric,0)) > 0.75
),

v_empty_tbl AS (SELECT schemaname, relname FROM pg_stat_user_tables WHERE n_live_tup = 0),

v_unused_tbl AS (SELECT schemaname, relname FROM pg_stat_user_tables WHERE (seq_tup_read + idx_tup_fetch + n_tup_ins + n_tup_upd + n_tup_del) = 0),

v_single_col AS (
    SELECT table_schema, table_name FROM information_schema.columns 
    WHERE table_schema NOT IN ('pg_catalog','information_schema') GROUP BY table_schema, table_name HAVING count(*) = 1
),

v_useless_col AS (
    SELECT schemaname, tablename as relname, attname, null_frac 
    FROM pg_stats WHERE null_frac > 0.99 AND schemaname NOT IN ('pg_catalog','information_schema')
),

v_useless_col AS (
    SELECT schemaname, tablename as relname, attname, null_frac 
    FROM pg_stats WHERE null_frac > 0.99 AND schemaname NOT IN ('pg_catalog','information_schema')
),

v_av_tune AS (
    SELECT schemaname, relname, n_dead_tup, last_autovacuum 
    FROM pg_stat_user_tables 
    WHERE n_dead_tup > (current_setting('autovacuum_vacuum_threshold')::int + current_setting('autovacuum_vacuum_scale_factor')::float * n_live_tup)
),

v_slots AS (
    SELECT slot_name, active, restart_lsn FROM pg_replication_slots WHERE NOT active
),

v_denorm AS (
    SELECT table_schema, table_name, substring(column_name FROM '^(.*)[0-9]+$') as pattern, count(*) as cnt 
    FROM information_schema.columns WHERE column_name ~ '[0-9]$' AND table_schema NOT IN ('pg_catalog','information_schema')
    GROUP BY table_schema, table_name, substring(column_name FROM '^(.*)[0-9]+$') HAVING count(*) > 2
),

v_frag AS (
    SELECT n.nspname || '.' || t.relname as relname, a.attname, ty.typname 
    FROM pg_index i 
    JOIN pg_class t ON t.oid=i.indrelid 
    JOIN pg_namespace n ON t.relnamespace = n.oid
    JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=ANY(i.indkey) 
    JOIN pg_type ty ON a.atttypid=ty.oid
    WHERE i.indisprimary AND ty.typname IN ('text','varchar','uuid')
),

v_too_many_idx AS (
    SELECT schemaname, relname, count(*) as cnt FROM pg_stat_user_indexes GROUP BY schemaname, relname HAVING count(*) > 10
),

html AS (
    SELECT '
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Rapport d''Audit PostgreSQL</title>
<style>
    @import url(''https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap'');
    :root {
        --bg: #0f172a;
        --card-bg: #1e293b;
        --primary: #38bdf8;
        --secondary: #64748b;
        --text: #f8fafc;
        --text-muted: #94a3b8;
        --border: #334155;
        --danger: #ef4444;
        --warning: #f59e0b;
        --info: #0ea5e9;
    }
    body.light-mode {
        --bg: #f8fafc;
        --card-bg: #ffffff;
        --primary: #2563eb;
        --secondary: #475569;
        --text: #1e293b;
        --text-muted: #64748b;
        --border: #e2e8f0;
    }
    body { 
        font-family: ''Inter'', system-ui, -apple-system, sans-serif;
        background-color: var(--bg); color: var(--text); margin: 0; padding: 40px; line-height: 1.6;
        transition: background-color 0.3s, color 0.3s;
    }
    .container { max-width: 1400px; margin: 0 auto; }
    
    /* Header */
    header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 50px; }
    h1 { background: linear-gradient(135deg, #38bdf8, #818cf8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; margin: 0; font-weight: 800; font-size: 3rem; letter-spacing: -0.03em; }
    .meta { color: var(--text-muted); font-size: 1rem; margin-top: 12px; font-weight: 500; }

    /* Theme Switch */
    .theme-switch { background: var(--card-bg); border: 1px solid var(--border); padding: 10px 20px; border-radius: 50px; cursor: pointer; display: flex; align-items: center; gap: 10px; font-weight: 600; font-size: 0.9rem; color: var(--text); transition: all 0.3s; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
    .theme-switch:hover { border-color: var(--primary); transform: translateY(-2px); }

    /* Navigation */
    .nav-bar { 
        background: var(--card-bg); padding: 20px; border-radius: 12px; border: 1px solid var(--border);
        box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); margin-bottom: 40px; 
        display: flex; justify-content: center; gap: 15px; flex-wrap: wrap;
    }
    .nav-bar a { 
        text-decoration: none; color: var(--text); font-weight: 500; font-size: 0.95rem; 
        padding: 10px 20px; border-radius: 8px; background: rgba(255,255,255,0.03);
        border: 1px solid rgba(255,255,255,0.05); transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .nav-bar a:hover { background-color: var(--primary); color: #fff; border-color: var(--primary); transform: translateY(-2px); box-shadow: 0 4px 12px rgba(56,189,248,0.3); }

    /* Cards Sections */
    .card { 
        background: var(--card-bg); border-radius: 16px; border: 1px solid var(--border);
        box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); margin-bottom: 40px; overflow: hidden; 
    }
    
    .card-header {
        background: rgba(255,255,255,0.02); color: var(--text); padding: 20px 25px;
        font-size: 1.25rem; font-weight: 700; border-bottom: 1px solid var(--border);
        display: flex; align-items: center; justify-content: space-between;
    }
    body.light-mode .card-header { background: #34495e; color: white; }
    
    /* Tables */
    table { width: 100%; border-collapse: separate; border-spacing: 0; font-size: 0.95rem; }
    th { 
        background: rgba(255,255,255,0.01); color: var(--text-muted); font-weight: 600; text-transform: uppercase; 
        font-size: 0.8rem; padding: 16px 25px; text-align: left; border-bottom: 1px solid var(--border);
        letter-spacing: 0.05em;
    }
    body.light-mode th { background: #f8f9fa; color: #64748b; }
    td { padding: 16px 25px; border-bottom: 1px solid var(--border); color: var(--text); vertical-align: top; }
    tr:last-child td { border-bottom: none; }
    tr { transition: background-color 0.2s; }
    tr:hover { background-color: rgba(255,255,255,0.03); }
    body.light-mode tr:hover { background-color: #f1f5f9; }

    /* Badges & Utility */
    .badge { 
        display: inline-block; padding: 6px 12px; border-radius: 6px; 
        font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    .b-red    { background: rgba(239, 68, 68, 0.1); color: #fca5a5; border: 1px solid rgba(239, 68, 68, 0.2); }
    .b-orange { background: rgba(245, 158, 11, 0.1); color: #fcd34d; border: 1px solid rgba(245, 158, 11, 0.2); }
    .b-blue   { background: rgba(14, 165, 233, 0.1); color: #7dd3fc; border: 1px solid rgba(14, 165, 233, 0.2); }
    .b-gray   { background: rgba(148, 163, 184, 0.1); color: #cbd5e1; border: 1px solid rgba(148, 163, 184, 0.2); }
    
    body.light-mode .b-red { background: #fee2e2; color: #b91c1c; border-color: #fecaca; }
    body.light-mode .b-orange { background: #fef3c7; color: #b45309; border-color: #fde68a; }
    body.light-mode .b-blue { background: #e0f2fe; color: #0369a1; border-color: #bae6fd; }
    body.light-mode .b-gray { background: #f1f5f9; color: #475569; border-color: #e2e8f0; }

    .code { font-family: ''JetBrains Mono'', ''Fira Code'', Consolas, monospace; font-size: 0.9rem; color: #f472b6; background: rgba(244, 114, 182, 0.1); padding: 4px 8px; border-radius: 6px; border: 1px solid rgba(244, 114, 182, 0.2); }
    body.light-mode .code { color: #db2777; background: #fdf2f8; border-color: #fbcfe8; }
    .val  { font-weight: 700; color: var(--primary); }

    /* Back to Top */
    #backToTop { position: fixed; bottom: 30px; right: 30px; width: 50px; height: 50px; background: var(--primary); color: white; border: none; border-radius: 50%; cursor: pointer; display: none; align-items: center; justify-content: center; font-size: 1.5rem; box-shadow: 0 4px 15px rgba(0,0,0,0.3); transition: all 0.3s; z-index: 1000; }
    #backToTop:hover { transform: translateY(-5px); background-color: var(--info); }
</style>
</head>
<body>

<div class="container">
    <header>
        <div>
            <h1 data-i18n="title">Audit de Santé PostgreSQL</h1>
            <div class="meta"><span data-i18n="gen_on">Généré le</span> '' || to_char(now(), ''DD/MM/YYYY à HH24:MI'') || ''</div>
        </div>
        <div style="display: flex; gap: 10px;">
            <button class="theme-switch" onclick="toggleLanguage()">
                <span id="lang-icon">🌍</span> <span id="lang-text">EN</span>
            </button>
            <button class="theme-switch" onclick="toggleTheme()">
                <span id="theme-icon">🌞</span> <span id="theme-text">Mode Clair</span>
            </button>
        </div>
    </header>

    <div class="nav-bar">
        <a href="#storage" data-i18n="nav_storage">💾 Stockage</a>
        <a href="#index" data-i18n="nav_index">🔎 Indexation</a>
        <a href="#schema" data-i18n="nav_schema">🏗️ Schéma</a>
        <a href="#maint" data-i18n="nav_maint">🧹 Maintenance</a>
        <a href="#secu" data-i18n="nav_secu">🔒 Sécurité</a>
    </div>
    ' as val
    
    UNION ALL SELECT '<div class="card" id="storage"><div class="card-header" data-i18n="h_storage">1. Tables & Stockage</div><table><tr><th data-i18n="th_status">Statut</th><th data-i18n="th_object">Objet (Schema.Table)</th><th data-i18n="th_details">Détails / Impact</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red" data-i18n="unlogged">UNLOGGED</span></td><td class="code">'||object_name||'</td><td><span data-i18n="size">Taille</span>: <span class="val">'||size||'</span> (<span data-i18n="non_repl">Non répliqué</span>)</td></tr>','') FROM v_unlogged),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange" data-i18n="bloat">BLOAT</span></td><td class="code">'||schemaname||'.'||tablename||'</td><td><span data-i18n="lost">Perdu</span>: <span class="val">'||wasted||'</span> (Ratio: '||tbloat||')</td></tr>','') FROM v_bloat LIMIT 20),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange" data-i18n="frag">FRAGMENTATION</span></td><td class="code">'||relname||'</td><td>Type: '||typname||' (<span data-i18n="slow_ins">Insertions lentes</span>)</td></tr>','') FROM v_frag),'')
    UNION ALL SELECT '</table></div>'

    UNION ALL SELECT '<div class="card" id="index"><div class="card-header" data-i18n="h_index">2. Santé des Index</div><table><tr><th data-i18n="th_alert">Alerte</th><th data-i18n="th_idx_tbl">Index / Table</th><th data-i18n="th_analysis">Analyse</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red" data-i18n="duplicate">DUPLIQUÉ</span></td><td class="code">'||tbl||'</td><td>'||indexes||'</td></tr>','') FROM v_idx_duplicate),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange" data-i18n="redundant">REDONDANT</span></td><td class="code">'||idx_candidate||'</td><td><span data-i18n="inc_in">Inclus dans</span>: <span class="code">'||idx_keep||'</span> (<span data-i18n="gain">Gain</span>: '||size_saved||')</td></tr>','') FROM v_idx_redundant),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue" data-i18n="ineff">INEFFICACE</span></td><td class="code">'||schemaname||'.'||relname||' <br><small>('||indexrelname||')</small></td><td>Ratio Read/Fetch: <span class="val">'||ratio||'</span></td></tr>','') FROM v_idx_ineff),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-gray" data-i18n="unused">INUTILISÉ</span></td><td class="code">'||schemaname||'.'||relname||' <br><small>('||indexrelname||')</small></td><td><span data-i18n="size">Taille</span>: <span class="val">'||size||'</span></td></tr>','') FROM v_idx_unused LIMIT 20),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange" data-i18n="overhead">SURCHARGE</span></td><td class="code">'||schemaname||'.'||relname||'</td><td><span class="val">'||cnt||'</span> <span data-i18n="idx_on_tbl">index sur cette table</span></td></tr>','') FROM v_too_many_idx),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red" data-i18n="invalid">INVALIDE</span></td><td class="code">'||nspname||'.'||relname||'</td><td><span data-i18n="corrupt">Index corrompu (REINDEX requis)</span></td></tr>','') FROM v_idx_invalid),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red" data-i18n="missing">MANQUANT</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>SeqScan: <span class="val">'||seq_scan||'</span></td></tr>','') FROM v_missing_idx LIMIT 20),'')
    UNION ALL SELECT '</table></div>'

    UNION ALL SELECT '<div class="card" id="schema"><div class="card-header" data-i18n="h_schema">3. Qualité du Schéma</div><table><tr><th data-i18n="th_type">Type</th><th data-i18n="th_obj">Objet</th><th data-i18n="th_prob">Problème détecté</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red" data-i18n="miss_fk">FK MANQUANTE</span></td><td class="code">'||tbl||'</td><td>Colonne: '||col||' (<span data-i18n="lock_risk">Risque Locking</span>)</td></tr>','') FROM v_fk_unindexed),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red" data-i18n="dup_fk">FK DOUBLON</span></td><td class="code">'||tbl||'</td><td>Constraint: ''||conname||''</td></tr>','') FROM v_fk_dup),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange" data-i18n="denorm">DENORMALISATION</span></td><td class="code">'||table_schema||'.'||table_name||'</td><td>Pattern: <b>'||pattern||'</b> ('||cnt||' colonnes)</td></tr>','') FROM v_denorm),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-gray" data-i18n="empty_tbl">TABLE VIDE</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>0 tuples</td></tr>','') FROM v_empty_tbl LIMIT 20),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-gray" data-i18n="unused_tbl">INUTILISÉE</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>0 accès (Scan/Fetch/DML)</td></tr>','') FROM v_unused_tbl LIMIT 20),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue" data-i18n="mono_col">MONO-COLONNE</span></td><td class="code">'||table_schema||'.'||table_name||'</td><td><span data-i18n="struct_susp">Structure suspecte</span></td></tr>','') FROM v_single_col),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange" data-i18n="null_col">COLONNE NULL</span></td><td class="code">'||schemaname||'.'||relname||' <small>('||attname||')</small></td><td>Nulls: <span class="val">'||(null_frac*100)::int||'%</span></td></tr>','') FROM v_useless_col),'')
    UNION ALL SELECT '</table></div>'

    UNION ALL SELECT '<div class="card" id="maint"><div class="card-header" data-i18n="h_maint">4. Maintenance & Capacité</div><table><tr><th data-i18n="th_alert">Alerte</th><th data-i18n="th_obj">Objet</th><th data-i18n="th_val_act">Valeur Actuelle</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red" data-i18n="seq_full">SEQUENCE FULL</span></td><td class="code">'||schemaname||'.'||sequencename||'</td><td>Utilisation: <span class="val">'||pct||'%</span></td></tr>','') FROM v_seq),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange" data-i18n="tune_av">TUNING AV</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>Dead Tuples: <span class="val">'||n_dead_tup||'</span></td></tr>','') FROM v_av_tune),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red" data-i18n="slot_inact">SLOT INACTIF</span></td><td class="code">'||slot_name||'</td><td><span data-i18n="retain_wal">Retient les WAL</span> (LSN: '||restart_lsn||')</td></tr>','') FROM v_slots),'')
    UNION ALL SELECT '</table></div>'

    UNION ALL SELECT '<div class="card" id="secu"><div class="card-header" data-i18n="h_secu">5. Sécurité</div><table><tr><th data-i18n="th_type">Type</th><th data-i18n="th_name">Nom</th><th data-i18n="th_status">Statut</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue" data-i18n="role">ROLE</span></td><td class="code">'||rolname||'</td><td>Pwd: <b>'||pwd||'</b> (Superuser: '||rolsuper||')</td></tr>','') FROM v_secu),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange" data-i18n="func">FONCTION</span></td><td class="code">'||nspname||'.'||proname||'</td><td><span data-i18n="secu_def">Exécuté en SECURITY DEFINER</span></td></tr>','') FROM v_funcs),'')
    UNION ALL SELECT '</table></div>'

    UNION ALL SELECT '
    <button id="backToTop" onclick="scrollToTop()" title="Retour en haut">↑</button>
    <script>
    let currentLang = ''fr'';
    const translations = {
        fr: {
            title: "Audit de Santé PostgreSQL", gen_on: "Généré le",
            nav_storage: "💾 Stockage", nav_index: "🔎 Indexation", nav_schema: "🏗️ Schéma", nav_maint: "🧹 Maintenance", nav_secu: "🔒 Sécurité",
            h_storage: "1. Tables & Stockage", h_index: "2. Santé des Index", h_schema: "3. Qualité du Schéma", h_maint: "4. Maintenance & Capacité", h_secu: "5. Sécurité",
            th_status: "Statut", th_object: "Objet (Schema.Table)", th_details: "Détails / Impact", th_alert: "Alerte", th_idx_tbl: "Index / Table", th_analysis: "Analyse",
            th_type: "Type", th_obj: "Objet", th_prob: "Problème détecté", th_val_act: "Valeur Actuelle", th_name: "Nom",
            unlogged: "UNLOGGED", bloat: "BLOAT", frag: "FRAGMENTATION", size: "Taille", non_repl: "Non répliqué", lost: "Perdu", slow_ins: "Insertions lentes",
            duplicate: "DUPLIQUÉ", redundant: "REDONDANT", ineff: "INEFFICACE", unused: "INUTILISÉ", overhead: "SURCHARGE", invalid: "INVALIDE", missing: "MANQUANT",
            inc_in: "Inclus dans", gain: "Gain", idx_on_tbl: "index sur cette table", corrupt: "Index corrompu (REINDEX requis)",
            miss_fk: "FK MANQUANTE", dup_fk: "FK DOUBLON", denorm: "DENORMALISATION", empty_tbl: "TABLE VIDE", unused_tbl: "INUTILISÉE", mono_col: "MONO-COLONNE", null_col: "COLONNE NULL",
            lock_risk: "Risque Locking", struct_susp: "Structure suspecte", seq_full: "SEQUENCE FULL", tune_av: "TUNING AV", slot_inact: "SLOT INACTIF",
            retain_wal: "Retient les WAL", role: "ROLE", func: "FONCTION", secu_def: "Exécuté en SECURITY DEFINER", back_to_top: "Retour en haut"
        },
        en: {
            title: "PostgreSQL Health Audit", gen_on: "Generated on",
            nav_storage: "💾 Storage", nav_index: "🔎 Indexing", nav_schema: "🏗️ Schema", nav_maint: "🧹 Maintenance", nav_secu: "🔒 Security",
            h_storage: "1. Tables & Storage", h_index: "2. Index Health", h_schema: "3. Schema Quality", h_maint: "4. Maintenance & Capacity", h_secu: "5. Security",
            th_status: "Status", th_object: "Object (Schema.Table)", th_details: "Details / Impact", th_alert: "Alert", th_idx_tbl: "Index / Table", th_analysis: "Analysis",
            th_type: "Type", th_obj: "Object", th_prob: "Problem Detected", th_val_act: "Current Value", th_name: "Name",
            unlogged: "UNLOGGED", bloat: "BLOAT", frag: "FRAGMENTATION", size: "Size", non_repl: "Not replicated", lost: "Lost", slow_ins: "Slow insertions",
            duplicate: "DUPLICATE", redundant: "REDUNDANT", ineff: "INEFFICIENT", unused: "UNUSED", overhead: "OVERHEAD", invalid: "INVALID", missing: "MISSING",
            inc_in: "Included in", gain: "Gain", idx_on_tbl: "indexes on this table", corrupt: "Corrupt index (REINDEX required)",
            miss_fk: "MISSING FK", dup_fk: "DUPLICATE FK", denorm: "DENORMALIZATION", empty_tbl: "EMPTY TABLE", unused_tbl: "UNUSED TABLE", mono_col: "SINGLE COLUMN", null_col: "NULL COLUMN",
            lock_risk: "Locking Risk", struct_susp: "Suspicious structure", seq_full: "SEQUENCE FULL", tune_av: "AV TUNING", slot_inact: "INACTIVE SLOT",
            retain_wal: "Retains WAL", role: "ROLE", func: "FUNCTION", secu_def: "Executed as SECURITY DEFINER", back_to_top: "Back to Top"
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
            if (translations[currentLang][key]) el.innerText = translations[currentLang][key];
        });
        const btt = document.getElementById(''backToTop'');
        if (btt) btt.title = translations[currentLang].back_to_top;
    }

    function toggleTheme() {
        const body = document.body;
        const icon = document.getElementById(''theme-icon'');
        const text = document.getElementById(''theme-text'');
        body.classList.toggle(''light-mode'');
        if (body.classList.contains(''light-mode'')) {
            icon.innerText = ''🌙'';
            text.innerText = currentLang === ''fr'' ? ''Mode Sombre'' : ''Dark Mode'';
        } else {
            icon.innerText = ''🌞'';
            text.innerText = currentLang === ''fr'' ? ''Mode Clair'' : ''Light Mode'';
        }
    }
    function scrollToTop() {
        window.scrollTo({ top: 0, behavior: ''smooth'' });
    }
    window.onscroll = function() {
        const btn = document.getElementById("backToTop");
        if (document.body.scrollTop > 500 || document.documentElement.scrollTop > 500) {
            btn.style.display = "flex";
        } else {
            btn.style.display = "none";
        }
    };
    document.addEventListener(''DOMContentLoaded'', updateUI);
    </script>
    </div></body></html>'
)
SELECT string_agg(val, '') FROM html;
