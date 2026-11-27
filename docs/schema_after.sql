--
-- PostgreSQL database dump
--

\restrict GKwNGl5ezYtOue4LSCgrfAi3ozIniA3XKNO65ZxOIdHxwXjrjKTTiJhPekvkrXh

-- Dumped from database version 18.7 (Debian 18.7-1.pgdg13+5)
-- Dumped by pg_dump version 18.7 (Debian 18.7-1.pgdg13+5)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: archive_is_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.archive_is_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'inventory_log_archive is append-only (% refused)', TG_OP;
END;
$$;


--
-- Name: cancel_order(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cancel_order(p_order_id bigint) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: inventory_log_keep_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.inventory_log_keep_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: log_opening_stock(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_opening_stock() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note)
    VALUES (NEW.product_id, NEW.stock_quantity, 'restock', now(), 'opening stock');
    RETURN NEW;   -- the return value of an AFTER trigger is ignored; NEW is conventional
END;
$$;


--
-- Name: place_order(bigint, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.place_order(p_customer_id bigint, p_product_id bigint, p_quantity integer) RETURNS TABLE(success boolean, order_id bigint, message text)
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION place_order(p_customer_id bigint, p_product_id bigint, p_quantity integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.place_order(p_customer_id bigint, p_product_id bigint, p_quantity integer) IS 'Places a one-product order. Takes stock with a conditional update (row lock), so concurrent buyers can never oversell; refusals say "out of stock".';


--
-- Name: report_anchor_month(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.report_anchor_month() RETURNS date
    LANGUAGE sql STABLE
    AS $$
    SELECT date_trunc('month', max(order_date) AT TIME ZONE 'Africa/Accra')::date
    FROM   orders
    WHERE  order_date <= now();
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    category_id integer CONSTRAINT categories_category_id_not_null1 NOT NULL,
    category_name text NOT NULL,
    parent_id integer,
    CONSTRAINT categories_not_own_parent CHECK ((parent_id <> category_id))
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    customer_id integer CONSTRAINT customers_customer_id_not_null1 NOT NULL,
    full_name text NOT NULL,
    email text,
    phone text,
    city text,
    registered_at timestamp with time zone
);


--
-- Name: data_fix_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.data_fix_log (
    fix_id bigint NOT NULL,
    finding text NOT NULL,
    table_name text NOT NULL,
    row_id bigint,
    action text NOT NULL,
    detail text,
    fixed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: data_fix_log_fix_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.data_fix_log ALTER COLUMN fix_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.data_fix_log_fix_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: inventory_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_log (
    log_id integer CONSTRAINT inventory_log_log_id_not_null1 NOT NULL,
    product_id integer NOT NULL,
    change_qty integer NOT NULL,
    reason text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    note text,
    order_id bigint,
    recorded_by text DEFAULT CURRENT_USER NOT NULL,
    CONSTRAINT inventory_log_reason_valid CHECK ((reason = ANY (ARRAY['sale'::text, 'restock'::text, 'return'::text, 'correction'::text, 'damage'::text, 'stock_take'::text, 'cancellation'::text])))
);


--
-- Name: inventory_log_archive; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_log_archive (
    archive_id bigint NOT NULL,
    operation text NOT NULL,
    archived_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_by text DEFAULT CURRENT_USER NOT NULL,
    log_id bigint NOT NULL,
    product_id integer,
    change_qty integer,
    reason text,
    created_at timestamp with time zone,
    note text,
    order_id bigint,
    recorded_by text
);


--
-- Name: inventory_log_archive_archive_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.inventory_log_archive ALTER COLUMN archive_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.inventory_log_archive_archive_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: inventory_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.inventory_log ALTER COLUMN log_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.inventory_log_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    order_id integer CONSTRAINT orders_order_id_not_null1 NOT NULL,
    customer_id integer NOT NULL,
    order_date timestamp with time zone DEFAULT now() NOT NULL,
    status text NOT NULL,
    total_amount numeric(12,2) NOT NULL,
    CONSTRAINT orders_status_valid CHECK ((status = ANY (ARRAY['pending'::text, 'shipped'::text, 'completed'::text, 'cancelled'::text, 'refunded'::text]))),
    CONSTRAINT orders_total_positive CHECK ((total_amount > (0)::numeric))
);


--
-- Name: v_spend_orders; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_spend_orders AS
 SELECT order_id,
    customer_id,
    total_amount,
    (date_trunc('month'::text, (order_date AT TIME ZONE 'Africa/Accra'::text)))::date AS month
   FROM public.orders o
  WHERE (status = ANY (ARRAY['pending'::text, 'shipped'::text, 'completed'::text]));


--
-- Name: monday_report; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.monday_report AS
 WITH a AS MATERIALIZED (
         SELECT public.report_anchor_month() AS m
        ), per_customer AS (
         SELECT s.customer_id,
            sum(s.total_amount) AS total_spent,
            count(*) AS order_count,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '11 mons'::interval))) AS m01,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '10 mons'::interval))) AS m02,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '9 mons'::interval))) AS m03,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '8 mons'::interval))) AS m04,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '7 mons'::interval))) AS m05,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '6 mons'::interval))) AS m06,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '5 mons'::interval))) AS m07,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '4 mons'::interval))) AS m08,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '3 mons'::interval))) AS m09,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '2 mons'::interval))) AS m10,
            sum(s.total_amount) FILTER (WHERE (s.month = (a.m - '1 mon'::interval))) AS m11,
            sum(s.total_amount) FILTER (WHERE (s.month = a.m)) AS m12
           FROM (public.v_spend_orders s
             CROSS JOIN a)
          GROUP BY s.customer_id
        )
 SELECT c.customer_id,
    c.full_name,
    COALESCE(pc.total_spent, (0)::numeric) AS total_spent,
    COALESCE(pc.order_count, (0)::bigint) AS order_count,
    COALESCE(pc.m01, (0)::numeric) AS m01,
    COALESCE(pc.m02, (0)::numeric) AS m02,
    COALESCE(pc.m03, (0)::numeric) AS m03,
    COALESCE(pc.m04, (0)::numeric) AS m04,
    COALESCE(pc.m05, (0)::numeric) AS m05,
    COALESCE(pc.m06, (0)::numeric) AS m06,
    COALESCE(pc.m07, (0)::numeric) AS m07,
    COALESCE(pc.m08, (0)::numeric) AS m08,
    COALESCE(pc.m09, (0)::numeric) AS m09,
    COALESCE(pc.m10, (0)::numeric) AS m10,
    COALESCE(pc.m11, (0)::numeric) AS m11,
    COALESCE(pc.m12, (0)::numeric) AS m12,
    rank() OVER (ORDER BY COALESCE(pc.total_spent, (0)::numeric) DESC) AS spend_rank,
    (rank() OVER (ORDER BY COALESCE(pc.total_spent, (0)::numeric) DESC) <= 100) AS is_top_100
   FROM (public.customers c
     LEFT JOIN per_customer pc ON ((pc.customer_id = c.customer_id)));


