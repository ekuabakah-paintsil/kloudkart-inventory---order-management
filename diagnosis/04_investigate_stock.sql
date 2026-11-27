-- =============================================================================
-- 04_investigate_stock.sql  (investigation, not part of run_all)
-- =============================================================================
-- Tests whether the inventory log is a complete trail: units sold vs logged, and stock vs movements.
-- Results recorded in docs/working_notes.md.
--
-- WHY IT MATTERS
--   Nana's 4th criterion is an audit trail, and his complaint is that stock counts no
--   longer match reality. If the log is complete, two things must hold:
--     (a) units sold on orders = units logged as 'sale' movements
--     (b) each product's stock = the sum of its movements
--   What this found: (a) looked 22% short until split by status (query 3): the log
--   matches completed + shipped orders to within 70 units, so it is NOT a fault.
--   (b) holds for 3,879 of 4,023 products; the other 144 became finding F-01.
--
-- Run on the raw load to reproduce the recorded figures (the cleanup changes them).
-- Run: docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f diagnosis/04_investigate_stock.sql
-- =============================================================================

-- ---------------------------------------------------------------- QUERY 1
-- 1. Units sold per order lines vs units logged as sales (excluding the 6 placeholder lines)
-- Two single numbers side by side. Sales are stored as NEGATIVE movements, so the
-- minus sign in -sum(change_qty) turns them back into units sold.
-- quantity < 999 leaves out the placeholder lines, which would add 23,994 fake units
-- (4 × 999 + 2 × 9,999).
SELECT (SELECT sum(quantity) FROM order_items WHERE quantity < 999)        AS units_in_order_lines,
       (SELECT -sum(change_qty) FROM inventory_log WHERE reason = 'sale')  AS units_logged_as_sales;

-- ---------------------------------------------------------------- QUERY 2
-- 2. Does each product's stock equal the sum of its movements?
-- moves: each product's net movement (restocks in, sales out, corrections either way).
-- Each product is put into one of four groups; total_gap adds up the differences, so
-- the size of the problem is visible in units, not just in products.
WITH moves AS (
    SELECT product_id, sum(change_qty) AS net_moves
    FROM   inventory_log
    GROUP  BY product_id
)
SELECT CASE WHEN m.product_id IS NULL                     THEN 'no movements at all'
            WHEN p.stock_quantity = m.net_moves           THEN 'stock = movements'
            WHEN p.stock_quantity > m.net_moves           THEN 'stock HIGHER than movements'
            ELSE                                               'stock LOWER than movements' END AS result,
       count(*)                                         AS products,
       sum(p.stock_quantity - coalesce(m.net_moves, 0)) AS total_gap
FROM   products p
LEFT   JOIN moves m USING (product_id)
GROUP  BY 1
ORDER  BY 1;

-- ---------------------------------------------------------------- QUERY 3
-- 3. Units in order lines by normalised status
-- Splits the units on order lines by status, after mapping the 15 spellings to 5
-- (same CASE as the cleanup). This showed stock moves only for completed + shipped
-- orders, which explains the 22% gap in query 1.
SELECT CASE lower(trim(o.status))
            WHEN 'complete'  THEN 'completed'
            WHEN 'canceled'  THEN 'cancelled'
            ELSE lower(trim(o.status)) END AS status,
       count(DISTINCT o.order_id)          AS orders,
       sum(oi.quantity)                    AS units
FROM   order_items oi
JOIN   orders o ON o.order_id = oi.order_id
WHERE  oi.quantity < 999
GROUP  BY 1
ORDER  BY 3 DESC;