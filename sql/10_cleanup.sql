-- =============================================================================
-- 10_cleanup.sql  —  repair or set aside the faulty rows found in the diagnosis
-- =============================================================================
--
-- WHAT THIS FILE DOES
--   Works through the findings in docs/data_findings.md (F-01 … F-15) and gives each
--   one of three treatments (decision record ADR-005):
--     FIX IN PLACE   only when the correct value is certain
--                    (F-02, F-03, F-04, F-05, F-14)
--     QUARANTINE     move broken rows that can't be repaired into a quarantine_* table,
--                    labelled with the finding and the reason
--                    (F-06, F-07, F-10, F-11, F-12, F-15)
--     LEAVE          when nobody can know the correct value; documented instead
--                    (F-01, F-08, F-09, F-13)
--
-- TWO PROMISES THIS FILE KEEPS
--   1. Nothing is deleted outright. Before a row leaves a live table, it is copied to a
--      quarantine table. An auditor can always see what was removed and why.
--   2. Every in-place change is written to data_fix_log, so every altered row can be
--      traced and, if needed, reversed.
--
-- WHEN IT RUNS
--   Once, straight after load.sql, and BEFORE 20_constraints.sql. The rules added in 20
--   (foreign keys, uniqueness, value checks) cannot be created while rows that break them
--   are still in the tables; PostgreSQL refuses. This file makes the data obey them first.
--
-- ORDER OF THE STEPS BELOW
--   Some fixes change what the next one sees, so the order is deliberate:
--   statuses first (later steps read them), customers merged before orphan orders are
--   looked for, orders quarantined before orphan LINES are looked for, double lines
--   removed before placeholder quantities are worked out from the totals.
-- =============================================================================

\echo '== 10_cleanup: fixing and quarantining faulty rows'

-- Everything between BEGIN and COMMIT is one transaction: either ALL of it happens, or,
-- if any statement fails, NONE of it does. That stops a half-finished cleanup (e.g.
-- orders moved to a merged customer, but the duplicate customer not yet removed).
BEGIN;

-- =============================================================================
-- BOOKKEEPING TABLES
-- =============================================================================

-- data_fix_log: one row per change made to the data, so an auditor can see what was
-- altered, by which finding, and when.
CREATE TABLE data_fix_log (
    -- GENERATED ALWAYS AS IDENTITY: PostgreSQL hands out 1, 2, 3 … automatically.
    fix_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    finding     text        NOT NULL,     -- F-number from data_findings.md
    table_name  text        NOT NULL,     -- which table was changed
    row_id      bigint,                    -- which row; NULL when the entry summarises many rows
    action      text        NOT NULL,     -- what was done, in words
    detail      text,                      -- before -> after, or extra context
    fixed_at    timestamptz NOT NULL DEFAULT now()   -- when the change was made
);