--
-- Name: monday_report_running_total; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.monday_report_running_total AS
 WITH a AS MATERIALIZED (
         SELECT public.report_anchor_month() AS m
        ), monthly AS (
         SELECT v_spend_orders.customer_id,
            v_spend_orders.month,
            sum(v_spend_orders.total_amount) AS month_spend
           FROM public.v_spend_orders
          GROUP BY v_spend_orders.customer_id, v_spend_orders.month
        ), running AS (
         SELECT monthly.customer_id,
            monthly.month,
            monthly.month_spend,
            sum(monthly.month_spend) OVER (PARTITION BY monthly.customer_id ORDER BY monthly.month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
           FROM monthly
        )
 SELECT r.customer_id,
    r.month,
    r.month_spend,
    r.running_total
   FROM (running r
     CROSS JOIN a)
  WHERE ((r.month > (a.m - '1 year'::interval)) AND (r.month <= a.m));


--
-- Name: monday_report_top100; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.monday_report_top100 AS
 SELECT spend_rank,
    customer_id,
    full_name,
    total_spent,
    order_count
   FROM public.monday_report
  WHERE is_top_100
  ORDER BY spend_rank, customer_id;


--
-- Name: order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_items (
    order_item_id integer CONSTRAINT order_items_order_item_id_not_null1 NOT NULL,
    order_id integer NOT NULL,
    product_id integer NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(12,2),
    CONSTRAINT order_items_quantity_positive CHECK ((quantity > 0))
);


--
-- Name: order_items_order_item_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.order_items ALTER COLUMN order_item_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.order_items_order_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orders_order_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.orders ALTER COLUMN order_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.orders_order_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    product_id integer CONSTRAINT products_product_id_not_null1 NOT NULL,
    product_name text NOT NULL,
    category_id integer,
    price numeric(12,2) NOT NULL,
    stock_quantity integer NOT NULL,
    created_at timestamp with time zone,
    low_stock_threshold integer DEFAULT 10 NOT NULL,
    CONSTRAINT products_low_stock_threshold_not_negative CHECK ((low_stock_threshold >= 0)),
    CONSTRAINT products_price_positive CHECK ((price > (0)::numeric)),
    CONSTRAINT products_stock_not_negative CHECK ((stock_quantity >= 0))
);


