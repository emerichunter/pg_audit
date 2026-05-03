\set quiet on
\pset format unaligned
\pset tuples_only on
\pset border 0
\pset footer off

-- Get dynamic version
SELECT current_setting('server_version') as pg_version \gset

SELECT $HTML$<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<title>Rapport Performance PostgreSQL $HTML$ || :'pg_version' || $HTML$</title>
<style>
  @import url("https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500&display=swap");
  
  :root { 
    --bg: #0f172a; --surface: #1e293b; --primary: #38bdf8; --text: #f8fafc; --text-muted: #94a3b8; --border: #334155; --hover: #0ea5e9; 
    --h2-bg: rgba(255,255,255,0.02); --h2-border: #38bdf8;
  }
  
  body.light-mode { 
    --bg: #f8fafc; --surface: #ffffff; --primary: #2563eb; --text: #1e293b; --text-muted: #64748b; --border: #e2e8f0; --hover: #1d4ed8; 
    --h2-bg: #fff0f0; --h2-border: #c0392b;
  }

  body { font-family: "Inter", system-ui, -apple-system, sans-serif; margin: 40px auto; max-width: 1400px; background-color: var(--bg); color: var(--text); line-height: 1.6; transition: background-color 0.3s, color 0.3s; }
  
  .header-container { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 30px; }
  h1 { color: var(--text); font-size: 2.5rem; background: linear-gradient(135deg, var(--primary), #818cf8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; border-bottom: none; margin: 0; font-weight: 800; letter-spacing: -0.02em; }
  .pg-version-badge { background: var(--primary); color: #000; padding: 4px 12px; border-radius: 6px; font-weight: 800; font-size: 0.9rem; margin-left: 15px; vertical-align: middle; -webkit-text-fill-color: initial; display: inline-block; }
  
  /* Theme Switch */
  .theme-switch { background: var(--surface); border: 1px solid var(--border); padding: 8px 16px; border-radius: 50px; cursor: pointer; display: flex; align-items: center; gap: 8px; font-weight: 600; font-size: 0.85rem; color: var(--text); transition: all 0.3s; }
  .theme-switch:hover { border-color: var(--primary); box-shadow: 0 0 15px rgba(56,189,248,0.2); }
  
  h2 { color: var(--text); margin-top: 60px; font-size: 1.5rem; display: flex; align-items: center; gap: 12px; font-weight: 700; padding: 10px; border-radius: 8px; background: var(--h2-bg); }
  h2::before { content: ""; display: block; width: 6px; height: 24px; background: var(--h2-border); border-radius: 4px; }
  body.light-mode h2 { color: #c0392b; }
  body.light-mode .nav-menu { background: rgba(255, 255, 255, 0.85); }
  
  /* Navigation */
  .nav-menu { position: sticky; top: 20px; z-index: 100; backdrop-filter: blur(12px); background: rgba(30, 41, 59, 0.85); padding: 20px 25px; border-radius: 12px; border: 1px solid var(--border); box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 40px; }
  .nav-menu strong { color: var(--text-muted); margin-right: 10px; font-weight: 600; }
  .nav-menu a { text-decoration: none; color: var(--text); font-weight: 500; padding: 8px 16px; border-radius: 8px; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.05); transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1); font-size: 0.9em; }
  .nav-menu a:hover { background: var(--primary); color: #fff; border-color: var(--primary); transform: translateY(-2px); box-shadow: 0 4px 12px rgba(56,189,248,0.3); }

  /* Tableaux */
  table { width: 100%; border-collapse: separate; border-spacing: 0; margin-top: 20px; background: var(--surface); border-radius: 12px; box-shadow: 0 10px 30px -10px rgba(0,0,0,0.5); font-size: 0.95em; table-layout: fixed; border: 1px solid var(--border); }
  th { background: rgba(255,255,255,0.02); color: var(--text-muted); padding: 16px; text-align: left; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; font-size: 0.75rem; border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 10; backdrop-filter: blur(8px); }
  body.light-mode th { background: #34495e; color: #fff; }
  td { padding: 16px; border-bottom: 1px solid var(--border); vertical-align: top; font-family: "JetBrains Mono", "Fira Code", monospace; color: var(--text); }
  tr:last-child td { border-bottom: none; }
  tr { transition: background-color 0.2s; }
  tr:hover { background-color: rgba(255,255,255,0.03); }
  body.light-mode tr:hover { background-color: #f1f5f9; }

  /* --- CSS COLONNE REQUETE --- */
  td:first-child { width: 40%; cursor: pointer; color: var(--primary); transition: all 0.3s ease; vertical-align: middle; }
  .query-content { display: -webkit-box; -webkit-line-clamp: 1; -webkit-box-orient: vertical; overflow: hidden; text-overflow: ellipsis; max-height: 1.5em; word-break: break-all; }
  .query-content:not(.expanded) br { display: none; }
  .query-content.expanded { -webkit-line-clamp: unset; max-height: none; background: rgba(56,189,248,0.05); border-left: 3px solid var(--primary); padding-left: 13px; color: var(--text); border-radius: 0 8px 8px 0; }
  body.light-mode .query-content.expanded { background: #fffbe6; border-left-color: #f59e0b; }
  td:first-child:hover .query-content:not(.expanded) { color: var(--hover); }

  /* Back to Top */
  #backToTop { position: fixed; bottom: 30px; right: 30px; width: 50px; height: 50px; background: var(--primary); color: white; border: none; border-radius: 50%; cursor: pointer; display: none; align-items: center; justify-content: center; font-size: 1.5rem; box-shadow: 0 4px 15px rgba(0,0,0,0.3); transition: all 0.3s; z-index: 1000; }
  #backToTop:hover { transform: translateY(-5px); background: var(--hover); }

  .timestamp { font-size: 0.85em; color: var(--text-muted); text-align: center; margin-top: 60px; padding-top: 20px; border-top: 1px solid var(--border); font-weight: 500; }
</style>
</head>
<body>
<div class="header-container">
  <div>
    <h1 data-i18n="title">Rapport Performance PostgreSQL <span class="pg-version-badge">$HTML$ || :'pg_version' || $HTML$</span></h1>
  </div>
  <div style="display: flex; gap: 10px;">
    <button class="theme-switch" onclick="toggleLanguage()">
      <span id="lang-icon"><svg class="icon" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"></circle><line x1="2" y1="12" x2="22" y2="12"></line><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"></path></svg></span> <span id="lang-text">EN</span>
    </button>
    <button class="theme-switch" onclick="toggleTheme()">
      <span id="theme-icon"><svg class="icon" viewBox="0 0 24 24"><circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line></svg></span> <span id="theme-text">Mode Clair</span>
    </button>
  </div>
</div>
<div class="nav-menu">
  <strong data-i18n="nav_title">Navigation Rapide :</strong>
  <a href="#cpu" data-i18n="nav_cpu">1. Top CPU</a>
  <a href="#io" data-i18n="nav_io">2. Top IO</a>
  <a href="#planning" data-i18n="nav_plan">3. Planning Time</a>
  <a href="#wal" data-i18n="nav_wal">4. Top WAL</a>
  <a href="#freq" data-i18n="nav_freq">5. Frequence</a>
  <a href="#heavy" data-i18n="nav_heavy">6. Lourdes (Candidats Parallel)</a>
  <a href="#jitter" data-i18n="nav_jitter">7. Jitter</a>
  <a href="#temp" data-i18n="nav_temp">8. Temp Files</a>
  <a href="#cache" data-i18n="nav_cache">9. Cache Miss</a>
  <a href="#jit" data-i18n="nav_jit">10. JIT</a>
  <a href="#info" data-i18n="nav_info">11. Info Globales</a>
</div>
<h2 id="cpu" data-i18n="h2_cpu">1. Top Consommateurs CPU (Hors IO)</h2>
<p data-i18n="p_cpu">Charge processeur pure (Total Time - IO Time).</p>$HTML$;

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

SELECT $HTML$
<button id="backToTop" onclick="scrollToTop()" title="Retour en haut"><svg class="icon" viewBox="0 0 24 24"><path d="M12 19V5M5 12l7-7 7 7"></path></svg></button>
<script>
const translations = {
  fr: {
    title: "Rapport Performance PostgreSQL",
    nav_title: "Navigation Rapide :",
    nav_cpu: "1. Top CPU", nav_io: "2. Top IO", nav_plan: "3. Planning Time", nav_wal: "4. Top WAL", nav_freq: "5. Frequence",
    nav_heavy: "6. Lourdes (Candidats Parallel)", nav_jitter: "7. Jitter", nav_temp: "8. Temp Files", nav_cache: "9. Cache Miss", nav_jit: "10. JIT", nav_info: "11. Info Globales",
    h2_cpu: "1. Top Consommateurs CPU (Hors IO)", p_cpu: "Charge processeur pure (Total Time - IO Time).",
    h2_io: "2. Top Consommateurs IO (Latence Disque)", p_io: "Attente disque (lecture/ecriture).",
    h2_plan: "3. Top Temps de Planification", p_plan: "Necessite track_planning = on.",
    h2_wal: "4. Top Generateurs de WAL", p_wal: "Ecritures journalisees (pression sur les checkpoints).",
    h2_freq: "5. Top Frequence (Requetes marteaux)", p_freq: "Requetes tres rapides mais au volume massif.",
    h2_heavy: "6. Requetes Lourdes (Temps total)", p_heavy: "Les temps d'execution absolus les plus longs.",
    h2_jitter: "7. Instabilite (Jitter / Ecart-type)", p_jitter: "Forte deviation standard (plans instables).",
    h2_temp: "8. Fichiers Temporaires (Spill to Disk)", p_temp: "Consommateurs de work_mem.",
    h2_cache: "9. Cache Miss et Blocs Salis", p_cache: "Pression sur le buffer pool (RAM).",
    h2_jit: "10. Surcharge JIT", h2_info: "11. Informations Globales et Sante",
    "Requete (Cliquer)": "Requete (Cliquer)", "Appels": "Appels", "Total (ms)": "Total (ms)", "CPU Time (ms)": "CPU Time (ms)", "PCT CPU": "PCT CPU",
    "Moyenne (ms)": "Moyenne (ms)", "IO Wait (ms)": "IO Wait (ms)", "PCT IO": "PCT IO", "Total Plan (ms)": "Total Plan (ms)",
    "Moy Plan (ms)": "Moy Plan (ms)", "PCT Planning": "PCT Planning", "Total WAL": "Total WAL", "Bytes / Appel": "Bytes / Appel",
    "WAL Records": "WAL Records", "PCT Charge": "PCT Charge", "Total Time (ms)": "Total Time (ms)", "Lignes Totales": "Lignes Totales",
    "Ecart-Type (ms)": "Ecart-Type (ms)", "Ratio Var.": "Ratio Var.", "Blks Written": "Blks Written", "Total Temp Size": "Total Temp Size",
    "Blks / Appel": "Blks / Appel", "Cache Hit PCT": "Cache Hit PCT", "Blocks Salis": "Blocks Salis", "JIT Overhead (ms)": "JIT Overhead (ms)",
    "Deallocations": "Deallocations", "Dernier Reset": "Dernier Reset", "timestamp_prefix": "Généré le: ", "back_to_top": "Retour en haut"
  },
  en: {
    title: "PostgreSQL Performance Report",
    nav_title: "Quick Navigation:",
    nav_cpu: "1. Top CPU", nav_io: "2. Top IO", nav_plan: "3. Planning Time", nav_wal: "4. Top WAL", nav_freq: "5. Frequency",
    nav_heavy: "6. Heavy Queries", nav_jitter: "7. Jitter", nav_temp: "8. Temp Files", nav_cache: "9. Cache Miss", nav_jit: "10. JIT", nav_info: "11. Info",
    h2_cpu: "1. Top CPU Consumers (Excl. IO)", p_cpu: "Pure processor load (Total Time - IO Time).",
    h2_io: "2. Top IO (Disk Latency)", p_io: "Disk wait (read/write).",
    h2_plan: "3. Planning Time", p_plan: "Requires track_planning = on.",
    h2_wal: "4. Top WAL Generators", p_wal: "Journal writes (checkpoint pressure).",
    h2_freq: "5. High Frequency", p_freq: "Fast but massive query volume.",
    h2_heavy: "6. Heavy Queries (Parallel Candidates)", p_heavy: "Longest absolute execution times.",
    h2_jitter: "7. Instability (Jitter)", p_jitter: "High standard deviation (unstable plans).",
    h2_temp: "8. Temp Files (Disk Spill)", p_temp: "Insufficient work_mem.",
    h2_cache: "9. Cache Miss & Dirtied Blocks", p_cache: "Pressure on buffer pool (RAM).",
    h2_jit: "10. JIT Overhead", h2_info: "11. Global Health",
    "Requete (Cliquer)": "Query (Click)", "Appels": "Calls", "Total (ms)": "Total (ms)", "CPU Time (ms)": "CPU Time (ms)", "PCT CPU": "PCT CPU",
    "Moyenne (ms)": "Average (ms)", "IO Wait (ms)": "IO Wait (ms)", "PCT IO": "PCT IO", "Total Plan (ms)": "Total Plan (ms)",
    "Moy Plan (ms)": "Avg Plan (ms)", "PCT Planning": "PCT Planning", "Total WAL": "Total WAL", "Bytes / Appel": "Bytes / Call",
    "WAL Records": "WAL Records", "PCT Charge": "PCT Load", "Total Time (ms)": "Total Time (ms)", "Lignes Totales": "Total Rows",
    "Ecart-Type (ms)": "Stddev (ms)", "Ratio Var.": "Var. Ratio", "Blks Written": "Blks Written", "Total Temp Size": "Total Temp Size",
    "Blks / Appel": "Blks / Call", "Cache Hit PCT": "Cache Hit PCT", "Blocks Salis": "Dirtied Blocks", "JIT Overhead (ms)": "JIT Overhead (ms)",
    "Deallocations": "Deallocations", "Dernier Reset": "Last Reset", "timestamp_prefix": "Generated on: ", "back_to_top": "Back to Top"
  }
};

let currentLang = "fr";

function toggleLanguage() {
  currentLang = currentLang === "fr" ? "en" : "fr";
  document.getElementById("lang-text").innerText = currentLang === "fr" ? "EN" : "FR";
  updateUI();
}

function updateUI() {
  document.querySelectorAll("[data-i18n]").forEach(el => {
    const key = el.getAttribute("data-i18n");
    if (translations[currentLang][key]) el.innerHTML = translations[currentLang][key];
  });
}

function toggleTheme() {
  const body = document.body;
  const icon = document.getElementById("theme-icon");
  const text = document.getElementById("theme-text");
  body.classList.toggle("light-mode");
  if (body.classList.contains("light-mode")) {
    icon.innerHTML = <svg class="icon" viewBox="0 0 24 24"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>;
    text.innerText = currentLang === "fr" ? "Mode Sombre" : "Dark Mode";
  } else {
    icon.innerHTML = <svg class="icon" viewBox="0 0 24 24"><circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line></svg>;
    text.innerText = currentLang === "fr" ? "Mode Clair" : "Light Mode";
  }
}

function scrollToTop() {
  window.scrollTo({ top: 0, behavior: "smooth" });
}

window.onscroll = function() {
  const btn = document.getElementById("backToTop");
  if (document.body.scrollTop > 500 || document.documentElement.scrollTop > 500) {
    btn.style.display = "flex";
  } else {
    btn.style.display = "none";
  }
};

document.addEventListener("DOMContentLoaded", function() {
    var cells = document.querySelectorAll("td:first-child");
    cells.forEach(function(cell) {
        var content = cell.innerHTML;
        cell.innerHTML = '<div class="query-content">' + content + '</div>';
        cell.title = currentLang === "fr" ? "Cliquez pour voir la requ&ecirc;te compl&egrave;te" : "Click to see full query";
        cell.addEventListener("click", function() {
            this.querySelector(".query-content").classList.toggle("expanded");
        });
    });
    updateUI();
});

// Override updateUI to also translate table headers generated by psql
const originalUpdateUI = updateUI;
updateUI = function() {
  originalUpdateUI();
  document.querySelectorAll("th").forEach(th => {
    const text = th.innerText.trim();
    if (translations[currentLang][text]) {
      th.innerHTML = translations[currentLang][text];
    }
  });
};
</script>

<div class="timestamp"><span data-i18n="timestamp_prefix">G&eacute;n&eacute;r&eacute; le: </span> <script>document.write(new Date().toLocaleString())</script></div>
</body>
</html>
$HTML$;

