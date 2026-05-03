# PostgreSQL Modern Reporting UI

This directory contains modernized, high-fidelity HTML reporting templates for the PostgreSQL Assessment Engine. These reports are designed to provide a premium, data-first experience for database administrators and consultants.

## 🎨 Design Philosophy
- **Premium Aesthetics**: A custom "Deep Sea" dark mode palette using Slate and Navy tones.
- **Modern Typography**: Uses **Inter** for readability and **JetBrains Mono** for SQL code blocks.
- **Interactive UX**: Tables include hover effects, sticky headers, and interactive row expansion for long SQL queries.
- **Visual Cues**: Color-coded risk badges (UNLOGGED, BLOAT, FK MANQUANTE) for instant technical auditing.

## 📄 Key Files

### 1. `pg17_perf_report.sql`
A comprehensive performance dashboard optimized for PostgreSQL 17.
- **Metrics**: Top CPU consumers, Disk I/O latency, WAL generation, Planning time, Jitter, and JIT overhead.
- **Interactive**: Click any query to expand the full SQL text.

### 2. `ultimate_report.sql`
A deep-dive structural audit report that returns a single, self-contained HTML document.
- **Sections**: Storage (Bloat/Fragmentation), Index Health (Duplicates/Unused), Schema Quality (FK issues), Maintenance (Sequence saturation), and Security.

### 3. `sample_report.html`
A standalone, consolidated sample showing the unified design system applied to various audit results.

## 🚀 Generation Instructions

To generate a clean HTML report without any SQL metadata or extraneous characters, run the scripts using `psql` with the following flags:

```bash
# -A: Unaligned output
# -t: Tuples only (no headers/footers)
psql -A -t -f pg17_perf_report.sql > performance_report.html
psql -A -t -f ultimate_report.sql > audit_report.html
```

### Configuration Notes
The SQL files are pre-configured with:
- `\set quiet on` to suppress internal psql messages.
- `\pset format html` (for Performance report) to let psql handle table rendering.
- Custom CSS injected directly into the output for a zero-dependency, portable report.

## 🛠️ Testing
Mock preview files are provided to visualize the layout without a live database:
- `pg17_perf_report_test.html`
- `ultimate_report_test.html`
