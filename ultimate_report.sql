/* ULTIMATE POSTGRESQL AUDIT REPORT - V10 (FLAT CSS & FULL LOGIC) */
WITH RECURSIVE 
-- =================================================================================
-- 0. CONSTANTES
-- =================================================================================
constants AS (SELECT current_setting('block_size')::numeric AS bs, 8 AS chunk_size),

-- =================================================================================
-- 1. LOGIQUE METIER (AUDIT COMPLET)
-- =================================================================================

-- 1. UNLOGGED TABLES (Risque Data Loss)
v_unlogged AS (
    SELECT n.nspname || '.' || c.relname as object_name, 
    CASE WHEN c.relkind='r' THEN 'Table' WHEN c.relkind='i' THEN 'Index' ELSE 'Autre' END as kind,
    pg_size_pretty(c.relpages::bigint*8*1024) as size
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relpersistence = 'u'
),

-- 2. BLOAT (Espace disque perdu)
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

-- 3. INDEX REDONDANTS (A peut remplacer B)
v_idx_redundant AS (
    SELECT i.indexrelid::regclass::text as idx_candidate, j.indexrelid::regclass::text as idx_keep,
    pg_size_pretty(pg_relation_size(i.indexrelid)) as size_saved
    FROM pg_index i JOIN pg_index j ON i.indrelid = j.indrelid AND i.indexrelid <> j.indexrelid
    WHERE string_to_array(i.indkey::text, ' ')::int2[] <@ string_to_array(j.indkey::text, ' ')::int2[]
    AND NOT i.indisunique AND NOT i.indisprimary
),

-- 4. INDEX DUPLIQUÉS (Identiques)
v_idx_duplicate AS (
    SELECT n.nspname || '.' || c.relname as tbl, array_agg(indexrelid::regclass)::text as indexes, pg_size_pretty(SUM(pg_relation_size(indexrelid))::bigint) as size
    FROM pg_index i 
    JOIN pg_class c ON c.oid = i.indrelid 
    JOIN pg_namespace n ON n.oid = c.relnamespace
    GROUP BY n.nspname, c.relname, indrelid, indkey, indclass, indoption, indexprs, indpred HAVING count(*) > 1
),

-- 5. INDEX INUTILISÉS (0 Scans)
v_idx_unused AS (
    SELECT schemaname, relname, indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) as size
    FROM pg_stat_user_indexes WHERE idx_scan = 0 AND idx_tup_read = 0 AND schemaname NOT IN ('pg_catalog', 'information_schema')
),

-- 6. INDEX INEFFICACES (Scan beaucoup, trouve peu)
v_idx_ineff AS (
    SELECT schemaname, relname, indexrelname, idx_scan, idx_tup_fetch, (idx_tup_read::numeric / NULLIF(idx_tup_fetch,0))::numeric(10,1) as ratio
    FROM pg_stat_user_indexes WHERE idx_scan > 50 AND (idx_tup_read::numeric / NULLIF(idx_tup_fetch,0)) > 100
),

-- 7. INDEX INVALIDES (Corrompus/En échec)
v_idx_invalid AS (
    SELECT n.nspname, c.relname FROM pg_index i JOIN pg_class c ON i.indexrelid=c.oid JOIN pg_namespace n ON c.relnamespace=n.oid
    WHERE NOT i.indisvalid
),

-- 8. INDEX MANQUANTS (Full Seq Scan élevés)
v_missing_idx AS (
    SELECT schemaname, relname, seq_scan, seq_tup_read, idx_scan, 
    (seq_tup_read::numeric / NULLIF(idx_tup_fetch, 0))::numeric(10,2) as ratio
    FROM pg_stat_user_tables WHERE seq_scan > 100 AND (seq_tup_read::numeric / NULLIF(idx_tup_fetch, 0)) > 1000
),

-- 9. FK NON INDEXEES (Risque locking)
v_fk_unindexed AS (
    SELECT n1.nspname || '.' || c1.relname as tbl, a1.attname as col 
    FROM pg_constraint t 
    JOIN pg_attribute a1 ON a1.attrelid=t.conrelid AND a1.attnum=t.conkey[1] 
    JOIN pg_class c1 ON c1.oid=t.conrelid
    JOIN pg_namespace n1 ON n1.oid=c1.relnamespace
    WHERE t.contype='f' AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=t.conrelid AND i.indkey[0]=t.conkey[1])
),

