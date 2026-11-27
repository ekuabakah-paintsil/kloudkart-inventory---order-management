-- =============================================================================
-- 30_audit_trail.sql  —  Nana's 4th criterion: proof of what happened
-- =============================================================================
--
-- THE GOAL
--   "A trail of every stock movement (sale, restock, correction) that an auditor could
--   walk through after the fact." The inventory_log table already records movements,
--   and the diagnosis showed it is a complete trail for 96.4% of products. What it
--   lacked was PROTECTION (nothing stopped a row being edited or deleted) and LINKS
--   (a sale didn't say which order caused it).
--
-- THREE LAYERS
--   1. Record   every movement says which order caused it and who wrote it.
--   2. Protect  a movement can never vanish or be rewritten silently: before any UPDATE
--               or DELETE on inventory_log, the old row is copied to inventory_log_archive,
--               and the archive itself refuses all changes.
--   3. Read     v_audit_trail shows live and archived movements in one place.
--
-- WHY ARCHIVE INSTEAD OF SIMPLY FORBIDDING CHANGES? (ADR-005)
--   race_test.py deletes the log rows of its own test products when it cleans up, and it
--   must run unmodified. Forbidding deletes would break it. Archiving keeps the test
--   working AND keeps every removed row on record, with who removed it and when.
--
-- KEY IDEA: TRIGGERS
--   A trigger is a small function PostgreSQL runs AUTOMATICALLY when something happens
--   to a table (an insert, update or delete). Nobody has to remember to call it, which
--   is exactly what you want for an audit: it can't be skipped by forgetful code.
-- =============================================================================

\echo '== 30_audit_trail: movement trail and archive'

BEGIN;

-- =============================================================================
-- 1. RECORD: link each movement to its order and its author
-- =============================================================================
-- order_id links a sale (or cancellation) to the order behind it. Deliberately not a
-- foreign key: race_test deletes orders before their log rows, and a trail entry must
-- outlive the thing it describes.
--   (Put differently: if the order is ever deleted, the movement must still exist and
--    still say which order it was. A foreign key would forbid exactly that.)
ALTER TABLE inventory_log ADD COLUMN order_id    bigint;
-- current_user is the database account that wrote the row. Filled in automatically.
ALTER TABLE inventory_log ADD COLUMN recorded_by text NOT NULL DEFAULT current_user;
-- A PARTIAL index ("WHERE order_id IS NOT NULL"): only rows that have an order are
-- indexed. Historical rows (no order_id) take no space in it. Makes "show me the
-- movements for order X" instant.
CREATE INDEX inventory_log_order_id_idx ON inventory_log (order_id) WHERE order_id IS NOT NULL;

-- =============================================================================
-- 2. PROTECT: nothing in the trail can disappear or change without a record
-- =============================================================================

-- The archive: the same columns as inventory_log, plus WHAT happened to the row
-- (operation), WHEN (archived_at) and WHO did it (archived_by).
CREATE TABLE inventory_log_archive (
    archive_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation     text        NOT NULL,          -- 'UPDATE' or 'DELETE'
    archived_at   timestamptz NOT NULL DEFAULT now(),
    archived_by   text        NOT NULL DEFAULT current_user,
    log_id        bigint      NOT NULL,          -- the id the row had in inventory_log
    product_id    integer,
    change_qty    integer,
    reason        text,
    created_at    timestamptz,
    note          text,
    order_id      bigint,
    recorded_by   text
);
-- Lets an auditor find every archived version of one movement quickly.
CREATE INDEX inventory_log_archive_log_id_idx ON inventory_log_archive (log_id);

-- The trigger FUNCTION: what to do. Inside a trigger:
--   OLD    = the row as it was before the change
--   NEW    = the row as it will be after an UPDATE (there is no NEW for a DELETE)
--   TG_OP  = which operation fired it: 'UPDATE' or 'DELETE'
-- It copies OLD into the archive, then RETURNs a row to tell PostgreSQL to carry on with
-- the original operation. (Returning NULL from a BEFORE trigger would cancel it instead.)
CREATE FUNCTION inventory_log_keep_history() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO inventory_log_archive
        (operation, log_id, product_id, change_qty, reason, created_at, note, order_id, recorded_by)
    VALUES
        (TG_OP, OLD.log_id, OLD.product_id, OLD.change_qty, OLD.reason, OLD.created_at,
         OLD.note, OLD.order_id, OLD.recorded_by);
    -- For a DELETE, carry on deleting OLD; for an UPDATE, carry on writing NEW.
    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

-- The TRIGGER itself: when to run the function.
--   BEFORE   run it before the row is changed, while OLD is still intact
--   FOR EACH ROW   once per affected row (a delete of 240 rows archives 240 rows)
CREATE TRIGGER inventory_log_keep_history
    BEFORE UPDATE OR DELETE ON inventory_log
    FOR EACH ROW EXECUTE FUNCTION inventory_log_keep_history();

-- The archive itself is append-only: nothing may change or remove an archived row.
-- RAISE EXCEPTION stops the statement with an error, so any UPDATE or DELETE on the
-- archive fails and changes nothing. Rows can be ADDED (by the trigger above), never altered.
CREATE FUNCTION archive_is_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'inventory_log_archive is append-only (% refused)', TG_OP;
END;
$$;

CREATE TRIGGER inventory_log_archive_append_only
    BEFORE UPDATE OR DELETE ON inventory_log_archive
    FOR EACH ROW EXECUTE FUNCTION archive_is_append_only();

-- A product created with stock already on the shelf gets that opening stock recorded as
-- its first movement, so its stock is explained by the trail from day one.
--   Without this, every new product would start with stock but no movement, and the
--   stock-drift check (sql/70) would flag it as "stock the trail can't explain".
CREATE FUNCTION log_opening_stock() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note)
    VALUES (NEW.product_id, NEW.stock_quantity, 'restock', now(), 'opening stock');
    RETURN NEW;   -- the return value of an AFTER trigger is ignored; NEW is conventional
