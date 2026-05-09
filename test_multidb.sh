#!/usr/bin/env bash
# =============================================================================
#  test_multidb.sh  —  Multi-database ZK collect + replay integration test
#
#  Tests:
#    1. Start or reuse a Docker PostgreSQL container
#    2. Create 3 test databases with realistic tables and pg_stat_statements
#    3. Run zk_collect.sh (all databases)  — verify bundle structure
#    4. Run zk_replay.sh                   — verify per-database reports
#    5. Verify JSON is valid for each report
#    6. Print PASS / FAIL summary
#
#  Usage:
#    ./test_multidb.sh [--container NAME] [--keep] [--json]
#
#  Options:
#    --container NAME   Docker container name (default: zk-test-multidb)
#    --keep             Keep container and bundle after test (default: remove)
#    --json             Generate JSON reports instead of HTML
#    --help             Show this help
#
#  Requirements:
#    docker, psql (local or inside container), bash 4.3+
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CONTAINER="zk-test-multidb"
KEEP=false
JSON_MODE=false
PG_USER="postgres"
PG_IMAGE="postgres:17"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
_pass() { printf "  \033[32m✓ PASS  %s\033[0m\n" "$*"; }
_fail() { printf "  \033[31m✗ FAIL  %s\033[0m\n" "$*"; FAILURES=$(( FAILURES + 1 )); }
_step() { printf "\n  \033[36m▶ %s\033[0m\n" "$*"; }
_info() { printf "  \033[90m  %s\033[0m\n" "$*"; }
_warn() { printf "  \033[33m⚠ WARN  %s\033[0m\n" "$*"; }

FAILURES=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="$2"; shift 2 ;;
    --keep)      KEEP=true;       shift   ;;
    --json)      JSON_MODE=true;  shift   ;;
    --help|-h)
      sed -n '/^#  Usage:/,/^[^#]/p' "$0" | sed 's/^#  \{0,2\}//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Cleanup handler
