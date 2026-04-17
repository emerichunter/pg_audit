# PG_Audit

A collection of PostgreSQL audit and performance reporting tools.

## Files

### pg17_perf_report.sql
Generates a comprehensive HTML performance report for PostgreSQL 17, analyzing:
- Top CPU consumers
- IO performance
- Query planning time
- WAL activity
- Query frequency
- Heavy queries (parallel candidates)
- Jitter analysis
- Temporary files usage
- Cache misses
- JIT compilation stats
- Global system information

### ultimate_report.sql
Ultimate PostgreSQL audit report that identifies:
- Unlogged tables (data loss risk)
- Table/index bloat (wasted disk space)
- Redundant indexes
- Duplicate indexes
- Unused indexes
- Missing indexes
- Long-running queries
- Connection issues
- And more comprehensive audit metrics

## Usage

Both scripts generate HTML output for easy viewing in a web browser.

### Running the Reports

To generate clean HTML output without psql formatting artifacts (dashed lines, string_agg headers, trailing + signs), use these psql options:

```bash
# For pg17_perf_report.sql
psql -A -t -q -d your_database -f pg17_perf_report.sql -o pg17_report.html

# For ultimate_report.sql
psql -A -t -q -d your_database -f ultimate_report.sql -o ultimate_report.html
```

### Option Explanations
- `-A`: Unaligned output (removes spaces and trailing + signs)
- `-t`: Tuples only (removes column headers like "string_agg" and dashed borders)
- `-q`: Quiet mode (suppresses connection messages)

### Viewing Results
Open the generated `.html` files in your web browser to view the formatted reports.

## Requirements
- PostgreSQL 17 (for pg17_perf_report.sql)
- pg_stat_statements extension enabled
- Appropriate database permissions for viewing system statistics