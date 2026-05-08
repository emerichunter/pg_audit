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

The ZK system lets you audit a PostgreSQL instance **without extracting user data**. It captures schema structure, catalog metadata, and statistical counters — nothing from actual application tables — then bundles the result into a portable JSON snapshot.

The bundle can then be transported to another machine and replayed against a local PostgreSQL instance (any version) to generate the full HTML reports without any further access to the target server.

```
Target server                  Consultant / CI machine
─────────────                  ──────────────────────
zk_collect.ps1   ──bundle──►  zk_replay.ps1
(collect once)                (replay anytime, offline)
                               ↓
                         offline_ultimate_report.html
                         offline_perf_report.html
```

### What it collects

**`catalog_snapshot.json`** (via `zk_catalog_dump.sql`)

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
| `_meta` | Block size, autovacuum_freeze_max_age, collection timestamp |

**`stat_snapshot.json`** (via `zk_stat_dump.sql`)

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

**`schema_dump.sql`** — DDL only (`pg_dump --schema-only`), no data.

**`statistics_dump.sql`** — Planner statistics objects (`pg_dump --statistics-only`, PG18+ only).

**`manifest.json`** — Collection metadata: timestamp, PG version, file inventory with sizes.

### How to collect

Both `zk_collect.ps1` (PowerShell, Windows) and `zk_collect.sh` (bash, Linux/macOS/WSL) are provided. They are feature-identical and produce the same bundle format.

**Local PostgreSQL (PowerShell):**
```powershell
.\zk_collect.ps1 -PgHost localhost -Port 5432 -Database mydb -User postgres
```

**Local PostgreSQL (bash):**
```bash
./zk_collect.sh --host localhost --port 5432 --database mydb --user postgres
```

**With password / custom output:**
```powershell
# PowerShell
.\zk_collect.ps1 -PgHost db.example.com -User readonly `
                 -Password secret -OutputDir ./audit_bundle
```
```bash
# bash
./zk_collect.sh --host db.example.com --user readonly \
                --password secret --output-dir ./audit_bundle
```

**Docker container:**
```powershell
# PowerShell
.\zk_collect.ps1 -DockerContainer my-postgres-container `
                 -Database mydb -User postgres
```
```bash
# bash
./zk_collect.sh --docker-container my-postgres-container \
                --database mydb --user postgres
```

**Skip DDL dump (stats only):**
```powershell
.\zk_collect.ps1 -DockerContainer my-pg -NoSchemaDump
```
```bash
./zk_collect.sh --docker-container my-pg --no-schema-dump
```

The output directory is auto-named `zk_audit_YYYYMMDD_HHMMSS` if not set.

### Bundle contents

```
zk_audit_20260508_143022/
├── catalog_snapshot.json    ~80 KB   schema, indexes, roles, settings
├── stat_snapshot.json       ~140 KB  query stats, table stats, bloat
├── schema_dump.sql          ~20 KB   DDL structure (pg_dump --schema-only)
├── statistics_dump.sql      ~38 KB   planner stats (PG18+ only)
└── manifest.json            ~1 KB    collection metadata
```

Typical total size: **250–400 KB** for a moderately sized database.

---

## Offline Replay

Once you have a bundle, run the two audit reports against a local PostgreSQL instance (any version, any database) without the target server being accessible at all.

### How to replay

Both `zk_replay.ps1` (PowerShell, Windows) and `zk_replay.sh` (bash, Linux/macOS/WSL) are provided.

**Against a local PostgreSQL (PowerShell):**
```powershell
.\zk_replay.ps1 -Bundle .\zk_audit_20260508_143022
```

**Against a local PostgreSQL (bash):**
```bash
./zk_replay.sh --bundle ./zk_audit_20260508_143022
```

**Against a Docker container:**
```powershell
# PowerShell
.\zk_replay.ps1 -Bundle .\zk_audit_20260508_143022 `
                -DockerContainer pg-test-report `
                -OutputDir .\reports
```
```bash
# bash
./zk_replay.sh --bundle ./zk_audit_20260508_143022 \
               --docker-container pg-test-report \
               --output-dir ./reports
```

**Full parameter set:**
```powershell
.\zk_replay.ps1 `
  -Bundle       .\zk_audit_20260508_143022 `
  -PgHost       localhost `
  -Port         5432 `
  -Database     postgres `
  -User         postgres `
  -Password     secret `
  -DockerContainer "" `
  -OutputDir    .\reports
```

Output files written to `OutputDir` (defaults to the bundle directory):
- `offline_ultimate_report.html`
- `offline_perf_report.html`

### How it works

The replay orchestrator (`zk_replay.ps1`) performs four steps:

