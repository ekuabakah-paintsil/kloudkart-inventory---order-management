-- 04_investigate_stock.sql (investigation, not part of run_all)
-- Tests whether the inventory log is a complete trail: units sold vs logged, and stock vs movements.
-- Results recorded in docs/working_notes.md.
-- Run: docker exec -w /lab -i kloudkart psql -U postgres -f sql/04_investigate_stock.sql

-- 1. Units sold per order lines vs units logged as sales (excluding the 6 placeholder lines)
SELECT (SELECT sum(quantity) FROM order_items WHERE quantity < 999)        AS units_in_order_lines,
       (SELECT -sum(change_qty) FROM inventory_log WHERE reason = 'sale')  AS units_logged_as_sales;

-- 2. Does each product's stock equal the sum of its movements?
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

-- 3. Units in order lines by normalised status
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