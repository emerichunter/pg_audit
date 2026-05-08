#!/usr/bin/env bash
# =============================================================================
#  System Health Report Generator v1.0
#  Reads a sys_collect bundle and produces a self-contained HTML report.
#
#  Usage:
#    ./sys_report.sh --bundle DIR [--output FILE]
#
#  Options:
#    --bundle DIR     Path to sys_collect output directory (REQUIRED)
#    --output FILE    Output HTML file (default: DIR/sys_report.html)
#    -h, --help       Show this help
# =============================================================================

set -uo pipefail

BUNDLE=""
OUTPUT_FILE=""

_err()  { printf "  \033[31mERR  %s\033[0m\n" "$*" >&2; exit 1; }
_step() { printf "  \033[36m%s\033[0m\n" "$*"; }
_ok()   { printf "  \033[32mOK  %s\033[0m\n" "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)  BUNDLE="$2";      shift 2 ;;
    --output)  OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help) grep '^#  ' "$0" | sed 's/^#  //'; exit 0 ;;
    *) _err "Unknown argument: $1" ;;
  esac
done

[[ -z "$BUNDLE" ]] && _err "--bundle is required"
[[ -d "$BUNDLE" ]] || _err "Bundle directory not found: $BUNDLE"
BUNDLE="$(cd "$BUNDLE" && pwd)"
[[ -z "$OUTPUT_FILE" ]] && OUTPUT_FILE="${BUNDLE}/sys_report.html"

# ---------------------------------------------------------------------------
# Helper: read a bundle file safely
# ---------------------------------------------------------------------------
_read() { cat "${BUNDLE}/${1}" 2>/dev/null || echo ""; }

# ---------------------------------------------------------------------------
# Helpers: parse common values
# ---------------------------------------------------------------------------
_extract() { grep -oP "(?<=${1})[^\n]+" "${BUNDLE}/${2}" 2>/dev/null | head -1 | xargs || echo "N/A"; }

_meminfo_kb() {
  grep -i "^${1}:" "${BUNDLE}/04_meminfo.txt" 2>/dev/null \
    | awk '{print $2}' | head -1 || echo "0"
}

_sysctl_val() {
  grep -E "^${1}\s*=" "${BUNDLE}/09_sysctl.txt" 2>/dev/null \
    | awk -F'=' '{gsub(/ /,"",$2); print $2}' | head -1 || echo "N/A"
}

# Human-readable bytes (awk-only, no bc dependency)
_human() {
  local kb="${1:-0}"
  awk -v kb="$kb" 'BEGIN{
    if      (kb>=1048576) printf "%.1f GB", kb/1048576
    else if (kb>=1024)    printf "%.1f MB", kb/1024
    else                  printf "%d KB",   kb
  }'
}

# Badge helper
_badge() {
  # _badge LEVEL TEXT
  local lvl="$1" txt="$2"
  case "$lvl" in
    red)    echo "<span class=\"badge b-red\">$txt</span>"    ;;
    orange) echo "<span class=\"badge b-orange\">$txt</span>" ;;
    green)  echo "<span class=\"badge b-green\">$txt</span>"  ;;
    blue)   echo "<span class=\"badge b-blue\">$txt</span>"   ;;
    gray)   echo "<span class=\"badge b-gray\">$txt</span>"   ;;
  esac
}

# ---------------------------------------------------------------------------
# Parse meta
# ---------------------------------------------------------------------------
_step "Parsing metadata..."

META_FILE="${BUNDLE}/00_meta.txt"
HOSTNAME="$(grep '^hostname:' "$META_FILE" 2>/dev/null | cut -d' ' -f2- | xargs || echo "unknown")"
UNAME="$(grep '^uname:' "$META_FILE" 2>/dev/null | cut -d' ' -f2- | xargs || echo "N/A")"
KERNEL="$(echo "$UNAME" | awk '{print $3}' | head -1)"
UPTIME_RAW="$(grep '^uptime:' "$META_FILE" 2>/dev/null | cut -d' ' -f2- | xargs || echo "N/A")"
DATE_UTC="$(grep '^date_utc:' "$META_FILE" 2>/dev/null | cut -d' ' -f2- | xargs || echo "N/A")"
VIRT="$(grep '^virtualization:' "$META_FILE" 2>/dev/null | cut -d' ' -f2- | xargs || echo "bare-metal/unknown")"
OS_PRETTY="$(grep 'PRETTY_NAME' "${BUNDLE}/00_meta.txt" 2>/dev/null | cut -d'"' -f2 | head -1)"
if [[ -z "$OS_PRETTY" ]]; then
  OS_PRETTY="$(grep 'NAME=' "${BUNDLE}/00_meta.txt" 2>/dev/null | grep -v PRETTY | cut -d'=' -f2- | tr -d '"' | head -1)"
