-- =============================================================================
-- 50_monday_report.sql  —  Nana's 2nd criterion: Adwoa's report in seconds
-- =============================================================================
--
-- WHAT ADWOA NEEDS, for every customer:
--   total spent · order count · spend in each of the last 12 months ·
--   a running total (she keeps this by hand today) · a top-100 ranking
--
-- WHY THE OLD REPORT TOOK ~40 MINUTES
--   It looked each figure up separately: for each of ~40,000 customers, one search for the
--   total, one for the count and one for EACH of 12 months, about 560,000 searches of the
--   orders table. (measurement/x50_monday_report_before.sql reproduces it for timing.)
--
-- How it is fast: every figure comes from ONE pass over orders (GROUP BY customer with
-- FILTER per month) and window functions for the ranking and running total, instead of a
-- separate lookup per customer per month. No bigger server, no copy of the data to refresh:
-- the views always show current figures. Timings: docs/measurement_report.md,
-- "before" query: measurement/x50_monday_report_before.sql.  (Decision record ADR-002.)
--
-- Decisions (see the decision records, ADR-003):
--   * Spend = orders.total_amount (what checkout charged). Order lines are damaged in four
--     ways (F-11, F-12, F-13, F-14); the stored total agrees with them in 98.5% of orders.
--   * Counted: pending, shipped, completed. Not counted: cancelled, refunded (money returned).
--     Uses the cleaned status values (F-04), so no spelling can slip through.
--   * "Trailing 12 months" ends with the month of the latest order on or before today, so
--     the report is correct on this extract (ends Aug 2026) and on live data alike.
--
-- WHAT THIS FILE CREATES (all are VIEWS: saved queries, recomputed fresh on every read)
--   monday_report                one row per customer, every figure
--   monday_report_top100         the top 100 spenders
--   monday_report_running_total  month-by-month running total per customer
--   v_report_months              which calendar month each column m01..m12 is
--   v_spend_orders               the orders that count as spending (used by the others)
-- =============================================================================

\echo '== 50_monday_report: report views'

BEGIN;

-- Index on order date: makes "latest order date" (below) a quick lookup at the end of
-- the index instead of reading every order.
CREATE INDEX orders_order_date_idx ON orders (order_date);

-- -----------------------------------------------------------------------------
-- report_anchor_month(): the last month of the reporting window.
-- -----------------------------------------------------------------------------
-- = the month of the latest order dated on or before today.
--   On this extract that is August 2026 (the data ends there); on live data it is the
--   current month. Using today's month on the extract would leave three empty months and
--   make it look as if sales collapsed.
-- date_trunc('month', …) rounds a date down to the 1st of its month (2026-08-17 -> 2026-08-01).
-- AT TIME ZONE 'Africa/Accra' reads the moment on Accra's clock, so an order at 23:30
-- on the 31st counts in that month, not the next.
-- STABLE tells PostgreSQL the result doesn't change within one query, so it may reuse it.
CREATE FUNCTION report_anchor_month() RETURNS date
LANGUAGE sql STABLE AS $$
    SELECT date_trunc('month', max(order_date) AT TIME ZONE 'Africa/Accra')::date
    FROM   orders
    WHERE  order_date <= now();
$$;

-- -----------------------------------------------------------------------------
-- v_report_months: which calendar month each column m01..m12 stands for (m12 = latest).
-- -----------------------------------------------------------------------------
-- generate_series(1, 12) produces the numbers 1 to 12, one per row. For each n:
--   column name 'm01' … 'm12'  (lpad pads 1 to '01')
--   month = anchor month minus (12 − n) months, so m12 is the anchor, m01 is 11 months before
CREATE VIEW v_report_months AS
SELECT 'm' || lpad(n::text, 2, '0') AS column_name,
       (report_anchor_month() - make_interval(months => 12 - n))::date AS month
FROM   generate_series(1, 12) AS n;

-- -----------------------------------------------------------------------------
-- v_spend_orders: orders that count as customer spending.
-- -----------------------------------------------------------------------------
-- Defined ONCE here, so every part of the report uses the same definition of "spend".
-- To change the definition (e.g. count only shipped and completed), change this one line.
CREATE VIEW v_spend_orders AS
SELECT o.order_id, o.customer_id, o.total_amount,
       -- The order's month, on Accra's clock, rounded to the 1st.
       date_trunc('month', o.order_date AT TIME ZONE 'Africa/Accra')::date AS month
FROM   orders o
WHERE  o.status IN ('pending', 'shipped', 'completed');

