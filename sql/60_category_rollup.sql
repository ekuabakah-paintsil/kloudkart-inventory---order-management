-- =============================================================================
-- 60_category_rollup.sql  —  Nana's 3rd criterion: low stock at a glance, by category
-- =============================================================================
--
-- WHAT NANA ASKED FOR
--   "Low-stock visibility at a glance, rolled up through the nested category tree
--   (Electronics → Phones → Phone Accessories → Cases), in a couple of seconds."
--   ROLLED UP means a category's numbers include everything beneath it, at every level:
--   "Electronics" counts the low-stock cases inside Phone Accessories inside Phones.
--
-- THE THREE TRAPS, AND HOW THIS FILE AVOIDS THEM (decision record ADR-007)
--   * No fixed depth: a recursive query walks the tree however deep marketing makes it.
--   * Loop-proof: the CYCLE clause stops a walk the moment it revisits a category, so the
--     9001 <-> 9002 loop (F-08) cannot make the rollup run forever. Categories that never
--     reach a top-level department are flagged has_root = false. A depth limit (50) is a
--     second guard, as the Learning Path (chapter 9.1) recommends: CYCLE tells you a loop
--     exists; the depth limit guarantees termination whatever else goes wrong.
--   * No double-counting: each category's figures mean "products anywhere beneath it,
--     counted once" (the closure list holds each ancestor/descendant pair once).
--   * Uncategorised products (category_id NULL, allowed by design) get their own row, so
--     their low stock is not invisible.
--
-- "Low stock" = stock at or below the product's low_stock_threshold. The brief does not
-- define it; default 10 units, adjustable per product by Nana's team.
--
-- KEY IDEA: RECURSIVE QUERIES  (WITH RECURSIVE)
--   A recursive query has two halves joined by UNION ALL:
--     1. the STARTING rows (e.g. every category)
--     2. a step that takes the rows found so far and finds the next level
--        (e.g. their children)
--   PostgreSQL repeats step 2 until it finds nothing new. Because it simply repeats,
--   it works for 3 levels or 30, with no depth written anywhere.
-- =============================================================================

\echo '== 60_category_rollup: low-stock rollup'

BEGIN;

-- The threshold column. NOT NULL DEFAULT 10: every existing and future product gets 10
-- unless someone sets another value (e.g. UPDATE products SET low_stock_threshold = 50
-- WHERE product_id = …). The CHECK stops a nonsensical negative threshold.
ALTER TABLE products ADD COLUMN low_stock_threshold integer NOT NULL DEFAULT 10
    CONSTRAINT products_low_stock_threshold_not_negative CHECK (low_stock_threshold >= 0);

-- -----------------------------------------------------------------------------
-- v_category_closure: every (ancestor, descendant) pair in the tree
-- -----------------------------------------------------------------------------
-- Every (ancestor, descendant) pair in the tree, including each category with itself.
-- Example: Electronics(1) > Phones(2) > Cases(3) gives
--   (1,1) (1,2) (1,3)   Electronics contains itself, Phones and Cases
--   (2,2) (2,3)         Phones contains itself and Cases
--   (3,3)               Cases contains itself
-- With this list, "everything under Electronics" is just: all rows where ancestor = 1.
CREATE VIEW v_category_closure AS
WITH RECURSIVE down (ancestor_id, descendant_id, depth) AS (
    -- 1. Start: every category is its own ancestor, at depth 0.
    SELECT category_id, category_id, 0 FROM categories
    UNION ALL
    -- 2. Step: for each pair found so far, the CHILDREN of the descendant are also
    --    descendants of the same ancestor, one level deeper.
    SELECT d.ancestor_id, c.category_id, d.depth + 1
    FROM   down d
    JOIN   categories c ON c.parent_id = d.descendant_id
    -- SECOND GUARD, a depth limit (Learning Path, chapter 9.1: "use both"). The tree is
    -- 3-4 levels deep today; 50 is far beyond anything marketing will build, so it never
    -- cuts a real path short, but it guarantees the walk ends even if CYCLE were removed.
    WHERE  d.depth < 50
-- CYCLE (PostgreSQL 14+): remembers each walk's path. If a walk reaches a category already
-- on its path (a loop), that row is marked is_cycle = true and the walk STOPS there.
-- Without this, 9001 -> 9002 -> 9001 -> … would repeat forever.
) CYCLE descendant_id SET is_cycle USING walk_path
-- Keep only genuine pairs (not the "we've looped back" marker rows). DISTINCT removes any
-- pair reached by two routes.
SELECT DISTINCT ancestor_id, descendant_id
FROM   down
WHERE  NOT is_cycle;

