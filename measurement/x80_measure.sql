-- =============================================================================
-- x80_measure.sql  (measurement only, NOT part of run_all)
-- =============================================================================
-- Times each report the client asked for, 10 runs each, then prints the query plans of the
-- report and the rollup, for docs/measurement_report.md.
-- Run after sql/00_run_all.sql:
--   docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f measurement/x80_measure.sql
-- Results are discarded; only the "Time:" lines print. The first run of each block is
-- "cold" (data not yet in memory), the others are "warm". Report the median and the worst.
--
-- WHY 10 RUNS, NOT 1
--   A single timing can be thrown off by anything else the laptop is doing. The
--   measurement template asks for median, p95 and worst, which needs several runs.
--   Median = the middle value of the 10 when sorted: the typical time.
--   Worst  = the slowest: what Adwoa sees on a bad Monday.
--
-- HOW IT WORKS
--   \timing on   psql prints "Time: … ms" after every statement
--   \o /dev/null  send query RESULTS nowhere, so printing 40,000 rows to the screen
--                 isn't part of what is being timed (the Time lines still appear)
--   \o            (at the end) send results back to the screen

\timing on
\o /dev/null

\echo '== monday_report (all customers), 10 runs'
SELECT * FROM monday_report;
SELECT * FROM monday_report;
SELECT * FROM monday_report;
SELECT * FROM monday_report;
SELECT * FROM monday_report;
SELECT * FROM monday_report;
SELECT * FROM monday_report;
SELECT * FROM monday_report;
SELECT * FROM monday_report;
SELECT * FROM monday_report;

\echo '== monday_report_top100, 10 runs'
SELECT * FROM monday_report_top100;
SELECT * FROM monday_report_top100;
SELECT * FROM monday_report_top100;
SELECT * FROM monday_report_top100;
SELECT * FROM monday_report_top100;
SELECT * FROM monday_report_top100;
SELECT * FROM monday_report_top100;
SELECT * FROM monday_report_top100;
SELECT * FROM monday_report_top100;
SELECT * FROM monday_report_top100;

\echo '== monday_report_running_total, 10 runs'
SELECT * FROM monday_report_running_total;
SELECT * FROM monday_report_running_total;
SELECT * FROM monday_report_running_total;
SELECT * FROM monday_report_running_total;
SELECT * FROM monday_report_running_total;
SELECT * FROM monday_report_running_total;
SELECT * FROM monday_report_running_total;
SELECT * FROM monday_report_running_total;
SELECT * FROM monday_report_running_total;
SELECT * FROM monday_report_running_total;

\echo '== v_low_stock_rollup, 10 runs'
SELECT * FROM v_low_stock_rollup;
SELECT * FROM v_low_stock_rollup;
SELECT * FROM v_low_stock_rollup;
SELECT * FROM v_low_stock_rollup;
SELECT * FROM v_low_stock_rollup;
SELECT * FROM v_low_stock_rollup;
SELECT * FROM v_low_stock_rollup;
SELECT * FROM v_low_stock_rollup;
SELECT * FROM v_low_stock_rollup;
SELECT * FROM v_low_stock_rollup;

\o
\timing off

-- ---------------------------------------------------------------- PLANS (the "after")
-- EXPLAIN (ANALYZE, BUFFERS) runs the query and prints the plan PostgreSQL chose, with the
-- real time and rows of every step (Learning Path, chapter 11). Compare with the plan from
-- x50: there, 14 SubPlans each loop once per customer; here, the orders table is read ONCE
-- (one Seq Scan feeding one HashAggregate / GroupAggregate). BUFFERS shows how much data
-- was read from memory ("hit") versus disk ("read").
\echo '== plan: monday_report'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM monday_report;
\echo '== plan: v_low_stock_rollup'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM v_low_stock_rollup;

\echo '== done: send these Time lines and plans to fill docs/measurement_report.md'
