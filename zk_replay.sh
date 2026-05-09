#!/usr/bin/env bash
# =============================================================================
#  ZK Replay v2.0  (bash)
#  Runs pg_audit reports against an offline ZK bundle
#
#  Supports both v2.0 multi-database bundles (catalog_db_<name>.json) and
#  legacy v1.0 bundles (catalog_snapshot.json + stat_snapshot.json).
#
#  Mirrors zk_replay.ps1 — same workflow, same output files.
#
#  Usage:
#    ./zk_replay.sh --bundle BUNDLE_DIR [OPTIONS]
#
#  Options:
#    --bundle DIR             Path to bundle directory (REQUIRED)
#    --host HOST              PostgreSQL replay host (default: localhost)
#    --port PORT              PostgreSQL port (default: 5432)
#    --database DATABASE      PostgreSQL database for replay staging (default: postgres)
#    --user USER              PostgreSQL user (default: postgres)
#    --password PASSWORD      PostgreSQL password (or export PGPASSWORD)
#    --docker-container NAME  Run psql inside this Docker container
#    --output-dir DIR         Directory for HTML/JSON reports (default: bundle dir)
#    --json                   Emit JSON instead of HTML (for LLM ingestion)
#    -h, --help               Show this help
#
#  Examples:
#    # Multi-database bundle (v2.0) — generates one report per database
#    ./zk_replay.sh --bundle ./zk_audit_PG17_20260508_143022
#
#    # Docker container
#    ./zk_replay.sh --bundle ./zk_audit_PG17_20260508_143022 \
#                   --docker-container pg-test-report --output-dir ./reports
#
#    # JSON output for LLM ingestion
#    ./zk_replay.sh --bundle ./zk_audit_PG17_20260508_143022 \
#                   --docker-container pg-test-report --json
#
#    # Legacy v1.0 bundle (catalog_snapshot.json / stat_snapshot.json)
#    ./zk_replay.sh --bundle ./zk_audit_20260508_143022
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
BUNDLE=""
PG_HOST="localhost"
PG_PORT=5432
DATABASE="postgres"
PG_USER="postgres"
PG_PASSWORD=""
OUTPUT_DIR=""
DOCKER_CONTAINER=""
JSON_MODE=false

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
_step() { printf "  \033[36m%s\033[0m\n"       "$*"; }
_ok()   { printf "  \033[32mOK  %s\033[0m\n"   "$*"; }
_warn() { printf "  \033[33mWARN  %s\033[0m\n" "$*"; }
_err()  { printf "  \033[31mERR  %s\033[0m\n"  "$*" >&2; exit 1; }
_gray() { printf "  \033[90m%s\033[0m\n"        "$*"; }

usage() {
  sed -n '/^#  Usage:/,/^[^#]/p' "$0" | sed 's/^#  \{0,2\}//'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)            BUNDLE="$2";           shift 2 ;;
    --host)              PG_HOST="$2";          shift 2 ;;
    --port)              PG_PORT="$2";          shift 2 ;;
    --database)          DATABASE="$2";         shift 2 ;;
    --user)              PG_USER="$2";          shift 2 ;;
    --password)          PG_PASSWORD="$2";      shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";       shift 2 ;;
    --docker-container)  DOCKER_CONTAINER="$2"; shift 2 ;;
    --json)              JSON_MODE=true;         shift   ;;
    -h|--help)           usage ;;
    *) _err "Unknown argument: $1" ;;
  esac
done

[[ -z "$BUNDLE" ]] && _err "--bundle is required. Use --help for usage."

# ---------------------------------------------------------------------------
# Validate bundle
# ---------------------------------------------------------------------------
BUNDLE="$(cd "$BUNDLE" && pwd)"

INGEST_SQL="${SCRIPT_DIR}/zk_ingest.sql"
[[ -f "$INGEST_SQL" ]] || _err "zk_ingest.sql not found at: $INGEST_SQL"

if $JSON_MODE; then
  ULTIMATE_SQL="${SCRIPT_DIR}/ultimate_report_json.sql"
  PERF_SQL="${SCRIPT_DIR}/pg_perf_report_json.sql"
else
  ULTIMATE_SQL="${SCRIPT_DIR}/ultimate_report.sql"
  PERF_SQL="${SCRIPT_DIR}/pg_perf_report.sql"
fi
[[ -f "$ULTIMATE_SQL" ]] || _err "$(basename "$ULTIMATE_SQL") not found at: $ULTIMATE_SQL"
[[ -f "$PERF_SQL"     ]] || _err "$(basename "$PERF_SQL") not found at: $PERF_SQL"