fi
if [[ -z "$OS_PRETTY" ]]; then OS_PRETTY="Linux"; fi

# From manifest if available
if [[ -f "${BUNDLE}/manifest.json" ]]; then
  COLL_AT="$(grep '"collected_at"' "${BUNDLE}/manifest.json" | grep -oP '(?<=")[0-9T:Z-]+' | head -1)"
  TARGET="$(grep '"target"' "${BUNDLE}/manifest.json" | cut -d'"' -f4)"
else
  COLL_AT="$DATE_UTC"
  TARGET="$HOSTNAME"
fi

# ---------------------------------------------------------------------------
# Parse CPU
# ---------------------------------------------------------------------------
CPU_MODEL="$(grep -iE '^Model name|^model name' "${BUNDLE}/01_cpu_lscpu.txt" 2>/dev/null \
  | head -1 | sed 's/.*: *//' | xargs || echo "N/A")"
CPU_CORES="$(grep -iE '^CPU\(s\):|^cpus:' "${BUNDLE}/01_cpu_lscpu.txt" 2>/dev/null \
  | head -1 | awk '{print $NF}' || echo "?")"
CPU_PHYS="$(grep -iE '^Socket|socket' "${BUNDLE}/01_cpu_lscpu.txt" 2>/dev/null \
  | head -1 | awk '{print $NF}' || echo "?")"
CPU_NUMA="$(grep -iE '^NUMA node' "${BUNDLE}/01_cpu_lscpu.txt" 2>/dev/null \
  | head -1 | awk '{print $NF}' || echo "?")"

LOAD_LINE="$(cat "${BUNDLE}/03_loadavg.txt" 2>/dev/null | head -1)"
LOAD_1="$(echo "$LOAD_LINE" | awk '{print $1}')"
LOAD_5="$(echo "$LOAD_LINE" | awk '{print $2}')"
LOAD_15="$(echo "$LOAD_LINE" | awk '{print $3}')"
LOAD_CPUS="$(grep 'cpus:' "${BUNDLE}/03_loadavg.txt" 2>/dev/null | awk '{print $2}' || echo "1")"
if [[ -z "$LOAD_CPUS" || "$LOAD_CPUS" == "N/A" ]]; then LOAD_CPUS=1; fi

# vmstat: get average idle and iowait from samples (skip header lines)
VMSTAT_IDLE="$(awk 'NR>3 && NF>0 {idle+=$15; n++} END{if(n>0) printf "%.0f", idle/n; else print "N/A"}' \
  "${BUNDLE}/02_cpu_vmstat.txt" 2>/dev/null || echo "N/A")"
VMSTAT_IOWAIT="$(awk 'NR>3 && NF>0 {wa+=$16; n++} END{if(n>0) printf "%.0f", wa/n; else print "N/A"}' \
  "${BUNDLE}/02_cpu_vmstat.txt" 2>/dev/null || echo "N/A")"

# ---------------------------------------------------------------------------
# Parse Memory
# ---------------------------------------------------------------------------
_kb()  { local v; v="$(_meminfo_kb "$1")"; printf '%s' "${v//[^0-9]/}"; }
MEM_TOTAL_KB="$(_kb MemTotal)"
MEM_FREE_KB="$(_kb MemFree)"
MEM_AVAIL_KB="$(_kb MemAvailable)"
MEM_CACHED_KB="$(_kb Cached)"
SWAP_TOTAL_KB="$(_kb SwapTotal)"
SWAP_FREE_KB="$(_kb SwapFree)"
SWAP_USED_KB=$(( ${SWAP_TOTAL_KB:-0} - ${SWAP_FREE_KB:-0} ))
MEM_USED_KB=$(( ${MEM_TOTAL_KB:-0} - ${MEM_AVAIL_KB:-0} ))
MEM_PCT=0
if [[ "$MEM_TOTAL_KB" -gt 0 ]]; then MEM_PCT=$(( MEM_USED_KB * 100 / MEM_TOTAL_KB )); fi

HP_TOTAL="$(_meminfo_kb HugePages_Total)"
HP_FREE="$(_meminfo_kb HugePages_Free)"
HP_SIZE_KB="$(_meminfo_kb Hugepagesize)"
THP_STATUS="$(grep -oE '\[.*\]' "${BUNDLE}/05_hugepages.txt" 2>/dev/null | head -1 | tr -d '[]' || echo "unknown")"

SWAPPINESS="$(_sysctl_val vm.swappiness)"
DIRTY_RATIO="$(_sysctl_val vm.dirty_ratio)"
DIRTY_BG="$(_sysctl_val vm.dirty_background_ratio)"
OVERCOMMIT="$(_sysctl_val vm.overcommit_memory)"

