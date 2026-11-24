-- 03_category_cycles.sql (investigation, not part of run_all)
-- Finds cycles in the category tree and what hangs below orphan categories.
-- Results recorded in docs/working_notes.md.
-- Run: docker exec -w /lab -i kloudkart psql -U postgres -f sql/03_category_cycles.sql

-- Walk up from every category; report any category whose path returns to itself.
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

-- Everything below the orphan category(ies)
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