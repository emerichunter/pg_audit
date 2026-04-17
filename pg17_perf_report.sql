-- Configuration psql
\set quiet on
\pset format unaligned
\pset title 'Rapport Performance PostgreSQL 17'

-- -----------------------------------------------------------------------------
-- 1. En-tete HTML, CSS et JS
-- -----------------------------------------------------------------------------
\qecho <!DOCTYPE html>
\qecho <html lang="fr">
\qecho <head>
\qecho <meta charset="UTF-8">
\qecho <title>Rapport Performance PostgreSQL 17</title>
\qecho <style>
\qecho   body { font-family: 'Segoe UI', sans-serif; margin: 20px; background-color: #f4f4f9; color: #333; }
\qecho   h1 { color: #2c3e50; border-bottom: 3px solid #3498db; padding-bottom: 15px; }
\qecho   h2 { color: #c0392b; margin-top: 50px; border-left: 6px solid #c0392b; padding-left: 15px; background: #fff0f0; padding: 5px; }
\qecho   
\qecho   /* Navigation */
\qecho   .nav-menu { background: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); margin-bottom: 30px; }
\qecho   .nav-menu a { margin-right: 15px; text-decoration: none; color: #2980b9; font-weight: 600; border: 1px solid #e1e1e1; padding: 5px 10px; border-radius: 4px; background: #f9f9f9; display: inline-block; margin-bottom: 5px; font-size: 0.9em; }
\qecho   .nav-menu a:hover { background-color: #3498db; color: #fff; }
\qecho
\qecho   /* Tableaux */
\qecho   table { width: 100%; border-collapse: collapse; margin-top: 15px; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1); font-size: 0.85em; table-layout: fixed; }
\qecho   th { background-color: #34495e; color: #fff; padding: 12px; text-align: left; position: sticky; top: 0; z-index: 10; }
\qecho   td { padding: 8px; border-bottom: 1px solid #eee; vertical-align: top; font-family: monospace; color: #444; overflow: hidden; }
\qecho   tr:nth-child(even) { background-color: #fcfcfc; }
\qecho   tr:hover { background-color: #eaf2f8; }
\qecho
\qecho   /* --- CSS COLONNE REQUETE --- */
\qecho   td:first-child {
\qecho       width: 40%;              
\qecho       white-space: nowrap;     
\qecho       overflow: hidden;        
\qecho       text-overflow: ellipsis; 
\qecho       cursor: pointer;         
\qecho       color: #2980b9;          
\qecho       transition: all 0.2s;
\qecho   }
\qecho   
\qecho   td:first-child.expanded {
\qecho       white-space: pre-wrap;   
\qecho       word-break: break-all;   
\qecho       background-color: #fffbe6; 
\qecho       color: #333;
\qecho       border: 1px solid #f1c40f;
\qecho   }
\qecho   
\qecho   td:first-child:hover::after {
\qecho       content: " (cliquer)";
\qecho       font-size: 0.8em;
\qecho       color: #999;
\qecho   }
\qecho
\qecho   .timestamp { font-size: 0.8em; color: #7f8c8d; text-align: right; border-top: 1px solid #ddd; padding-top: 10px; margin-top: 40px; }
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

-- -----------------------------------------------------------------------------
-- 1. CPU
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 2. IO
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 3. PLANNING TIME
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 4. WAL
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 5. FREQUENCE
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 6. LOURDES (Candidats Parallelisme)
-- -----------------------------------------------------------------------------
\qecho <h2 id="heavy">6. Requetes Lourdes</h2>
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

-- -----------------------------------------------------------------------------
-- 7. JITTER
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 8. TEMP FILES
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 9. CACHE & DIRTIED
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 10. JIT
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 11. GLOBAL INFO
-- -----------------------------------------------------------------------------
\qecho <h2 id="info">11. Sante Globale</h2>

SELECT 
    dealloc AS "Deallocations", 
    stats_reset AS "Dernier Reset"
FROM pg_stat_statements_info;

-- -----------------------------------------------------------------------------
-- JAVASCRIPT
-- -----------------------------------------------------------------------------
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