# ---------------------------------------------------------------------------
# Parse Disk
# ---------------------------------------------------------------------------
# Extract filesystem rows from df -h, skip tmpfs/devtmpfs
DF_ROWS="$(awk 'NR>1 && !/tmpfs|devtmpfs|udev|overlay|shm/' \
  "${BUNDLE}/06_df.txt" 2>/dev/null || echo "")"

# ---------------------------------------------------------------------------
# Parse I/O (iostat)
# ---------------------------------------------------------------------------
# Average await from iostat -x (column 10 in older iostat, varies)
IOSTAT_HIGH="$(awk '/Device/{hdr=1;next} hdr && NF>5 {
  if ($NF+0 > 10) print $1, "util="$NF"% await=" $(NF-1)
}' "${BUNDLE}/07_iostat.txt" 2>/dev/null | head -5 || echo "")"

# ---------------------------------------------------------------------------
# Parse Network
# ---------------------------------------------------------------------------
NET_ROWS="$(awk '/^\s+[a-z]/ && !/lo:/' "${BUNDLE}/10_net_ifaces.txt" 2>/dev/null | head -20 || echo "")"

NET_ERRORS="$(grep -oE 'errors [0-9]+' "${BUNDLE}/10_net_ifaces.txt" 2>/dev/null \
  | awk '{s+=$2} END{print s+0}' | tr -d '\n\r' || echo "0")"
NET_DROPS="$(grep -oE 'dropped [0-9]+' "${BUNDLE}/10_net_ifaces.txt" 2>/dev/null \
  | awk '{s+=$2} END{print s+0}' | tr -d '\n\r' || echo "0")"
NET_ERRORS="${NET_ERRORS:-0}"; NET_ERRORS="${NET_ERRORS//[^0-9]/}"
NET_DROPS="${NET_DROPS:-0}";   NET_DROPS="${NET_DROPS//[^0-9]/}"
: "${NET_ERRORS:=0}"; : "${NET_DROPS:=0}"

# Listening ports
PORTS_TABLE="$(awk 'NR>1 && /LISTEN/' "${BUNDLE}/12_sockets.txt" 2>/dev/null | head -30 || echo "")"

# ---------------------------------------------------------------------------
# Sysctl risk checks
# ---------------------------------------------------------------------------
SOMAXCONN="$(_sysctl_val net.core.somaxconn)"
FILEMAX="$(_sysctl_val fs.file-max)"
NR_HUGEPAGES="$(_sysctl_val vm.nr_hugepages)"

# ---------------------------------------------------------------------------
# Build findings list
# ---------------------------------------------------------------------------
declare -a FINDINGS_HTML=()

_finding() {
  local level="$1" category="$2" detail="$3"
  FINDINGS_HTML+=("<tr><td>$(_badge "$level" "$category")</td><td>${detail}</td></tr>")
}

# Load average vs CPUs
if [[ "$LOAD_1" != "N/A" && "$LOAD_CPUS" -gt 0 ]]; then
  LOAD_RATIO_PCT=$(awk "BEGIN{printf \"%.0f\", ($LOAD_1 / $LOAD_CPUS) * 100}" 2>/dev/null || echo "0")
  if   (( LOAD_RATIO_PCT >= 100 )); then _finding "red"    "LOAD HIGH"    "1-min load avg ${LOAD_1} ≥ CPU count (${LOAD_CPUS}) — system saturated"
  elif (( LOAD_RATIO_PCT >= 70  )); then _finding "orange" "LOAD WARN"    "1-min load avg ${LOAD_1}, ${LOAD_RATIO_PCT}% of CPU count (${LOAD_CPUS})"
  else                                   _finding "green"  "LOAD OK"      "1-min load avg ${LOAD_1} / ${LOAD_CPUS} CPUs (${LOAD_RATIO_PCT}%)"
  fi
fi

# I/O wait
if [[ "$VMSTAT_IOWAIT" != "N/A" && "$VMSTAT_IOWAIT" =~ ^[0-9]+$ ]]; then
  if   (( VMSTAT_IOWAIT >= 20 )); then _finding "red"    "IOWAIT HIGH"  "avg iowait ${VMSTAT_IOWAIT}% — I/O bottleneck likely"
  elif (( VMSTAT_IOWAIT >= 10 )); then _finding "orange" "IOWAIT WARN"  "avg iowait ${VMSTAT_IOWAIT}% — watch disk latency"
  else                                 _finding "green"  "IOWAIT OK"    "avg iowait ${VMSTAT_IOWAIT}%"
  fi
fi

