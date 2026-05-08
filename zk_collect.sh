#!/usr/bin/env bash
# =============================================================================
#  ZK Audit Collector v1.0  (bash)
#  Zero Knowledge PostgreSQL snapshot bundle
#
#  Mirrors zk_collect.ps1 — same output format, same bundle structure.
#
#  Usage:
#    ./zk_collect.sh [OPTIONS]
#
#  Options:
#    --host HOST              PostgreSQL server hostname (default: localhost)
#    --port PORT              PostgreSQL port (default: 5432)
#    --database DATABASE      Database to snapshot (default: postgres)
#    --user USER              PostgreSQL user (default: postgres)
#    --password PASSWORD      PostgreSQL password (or export PGPASSWORD)
#    --output-dir DIR         Output directory (default: zk_audit_YYYYMMDD_HHMMSS)
#    --docker-container NAME  Run psql/pg_dump inside this Docker container
#    --databases LIST         Comma-separated databases for pg_dump (unused, reserved)
#    --no-schema-dump         Skip pg_dump --schema-only
#    --no-stat-dump           Skip pg_dump --statistics-only
#    -h, --help               Show this help
#
#  Examples:
#    # Local PostgreSQL
#    ./zk_collect.sh --host localhost --port 5432 --database mydb --user postgres
#
#    # Docker container
#    ./zk_collect.sh --docker-container my-postgres --database mydb --user postgres
#
#    # With password, custom output directory
#    ./zk_collect.sh --host db.example.com --user readonly \
#                    --password secret --output-dir ./my_audit
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PG_HOST="localhost"
PG_PORT=5432
DATABASE="postgres"
PG_USER="postgres"
PG_PASSWORD=""
OUTPUT_DIR=""
DOCKER_CONTAINER=""
DATABASES=""
NO_SCHEMA_DUMP=0
NO_STAT_DUMP=0

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
    --host)              PG_HOST="$2";          shift 2 ;;
    --port)              PG_PORT="$2";          shift 2 ;;
    --database)          DATABASE="$2";         shift 2 ;;
    --user)              PG_USER="$2";          shift 2 ;;
    --password)          PG_PASSWORD="$2";      shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";       shift 2 ;;
    --docker-container)  DOCKER_CONTAINER="$2"; shift 2 ;;
    --databases)         DATABASES="$2";        shift 2 ;;
    --no-schema-dump)    NO_SCHEMA_DUMP=1;      shift ;;
    --no-stat-dump)      NO_STAT_DUMP=1;        shift ;;
    -h|--help)           usage ;;
    *) _err "Unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Setup output directory
# ---------------------------------------------------------------------------
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="zk_audit_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

printf "\n"
printf "  \033[97mZK Audit Collector v1.0 (bash)\033[0m\n"
_gray "Output: $OUTPUT_DIR"
printf "\n"

# ---------------------------------------------------------------------------
# Password / env setup
# ---------------------------------------------------------------------------
ORIG_PGPASSWORD="${PGPASSWORD:-}"
[[ -n "$PG_PASSWORD" ]] && export PGPASSWORD="$PG_PASSWORD"

# ---------------------------------------------------------------------------
# Helpers: psql and pg_dump wrappers
# ---------------------------------------------------------------------------

# _psql SQL_FILE OUT_FILE [DATABASE]
_psql() {
  local sql_file="$1"
  local out_file="$2"
  local db="${3:-$DATABASE}"

  if [[ -n "$DOCKER_CONTAINER" ]]; then
    local leaf
    leaf="$(basename "$sql_file")"
    local tmp_in="/tmp/zk_in_${leaf}"
    local tmp_out="/tmp/zk_out_${leaf}"

    docker cp "$sql_file" "${DOCKER_CONTAINER}:${tmp_in}" > /dev/null
    docker exec "$DOCKER_CONTAINER" \
      sh -c "psql -U \"$PG_USER\" -d \"$db\" -A -t -q -f \"$tmp_in\" > \"$tmp_out\" 2>&1"
    docker cp "${DOCKER_CONTAINER}:${tmp_out}" "$out_file" > /dev/null
    docker exec "$DOCKER_CONTAINER" rm -f "$tmp_in" "$tmp_out" > /dev/null
  else
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" \
         -A -t -q -f "$sql_file" -o "$out_file" 2>&1 | head -20 || true
  fi
}

