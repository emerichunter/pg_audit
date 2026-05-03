$c = Get-Content pg_perf_report.sql
$c[88] = '    <button class="theme-switch" onclick="toggleQueries()" id="query-toggle-btn"><span id="query-toggle-text">SHORT / LONG</span></button>' + "`r`n" + $c[88]
$c | Set-Content pg_perf_report.sql
