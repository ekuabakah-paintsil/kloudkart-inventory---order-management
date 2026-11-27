-- =============================================================================
-- 40_place_order.sql  —  Nana's 1st criterion: no overselling, ever
-- =============================================================================
--
-- THE PROBLEM
--   Last month two orders arrived at the same moment for the last unit of the best-seller.
--   Both read "1 in stock", both said "yes", both took it: stock went to −1 and a customer
--   paid for something that didn't exist. That is a RACE: two things happening at once,
--   and the result depending on who gets there first.
--
-- THE CONTRACT (fixed by race_test.py, which must pass unmodified)
--   place_order(customer, product, quantity) returns (success, order_id, message)
--     success  -> success = true, order_id = the new order
--     no stock -> success = false, order_id = NULL, message contains "out of stock"
--     it must NEVER raise an error under contention, never leave stock below zero,
--     and take the stock, create the order and log the movement all together or not at all.
--
-- =============================================================================
-- THE MECHANISM: one conditional UPDATE  (decision record ADR-001)
-- =============================================================================
-- Mechanism: one conditional UPDATE.
--     UPDATE products SET stock_quantity = stock_quantity - q
--     WHERE product_id = p AND stock_quantity >= q
--
-- In words: "take q units off this product, BUT ONLY IF it still has at least q."
-- The check and the subtraction are ONE statement, so nothing can happen between them.
--
-- How it holds under contention (PostgreSQL's default isolation, Read Committed):
--   * The UPDATE takes a row lock on the product. A second buyer's UPDATE on the same
--     product waits for the first transaction to finish.
--   * When it resumes, PostgreSQL re-checks the WHERE condition against the row as the
--     first buyer left it. If stock is now too low, no row matches: zero rows updated,
--     which this function reports as "out of stock". No error is raised, nothing retries.
--   * Check and decrement are one statement, so no other buyer can act between them.
-- The CHECK (stock_quantity >= 0) from 20_constraints.sql is a safety net under this: if
-- any other code path ever tries to oversell, the database refuses instead of going negative.
--
-- HOW THIS RELATES TO "SELECT ... FOR UPDATE" (Learning Path, chapter 14)
--   The course's pattern is: SELECT ... FOR UPDATE (lock and read), decide, then UPDATE.
--   This function does the same thing in one statement: an UPDATE locks the row it changes
--   by itself, and the "decide" step is the WHERE condition. Same guarantee, fewer steps,
--   and the lock is held for less time, which matters when 400 buyers queue on one row.
--
--   WHICH LOCK MODE? An UPDATE that changes only non-key columns (stock_quantity is not a
--   key) takes a FOR NO KEY UPDATE row lock, one step weaker than FOR UPDATE. For this
--   purpose they behave the same: FOR NO KEY UPDATE conflicts with itself, so the second
--   buyer's UPDATE still waits for the first. The one thing it does NOT block is
--   FOR KEY SHARE, the lock a foreign-key check takes, so inserting order lines that point
--   at this product never waits on it. FOR UPDATE would block those too, for no benefit.
--
--   NO lock_timeout IS SET, DELIBERATELY. A timeout that fires raises an error, and
--   race_test counts any error reaching the caller as a failure. The wait is bounded instead
--   by keeping the transaction short (three inserts, no outside calls): 400 buyers for 50
--   units resolved in 3.48 seconds on the real extract. (ADR-001, "What this survives".)
--
-- WALK-THROUGH: two buyers, Ama and Kofi, one unit left
--   10:00:00.000  Ama's UPDATE finds stock 1 >= 1, locks the product row, sets stock to 0.
--   10:00:00.001  Kofi's UPDATE reaches the same row, finds it locked, and WAITS.
--   10:00:00.004  Ama's order, line and movement are written; her transaction commits;
--                 the lock is released.
--   10:00:00.004  Kofi's UPDATE wakes up and re-checks its WHERE against the NEW row:
--                 is 0 >= 1? No. Zero rows updated. Kofi gets "out of stock".
--   No error, no retry, and stock never went below 0.
--
-- Rejected alternatives (see the decision record):
--   * Read stock, then update (no lock): two buyers both read 1 and both sell it. This is
--     the race Nana already has.
--   * Trigger or CHECK alone: a CHECK turns the second sale into an ERROR, and race_test
--     counts any error reaching the client as a failure; a trigger that reads stock before
--     the update has the same race as above.
--   * Serializable isolation with retries: a function cannot switch its own transaction to
--     Serializable, and the test calls it at the default level.
--
-- Stock is now committed when the order is PLACED (status 'pending'), not at fulfilment.
-- cancel_order() therefore returns the stock, with its own movement in the trail.
-- (Decision record ADR-001.)
-- =============================================================================

\echo '== 40_place_order: order placement and cancellation'

-- CREATE OR REPLACE: create the function, or overwrite it if it already exists.
-- RETURNS TABLE (…): the function returns rows with these three columns. The test reads
-- them with  SELECT success, order_id, message FROM place_order(…).
-- LANGUAGE plpgsql: PostgreSQL's own programming language (variables, IF, loops) for
-- functions that need more than a single query.
-- Note there is no BEGIN/COMMIT inside: the CALLER's transaction wraps the whole function.
-- In race_test each call runs in its own transaction, so either everything below
-- happens, or (on any error) none of it does.
CREATE OR REPLACE FUNCTION place_order(
    p_customer_id  bigint,      -- p_ prefix = "parameter", so names never clash with columns
    p_product_id   bigint,
    p_quantity     integer
) RETURNS TABLE (success boolean, order_id bigint, message text)
LANGUAGE plpgsql AS $$
-- The returned column "order_id" has the same name as the orders.order_id column.
-- This directive tells plpgsql: where a name could mean either, it means the COLUMN.
#variable_conflict use_column
DECLARE
    -- Local variables, filled in as the function runs.
    v_price     numeric(12,2);   -- the product's price at the moment of sale
    v_left      integer;         -- stock remaining after this sale (for the message)
    v_order_id  bigint;          -- the id PostgreSQL gives the new order
BEGIN
    -- ---- Guard 1: a sensible quantity. Without it, quantity −5 would ADD stock.
    -- RETURN QUERY SELECT … adds one result row; the bare RETURN then ends the function.
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Quantity must be at least 1';
        RETURN;
    END IF;

    -- ---- Guard 2: the customer must exist. Without this check, the INSERT into orders
    -- below would hit the foreign key and raise an ERROR, and the contract says reply,
    -- don't crash.
    IF NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = p_customer_id) THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Unknown customer ' || p_customer_id;
        RETURN;
    END IF;

    -- ---- THE KEY STEP. Check and take the stock in one locked step.
    -- RETURNING … INTO … hands back values from the row just updated (its price and the
    -- stock now left) straight into the variables, with no second read of the table.
    UPDATE products p
    SET    stock_quantity = p.stock_quantity - p_quantity
    WHERE  p.product_id = p_product_id
    AND    p.stock_quantity >= p_quantity
    RETURNING p.price, p.stock_quantity INTO v_price, v_left;

    -- FOUND is a plpgsql flag: true if the last statement touched a row. Not found means
    -- either the product doesn't exist, or it doesn't have enough stock. Tell them apart
    -- so the caller gets an accurate message.
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM products p WHERE p.product_id = p_product_id) THEN
            -- The words "out of stock" are what race_test looks for (case-insensitive).
            RETURN QUERY SELECT false, NULL::bigint,
                'Sorry, this item is out of stock (requested ' || p_quantity || ')';
        ELSE
            RETURN QUERY SELECT false, NULL::bigint, 'Unknown product ' || p_product_id;
        END IF;
        RETURN;
    END IF;

    -- ---- Stock is taken and the row is still locked by us. Now record the sale.
    -- Same transaction as the stock decrement: if any of these fail, the decrement is
    -- undone too. No order without its stock movement, no movement without its order.

    -- The order. order_id is left out, so PostgreSQL generates it (identity, sql/20).
    -- Status 'pending': stock is committed at placement (ADR-001).
    -- Total = price × quantity, computed here, so the stored total and the line below
    -- always agree. That kind of disagreement (F-09) can't happen for new orders.
    INSERT INTO orders (customer_id, order_date, status, total_amount)
    VALUES (p_customer_id, now(), 'pending', v_price * p_quantity)
    RETURNING orders.order_id INTO v_order_id;

    -- The order line. unit_price records the price at the moment of sale; it will stay
    -- correct even if the product's price changes later.
    INSERT INTO order_items (order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_price);

    -- The stock movement for the audit trail: negative = stock going out. It carries the
    -- order id, so an auditor can tie every unit sold to its order (sql/30).
    INSERT INTO inventory_log (product_id, change_qty, reason, created_at, order_id)
    VALUES (p_product_id, -p_quantity, 'sale', now(), v_order_id);

    -- Success: the one row the caller reads.
    RETURN QUERY SELECT true, v_order_id,
        'Order ' || v_order_id || ' placed; ' || v_left || ' left in stock';
