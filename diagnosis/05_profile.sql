-- =============================================================================
-- 05_profile.sql  (investigation, not part of run_all)
-- =============================================================================
-- A column-by-column profile of the six tables: what is in each column BEFORE judging it.
-- Results recorded in docs/working_notes.md ("Data profile") and, via
-- measurement/x01_export_baseline.sql, in results/profile_before.csv.
--
-- WHAT IT PRINTS: one row per column
--   rows             rows in the table
--   nulls, null_pct  how many values are missing, and what share
--   distinct_values  how many different values the column holds
--   min_value,       numbers and dates: the smallest and largest value
--   max_value        text columns: the shortest and longest LENGTH in characters
--   note             what the figures mean, plus format checks where they matter
--                    (email shape, phone formats, the most common cities, the values of
--                    the two free-text code columns)
--
-- CONFIDENTIALITY: text columns report LENGTHS, never values, so no customer name, email
-- or phone number appears in the output. City names and status/reason codes are not
-- personal and are listed. The output is safe to commit.
--
-- HOW IT WORKS
--   information_schema.columns is PostgreSQL's own list of every column of every table.
--   A DO block (a one-off piece of PL/pgSQL) loops over that list and, for each column,
--   builds and runs one query with format() + EXECUTE. That is "dynamic SQL": the query
--   text is assembled at run time, because the column name is only known inside the loop.
--   %I in format() quotes a name safely, the same as in measurement/x90.
--   The results go into a TEMP table (gone when the session ends), then one SELECT prints it.
--
-- Run on the raw load (after schema.sql + load.sql) to profile the data as delivered:
--   docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f diagnosis/05_profile.sql
-- =============================================================================

-- Hide the "CREATE TABLE" / "DO" status lines, so only the profile itself prints
-- (and so a CSV export of this script contains only the table).
\set QUIET on

SET client_min_messages = warning;   -- hide the "does not exist, skipping" notice on a first run
DROP TABLE IF EXISTS column_profile;
CREATE TEMP TABLE column_profile (
    table_order     integer,   -- keeps the tables in a readable order
    table_name      text,
    column_position integer,   -- keeps each table's columns in schema order
    column_name     text,
    data_type       text,
    rows            bigint,
    nulls           bigint,
    distinct_values bigint,
    min_value       text,
    max_value       text,
    note            text
);

DO $$
DECLARE
    c          record;    -- one column from information_schema, per loop
    v_rows     bigint;
    v_nulls    bigint;
    v_distinct bigint;
    v_min      text;
    v_max      text;
    v_tables   text[] := ARRAY['categories', 'products', 'customers', 'orders', 'order_items', 'inventory_log'];
BEGIN
    FOR c IN
        SELECT table_name::text AS t, column_name::text AS col, data_type::text AS dtype,
               ordinal_position AS pos, array_position(v_tables, table_name::text) AS t_order
        FROM   information_schema.columns
        WHERE  table_schema = 'public' AND table_name::text = ANY (v_tables)
    LOOP
        IF c.dtype = 'text' THEN
            -- Text: count, missing, distinct, and the shortest/longest LENGTH (not the value).
            EXECUTE format('SELECT count(*), count(*) - count(%1$I), count(DISTINCT %1$I),
                                   min(length(%1$I))::text, max(length(%1$I))::text
                            FROM %2$I', c.col, c.t)
            INTO v_rows, v_nulls, v_distinct, v_min, v_max;
        ELSE
            -- Numbers and dates: the smallest and largest actual value.
            EXECUTE format('SELECT count(*), count(*) - count(%1$I), count(DISTINCT %1$I),
                                   min(%1$I)::text, max(%1$I)::text
                            FROM %2$I', c.col, c.t)
            INTO v_rows, v_nulls, v_distinct, v_min, v_max;
        END IF;

        INSERT INTO column_profile
        VALUES (c.t_order, c.t, c.pos, c.col, c.dtype, v_rows, v_nulls, v_distinct, v_min, v_max,
                CASE WHEN c.dtype = 'text' THEN 'min/max = length in characters' END);
    END LOOP;
END;
$$;

-- -----------------------------------------------------------------------------
-- Format checks, added to the note of the column they describe.
-- -----------------------------------------------------------------------------

-- Email shape: something@something.something, with no spaces. Leading/trailing spaces and
-- capitals are counted separately, because those are what hid duplicates (F-05).
UPDATE column_profile SET note = note || format(
    '; %s not shaped like name@domain.tld; %s with leading/trailing spaces; %s with capitals',
    (SELECT count(*) FROM customers WHERE trim(email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    (SELECT count(*) FROM customers WHERE email <> trim(email)),
    (SELECT count(*) FROM customers WHERE email <> lower(email)))
WHERE table_name = 'customers' AND column_name = 'email';

-- Phone formats: every digit replaced by 9, so "+233 24 123 4567" becomes "+999 99 999 9999".
-- Shows how many different layouts exist and the three most common, without any real number.
UPDATE column_profile SET note = note || '; formats: '
    || (SELECT count(DISTINCT regexp_replace(phone, '[0-9]', '9', 'g')) FROM customers)
    || ' layouts, most common '
    || (SELECT string_agg(fmt || ' (' || n || ')', ', ' ORDER BY n DESC)
        FROM (SELECT regexp_replace(phone, '[0-9]', '9', 'g') AS fmt, count(*) AS n
              FROM customers WHERE phone IS NOT NULL
              GROUP BY 1 ORDER BY 2 DESC LIMIT 3) top3)
WHERE table_name = 'customers' AND column_name = 'phone';

-- Cities: the five most common, with counts. (A city is not personal data.)
UPDATE column_profile SET note = note || '; top 5: ' || (
    SELECT string_agg(city || ' ' || n, ', ' ORDER BY n DESC)
    FROM (SELECT city, count(*) AS n FROM customers WHERE city IS NOT NULL
          GROUP BY city ORDER BY 2 DESC LIMIT 5) top5)
WHERE table_name = 'customers' AND column_name = 'city';

-- The two free-text code columns: every value with its count. Values are quoted so a
-- leading space (' completed') is visible.
UPDATE column_profile SET note = note || '; values: ' || (
    SELECT string_agg('''' || status || ''' ' || n, ', ' ORDER BY n DESC)
    FROM (SELECT status, count(*) AS n FROM orders GROUP BY status) s)
WHERE table_name = 'orders' AND column_name = 'status';

UPDATE column_profile SET note = note || '; values: ' || (
    SELECT string_agg('''' || reason || ''' ' || n, ', ' ORDER BY n DESC)
    FROM (SELECT reason, count(*) AS n FROM inventory_log GROUP BY reason) s)
WHERE table_name = 'inventory_log' AND column_name = 'reason';

RESET client_min_messages;
\set QUIET off

-- -----------------------------------------------------------------------------
-- The profile
-- -----------------------------------------------------------------------------
-- null_pct: share of the column that is empty. NULLIF avoids dividing by zero on an
-- empty table.
SELECT table_name, column_name, data_type, rows, nulls,
       round(100.0 * nulls / NULLIF(rows, 0), 1) AS null_pct,
       distinct_values, min_value, max_value, note
FROM   column_profile
ORDER  BY table_order, column_position;
