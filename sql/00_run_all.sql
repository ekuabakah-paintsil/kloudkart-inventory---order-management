-- =============================================================================
-- 00_run_all.sql  —  build the whole solution from nothing
-- =============================================================================
--
-- WHAT THIS FILE IS FOR
--   The brief says the solution must "run top to bottom against a fresh load".
--   This file is that guarantee: it throws away whatever is in the database,
--   reloads Kloud Kart's extract exactly as delivered, and then applies every
--   part of the solution in the one order that works. Nobody has to remember
--   which script comes first or type anything by hand.
--
-- HOW TO RUN IT (from the repository root, where schema.sql, load.sql and data/ live)
--   docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f sql/00_run_all.sql
--     -w /lab        start psql inside /lab, which is this folder seen from inside Docker,
--                    so "schema.sql" and "data/..." resolve correctly
--     -e PAGER=cat   print results straight to the terminal instead of a scrolling pager
--   Then, from the same folder:  python race_test.py
--
-- WHY THE ORDER MATTERS
--   10 cleanup      must come before 20, because PostgreSQL refuses to add a rule
--                   (e.g. a foreign key) while rows that break it still exist.
--   20 constraints  must come before 40, because place_order relies on the generated
--                   ids and the "stock can't go negative" safety net created in 20.
--   30 audit trail  must come before 40, because place_order writes the order_id
--                   column that 30 adds to inventory_log.
--   50 / 60 / 70    only read from the tables, so they come last.
--
-- Lines starting with a backslash (\set, \i, \echo, \timing) are psql commands, not SQL:
-- they control the psql program itself (stop on error, include a file, print a message).
-- =============================================================================

-- Stop at the FIRST error instead of carrying on. Without this, one failed step would
-- be followed by dozens of confusing knock-on errors, and the build could look finished
-- when it is not.
\set ON_ERROR_STOP on

-- Don't print a "Time:" line after every statement; it would bury the useful output.
\timing off

\echo '== fresh load'

-- \i means "run this file here, as if its contents were pasted in".
-- schema.sql (from the Evalu8 bundle) drops the six tables and recreates them empty.
-- load.sql (also from the bundle) copies the six CSV files in data/ into those tables.
\i schema.sql
\i load.sql

-- load.sql switches timing ON for itself, so switch it off again for the rest of the build.
\timing off

-- -----------------------------------------------------------------------------
-- Clear out objects from a PREVIOUS run of this file.
-- schema.sql only knows about the original six tables. Everything the solution adds
-- (quarantine tables, archive, views, functions) would otherwise still exist from the
-- last run, and the CREATE statements below would fail with "already exists".
-- IF EXISTS makes each DROP harmless on the very first run, when nothing exists yet.
-- CASCADE also removes anything that depends on the object (e.g. a view built on a view).
-- -----------------------------------------------------------------------------
DROP VIEW  IF EXISTS v_data_health, v_stock_drift, v_low_stock_products, v_low_stock_rollup,
                     v_category_path, v_category_closure, monday_report_running_total,
                     monday_report_top100, monday_report, v_spend_orders, v_report_months,
                     v_audit_trail CASCADE;
DROP TABLE IF EXISTS inventory_log_archive, data_fix_log,
                     quarantine_categories, quarantine_products, quarantine_customers,
                     quarantine_orders, quarantine_order_items, quarantine_inventory_log CASCADE;
-- Functions are identified by name AND argument types, which is why place_order is
-- written with its three argument types here.
DROP FUNCTION IF EXISTS place_order(bigint, bigint, integer), cancel_order(bigint),
                        report_anchor_month(), inventory_log_keep_history(), log_opening_stock(),
                        archive_is_append_only() CASCADE;

-- -----------------------------------------------------------------------------
-- The solution, in dependency order (see "WHY THE ORDER MATTERS" above).
-- -----------------------------------------------------------------------------
\i sql/10_cleanup.sql
\i sql/20_constraints.sql
\i sql/30_audit_trail.sql
\i sql/40_place_order.sql
\i sql/50_monday_report.sql
\i sql/60_category_rollup.sql
\i sql/70_improvement.sql

-- ANALYZE refreshes PostgreSQL's statistics about each table (how many rows, how values
-- are spread). The query planner uses these to choose fast plans. After a load and a
-- cleanup that moved thousands of rows, the old statistics would be wrong, and the
-- first report could pick a slow plan.
ANALYZE;

-- -----------------------------------------------------------------------------
-- Evidence printed at the end of every build.
-- -----------------------------------------------------------------------------

-- Row counts AFTER the cleanup. Compared with the raw-load counts, these are the
-- "after fixes" rows of the Reconciliation table in docs/data_findings.md.
\echo '== row counts after cleanup (Reconciliation table in data_findings.md)'
SELECT 'categories' AS table_name, count(*) AS rows FROM categories
UNION ALL SELECT 'products',      count(*) FROM products
UNION ALL SELECT 'customers',     count(*) FROM customers
UNION ALL SELECT 'orders',        count(*) FROM orders
UNION ALL SELECT 'order_items',   count(*) FROM order_items
UNION ALL SELECT 'inventory_log', count(*) FROM inventory_log;

-- The same 56 checks that produced the baseline, run again on the fixed data.
-- Faults that were fixed or quarantined should now show 0; the ones left by decision
-- (see ADR-006) still show their counts.
\echo '== integrity checks after the fixes (compare with the baseline in working_notes.md)'
\i diagnosis/01_integrity_checks.sql

-- The improvement beyond the brief (sql/70): one row per rule that matters to Nana.
\echo '== data health'
SELECT * FROM v_data_health;

\echo '== done: run  python race_test.py  next'
