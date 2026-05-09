# PostgreSQL Audit & Performance Reports

Standardized PostgreSQL assessment reports with a premium "Deep Sea" interface, a **Zero Knowledge (ZK) collection system** for offline audit delivery, and a **System Health collector** for OS-level diagnostics. Supports live generation, offline replay from JSON bundles, and standalone system snapshots — no persistent access to the target required.

---

## Table of Contents

1. [Report Overview](#report-overview)
2. [Live Generation — Direct psql](#live-generation--direct-psql)
3. [Zero Knowledge (ZK) Collection System](#zero-knowledge-zk-collection-system)
   - [What it collects](#what-it-collects)
   - [How to collect](#how-to-collect)
   - [Bundle contents](#bundle-contents)
4. [Offline Replay](#offline-replay)
   - [How to replay](#how-to-replay)
   - [How it works](#how-it-works)
5. [System Health Report](#system-health-report)
   - [What it collects](#what-it-collects-1)
   - [Client quick start](#client-quick-start-no-expert-required)
   - [How to generate](#how-to-generate)
6. [JSON Export for LLM](#json-export-for-llm)
   - [Usage](#usage)
   - [JSON structure](#json-structure)
   - [Suggested LLM prompt](#suggested-llm-prompt)
7. [Version Compatibility Matrix](#version-compatibility-matrix)
8. [Limitations](#limitations)
9. [Use Cases](#use-cases)
10. [Prerequisites](#prerequisites)
11. [UI Features](#ui-features)

---

> **v2.0 highlights** — The collector now captures **every database in the cluster** in a single run and embeds the PostgreSQL major version in the bundle directory name (`zk_audit_PG17_YYYYMMDD_HHMMSS`). Per-database files (`catalog_db_<db>.json`, `stat_db_<db>.json`) are written into one bundle; the replayer generates a dedicated report pair for each database. Legacy v1.0 bundles (`catalog_snapshot.json` / `stat_snapshot.json`) are still supported transparently.

---

## Report Overview

| File | Purpose | Compatibility |
|------|---------|---------------|
| `ultimate_report.sql` | Full health and structural audit — infrastructure, schema, security, XID wraparound, bloat, missing indexes, FK gaps | PG 12 – 18 |
| `ultimate_report_json.sql` | Same audit as above, JSON output for LLM ingestion | PG 12 – 18 |
| `pg_perf_report.sql` | Query-level performance deep-dive — CPU, I/O, WAL, planning, JIT, cache miss | PG 13 – 18 |
| `pg_perf_report_json.sql` | Same performance data, JSON output for LLM ingestion | PG 13 – 18 |
| `ultimate_report_pg19.sql` | Experimental audit for PG 19 features — `pg_stat_lock`, `pg_stat_recovery`, autovacuum parallel | PG 19 (experimental) |

The HTML reports are self-contained: no external CDN, no internet required. All CSS and JavaScript are embedded inline. JSON companions use the same CTEs — no duplication of collection logic.

---

## Live Generation — Direct psql

```bash
# Full audit (PG12-18)
psql -A -t -q -d mydb -f ultimate_report.sql -o audit.html

# Performance deep-dive (PG13-18)
psql -A -t -q -d mydb -f pg_perf_report.sql -o perf.html

# PG19 experimental
psql -A -t -q -d mydb -f ultimate_report_pg19.sql -o audit_pg19.html
```

The scripts use internal `\pset` directives (`format html`, `tuples_only on`, `footer off`) so all four flags (`-A -t -q`) are necessary to strip psql metadata wrappers from the output.

### With connection flags

```bash
psql -h db.internal -p 5432 -U readonly -d mydb \
     -A -t -q -f ultimate_report.sql -o audit.html
```

### Minimum required privileges

| Feature | Minimum role |
|---------|-------------|
| Core metrics | `pg_read_all_stats` (PG10+) or `pg_monitor` |
| WAL / archiver details | `pg_read_all_stats` |
| `pg_stat_statements` | Extension must be loaded; no extra role needed |
| Security section (`pg_roles`) | Superuser or `pg_read_all_settings` |

Sections that lack permission return "N/A" or "No data" instead of failing the entire script.

---

## Zero Knowledge (ZK) Collection System

The ZK system lets you audit a PostgreSQL **cluster** (all databases) **without extracting user data**. It captures schema structure, catalog metadata, and statistical counters — nothing from actual application tables — then bundles the result into a portable JSON snapshot.

The bundle can be transported to another machine and replayed against a local PostgreSQL instance (any version) to generate the full HTML reports without any further access to the target server.

```
Target cluster (postgres:5432)          Consultant / CI machine
──────────────────────────────          ──────────────────────────────────────
zk_collect.sh   ──bundle──►  zk_replay.sh
(all databases,               (one report pair per database)
 one bundle dir)               ↓
                         offline_ultimate_report_mydb.html
                         offline_perf_report_mydb.html
                         offline_ultimate_report_analytics.html
                         offline_perf_report_analytics.html
                         ...
```

**Bundle directory name** embeds the PostgreSQL major version for traceability:
```
zk_audit_PG17_20260508_143022/   ← collected from a PG 17 cluster
zk_audit_PG16_20260508_143022/   ← collected from a PG 16 cluster
```

### What it collects

One file pair is written **per database** in the cluster. The schema below applies to each file. File names follow the pattern `catalog_db_<dbname>.json` and `stat_db_<dbname>.json`.

**`catalog_db_<dbname>.json`** (via `zk_catalog_dump.sql`)

| Section | Contents |
|---------|----------|
| `databases` | Names, encoding, collation, size, XID age |
| `schemas` | Schema names and owners |
| `tables` | Schema, name, row estimate, size bytes, `relpages`, `relfrozenxid` |
| `columns` | Name, type, nullability, default, alignment, storage |
| `indexes` | Name, columns (`indkey`/`indclass`/`indoption`), uniqueness, validity, size |
| `constraints` | Type, column keys, referenced table |
| `unindexed_fks` | Pre-computed: FK constraints with no matching index |
| `sequences` | Last value, min/max, increment, cycle |
| `views` | Names and owning schema |
| `functions_summary` | Count per schema/language |
| `roles` | Name, flags (super/replication/login), password type (`md5`/`scram`/`none`) — **never the hash** |
| `settings_key` | ~40 key GUCs (shared_buffers, wal_level, autovacuum settings, etc.) |
| `planner_stats` | Per-column: `null_frac`, `avg_width`, `n_distinct`, `correlation` — no actual data |
| `bloat_computed` | Pre-computed table/index bloat estimates |
| `available_extensions` | Installable extension list + installed versions |
| `_meta` | Block size, autovacuum_freeze_max_age, collection timestamp, **pg_version** |

**`stat_db_<dbname>.json`** (via `zk_stat_dump.sql`)

| Section | Contents |
|---------|----------|
| `stat_statements` | Top queries: timing, row counts, block I/O, WAL, plan time, JIT — **no bind parameters** |
| `stat_tables` | Per-table: scan counts, tuple counts, dead tuples, vacuum/analyze timestamps |
| `statio_tables` | Per-table: buffer hit/read counts, cache hit ratio |
| `stat_indexes` | Per-index: scan count, tuple reads, size, uniqueness |
| `stat_bgwriter` / `stat_checkpointer` | Checkpoint timing, buffer allocation (PG17+ split) |
| `stat_database` | Per-database: transactions, cache hits, temp files, deadlocks |
| `stat_replication` | Standby state, LSN positions, lag intervals |
| `replication_slots` | Slot name, type, WAL retained bytes |
| `activity_summary` | Connection counts by state — **no query text** |
| `blocking_sessions` | Blocked PIDs, wait events, truncated query snippets (200 chars) |
| `locks_summary` | Lock counts by type and mode — no row-level details |
| `bloat_estimate` | Dead tuple ratio per table from `pg_stat_user_tables` |
| `dup_indexes` | Pre-computed duplicate index groups |
| `unused_indexes` | Zero-scan indexes with size |
| `missing_index_candidates` | High seq-scan, large tables without indexes |
| `stat_archiver` | WAL archive success/failure counts |
| `stat_progress_vacuum` | In-flight vacuum progress (snapshot at collection time) |
| `_meta` | PG version, uptime, cluster role, current WAL LSN |

**`schema_dump_<dbname>.sql`** — DDL only (`pg_dump --schema-only`), no data.

**`statistics_dump_<dbname>.sql`** — Planner statistics objects (`pg_dump --statistics-only`, PG18+ only).

**`manifest.json`** — Collection metadata: timestamp, PG major version (`pg_major`), databases array, file inventory with sizes.

### How to collect

Both `zk_collect.ps1` (PowerShell, Windows) and `zk_collect.sh` (bash, Linux/macOS/WSL) are provided. They are feature-identical and produce the same bundle format.

By default the collector discovers **all connectable databases** in the cluster (excluding `template0` and `template1`) and collects them in a single bundle. Use `--database` / `-Database` to restrict collection to one database.

**Collect entire cluster — all databases (recommended):**
```bash
# bash
./zk_collect.sh --host localhost --port 5432 --user postgres
# → zk_audit_PG17_20260508_143022/
#     catalog_db_postgres.json
#     catalog_db_myapp.json
#     catalog_db_analytics.json
#     stat_db_postgres.json
#     stat_db_myapp.json
#     stat_db_analytics.json
#     manifest.json
```
```powershell
# PowerShell
.\zk_collect.ps1 -PgHost localhost -Port 5432 -User postgres
```

**Single-database collection (backward compat / targeted):**
```bash
# bash
./zk_collect.sh --host localhost --database mydb --user postgres
# → zk_audit_PG17_20260508_143022/
#     catalog_db_mydb.json
#     stat_db_mydb.json
#     manifest.json
```
```powershell
# PowerShell
.\zk_collect.ps1 -PgHost localhost -Database mydb -User postgres
```

**With password / custom output:**
```bash
# bash
./zk_collect.sh --host db.example.com --user readonly \
                --password secret --output-dir ./audit_bundle
```
```powershell
# PowerShell
.\zk_collect.ps1 -PgHost db.example.com -User readonly `
                 -Password secret -OutputDir ./audit_bundle
```

**Docker container (entire cluster):**
```bash
# bash
./zk_collect.sh --docker-container my-postgres-container --user postgres
```
```powershell
# PowerShell
.\zk_collect.ps1 -DockerContainer my-postgres-container -User postgres
```

**Skip DDL dump (stats only):**
```bash
./zk_collect.sh --docker-container my-pg --no-schema-dump
```
```powershell
.\zk_collect.ps1 -DockerContainer my-pg -NoSchemaDump
```

The output directory is auto-named `zk_audit_PG<MAJOR>_YYYYMMDD_HHMMSS` if not set.

### Bundle contents

**Multi-database bundle (v2.0, default):**
```
zk_audit_PG17_20260508_143022/
├── catalog_db_postgres.json       ~9 KB    schema, indexes, roles, settings
├── catalog_db_myapp.json          ~80 KB   "
├── catalog_db_analytics.json      ~45 KB   "
├── stat_db_postgres.json          ~34 KB   query stats, table stats, bloat
├── stat_db_myapp.json             ~200 KB  "
├── stat_db_analytics.json         ~140 KB  "
├── schema_dump_myapp.sql          ~20 KB   DDL (pg_dump --schema-only)
├── schema_dump_analytics.sql      ~12 KB   "
├── statistics_dump_myapp.sql      ~38 KB   planner stats (PG18+ only)
└── manifest.json                  ~1 KB    pg_major, databases[], file inventory
```

**`manifest.json` structure:**
```json
{
  "collected_at": "2026-05-08T14:30:22Z",
  "pg_version": "PostgreSQL 17.4 ...",
  "pg_major": 17,
  "databases": ["postgres", "myapp", "analytics"],
  "files": { "catalog_db_myapp.json": 81920, ... }
}
```

**Single-database bundle** (when `--database` is specified):
```
zk_audit_PG17_20260508_143022/
├── catalog_db_mydb.json
├── stat_db_mydb.json
├── schema_dump_mydb.sql
└── manifest.json
```

**Legacy v1.0 bundle** (collected before v2.0, still replayed automatically):
```
zk_audit_20260508_143022/
├── catalog_snapshot.json
├── stat_snapshot.json
└── manifest.json
```

Typical total size: **250–400 KB per database**; a 3-database cluster is typically **700 KB – 1.2 MB**.

---

## Offline Replay

Once you have a bundle, run the audit reports against a local PostgreSQL instance (any version, any database) without the target server being accessible at all. **One report pair is generated per database in the bundle.**

### How to replay

Both `zk_replay.ps1` (PowerShell, Windows) and `zk_replay.sh` (bash, Linux/macOS/WSL) are provided. Both automatically detect v2.0 multi-database bundles and legacy v1.0 single-database bundles.

**Against a Docker container (recommended for isolation):**
```bash
# bash — multi-database bundle
./zk_replay.sh --bundle ./zk_audit_PG17_20260508_143022 \
               --docker-container pg-replay \
               --output-dir ./reports
# → reports/offline_ultimate_report_postgres.html
# → reports/offline_perf_report_postgres.html
# → reports/offline_ultimate_report_myapp.html
# → reports/offline_perf_report_myapp.html
# → reports/offline_ultimate_report_analytics.html
# → reports/offline_perf_report_analytics.html
```
```powershell
# PowerShell
.\zk_replay.ps1 -Bundle .\zk_audit_PG17_20260508_143022 `
                -DockerContainer pg-replay `
                -OutputDir .\reports
```

**Against a local PostgreSQL:**
```bash
./zk_replay.sh --bundle ./zk_audit_PG17_20260508_143022
```
```powershell
.\zk_replay.ps1 -Bundle .\zk_audit_PG17_20260508_143022
```

**JSON output (for LLM ingestion):**
```bash
./zk_replay.sh --bundle ./zk_audit_PG17_20260508_143022 \
               --docker-container pg-replay --json
# → reports/offline_ultimate_report_myapp.json
# → reports/offline_perf_report_myapp.json
```

**Legacy v1.0 bundle (backward compat — no changes needed):**
```bash
./zk_replay.sh --bundle ./zk_audit_20260508_143022
# Detected as legacy v1.0 → produces:
# → offline_ultimate_report.html
# → offline_perf_report.html
```

Output files written to `--output-dir` (defaults to the bundle directory).

**Output naming:**

| Bundle format | Report files |
|--------------|-------------|
| v2.0 multi-DB | `offline_ultimate_report_<dbname>.html/json` per database |
| v1.0 legacy | `offline_ultimate_report.html/json` (no suffix) |

### How it works

The replayer (`zk_replay.sh` / `zk_replay.ps1`) performs these steps **for each database** in the bundle:

1. **Detect bundle format** — Scans for `catalog_db_*.json` (v2.0) or `catalog_snapshot.json` (legacy v1.0). Processes all databases found.

2. **Load JSON** — Reads `catalog_db_<db>.json` and `stat_db_<db>.json` and inserts them into temporary staging tables (`_zk_catalog`, `_zk_stat`) using PostgreSQL dollar-quoting.

3. **Build shadow schema** (`zk_ingest.sql`) — Creates a `zk` schema with shadow views and functions that expose the bundled data through the same interface as live PostgreSQL system catalogs:
   - `zk.pg_stat_statements` — all version-variant column names unified via `COALESCE`
   - `zk.pg_class`, `zk.pg_namespace` — backed by OID-fabricated tables from catalog JSON
   - `zk.pg_database`, `zk.pg_settings`, `zk.pg_roles`, `zk.pg_sequences` — from catalog JSON
   - `zk.pg_stat_user_tables`, `zk.pg_statio_user_tables`, `zk.pg_stat_user_indexes` — from stat JSON
   - `zk.pg_is_in_recovery()`, `zk.pg_current_wal_lsn()`, `zk.current_setting()` — shadow functions returning values from `_meta`

4. **Run reports** — Executes `ultimate_report.sql` and `pg_perf_report.sql` with `search_path = zk, pg_catalog, public`. All unqualified catalog references resolve to the shadow `zk` schema transparently. The reports require no modification.

5. **Output** — Each report is run with psql `-o` to capture the full HTML/JSON output, suffixed with the database name.

---

## System Health Report

A separate OS-level assessment that runs independently of PostgreSQL. Collects raw system metrics and generates a self-contained HTML report with color-coded findings and recommendations.

```
Server / VM / Container
────────────────────────
sys_collect.sh   ──bundle──►  sys_report.sh
(collect once)                (generate anytime)
                               ↓
                         sys_report.html
```

### What it collects

| Section | Tools used | Fallback |
|---------|-----------|---------|
| CPU info & topology | `lscpu`, `nproc` | `/proc/cpuinfo` |
| CPU usage & I/O wait | `vmstat 1 5`, `mpstat` | `/proc/stat` |
| Load average | `/proc/loadavg` | `uptime` |
| Memory detail | `/proc/meminfo`, `free -m`, `vmstat -s` | always available |
| Huge pages & THP | `/proc/meminfo`, sysctl, `/sys/kernel/mm/transparent_hugepage` | graceful skip |
| Disk usage | `df -h`, `lsblk` | always available |
| I/O statistics | `iostat -x 1 5` (sysstat) | `/proc/diskstats` snapshots |
| Mount options | `findmnt`, `/etc/fstab` | `/proc/mounts` |
| Kernel parameters | `sysctl` — vm.\*, net.\*, kernel.shm\*, fs.file-max | `/proc/sys/*` |
| Network interfaces | `ip -s link`, `/proc/net/dev` | `ifconfig` |
| Network throughput | `sar -n DEV 1 5` (sysstat) | `/proc/net/dev` snapshots |
| Sockets & ports | `ss -s`, `ss -tuln` | `netstat` |
| Top processes | `ps aux` by CPU and memory | always available |
| Running services | `systemctl list-units` | `ps aux` |
| Docker containers | `docker ps`, `docker stats` | graceful skip |
| Kernel events | `dmesg --level=err,warn` | graceful skip (root needed) |
| Security posture | SELinux/AppArmor, iptables/nft, ASLR | partial |

**Findings automatically checked:**
- Load average vs CPU count (saturated / warning / OK)
- I/O wait % (bottleneck / warning / OK)
- Memory usage % (critical / warning / OK)
- Swap activity (active / no swap configured)
- `vm.swappiness` (PostgreSQL recommends 1–10; warns if > 10)
- Transparent Huge Pages (warns if `always`; recommends `never` or `madvise`)
- Huge pages not configured (TLB pressure info)
- `vm.dirty_ratio` too high (warns if > 40)
- `vm.overcommit_memory=1` (OOM kill risk)
- `net.core.somaxconn` too low (< 4096)
- Network errors / drops > 0
- Disk usage ≥ 80% (warning), ≥ 90% (critical)

---

### Client Quick Start (no expert required)

> **Send these two files to your client and ask them to run the following commands. No PostgreSQL access, no root strictly required (some sections need sudo for sysctl/dmesg).**

```bash
# 1. Copy the scripts to the target server
scp sys_collect.sh sys_report.sh user@server:~

# 2. SSH into the server and run the collector
ssh user@server
bash sys_collect.sh              # collects everything, auto-names output dir

# 3. (Optional) Generate the HTML report locally too
bash sys_report.sh --bundle sys_HOSTNAME_YYYYMMDD_HHMMSS

# 4. Compress and send the bundle
zip -r sys_bundle.zip sys_HOSTNAME_YYYYMMDD_HHMMSS/
```

The bundle is typically **50–200 KB**. The consultant runs `sys_report.sh --bundle` on their own machine to generate the HTML report without needing any further server access.

**Permissions needed:**
- Regular user: CPU, memory, disk, network, processes, ports (most sections)
- Root / sudo: `sysctl` full dump, `dmesg` kernel events, `iptables`

**Tools needed on the target server (all optional — script degrades gracefully):**
```bash
# Debian / Ubuntu
apt-get install -y sysstat iproute2 procps

# RHEL / CentOS
yum install -y sysstat iproute procps-ng
```

---

### How to generate

**Collect on the local machine:**
```bash
./sys_collect.sh
./sys_report.sh --bundle sys_HOSTNAME_YYYYMMDD_HHMMSS
```

**Collect inside a Docker container:**
```bash
./sys_collect.sh --docker-container my-postgres-container
./sys_report.sh  --bundle sys_HOSTNAME_YYYYMMDD_HHMMSS
```

**Collect from a remote server via SSH:**
```bash
./sys_collect.sh --ssh db.example.com --ssh-user root
./sys_report.sh  --bundle sys_db_YYYYMMDD_HHMMSS
```

**Custom output path:**
```bash
./sys_collect.sh --output-dir /tmp/my_bundle
./sys_report.sh  --bundle /tmp/my_bundle --output /tmp/my_bundle/report.html
```

**Full parameter reference:**

`sys_collect.sh`:
| Parameter | Default | Description |
|-----------|---------|-------------|
| `--output-dir DIR` | `sys_HOST_YYYYMMDD_HHMMSS` | Output directory |
| `--docker-container NAME` | — | Collect inside Docker container |
| `--ssh HOST` | — | Collect via SSH |
| `--ssh-user USER` | `root` | SSH username |
| `--ssh-port PORT` | `22` | SSH port |
| `--ssh-key FILE` | — | SSH private key |

`sys_report.sh`:
| Parameter | Default | Description |
|-----------|---------|-------------|
| `--bundle DIR` | **required** | Path to sys_collect output |
| `--output FILE` | `BUNDLE/sys_report.html` or `.json` | Output file |
| `--json` | off | Emit JSON instead of HTML |

---

## JSON Export for LLM

All three report types can output structured JSON instead of HTML. Feed the JSON directly into an LLM (ChatGPT, Claude, Gemini, local models) to generate a plain-language diagnosis, compare environments, or automate triage.

### Architecture

```
ZK bundle (v2.0)                  Replay container                    LLM
────────────────                  ────────────────                    ───
catalog_db_myapp.json  ─► offline_ultimate_report_myapp.json ─►
stat_db_myapp.json     ─► offline_perf_report_myapp.json     ─► diagnosis
catalog_db_analytics.json ► offline_ultimate_report_analytics.json ─►
stat_db_analytics.json   ─► offline_perf_report_analytics.json    ─►
                                                                    ─►
sys_collect bundle     ─► sys_report.json                          ─►
```

### Files

| Report | JSON companion | Output |
|--------|---------------|--------|
| Ultimate Audit | `ultimate_report_json.sql` | Same CTEs as HTML, single JSON object |
| Performance | `pg_perf_report_json.sql` | All pg_stat_statements sections as arrays |
| System Health | `sys_report.sh --json` | Parsed OS metrics + findings array |

The JSON SQL companions work in both **live** mode (direct psql) and **offline** (ZK shadow schema via `search_path = zk`).

### Usage

**ZK offline replay → JSON:**
```bash
# Bash (Linux / WSL) — multi-database bundle
./zk_replay.sh --bundle ./zk_audit_PG17_20260508_143022 \
               --docker-container pg-test-report \
               --json

# Output (one pair per database)
# reports/offline_ultimate_report_postgres.json
# reports/offline_perf_report_postgres.json
# reports/offline_ultimate_report_myapp.json
# reports/offline_perf_report_myapp.json
```

**PowerShell:**
```powershell
.\zk_replay.ps1 -Bundle .\zk_audit_PG17_20260508_143022 `
                -DockerContainer pg-test-report `
                -Json
```

**Live generation (direct psql):**
```bash
# Ultimate audit JSON
psql -h db -U postgres -d mydb -A -t -q \
     -f ultimate_report_json.sql -o audit.json

# Performance JSON
psql -h db -U postgres -d mydb -A -t -q \
     -f pg_perf_report_json.sql -o perf.json
```

**System health JSON:**
```bash
# Collect first (if needed)
./sys_collect.sh --output-dir ./sys_bundle

# Generate JSON
./sys_report.sh --bundle ./sys_bundle --json
# → sys_bundle/sys_report.json
```

### JSON structure

**Ultimate Audit (`offline_ultimate_report.json`):**
```json
{
  "report": "ultimate_audit",
  "pg_version": "17.4",
  "generated_at": "2026-05-08T20:18:51Z",
  "buffer_hit_ratio_pct": 99.7,
  "extensions": [...],
  "databases": [...],
  "archiving": {"status": "OK", "archived_count": 0, ...},
  "replication": {"status": "PRIMARY_NO_REPLICAS", ...},
  "replication_slots": [],
  "bloat": [{"schemaname":"public","tablename":"events","tbloat":3.1,"wasted":"942 MB"}],
  "duplicate_indexes": [],
  "inefficient_indexes": [],
  "missing_indexes": [...],
  "unindexed_fk": [...],
  "wraparound_risk": [],
  "blocking_locks": [],
  "roles_security": [...],
  "sequences_at_risk": [],
  "critical_settings": [{"name":"fsync","setting":"on","risk":"OK"}, ...]
}
```

**Performance (`offline_perf_report.json`):**
```json
{
  "report": "performance",
  "pg_version": "17.4",
  "top_cpu": [{"query":"...", "calls":1200, "cpu_time_ms":191776, "pct_cpu":100.0}],
  "top_io": [...],
  "top_planning": [...],
  "top_wal": [...],
  "top_freq": [...],
  "top_heavy": [...],
  "top_jitter": [...],
  "top_temp_files": [...],
  "top_cache_miss": [...],
  "stats_meta": {"dealloc":0, "stats_reset":"..."}
}
```

**System Health (`sys_report.json`):**
```json
{
  "report": "system_health",
  "host": {"hostname":"db01","os":"Ubuntu 22.04","kernel":"6.8.0"},
  "cpu": {"model":"Intel Xeon E5-2680","logical_cpus":"16","load_1m":"2.1","avg_iowait_pct":"18"},
  "memory": {"total_kb":32768000,"used_kb":28000000,"used_pct":85},
  "kernel": {"vm_swappiness":"60","vm_dirty_ratio":"20"},
  "network": {"total_errors":0,"total_drops":0},
  "disk": [{"filesystem":"/dev/sda1","pct":"87%","mount":"/"}],
  "findings": [
    {"level":"orange","category":"IOWAIT WARN","detail":"avg iowait 18% — watch disk latency"},
    {"level":"orange","category":"MEM WARN","detail":"26.7 GB used / 31.2 GB total (85%)"}
  ]
}
```

### Suggested LLM prompt

```
You are a senior PostgreSQL and Linux performance engineer.
I'm providing you with three JSON reports from a production server audit:
1. PostgreSQL Ultimate Audit (schema, security, bloat, replication)
2. PostgreSQL Performance Report (top queries by CPU, I/O, WAL)
3. System Health Report (CPU, RAM, disk, network, kernel tuning)

Analyze all three. Identify the top 5 issues by risk/impact.
For each issue: explain what it means in plain language, the risk if not fixed,
and give a concrete remediation command or config change.
Format the output as a prioritized action plan.

--- ULTIMATE AUDIT ---
<paste offline_ultimate_report.json>

--- PERFORMANCE REPORT ---
<paste offline_perf_report.json>

--- SYSTEM HEALTH ---
<paste sys_report.json>
```

> **Tip:** For large perf reports (500+ KB), use a model with a large context window (Claude 3.5 Sonnet, GPT-4o, Gemini 1.5 Pro) or summarize the top 3 entries per section before pasting.

---

## Version Compatibility Matrix

### Collection (`zk_collect.ps1` + `zk_stat_dump.sql`)

| PostgreSQL | `pg_stat_statements` | Plan time / WAL | JIT basic | JIT extended | `--statistics-only` |
|-----------|---------------------|-----------------|-----------|--------------|---------------------|
| PG 12 | `total_time` / `mean_time` names | — | — | — | — |
| PG 13 | `total_exec_time` / `_exec_` suffix | plan time + WAL | — | — | — |
| PG 14 | + `toplevel` | + `mean_plan_time`, `plans` | `jit_functions`, `jit_generation_time` | — | — |
| PG 15–16 | unchanged | unchanged | unchanged | `jit_inlining_time`, `jit_optimization_time`, `jit_emission_time` | — |
| PG 17 | `shared_blk_read_time` renamed | + `local_blk_*_time`, `temp_blk_*_time` | unchanged | unchanged | — |
| PG 18 | + `stats_since` | unchanged | unchanged | unchanged | `pg_dump --statistics-only` |

### Live reports

| Report | PG 12 | PG 13 | PG 14 | PG 15 | PG 16 | PG 17 | PG 18 | PG 19 |
|--------|-------|-------|-------|-------|-------|-------|-------|-------|
| `ultimate_report.sql` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `pg_perf_report.sql` | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `ultimate_report_pg19.sql` | — | — | — | — | — | — | — | ✓ |

### Offline replay (`zk_replay.ps1` / `zk_replay.sh`)

The replay target PostgreSQL version (the local instance used to run the reports) can be **any version from PG 12 to PG 18**. The shadow `zk.pg_stat_statements` view normalises all version-variant column names so the reports always receive the column set they expect.

Both replayers support:
- **v2.0 bundles** (`catalog_db_*.json`) — auto-detected; one report pair generated per database
- **Legacy v1.0 bundles** (`catalog_snapshot.json`) — backward compat; single report pair with no database suffix

---

## Limitations

### Offline replay limitations

| Limitation | Detail |
|-----------|--------|
| **Duplicate index detection** | `v_idx_duplicate` in `ultimate_report` requires `pg_index.indkey::regclass` which cannot be resolved against fabricated OIDs. The section returns empty in offline mode. Use the pre-computed `zk.v_dup_indexes_precomputed` view to access this data directly. |
| **FK/unindexed-FK detection** | `v_fk_unindexed` requires `pg_constraint` cross-joins not available in offline mode. The section returns empty. Use `zk.v_unindexed_fks_precomputed` instead. |
| **Live blocking detail** | `pg_blocking_pids()` always returns empty (`{}`) — locking state is a point-in-time snapshot, not a live view. Aggregate lock stats and session summaries are available from `zk.pg_stat_activity`. |
| **Version detection for `\gset`** | The `current_setting('server_version_num')` shadow function reads from bundle `_meta`, so `\if :is_pg17` conditionals in the reports operate on the **target server version**, not the replay host version. |
| **`pg_dump` DDL** | `schema_dump.sql` and `statistics_dump.sql` are included in the bundle but not used during replay — they are for reference / archival. |
| **In-flight vacuum** | `pg_stat_progress_vacuum` returns empty: vacuum state is captured instantaneously and is almost always empty at collection time. |
| **`pg_size_pretty`** | Available and correct — uses the real function from `pg_catalog` since it only formats numbers. |

### Collection limitations

| Limitation | Detail |
|-----------|--------|
| **No user data** | By design. No row data, no column values, no sequence data beyond metadata. |
| **Query text** | `pg_stat_statements` query text is included (it is anonymised parameter-free SQL). Remove or truncate if the SQL itself is sensitive. |
| **Blocking sessions** | Blocking session `query_snippet` captures up to 200 characters of the waiting query. Set `pg_stat_statements.track = none` or use `-NoStatDump` if this is a concern. |
| **Password hashes** | `roles.pwd_type` captures only the hash algorithm type (`md5`, `scram-sha-256`, `none`) — never the actual hash. |
| **Managed cloud (RDS/Aurora/Cloud SQL)** | Collection works but some sections (e.g. `pg_stat_archiver`, WAL LSN functions) may return `PERMISSION_DENIED` for restricted users. Use a role with `pg_read_all_stats`. |

---

## Use Cases

### Consulting delivery — zero access to production
Collect the entire cluster in one run (or have the client run `zk_collect.ps1`), then generate the full audit reports at your desk — one report pair per database — without ever holding a connection open to the client's server.

```
Client runs:  .\zk_collect.ps1 -User readonly
              # → collects ALL databases in the cluster
Client sends: zk_audit_PG17_20260508_143022.zip  (< 1.5 MB for 3 databases)
You run:      .\zk_replay.ps1 -Bundle .\zk_audit_PG17_20260508_143022
You deliver:  offline_ultimate_report_prod.html
              offline_perf_report_prod.html
              offline_ultimate_report_analytics.html
              offline_perf_report_analytics.html
              ...
```

### Multi-database cluster audit
A single collect + replay covers every database in the cluster, including `postgres` (roles, settings, cluster-level stats). Each database gets its own dedicated report pair so you can assess schema isolation, per-database bloat, and query patterns independently.

```bash
./zk_collect.sh --docker-container prod-pg --user postgres
# → zk_audit_PG17_20260508_143022/ with one file pair per database

./zk_replay.sh  --bundle ./zk_audit_PG17_20260508_143022 \
                --docker-container pg-replay --output-dir ./reports
# → reports/ with offline_*_<dbname>.html for every database
```

### CI / scheduled audits
Run `zk_collect.sh` as a scheduled task or CI step, commit bundles to Git (they are small), and replay on any runner to generate and archive reports.

```bash
# Linux / macOS / WSL CI:
./zk_collect.sh --docker-container prod-pg
./zk_replay.sh  --bundle ./zk_audit_PG*_$(date +%Y%m%d)_* --output-dir ./reports
```
```powershell
# Windows / PowerShell CI:
.\zk_collect.ps1 -DockerContainer prod-pg
.\zk_replay.ps1  -Bundle (Get-Item ".\zk_audit_PG*_$(Get-Date -Format yyyyMMdd)*") `
                 -OutputDir .\reports
```

### Air-gapped or restricted environments
Environments where the DBA workstation cannot reach the PostgreSQL host directly (firewall rules, jump hosts, VPN). Collect the bundle inside the network, transfer it out-of-band, replay anywhere.

### Before/after comparison
Collect bundles before and after a migration, index change, or configuration tuning. The PG version and timestamp in the bundle name make it easy to keep snapshots organized for side-by-side comparison.

```bash
./zk_collect.sh --host db --user postgres --output-dir ./before_migration
# run migration
./zk_collect.sh --host db --user postgres --output-dir ./after_migration
# compare offline_perf_report_myapp.html from each bundle
```

### Direct live audit
For environments where you do have direct access, skip the ZK layer and run the reports directly:

```bash
psql -h prod-db -U readonly -d mydb -A -t -q -f ultimate_report.sql -o audit.html
```

---

## Prerequisites

### For live report generation
- `psql` in `PATH` (part of the PostgreSQL client package)
- Role with at minimum `pg_read_all_stats` or `pg_monitor`
- `pg_stat_statements` extension enabled for query-level metrics (optional but recommended)

### For ZK collection

> Full prerequisites (required grants, optional pg_stat_statements) are documented at the top of `zk_catalog_dump.sql` and `zk_stat_dump.sql`.

**`zk_collect.ps1` (Windows / PowerShell):**
- PowerShell 5.1+ — ships with Windows 10/11
- `psql` and `pg_dump` in `PATH` (or Docker container if using `-DockerContainer`)
- Docker CLI in `PATH` if using `-DockerContainer`
- Read-only PostgreSQL role with `pg_read_all_stats` or `pg_monitor` (write access not required)
- `pg_stat_statements` loaded and enabled in `shared_preload_libraries` (optional — query-level metrics only; gracefully skipped if absent)

**`zk_collect.sh` (Linux / macOS / WSL):**
- bash 4.3+
- `psql` and `pg_dump` in `PATH` — install via `apt install postgresql-client` or `brew install libpq`
- Docker CLI in `PATH` if using `--docker-container`
- Read-only PostgreSQL role with `pg_read_all_stats` or `pg_monitor`
- `pg_stat_statements` (optional; gracefully skipped if absent)

### For ZK replay

**`zk_replay.ps1` (Windows / PowerShell):**
- PowerShell 5.1+
- A local PostgreSQL instance accessible via `psql` **or** a Docker container
  - The replay target can be any PG version (12–18)
- The replay target user needs: `CREATE SCHEMA`, `CREATE TABLE`, `CREATE FUNCTION` privileges
- Typically superuser or a dedicated `audit_replay` role is appropriate

**`zk_replay.sh` (Linux / macOS / WSL):**
- bash 4+
- `psql` in `PATH` (`postgresql-client` package) **or** a Docker container for replay
- Same privilege requirements as the PowerShell variant

### Integration test

`test_multidb.sh` is an end-to-end integration test that spins up a `postgres:17` Docker container, creates three realistic test databases (`zktest_app`, `zktest_reporting`, `zktest_legacy`), runs collect + replay, and asserts ~48 checks including multi-database isolation and legacy v1.0 backward compatibility.

```bash
./test_multidb.sh --container zk-test --json
```

### Tested environments

| Environment | Collection | Replay |
|------------|-----------|--------|
| Local PostgreSQL (Windows, Linux, macOS) | ✓ | ✓ |
| Docker container (`docker exec psql`) | ✓ | ✓ |
| AWS RDS / Aurora | ✓ (with `pg_read_all_stats`) | n/a |
| Azure Database for PostgreSQL | ✓ (with `pg_read_all_stats`) | n/a |
| Google Cloud SQL | ✓ (with `pg_read_all_stats`) | n/a |
| Air-gapped server | ✓ | replayed elsewhere |

---

## UI Features

- **Dual-theme**: Premium "Deep Sea" dark mode by default; "Legacy White" mode for accessibility and printing
- **Bilingual (EN/FR)**: Instant client-side translation of all UI elements and technical labels
- **Query expansion**: Click any truncated SQL query, or use the global **SHORT / LONG** toggle to expand all queries at once
- **Sticky headers**: Column headers remain visible when scrolling long tables
- **Back-to-top**: Smooth scroll navigation for long reports
- **Copy-to-clipboard**: Copy query snippets directly from report rows
- **Visual risk indicators**: Color-coded badges — red (critical), orange (warning), blue (info)
- **Version badges**: Dynamic PostgreSQL version shown in the report header
- **Self-contained**: All CSS and JavaScript are embedded inline; reports open in any browser with no internet dependency