-- -----------------------------------------------------------------------------
-- monday_report: one row per customer.
-- -----------------------------------------------------------------------------
-- WITH … AS (…) defines named steps ("CTEs") used by the final SELECT.
CREATE VIEW monday_report AS
-- Step a: the anchor month, worked out ONCE. MATERIALIZED forces PostgreSQL to compute
-- it once and keep the answer; otherwise it may inline it and recompute per row.
WITH a AS MATERIALIZED (SELECT report_anchor_month() AS m),
-- Step per_customer: THE ONE PASS. GROUP BY customer_id collapses each customer's orders
-- into one row. Each aggregate below is computed during that same single read:
--   sum(…)              total spent
--   count(*)            number of orders
--   sum(…) FILTER (WHERE month = …)   adds up only that month's orders. Twelve of these
--                                     give the twelve monthly columns, still in one pass.
per_customer AS (
    SELECT s.customer_id,
           sum(s.total_amount) AS total_spent,
           count(*)            AS order_count,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '11 months') AS m01,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '10 months') AS m02,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '9 months')  AS m03,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '8 months')  AS m04,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '7 months')  AS m05,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '6 months')  AS m06,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '5 months')  AS m07,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '4 months')  AS m08,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '3 months')  AS m09,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '2 months')  AS m10,
           sum(s.total_amount) FILTER (WHERE s.month = a.m - interval '1 month')   AS m11,
           sum(s.total_amount) FILTER (WHERE s.month = a.m)                        AS m12
    -- CROSS JOIN a: attaches the single anchor-month value to every order row.
    FROM   v_spend_orders s CROSS JOIN a
    GROUP  BY s.customer_id
)
-- Final step: start from ALL customers (LEFT JOIN), so customers with no spending still
-- appear, with 0. coalesce(x, 0) turns "no orders" (NULL) into 0.
SELECT c.customer_id,
       c.full_name,
       coalesce(pc.total_spent, 0) AS total_spent,
       coalesce(pc.order_count, 0) AS order_count,
       coalesce(pc.m01, 0) AS m01, coalesce(pc.m02, 0) AS m02, coalesce(pc.m03, 0) AS m03,
       coalesce(pc.m04, 0) AS m04, coalesce(pc.m05, 0) AS m05, coalesce(pc.m06, 0) AS m06,
       coalesce(pc.m07, 0) AS m07, coalesce(pc.m08, 0) AS m08, coalesce(pc.m09, 0) AS m09,
       coalesce(pc.m10, 0) AS m10, coalesce(pc.m11, 0) AS m11, coalesce(pc.m12, 0) AS m12,
       -- WINDOW FUNCTION: rank() OVER (ORDER BY … DESC) numbers customers 1, 2, 3 … by
       -- spend, highest first, without collapsing rows. Equal spend gets the same rank.
       rank() OVER (ORDER BY coalesce(pc.total_spent, 0) DESC) AS spend_rank,
       -- true/false: is this customer within the top 100?
       rank() OVER (ORDER BY coalesce(pc.total_spent, 0) DESC) <= 100 AS is_top_100
FROM   customers c
LEFT   JOIN per_customer pc ON pc.customer_id = c.customer_id;

-- -----------------------------------------------------------------------------
-- monday_report_top100
-- -----------------------------------------------------------------------------
-- Top 100 on its own. rank() keeps ties together, so a tie at 100th can return 101+ rows.
-- (Cutting a tie in half would mean dropping a customer who spent exactly as much as
-- one kept in, with no fair reason to choose.)
CREATE VIEW monday_report_top100 AS
SELECT spend_rank, customer_id, full_name, total_spent, order_count
FROM   monday_report
WHERE  is_top_100
ORDER  BY spend_rank, customer_id;

-- -----------------------------------------------------------------------------
-- monday_report_running_total
-- -----------------------------------------------------------------------------
-- Running total per customer, month by month: what Adwoa tracks by hand today.
-- The running total includes all earlier spend; rows are shown for the trailing 12 months.
--   Example for one customer:   month     month_spend   running_total
--                               2026-06   GH₵ 200       GH₵ 1,450   (1,250 spent before June)
--                               2026-07   GH₵   0       (no row: no orders that month)
--                               2026-08   GH₵ 300       GH₵ 1,750
CREATE VIEW monday_report_running_total AS
WITH a AS MATERIALIZED (SELECT report_anchor_month() AS m),   -- MATERIALIZED: computed once, not once per row
-- monthly: each customer's spend per month (one pass over the spend orders).
monthly AS (
    SELECT customer_id, month, sum(total_amount) AS month_spend
    FROM   v_spend_orders
    GROUP  BY customer_id, month
-- running: WINDOW FUNCTION. sum(…) OVER (PARTITION BY customer ORDER BY month) adds up,
-- for each row, that customer's spend in this month AND every month before it.
-- PARTITION BY restarts the sum for each customer.
-- THE FRAME, stated explicitly (Learning Path, chapter 8): ROWS BETWEEN UNBOUNDED PRECEDING
-- AND CURRENT ROW = "this row and every earlier row". The default would be RANGE, which
-- differs only when two rows tie on the ORDER BY value. Here there is exactly one row per
-- customer per month (the GROUP BY above), so there are no ties and both give the same
-- answer. ROWS is written out so nobody has to know that to trust the figure.
), running AS (
    SELECT customer_id, month, month_spend,
           sum(month_spend) OVER (PARTITION BY customer_id ORDER BY month
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
    FROM   monthly
)
-- Only now filter to the 12-month window. The filter comes AFTER the running sum on
-- purpose: the total must include spend from before the window.
SELECT r.customer_id, r.month, r.month_spend, r.running_total
FROM   running r
CROSS  JOIN a
WHERE  r.month >  a.m - interval '12 months'
AND    r.month <= a.m;

COMMIT;

\echo '== 50_monday_report: done. Try: SELECT * FROM monday_report_top100;'
