\set quiet on
\pset format unaligned
\pset tuples_only on
\pset border 0
\pset footer off

\qecho <!DOCTYPE html>
\qecho <html lang="fr">
\qecho <head>
\qecho <meta charset="UTF-8">
\qecho <title>Rapport Performance PostgreSQL 17</title>
\qecho <style>
\qecho   @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500&display=swap');
\qecho   :root { --bg: #0f172a; --surface: #1e293b; --primary: #38bdf8; --text: #f8fafc; --text-muted: #94a3b8; --border: #334155; --hover: #0ea5e9; }
\qecho   body { font-family: 'Inter', system-ui, -apple-system, sans-serif; margin: 40px auto; max-width: 1400px; background-color: var(--bg); color: var(--text); line-height: 1.6; }
\qecho   h1 { color: var(--text); font-size: 2.5rem; background: linear-gradient(135deg, #38bdf8, #818cf8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; border-bottom: none; margin-bottom: 30px; font-weight: 800; letter-spacing: -0.02em; }
\qecho   h2 { color: var(--text); margin-top: 60px; font-size: 1.5rem; display: flex; align-items: center; gap: 12px; font-weight: 700; }
\qecho   h2::before { content: ''; display: block; width: 6px; height: 24px; background: linear-gradient(to bottom, #38bdf8, #818cf8); border-radius: 4px; }
\qecho   
\qecho   /* Navigation */
\qecho   .nav-menu { background: var(--surface); padding: 20px 25px; border-radius: 12px; border: 1px solid var(--border); box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 40px; }
\qecho   .nav-menu strong { color: var(--text-muted); margin-right: 10px; font-weight: 600; }
\qecho   .nav-menu a { text-decoration: none; color: var(--text); font-weight: 500; padding: 8px 16px; border-radius: 8px; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.05); transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1); font-size: 0.9em; }
\qecho   .nav-menu a:hover { background: var(--primary); color: #fff; border-color: var(--primary); transform: translateY(-2px); box-shadow: 0 4px 12px rgba(56,189,248,0.3); }
\qecho
\qecho   /* Tableaux */
\qecho   table { width: 100%; border-collapse: separate; border-spacing: 0; margin-top: 20px; background: var(--surface); border-radius: 12px; box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); font-size: 0.95em; table-layout: fixed; border: 1px solid var(--border); }
\qecho   th { background: rgba(255,255,255,0.02); color: var(--text-muted); padding: 16px; text-align: left; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; font-size: 0.75rem; border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 10; backdrop-filter: blur(8px); }
\qecho   th:first-child { border-top-left-radius: 12px; }
\qecho   th:last-child { border-top-right-radius: 12px; }
\qecho   td { padding: 16px; border-bottom: 1px solid var(--border); vertical-align: top; font-family: 'JetBrains Mono', 'Fira Code', monospace; color: var(--text); }
\qecho   tr:last-child td { border-bottom: none; }
\qecho   tr { transition: background-color 0.2s; }
\qecho   tr:hover { background-color: rgba(255,255,255,0.03); }
\qecho
\qecho   /* --- CSS COLONNE REQUETE --- */
\qecho   td:first-child { width: 40%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; cursor: pointer; color: var(--primary); transition: all 0.3s ease; }
\qecho   td:first-child.expanded { white-space: pre-wrap; word-break: break-all; background: rgba(56,189,248,0.05); border-left: 3px solid var(--primary); padding-left: 13px; color: var(--text); border-radius: 0 8px 8px 0; }
\qecho   td:first-child:hover { color: var(--hover); }
\qecho   td:first-child:not(.expanded):hover::after { content: " (cliquer)"; font-size: 0.8em; opacity: 0.6; }
\qecho
\qecho   .timestamp { font-size: 0.85em; color: var(--text-muted); text-align: center; margin-top: 60px; padding-top: 20px; border-top: 1px solid var(--border); font-weight: 500; }
\qecho </style>
\qecho </head>
\qecho <body>

\qecho <h1>Rapport Audit Complet (PG 17)</h1>

\qecho <div class="nav-menu">
\qecho   <strong>Navigation Rapide :</strong>
\qecho   <a href="#cpu">1. Top CPU</a>
\qecho   <a href="#io">2. Top IO</a>
\qecho   <a href="#planning">3. Planning Time</a>
\qecho   <a href="#wal">4. Top WAL</a>
\qecho   <a href="#freq">5. Frequence</a>
\qecho   <a href="#heavy">6. Lourdes (Candidats Parallel)</a>
\qecho   <a href="#jitter">7. Jitter</a>
\qecho   <a href="#temp">8. Temp Files</a>
\qecho   <a href="#cache">9. Cache Miss</a>
\qecho   <a href="#jit">10. JIT</a>
\qecho   <a href="#info">11. Info Globales</a>
\qecho </div>

\pset format html
\pset tableattr 'class="data-table"'

\qecho <h2 id="cpu">1. Top Consommateurs CPU (Hors IO)</h2>
\qecho <p>Charge processeur pure (Total Time - IO Time).</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round(total_exec_time::numeric, 2) AS "Total (ms)",
    round((total_exec_time - (shared_blk_read_time + shared_blk_write_time + local_blk_read_time + local_blk_write_time + temp_blk_read_time + temp_blk_write_time))::numeric, 2) AS "CPU Time (ms)",
    round((100 * (total_exec_time - (shared_blk_read_time + shared_blk_write_time + local_blk_read_time + local_blk_write_time + temp_blk_read_time + temp_blk_write_time)) / NULLIF(total_exec_time, 0))::numeric, 1) AS "PCT CPU"
FROM pg_stat_statements
WHERE calls > 50
ORDER BY (total_exec_time - (shared_blk_read_time + shared_blk_write_time + local_blk_read_time + local_blk_write_time + temp_blk_read_time + temp_blk_write_time)) DESC 
LIMIT 10;

\qecho <h2 id="io">2. Top IO (Latence Disque)</h2>
\qecho <p>Attente disque (lecture/ecriture).</p>

SELECT
    query AS "Requete (Cliquer)", 
    calls AS "Appels",
    round(mean_exec_time::numeric, 2) AS "Moyenne (ms)",
    round((shared_blk_read_time + shared_blk_write_time + local_blk_read_time + local_blk_write_time + temp_blk_read_time + temp_blk_write_time)::numeric, 2) AS "IO Wait (ms)",
    round((100 * (shared_blk_read_time + shared_blk_write_time + local_blk_read_time + local_blk_write_time + temp_blk_read_time + temp_blk_write_time) / NULLIF(total_exec_time, 0))::numeric, 1) AS "PCT IO"
FROM pg_stat_statements
WHERE (shared_blk_read_time + shared_blk_write_time + local_blk_read_time + local_blk_write_time + temp_blk_read_time + temp_blk_write_time) > 0
ORDER BY (shared_blk_read_time + shared_blk_write_time + local_blk_read_time + local_blk_write_time + temp_blk_read_time + temp_blk_write_time) DESC 
LIMIT 10;

\qecho <h2 id="planning">3. Temps de Planification</h2>
\qecho <p>Necessite track_planning = on.</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round(total_plan_time::numeric, 2) AS "Total Plan (ms)",
    round(mean_plan_time::numeric, 2) AS "Moy Plan (ms)",
    round((total_plan_time / NULLIF(total_exec_time + total_plan_time, 0) * 100)::numeric, 1) AS "PCT Planning"
FROM pg_stat_statements
WHERE plans > 0
ORDER BY total_plan_time DESC
LIMIT 10;

\qecho <h2 id="wal">4. Top Generateurs de WAL</h2>
\qecho <p>Ecritures journaux (pression checkpoint).</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    pg_size_pretty(wal_bytes) AS "Total WAL",
    round((wal_bytes / NULLIF(calls, 0))::numeric, 2) AS "Bytes / Appel",
    wal_records AS "WAL Records"
FROM pg_stat_statements
ORDER BY wal_bytes DESC 
LIMIT 10;

\qecho <h2 id="freq">5. Haute Frequence</h2>
\qecho <p>Requetes rapides mais massives.</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round(mean_exec_time::numeric, 2) AS "Moyenne (ms)",
    round(total_exec_time::numeric, 2) AS "Total (ms)",
    round((100.0 * total_exec_time / SUM(total_exec_time) OVER())::numeric, 2) AS "PCT Charge"
FROM pg_stat_statements
ORDER BY calls DESC 
LIMIT 10;

\qecho <h2 id="heavy">6. Lourdes (Candidats Parallelisme)</h2>
\qecho <p>Les plus longues en temps absolu. Candidats potentiels pour parallelisme.</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round(total_exec_time::numeric, 2) AS "Total Time (ms)",
    round(mean_exec_time::numeric, 2) AS "Moyenne (ms)",
    rows AS "Lignes Totales"
FROM pg_stat_statements
ORDER BY total_exec_time DESC 
LIMIT 10;

\qecho <h2 id="jitter">7. Instabilite (Jitter)</h2>
\qecho <p>Ecart-type eleve (plans instables).</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round(mean_exec_time::numeric, 2) AS "Moyenne (ms)",
    round(stddev_exec_time::numeric, 2) AS "Ecart-Type (ms)",
    round((stddev_exec_time / NULLIF(mean_exec_time, 0))::numeric, 2) AS "Ratio Var."
FROM pg_stat_statements
WHERE calls > 10 
  AND stddev_exec_time > mean_exec_time
ORDER BY stddev_exec_time DESC 
LIMIT 10;

\qecho <h2 id="temp">8. Temp Files (Disk Spill)</h2>
\qecho <p>Manque de work_mem.</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    temp_blks_written AS "Blks Written",
    pg_size_pretty(temp_blks_written * 8192) AS "Total Temp Size",
    round((temp_blks_written::numeric / NULLIF(calls, 0)), 2) AS "Blks / Appel"
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC 
LIMIT 10;

\qecho <h2 id="cache">9. Cache Miss et Blocs Salis</h2>
\qecho <p>Pression sur le buffer pool (RAM).</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0)), 2) AS "Cache Hit PCT",
    (shared_blks_dirtied + local_blks_dirtied) AS "Blocks Salis"