# Memory usage
if (( MEM_TOTAL_KB > 0 )); then
  if   (( MEM_PCT >= 95 )); then _finding "red"    "MEM CRITICAL" "$(_human $MEM_USED_KB) used / $(_human $MEM_TOTAL_KB) total (${MEM_PCT}%)"
  elif (( MEM_PCT >= 80 )); then _finding "orange" "MEM WARN"     "$(_human $MEM_USED_KB) used / $(_human $MEM_TOTAL_KB) total (${MEM_PCT}%)"
  else                           _finding "green"  "MEM OK"       "$(_human $MEM_USED_KB) used / $(_human $MEM_TOTAL_KB) total (${MEM_PCT}%)"
  fi
fi

# Swap usage
if (( SWAP_TOTAL_KB > 0 && SWAP_USED_KB > 0 )); then
  _finding "orange" "SWAP ACTIVE" "Swap used: $(_human $SWAP_USED_KB) — investigate memory pressure"
elif (( SWAP_TOTAL_KB == 0 )); then
  _finding "orange" "NO SWAP"     "No swap configured — OOM risk if memory exhausted"
fi

# Swappiness for PostgreSQL
if [[ "$SWAPPINESS" =~ ^[0-9]+$ ]]; then
  if   (( SWAPPINESS > 10 )); then _finding "orange" "SWAPPINESS"    "vm.swappiness=${SWAPPINESS} — PostgreSQL recommends 1–10"
  elif (( SWAPPINESS == 0 )); then _finding "blue"   "SWAPPINESS"    "vm.swappiness=0 — may cause OOM kill instead of swap; prefer 1"
  else                             _finding "green"  "SWAPPINESS OK" "vm.swappiness=${SWAPPINESS}"
  fi
fi

# Transparent Huge Pages
if [[ "$THP_STATUS" == "always" ]]; then
  _finding "orange" "THP ALWAYS"   "transparent_hugepage=always — can cause PostgreSQL latency spikes; set to madvise or never"
elif [[ "$THP_STATUS" == "madvise" ]]; then
  _finding "green"  "THP MADVISE"  "transparent_hugepage=madvise (acceptable)"
elif [[ "$THP_STATUS" == "never" ]]; then
  _finding "green"  "THP NEVER"    "transparent_hugepage=never (recommended for databases)"
fi

# Huge pages not configured
if [[ "$HP_TOTAL" == "0" || "$HP_TOTAL" == "N/A" ]]; then
  _finding "blue"   "HUGEPAGES"    "HugePages_Total=0 — configuring huge pages reduces TLB pressure for large shared_buffers"
fi

# dirty_ratio
if [[ "$DIRTY_RATIO" =~ ^[0-9]+$ ]]; then
  if (( DIRTY_RATIO > 40 )); then
    _finding "orange" "DIRTY_RATIO" "vm.dirty_ratio=${DIRTY_RATIO} — high; can cause long I/O bursts (PostgreSQL: prefer 10–20)"
  else
    _finding "green"  "DIRTY_RATIO OK" "vm.dirty_ratio=${DIRTY_RATIO}"
  fi
fi

# overcommit
if [[ "$OVERCOMMIT" == "1" ]]; then
  _finding "orange" "OVERCOMMIT"   "vm.overcommit_memory=1 (always overcommit) — OOM kill risk"
elif [[ "$OVERCOMMIT" == "0" ]]; then
  _finding "green"  "OVERCOMMIT OK" "vm.overcommit_memory=0 (heuristic)"
fi

# somaxconn
if [[ "$SOMAXCONN" =~ ^[0-9]+$ && "$SOMAXCONN" -lt 4096 ]]; then
  _finding "blue"   "SOMAXCONN"    "net.core.somaxconn=${SOMAXCONN} — consider 4096+ for busy PostgreSQL instances"
fi

# net errors/drops
if (( ${NET_ERRORS:-0} > 0 || ${NET_DROPS:-0} > 0 )); then
  _finding "orange" "NET ERRORS"   "Network errors=${NET_ERRORS}, drops=${NET_DROPS} — check NIC or switch"
fi

# Disk usage from df
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  PCT_RAW="$(echo "$line" | awk '{print $5}' | tr -d '%')"
  MOUNT="$(echo "$line" | awk '{print $6}')"
  if [[ "$PCT_RAW" =~ ^[0-9]+$ ]]; then
    if   (( PCT_RAW >= 90 )); then _finding "red"    "DISK FULL"    "${MOUNT} at ${PCT_RAW}% — critical, immediate action needed"
    elif (( PCT_RAW >= 80 )); then _finding "orange" "DISK WARN"    "${MOUNT} at ${PCT_RAW}% — plan cleanup or expansion"
    fi
  fi
done <<< "$DF_ROWS"

_ok "Findings computed: ${#FINDINGS_HTML[@]} items"