# ---------------------------------------------------------------------------
BUNDLE_DIR=""
LEGACY_DIR=""
cleanup() {
  if ! $KEEP; then
    if docker ps -q --filter "name=^${CONTAINER}$" 2>/dev/null | grep -q .; then
      _info "Removing container: ${CONTAINER}"
      docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
    fi
    if [[ -n "$BUNDLE_DIR" && -d "$BUNDLE_DIR" ]]; then
      _info "Removing bundle: ${BUNDLE_DIR}"
      rm -rf "$BUNDLE_DIR"
    fi
    if [[ -n "$LEGACY_DIR" && -d "$LEGACY_DIR" ]]; then
      rm -rf "$LEGACY_DIR"
    fi
  else
    _info "Keeping container '${CONTAINER}' and bundle '${BUNDLE_DIR}' (--keep)"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: run SQL in container
# ---------------------------------------------------------------------------
_psql() {
  local db="$1"; shift
  docker exec "$CONTAINER" psql -U "$PG_USER" -d "$db" -A -t -q -c "$*" 2>/dev/null \
    | tr -d '\r'
}

_psql_f() {
  local db="$1"
  local sql_file="$2"
  docker exec "$CONTAINER" psql -U "$PG_USER" -d "$db" -A -t -q -f "$sql_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Step 1: Start / reuse Docker container
# ---------------------------------------------------------------------------
_step "1. Docker container setup"

if docker ps -q --filter "name=^${CONTAINER}$" 2>/dev/null | grep -q .; then
  _info "Reusing running container: ${CONTAINER}"
else
  if docker ps -aq --filter "name=^${CONTAINER}$" 2>/dev/null | grep -q .; then
    _info "Removing stopped container: ${CONTAINER}"
    docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
  fi
  _info "Starting container: ${CONTAINER} (image: ${PG_IMAGE})"
  docker run -d --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=testpass \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    "$PG_IMAGE" \
    postgres -c shared_preload_libraries=pg_stat_statements \
             -c pg_stat_statements.track=all \
             -c track_counts=on \
             -c track_io_timing=on \
    > /dev/null

  # Wait for PostgreSQL to be ready
  _info "Waiting for PostgreSQL to be ready..."
  for i in $(seq 1 30); do
    if docker exec "$CONTAINER" pg_isready -U "$PG_USER" -q 2>/dev/null; then
      break
    fi
    sleep 1
    if [[ "$i" -eq 30 ]]; then
      _fail "PostgreSQL did not become ready in 30 seconds"
      exit 1
    fi
  done
fi

PG_VER=$(_psql postgres "SELECT substring(version() FROM '^PostgreSQL ([0-9]+)');" 2>/dev/null \
  | tr -d '[:space:]')
_pass "Container ready  (PostgreSQL ${PG_VER})"

# ---------------------------------------------------------------------------
# Step 2: Create test databases and schemas
# ---------------------------------------------------------------------------
_step "2. Creating test databases"

# Drop + recreate test databases
for db in zktest_app zktest_reporting zktest_legacy; do
  docker exec "$CONTAINER" psql -U "$PG_USER" -d postgres -A -t -q \
    -c "DROP DATABASE IF EXISTS ${db};" 2>/dev/null || true
  docker exec "$CONTAINER" psql -U "$PG_USER" -d postgres -A -t -q \
    -c "CREATE DATABASE ${db};" 2>/dev/null
done

# Helper: run a SQL script in a database via temp file (more reliable than heredoc)
_setup_db() {
  local db="$1"
  local sql="$2"
  local tmp_sql
  tmp_sql="$(mktemp /tmp/zktest_setup_XXXXXX.sql)"
  printf '%s\n' "$sql" > "$tmp_sql"
  docker cp "$tmp_sql" "${CONTAINER}:/tmp/zktest_setup_${db}.sql" > /dev/null
  docker exec "$CONTAINER" psql -U "$PG_USER" -d "$db" -q \
    -f "/tmp/zktest_setup_${db}.sql" 2>/dev/null || true
  docker exec "$CONTAINER" rm -f "/tmp/zktest_setup_${db}.sql" > /dev/null || true
  rm -f "$tmp_sql"
}

# zktest_app: typical web application schema
_setup_db zktest_app "
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE TABLE users (
  id         bigserial PRIMARY KEY,
  email      varchar(255) NOT NULL UNIQUE,
  username   varchar(64) NOT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
CREATE TABLE posts (
  id         bigserial PRIMARY KEY,
  user_id    bigint NOT NULL REFERENCES users(id),
  title      varchar(500) NOT NULL,
  body       text,
  published  boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);
CREATE TABLE tags (
  id   serial PRIMARY KEY,
  name varchar(100) NOT NULL UNIQUE
);
CREATE TABLE post_tags (
  post_id bigint NOT NULL REFERENCES posts(id),
  tag_id  int    NOT NULL REFERENCES tags(id),
  PRIMARY KEY (post_id, tag_id)
);
CREATE INDEX idx_users_email_a ON users(email);
CREATE INDEX idx_users_email_b ON users(email);

INSERT INTO users (email, username)
  SELECT 'user' || i || '@example.com', 'user' || i
  FROM generate_series(1, 100) i;
INSERT INTO posts (user_id, title, body, published)
  SELECT (random() * 99 + 1)::int, 'Post ' || i, repeat('x', 200), i % 3 = 0
  FROM generate_series(1, 500) i;
INSERT INTO tags (name) VALUES ('tech'), ('news'), ('opinion'), ('tutorial');
INSERT INTO post_tags (post_id, tag_id)
  SELECT (random() * 499 + 1)::int, (random() * 3 + 1)::int
  FROM generate_series(1, 200) i ON CONFLICT DO NOTHING;
SELECT count(*) FROM users WHERE email LIKE '%@example.com';
SELECT count(*) FROM posts WHERE published = true;
ANALYZE;
"

# zktest_reporting: analytics / reporting schema
_setup_db zktest_reporting "
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE TABLE events (
  id         bigserial PRIMARY KEY,
  event_type varchar(64) NOT NULL,
  user_id    bigint,
  session_id uuid DEFAULT gen_random_uuid(),
  payload    jsonb,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX idx_events_type       ON events(event_type);
CREATE INDEX idx_events_user_id    ON events(user_id);
CREATE INDEX idx_events_created_at ON events(created_at);

CREATE TABLE daily_aggregates (
  date        date NOT NULL,
  event_type  varchar(64) NOT NULL,
  cnt         bigint DEFAULT 0,
  PRIMARY KEY (date, event_type)
);

INSERT INTO events (event_type, user_id)
  SELECT CASE (i % 5)
           WHEN 0 THEN 'page_view' WHEN 1 THEN 'click'
           WHEN 2 THEN 'signup'    WHEN 3 THEN 'purchase'
           ELSE 'logout'
         END, (random() * 1000)::int
  FROM generate_series(1, 1000) i;
SELECT event_type, count(*) FROM events GROUP BY event_type;
ANALYZE;
"

# zktest_legacy: minimal schema, no pg_stat_statements
_setup_db zktest_legacy "
CREATE TABLE config (
  key   varchar(128) PRIMARY KEY,
  value text,
  updated_at timestamptz DEFAULT now()
);
INSERT INTO config (key, value) VALUES ('version', '1.0'), ('env', 'test');
ANALYZE;
"

_pass "Databases created: zktest_app, zktest_reporting, zktest_legacy"

# Verify postgres DB also accessible (should be included in collection)
DB_COUNT=$(_psql postgres \
  "SELECT count(*) FROM pg_database WHERE datallowconn AND datname NOT IN ('template0','template1');" \
  | tr -d '[:space:]')
_info "Connectable databases in cluster: ${DB_COUNT}"

# ---------------------------------------------------------------------------
# Step 3: Run zk_collect.sh
# ---------------------------------------------------------------------------
_step "3. Running zk_collect.sh (all databases)"

BUNDLE_DIR="$(mktemp -d /tmp/zk_test_bundle_XXXXXX)"

"${SCRIPT_DIR}/zk_collect.sh" \
  --docker-container "$CONTAINER" \
  --user "$PG_USER" \
  --output-dir "$BUNDLE_DIR" \
  --no-schema-dump \
  --no-stat-dump

_info "Bundle: ${BUNDLE_DIR}"

# ---------------------------------------------------------------------------
# Verify bundle structure
# ---------------------------------------------------------------------------
_step "3a. Verifying bundle structure"

# Check manifest exists and is valid JSON
if [[ -f "${BUNDLE_DIR}/manifest.json" ]]; then
  if python3 -c "import json,sys; json.load(open('${BUNDLE_DIR}/manifest.json'))" 2>/dev/null; then
    _pass "manifest.json is valid JSON"
  elif python -c "import json,sys; json.load(open('${BUNDLE_DIR}/manifest.json'))" 2>/dev/null; then
    _pass "manifest.json is valid JSON"
  else
    _fail "manifest.json is not valid JSON"
  fi
else
  _fail "manifest.json not found"
fi

# Check bundle name contains PG version
BUNDLE_NAME="$(basename "$BUNDLE_DIR")"
# Note: when --output-dir is specified, it's an exact path, not auto-named.
# Check the manifest for pg_major instead.
PG_MAJOR_IN_MANIFEST=""
if command -v python3 &>/dev/null; then
  PG_MAJOR_IN_MANIFEST=$(python3 -c "
import json
m=json.load(open('${BUNDLE_DIR}/manifest.json'))
print(m.get('pg_major',''))
" 2>/dev/null || echo "")
elif command -v python &>/dev/null; then
  PG_MAJOR_IN_MANIFEST=$(python -c "
import json
m=json.load(open('${BUNDLE_DIR}/manifest.json'))
print(m.get('pg_major',''))
" 2>/dev/null || echo "")
fi

if [[ -n "$PG_MAJOR_IN_MANIFEST" && "$PG_MAJOR_IN_MANIFEST" -gt 0 ]]; then
  _pass "pg_major in manifest: ${PG_MAJOR_IN_MANIFEST}"
else
  _fail "pg_major missing or zero in manifest"
fi

# Check databases array in manifest
MANIFEST_DBS=""
if command -v python3 &>/dev/null; then
  MANIFEST_DBS=$(python3 -c "
import json
m=json.load(open('${BUNDLE_DIR}/manifest.json'))
print(' '.join(sorted(m.get('databases',[]))))
" 2>/dev/null || echo "")
fi

_info "Databases in manifest: ${MANIFEST_DBS}"
for expected_db in postgres zktest_app zktest_reporting zktest_legacy; do
  if echo "$MANIFEST_DBS" | grep -qw "$expected_db"; then
    _pass "manifest.databases includes '${expected_db}'"
  else
    _fail "manifest.databases missing '${expected_db}'"
  fi
done

# Check per-database files exist
for db in postgres zktest_app zktest_reporting zktest_legacy; do
  if [[ -f "${BUNDLE_DIR}/catalog_db_${db}.json" ]]; then
    SZ="$(wc -c < "${BUNDLE_DIR}/catalog_db_${db}.json" 2>/dev/null || echo 0)"
    if [[ "$SZ" -gt 100 ]]; then
      _pass "catalog_db_${db}.json  (${SZ} bytes)"
    else
      _fail "catalog_db_${db}.json is too small (${SZ} bytes)"
    fi
  else
    _fail "catalog_db_${db}.json not found"
  fi

  if [[ -f "${BUNDLE_DIR}/stat_db_${db}.json" ]]; then
    SZ="$(wc -c < "${BUNDLE_DIR}/stat_db_${db}.json" 2>/dev/null || echo 0)"
    if [[ "$SZ" -gt 100 ]]; then
      _pass "stat_db_${db}.json  (${SZ} bytes)"
    else
      _fail "stat_db_${db}.json is too small (${SZ} bytes)"
    fi
  else
    _fail "stat_db_${db}.json not found"
  fi
done

# Validate each catalog JSON
_step "3b. Validating JSON correctness"
JSON_VALIDATOR="python3 -c \"import json,sys; json.load(sys.stdin)\""
if ! command -v python3 &>/dev/null; then
  JSON_VALIDATOR="python -c \"import json,sys; json.load(sys.stdin)\""
fi

for db in postgres zktest_app zktest_reporting zktest_legacy; do
  for ftype in catalog stat; do
    f="${BUNDLE_DIR}/${ftype}_db_${db}.json"
    [[ -f "$f" ]] || continue
    if eval "$JSON_VALIDATOR" < "$f" 2>/dev/null; then
      _pass "${ftype}_db_${db}.json is valid JSON"
    else
      _fail "${ftype}_db_${db}.json is INVALID JSON"
    fi
  done
done

# Check pg_version is embedded in each catalog file
for db in postgres zktest_app zktest_reporting zktest_legacy; do
  f="${BUNDLE_DIR}/catalog_db_${db}.json"
  [[ -f "$f" ]] || continue
  if grep -q '"pg_version"' "$f" 2>/dev/null; then
    VER_IN_FILE=$(python3 -c "
import json; d=json.load(open('$f'))
print(d.get('_meta',{}).get('pg_version','')[:30])
" 2>/dev/null || echo "")
    _pass "catalog_db_${db}.json embeds pg_version: ${VER_IN_FILE}"
  else
    _fail "catalog_db_${db}.json missing pg_version"
  fi
done

# ---------------------------------------------------------------------------
# Step 4: Run zk_replay.sh
# ---------------------------------------------------------------------------
_step "4. Running zk_replay.sh (multi-database replay)"

REPORTS_DIR="${BUNDLE_DIR}/reports"
mkdir -p "$REPORTS_DIR"

REPLAY_ARGS=(
  --bundle "$BUNDLE_DIR"
  --docker-container "$CONTAINER"
  --user "$PG_USER"
  --output-dir "$REPORTS_DIR"
)
$JSON_MODE && REPLAY_ARGS+=(--json)

"${SCRIPT_DIR}/zk_replay.sh" "${REPLAY_ARGS[@]}"

# ---------------------------------------------------------------------------
# Verify reports exist and are non-empty
# ---------------------------------------------------------------------------
_step "4a. Verifying per-database reports"

EXT="html"; $JSON_MODE && EXT="json"

for db in postgres zktest_app zktest_reporting zktest_legacy; do
  for rtype in ultimate_report perf_report; do
    f="${REPORTS_DIR}/offline_${rtype}_${db}.${EXT}"
    if [[ -f "$f" ]]; then
      SZ="$(wc -c < "$f" 2>/dev/null || echo 0)"
      if [[ "$SZ" -gt 100 ]]; then
        _pass "offline_${rtype}_${db}.${EXT}  (${SZ} bytes)"
      else
        _fail "offline_${rtype}_${db}.${EXT} is too small (${SZ} bytes)"
      fi
    else
      _fail "offline_${rtype}_${db}.${EXT} not found"
    fi
  done
done

# If JSON mode, validate each report JSON
if $JSON_MODE; then
  _step "4b. Validating report JSON"
  for db in postgres zktest_app zktest_reporting zktest_legacy; do
    for rtype in ultimate_report perf_report; do
      f="${REPORTS_DIR}/offline_${rtype}_${db}.${EXT}"
      [[ -f "$f" ]] || continue
      if eval "$JSON_VALIDATOR" < "$f" 2>/dev/null; then
        _pass "offline_${rtype}_${db}.${EXT} is valid JSON"
      else
        _fail "offline_${rtype}_${db}.${EXT} is INVALID JSON"
      fi
    done
  done
fi

# ---------------------------------------------------------------------------
# Step 5: Verify database-specific data appears in correct reports
# ---------------------------------------------------------------------------
_step "5. Verifying database-specific content in reports"

# Each per-database report should show its own pg_version
for db in zktest_app zktest_reporting; do
  f="${REPORTS_DIR}/offline_ultimate_report_${db}.${EXT}"
  [[ -f "$f" ]] || continue
  if grep -q 'PostgreSQL' "$f" 2>/dev/null; then
    _pass "Report for ${db} contains PostgreSQL version string"
  else
    _warn "Report for ${db}: PostgreSQL version string not found (may be OK)"
  fi
done

# zktest_app should have table 'users' and 'posts' in its catalog
f="${BUNDLE_DIR}/catalog_db_zktest_app.json"
if [[ -f "$f" ]]; then
  if grep -q '"users"' "$f" && grep -q '"posts"' "$f"; then
    _pass "catalog_db_zktest_app.json contains tables: users, posts"
  else
    _fail "catalog_db_zktest_app.json missing expected tables"
  fi
fi

# zktest_reporting should have 'events' table
f="${BUNDLE_DIR}/catalog_db_zktest_reporting.json"
if [[ -f "$f" ]]; then
  if grep -q '"events"' "$f"; then
    _pass "catalog_db_zktest_reporting.json contains table: events"
  else
    _fail "catalog_db_zktest_reporting.json missing 'events' table"
  fi
fi

# Databases should NOT appear in each other's catalog tables section
f="${BUNDLE_DIR}/catalog_db_zktest_legacy.json"
if [[ -f "$f" ]]; then
  if ! grep -q '"users"' "$f" 2>/dev/null; then
    _pass "catalog_db_zktest_legacy.json does not contain zktest_app tables (correct isolation)"
  else
    _fail "catalog_db_zktest_legacy.json unexpectedly contains 'users' table"
  fi
fi

# ---------------------------------------------------------------------------
# Step 6: Test legacy bundle backward compatibility (catalog_snapshot.json)
# ---------------------------------------------------------------------------
_step "6. Testing legacy bundle backward compatibility"

LEGACY_DIR="$(mktemp -d /tmp/zk_test_legacy_XXXXXX)"

# Create a minimal legacy-format bundle
cp "${BUNDLE_DIR}/catalog_db_postgres.json" "${LEGACY_DIR}/catalog_snapshot.json"
cp "${BUNDLE_DIR}/stat_db_postgres.json"    "${LEGACY_DIR}/stat_snapshot.json"

LEGACY_REPORTS="${LEGACY_DIR}/reports"
mkdir -p "$LEGACY_REPORTS"

LEGACY_ARGS=(
  --bundle "$LEGACY_DIR"
  --docker-container "$CONTAINER"
  --user "$PG_USER"
  --output-dir "$LEGACY_REPORTS"
)
$JSON_MODE && LEGACY_ARGS+=(--json)

if "${SCRIPT_DIR}/zk_replay.sh" "${LEGACY_ARGS[@]}" 2>/dev/null; then
  f="${LEGACY_REPORTS}/offline_ultimate_report.${EXT}"
  if [[ -f "$f" && "$(wc -c < "$f")" -gt 100 ]]; then
    _pass "Legacy bundle replay produces offline_ultimate_report.${EXT}"
  else
    _fail "Legacy bundle replay: report missing or empty"
  fi
else
  _fail "Legacy bundle replay failed"
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
printf "\n"
printf "  ══════════════════════════════════════════════\n"
if [[ "$FAILURES" -eq 0 ]]; then
  printf "  \033[32m  ALL TESTS PASSED\033[0m\n"
else
  printf "  \033[31m  %d TEST(S) FAILED\033[0m\n" "$FAILURES"
fi
printf "  ══════════════════════════════════════════════\n\n"

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