[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$BUNDLE"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# ---------------------------------------------------------------------------
# Detect bundle format: v2.0 (catalog_db_*.json) vs legacy (catalog_snapshot.json)
# ---------------------------------------------------------------------------
MULTI_DB=false
declare -a DB_NAMES=()
declare -a CATALOG_FILES_ARR=()
declare -a STAT_FILES_ARR=()

# Collect v2.0 per-database catalog files
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  CATALOG_FILES_ARR+=("$f")
  base="$(basename "$f")"
  db="${base#catalog_db_}"
  db="${db%.json}"
  DB_NAMES+=("$db")
done < <(find "$BUNDLE" -maxdepth 1 -name 'catalog_db_*.json' | sort 2>/dev/null || true)

if [[ ${#CATALOG_FILES_ARR[@]} -gt 0 ]]; then
  MULTI_DB=true
  for i in "${!DB_NAMES[@]}"; do
    db="${DB_NAMES[$i]}"
    STAT_FILES_ARR+=("${BUNDLE}/stat_db_${db}.json")
  done
elif [[ -f "${BUNDLE}/catalog_snapshot.json" ]]; then
  # Legacy single-database bundle
  MULTI_DB=false
  DB_NAMES=("")
  CATALOG_FILES_ARR=("${BUNDLE}/catalog_snapshot.json")
  STAT_FILES_ARR=("${BUNDLE}/stat_snapshot.json")
  [[ -f "${BUNDLE}/stat_snapshot.json" ]] || _err "stat_snapshot.json not found in: $BUNDLE"
else
  _err "No catalog files found in bundle. Expected catalog_db_*.json (v2.0) or catalog_snapshot.json (legacy)."
fi

# ---------------------------------------------------------------------------
# Password / env setup
# ---------------------------------------------------------------------------
ORIG_PGPASSWORD="${PGPASSWORD:-}"
[[ -n "$PG_PASSWORD" ]] && export PGPASSWORD="$PG_PASSWORD"

# ---------------------------------------------------------------------------
# psql runner — SQL_FILE [OUT_FILE]
# ---------------------------------------------------------------------------
_psql() {
  local sql_file="$1"
  local out_file="${2:-}"

  if [[ -n "$DOCKER_CONTAINER" ]]; then
    local leaf
    leaf="$(basename "$sql_file")-$$"
    local tmp_in="/tmp/zk_replay_${leaf}"
    docker cp "$sql_file" "${DOCKER_CONTAINER}:${tmp_in}" > /dev/null

    if [[ -n "$out_file" ]]; then
      local tmp_out="/tmp/zk_replay_out_${leaf}.html"
      docker exec "$DOCKER_CONTAINER" \
        sh -c "psql -U \"$PG_USER\" -d \"$DATABASE\" -q -f \"$tmp_in\" -o \"$tmp_out\" 2>&1"
      docker cp "${DOCKER_CONTAINER}:${tmp_out}" "$out_file" > /dev/null
      docker exec "$DOCKER_CONTAINER" rm -f "$tmp_out" > /dev/null
    else
      docker exec "$DOCKER_CONTAINER" \
        sh -c "psql -U \"$PG_USER\" -d \"$DATABASE\" -q -f \"$tmp_in\" 2>&1"
    fi
    docker exec "$DOCKER_CONTAINER" rm -f "$tmp_in" > /dev/null
  else
    local conn_args=(-h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE" -q)
    if [[ -n "$out_file" ]]; then
      psql "${conn_args[@]}" -f "$sql_file" -o "$out_file" 2>&1 | head -40 || true
    else
      psql "${conn_args[@]}" -f "$sql_file" 2>&1 | head -40 || true
    fi
  fi
}

_kb() {
  local f="$1"
  [[ -f "$f" ]] || { echo 0; return; }
  local sz
  sz=$(wc -c < "$f" 2>/dev/null || echo 0)
  echo "$(( (sz + 512) / 1024 ))"
}

# ---------------------------------------------------------------------------
# Helper: load two JSON files into _zk_catalog + _zk_stat staging tables
# ---------------------------------------------------------------------------
_load_bundle() {
  local catalog_file="$1"
  local stat_file="$2"

  local CATALOG_JSON STAT_JSON
  CATALOG_JSON="$(<"$catalog_file")"
  STAT_JSON="$(<"$stat_file")"

  # Dollar-quote tag — split literal to avoid matching itself in source
  local DQ_TAG='$'"zk"'$'

  # Safety check: JSON must not contain the tag
  if printf '%s' "$CATALOG_JSON" | grep -qF "$DQ_TAG" || \
     printf '%s' "$STAT_JSON"    | grep -qF "$DQ_TAG"; then
    _err "JSON contains dollar-quote tag ${DQ_TAG} — cannot safely embed"
  fi

  # Write load SQL to a temp file
  local TMP_LOAD
  TMP_LOAD="$(mktemp /tmp/zk_load_XXXXXX.sql)"
  trap 'rm -f "$TMP_LOAD"' EXIT

  {
    printf "SET client_min_messages = WARNING;\n"
    printf "DROP TABLE IF EXISTS _zk_catalog CASCADE;\n"
    printf "DROP TABLE IF EXISTS _zk_stat CASCADE;\n"
    printf "CREATE UNLOGGED TABLE _zk_catalog (data jsonb);\n"
    printf "CREATE UNLOGGED TABLE _zk_stat    (data jsonb);\n"
    printf "INSERT INTO _zk_catalog (data) VALUES (%s\n" "$DQ_TAG"
    printf '%s\n' "$CATALOG_JSON"
    printf "%s::jsonb);\n" "$DQ_TAG"
    printf "INSERT INTO _zk_stat (data) VALUES (%s\n" "$DQ_TAG"
    printf '%s\n' "$STAT_JSON"
    printf "%s::jsonb);\n" "$DQ_TAG"
  } > "$TMP_LOAD"

  _psql "$TMP_LOAD"
  rm -f "$TMP_LOAD"
  trap - EXIT
}

# ---------------------------------------------------------------------------
# Helper: wrap a report with search_path and run it
# ---------------------------------------------------------------------------
_run_report() {
  local report_sql="$1"
  local out_html="$2"
  local label="$3"

  _step "Generating ${label}..."

  local tmp_wrap
  tmp_wrap="$(mktemp /tmp/zk_wrap_XXXXXX.sql)"

  {
    printf "SET search_path = zk, pg_catalog, public;\n"
    cat "$report_sql"
  } > "$tmp_wrap"

  _psql "$tmp_wrap" "$out_html"
  rm -f "$tmp_wrap"

  local sz
  sz="$(_kb "$out_html")"
  _ok "${label}  (${sz} KB)  ->  ${out_html}"
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
printf "\n"
printf "  \033[97mZK Replay v2.0 (bash)\033[0m\n"
_gray "Bundle: $BUNDLE"
_gray "Output: $OUTPUT_DIR"
if $MULTI_DB; then
  _gray "Mode:   multi-database (v2.0)  [${#DB_NAMES[@]} database(s): ${DB_NAMES[*]}]"
else
  _gray "Mode:   legacy single-database (v1.0)"
fi
printf "\n"

EXT="html"; $JSON_MODE && EXT="json"

# ---------------------------------------------------------------------------
# Main replay loop — one iteration per database
# ---------------------------------------------------------------------------
for i in "${!DB_NAMES[@]}"; do
  db="${DB_NAMES[$i]}"
  catalog_file="${CATALOG_FILES_ARR[$i]}"
  stat_file="${STAT_FILES_ARR[$i]}"

  if $MULTI_DB; then
    SUFFIX="_${db}"
    LABEL="Database: ${db}"
    [[ -f "$catalog_file" ]] || { _warn "Skipping ${db}: catalog file not found"; continue; }
    [[ -f "$stat_file"    ]] || { _warn "Skipping ${db}: stat file not found";    continue; }
  else
    SUFFIX=""
    LABEL="(legacy bundle)"
  fi

  printf "\n"
  _step "━━━ Replaying ${LABEL} ━━━"

  # ------------------------------------------------------------------
  # Step 1: Load JSON into staging tables
  # ------------------------------------------------------------------
  _step "Loading JSON bundle into staging tables..."
  _load_bundle "$catalog_file" "$stat_file"
  _ok "Staging tables created"

  # ------------------------------------------------------------------
  # Step 2: Build shadow zk schema
  # ------------------------------------------------------------------
  _step "Building shadow zk schema (zk_ingest.sql)..."
  _psql "$INGEST_SQL"
  _ok "Shadow schema ready"

  # ------------------------------------------------------------------
  # Step 3: Generate reports
  # ------------------------------------------------------------------
  ULTIMATE_OUT="${OUTPUT_DIR}/offline_ultimate_report${SUFFIX}.${EXT}"
  PERF_OUT="${OUTPUT_DIR}/offline_perf_report${SUFFIX}.${EXT}"

  _run_report "$ULTIMATE_SQL" "$ULTIMATE_OUT" "ultimate_report${SUFFIX}"
  _run_report "$PERF_SQL"     "$PERF_OUT"     "pg_perf_report${SUFFIX}"
done

# ---------------------------------------------------------------------------
# Restore PGPASSWORD
# ---------------------------------------------------------------------------
if [[ -n "$PG_PASSWORD" ]]; then
  if [[ -n "$ORIG_PGPASSWORD" ]]; then
    export PGPASSWORD="$ORIG_PGPASSWORD"
  else
    unset PGPASSWORD
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n"
printf "  \033[97mReplay complete.\033[0m\n"
printf "\n"
for f in "$OUTPUT_DIR"/offline_*."$EXT"; do
  [[ -f "$f" ]] || continue
  NAME="$(basename "$f")"
  SZ="$(_kb "$f")"
  printf "  \033[90m    %-44s %8d KB\033[0m\n" "$NAME" "$SZ"
done
printf "\n"