END;
$$;

-- A comment stored IN the database, visible to anyone who inspects the function later
-- (for example with  \df+ place_order  in psql).
COMMENT ON FUNCTION place_order(bigint, bigint, integer) IS
    'Places a one-product order. Takes stock with a conditional update (row lock), so concurrent buyers can never oversell; refusals say "out of stock".';

-- =============================================================================
-- cancel_order: give the stock back
-- =============================================================================
-- Returns a cancelled order's stock to the shelf. Without this, deducting at placement
-- would leak stock every time an order is cancelled.
-- Only PENDING orders can be cancelled here. A shipped order has left the warehouse;
-- getting that stock back is a 'return', a different process.
CREATE OR REPLACE FUNCTION cancel_order(p_order_id bigint)
RETURNS TABLE (success boolean, message text)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_status text;      -- the order's current status
    r        record;    -- one order line at a time, in the loop below
BEGIN
    -- FOR UPDATE locks the order row. If two people press "cancel" at the same moment,
    -- the second waits, then sees status 'cancelled' and is refused, so the stock can't
    -- be returned twice. (The same idea as place_order's row lock.)
    SELECT o.status INTO v_status FROM orders o WHERE o.order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Unknown order ' || p_order_id; RETURN;
    END IF;
    IF v_status <> 'pending' THEN
        RETURN QUERY SELECT false, 'Only pending orders can be cancelled (status ' || v_status || ')'; RETURN;
    END IF;

    -- For every line of the order: put the units back, and record why in the trail.
    -- ORDER BY product_id: each UPDATE below locks a product row. An order with several
    -- products locks several rows, and two cancellations that lock the same products in
    -- opposite orders would DEADLOCK (each waiting for a row the other holds). Always
    -- locking in product_id order makes that impossible (Learning Path, chapter 14.1).
    FOR r IN SELECT oi.product_id, oi.quantity FROM order_items oi WHERE oi.order_id = p_order_id
             ORDER BY oi.product_id LOOP
        UPDATE products p SET stock_quantity = p.stock_quantity + r.quantity
        WHERE  p.product_id = r.product_id;
        -- Positive change_qty = stock coming back in.
        INSERT INTO inventory_log (product_id, change_qty, reason, created_at, order_id)
        VALUES (r.product_id, r.quantity, 'cancellation', now(), p_order_id);
    END LOOP;

    -- The order keeps its total; the status records that it was cancelled (ADR-003).
    UPDATE orders o SET status = 'cancelled' WHERE o.order_id = p_order_id;
    RETURN QUERY SELECT true, 'Order ' || p_order_id || ' cancelled; stock returned';
END;
$$;

\echo '== 40_place_order: done'