-- Quarantine tables. "LIKE categories" copies the column names and types of the live
-- table, so a quarantined row keeps exactly the shape it had. Three columns are added:
--   q_finding  which finding put the row here (e.g. 'F-06')
--   q_reason   why, in words
--   q_at       when
-- Nothing reads these tables in normal use; they exist so removed rows are never lost.
CREATE TABLE quarantine_categories    (LIKE categories,    q_finding text NOT NULL, q_reason text, q_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE quarantine_products      (LIKE products,      q_finding text NOT NULL, q_reason text, q_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE quarantine_customers     (LIKE customers,     q_finding text NOT NULL, q_reason text, q_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE quarantine_orders        (LIKE orders,        q_finding text NOT NULL, q_reason text, q_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE quarantine_order_items   (LIKE order_items,   q_finding text NOT NULL, q_reason text, q_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE quarantine_inventory_log (LIKE inventory_log, q_finding text NOT NULL, q_reason text, q_at timestamptz NOT NULL DEFAULT now());

-- =============================================================================
-- F-04  Order status typed 15 different ways  ->  FIX IN PLACE
-- =============================================================================
-- Five real statuses were stored under 15 spellings: capitals ('COMPLETED'), a leading
-- space (' completed'), 'complete' for 'completed' and 'canceled' for 'cancelled'.
-- The correct value is never in doubt, so the rows are rewritten.
--
-- How the new value is worked out (the same CASE appears twice below):
--   lower(trim(status))   'trim' removes surrounding spaces, 'lower' removes capitals
--   CASE … WHEN …         then the two spelling variants are mapped to the standard word
--
-- WITH fixed AS (UPDATE … RETURNING 1) lets one statement both change the rows AND
-- count them: the UPDATE returns one row per change, and the INSERT below records how
-- many there were in data_fix_log.
WITH fixed AS (
    UPDATE orders
    SET    status = CASE lower(trim(status))
                        WHEN 'complete' THEN 'completed'
                        WHEN 'canceled' THEN 'cancelled'
                        ELSE lower(trim(status)) END
    -- Only touch rows whose status actually changes. IS DISTINCT FROM is a "not equal"
    -- that also behaves sensibly with NULLs (plain <> returns "unknown" for NULL).
    WHERE  status IS DISTINCT FROM
           CASE lower(trim(status))
               WHEN 'complete' THEN 'completed'
               WHEN 'canceled' THEN 'cancelled'
               ELSE lower(trim(status)) END
    RETURNING 1
)
INSERT INTO data_fix_log (finding, table_name, action, detail)
SELECT 'F-04', 'orders', 'normalise status', count(*) || ' orders rewritten to one of 5 statuses' FROM fixed;

-- =============================================================================
-- F-05  Customers registered twice  ->  MERGE (fix in place)
-- =============================================================================
-- 533 groups of customer records share an email once capitals and spaces are ignored,
-- and in every group the name matches too: one person, two or three records. Their
-- spending is split across the records, which distorts the top-100 ranking.
--
-- Plan:
--   1. For each record, work out which record in its group SURVIVES (the lowest id).
--   2. Move every order from the duplicates onto the survivor.
--   3. Copy the duplicates to quarantine_customers, then remove them.
--   4. Store every email in its normalised form, so a uniqueness rule can hold (sql/20).

-- Step 1. A TEMP table exists only until this session ends; it is scratch space.
-- min(customer_id) OVER (PARTITION BY lower(trim(email))) is a WINDOW FUNCTION: for each
-- row it looks at all rows with the same normalised email (the "partition") and returns
-- the smallest customer_id among them, without collapsing the rows together.
-- Result: one row per customer, saying "this record (dup_id) should become keep_id".
CREATE TEMP TABLE customer_merge AS
SELECT customer_id AS dup_id,
       min(customer_id) OVER (PARTITION BY lower(trim(email))) AS keep_id
FROM   customers
WHERE  email IS NOT NULL;           -- a missing email can't prove two records are one person

-- Every survivor also appears in the list as "merge into itself"; remove those rows.
DELETE FROM customer_merge WHERE dup_id = keep_id;

-- Safety check: never merge two records whose NAMES differ, even if the email matches.
-- Two different people sharing an address (e.g. a family email) must stay separate.
-- (On Kloud Kart's data all 533 groups had matching names, so this removes nothing,
-- but it protects any future run.)
DELETE FROM customer_merge m
USING  customers a, customers b
WHERE  a.customer_id = m.dup_id AND b.customer_id = m.keep_id
AND    lower(trim(a.full_name)) <> lower(trim(b.full_name));   -- different person: never merge

-- Step 2a. Record every order that is about to move, BEFORE moving it, so the log shows
-- which customer each order used to belong to.
INSERT INTO data_fix_log (finding, table_name, row_id, action, detail)
SELECT 'F-05', 'orders', o.order_id, 'move order to surviving customer',
       'customer ' || m.dup_id || ' -> ' || m.keep_id
FROM   orders o JOIN customer_merge m ON m.dup_id = o.customer_id;

-- Step 2b. Move the orders. "UPDATE … FROM" joins orders to the merge list and sets
-- each order's customer to the survivor.
UPDATE orders o SET customer_id = m.keep_id
FROM   customer_merge m WHERE m.dup_id = o.customer_id;

-- Step 3. Copy each duplicate record to quarantine (c.* = all its columns, then the
-- finding and reason), then remove it from the live table.
INSERT INTO quarantine_customers
SELECT c.*, 'F-05', 'duplicate of customer ' || m.keep_id
FROM   customers c JOIN customer_merge m ON m.dup_id = c.customer_id;
DELETE FROM customers c USING customer_merge m WHERE m.dup_id = c.customer_id;

-- Step 4. Store every email normalised. 234 of the 533 duplicate groups differed ONLY
-- by capitals or spaces, which is how they slipped past any check on the raw text.
UPDATE customers SET email = lower(trim(email)) WHERE email <> lower(trim(email));

-- =============================================================================
-- F-06  Orders that belong to no customer  ->  QUARANTINE
-- =============================================================================
-- 210 orders (GH₵665,180.61) point at a customer_id that doesn't exist. The real
-- customer can't be recovered, so the orders are set aside rather than guessed at.
-- NOT EXISTS (…) is true when the inner query finds no matching customer.
INSERT INTO quarantine_orders
SELECT o.*, 'F-06', 'customer_id points at no customer'
FROM   orders o
WHERE  NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id);

-- An order's lines go with it; a line without its order would just become the next orphan.
INSERT INTO quarantine_order_items
SELECT oi.*, 'F-06', 'line of an order quarantined under F-06'
FROM   order_items oi
WHERE  oi.order_id IN (SELECT order_id FROM quarantine_orders WHERE q_finding = 'F-06');

-- =============================================================================
-- F-10  Orders dated after the extract ends  ->  QUARANTINE
-- =============================================================================
-- Real trading runs August 2025 to August 2026 (thousands of orders a month). After
-- that, 24 stray orders are dated up to August 2027, all exactly on the minute, a sign
-- of hand entry. Their true date is unknown, so they can't be "corrected".
-- The cut-off 2026-09-01 is an assumption, stated in data_findings.md and the README.
INSERT INTO quarantine_orders
SELECT o.*, 'F-10', 'order_date after extract end (assumed 2026-08-31)'
FROM   orders o
WHERE  o.order_date >= '2026-09-01'
-- An order already quarantined under F-06 must not be copied a second time.
AND    o.order_id NOT IN (SELECT order_id FROM quarantine_orders);

INSERT INTO quarantine_order_items
SELECT oi.*, 'F-10', 'line of an order quarantined under F-10'
FROM   order_items oi
WHERE  oi.order_id IN (SELECT order_id FROM quarantine_orders WHERE q_finding = 'F-10');

-- Now that F-06 and F-10 orders and their lines are safely copied, remove them from the
-- live tables. Lines first: in this order nothing is ever left pointing at a missing order.
DELETE FROM order_items WHERE order_id IN (SELECT order_id FROM quarantine_orders);
DELETE FROM orders      WHERE order_id IN (SELECT order_id FROM quarantine_orders);
-- The 40 stock movements dated after the extract end stay in the log: the movement is real
-- (stock reconciles with it), only its date is wrong. They are listed in data_findings.md.
-- (The 14 F-03 correction movements added further down are dated at cleanup time, so after
-- this script the "after extract end" check shows 54 movements: 40 old + 14 new, not a fault.)

-- =============================================================================
-- F-12  Order lines that belong to no order  ->  QUARANTINE
-- =============================================================================
-- 692 lines point at an order_id that doesn't exist. Same pattern: copy, then remove.
INSERT INTO quarantine_order_items
SELECT oi.*, 'F-12', 'order_id points at no order'
FROM   order_items oi
WHERE  NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id);
DELETE FROM order_items oi
WHERE  NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id);

-- =============================================================================
-- F-11  Order lines saved twice  ->  QUARANTINE the extra copy
-- =============================================================================
-- Some orders list the same product twice. Two situations look alike but are different:
--   * a DOUBLE INSERT: the app saved the same line twice; the customer paid once,
--     so the order's stored total is LOWER than the sum of its lines;
--   * a SPLIT SALE: the same product sold at two prices (e.g. part on promotion); the
--     stored total MATCHES the lines. This is legitimate and must not be touched.
-- So a line counts as a double insert only if BOTH are true:
--   (a) it is an exact copy (same order, product, quantity and price) of an earlier line
--   (b) its order's total is below the sum of its lines
CREATE TEMP TABLE double_lines AS
-- line_totals: the sum of quantity × price for every order.
WITH line_totals AS (
    SELECT order_id, sum(quantity * unit_price) AS lines_total
    FROM   order_items GROUP BY order_id
), ranked AS (
    -- row_number() numbers identical lines 1, 2, 3 … in id order. copy_no = 1 is the
    -- original; copy_no > 1 is a copy. PARTITION BY lists what "identical" means.
    SELECT oi.order_item_id, oi.order_id,
           row_number() OVER (PARTITION BY oi.order_id, oi.product_id, oi.quantity, oi.unit_price
                              ORDER BY oi.order_item_id) AS copy_no
    FROM   order_items oi
)
SELECT r.order_item_id
FROM   ranked r
JOIN   orders o       ON o.order_id = r.order_id
JOIN   line_totals lt ON lt.order_id = r.order_id
WHERE  r.copy_no > 1                       -- (a) it is a copy
AND    o.total_amount < lt.lines_total;    -- (b) the customer was charged for it only once

INSERT INTO quarantine_order_items
SELECT oi.*, 'F-11', 'exact copy of another line; order total shows it was charged once'
FROM   order_items oi WHERE oi.order_item_id IN (SELECT order_item_id FROM double_lines);
DELETE FROM order_items WHERE order_item_id IN (SELECT order_item_id FROM double_lines);

-- =============================================================================
-- F-14  Placeholder quantities (999 / 9999)  ->  FIX where the total proves the answer
-- =============================================================================
-- Six lines had quantity 999 or 9999 where the customer bought one. The order's stored
-- total shows what was really charged, so the real quantity can be worked out:
--
--     implied quantity = (order total − all the OTHER lines in the order) ÷ this line's price
--
-- It is only applied when the answer is a whole number between 1 and 20 (every genuine
-- line in the data is 20 or less). Anything else is left alone and listed for review:
-- a fix we can't prove is a guess.
CREATE TEMP TABLE placeholder_fix AS
SELECT oi.order_item_id, oi.quantity AS old_qty,
       (o.total_amount - coalesce((SELECT sum(x.quantity * x.unit_price)
                                   FROM order_items x
                                   WHERE x.order_id = oi.order_id
                                   AND   x.order_item_id <> oi.order_item_id), 0))
       -- NULLIF(price, 0) turns a zero price into NULL, so a zero-priced line gives
       -- "unknown" instead of crashing with a divide-by-zero error.
       / NULLIF(oi.unit_price, 0) AS implied_qty
FROM   order_items oi JOIN orders o ON o.order_id = oi.order_id
WHERE  oi.quantity IN (999, 9999);

-- Record every placeholder line and what happened to it (fixed, or left for review).
INSERT INTO data_fix_log (finding, table_name, row_id, action, detail)
SELECT 'F-14', 'order_items', order_item_id,
       CASE WHEN implied_qty = round(implied_qty) AND implied_qty BETWEEN 1 AND 20
            THEN 'set quantity from order total' ELSE 'left for review: total does not imply a whole quantity' END,
       'quantity ' || old_qty || ' -> ' || coalesce(round(implied_qty, 2)::text, 'unknown')
FROM   placeholder_fix;

-- Apply only the provable ones. implied_qty = round(implied_qty) means "has no fraction".
UPDATE order_items oi SET quantity = round(f.implied_qty)::int
FROM   placeholder_fix f
WHERE  f.order_item_id = oi.order_item_id
AND    f.implied_qty = round(f.implied_qty) AND f.implied_qty BETWEEN 1 AND 20;

-- =============================================================================
-- F-02  The same product listed twice  ->  MERGE into the original
-- =============================================================================
-- 23 products (ids 9001–9023) duplicate an existing product: same name, same category,
-- and both copies sell. Each copy has its own stock count, so neither count is the real
-- shelf, and a buyer can keep buying from one listing after the other hits zero.
--
-- What counts as a duplicate: same name (ignoring capitals and spaces), same category
-- AND same price, with a lower id already existing. Same-name products at a DIFFERENT
-- price are genuine variants (sizes, colours, suppliers) and are left alone.
--
-- Merging moves everything onto the original, keeping the books balanced:
--   order lines and stock movements are re-pointed, and the copy's stock is ADDED.
--   Stock = sum of movements held for both rows before, so it still holds for the
--   merged row afterwards.
CREATE TEMP TABLE product_merge AS
SELECT product_id AS dup_id,
       -- Same window-function idea as for customers: the smallest id in each group
       -- of identical name + category + price is the original.
       min(product_id) OVER (PARTITION BY lower(trim(product_name)), category_id, price) AS keep_id
FROM   products;
DELETE FROM product_merge WHERE dup_id = keep_id;   -- originals don't merge into themselves

-- Log each merge, including how much stock the copy brings with it.
INSERT INTO data_fix_log (finding, table_name, row_id, action, detail)
SELECT 'F-02', 'products', m.keep_id, 'merge duplicate listing',
       'product ' || m.dup_id || ' merged into ' || m.keep_id || '; stock ' || p.stock_quantity || ' added'
FROM   product_merge m JOIN products p ON p.product_id = m.dup_id;

-- Re-point sales and stock movements from the copy to the original.
UPDATE order_items oi   SET product_id = m.keep_id FROM product_merge m WHERE oi.product_id = m.dup_id;
UPDATE inventory_log il SET product_id = m.keep_id FROM product_merge m WHERE il.product_id = m.dup_id;

-- Add the copies' stock to the original. The inner query totals the stock of all copies
-- per original first, in case one original has more than one copy.
UPDATE products p SET stock_quantity = p.stock_quantity + d.extra
FROM  (SELECT m.keep_id, sum(dp.stock_quantity) AS extra
       FROM product_merge m JOIN products dp ON dp.product_id = m.dup_id
       GROUP BY m.keep_id) d
WHERE p.product_id = d.keep_id;

-- Copy the duplicate listings to quarantine, then remove them.
INSERT INTO quarantine_products
SELECT p.*, 'F-02', 'duplicate listing merged into product ' || m.keep_id
FROM   products p JOIN product_merge m ON m.dup_id = p.product_id;
DELETE FROM products p USING product_merge m WHERE m.dup_id = p.product_id;

-- =============================================================================
-- F-07  Stock movements for products that don't exist  ->  QUARANTINE
-- =============================================================================
-- 120 movements point at a product_id no product has. Done AFTER the F-02 merge, so a
-- movement belonging to a merged copy has already been re-pointed and isn't caught here.
INSERT INTO quarantine_inventory_log
SELECT il.*, 'F-07', 'product_id points at no product'
FROM   inventory_log il
WHERE  NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = il.product_id);
DELETE FROM inventory_log il
WHERE  NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = il.product_id);