# _pgdump OUT_FILE DATABASE [EXTRA_ARGS...]
_pgdump() {
  local out_file="$1"
  local db="$2"
  shift 2
  local extra_args=("$@")

  if [[ -n "$DOCKER_CONTAINER" ]]; then
    local leaf
    leaf="$(basename "$out_file")"
    local tmp_out="/tmp/zk_pgdump_${leaf}"
    # Build args string safely (no user data in args)
    local arg_str
    arg_str="$(printf ' %q' "${extra_args[@]}")"
    docker exec "$DOCKER_CONTAINER" \
      sh -c "pg_dump -U \"$PG_USER\" -d \"$db\" ${arg_str} > \"$tmp_out\" 2>&1"
    docker cp "${DOCKER_CONTAINER}:${tmp_out}" "$out_file" > /dev/null
    docker exec "$DOCKER_CONTAINER" rm -f "$tmp_out" > /dev/null
  else
    pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" \
            "${extra_args[@]}" -f "$out_file" 2>&1 | head -20 || true
  fi
}

# Human-readable KB
_kb() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local sz
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    echo "$(( (sz + 512) / 1024 ))"
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# Step 1: catalog_snapshot.json
# ---------------------------------------------------------------------------
_step "Collecting catalog snapshot (schema, indexes, roles, settings)..."
CATALOG_SQL="${SCRIPT_DIR}/zk_catalog_dump.sql"
CATALOG_OUT="${OUTPUT_DIR}/catalog_snapshot.json"

if [[ ! -f "$CATALOG_SQL" ]]; then
  _warn "zk_catalog_dump.sql not found at ${CATALOG_SQL}"
else
  if _psql "$CATALOG_SQL" "$CATALOG_OUT"; then
    _ok "catalog_snapshot.json  ($(_kb "$CATALOG_OUT") KB)"
  else
    _warn "catalog_snapshot.json failed"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: stat_snapshot.json
# ---------------------------------------------------------------------------
_step "Collecting statistics snapshot (pg_stat_statements, bloat, locks)..."
STAT_SQL="${SCRIPT_DIR}/zk_stat_dump.sql"
STAT_OUT="${OUTPUT_DIR}/stat_snapshot.json"

if [[ ! -f "$STAT_SQL" ]]; then
  _warn "zk_stat_dump.sql not found at ${STAT_SQL}"
else
  if _psql "$STAT_SQL" "$STAT_OUT"; then
    _ok "stat_snapshot.json  ($(_kb "$STAT_OUT") KB)"
  else
    _warn "stat_snapshot.json failed"
  fi
fi

# ---------------------------------------------------------------------------
# Detect PostgreSQL major version
# ---------------------------------------------------------------------------
PG_VER_NUM=0
if [[ -n "$DOCKER_CONTAINER" ]]; then
  PG_VER_NUM=$(docker exec "$DOCKER_CONTAINER" \
    psql -U "$PG_USER" -d "$DATABASE" -A -t -q \
    -c "SELECT current_setting('server_version_num')::int;" 2>/dev/null | tr -d '[:space:]') || PG_VER_NUM=0
else
  PG_VER_NUM=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE" -A -t -q \
    -c "SELECT current_setting('server_version_num')::int;" 2>/dev/null | tr -d '[:space:]') || PG_VER_NUM=0
fi
PG_VER_NUM="${PG_VER_NUM:-0}"
PG_MAJOR=$(( PG_VER_NUM / 10000 ))
_gray "Detected PostgreSQL major version: ${PG_MAJOR}"