-- 10. FK DOUBLONS
v_fk_dup AS (
    SELECT conname, n.nspname || '.' || c.relname as tbl
    FROM pg_constraint t1 
    JOIN pg_class c ON t1.conrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE EXISTS (SELECT 1 FROM pg_constraint t2 WHERE t1.conrelid=t2.conrelid AND t1.conkey=t2.conkey AND t1.oid <> t2.oid AND t2.contype='f') AND t1.contype='f'
),

-- 11. SÉCURITÉ (Mots de passe manquants)
v_secu AS (
    SELECT rolname, rolsuper, CASE WHEN rolpassword IS NULL THEN '⚠️ NO PASSWORD' ELSE 'OK' END as pwd 
    FROM pg_roles WHERE rolname NOT LIKE 'pg_%'
),

-- 12. FONCTIONS A RISQUE (Security Definer)
v_funcs AS (
    SELECT n.nspname, p.proname, l.lanname, CASE WHEN p.prosecdef THEN 'SECURITY DEFINER' ELSE 'INVOKER' END as sec
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid JOIN pg_language l ON p.prolang=l.oid
    WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND p.prosecdef
),

-- 13. SÉQUENCES FULL (>75%)
v_seq AS (
    SELECT schemaname, sequencename, last_value, max_value, 
    round((last_value::numeric / NULLIF(max_value::numeric,0)) * 100, 2) as pct
    FROM pg_sequences WHERE (last_value::numeric / NULLIF(max_value::numeric,0)) > 0.75
),

-- 14. TABLES VIDES
v_empty_tbl AS (SELECT schemaname, relname FROM pg_stat_user_tables WHERE n_live_tup = 0),

-- 15. TABLES INUTILISÉES
v_unused_tbl AS (SELECT schemaname, relname FROM pg_stat_user_tables WHERE (seq_tup_read + idx_tup_fetch + n_tup_ins + n_tup_upd + n_tup_del) = 0),

-- 16. TABLES MONO-COLONNE
v_single_col AS (
    SELECT table_schema, table_name FROM information_schema.columns 
    WHERE table_schema NOT IN ('pg_catalog','information_schema') GROUP BY table_schema, table_name HAVING count(*) = 1
),

-- 17. COLONNES NULL / USELESS (>99% NULL)
v_useless_col AS (
    SELECT schemaname, tablename as relname, attname, null_frac 
    FROM pg_stats WHERE null_frac > 0.99 AND schemaname NOT IN ('pg_catalog','information_schema')
),

-- 18. AUTOVACUUM TUNING REQUIS
v_av_tune AS (
    SELECT schemaname, relname, n_dead_tup, last_autovacuum 
    FROM pg_stat_user_tables 
    WHERE n_dead_tup > (current_setting('autovacuum_vacuum_threshold')::int + current_setting('autovacuum_vacuum_scale_factor')::float * n_live_tup)
),

-- 19. REPLICATION SLOTS INACTIFS
v_slots AS (
    SELECT slot_name, active, restart_lsn FROM pg_replication_slots WHERE NOT active
),

-- 20. DENORMALIZATION (Pattern matching sur noms de colonnes)
v_denorm AS (
    SELECT table_schema, table_name, substring(column_name FROM '^(.*)[0-9]+$') as pattern, count(*) as cnt 
    FROM information_schema.columns WHERE column_name ~ '[0-9]$' AND table_schema NOT IN ('pg_catalog','information_schema')
    GROUP BY table_schema, table_name, substring(column_name FROM '^(.*)[0-9]+$') HAVING count(*) > 2
),

-- 21. FRAGMENTATION PK (UUID/Text non séquentiel)
v_frag AS (
    SELECT n.nspname || '.' || t.relname as relname, a.attname, ty.typname 
    FROM pg_index i 
    JOIN pg_class t ON t.oid=i.indrelid 
    JOIN pg_namespace n ON t.relnamespace = n.oid
    JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=ANY(i.indkey) 
    JOIN pg_type ty ON a.atttypid=ty.oid
    WHERE i.indisprimary AND ty.typname IN ('text','varchar','uuid')
),

-- 22. TROP D'INDEX (>10 par table)
v_too_many_idx AS (
    SELECT schemaname, relname, count(*) as cnt FROM pg_stat_user_indexes GROUP BY schemaname, relname HAVING count(*) > 10
),