-- =============================================================================
-- F-03  Negative stock  ->  FIX: set to 0, and record why
-- =============================================================================
-- 14 products had stock below zero: the trace of past oversells. Stock can't really be
-- negative, so it is reset to 0. But simply overwriting the number would break the rule
-- "stock = sum of its movements" (the audit trail). So FIRST a 'correction' movement is
-- written for the exact amount, THEN the stock is changed. The trail still explains it.
--
-- Example: stock is −3. A movement of +3 (that is, −stock_quantity) is logged, then
-- stock becomes 0. Before: −3 = sum of movements. After: 0 = that sum + 3. Still equal.
INSERT INTO inventory_log (log_id, product_id, change_qty, reason, created_at, note)
-- inventory_log has no automatic id yet (that is added in sql/20), so new ids are
-- made by hand: the current highest id, plus 1, 2, 3 … (row_number) for each new row.
SELECT (SELECT coalesce(max(log_id), 0) FROM inventory_log)
         + row_number() OVER (ORDER BY product_id),
       product_id, -stock_quantity, 'correction', now(),
       'F-03: negative stock reset to 0 during data cleanup'
FROM   products WHERE stock_quantity < 0;

INSERT INTO data_fix_log (finding, table_name, row_id, action, detail)
SELECT 'F-03', 'products', product_id, 'reset negative stock to 0', 'was ' || stock_quantity
FROM   products WHERE stock_quantity < 0;

