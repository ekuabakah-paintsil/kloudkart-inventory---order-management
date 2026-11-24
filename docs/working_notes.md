# Working notes

## Schema grid

| Table | Column | PK? | Points to | FK enforced? | UNIQUE? | CHECK? | Right type? | Notes |
|---|---|---|---|---|---|---|---|---|
| categories | category_id | yes | | | n/a (PK) | no | integer | |
| categories | category_name | no | | | no — should be (parent_id, category_name), NULLS NOT DISTINCT | no — should be NOT NULL | text | check: duplicate (parent_id, category_name), treating NULL parents as equal; check: NULL names |
| categories | parent_id | no | categories (itself) | no | | NULL allowed (= top level); should be parent_id <> category_id | integer | check: orphans (parent_id with no matching category); check: self-parent; check: cycles (A→B→A), no CHECK can see these, rollup must guard against them |
| products | product_id | yes | | | n/a (PK) | no | integer | |
| products | product_name | no | | | no — fine (variants/suppliers can share names) | no | text | check: same name + same category, for review |
| products | category_id | no | categories | no | | no — NULL allowed | integer | must stay nullable: uncategorised products allowed, race_test inserts NULL; check: orphans |
| products | price | no | | | | no — should be > 0, NOT NULL | numeric(12,2) — ok (exact decimal) | check: rows <= 0 or NULL |
| products | stock_quantity | no | | | | no — should be >= 0, NOT NULL | integer | check: rows < 0 or NULL |
| products | created_at | no | | | | no — future dates checked by query, not CHECK | timestamp — should be timestamptz | check: future dates |
| customers | customer_id | yes | | | n/a (PK) | no | integer | |
| customers | full_name | no | | | no — fine (people share names) | no | text | |
| customers | email | no | | | no — should be (on lower(trim(email))) | no | text | comment: "Not unique. Never was."; check: duplicates on lower(trim(email)), excluding NULL |
| customers | phone | no | | | no — fine (phones are shared) | no | text | |
| customers | city | no | | | | no | text | |
| customers | registered_at | no | | | | no — future dates checked by query, not CHECK | timestamp — should be timestamptz | check: future dates |
| orders | order_id | yes | | | n/a (PK) | no | integer | |
| orders | customer_id | no | customers | no | | no — should be NOT NULL | integer | check: orphans; check: NULLs |
| orders | order_date | no | | | | no — future dates and before-registration checked by query, not CHECK | timestamp — should be timestamptz | comment: "Nobody remembers why."; check: future dates; check: order_date < customer's registered_at (cross-table) |
| orders | status | no | | | | no — should be one of a fixed list, values TBD | text — revisit after seeing values | comment: "Free text. No check constraint."; check: SELECT DISTINCT status |
| orders | total_amount | no | | | | no — should be > 0, NOT NULL (cancelled orders keep their total; status marks the cancellation) | numeric(12,2) — ok (exact decimal) | comment: "Written by the application at checkout."; check: rows <= 0 or NULL (if any, check their status); check: total_amount vs sum(quantity × unit_price) of its lines |
| order_items | order_item_id | yes | | | n/a (PK) | no | integer | |
| order_items | order_id | no | orders | no | no — duplicates flagged for review; cross-check against total_amount to separate splits from double inserts | no — should be NOT NULL | integer | check: orphans; check: NULLs; check: duplicate (order_id, product_id) lines |
| order_items | product_id | no | products | no | see above | no — should be NOT NULL | integer | check: orphans; check: NULLs |
| order_items | quantity | no | | | | no — should be > 0, NOT NULL | integer | check: rows <= 0 or NULL |
| order_items | unit_price | no | | | | no — should be > 0, NOT NULL | numeric(12,2) — ok (exact decimal) | check: rows <= 0 or NULL; snapshot of price at sale, differing from products.price is expected, not a fault |
| inventory_log | log_id | yes | | | n/a (PK) | no | integer | |
| inventory_log | product_id | no | products | no | | no — should be NOT NULL | integer | check: orphans; check: NULLs |
| inventory_log | change_qty | no | | | | no — fine, intentional | integer | comment: "Negative for outward movement." Don't flag negatives. |
| inventory_log | reason | no | | | | no — should be one of (sale, restock, correction), confirm after seeing values | text | comment: "Free text."; check: SELECT DISTINCT reason |
| inventory_log | created_at | no | | | | no — future dates checked by query, not CHECK | timestamp — should be timestamptz | check: future dates |
| inventory_log | note | no | | | | no — fine | text | |

