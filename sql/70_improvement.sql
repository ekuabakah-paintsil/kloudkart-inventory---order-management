-- =============================================================================
-- 70_improvement.sql  —  improvement beyond the brief: a standing stock-drift watch
-- =============================================================================
--
-- The problem: Nana's complaint was that stock counts "no longer match reality", and
-- nobody could say which products or since when. The diagnosis found 144 such products
-- (F-01) only by comparing each product's stock with the sum of its recorded movements.
-- The cleanup fixes only 31 (recounts the log held but never applied); for the other
-- 113 the data cannot say which side is right.
--
-- THE IDEA IN ONE SENTENCE
--   If the trail is complete, every product's stock should equal the sum of its movements
--   (restocks in, sales out, corrections either way). Any product where it doesn't is a
--   product whose stock changed without a record, so it needs a physical count.
--
-- What this adds:
--   * v_stock_drift   - every product whose stock does not equal its movement trail,
--                       by how much, and when it last moved. Empty means every count is
--                       explained by the trail. A non-empty row is a product to physically
--                       count, or a change made outside place_order.
--   * v_data_health   - one row per rule that matters to Nana, with today's count of
--                       breaches, so the faults found in this audit are seen if they return.
-- Worth to Nana: the 113 remaining products become a counting list for the warehouse, and the next
-- drift is caught the week it happens instead of after the next oversell.
-- (Full write-up: docs/improvement.md.)
--
-- Both are VIEWS, so they cost nothing until someone looks, and they are always current.
-- =============================================================================

\echo '== 70_improvement: stock drift watch and data health'

BEGIN;

-- -----------------------------------------------------------------------------
-- v_stock_drift
-- -----------------------------------------------------------------------------
CREATE VIEW v_stock_drift AS
-- moves: for each product, the stock its history says it should have (the sum of every
-- movement) and the date of its most recent movement.
WITH moves AS (
    SELECT product_id, sum(change_qty) AS trail_quantity, max(created_at) AS last_movement
    FROM   inventory_log
    GROUP  BY product_id
)
SELECT p.product_id,
       p.product_name,
       p.stock_quantity                                    AS stock_on_record,
       -- A product with no movements at all has a trail of 0 (coalesce turns NULL into 0).
       coalesce(m.trail_quantity, 0)                       AS stock_per_trail,
       p.stock_quantity - coalesce(m.trail_quantity, 0)    AS difference,
       -- What the gap means for Nana, in words:
       --   positive difference: the record shows MORE than the history explains, so the
       --     shop may sell units that aren't on the shelf (an oversell waiting to happen)
       --   negative difference: the record shows LESS, so units left without a record
       --     (loss, theft, damage) or real stock is being refused to customers
       CASE WHEN p.stock_quantity > coalesce(m.trail_quantity, 0)
            THEN 'more on record than the trail explains: may sell stock that is not there'
            ELSE 'less on record than the trail explains: unrecorded loss, or stock refused' END AS meaning,
       m.last_movement
FROM   products p
-- LEFT JOIN … USING (product_id): keep every product, even one with no movements.
LEFT   JOIN moves m USING (product_id)
-- Only products where the two disagree. IS DISTINCT FROM is "not equal" that also
-- handles NULL safely.
WHERE  p.stock_quantity IS DISTINCT FROM coalesce(m.trail_quantity, 0)
-- Biggest gap first: the warehouse should count those first.
ORDER  BY abs(p.stock_quantity - coalesce(m.trail_quantity, 0)) DESC, p.product_id;

-- -----------------------------------------------------------------------------
-- v_data_health
-- -----------------------------------------------------------------------------
-- One row per rule. Each row is its own small query, stacked with UNION ALL.
-- "breaches" should be 0 for a healthy database; the "action" column says what to do
-- if it isn't. Some rows will never be 0 on this extract, because they count historical
-- faults left by decision (F-08, F-09, F-13). What matters is that the number does not GROW.
CREATE VIEW v_data_health AS
SELECT 'products whose stock does not match their trail' AS rule,
       (SELECT count(*) FROM v_stock_drift) AS breaches,
       'count these products; investigate changes made outside place_order' AS action
UNION ALL
SELECT 'products with negative stock',
       (SELECT count(*) FROM products WHERE stock_quantity < 0),
       'should be impossible: a database rule now refuses it'
UNION ALL
-- Uses has_root from sql/60: categories caught in a loop never reach a department.
SELECT 'categories that never reach a top-level department',
       (SELECT count(*) FROM v_category_path WHERE NOT has_root),
       'give the category a real parent; its products are missing from the low-stock view'
UNION ALL
SELECT 'order lines with no price',
       (SELECT count(*) FROM order_items WHERE unit_price IS NULL OR unit_price <= 0),
       'historical only; new lines always carry a price'
UNION ALL
-- Same comparison as the diagnosis: each order's stored total vs the sum of its lines.
SELECT 'orders whose total differs from their lines',
       (SELECT count(*) FROM orders o
        JOIN (SELECT order_id, sum(quantity * unit_price) AS lines FROM order_items GROUP BY order_id) l
          USING (order_id)
        WHERE o.total_amount <> l.lines),
       'historical; new orders are written in one step and always agree'
UNION ALL
SELECT 'orders dated in the future',
       (SELECT count(*) FROM orders WHERE order_date > now()),
       'check how the date was entered';

COMMIT;

\echo '== 70_improvement: done. Try: SELECT * FROM v_data_health;'