# ---------------------------------------------------------------------------
# Noatime check on mounts
# ---------------------------------------------------------------------------
MOUNT_ISSUES=""
while IFS= read -r line; do
  [[ -z "$line" || "$line" == "#"* ]] && continue
  if echo "$line" | grep -qv "noatime\|relatime"; then
    MNT="$(echo "$line" | awk '{print $1}')"
    FSTYPE="$(echo "$line" | awk '{print $3}')"
    if echo "$FSTYPE" | grep -qE '^ext|^xfs|^btrfs'; then
      MOUNT_ISSUES+="<tr><td class=\"code\">${MNT}</td><td>Missing noatime/relatime — adds write overhead</td></tr>"
    fi
  fi
done < <(grep -v '==\|^#' "${BUNDLE}/08_mounts.txt" 2>/dev/null | head -30 || true)

# ---------------------------------------------------------------------------
# Emit HTML
# ---------------------------------------------------------------------------
_step "Generating HTML report..."

# Escape function for raw text blocks
_esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# Pre-escape raw data blocks
DF_HTML="$( echo "$DF_ROWS" | _esc)"
VMSTAT_HTML="$(tail -n +2 "${BUNDLE}/02_cpu_vmstat.txt" 2>/dev/null | head -20 | _esc || echo "")"
IOSTAT_HTML="$(grep -A200 'iostat' "${BUNDLE}/07_iostat.txt" 2>/dev/null | head -40 | _esc || echo "")"
PORTS_HTML="$(echo "$PORTS_TABLE" | _esc)"
SYSCTL_HTML="$(grep -E '^(vm\.|net\.core\.|net\.ipv4\.tcp|fs\.file|kernel\.shm|kernel\.sem)' \
  "${BUNDLE}/09_sysctl.txt" 2>/dev/null | head -40 | _esc || echo "")"
PROC_CPU_HTML="$(awk 'NR<=22' "${BUNDLE}/13_processes.txt" 2>/dev/null | head -22 | _esc || echo "")"
PROC_MEM_HTML="$(awk '/Top 20 by RSS/,0' "${BUNDLE}/13_processes.txt" 2>/dev/null | head -25 | _esc || echo "")"
LSBLK_HTML="$(cat "${BUNDLE}/06_lsblk.txt" 2>/dev/null | _esc || echo "")"
DMESG_HTML="$(cat "${BUNDLE}/17_dmesg.txt" 2>/dev/null | head -60 | _esc || echo "")"
DOCKER_HTML="$(cat "${BUNDLE}/16_docker.txt" 2>/dev/null | _esc || echo "")"
NET_HTML="$(grep -A3 '/proc/net/dev' "${BUNDLE}/10_net_ifaces.txt" 2>/dev/null | \
  awk 'NF>0 && !/proc/' | head -20 | _esc || echo "")"
SERVICES_HTML="$(head -40 "${BUNDLE}/14_services.txt" 2>/dev/null | _esc || echo "")"
SECURITY_HTML="$(head -60 "${BUNDLE}/15_security.txt" 2>/dev/null | _esc || echo "")"

FINDINGS_BLOCK=""
for row in "${FINDINGS_HTML[@]:-}"; do
  FINDINGS_BLOCK+="$row"$'\n'
done

