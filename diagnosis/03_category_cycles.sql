-- =============================================================================
-- 03_category_cycles.sql  (investigation, not part of run_all)
-- =============================================================================
-- Finds cycles in the category tree and what hangs below orphan categories.
-- Results recorded in docs/working_notes.md.
--
-- WHY THIS MATTERS
--   The low-stock rollup (sql/60) walks the category tree. A loop (A's parent is B,
--   B's parent is A) would make a naive walk run forever, and the products in it would
--   belong to no department. An orphan category (parent missing) cuts off everything
--   below it. This script measures both. Found: one loop (9001 <-> 9002, 6 products) and
--   one orphan with nothing below it.
--
-- Run: docker exec -w /lab -i kloudkart psql -U postgres -f diagnosis/03_category_cycles.sql
-- =============================================================================

-- ---------------------------------------------------------------- QUERY 1: loops
-- Walk up from every category; report any category whose path returns to itself.
-- WITH RECURSIVE: start with every category, then repeatedly step to its parent.
--   path      the categories visited so far, as an array: {5, 2, 1}
--   is_cycle  true when the next category is ALREADY in the path (= ANY(path)), a loop
-- WHERE NOT w.is_cycle stops a walk once it has looped. That guard is what makes this
-- query finish even though the data contains a loop; the rollup in sql/60 uses the same
-- idea (via the CYCLE clause).
WITH RECURSIVE walk AS (
    SELECT category_id AS start_id,
           parent_id   AS current_id,
           ARRAY[category_id] AS path,
           false       AS is_cycle
    FROM   categories
    UNION ALL
    SELECT w.start_id,
           c.parent_id,
           w.path || c.category_id,
           c.category_id = ANY(w.path)
    FROM   walk w
    JOIN   categories c ON c.category_id = w.current_id
    WHERE  NOT w.is_cycle
)
SELECT start_id, path
FROM   walk
WHERE  is_cycle
ORDER  BY start_id;

-- ---------------------------------------------------------------- QUERY 2: orphans
-- Everything below the orphan category(ies)
-- orphan: categories whose parent doesn't exist (LEFT JOIN finds no parent).
-- below:  a recursive walk DOWN (parent -> children) from each orphan, collecting every
--         category beneath it at any depth; the path array again guards against loops.
-- Result: how many categories and products would vanish from the rollup. Here 1 and 0,
-- which is why this finding is ranked lowest (F-15).
WITH RECURSIVE orphan AS (
    SELECT c.category_id
    FROM   categories c
    LEFT   JOIN categories p ON p.category_id = c.parent_id
    WHERE  c.parent_id IS NOT NULL AND p.category_id IS NULL
), below AS (
    SELECT category_id, ARRAY[category_id] AS path FROM orphan
    UNION ALL
    SELECT c.category_id, b.path || c.category_id
    FROM   below b
    JOIN   categories c ON c.parent_id = b.category_id
    WHERE  NOT c.category_id = ANY(b.path)
)
SELECT (SELECT count(*) FROM below)                                         AS categories_cut_off,
       (SELECT count(*) FROM products WHERE category_id IN (SELECT category_id FROM below)) AS products_cut_off;