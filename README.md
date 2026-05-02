# 📊 PostgreSQL Modern Assessment Reports

Standardized and modernized PostgreSQL assessment reports featuring a premium "Deep Sea" interface. These reports are designed to provide a professional, data-first experience for database administrators and consultants, supporting both **English** and **French** languages.

---

## ✨ Key Features

- **🌓 Dual-Theme System**: Premium "Deep Sea" dark mode by default, with a "Legacy White" mode for accessibility and printing.
- **🌍 Bilingual Support (EN/FR)**: Instant client-side translation of all UI elements, card headers, and technical labels.
- **🚀 Interactive UX**: 
  - **Query Expansion**: Click any truncated SQL query to reveal the full text.
  - **Sticky Headers**: Keep track of columns even in very long tables.
  - **Back-to-Top**: Smooth scrolling navigation for deep-dive reports.
- **🎨 Visual Risk Indicators**: Color-coded badges (Red for critical, Orange for warnings, Blue for info) to highlight audit findings immediately.

---

## 📄 Report Overview

### 1. `pg17_perf_report.sql`
A comprehensive performance dashboard optimized for PostgreSQL 17.
- **Metrics**: Top CPU consumers, Disk I/O latency, WAL generation, Planning time, Jitter, and JIT overhead.
- **Goal**: Identify query-level bottlenecks with precision.

### 2. `ultimate_report.sql`
A deep-dive structural audit report that returns a single, self-contained HTML document.
- **Sections**: Tables & Storage (Bloat), Index Health (Duplicates/Unused), Schema Quality (Missing FKs), Maintenance (Sequence saturation), and Security (Security Definer functions, Roles).

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

If you want to visualize the UI without connecting to a live database, use the provided mock samples:

- **Performance Preview**: `pg17_perf_report_test.html`
- **Audit Preview**: `ultimate_report_test.html`

> [!TIP]
> Open these files in any modern browser. You can toggle the **Language (🌍)** and **Theme (🌞/🌙)** in the header to preview the different states.

---

## ⚙️ Configuration Notes
The scripts include internal `\pset` commands to handle rendering:
- `\set quiet on`: Suppresses internal psql messages during generation.
- `\pset format html`: Used in the performance report to let psql natively render result sets as HTML tables.
- **Self-Contained**: All CSS and JavaScript are injected directly into the output. No external internet connection or dependencies are required to view the reports.