FROM pg_stat_statements
ORDER BY (shared_blks_hit + shared_blks_read) DESC
LIMIT 10;

\qecho <h2 id="jit">10. Surcharge JIT</h2>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round(mean_exec_time::numeric, 2) AS "Moyenne (ms)",
    round((jit_generation_time + jit_inlining_time + jit_optimization_time + jit_emission_time)::numeric, 2) AS "JIT Overhead (ms)"
FROM pg_stat_statements
WHERE jit_functions > 0
ORDER BY (jit_generation_time + jit_inlining_time + jit_optimization_time + jit_emission_time) DESC 
LIMIT 10;

\qecho <h2 id="info">11. Sante Globale</h2>

SELECT 
    dealloc AS "Deallocations", 
    stats_reset AS "Dernier Reset"
FROM pg_stat_statements_info;

\qecho <script>
\qecho document.addEventListener("DOMContentLoaded", function() {
\qecho     var cells = document.querySelectorAll("td:first-child");
\qecho     cells.forEach(function(cell) {
\qecho         cell.title = "Cliquez pour voir la requete complete";
\qecho         cell.addEventListener("click", function() {
\qecho             this.classList.toggle("expanded");
\qecho         });
\qecho     });
\qecho });
\qecho </script>

\qecho <div class="timestamp">Genere le: <script>document.write(new Date().toLocaleString())</script></div>
\qecho </body>
\qecho </html>