#Requires -Version 5.1
<#
.SYNOPSIS
  ZK Replay - runs pg_audit reports against an offline ZK bundle

.DESCRIPTION
  Loads catalog_snapshot.json + stat_snapshot.json from a bundle directory
  into a local PostgreSQL instance, builds the shadow 'zk' schema via
  zk_ingest.sql, then runs ultimate_report.sql and pg_perf_report.sql
  with search_path = zk so all queries resolve against the captured data.

  Outputs:
    offline_ultimate_report.html   - full audit report
    offline_perf_report.html       - performance deep-dive

.PARAMETER Bundle
  Path to the bundle directory (contains catalog_snapshot.json, stat_snapshot.json)

.PARAMETER PgHost
  PostgreSQL host to use as replay target (default: localhost)
.PARAMETER Port
  PostgreSQL port (default: 5432)
.PARAMETER Database
  Database to use for replay staging (default: postgres)
.PARAMETER User
  PostgreSQL user (default: postgres)
.PARAMETER Password
  PostgreSQL password (or set PGPASSWORD env var)
.PARAMETER DockerContainer
  If set, run psql inside this Docker container
.PARAMETER OutputDir
  Directory to write HTML reports (default: same as Bundle)

.EXAMPLE
  .\zk_replay.ps1 -Bundle .\zk_audit_20260508_120000

.EXAMPLE
  .\zk_replay.ps1 -Bundle .\zk_audit_20260508_120000 -DockerContainer pg-test-report -OutputDir .\reports
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bundle,
    [string]$PgHost    = "localhost",
    [int]   $Port      = 5432,
    [string]$Database  = "postgres",
    [string]$User      = "postgres",
    [string]$Password  = "",
    [string]$DockerContainer = "",
    [string]$OutputDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step { param([string]$msg); Write-Host ('  ' + $msg) -ForegroundColor Cyan }
function Write-Ok   { param([string]$msg); Write-Host ('  OK  ' + $msg) -ForegroundColor Green }
function Write-Warn { param([string]$msg); Write-Host ('  WARN  ' + $msg) -ForegroundColor Yellow }
function Write-Err  { param([string]$msg); Write-Host ('  ERR  ' + $msg) -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Validate bundle
# ---------------------------------------------------------------------------

$Bundle      = (Resolve-Path $Bundle).ProviderPath
$catalogFile = Join-Path $Bundle 'catalog_snapshot.json'
$statFile    = Join-Path $Bundle 'stat_snapshot.json'

if (-not (Test-Path $catalogFile)) { Write-Err ('catalog_snapshot.json not found in: ' + $Bundle) }
if (-not (Test-Path $statFile))    { Write-Err ('stat_snapshot.json not found in: '    + $Bundle) }

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ingestSql   = Join-Path $scriptDir 'zk_ingest.sql'
$ultimateSql = Join-Path $scriptDir 'ultimate_report.sql'
$perfSql     = Join-Path $scriptDir 'pg_perf_report.sql'

foreach ($f in @($ingestSql, $ultimateSql, $perfSql)) {
    if (-not (Test-Path $f)) { Write-Err ('Required file not found: ' + $f) }
}

if (-not $OutputDir) { $OutputDir = $Bundle }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = (Resolve-Path $OutputDir).ProviderPath

# ---------------------------------------------------------------------------
# Password setup
# ---------------------------------------------------------------------------

$origPgPassword = $env:PGPASSWORD
if ($Password) { $env:PGPASSWORD = $Password }

# ---------------------------------------------------------------------------
# psql runner
# ---------------------------------------------------------------------------

function Invoke-Psql {
    param(
        [string]$SqlFile,
        [string]$OutFile = ''
    )

    $absScript = (Resolve-Path $SqlFile).ProviderPath

    if ($DockerContainer) {
        $leaf   = Split-Path -Leaf $SqlFile
        $tmpIn  = '/tmp/zk_replay_' + $leaf
        docker cp $absScript ($DockerContainer + ':' + $tmpIn) | Out-Null

        if ($OutFile) {
            $tmpOut = '/tmp/zk_replay_out_' + [System.IO.Path]::GetRandomFileName() + '.html'
            docker exec $DockerContainer sh -c ("psql -U '" + $User + "' -d '" + $Database + "' -q -f '" + $tmpIn + "' -o '" + $tmpOut + "' 2>&1")
            docker cp ($DockerContainer + ':' + $tmpOut) $OutFile | Out-Null
            docker exec $DockerContainer rm -f $tmpOut | Out-Null
        } else {
            docker exec $DockerContainer sh -c ("psql -U '" + $User + "' -d '" + $Database + "' -q -f '" + $tmpIn + "' 2>&1")
        }
        docker exec $DockerContainer rm -f $tmpIn | Out-Null
    } else {
        $connArgs = @('-h', $PgHost, '-p', $Port.ToString(), '-U', $User, '-d', $Database, '-q')
        if ($OutFile) {
            & psql @connArgs -f $absScript -o $OutFile 2>&1
        } else {
            & psql @connArgs -f $absScript 2>&1
        }
    }
}

# ---------------------------------------------------------------------------
# Step 1: Load JSON into staging tables
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  ZK Replay v1.0' -ForegroundColor White
Write-Host ('  Bundle: ' + $Bundle) -ForegroundColor DarkGray
Write-Host ('  Output: ' + $OutputDir) -ForegroundColor DarkGray
Write-Host ''

Write-Step 'Loading JSON bundle into staging tables...'

$catalogJson = Get-Content $catalogFile -Raw -Encoding UTF8
$statJson    = Get-Content $statFile    -Raw -Encoding UTF8

# Build dollar-quote tag from parts to avoid $ in PS string literals
$dqTag = '$' + 'zk' + '$'

# Safety check: JSON must not contain the dollar-quote tag
if ($catalogJson.Contains($dqTag) -or $statJson.Contains($dqTag)) {
    Write-Err ('JSON content contains dollar-quote tag ' + $dqTag + ' - cannot safely embed')
}

# Build load SQL via StringBuilder - no PS string interpolation of $ chars
$NL = [System.Environment]::NewLine
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('-- ZK Replay: staging table setup')
[void]$sb.AppendLine('SET client_min_messages = WARNING;')
[void]$sb.AppendLine('DROP TABLE IF EXISTS _zk_catalog CASCADE;')
[void]$sb.AppendLine('DROP TABLE IF EXISTS _zk_stat CASCADE;')
[void]$sb.AppendLine('CREATE UNLOGGED TABLE _zk_catalog (data jsonb);')
[void]$sb.AppendLine('CREATE UNLOGGED TABLE _zk_stat    (data jsonb);')
[void]$sb.AppendLine('INSERT INTO _zk_catalog (data) VALUES (' + $dqTag)
[void]$sb.AppendLine($catalogJson)
[void]$sb.AppendLine($dqTag + '::jsonb);')
[void]$sb.AppendLine('INSERT INTO _zk_stat (data) VALUES (' + $dqTag)
[void]$sb.AppendLine($statJson)
[void]$sb.AppendLine($dqTag + '::jsonb);')

$tmpLoadSql = [System.IO.Path]::GetTempFileName() + '.sql'
[System.IO.File]::WriteAllText($tmpLoadSql, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))

