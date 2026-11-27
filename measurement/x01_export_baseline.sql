-- =============================================================================
-- x01_export_baseline.sql  (export only, NOT part of run_all)
-- =============================================================================
--
-- WHAT IT DOES
--   Saves the 56 integrity checks on the RAW data as a CSV: the BEFORE half of the
--   before/after comparison. (x90_export_results.sql saves the AFTER half.)
--   Also saves the column-by-column profile of the raw data (diagnosis/05_profile.sql).
--   Counts, lengths and codes only, no customer data: safe to commit.
--
-- RUN IT on the raw load, i.e. after schema.sql + load.sql and BEFORE 00_run_all.sql:
--   docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f schema.sql
--   docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f load.sql
--   docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f measurement/x01_export_baseline.sql
--
-- (See x90_export_results.sql for what \! mkdir, \pset format csv and \o do.)
-- =============================================================================

\set ON_ERROR_STOP on
\! mkdir -p results
\pset format csv

-- The checks on the data exactly as delivered.
\o results/integrity_checks_before.csv
\i diagnosis/01_integrity_checks.sql

-- Raw row counts: the "Raw load" rows of the Reconciliation table.
-- The column profile of the data exactly as delivered.
\o results/profile_before.csv
\i diagnosis/05_profile.sql

\o results/row_counts_before.csv
SELECT 'categories' AS table_name, count(*) AS rows FROM categories
UNION ALL SELECT 'products',      count(*) FROM products
UNION ALL SELECT 'customers',     count(*) FROM customers
UNION ALL SELECT 'orders',        count(*) FROM orders
UNION ALL SELECT 'order_items',   count(*) FROM order_items
UNION ALL SELECT 'inventory_log', count(*) FROM inventory_log;

\o
\pset format aligned
\echo '== done: results/integrity_checks_before.csv, results/profile_before.csv and results/row_counts_before.csv'