1. **Load JSON** — Reads `catalog_snapshot.json` and `stat_snapshot.json` from the bundle and inserts them into temporary staging tables (`_zk_catalog`, `_zk_stat`) using PostgreSQL dollar-quoting.

2. **Build shadow schema** (`zk_ingest.sql`) — Creates a `zk` schema containing shadow views and functions that expose the bundled data through the same interface as live PostgreSQL system catalogs:
   - `zk.pg_stat_statements` — all version-variant column names unified via `COALESCE`
   - `zk.pg_class`, `zk.pg_namespace` — backed by OID-fabricated tables from catalog JSON
   - `zk.pg_database`, `zk.pg_settings`, `zk.pg_roles`, `zk.pg_sequences` — from catalog JSON
   - `zk.pg_stat_user_tables`, `zk.pg_statio_user_tables`, `zk.pg_stat_user_indexes` — from stat JSON
   - `zk.pg_is_in_recovery()`, `zk.pg_current_wal_lsn()`, `zk.current_setting()` — shadow functions returning values from `_meta`

3. **Run reports** — Executes `ultimate_report.sql` and `pg_perf_report.sql` with `search_path = zk, pg_catalog, public`. With this search path, all unqualified catalog references (`pg_stat_statements`, `pg_database`, etc.) resolve to the shadow `zk` schema transparently. The reports require no modification.

4. **Output HTML** — Each report is run with psql `-o` to capture the full HTML output.

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
ZK bundle                 Replay container              LLM
──────────                ─────────────────             ───
catalog_snapshot.json  ─► offline_ultimate_report.json ─►
stat_snapshot.json     ─► offline_perf_report.json     ─► diagnosis
                                                        ─►
sys_collect bundle     ─► sys_report.json              ─►
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
# Bash (Linux / WSL)
./zk_replay.sh --bundle ./my_bundle \
               --docker-container pg-test-report \
               --json

# Output
# zk_json_reports/offline_ultimate_report.json
# zk_json_reports/offline_perf_report.json
```

**PowerShell:**
```powershell
.\zk_replay.ps1 -Bundle .\my_bundle `
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

### Offline replay (`zk_replay.ps1`)

The replay target PostgreSQL version (the local instance used to run the reports) can be **any version from PG 12 to PG 18**. The shadow `zk.pg_stat_statements` view normalises all version-variant column names so the reports always receive the column set they expect.

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
Collect a bundle on-site (or have the client run `zk_collect.ps1`), then generate the full HTML audit reports at your desk without ever holding a connection open to the client's server.

```
Client runs:  .\zk_collect.ps1 -Database prod -User readonly
Client sends: zk_audit_20260508_143022.zip  (< 500 KB)
You run:      .\zk_replay.ps1 -Bundle .\zk_audit_20260508_143022
You deliver:  offline_ultimate_report.html + offline_perf_report.html
```

### CI / scheduled audits
Run `zk_collect.ps1` as a scheduled task or CI step, commit bundles to Git (they are tiny), and replay on any runner to generate and archive reports.

```powershell
# Windows / PowerShell CI:
.\zk_collect.ps1 -DockerContainer prod-pg -OutputDir ./audit_$(Get-Date -Format yyyyMMdd)
.\zk_replay.ps1  -Bundle ./audit_$(Get-Date -Format yyyyMMdd) -OutputDir ./reports
```
```bash
# Linux / macOS / WSL CI:
./zk_collect.sh --docker-container prod-pg --output-dir ./audit_$(date +%Y%m%d)
./zk_replay.sh  --bundle ./audit_$(date +%Y%m%d) --output-dir ./reports
```

### Air-gapped or restricted environments
Environments where the DBA workstation cannot reach the PostgreSQL host directly (firewall rules, jump hosts, VPN). Collect the bundle inside the network, transfer it out-of-band, replay anywhere.

### Before/after comparison
Collect bundles before and after a migration, index change, or configuration tuning. Keep both reports as HTML snapshots for side-by-side comparison.

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

**`zk_collect.ps1` (Windows / PowerShell):**
- PowerShell 5.1+ — ships with Windows 10/11
- `psql` and `pg_dump` in `PATH` (or Docker container if using `-DockerContainer`)
- Docker CLI in `PATH` if using `-DockerContainer`
- Read-only PostgreSQL role (write access not required)

**`zk_collect.sh` (Linux / macOS / WSL):**
- bash 4+
- `psql` and `pg_dump` in `PATH` — install via `apt install postgresql-client` or `brew install libpq`
- Docker CLI in `PATH` if using `--docker-container`
- Read-only PostgreSQL role (write access not required)

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