try {
    Invoke-Psql -SqlFile $tmpLoadSql
    Write-Ok 'Staging tables created'
} catch {
    Write-Err ('Failed to load JSON into staging tables: ' + $_)
} finally {
    Remove-Item $tmpLoadSql -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Step 2: Run zk_ingest.sql to build shadow schema
# ---------------------------------------------------------------------------

Write-Step 'Building shadow zk schema (zk_ingest.sql)...'

try {
    Invoke-Psql -SqlFile $ingestSql
    Write-Ok 'Shadow schema ready'
} catch {
    Write-Err ('zk_ingest.sql failed: ' + $_)
}

# ---------------------------------------------------------------------------
# Helper: wrap a report SQL with search_path override and run it
# ---------------------------------------------------------------------------

function Invoke-Report {
    param([string]$ReportSql, [string]$OutHtml, [string]$Label)

    Write-Step ('Generating ' + $Label + '...')

    $tmpWrapper = [System.IO.Path]::GetTempFileName() + '.sql'

    # Inline the report SQL into the wrapper so \i is not needed (avoids path-with-spaces issues in Docker)
    $reportContent = Get-Content $ReportSql -Raw -Encoding UTF8
    $wrapContent = 'SET search_path = zk, pg_catalog, public;' + [System.Environment]::NewLine
    $wrapContent += $reportContent
    [System.IO.File]::WriteAllText($tmpWrapper, $wrapContent, (New-Object System.Text.UTF8Encoding $false))

    try {
        Invoke-Psql -SqlFile $tmpWrapper -OutFile $OutHtml
        $sizeKb = [math]::Round((Get-Item $OutHtml).Length / 1KB, 1)
        Write-Ok ($Label + '  (' + $sizeKb + ' KB)  ->  ' + $OutHtml)
    } catch {
        Write-Warn ($Label + ' failed: ' + $_)
    } finally {
        Remove-Item $tmpWrapper -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Step 3: Generate reports
# ---------------------------------------------------------------------------

$ultimateOut = Join-Path $OutputDir 'offline_ultimate_report.html'
$perfOut     = Join-Path $OutputDir 'offline_perf_report.html'

Invoke-Report -ReportSql $ultimateSql -OutHtml $ultimateOut -Label 'ultimate_report'
Invoke-Report -ReportSql $perfSql     -OutHtml $perfOut     -Label 'pg_perf_report'

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

if ($Password -or $origPgPassword) {
    $env:PGPASSWORD = if ($origPgPassword) { $origPgPassword } else { '' }
}

Write-Host ''
Write-Host '  Replay complete.' -ForegroundColor White
Write-Host ''
Get-ChildItem $OutputDir -Filter 'offline_*.html' | ForEach-Object {
    $kb = [math]::Round($_.Length / 1KB, 1)
    Write-Host ('    ' + ('{0,-40}' -f $_.Name) + ('  {0,8} KB' -f $kb)) -ForegroundColor DarkGray
}
Write-Host ''