-- =================================================================================
-- 2. GENERATION HTML (DESIGN FLAT & JOLI)
-- =================================================================================
html AS (
    SELECT '
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Rapport d''Audit PostgreSQL</title>
<style>
    :root {
        --primary: #2c3e50;
        --secondary: #34495e;
        --accent: #3498db;
        --bg: #ecf0f1;
        --card-bg: #ffffff;
        --text: #333333;
    }
    body { 
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, "Open Sans", "Helvetica Neue", sans-serif;
        background-color: var(--bg); color: var(--text); margin: 0; padding: 40px; line-height: 1.6;
    }
    .container { max-width: 1200px; margin: 0 auto; }
    
    /* Header */
    header { text-align: center; margin-bottom: 40px; }
    h1 { color: var(--primary); margin: 0; font-weight: 700; font-size: 2.5rem; letter-spacing: -1px; }
    .meta { color: #7f8c8d; font-size: 0.95rem; margin-top: 5px; }

    /* Navigation */
    .nav-bar { 
        background: var(--card-bg); padding: 15px; border-radius: 8px; 
        box-shadow: 0 4px 6px rgba(0,0,0,0.05); margin-bottom: 30px; 
        display: flex; justify-content: center; gap: 20px; flex-wrap: wrap;
    }
    .nav-bar a { 
        text-decoration: none; color: var(--secondary); font-weight: 600; font-size: 0.9rem; 
        padding: 5px 10px; border-radius: 4px; transition: all 0.2s;
    }
    .nav-bar a:hover { background-color: var(--accent); color: white; }

    /* Cards Sections */
    .card { 
        background: var(--card-bg); border-radius: 8px; 
        box-shadow: 0 4px 12px rgba(0,0,0,0.08); margin-bottom: 40px; overflow: hidden; 
    }
    
    .card-header {
        background: var(--secondary); color: white; padding: 15px 20px;
        font-size: 1.1rem; font-weight: 600; letter-spacing: 0.5px;
        display: flex; align-items: center; justify-content: space-between;
    }
    
    /* Tables */
    table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
    th { 
        background: #f8f9fa; color: #7f8c8d; font-weight: 700; text-transform: uppercase; 
        font-size: 0.75rem; padding: 12px 20px; text-align: left; border-bottom: 2px solid #eee;
    }
    td { padding: 12px 20px; border-bottom: 1px solid #f1f1f1; color: #444; vertical-align: top; }
    tr:last-child td { border-bottom: none; }
    tr:hover { background-color: #f8f9fa; }

    /* Badges & Utility */
    .badge { 
        display: inline-block; padding: 4px 8px; border-radius: 4px; 
        font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;
    }
    .b-red    { background: #ffebee; color: #c0392b; border: 1px solid #ffcdd2; }
    .b-orange { background: #fff3e0; color: #e67e22; border: 1px solid #ffe0b2; }
    .b-blue   { background: #e3f2fd; color: #2980b9; border: 1px solid #bbdefb; }
    .b-gray   { background: #f5f5f5; color: #7f8c8d; border: 1px solid #e0e0e0; }
    
    .code { font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace; font-size: 0.85rem; color: #e83e8c; background: #fdf2f8; padding: 2px 5px; border-radius: 3px; }
    .val  { font-weight: 600; color: #2c3e50; }
</style>
</head>
<body>

<div class="container">
    <header>
        <h1>Audit de Santé PostgreSQL</h1>
        <div class="meta">Généré le ' || to_char(now(), 'DD/MM/YYYY à HH24:MI') || '</div>
    </header>

    <div class="nav-bar">
        <a href="#storage">💾 Stockage</a>
        <a href="#index">🔎 Indexation</a>
        <a href="#schema">🏗️ Schéma</a>
        <a href="#maint">🧹 Maintenance</a>
        <a href="#secu">🔒 Sécurité</a>
    </div>
    ' as val
    
    -- 1. STOCKAGE
    UNION ALL SELECT '<div class="card" id="storage"><div class="card-header">1. Tables & Stockage</div><table><tr><th>Statut</th><th>Objet (Schema.Table)</th><th>Détails / Impact</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">UNLOGGED</span></td><td class="code">'||object_name||'</td><td>Taille: <span class="val">'||size||'</span> (Non répliqué)</td></tr>','') FROM v_unlogged),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">BLOAT</span></td><td class="code">'||schemaname||'.'||tablename||'</td><td>Perdu: <span class="val">'||wasted||'</span> (Ratio: '||tbloat||')</td></tr>','') FROM v_bloat LIMIT 20),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">FRAGMENTATION</span></td><td class="code">'||relname||'</td><td>Type: '||typname||' (Insertions lentes)</td></tr>','') FROM v_frag),'')
    UNION ALL SELECT '</table></div>'

    -- 2. INDEXATION
    UNION ALL SELECT '<div class="card" id="index"><div class="card-header">2. Santé des Index</div><table><tr><th>Alerte</th><th>Index / Table</th><th>Analyse</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">DUPLIQUÉ</span></td><td class="code">'||tbl||'</td><td>'||indexes||'</td></tr>','') FROM v_idx_duplicate),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">REDONDANT</span></td><td class="code">'||idx_candidate||'</td><td>Inclus dans: <span class="code">'||idx_keep||'</span> (Gain: '||size_saved||')</td></tr>','') FROM v_idx_redundant),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue">INEFFICACE</span></td><td class="code">'||schemaname||'.'||relname||' <br><small>('||indexrelname||')</small></td><td>Ratio Read/Fetch: <span class="val">'||ratio||'</span></td></tr>','') FROM v_idx_ineff),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-gray">INUTILISÉ</span></td><td class="code">'||schemaname||'.'||relname||' <br><small>('||indexrelname||')</small></td><td>Taille: <span class="val">'||size||'</span></td></tr>','') FROM v_idx_unused LIMIT 20),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">SURCHARGE</span></td><td class="code">'||schemaname||'.'||relname||'</td><td><span class="val">'||cnt||'</span> index sur cette table</td></tr>','') FROM v_too_many_idx),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">INVALIDE</span></td><td class="code">'||nspname||'.'||relname||'</td><td>Index corrompu (REINDEX requis)</td></tr>','') FROM v_idx_invalid),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">MANQUANT</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>SeqScan: <span class="val">'||seq_scan||'</span></td></tr>','') FROM v_missing_idx LIMIT 20),'')
    UNION ALL SELECT '</table></div>'

    -- 3. SCHEMA
    UNION ALL SELECT '<div class="card" id="schema"><div class="card-header">3. Qualité du Schéma</div><table><tr><th>Type</th><th>Objet</th><th>Problème détecté</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">FK MANQUANTE</span></td><td class="code">'||tbl||'</td><td>Colonne: '||col||' (Risque Locking)</td></tr>','') FROM v_fk_unindexed),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">FK DOUBLON</span></td><td class="code">'||tbl||'</td><td>Constraint: '||conname||'</td></tr>','') FROM v_fk_dup),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">DENORMALISATION</span></td><td class="code">'||table_schema||'.'||table_name||'</td><td>Pattern: <b>'||pattern||'</b> ('||cnt||' colonnes)</td></tr>','') FROM v_denorm),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-gray">TABLE VIDE</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>0 tuples</td></tr>','') FROM v_empty_tbl LIMIT 20),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-gray">INUTILISÉE</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>0 accès (Scan/Fetch/DML)</td></tr>','') FROM v_unused_tbl LIMIT 20),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue">MONO-COLONNE</span></td><td class="code">'||table_schema||'.'||table_name||'</td><td>Structure suspecte</td></tr>','') FROM v_single_col),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">COLONNE NULL</span></td><td class="code">'||schemaname||'.'||relname||' <small>('||attname||')</small></td><td>Nulls: <span class="val">'||(null_frac*100)::int||'%</span></td></tr>','') FROM v_useless_col),'')
    UNION ALL SELECT '</table></div>'

    -- 4. MAINTENANCE
    UNION ALL SELECT '<div class="card" id="maint"><div class="card-header">4. Maintenance & Capacité</div><table><tr><th>Alerte</th><th>Objet</th><th>Valeur Actuelle</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">SEQUENCE FULL</span></td><td class="code">'||schemaname||'.'||sequencename||'</td><td>Utilisation: <span class="val">'||pct||'%</span></td></tr>','') FROM v_seq),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">TUNING AV</span></td><td class="code">'||schemaname||'.'||relname||'</td><td>Dead Tuples: <span class="val">'||n_dead_tup||'</span></td></tr>','') FROM v_av_tune),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-red">SLOT INACTIF</span></td><td class="code">'||slot_name||'</td><td>Retient les WAL (LSN: '||restart_lsn||')</td></tr>','') FROM v_slots),'')
    UNION ALL SELECT '</table></div>'

    -- 5. SECURITE
    UNION ALL SELECT '<div class="card" id="secu"><div class="card-header">5. Sécurité</div><table><tr><th>Type</th><th>Nom</th><th>Statut</th></tr>'
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-blue">ROLE</span></td><td class="code">'||rolname||'</td><td>Pwd: <b>'||pwd||'</b> (Superuser: '||rolsuper||')</td></tr>','') FROM v_secu),'')
    UNION ALL SELECT COALESCE((SELECT string_agg('<tr><td><span class="badge b-orange">FONCTION</span></td><td class="code">'||nspname||'.'||proname||'</td><td>Exécuté en SECURITY DEFINER</td></tr>','') FROM v_funcs),'')
    UNION ALL SELECT '</table></div>'

    UNION ALL SELECT '</div></body></html>'
)
SELECT string_agg(val, '') FROM html;