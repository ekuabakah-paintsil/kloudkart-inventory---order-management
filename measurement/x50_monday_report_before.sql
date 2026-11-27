-- =============================================================================
-- x50_monday_report_before.sql  (measurement only, NOT part of run_all)
-- =============================================================================
-- A deliberately naive version of the Monday report: the shape that takes ~40 minutes.
-- For each customer it runs separate lookups for the total, the count and each of the
-- 12 months, so the orders table is searched 14 times per customer (40,000+ customers).
-- Used as the "before" figure in docs/measurement_report.md.
--
-- WHY IT IS SLOW (read this against sql/50_monday_report.sql)
--   Each "(SELECT … FROM orders o WHERE o.customer_id = s.customer_id …)" in the column
--   list is a CORRELATED SUBQUERY: it runs again for every customer row. 14 of them ×
--   40,000 customers ≈ 560,000 separate searches. On the raw load there is no index on
--   orders.customer_id, so each search reads the whole orders table.
--   The fast version computes all 14 figures in ONE grouped pass instead.
-- It also has to clean the status on every row (lower(trim(status)), both spellings of
-- cancelled), because the raw data still has 15 spellings.
--
-- WARNING: run against the full customer list this can take a very long time. Time it on
-- a sample and scale up, e.g. change LIMIT 500 below and multiply by (customers / 500).
-- On a synthetic extract of the same size (40,533 customers, 160,006 orders) 500 customers
-- took 38.8 s, i.e. about 52 minutes for everyone, consistent with Adwoa's ~40 minutes.
--
-- Run it on the RAW load (after schema.sql + load.sql, BEFORE 00_run_all.sql), so it
-- measures the database as Adwoa has it today, without the indexes the solution adds.
--
-- Run (it switches timing on itself):
--   docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f measurement/x50_monday_report_before.sql
--
-- WHAT IT PRINTS (for docs/measurement_report.md, "Before / after")
--   1. "Time: …" for the 500-customer sample: multiply by (customers ÷ 500) for everyone.
--   2. The query PLAN with real timings (EXPLAIN ANALYZE, Learning Path chapter 11).
--      Look for the "SubPlan" lines and their "loops=500": each of the 14 lookups ran once
--      per customer. That is the expensive node, and it is the evidence for ADR-002.
--   The sample runs twice (once timed, once explained), so allow about twice the time.

-- A TEMP VIEW (exists only for this session) holds the naive query, so the same query
-- can be timed and then explained without copying it twice.
CREATE TEMP VIEW naive_monday_report AS
WITH sample AS (SELECT customer_id, full_name FROM customers ORDER BY customer_id LIMIT 500),
anchor AS (SELECT date_trunc('month', max(order_date))::date AS m FROM orders WHERE order_date <= now())
SELECT s.customer_id, s.full_name,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o
    WHERE o.customer_id = s.customer_id AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS total_spent,
  (SELECT count(*) FROM orders o
    WHERE o.customer_id = s.customer_id AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS order_count,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '11 months' AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m01,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '10 months' AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m02,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '9 months'  AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m03,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '8 months'  AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m04,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '7 months'  AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m05,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '6 months'  AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m06,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '5 months'  AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m07,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '4 months'  AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m08,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '3 months'  AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m09,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '2 months'  AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m10,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m - interval '1 month'   AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m11,
  (SELECT coalesce(sum(o.total_amount), 0) FROM orders o, anchor a WHERE o.customer_id = s.customer_id AND date_trunc('month', o.order_date) = a.m                        AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled', 'refunded')) AS m12
FROM sample s
ORDER BY total_spent DESC;

\timing on
\echo '== 1. naive report, 500 customers: timed (output discarded)'
\o /dev/null
SELECT * FROM naive_monday_report;
\o
\timing off

\echo '== 2. its plan, with real row counts and timings'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM naive_monday_report;