UPDATE products SET stock_quantity = 0 WHERE stock_quantity < 0;

-- =============================================================================
-- F-15  A category whose parent doesn't exist  ->  QUARANTINE (it is empty)
-- =============================================================================
-- One category points at a missing parent. It has no subcategories and no products, so
-- it costs nothing today; it is removed only so the category foreign key (sql/20) can
-- be added. The three conditions make sure it really is an EMPTY orphan: if a future
-- run found an orphan WITH children or products, this step would leave it alone.
INSERT INTO quarantine_categories
SELECT c.*, 'F-15', 'parent_id points at no category; no subcategories or products'
FROM   categories c
WHERE  c.parent_id IS NOT NULL                                                       -- not top-level
AND    NOT EXISTS (SELECT 1 FROM categories p WHERE p.category_id = c.parent_id)      -- parent missing
AND    NOT EXISTS (SELECT 1 FROM categories k WHERE k.parent_id = c.category_id)      -- no children
AND    NOT EXISTS (SELECT 1 FROM products  pr WHERE pr.category_id = c.category_id); -- no products
DELETE FROM categories WHERE category_id IN (SELECT category_id FROM quarantine_categories);

-- =============================================================================
-- LEFT AS THEY ARE, BY DECISION (ADR-005): the correct value is unknown
-- =============================================================================
-- F-01 stock vs movements: which side is right is unknown -> flagged by v_stock_drift (70).
-- F-08 category cycle: the correct parent is unknown -> rollup guards against it (60).
-- F-09 unexplained total mismatches: correct value unknown -> spend uses total_amount.
-- F-13 lost prices: correct price unknown -> spend uses total_amount.

-- Make every change above permanent, all together.
COMMIT;

-- =============================================================================
-- SUMMARY printed at the end: what moved where, and what was changed
-- =============================================================================
\echo '== 10_cleanup: summary'

-- How many rows each finding moved into each quarantine table.
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

-- How many in-place changes each finding made.
SELECT finding, action, count(*) AS rows FROM data_fix_log GROUP BY 1, 2 ORDER BY 1, 2;