END;
$$;

-- AFTER INSERT: the product row must exist first, because the movement's foreign key
-- (sql/20) requires the product to be there. WHEN (…) skips products created with 0 stock.
CREATE TRIGGER products_log_opening_stock
    AFTER INSERT ON products
    FOR EACH ROW WHEN (NEW.stock_quantity > 0)
    EXECUTE FUNCTION log_opening_stock();

-- =============================================================================
-- 3. READ: one place for an auditor to walk the whole trail
-- =============================================================================
-- One place to walk the trail: every movement ever recorded, live or since removed,
-- with the product and (where known) the order and customer behind it.
--
-- A VIEW is a saved query that behaves like a table: SELECT * FROM v_audit_trail
-- runs the query below fresh every time, so it is always up to date.
-- UNION ALL stacks two result sets on top of each other: first the live movements,
-- then the archived ones. Both halves must have the same columns in the same order.
-- LEFT JOIN keeps a movement even if its product or order no longer exists.
CREATE VIEW v_audit_trail AS
SELECT il.log_id, il.created_at AS moved_at, il.product_id, p.product_name,
       il.change_qty, il.reason, il.order_id, o.customer_id, il.note, il.recorded_by,
       'live'::text AS state, NULL::timestamptz AS removed_at, NULL::text AS removed_by
FROM   inventory_log il
LEFT   JOIN products p ON p.product_id = il.product_id
LEFT   JOIN orders   o ON o.order_id   = il.order_id
UNION ALL
SELECT a.log_id, a.created_at, a.product_id, p.product_name,
       a.change_qty, a.reason, a.order_id, NULL, a.note, a.recorded_by,
       -- 'DELETE' -> 'deleted', 'UPDATE' -> 'updated'
       lower(a.operation) || 'd', a.archived_at, a.archived_by
FROM   inventory_log_archive a
LEFT   JOIN products p ON p.product_id = a.product_id;

COMMIT;

\echo '== 30_audit_trail: done'