# ─── HTML ──────────────────────────────────────────────────────────────────
cat > "$OUTPUT_FILE" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>System Health Report — ${HOSTNAME}</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap');
:root{--bg:#0f172a;--card-bg:#1e293b;--primary:#38bdf8;--secondary:#64748b;
--text:#f8fafc;--text-muted:#94a3b8;--border:#334155;
--danger:#ef4444;--warning:#f59e0b;--info:#0ea5e9;--success:#10b981;}
body.light-mode{--bg:#f8fafc;--card-bg:#ffffff;--primary:#2563eb;--secondary:#475569;
--text:#1e293b;--text-muted:#64748b;--border:#e2e8f0;}
body{font-family:'Inter',sans-serif;background:var(--bg);color:var(--text);margin:0;padding:40px;line-height:1.6;transition:background .3s;}
.container{max-width:1400px;margin:0 auto;}
header{display:flex;justify-content:space-between;align-items:center;margin-bottom:50px;}
h1{background:linear-gradient(135deg,#38bdf8,#a78bfa);-webkit-background-clip:text;-webkit-text-fill-color:transparent;margin:0;font-weight:800;font-size:2.5rem;}
.meta{color:var(--text-muted);font-size:.9rem;margin-top:8px;font-weight:500;display:flex;align-items:center;gap:15px;}
.badge{padding:4px 10px;border-radius:6px;font-size:.7rem;font-weight:700;text-transform:uppercase;white-space:nowrap;}
.b-red{background:rgba(239,68,68,.1);color:#fca5a5;border:1px solid rgba(239,68,68,.2);}
.b-orange{background:rgba(245,158,11,.1);color:#fcd34d;border:1px solid rgba(245,158,11,.2);}
.b-green{background:rgba(16,185,129,.1);color:#6ee7b7;border:1px solid rgba(16,185,129,.2);}
.b-blue{background:rgba(14,165,233,.1);color:#7dd3fc;border:1px solid rgba(14,165,233,.2);}
.b-gray{background:rgba(148,163,184,.1);color:#cbd5e1;border:1px solid rgba(148,163,184,.2);}
.theme-switch{background:var(--card-bg);border:1px solid var(--border);padding:8px 16px;border-radius:50px;cursor:pointer;display:flex;align-items:center;gap:8px;font-weight:600;font-size:.85rem;color:var(--text);}
.theme-switch:hover{border-color:var(--primary);}
.nav-bar{background:var(--card-bg);padding:15px;border-radius:12px;border:1px solid var(--border);margin-bottom:40px;display:flex;justify-content:center;gap:10px;flex-wrap:wrap;position:sticky;top:20px;z-index:100;box-shadow:0 10px 30px -10px rgba(0,0,0,.5);}
.nav-bar a{text-decoration:none;color:var(--text);font-weight:600;font-size:.85rem;padding:8px 16px;border-radius:8px;transition:all .2s;display:flex;align-items:center;gap:8px;}
.nav-bar a:hover{background:var(--primary);color:#fff;}
.card{background:var(--card-bg);border-radius:16px;border:1px solid var(--border);margin-bottom:40px;overflow:hidden;box-shadow:0 10px 30px -10px rgba(0,0,0,.5);}
.card-header{background:rgba(255,255,255,.02);padding:15px 25px;font-size:1.1rem;font-weight:700;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:10px;}
table{width:100%;border-spacing:0;}
th{color:var(--text-muted);font-size:.75rem;text-transform:uppercase;padding:12px 25px;text-align:left;border-bottom:1px solid var(--border);}
td{padding:12px 25px;border-bottom:1px solid var(--border);font-size:.9rem;vertical-align:top;}
tr:last-child td{border-bottom:none;}
.code{font-family:'JetBrains Mono',monospace;color:var(--primary);font-size:.85rem;}
.pre-block{font-family:'JetBrains Mono',monospace;font-size:.78rem;background:rgba(0,0,0,.3);padding:16px 20px;margin:0;overflow-x:auto;white-space:pre;color:#94a3b8;line-height:1.5;}
body.light-mode .pre-block{background:#f1f5f9;color:#475569;}
.stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;padding:20px;}
.stat-card{background:rgba(255,255,255,.03);border:1px solid var(--border);border-radius:10px;padding:16px;}
.stat-label{font-size:.75rem;color:var(--text-muted);text-transform:uppercase;font-weight:600;margin-bottom:4px;}
.stat-value{font-size:1.4rem;font-weight:700;color:var(--primary);}
.stat-sub{font-size:.8rem;color:var(--text-muted);margin-top:2px;}
#backToTop{position:fixed;bottom:30px;right:30px;width:45px;height:45px;background:var(--primary);color:#fff;border:none;border-radius:50%;cursor:pointer;display:none;align-items:center;justify-content:center;z-index:1000;box-shadow:0 4px 15px rgba(0,0,0,.3);}
.severity-bar{height:6px;border-radius:3px;background:var(--border);overflow:hidden;margin-top:6px;}
.severity-fill{height:100%;border-radius:3px;}
</style>
</head>
<body>
<div class="container">
<header>
  <div>
    <h1>🖥️ System Health Report</h1>
    <div class="meta">
      <span><strong>${HOSTNAME}</strong></span>
      <span>${OS_PRETTY}</span>
      <span class="badge b-gray">Kernel ${KERNEL}</span>
      <span>${VIRT}</span>
    </div>
    <div class="meta" style="margin-top:4px">
      <span>Collected: ${COLL_AT}</span>
      <span>Uptime: ${UPTIME_RAW}</span>
    </div>
  </div>
  <button class="theme-switch" onclick="document.body.classList.toggle('light-mode')">☀ / 🌙</button>
</header>

<div class="nav-bar">
  <a href="#findings">⚠ Findings</a>
  <a href="#overview">📊 Overview</a>
  <a href="#cpu">⚡ CPU</a>
  <a href="#memory">🧠 Memory</a>
  <a href="#disk">💾 Disk</a>
  <a href="#network">🌐 Network</a>
  <a href="#kernel">⚙ Kernel</a>
  <a href="#processes">🔧 Processes</a>
  <a href="#security">🔒 Security</a>
</div>

<!-- ═══════════════════ FINDINGS ═══════════════════ -->
<div class="card" id="findings">
  <div class="card-header">⚠ Findings &amp; Recommendations</div>
  <table>
    <tr><th>Level</th><th>Detail</th></tr>
    ${FINDINGS_BLOCK:-<tr><td colspan="2" style="text-align:center;color:var(--text-muted)">No findings — all checks passed</td></tr>}
  </table>
</div>

<!-- ═══════════════════ OVERVIEW ═══════════════════ -->
<div class="card" id="overview">
  <div class="card-header">📊 Overview</div>
  <div class="stat-grid">
    <div class="stat-card">
      <div class="stat-label">CPU Cores</div>
      <div class="stat-value">${CPU_CORES}</div>
      <div class="stat-sub">${CPU_MODEL}</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Load Avg (1/5/15m)</div>
      <div class="stat-value">${LOAD_1}</div>
      <div class="stat-sub">${LOAD_5} / ${LOAD_15} — ${LOAD_CPUS} CPUs</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Memory</div>
      <div class="stat-value">$(_human $MEM_TOTAL_KB)</div>
      <div class="stat-sub">$(_human $MEM_USED_KB) used (${MEM_PCT}%)</div>
      <div class="severity-bar"><div class="severity-fill" style="width:${MEM_PCT}%;background:$(
        if (( MEM_PCT >= 90 )); then echo '#ef4444'
        elif (( MEM_PCT >= 75 )); then echo '#f59e0b'
        else echo '#10b981'; fi
      )"></div></div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Swap</div>
      <div class="stat-value">$(_human $SWAP_TOTAL_KB)</div>
      <div class="stat-sub">$(_human $SWAP_USED_KB) used</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">I/O Wait</div>
      <div class="stat-value">${VMSTAT_IOWAIT}%</div>
      <div class="stat-sub">avg over vmstat samples</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Virtualization</div>
      <div class="stat-value" style="font-size:1rem">${VIRT}</div>
      <div class="stat-sub">${OS_PRETTY}</div>
    </div>
  </div>
</div>

<!-- ═══════════════════ CPU ═══════════════════ -->
<div class="card" id="cpu">
  <div class="card-header">⚡ CPU</div>
  <table>
    <tr><th>Parameter</th><th>Value</th></tr>
    <tr><td>Model</td><td class="code">${CPU_MODEL}</td></tr>
    <tr><td>Logical CPUs</td><td class="code">${CPU_CORES}</td></tr>
    <tr><td>Sockets</td><td class="code">${CPU_PHYS}</td></tr>
    <tr><td>NUMA Nodes</td><td class="code">${CPU_NUMA}</td></tr>
    <tr><td>Load Avg (1 / 5 / 15 min)</td><td class="code">${LOAD_1} / ${LOAD_5} / ${LOAD_15} &nbsp; (${LOAD_CPUS} CPUs)</td></tr>
    <tr><td>Avg CPU Idle (vmstat samples)</td><td class="code">${VMSTAT_IDLE}%</td></tr>
    <tr><td>Avg I/O Wait (vmstat samples)</td><td class="code">${VMSTAT_IOWAIT}%</td></tr>
  </table>
  <pre class="pre-block">${VMSTAT_HTML:-# vmstat data not available}</pre>
</div>

<!-- ═══════════════════ MEMORY ═══════════════════ -->
<div class="card" id="memory">
  <div class="card-header">🧠 Memory</div>
  <table>
    <tr><th>Metric</th><th>Value</th></tr>
    <tr><td>Total RAM</td><td class="code">$(_human $MEM_TOTAL_KB)</td></tr>
    <tr><td>Used (MemTotal − MemAvailable)</td><td class="code">$(_human $MEM_USED_KB) (${MEM_PCT}%)</td></tr>
    <tr><td>Available</td><td class="code">$(_human $MEM_AVAIL_KB)</td></tr>
    <tr><td>Swap Total</td><td class="code">$(_human $SWAP_TOTAL_KB)</td></tr>
    <tr><td>Swap Used</td><td class="code">$(_human $SWAP_USED_KB)$(
      [[ "$SWAP_USED_KB" -gt 0 ]] && echo ' &nbsp; <span class="badge b-orange">ACTIVE</span>'
    )</td></tr>
    <tr><td>HugePages Total / Free</td><td class="code">${HP_TOTAL} / ${HP_FREE} &nbsp;
      (size: $(_human $HP_SIZE_KB))</td></tr>
    <tr><td>Transparent Huge Pages</td><td class="code">${THP_STATUS}</td></tr>
    <tr><td>vm.swappiness</td><td class="code">${SWAPPINESS}</td></tr>
    <tr><td>vm.dirty_ratio</td><td class="code">${DIRTY_RATIO}</td></tr>
    <tr><td>vm.dirty_background_ratio</td><td class="code">${DIRTY_BG}</td></tr>
    <tr><td>vm.overcommit_memory</td><td class="code">${OVERCOMMIT}</td></tr>
  </table>
</div>

<!-- ═══════════════════ DISK ═══════════════════ -->
<div class="card" id="disk">
  <div class="card-header">💾 Disk &amp; I/O</div>
  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Filesystem Usage (df -h)</div>
  <pre class="pre-block">Filesystem      Size  Used Avail Use% Mounted on
${DF_HTML:-# Not available}</pre>

  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Block Devices (lsblk)</div>
  <pre class="pre-block">${LSBLK_HTML:-# Not available}</pre>

  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">I/O Statistics (iostat -x)</div>
  <pre class="pre-block">${IOSTAT_HTML:-# iostat not available — install sysstat}</pre>

  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Mount Options</div>
  <pre class="pre-block">$(grep -v '==\|^#' "${BUNDLE}/08_mounts.txt" 2>/dev/null | head -30 | _esc || echo "# Not available")</pre>
  $(
    if [[ -n "$MOUNT_ISSUES" ]]; then
      echo '<table><tr><th>Mount</th><th>Issue</th></tr>'"$MOUNT_ISSUES"'</table>'
    fi
  )
</div>

<!-- ═══════════════════ NETWORK ═══════════════════ -->
<div class="card" id="network">
  <div class="card-header">🌐 Network</div>
  <table>
    <tr><th>Metric</th><th>Value</th></tr>
    <tr><td>Total NIC errors</td><td class="code">${NET_ERRORS}</td></tr>
    <tr><td>Total NIC drops</td><td class="code">${NET_DROPS}</td></tr>
    <tr><td>net.core.somaxconn</td><td class="code">${SOMAXCONN}</td></tr>
  </table>

  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">/proc/net/dev (interface counters)</div>
  <pre class="pre-block">$(grep -v '==' "${BUNDLE}/10_net_ifaces.txt" 2>/dev/null | \
    awk '/\/proc\/net\/dev/{f=1;next} f && NF>0' | head -20 | _esc || echo "# Not available")</pre>

  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">sar -n DEV (throughput sample)</div>
  <pre class="pre-block">$(grep -v '^==' "${BUNDLE}/11_net_throughput.txt" 2>/dev/null | \
    grep -v '^$' | head -25 | _esc || echo "# Not available")</pre>

  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Listening Ports (ss -tuln)</div>
  <pre class="pre-block">$(awk '/listening ports/,0' "${BUNDLE}/12_sockets.txt" 2>/dev/null | \
    tail -n +2 | head -30 | _esc || echo "# Not available")</pre>
</div>

<!-- ═══════════════════ KERNEL ═══════════════════ -->
<div class="card" id="kernel">
  <div class="card-header">⚙ Kernel Parameters</div>
  <pre class="pre-block">${SYSCTL_HTML:-# Not available}</pre>

  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Huge Pages Config</div>
  <pre class="pre-block">$(cat "${BUNDLE}/05_hugepages.txt" 2>/dev/null | _esc | head -20 || echo "# Not available")</pre>

  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Kernel Events (dmesg errors/warnings)</div>
  <pre class="pre-block">${DMESG_HTML:-# Not available (run as root)}</pre>
</div>

<!-- ═══════════════════ PROCESSES ═══════════════════ -->
<div class="card" id="processes">
  <div class="card-header">🔧 Top Processes</div>
  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Top by CPU</div>
  <pre class="pre-block">${PROC_CPU_HTML:-# Not available}</pre>
  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Top by Memory</div>
  <pre class="pre-block">${PROC_MEM_HTML:-# Not available}</pre>
  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Running Services</div>
  <pre class="pre-block">${SERVICES_HTML:-# Not available}</pre>
  <div class="card-header" style="font-size:.85rem;border-top:1px solid var(--border)">Docker Containers</div>
  <pre class="pre-block">${DOCKER_HTML:-# Docker not available}</pre>
</div>

<!-- ═══════════════════ SECURITY ═══════════════════ -->
<div class="card" id="security">
  <div class="card-header">🔒 Security Posture</div>
  <pre class="pre-block">${SECURITY_HTML:-# Not available}</pre>
</div>

</div><!-- /container -->
<button id="backToTop" onclick="window.scrollTo({top:0,behavior:'smooth'})">▲</button>
<script>
window.onscroll=function(){
  document.getElementById('backToTop').style.display=
    (window.pageYOffset||document.documentElement.scrollTop)>400?'flex':'none';
};
</script>
</body></html>
HTML

SZ="$(wc -c < "$OUTPUT_FILE" 2>/dev/null || echo 0)"
SZ_KB="$(( (SZ + 512) / 1024 ))"
_ok "HTML report: ${SZ_KB} KB → ${OUTPUT_FILE}"
printf "\n  \033[97mDone.\033[0m  Open: %s\n\n" "$OUTPUT_FILE"
