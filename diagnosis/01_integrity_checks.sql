-- =============================================================================
-- 01_integrity_checks.sql  —  the data diagnosis as one repeatable script
-- =============================================================================
--
-- WHAT IT DOES
--   Runs 56 checks against the data and prints ONE ROW PER CHECK: what it looks for and
--   how many rows fail it. It is the evidence behind docs/data_findings.md.
--
-- WHY ONE SCRIPT INSTEAD OF SEPARATE QUERIES
--   Because it is rerun: once on the raw load (the BEFORE, the baseline recorded in
--   docs/working_notes.md) and again at the end of sql/00_run_all.sql (the AFTER).
--   Comparing the two shows which faults the cleanup removed.
--
-- HOW TO READ THE LABELS
--   fault          should be 0 after the fixes
--   info / review  counts to read, not errors (e.g. top-level categories legitimately
--                  have no parent; products sharing a name are mostly genuine variants)
--   Date checks assume the extract ends 2026-08-31 (last month with real volume).
--
-- HOW IT IS BUILT
--   Every check is a small SELECT that returns two columns: a label and a count.
--   UNION ALL stacks them into one table. ORDER BY at the very end sorts by label.
--   Rule: UNION ALL goes BETWEEN two checks, never before ORDER BY.
--
-- Run: docker exec -w /lab -i kloudkart psql -U postgres -f diagnosis/01_integrity_checks.sql
-- =============================================================================

-- ---------------------------------------------------------------- ORPHANS
-- An "orphan" is a row pointing at something that doesn't exist (e.g. an order line
-- whose order is gone). The schema had no foreign keys, so nothing prevented them.
-- Pattern: LEFT JOIN the child to its parent. A LEFT JOIN keeps every child row even
-- when no parent matches, and fills the parent's columns with NULL. So
--   "parent id IS NULL"   = no parent was found = orphan.
-- "child column IS NOT NULL" leaves out empty values; those are counted by the NULL checks.

SELECT 'orphan: order_items.order_id → orders' AS check_name,
       count(*) AS failing_rows
FROM   order_items oi
LEFT   JOIN orders o ON o.order_id = oi.order_id
WHERE  oi.order_id IS NOT NULL
AND    o.order_id IS NULL

UNION ALL

SELECT 'impossible: products.stock_quantity < 0',
       count(*)
FROM   products
WHERE  stock_quantity < 0

UNION ALL

SELECT 'orphan: products.category_id → categories' AS check_name,
       count(*) AS failing_rows
FROM   products p
LEFT   JOIN categories c ON c.category_id = p.category_id
WHERE  p.category_id IS NOT NULL
AND    c.category_id IS NULL

UNION ALL

SELECT 'orphan: categories.parent_id → categories',
       count(*)
FROM   categories child
LEFT   JOIN categories parent ON parent.category_id = child.parent_id
WHERE  child.parent_id IS NOT NULL
AND    parent.category_id IS NULL

UNION ALL

SELECT 'orphan: orders.customer_id → customers',
       count(*)
FROM   orders o
LEFT   JOIN customers c ON c.customer_id = o.customer_id
WHERE  o.customer_id IS NOT NULL
AND    c.customer_id IS NULL

UNION ALL

SELECT 'orphan: order_items.product_id → products',
       count(*)
FROM   order_items oi
LEFT   JOIN products p ON p.product_id = oi.product_id
WHERE  oi.product_id IS NOT NULL
AND    p.product_id IS NULL

UNION ALL

SELECT 'orphan: inventory_log.product_id → products',
       count(*)
FROM   inventory_log il
LEFT   JOIN products p ON p.product_id = il.product_id
WHERE  il.product_id IS NOT NULL
AND    p.product_id IS NULL

UNION ALL

-- ---------------------------------------------------------------- NULLs (faults)
-- Columns the schema grid says must always have a value. Each check: WHERE col IS NULL.
-- (The schema allowed NULL in every non-id column.)
SELECT 'null (fault): categories.category_name', count(*) FROM categories WHERE category_name IS NULL
UNION ALL SELECT 'null (fault): orders.customer_id', count(*) FROM orders WHERE customer_id IS NULL
UNION ALL SELECT 'null (fault): orders.total_amount', count(*) FROM orders WHERE total_amount IS NULL
UNION ALL SELECT 'null (fault): order_items.order_id', count(*) FROM order_items WHERE order_id IS NULL
UNION ALL SELECT 'null (fault): order_items.product_id', count(*) FROM order_items WHERE product_id IS NULL
UNION ALL SELECT 'null (fault): order_items.quantity', count(*) FROM order_items WHERE quantity IS NULL
UNION ALL SELECT 'null (fault): order_items.unit_price', count(*) FROM order_items WHERE unit_price IS NULL
UNION ALL SELECT 'null (fault): inventory_log.product_id', count(*) FROM inventory_log WHERE product_id IS NULL
UNION ALL SELECT 'null (fault): products.price', count(*) FROM products WHERE price IS NULL
UNION ALL SELECT 'null (fault): products.stock_quantity', count(*) FROM products WHERE stock_quantity IS NULL