--
-- Name: quarantine_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quarantine_categories (
    category_id integer CONSTRAINT categories_category_id_not_null1 NOT NULL,
    category_name text,
    parent_id integer,
    q_finding text NOT NULL,
    q_reason text,
    q_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: quarantine_customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quarantine_customers (
    customer_id integer CONSTRAINT customers_customer_id_not_null1 NOT NULL,
    full_name text,
    email text,
    phone text,
    city text,
    registered_at timestamp without time zone,
    q_finding text NOT NULL,
    q_reason text,
    q_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: quarantine_inventory_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quarantine_inventory_log (
    log_id integer CONSTRAINT inventory_log_log_id_not_null1 NOT NULL,
    product_id integer,
    change_qty integer,
    reason text,
    created_at timestamp without time zone,
    note text,
    q_finding text NOT NULL,
    q_reason text,
    q_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: quarantine_order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quarantine_order_items (
    order_item_id integer CONSTRAINT order_items_order_item_id_not_null1 NOT NULL,
    order_id integer,
    product_id integer,
    quantity integer,
    unit_price numeric(12,2),
    q_finding text NOT NULL,
    q_reason text,
    q_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: quarantine_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quarantine_orders (
    order_id integer CONSTRAINT orders_order_id_not_null1 NOT NULL,
    customer_id integer,
    order_date timestamp without time zone,
    status text,
    total_amount numeric(12,2),
    q_finding text NOT NULL,
    q_reason text,
    q_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: quarantine_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quarantine_products (
    product_id integer CONSTRAINT products_product_id_not_null1 NOT NULL,
    product_name text,
    category_id integer,
    price numeric(12,2),
    stock_quantity integer,
    created_at timestamp without time zone,
    q_finding text NOT NULL,
    q_reason text,
    q_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: v_audit_trail; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_audit_trail AS
 SELECT il.log_id,
    il.created_at AS moved_at,
    il.product_id,
    p.product_name,
    il.change_qty,
    il.reason,
    il.order_id,
    o.customer_id,
    il.note,
    il.recorded_by,
    'live'::text AS state,
    NULL::timestamp with time zone AS removed_at,
    NULL::text AS removed_by
   FROM ((public.inventory_log il
     LEFT JOIN public.products p ON ((p.product_id = il.product_id)))
     LEFT JOIN public.orders o ON ((o.order_id = il.order_id)))
UNION ALL
 SELECT a.log_id,
    a.created_at AS moved_at,
    a.product_id,
    p.product_name,
    a.change_qty,
    a.reason,
    a.order_id,
    NULL::integer AS customer_id,
    a.note,
    a.recorded_by,
    (lower(a.operation) || 'd'::text) AS state,
    a.archived_at AS removed_at,
    a.archived_by AS removed_by
   FROM (public.inventory_log_archive a
     LEFT JOIN public.products p ON ((p.product_id = a.product_id)));


--
-- Name: v_category_closure; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_category_closure AS
 WITH RECURSIVE down(ancestor_id, descendant_id, depth) AS (
         SELECT categories.category_id,
            categories.category_id,
            0 AS "?column?"
           FROM public.categories
        UNION ALL
         SELECT d.ancestor_id,
            c.category_id,
            (d.depth + 1)
           FROM (down d
             JOIN public.categories c ON ((c.parent_id = d.descendant_id)))
          WHERE (d.depth < 50)
        ) CYCLE descendant_id SET is_cycle USING walk_path
 SELECT DISTINCT ancestor_id,
    descendant_id
   FROM down
  WHERE (NOT is_cycle);


--
-- Name: v_category_path; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_category_path AS
 WITH RECURSIVE up(category_id, current_id, path, depth) AS (
         SELECT c.category_id,
            c.parent_id,
            c.category_name,
            0 AS "?column?"
           FROM public.categories c
        UNION ALL
         SELECT u.category_id,
            p.parent_id,
            ((p.category_name || ' > '::text) || u.path),
            (u.depth + 1)
           FROM (up u
             JOIN public.categories p ON ((p.category_id = u.current_id)))
          WHERE (u.depth < 50)
        ) CYCLE current_id SET is_cycle USING walk_path
 SELECT DISTINCT ON (category_id) category_id,
    path,
    depth AS level,
    ((current_id IS NULL) AND (NOT is_cycle)) AS has_root
   FROM up
  ORDER BY category_id, ((current_id IS NULL) AND (NOT is_cycle)) DESC, depth DESC;


--
-- Name: v_stock_drift; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_stock_drift AS
 WITH moves AS (
         SELECT inventory_log.product_id,
            sum(inventory_log.change_qty) AS trail_quantity,
            max(inventory_log.created_at) AS last_movement
           FROM public.inventory_log
          GROUP BY inventory_log.product_id
        )
 SELECT p.product_id,
    p.product_name,
    p.stock_quantity AS stock_on_record,
    COALESCE(m.trail_quantity, (0)::bigint) AS stock_per_trail,
    (p.stock_quantity - COALESCE(m.trail_quantity, (0)::bigint)) AS difference,
        CASE
            WHEN (p.stock_quantity > COALESCE(m.trail_quantity, (0)::bigint)) THEN 'more on record than the trail explains: may sell stock that is not there'::text
            ELSE 'less on record than the trail explains: unrecorded loss, or stock refused'::text
        END AS meaning,
    m.last_movement
   FROM (public.products p
     LEFT JOIN moves m USING (product_id))
  WHERE (p.stock_quantity IS DISTINCT FROM COALESCE(m.trail_quantity, (0)::bigint))
  ORDER BY (abs((p.stock_quantity - COALESCE(m.trail_quantity, (0)::bigint)))) DESC, p.product_id;


--
-- Name: v_data_health; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_data_health AS
 SELECT 'products whose stock does not match their trail'::text AS rule,
    ( SELECT count(*) AS count
           FROM public.v_stock_drift) AS breaches,
    'count these products; investigate changes made outside place_order'::text AS action
UNION ALL
 SELECT 'products with negative stock'::text AS rule,
    ( SELECT count(*) AS count
           FROM public.products
          WHERE (products.stock_quantity < 0)) AS breaches,
    'should be impossible: a database rule now refuses it'::text AS action
UNION ALL
 SELECT 'categories that never reach a top-level department'::text AS rule,
    ( SELECT count(*) AS count
           FROM public.v_category_path
          WHERE (NOT v_category_path.has_root)) AS breaches,
    'give the category a real parent; its products are missing from the low-stock view'::text AS action
UNION ALL
 SELECT 'order lines with no price'::text AS rule,
    ( SELECT count(*) AS count
           FROM public.order_items
          WHERE ((order_items.unit_price IS NULL) OR (order_items.unit_price <= (0)::numeric))) AS breaches,
    'historical only; new lines always carry a price'::text AS action
UNION ALL
 SELECT 'orders whose total differs from their lines'::text AS rule,
    ( SELECT count(*) AS count
           FROM (public.orders o
             JOIN ( SELECT order_items.order_id,
                    sum(((order_items.quantity)::numeric * order_items.unit_price)) AS lines
                   FROM public.order_items
                  GROUP BY order_items.order_id) l USING (order_id))
          WHERE (o.total_amount <> l.lines)) AS breaches,
    'historical; new orders are written in one step and always agree'::text AS action
UNION ALL
 SELECT 'orders dated in the future'::text AS rule,
    ( SELECT count(*) AS count
           FROM public.orders
          WHERE (orders.order_date > now())) AS breaches,
    'check how the date was entered'::text AS action;


--
-- Name: v_low_stock_products; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_low_stock_products AS
 SELECT p.product_id,
    p.product_name,
    p.stock_quantity,
    p.low_stock_threshold,
    COALESCE(cp.path, '(uncategorised)'::text) AS category_path,
    COALESCE(cp.has_root, false) AS category_has_root
   FROM (public.products p
     LEFT JOIN public.v_category_path cp ON ((cp.category_id = p.category_id)))
  WHERE (p.stock_quantity <= p.low_stock_threshold)
  ORDER BY p.stock_quantity, p.product_id;


--
-- Name: v_low_stock_rollup; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_low_stock_rollup AS
 SELECT cp.category_id,
    cp.path,
    cp.level,
    cp.has_root,
    count(p.product_id) AS products,
    count(p.product_id) FILTER (WHERE (p.stock_quantity = 0)) AS out_of_stock,
    count(p.product_id) FILTER (WHERE (p.stock_quantity <= p.low_stock_threshold)) AS low_stock,
    COALESCE(sum(p.stock_quantity), (0)::bigint) AS units_in_stock
   FROM ((public.v_category_path cp
     LEFT JOIN public.v_category_closure cl ON ((cl.ancestor_id = cp.category_id)))
     LEFT JOIN public.products p ON ((p.category_id = cl.descendant_id)))
  GROUP BY cp.category_id, cp.path, cp.level, cp.has_root
UNION ALL
 SELECT NULL::integer AS category_id,
    '(uncategorised)'::text AS path,
    0 AS level,
    false AS has_root,
    count(*) AS products,
    count(*) FILTER (WHERE (products.stock_quantity = 0)) AS out_of_stock,
    count(*) FILTER (WHERE (products.stock_quantity <= products.low_stock_threshold)) AS low_stock,
    COALESCE(sum(products.stock_quantity), (0)::bigint) AS units_in_stock
   FROM public.products
  WHERE (products.category_id IS NULL);


--
-- Name: v_report_months; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_report_months AS
 SELECT ('m'::text || lpad((n)::text, 2, '0'::text)) AS column_name,
    ((public.report_anchor_month() - make_interval(months => (12 - n))))::date AS month
   FROM generate_series(1, 12) n(n);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (category_id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (customer_id);


--
-- Name: data_fix_log data_fix_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_fix_log
    ADD CONSTRAINT data_fix_log_pkey PRIMARY KEY (fix_id);


--
-- Name: inventory_log_archive inventory_log_archive_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_log_archive
    ADD CONSTRAINT inventory_log_archive_pkey PRIMARY KEY (archive_id);


--
-- Name: inventory_log inventory_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_log
    ADD CONSTRAINT inventory_log_pkey PRIMARY KEY (log_id);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (order_item_id);


--
-- Name: order_items order_items_unit_price_positive; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.order_items
    ADD CONSTRAINT order_items_unit_price_positive CHECK ((unit_price > (0)::numeric)) NOT VALID;


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (order_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (product_id);


--
-- Name: categories_name_per_parent_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX categories_name_per_parent_unique ON public.categories USING btree (parent_id, lower(TRIM(BOTH FROM category_name))) NULLS NOT DISTINCT;


--
-- Name: categories_parent_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX categories_parent_id_idx ON public.categories USING btree (parent_id);


--
-- Name: customers_email_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX customers_email_unique ON public.customers USING btree (lower(TRIM(BOTH FROM email)));


--
-- Name: inventory_log_archive_log_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX inventory_log_archive_log_id_idx ON public.inventory_log_archive USING btree (log_id);


--
-- Name: inventory_log_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX inventory_log_order_id_idx ON public.inventory_log USING btree (order_id) WHERE (order_id IS NOT NULL);


--
-- Name: inventory_log_product_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX inventory_log_product_idx ON public.inventory_log USING btree (product_id, created_at);


--
-- Name: order_items_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX order_items_order_id_idx ON public.order_items USING btree (order_id);


--
-- Name: order_items_product_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX order_items_product_id_idx ON public.order_items USING btree (product_id);


--
-- Name: orders_customer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_customer_id_idx ON public.orders USING btree (customer_id);


--
-- Name: orders_order_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_order_date_idx ON public.orders USING btree (order_date);


--
-- Name: products_category_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX products_category_id_idx ON public.products USING btree (category_id);


--
-- Name: inventory_log_archive inventory_log_archive_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER inventory_log_archive_append_only BEFORE DELETE OR UPDATE ON public.inventory_log_archive FOR EACH ROW EXECUTE FUNCTION public.archive_is_append_only();


--
-- Name: inventory_log inventory_log_keep_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER inventory_log_keep_history BEFORE DELETE OR UPDATE ON public.inventory_log FOR EACH ROW EXECUTE FUNCTION public.inventory_log_keep_history();


--
-- Name: products products_log_opening_stock; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER products_log_opening_stock AFTER INSERT ON public.products FOR EACH ROW WHEN ((new.stock_quantity > 0)) EXECUTE FUNCTION public.log_opening_stock();


--
-- Name: categories categories_parent_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_parent_fk FOREIGN KEY (parent_id) REFERENCES public.categories(category_id);


--
-- Name: inventory_log inventory_log_product_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_log
    ADD CONSTRAINT inventory_log_product_fk FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: order_items order_items_order_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_fk FOREIGN KEY (order_id) REFERENCES public.orders(order_id);


--
-- Name: order_items order_items_product_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_product_fk FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: orders orders_customer_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- Name: products products_category_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_fk FOREIGN KEY (category_id) REFERENCES public.categories(category_id);


--
-- PostgreSQL database dump complete
--

\unrestrict GKwNGl5ezYtOue4LSCgrfAi3ozIniA3XKNO65ZxOIdHxwXjrjKTTiJhPekvkrXh