## Silent failures

## Checks I could write

**Orphans (missing FK)**
- categories.parent_id → categories
- products.category_id → categories
- orders.customer_id → customers
- order_items.order_id → orders
- order_items.product_id → products
- inventory_log.product_id → products

**NULLs where a value is required**
- categories.category_name
- orders.customer_id
- order_items.order_id, order_items.product_id
- inventory_log.product_id
- products.price, products.stock_quantity
- orders.total_amount
- order_items.quantity, order_items.unit_price

**Impossible values**
- products.price <= 0
- products.stock_quantity < 0
- orders.total_amount <= 0 (if any, break down by status)
- order_items.quantity <= 0
- order_items.unit_price <= 0

**Duplicates**
- customers: lower(trim(email)), excluding NULL
- categories: (parent_id, category_name), NULL parents treated as equal
- products: same name + same category (for review, not automatically a fault)
- order_items: duplicate (order_id, product_id) lines (for review, cross-check with totals)

**Vocabulary**
- orders.status: distinct values and counts
- inventory_log.reason: distinct values and counts

**Dates**
- future created_at / registered_at / order_date
- orders dated before their customer registered

**Consistency**
- orders.total_amount vs sum(quantity × unit_price) of its lines
- categories: self-parent (parent_id = category_id)
- categories: cycles (A→B→A)

**Coverage**
- orders: min(order_date) and max(order_date), how many days/months does the extract cover?
- orders with no order_items lines
- inventory_log rows by reason; compare sale-type movements with order_items lines

## Judgement calls
- Negative inventory_log.change_qty is an outward movement, not a fault. Source: schema comment.
- order_items.unit_price is a snapshot of the price at sale; differing from current products.price is expected, not a fault.
- full_name and phone stay non-unique: people share names, households and businesses share phones.
- Email should be unique (on lower(trim(email))): it identifies the account. Risk: two real people sharing an address would be merged, so review before merging.
- NULL categories.parent_id means a top-level category: legitimate. parent_id <> category_id added as a CHECK to block the simplest loop.
- products.category_id stays nullable: uncategorised products are allowed, and race_test inserts NULL there.
- Product names are not unique (variants, suppliers); same name + same category is flagged for review, not counted as a fault.
- total_amount must be > 0: a cancelled order keeps its original total, and status marks the cancellation. If zero totals appear, check whether they are all cancelled; if so, the app zeroes on cancel and the rule needs revisiting.
- The Monday report's "total spent" excludes cancelled orders by status (confirm the status values first).
- Duplicate (order_id, product_id) lines are not blocked by UNIQUE: two lines at different unit prices can be a legitimate split (e.g. part on promotion). They are flagged for review and cross-checked against total_amount: if the total matches the sum including both lines, it is a split; if it matches with only one, the second is a double insert.
- Timestamps should become timestamptz. Assumption: existing values are Accra time (UTC+0), so converting changes no values today. Matters if any system ever writes in another zone or Kloud Kart expands.
- Future dates and "order before registration" are checked by query rather than CHECK constraints: PostgreSQL advises against time-dependent CHECKs, and the second rule spans two tables.

## Measurements
| Date | What | Condition | Result | Notes |
|---|---|---|---|---|
| 24 Nov | Row counts | fresh load | categories 94, products 4,023, customers 40,420, orders 159,384, order_items 336,559, inventory_log 282,352 | baseline; denominators for diagnosis |