-- =============================================================================
-- x90_export_results.sql  (export only, NOT part of run_all)
-- =============================================================================
--
-- WHAT IT DOES
--   Saves the results of the solution as CSV files (open in Excel or any spreadsheet)
--   in a results/ folder in the repository root, so the evidence exists as files, not just as text
--   that scrolled past in a terminal.
--
-- RUN IT after sql/00_run_all.sql:
--   docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f measurement/x90_export_results.sql
--   (For the BEFORE version of the integrity checks, run measurement/x01_export_baseline.sql on the
--    raw load, i.e. after schema.sql + load.sql and before 00_run_all.sql.)
--
-- TWO FOLDERS, ON PURPOSE
--   results/               counts, timings, summaries: no customer data. Safe to commit;
--                          this is evidence a grader can read without running anything.
--   results/client_data/   real rows: customer names, spending, products. CONFIDENTIAL.
--                          .gitignore must exclude this folder. Never commit it.
--
-- HOW IT WORKS (psql commands, not SQL)
--   \! mkdir -p …      run a shell command: create the folders if they don't exist yet
--                      (-w /lab means the folder appears inside your kloudkart-lab folder)
--   \pset format csv   print query results as CSV instead of a drawn table
--   \o some/file.csv   send every query result that follows into that file
--   \o                 (no file) send results back to the screen
--   \echo prints to the screen even while \o is redirecting, so the progress
--   messages below stay visible.
-- =============================================================================

\set ON_ERROR_STOP on
\! mkdir -p results/client_data
\pset format csv

\echo '== exporting summaries (safe to commit) to results/'

-- ---------------------------------------------------------------- integrity checks, AFTER
-- The same 56 checks as the baseline, on the fixed data. Compare with
-- results/integrity_checks_before.csv (from x01_export_baseline.sql).
\o results/integrity_checks_after.csv
\i diagnosis/01_integrity_checks.sql

-- ---------------------------------------------------------------- row counts after cleanup
-- The "after fixes" rows of the Reconciliation table in data_findings.md.
\o results/row_counts_after.csv
SELECT 'categories' AS table_name, count(*) AS rows FROM categories
UNION ALL SELECT 'products',      count(*) FROM products
UNION ALL SELECT 'customers',     count(*) FROM customers
UNION ALL SELECT 'orders',        count(*) FROM orders
UNION ALL SELECT 'order_items',   count(*) FROM order_items
UNION ALL SELECT 'inventory_log', count(*) FROM inventory_log;

-- ---------------------------------------------------------------- what the cleanup did
-- How many rows each finding moved into quarantine (counts only).
\o results/cleanup_quarantine_summary.csv
SELECT q_finding AS finding, 'quarantine_' || t AS moved_to, n AS rows
FROM (
    SELECT 'categories' AS t, q_finding, count(*) AS n FROM quarantine_categories GROUP BY 2
    UNION ALL SELECT 'products',      q_finding, count(*) FROM quarantine_products      GROUP BY 2
    UNION ALL SELECT 'customers',     q_finding, count(*) FROM quarantine_customers     GROUP BY 2
    UNION ALL SELECT 'orders',        q_finding, count(*) FROM quarantine_orders        GROUP BY 2
    UNION ALL SELECT 'order_items',   q_finding, count(*) FROM quarantine_order_items   GROUP BY 2
    UNION ALL SELECT 'inventory_log', q_finding, count(*) FROM quarantine_inventory_log GROUP BY 2
) s
ORDER BY 1, 2;

-- How many in-place fixes each finding made (counts only).
\o results/cleanup_fix_summary.csv
SELECT finding, action, count(*) AS rows FROM data_fix_log GROUP BY 1, 2 ORDER BY 1, 2;

-- ---------------------------------------------------------------- data health
\o results/data_health.csv
SELECT * FROM v_data_health;

-- ---------------------------------------------------------------- report timings
-- Times each report 10 times INSIDE the database and works out median, p95 and worst,
-- which are exactly the columns of the Results table in docs/measurement_report.md.
--
-- How: a DO block is a one-off piece of PL/pgSQL. For each view it runs the query 10
-- times and records the time before and after each run. clock_timestamp() is the real
-- time at that instant (unlike now(), which is fixed for the whole transaction).
-- EXECUTE runs the query and throws the rows away, so only the work is measured.
-- The timings go into a TEMP table (gone when this session ends).
\o
\echo '== timing each report 10 times (takes about 15 seconds)'
CREATE TEMP TABLE report_timings (query text, run integer, ms numeric);
DO $$
DECLARE
    v_view  text;
    v_run   integer;
    v_start timestamptz;
BEGIN
    FOREACH v_view IN ARRAY ARRAY['monday_report', 'monday_report_top100',
                                  'monday_report_running_total', 'v_low_stock_rollup'] LOOP
        FOR v_run IN 1..10 LOOP
            v_start := clock_timestamp();
            EXECUTE format('SELECT * FROM %I', v_view);    -- %I quotes the view name safely
            INSERT INTO report_timings
            VALUES (v_view, v_run, extract(epoch FROM clock_timestamp() - v_start) * 1000);
        END LOOP;
    END LOOP;
END;
$$;

-- Every individual run (run 1 is "cold", runs 2-10 "warm").
\o results/report_timings_runs.csv
SELECT query, run, round(ms, 2) AS ms FROM report_timings ORDER BY query, run;

-- One row per report: the figures for the measurement report.
-- percentile_cont(0.5) = median, percentile_cont(0.95) = p95 (Learning Path, chapter 6.1:
-- ordered-set aggregates; WITHIN GROUP says which values to sort).
\o results/report_timings_summary.csv
SELECT query,
       count(*)                                                      AS runs,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY ms)::numeric, 2) AS median_ms,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY ms)::numeric, 2) AS p95_ms,
       round(max(ms), 2)                                             AS worst_ms
FROM   report_timings
GROUP  BY query
ORDER  BY query;

-- ---------------------------------------------------------------- client data (CONFIDENTIAL)
\o
\echo '== exporting client data (CONFIDENTIAL, never commit) to results/client_data/'

-- Adwoa's report: one row per customer with the 12 monthly columns.
\o results/client_data/monday_report.csv
SELECT * FROM monday_report ORDER BY spend_rank, customer_id;

\o results/client_data/monday_report_top100.csv
SELECT * FROM monday_report_top100;

\o results/client_data/monday_report_running_total.csv
SELECT * FROM monday_report_running_total ORDER BY customer_id, month;

-- Which calendar month each column m01..m12 is (needed to read monday_report.csv).
\o results/client_data/report_months.csv
SELECT * FROM v_report_months ORDER BY column_name;

-- Low stock: the rollup by category, and the products behind it.
\o results/client_data/low_stock_rollup.csv
SELECT * FROM v_low_stock_rollup ORDER BY path;

\o results/client_data/low_stock_products.csv
SELECT * FROM v_low_stock_products;

-- The warehouse counting list (improvement, F-01).
\o results/client_data/stock_drift.csv
SELECT * FROM v_stock_drift;

-- Every in-place change the cleanup made, row by row.
\o results/client_data/data_fix_log.csv
SELECT * FROM data_fix_log ORDER BY fix_id;

-- Back to normal output.
\o
\pset format aligned
\echo '== done: CSV files are in results/ and results/client_data/'
