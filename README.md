# 📊 PostgreSQL Modern Assessment Reports

Standardized and modernized PostgreSQL assessment reports featuring a premium "Deep Sea" interface. These reports are designed to provide a professional, data-first experience for database administrators and consultants, supporting both **English** and **French** languages.

---

## ✨ Key Features

- **🌓 Dual-Theme System**: Premium "Deep Sea" dark mode by default, with a "Legacy White" mode for accessibility and printing.
- **🌍 Bilingual Support (EN/FR)**: Instant client-side translation of all UI elements, card headers, and technical labels.
- **🛡️ Robust & Permission-Safe**: Enhanced SQL logic that detects user privileges (e.g., `pg_read_all_stats`) to prevent script crashes on restricted environments (Managed RDS/Azure/GCP).
- **🚀 Interactive UX**: 
  - **Query Expansion**: Click any truncated SQL query to reveal the full text.
  - **Sticky Headers**: Keep track of columns even in very long tables.
  - **Back-to-Top**: Smooth scrolling navigation for deep-dive reports.
- **🎨 Visual Risk Indicators**: Color-coded badges (Red for critical, Orange for warnings, Blue for info) to highlight audit findings immediately.

---

## 📄 Report Overview

### 1. `pg17_perf_report.sql`
A comprehensive performance dashboard optimized for **PostgreSQL 17**.
- **Metrics**: Top CPU consumers, Disk I/O latency, WAL generation, Planning time, Jitter, and JIT overhead.
- **Goal**: Identify query-level bottlenecks with precision.

### 2. `ultimate_report.sql`
The primary health and structural audit engine, consolidating features from legacy DBA toolkits into a single, high-fidelity report.
- **Infrastructure**: WAL Archiving status, Replication lag, and active/inactive slots.
- **Maintenance**: Wraparound risk (XID age), Autovacuum progress tracking, and sequence exhaustion alerts.
- **Real-time Activity**: Locking trees (blockers/waiters) and live vacuum progress.
- **Schema Optimization**: Alignment padding estimation, fragmented primary keys (UUID/Text), and denormalization pattern detection.
- **Security**: Security Definer audit, role privilege checks, and credential validation.

---

## 🚀 Generation Instructions

To generate a professional HTML report without SQL metadata or extraneous characters, use the following `psql` command structure:

### Required `psql` Options:
- **`-A` (or `--no-align`)**: Switches to unaligned output mode. This is crucial for avoiding whitespace padding in the HTML tags.
- **`-t` (or `--tuples-only`)**: Removes column headers and footers from the output. This ensures the output is a clean HTML stream.
- **`-q` (or `--quiet`)**: Prevents `psql` from printing status messages.
- **`-f`**: Specifies the input SQL script.
- **`-o`**: Specifies the output HTML file path.

### Example Commands:

```bash
# Performance Report
psql -A -t -q -d [database_name] -f pg17_perf_report.sql -o performance_report.html

# Ultimate Health Audit
psql -A -t -q -d [database_name] -f ultimate_report.sql -o audit_report.html
```

---

## 🛠️ Testing & Preview

The engine is verified for compatibility with **PostgreSQL 17**. If you want to visualize the UI without connecting to a live database, use the provided mock samples:

- **Performance Preview**: `pg17_perf_report_test.html`
- **Audit Preview**: `audit_report_sample.html` (Generated on PG17)

> [!TIP]
> Open these files in any modern browser. You can toggle the **Language (🌍)** and **Theme (🌞/🌙)** in the header to preview the different states.

---

## ⚙️ Configuration Notes
The scripts include internal `\pset` commands to handle rendering:
- `\set quiet on`: Suppresses internal psql messages during generation.
- `\pset format html`: Used in the performance report to let psql natively render result sets as HTML tables.
- **Self-Contained**: All CSS and JavaScript are injected directly into the output. No external internet connection or dependencies are required.
- **Graceful Failures**: Queries requiring elevated privileges (like `pg_stat_archiver`) are wrapped in existence/permission checks. If unauthorized, the section will simply return "No data" or "N/A" instead of terminating the script.
