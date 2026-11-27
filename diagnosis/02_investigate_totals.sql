-- =============================================================================
-- 02_investigate_totals.sql  (investigation, not part of run_all)
-- =============================================================================
-- Explains the 2,398 total-vs-lines mismatches found by 01. Results recorded in docs/working_notes.md.
--
-- THE QUESTION
--   Every order has a stored total (written at checkout) and a set of lines
--   (quantity × price). They should agree. On 2,398 orders they don't. Why?
--   The answer decided which figure the Monday report trusts (ADR-004).
--
-- THE APPROACH: sort mismatches by likely cause before judging them
--   Each order is classified by what its lines contain (a NULL price? a zero price? the
--   same product twice?) and by direction (total higher or lower than the lines).
--   The DIRECTION is the clue:
--     total HIGHER than lines  the customer was charged for something a line lost
--     total LOWER  than lines  a line counts something the customer didn't pay for
--
-- Run: docker exec -w /lab -i kloudkart psql -U postgres -f diagnosis/02_investigate_totals.sql
-- (Must run on the RAW load: after the cleanup these faults are gone.)
-- =============================================================================

-- ---------------------------------------------------------------- QUERY 1
-- Classify every order by what its lines contain, then see which ones match.
-- l: one row per order with its lines' total and three yes/no flags.
--   bool_or(x) is true if x is true for ANY line of the order.
--   count(*) > count(DISTINCT product_id) is true if some product appears twice.
-- Each order is put in the FIRST kind that applies (the CASE checks in order 1 to 4),
-- so no order is counted twice. sum(total − lines) shows the money involved.
-- NOTE: sum() skips NULLs, so an order whose lines are ALL NULL-priced has no lines
-- total at all: "cannot compare".
WITH l AS (
    SELECT order_id,
           sum(quantity * unit_price)                AS lines_total,
           bool_or(unit_price IS NULL)               AS has_null_price,
           bool_or(unit_price = 0)                   AS has_zero_price,
           count(*) > count(DISTINCT product_id)     AS has_dup_line
    FROM   order_items
    GROUP  BY order_id
)
SELECT CASE WHEN has_null_price THEN '1 has NULL-price line'
            WHEN has_zero_price THEN '2 has zero-price line'
            WHEN has_dup_line   THEN '3 has duplicate line'
            ELSE                     '4 none of these' END          AS order_kind,
       CASE WHEN o.total_amount = l.lines_total THEN 'matches'
            WHEN o.total_amount > l.lines_total THEN 'total HIGHER than lines'
            WHEN o.total_amount < l.lines_total THEN 'total LOWER than lines'
            ELSE 'cannot compare' END                               AS result,
       count(*)                                                     AS orders,
       sum(o.total_amount - l.lines_total)                          AS total_difference
FROM   orders o
JOIN   l USING (order_id)
GROUP  BY 1, 2
ORDER  BY 1, 2;

-- ---------------------------------------------------------------- QUERY 2
-- Size of unexplained mismatches (order kind 4)
-- For orders with none of the known causes: how big are the differences? If almost all
-- were a pesewa or two, it would be ROUNDING (looks wrong, isn't). None were: the
-- smallest bucket (<= 0.05) came back empty, so these are real disagreements.
-- abs() = size of the difference ignoring direction; min/max show the range per bucket.
WITH l AS (
    SELECT order_id,
           sum(quantity * unit_price)            AS lines_total,
           bool_or(unit_price IS NULL)           AS has_null_price,
           bool_or(unit_price = 0)               AS has_zero_price,
           count(*) > count(DISTINCT product_id) AS has_dup_line
    FROM   order_items
    GROUP  BY order_id
)
SELECT CASE WHEN abs(o.total_amount - l.lines_total) <= 0.05  THEN 'a ≤ 0.05 (rounding?)'
            WHEN abs(o.total_amount - l.lines_total) <= 10    THEN 'b 0.05–10'
            WHEN abs(o.total_amount - l.lines_total) <= 1000  THEN 'c 10–1,000'
            WHEN abs(o.total_amount - l.lines_total) <= 10000 THEN 'd 1,000–10,000'
            ELSE                                                  'e > 10,000' END AS size,
       count(*)                                  AS orders,
       min(o.total_amount - l.lines_total)       AS min_diff,
       max(o.total_amount - l.lines_total)       AS max_diff
FROM   orders o
JOIN   l USING (order_id)
WHERE  NOT (has_null_price OR has_zero_price OR has_dup_line)
AND    o.total_amount <> l.lines_total
GROUP  BY 1
ORDER  BY 1;

-- ---------------------------------------------------------------- QUERY 3
-- Biggest line in each order with |total − lines| > 10,000 (all kinds)
-- Looks inside the extreme cases. DISTINCT ON (order_id) keeps ONE row per order: the
-- first in the ORDER BY, i.e. the line with the largest quantity × price. This is how the
-- placeholder quantities 999 and 9999 (F-14) were found. current_product_price compares
-- the line's price with today's price: they matched, so prices weren't the problem.
WITH l AS (
    SELECT order_id, sum(quantity * unit_price) AS lines_total
    FROM   order_items GROUP BY order_id
), extreme AS (
    SELECT o.order_id, o.total_amount, l.lines_total
    FROM   orders o JOIN l USING (order_id)
    WHERE  abs(o.total_amount - l.lines_total) > 10000
)
SELECT DISTINCT ON (e.order_id)
       e.order_id, e.total_amount, e.lines_total,
       oi.quantity, oi.unit_price, p.price AS current_product_price
FROM   extreme e
JOIN   order_items oi ON oi.order_id = e.order_id
LEFT   JOIN products p ON p.product_id = oi.product_id
ORDER  BY e.order_id, oi.quantity * oi.unit_price DESC NULLS LAST;