-- ---------------------------------------------------------------- NULLs (info)
-- Counted to look at, NOT faults: e.g. 7 categories with no parent are the top-level
-- departments; 37 products with no category are allowed by design.
UNION ALL SELECT 'null (info): categories.parent_id', count(*) FROM categories WHERE parent_id IS NULL
UNION ALL SELECT 'null (info): products.category_id', count(*) FROM products WHERE category_id IS NULL
UNION ALL SELECT 'null (info): products.product_name', count(*) FROM products WHERE product_name IS NULL
UNION ALL SELECT 'null (info): products.created_at', count(*) FROM products WHERE created_at IS NULL
UNION ALL SELECT 'null (info): customers.full_name', count(*) FROM customers WHERE full_name IS NULL
UNION ALL SELECT 'null (info): customers.email', count(*) FROM customers WHERE email IS NULL
UNION ALL SELECT 'null (info): customers.phone', count(*) FROM customers WHERE phone IS NULL
UNION ALL SELECT 'null (info): customers.city', count(*) FROM customers WHERE city IS NULL
UNION ALL SELECT 'null (info): customers.registered_at', count(*) FROM customers WHERE registered_at IS NULL
UNION ALL SELECT 'null (info): orders.order_date', count(*) FROM orders WHERE order_date IS NULL
UNION ALL SELECT 'null (info): orders.status', count(*) FROM orders WHERE status IS NULL
UNION ALL SELECT 'null (info): inventory_log.change_qty', count(*) FROM inventory_log WHERE change_qty IS NULL
UNION ALL SELECT 'null (info): inventory_log.reason', count(*) FROM inventory_log WHERE reason IS NULL
UNION ALL SELECT 'null (info): inventory_log.created_at', count(*) FROM inventory_log WHERE created_at IS NULL
UNION ALL SELECT 'null (info): inventory_log.note', count(*) FROM inventory_log WHERE note IS NULL

-- ---------------------------------------------------------------- IMPOSSIBLE VALUES
-- Values the business can't have: zero or negative prices and quantities, negative stock,
-- and the placeholder quantities 999/9999 (every genuine line is 20 or less).
-- NULLs are not counted here (NULL <= 0 is "unknown", not true): the NULL checks cover them.
UNION ALL SELECT 'impossible: products.price <= 0', count(*) FROM products WHERE price <= 0
UNION ALL SELECT 'impossible: orders.total_amount <= 0', count(*) FROM orders WHERE total_amount <= 0
UNION ALL SELECT 'impossible: order_items.quantity <= 0', count(*) FROM order_items WHERE quantity <= 0
UNION ALL SELECT 'impossible: order_items.unit_price <= 0', count(*) FROM order_items WHERE unit_price <= 0
UNION ALL SELECT 'impossible: order_items.quantity is placeholder (999/9999)', count(*) FROM order_items WHERE quantity IN (999, 9999)

-- ---------------------------------------------------------------- DUPLICATES
-- Each duplicate check returns TWO rows: how many GROUPS are duplicated, and how many
-- ROWS those groups contain (e.g. 533 emails shared by 1,068 customer records).
-- Pattern: GROUP BY the thing that should be unique, keep groups with HAVING count(*) > 1,
-- then count those groups (or add up their sizes) in an outer SELECT.
-- lower(trim(…)) ignores capitals and stray spaces, the way a person would compare them.
-- coalesce(parent_id, -1) makes two top-level categories (both NULL parent) comparable.
-- coalesce(sum(n), 0) returns 0 instead of empty when nothing is duplicated.
UNION ALL
SELECT 'duplicate: customers.email (groups)', count(*)
FROM (SELECT 1 FROM customers WHERE email IS NOT NULL
      GROUP BY lower(trim(email)) HAVING count(*) > 1) d
UNION ALL
SELECT 'duplicate: customers.email (rows)', coalesce(sum(n), 0)
FROM (SELECT count(*) AS n FROM customers WHERE email IS NOT NULL
      GROUP BY lower(trim(email)) HAVING count(*) > 1) d

UNION ALL
SELECT 'duplicate: categories (parent_id, name) (groups)', count(*)
FROM (SELECT 1 FROM categories
      GROUP BY coalesce(parent_id, -1), lower(trim(category_name)) HAVING count(*) > 1) d
UNION ALL
SELECT 'duplicate: categories (parent_id, name) (rows)', coalesce(sum(n), 0)
FROM (SELECT count(*) AS n FROM categories
      GROUP BY coalesce(parent_id, -1), lower(trim(category_name)) HAVING count(*) > 1) d