-- -----------------------------------------------------------------------------
-- v_category_path: each category's full path, and whether it reaches the top
-- -----------------------------------------------------------------------------
-- Each category with its full path from the top, e.g. "Electronics > Phones > Cases".
-- This walk goes UP (child -> parent), building the path text as it climbs.
CREATE VIEW v_category_path AS
WITH RECURSIVE up (category_id, current_id, path, depth) AS (
    -- 1. Start: each category, with its own name as the path so far, and its parent
    --    as the next one to visit (current_id).
    SELECT c.category_id, c.parent_id, c.category_name::text, 0
    FROM   categories c
    UNION ALL
    -- 2. Step: visit the parent, put its name in FRONT of the path, move on to ITS parent.
    --    At a top-level category current_id becomes NULL and the join finds nothing,
    --    so that walk ends.
    SELECT u.category_id, p.parent_id, p.category_name || ' > ' || u.path, u.depth + 1
    FROM   up u
    JOIN   categories p ON p.category_id = u.current_id
    WHERE  u.depth < 50                                  -- depth limit: the second guard
) CYCLE current_id SET is_cycle USING walk_path
-- Every step of every walk is a row; keep ONE row per category: the finished one.
-- DISTINCT ON (category_id) keeps the first row per category in the ORDER BY:
--   rows that reached the top (current_id IS NULL, no loop) come first, and among those
--   the deepest = the complete path. Looping categories never reach the top, so they
--   keep their longest partial path and has_root = false.
SELECT DISTINCT ON (category_id)
       category_id, path, depth AS level,
       (current_id IS NULL AND NOT is_cycle) AS has_root
FROM   up
ORDER  BY category_id, (current_id IS NULL AND NOT is_cycle) DESC, depth DESC;

-- -----------------------------------------------------------------------------
-- v_low_stock_rollup: THE ROLLUP, one row per category (any level) + uncategorised
-- -----------------------------------------------------------------------------
-- How a row is built, e.g. for Electronics:
--   v_category_path      gives the category and its path
--   v_category_closure   gives every category under it (itself included)
--   products             gives every product in any of those categories
--   then count / sum them.
-- LEFT JOINs keep categories that have no products (they show 0 instead of vanishing).
CREATE VIEW v_low_stock_rollup AS
SELECT cp.category_id,
       cp.path,
       cp.level,
       cp.has_root,
       count(p.product_id)                                                        AS products,
       count(p.product_id) FILTER (WHERE p.stock_quantity = 0)                    AS out_of_stock,
       count(p.product_id) FILTER (WHERE p.stock_quantity <= p.low_stock_threshold) AS low_stock,
       coalesce(sum(p.stock_quantity), 0)                                         AS units_in_stock
FROM   v_category_path cp
LEFT   JOIN v_category_closure cl ON cl.ancestor_id = cp.category_id
LEFT   JOIN products p            ON p.category_id  = cl.descendant_id
GROUP  BY cp.category_id, cp.path, cp.level, cp.has_root
UNION ALL
-- One extra row for products with no category: without it, their low stock would
-- appear nowhere in the rollup.
SELECT NULL, '(uncategorised)', 0, false,
       count(*),
       count(*) FILTER (WHERE stock_quantity = 0),
       count(*) FILTER (WHERE stock_quantity <= low_stock_threshold),
       coalesce(sum(stock_quantity), 0)
FROM   products
WHERE  category_id IS NULL;

-- -----------------------------------------------------------------------------
-- v_low_stock_products: the products behind the numbers
-- -----------------------------------------------------------------------------
-- The products behind the numbers, for drilling down from a rollup row.
-- e.g. the rollup says "Phone Accessories: 4 low"; this lists those 4, most urgent first.
CREATE VIEW v_low_stock_products AS
SELECT p.product_id, p.product_name, p.stock_quantity, p.low_stock_threshold,
       coalesce(cp.path, '(uncategorised)') AS category_path,
       coalesce(cp.has_root, false)         AS category_has_root
FROM   products p
LEFT   JOIN v_category_path cp ON cp.category_id = p.category_id
WHERE  p.stock_quantity <= p.low_stock_threshold
ORDER  BY p.stock_quantity, p.product_id;

COMMIT;

\echo '== 60_category_rollup: done. Try: SELECT * FROM v_low_stock_rollup ORDER BY path;'