# ---------------------------------------------------------------------------
# Step 3: pg_dump --schema-only
# ---------------------------------------------------------------------------
if [[ "$NO_SCHEMA_DUMP" -eq 0 ]]; then
  _step "Running pg_dump --schema-only..."
  SCHEMA_OUT="${OUTPUT_DIR}/schema_dump.sql"
  SCHEMA_ARGS=("--schema-only" "--no-password")
  [[ "$PG_MAJOR" -ge 18 ]] && SCHEMA_ARGS+=("--no-statistics")

  if _pgdump "$SCHEMA_OUT" "$DATABASE" "${SCHEMA_ARGS[@]}"; then
    _ok "schema_dump.sql  ($(_kb "$SCHEMA_OUT") KB)"
  else
    _warn "schema_dump.sql failed"
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: pg_dump --statistics-only  (PG18+ only)
# ---------------------------------------------------------------------------
if [[ "$NO_STAT_DUMP" -eq 0 ]]; then
  STATS_OUT="${OUTPUT_DIR}/statistics_dump.sql"

  if [[ "$PG_MAJOR" -ge 18 ]]; then
    _step "Running pg_dump --statistics-only (PG18+)..."
    if _pgdump "$STATS_OUT" "$DATABASE" "--statistics-only" "--no-password"; then
      _ok "statistics_dump.sql  ($(_kb "$STATS_OUT") KB)"
    else
      _warn "statistics_dump.sql failed"
      echo "-- pg_dump --statistics-only failed" > "$STATS_OUT"
    fi
  else
    _step "Skipping pg_dump --statistics-only (PG${PG_MAJOR} — requires PG18+)..."
    _gray "  Planner stats captured via pg_stats in catalog_snapshot.json"
    cat > "$STATS_OUT" <<EOF
-- pg_dump --statistics-only requires PostgreSQL 18+.
-- Planner statistics are available in catalog_snapshot.json (planner_stats section).
-- PostgreSQL major version detected: ${PG_MAJOR}
EOF
    _ok "statistics_dump.sql  (note written)"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: manifest.json
# ---------------------------------------------------------------------------
_step "Writing manifest..."

PG_VERSION=""
if [[ -n "$DOCKER_CONTAINER" ]]; then
  PG_VERSION=$(docker exec "$DOCKER_CONTAINER" \
    psql -U "$PG_USER" -d "$DATABASE" -A -t -q \
    -c "SELECT version();" 2>/dev/null | tr -d '\r\n') || PG_VERSION=""
else
  PG_VERSION=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE" -A -t -q \
    -c "SELECT version();" 2>/dev/null | tr -d '\r\n') || PG_VERSION=""
fi
# Escape for JSON
PG_VERSION_JSON="${PG_VERSION//\\/\\\\}"
PG_VERSION_JSON="${PG_VERSION_JSON//\"/\\\"}"

# Build host value
if [[ -n "$DOCKER_CONTAINER" ]]; then
  HOST_VAL="docker:${DOCKER_CONTAINER}"
else
  HOST_VAL="${PG_HOST}:${PG_PORT}"
fi

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Build files array
FILES_JSON="["
FIRST=1
for f in "$OUTPUT_DIR"/*.json "$OUTPUT_DIR"/*.sql; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == "manifest.json" ]] && continue
  NAME="$(basename "$f")"
  SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
  # Use date -r for Linux; fall back gracefully
  if date -r "$f" -u +"%Y-%m-%dT%H:%M:%SZ" &>/dev/null; then
    MTIME="$(date -r "$f" -u +"%Y-%m-%dT%H:%M:%SZ")"
  else
    MTIME="$GENERATED_AT"
  fi
  [[ "$FIRST" -eq 0 ]] && FILES_JSON+=","
  FILES_JSON+="{\"name\":\"${NAME}\",\"size_bytes\":${SZ},\"modified\":\"${MTIME}\"}"
  FIRST=0
done
FILES_JSON+="]"

cat > "${OUTPUT_DIR}/manifest.json" <<EOF
{
  "zk_audit_version": "1.0",
  "generated_at": "${GENERATED_AT}",
  "pg_version": "${PG_VERSION_JSON}",
  "database": "${DATABASE}",
  "host": "${HOST_VAL}",
  "files": ${FILES_JSON}
}
EOF
_ok "manifest.json"

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
printf "  \033[97mBundle ready: %s\033[0m\n" "$OUTPUT_DIR"
printf "\n"
for f in "$OUTPUT_DIR"/*; do
  [[ -f "$f" ]] || continue
  NAME="$(basename "$f")"
  SZ=$(wc -c < "$f" 2>/dev/null || echo 0)
  printf "  \033[90m    %-32s %8d KB\033[0m\n" "$NAME" "$(( (SZ + 512) / 1024 ))"
done
printf "\n"
