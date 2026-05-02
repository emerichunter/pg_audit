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
\qecho   
\qecho   :root { 
\qecho     --bg: #0f172a; --surface: #1e293b; --primary: #38bdf8; --text: #f8fafc; --text-muted: #94a3b8; --border: #334155; --hover: #0ea5e9; 
\qecho     --h2-bg: rgba(255,255,255,0.02); --h2-border: #38bdf8;
\qecho   }
\qecho   
\qecho   body.light-mode { 
\qecho     --bg: #f8fafc; --surface: #ffffff; --primary: #2563eb; --text: #1e293b; --text-muted: #64748b; --border: #e2e8f0; --hover: #1d4ed8; 
\qecho     --h2-bg: #fff0f0; --h2-border: #c0392b;
\qecho   }

\qecho   body { font-family: 'Inter', system-ui, -apple-system, sans-serif; margin: 40px auto; max-width: 1400px; background-color: var(--bg); color: var(--text); line-height: 1.6; transition: background-color 0.3s, color 0.3s; }
\qecho   
\qecho   .header-container { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 30px; }
\qecho   h1 { color: var(--text); font-size: 2.5rem; background: linear-gradient(135deg, var(--primary), #818cf8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; border-bottom: none; margin: 0; font-weight: 800; letter-spacing: -0.02em; }
\qecho   
\qecho   /* Theme Switch */
\qecho   .theme-switch { background: var(--surface); border: 1px solid var(--border); padding: 8px 16px; border-radius: 50px; cursor: pointer; display: flex; align-items: center; gap: 8px; font-weight: 600; font-size: 0.85rem; color: var(--text); transition: all 0.3s; }
\qecho   .theme-switch:hover { border-color: var(--primary); box-shadow: 0 0 15px rgba(56,189,248,0.2); }
\qecho   
\qecho   h2 { color: var(--text); margin-top: 60px; font-size: 1.5rem; display: flex; align-items: center; gap: 12px; font-weight: 700; padding: 10px; border-radius: 8px; background: var(--h2-bg); }
\qecho   h2::before { content: ''; display: block; width: 6px; height: 24px; background: var(--h2-border); border-radius: 4px; }
\qecho   body.light-mode h2 { color: #c0392b; }
\qecho   
\qecho   /* Navigation */
\qecho   .nav-menu { background: var(--surface); padding: 20px 25px; border-radius: 12px; border: 1px solid var(--border); box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 40px; }
\qecho   .nav-menu strong { color: var(--text-muted); margin-right: 10px; font-weight: 600; }
\qecho   .nav-menu a { text-decoration: none; color: var(--text); font-weight: 500; padding: 8px 16px; border-radius: 8px; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.05); transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1); font-size: 0.9em; }
\qecho   .nav-menu a:hover { background: var(--primary); color: #fff; border-color: var(--primary); transform: translateY(-2px); box-shadow: 0 4px 12px rgba(56,189,248,0.3); }

\qecho   /* Tableaux */
\qecho   table { width: 100%; border-collapse: separate; border-spacing: 0; margin-top: 20px; background: var(--surface); border-radius: 12px; box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); font-size: 0.95em; table-layout: fixed; border: 1px solid var(--border); overflow: hidden; }
\qecho   th { background: rgba(255,255,255,0.02); color: var(--text-muted); padding: 16px; text-align: left; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; font-size: 0.75rem; border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 10; backdrop-filter: blur(8px); }
\qecho   body.light-mode th { background: #34495e; color: #fff; }
\qecho   td { padding: 16px; border-bottom: 1px solid var(--border); vertical-align: top; font-family: 'JetBrains Mono', 'Fira Code', monospace; color: var(--text); }
\qecho   tr:last-child td { border-bottom: none; }
\qecho   tr { transition: background-color 0.2s; }
\qecho   tr:hover { background-color: rgba(255,255,255,0.03); }
\qecho   body.light-mode tr:hover { background-color: #f1f5f9; }

\qecho   /* --- CSS COLONNE REQUETE --- */
\qecho   td:first-child { width: 40%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; cursor: pointer; color: var(--primary); transition: all 0.3s ease; }
\qecho   td:first-child.expanded { white-space: pre-wrap; word-break: break-all; background: rgba(56,189,248,0.05); border-left: 3px solid var(--primary); padding-left: 13px; color: var(--text); border-radius: 0 8px 8px 0; }
\qecho   body.light-mode td:first-child.expanded { background: #fffbe6; border-left-color: #f59e0b; }
\qecho   td:first-child:hover { color: var(--hover); }

\qecho   /* Back to Top */
\qecho   #backToTop { position: fixed; bottom: 30px; right: 30px; width: 50px; height: 50px; background: var(--primary); color: white; border: none; border-radius: 50%; cursor: pointer; display: none; align-items: center; justify-content: center; font-size: 1.5rem; box-shadow: 0 4px 15px rgba(0,0,0,0.3); transition: all 0.3s; z-index: 1000; }
\qecho   #backToTop:hover { transform: translateY(-5px); background: var(--hover); }

\qecho   .timestamp { font-size: 0.85em; color: var(--text-muted); text-align: center; margin-top: 60px; padding-top: 20px; border-top: 1px solid var(--border); font-weight: 500; }
\qecho </style>
\qecho </head>
\qecho <body>
\qecho <div class="header-container">
\qecho   <h1 data-i18n="title">Rapport Audit Complet (PG 17)</h1>
\qecho   <div style="display: flex; gap: 10px;">
\qecho     <button class="theme-switch" onclick="toggleLanguage()">
\qecho       <span id="lang-icon">🌍</span> <span id="lang-text">EN</span>
\qecho     </button>
\qecho     <button class="theme-switch" onclick="toggleTheme()">
\qecho       <span id="theme-icon">🌞</span> <span id="theme-text">Mode Clair</span>
\qecho     </button>
\qecho   </div>
\qecho </div>

\qecho <div class="nav-menu">
\qecho   <strong data-i18n="nav_title">Navigation Rapide :</strong>
\qecho   <a href="#cpu" data-i18n="nav_cpu">1. Top CPU</a>
\qecho   <a href="#io" data-i18n="nav_io">2. Top IO</a>
\qecho   <a href="#planning" data-i18n="nav_plan">3. Planning Time</a>
\qecho   <a href="#wal" data-i18n="nav_wal">4. Top WAL</a>
\qecho   <a href="#freq" data-i18n="nav_freq">5. Frequence</a>
\qecho   <a href="#heavy" data-i18n="nav_heavy">6. Lourdes (Candidats Parallel)</a>
\qecho   <a href="#jitter" data-i18n="nav_jitter">7. Jitter</a>
\qecho   <a href="#temp" data-i18n="nav_temp">8. Temp Files</a>
\qecho   <a href="#cache" data-i18n="nav_cache">9. Cache Miss</a>
\qecho   <a href="#jit" data-i18n="nav_jit">10. JIT</a>
\qecho   <a href="#info" data-i18n="nav_info">11. Info Globales</a>
\qecho </div>

\pset format html
\pset tableattr 'class="data-table"'

\qecho <h2 id="cpu" data-i18n="h2_cpu">1. Top Consommateurs CPU (Hors IO)</h2>
\qecho <p data-i18n="p_cpu">Charge processeur pure (Total Time - IO Time).</p>

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

\qecho <h2 id="io" data-i18n="h2_io">2. Top IO (Latence Disque)</h2>
\qecho <p data-i18n="p_io">Attente disque (lecture/ecriture).</p>

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

\qecho <h2 id="planning" data-i18n="h2_plan">3. Temps de Planification</h2>
\qecho <p data-i18n="p_plan">Necessite track_planning = on.</p>

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

\qecho <h2 id="wal" data-i18n="h2_wal">4. Top Generateurs de WAL</h2>
\qecho <p data-i18n="p_wal">Ecritures journaux (pression checkpoint).</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    pg_size_pretty(wal_bytes) AS "Total WAL",
    round((wal_bytes / NULLIF(calls, 0))::numeric, 2) AS "Bytes / Appel",
    wal_records AS "WAL Records"
FROM pg_stat_statements
ORDER BY wal_bytes DESC 
LIMIT 10;

\qecho <h2 id="freq" data-i18n="h2_freq">5. Haute Frequence</h2>
\qecho <p data-i18n="p_freq">Requetes rapides mais massives.</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round(mean_exec_time::numeric, 2) AS "Moyenne (ms)",
    round(total_exec_time::numeric, 2) AS "Total (ms)",
    round((100.0 * total_exec_time / SUM(total_exec_time) OVER())::numeric, 2) AS "PCT Charge"
FROM pg_stat_statements
ORDER BY calls DESC 
LIMIT 10;

\qecho <h2 id="heavy" data-i18n="h2_heavy">6. Lourdes (Candidats Parallelisme)</h2>
\qecho <p data-i18n="p_heavy">Les plus longues en temps absolu. Candidats potentiels pour parallelisme.</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round(total_exec_time::numeric, 2) AS "Total Time (ms)",
    round(mean_exec_time::numeric, 2) AS "Moyenne (ms)",
    rows AS "Lignes Totales"
FROM pg_stat_statements
ORDER BY total_exec_time DESC 
LIMIT 10;

\qecho <h2 id="jitter" data-i18n="h2_jitter">7. Instabilite (Jitter)</h2>
\qecho <p data-i18n="p_jitter">Ecart-type eleve (plans instables).</p>

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

\qecho <h2 id="temp" data-i18n="h2_temp">8. Temp Files (Disk Spill)</h2>
\qecho <p data-i18n="p_temp">Manque de work_mem.</p>

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

\qecho <h2 id="cache" data-i18n="h2_cache">9. Cache Miss et Blocs Salis</h2>
\qecho <p data-i18n="p_cache">Pression sur le buffer pool (RAM).</p>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0)), 2) AS "Cache Hit PCT",
    (shared_blks_dirtied + local_blks_dirtied) AS "Blocks Salis"
FROM pg_stat_statements
ORDER BY (shared_blks_hit + shared_blks_read) DESC
LIMIT 10;

\qecho <h2 id="jit" data-i18n="h2_jit">10. Surcharge JIT</h2>

SELECT 
    query AS "Requete (Cliquer)",
    calls AS "Appels",
    round(mean_exec_time::numeric, 2) AS "Moyenne (ms)",
    round((jit_generation_time + jit_inlining_time + jit_optimization_time + jit_emission_time)::numeric, 2) AS "JIT Overhead (ms)"
FROM pg_stat_statements
WHERE jit_functions > 0
ORDER BY (jit_generation_time + jit_inlining_time + jit_optimization_time + jit_emission_time) DESC 
LIMIT 10;

\qecho <h2 id="info" data-i18n="h2_info">11. Sante Globale</h2>

SELECT 
    dealloc AS "Deallocations", 
    stats_reset AS "Dernier Reset"
FROM pg_stat_statements_info;

\qecho <button id="backToTop" onclick="scrollToTop()" title="Retour en haut">↑</button>

\qecho <script>
\qecho let currentLang = 'fr';
\qecho const translations = {
\qecho   fr: {
\qecho     title: "Rapport Audit Complet (PG 17)",
\qecho     nav_title: "Navigation Rapide :",
\qecho     nav_cpu: "1. Top CPU", nav_io: "2. Top IO", nav_plan: "3. Planning Time", nav_wal: "4. Top WAL", nav_freq: "5. Frequence",
\qecho     nav_heavy: "6. Lourdes", nav_jitter: "7. Jitter", nav_temp: "8. Temp Files", nav_cache: "9. Cache Miss", nav_jit: "10. JIT", nav_info: "11. Info",
\qecho     h2_cpu: "1. Top Consommateurs CPU (Hors IO)", p_cpu: "Charge processeur pure (Total Time - IO Time).",
\qecho     h2_io: "2. Top IO (Latence Disque)", p_io: "Attente disque (lecture/ecriture).",
\qecho     h2_plan: "3. Temps de Planification", p_plan: "Nécessite track_planning = on.",
\qecho     h2_wal: "4. Top Générateurs de WAL", p_wal: "Ecritures journaux (pression checkpoint).",
\qecho     h2_freq: "5. Haute Fréquence", p_freq: "Requêtes rapides mais massives.",
\qecho     h2_heavy: "6. Lourdes (Candidats Parallélisme)", p_heavy: "Les plus longues en temps absolu.",
\qecho     h2_jitter: "7. Instabilité (Jitter)", p_jitter: "Ecart-type élevé (plans instables).",
\qecho     h2_temp: "8. Temp Files (Disk Spill)", p_temp: "Manque de work_mem.",
\qecho     h2_cache: "9. Cache Miss et Blocs Salis", p_cache: "Pression sur le buffer pool (RAM).",
\qecho     h2_jit: "10. Surcharge JIT", h2_info: "11. Santé Globale",
\qecho     "Requete (Cliquer)": "Query (Click)", "Appels": "Calls", "Total (ms)": "Total (ms)", "CPU Time (ms)": "CPU Time (ms)", "PCT CPU": "PCT CPU",
\qecho     "Moyenne (ms)": "Average (ms)", "IO Wait (ms)": "IO Wait (ms)", "PCT IO": "PCT IO", "Total Plan (ms)": "Total Plan (ms)",
\qecho     "Moy Plan (ms)": "Avg Plan (ms)", "PCT Planning": "PCT Planning", "Total WAL": "Total WAL", "Bytes / Appel": "Bytes / Call",
\qecho     "WAL Records": "WAL Records", "PCT Charge": "PCT Load", "Total Time (ms)": "Total Time (ms)", "Lignes Totales": "Total Rows",
\qecho     "Ecart-Type (ms)": "Stddev (ms)", "Ratio Var.": "Var. Ratio", "Blks Written": "Blks Written", "Total Temp Size": "Total Temp Size",
\qecho     "Blks / Appel": "Blks / Call", "Cache Hit PCT": "Cache Hit PCT", "Blocks Salis": "Dirtied Blocks", "JIT Overhead (ms)": "JIT Overhead (ms)",
\qecho     "Deallocations": "Deallocations", "Dernier Reset": "Last Reset", "timestamp_prefix": "Généré le: ", "back_to_top": "Retour en haut"
\qecho   },
\qecho   en: {
\qecho     title: "Complete Audit Report (PG 17)",
\qecho     nav_title: "Quick Navigation:",
\qecho     nav_cpu: "1. Top CPU", nav_io: "2. Top IO", nav_plan: "3. Planning Time", nav_wal: "4. Top WAL", nav_freq: "5. Frequency",
\qecho     nav_heavy: "6. Heavy Queries", nav_jitter: "7. Jitter", nav_temp: "8. Temp Files", nav_cache: "9. Cache Miss", nav_jit: "10. JIT", nav_info: "11. Info",
\qecho     h2_cpu: "1. Top CPU Consumers (Excl. IO)", p_cpu: "Pure processor load (Total Time - IO Time).",
\qecho     h2_io: "2. Top IO (Disk Latency)", p_io: "Disk wait (read/write).",
\qecho     h2_plan: "3. Planning Time", p_plan: "Requires track_planning = on.",
\qecho     h2_wal: "4. Top WAL Generators", p_wal: "Journal writes (checkpoint pressure).",
\qecho     h2_freq: "5. High Frequency", p_freq: "Fast but massive query volume.",
\qecho     h2_heavy: "6. Heavy Queries (Parallel Candidates)", p_heavy: "Longest absolute execution times.",
\qecho     h2_jitter: "7. Instability (Jitter)", p_jitter: "High standard deviation (unstable plans).",
\qecho     h2_temp: "8. Temp Files (Disk Spill)", p_temp: "Insufficient work_mem.",
\qecho     h2_cache: "9. Cache Miss & Dirtied Blocks", p_cache: "Pressure on buffer pool (RAM).",
\qecho     h2_jit: "10. JIT Overhead", h2_info: "11. Global Health",
\qecho     "Requete (Cliquer)": "Query (Click)", "Appels": "Calls", "Total (ms)": "Total (ms)", "CPU Time (ms)": "CPU Time (ms)", "PCT CPU": "PCT CPU",
\qecho     "Moyenne (ms)": "Average (ms)", "IO Wait (ms)": "IO Wait (ms)", "PCT IO": "PCT IO", "Total Plan (ms)": "Total Plan (ms)",
\qecho     "Moy Plan (ms)": "Avg Plan (ms)", "PCT Planning": "PCT Planning", "Total WAL": "Total WAL", "Bytes / Appel": "Bytes / Call",
\qecho     "WAL Records": "WAL Records", "PCT Charge": "PCT Load", "Total Time (ms)": "Total Time (ms)", "Lignes Totales": "Total Rows",
\qecho     "Ecart-Type (ms)": "Stddev (ms)", "Ratio Var.": "Var. Ratio", "Blks Written": "Blks Written", "Total Temp Size": "Total Temp Size",
\qecho     "Blks / Appel": "Blks / Call", "Cache Hit PCT": "Cache Hit PCT", "Blocks Salis": "Dirtied Blocks", "JIT Overhead (ms)": "JIT Overhead (ms)",
\qecho     "Deallocations": "Deallocations", "Dernier Reset": "Last Reset", "timestamp_prefix": "Generated on: ", "back_to_top": "Back to Top"
\qecho   }
\qecho };
\qecho
\qecho function toggleLanguage() {
\qecho   currentLang = currentLang === 'fr' ? 'en' : 'fr';
\qecho   document.getElementById('lang-text').innerText = currentLang === 'fr' ? 'EN' : 'FR';
\qecho   updateUI();
\qecho }
\qecho
\qecho function updateUI() {
\qecho   document.querySelectorAll('[data-i18n]').forEach(el => {
\qecho     const key = el.getAttribute('data-i18n');
\qecho     if (translations[currentLang][key]) el.innerText = translations[currentLang][key];
\qecho   });
\qecho   
\qecho   document.querySelectorAll('th').forEach(th => {
\qecho     const text = th.innerText.trim();
\qecho     for (const [fr, en] of Object.entries(translations.fr)) {
\qecho       if (text === (currentLang === 'en' ? fr : en)) {
\qecho         th.innerText = translations[currentLang][fr] || text;
\qecho         break;
1\qecho       }
\qecho     }
\qecho   });
\qecho   
\qecho   const btt = document.getElementById('backToTop');
\qecho   if (btt) btt.title = translations[currentLang].back_to_top;
\qecho }
\qecho
\qecho function toggleTheme() {
\qecho   const body = document.body;
\qecho   const icon = document.getElementById('theme-icon');
\qecho   const text = document.getElementById('theme-text');
\qecho   body.classList.toggle('light-mode');
\qecho   if (body.classList.contains('light-mode')) {
\qecho     icon.innerText = '🌙';
\qecho     text.innerText = currentLang === 'fr' ? 'Mode Sombre' : 'Dark Mode';
\qecho   } else {
\qecho     icon.innerText = '🌞';
\qecho     text.innerText = currentLang === 'fr' ? 'Mode Clair' : 'Light Mode';
\qecho   }
\qecho }
\qecho
\qecho function scrollToTop() {
\qecho   window.scrollTo({ top: 0, behavior: 'smooth' });
\qecho }
\qecho
\qecho window.onscroll = function() {
\qecho   const btn = document.getElementById("backToTop");
\qecho   if (document.body.scrollTop > 500 || document.documentElement.scrollTop > 500) {
\qecho     btn.style.display = "flex";
\qecho   } else {
\qecho     btn.style.display = "none";
\qecho   }
\qecho };
\qecho
\qecho document.addEventListener("DOMContentLoaded", function() {
\qecho     var cells = document.querySelectorAll("td:first-child");
\qecho     cells.forEach(function(cell) {
\qecho         cell.title = currentLang === 'fr' ? "Cliquez pour voir la requete complete" : "Click to see full query";
\qecho         cell.addEventListener("click", function() {
\qecho             this.classList.toggle("expanded");
\qecho         });
\qecho     });
\qecho     updateUI();
\qecho });
\qecho </script>

\qecho <div class="timestamp"><span data-i18n="timestamp_prefix">Généré le: </span> <script>document.write(new Date().toLocaleString())</script></div>
\qecho </body>
\qecho </html>