UNION ALL
SELECT 'duplicate (review): products (name, category) (groups)', count(*)
FROM (SELECT 1 FROM products
      GROUP BY lower(trim(product_name)), category_id HAVING count(*) > 1) d
UNION ALL
SELECT 'duplicate (review): products (name, category) (rows)', coalesce(sum(n), 0)
FROM (SELECT count(*) AS n FROM products
      GROUP BY lower(trim(product_name)), category_id HAVING count(*) > 1) d

UNION ALL
SELECT 'duplicate (review): order_items (order_id, product_id) (groups)', count(*)
FROM (SELECT 1 FROM order_items
      GROUP BY order_id, product_id HAVING count(*) > 1) d
UNION ALL
SELECT 'duplicate (review): order_items (order_id, product_id) (rows)', coalesce(sum(n), 0)
FROM (SELECT count(*) AS n FROM order_items
      GROUP BY order_id, product_id HAVING count(*) > 1) d

-- ---------------------------------------------------------------- DATES
-- Compared with the extract end (2026-08-31), NOT today's date: real trading stopped in
-- August 2026, so anything dated later is wrong even if it is before "today". A check
-- against now() missed 8 orders and 7 movements. (See data_findings.md, F-10.)
UNION ALL SELECT 'date: orders.order_date after extract end (assumed 2026-08-31)', count(*) FROM orders WHERE order_date >= '2026-09-01'
UNION ALL SELECT 'date: inventory_log.created_at after extract end (assumed 2026-08-31)', count(*) FROM inventory_log WHERE created_at >= '2026-09-01'
UNION ALL SELECT 'date: customers.registered_at after extract end (assumed 2026-08-31)', count(*) FROM customers WHERE registered_at >= '2026-09-01'
UNION ALL SELECT 'date: products.created_at after extract end (assumed 2026-08-31)', count(*) FROM products WHERE created_at >= '2026-09-01'

UNION ALL
SELECT 'date: order placed before customer registered', count(*)
FROM   orders o
JOIN   customers c ON c.customer_id = o.customer_id
WHERE  o.order_date < c.registered_at

-- ---------------------------------------------------------------- CONSISTENCY
-- Rules that span more than one row or table, so no single-column check can see them:
-- a category being its own parent, orders with no lines, and an order's stored total
-- disagreeing with the sum of quantity × price of its lines.
UNION ALL
SELECT 'consistency: categories self-parent', count(*)
FROM   categories
WHERE  parent_id = category_id

UNION ALL
SELECT 'consistency: orders with no order_items', count(*)
FROM   orders o
WHERE  NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.order_id)

UNION ALL
SELECT 'consistency: total_amount <> sum of lines', count(*)
FROM   orders o
JOIN  (SELECT order_id, sum(quantity * unit_price) AS lines_total
       FROM   order_items
       GROUP  BY order_id) l ON l.order_id = o.order_id
WHERE  o.total_amount <> l.lines_total

-- ---------------------------------------------------------------- TREE AND STOCK
-- Categories in a loop: a recursive walk up the tree (same technique as diagnosis/03), counting
-- every category whose walk comes back to itself.
-- Stock reconciliation: a product's stock should equal the sum of its recorded movements.
-- Where it doesn't, stock changed without a record (F-01). IS DISTINCT FROM is "not equal"
-- that treats NULL safely; coalesce(m.net, 0) gives products with no movements a total of 0.
UNION ALL
SELECT 'consistency: categories in a cycle', count(DISTINCT start_id)
FROM (
    WITH RECURSIVE walk AS (
        SELECT category_id AS start_id, parent_id AS current_id,
               ARRAY[category_id] AS path, false AS is_cycle
        FROM   categories
        UNION ALL
        SELECT w.start_id, c.parent_id, w.path || c.category_id, c.category_id = ANY(w.path)
        FROM   walk w JOIN categories c ON c.category_id = w.current_id
        WHERE  NOT w.is_cycle
    )
    SELECT start_id FROM walk WHERE is_cycle
) cyc

UNION ALL
SELECT 'consistency: products where stock <> sum of movements', count(*)
FROM   products p
LEFT   JOIN (SELECT product_id, sum(change_qty) AS net FROM inventory_log GROUP BY product_id) m
       USING (product_id)
WHERE  p.stock_quantity IS DISTINCT FROM coalesce(m.net, 0)

-- ---------------------------------------------------------------- VOCABULARY
-- Statuses spelled any way other than the five standard values (F-04). On the raw load
-- 116,394 orders fail this; after the cleanup (sql/10) it should be 0.
UNION ALL
SELECT 'vocabulary: orders.status not in canonical 5', count(*)
FROM   orders
WHERE  status NOT IN ('completed', 'pending', 'shipped', 'cancelled', 'refunded')

ORDER  BY check_name;


