# Working notes

## Schema grid

| Table | Column | PK? | Points to | FK enforced? | UNIQUE? | CHECK? | Right type? | Notes |
|---|---|---|---|---|---|---|---|---|
| categories | category_id | yes | | | n/a (PK) | no | integer | |
| categories | category_name | no | | | no — should be (parent_id, category_name), NULLS NOT DISTINCT | no — should be NOT NULL | text | checked: 0 duplicates, 0 NULLs |
| categories | parent_id | no | categories (itself) | no | | NULL allowed (= top level); should be parent_id <> category_id | integer | found: 1 orphan (nothing below it); 0 self-parents; 1 cycle 9001 ↔ 9002 (6 products stranded). No CHECK can see cycles: rollup must guard against them |
| products | product_id | yes | | | n/a (PK) | no | integer | |
| products | product_name | no | | | no — fine (variants/suppliers can share names) | no | text | found: 23 duplicate listings (IDs 9001–9023), both copies selling; 377 groups are genuine variants |
| products | category_id | no | categories | no | | no — NULL allowed | integer | must stay nullable: uncategorised products allowed, race_test inserts NULL. Found: 0 orphans; 37 uncategorised (invisible to rollup) |
| products | price | no | | | | no — should be > 0, NOT NULL | numeric(12,2) — ok (exact decimal) | checked: clean |
| products | stock_quantity | no | | | | no — should be >= 0, NOT NULL | integer | found: 14 negative; 144 products don't reconcile with their movements |
| products | created_at | no | | | | no — dates checked by query, not CHECK | timestamp — should be timestamptz | checked: clean |
| customers | customer_id | yes | | | n/a (PK) | no | integer | |
| customers | full_name | no | | | no — fine (people share names) | no | text | |
| customers | email | no | | | no — should be (on lower(trim(email))) | no | text | comment: "Not unique. Never was." Found: 533 duplicate groups / 1,068 rows, all same name; 234 differ only by case/spaces |
| customers | phone | no | | | no — fine (phones are shared) | no | text | |
| customers | city | no | | | | no | text | |
| customers | registered_at | no | | | | no — dates checked by query, not CHECK | timestamp — should be timestamptz | checked: clean |
| orders | order_id | yes | | | n/a (PK) | no | integer | |
| orders | customer_id | no | customers | no | | no — should be NOT NULL | integer | found: 210 orphans; 0 NULLs |
| orders | order_date | no | | | | no — dates checked by query, not CHECK | timestamp — should be timestamptz | comment: "Nobody remembers why." Found: 24 after extract end (all on the minute); 0 before registration |
| orders | status | no | | | | no — should be one of (completed, pending, shipped, cancelled, refunded) | text — needs normalising + CHECK or lookup table | comment: "Free text. No check constraint." Found: 15 spellings for 5 statuses |
| orders | total_amount | no | | | | no — should be > 0, NOT NULL (cancelled orders keep their total; status marks the cancellation) | numeric(12,2) — ok (exact decimal) | comment: "Written by the application at checkout." Checked: 0 NULL, 0 <= 0. Agrees with its lines in 98.5% of orders |
| order_items | order_item_id | yes | | | n/a (PK) | no | integer | |
| order_items | order_id | no | orders | no | no — duplicates flagged for review, resolved via total_amount | no — should be NOT NULL | integer | found: 692 orphans; 533 double-inserted lines; 75 legitimate splits |
| order_items | product_id | no | products | no | see above | no — should be NOT NULL | integer | checked: clean |
| order_items | quantity | no | | | | no — should be > 0, NOT NULL; optional cap (real lines ≤ 20) | integer | found: 6 placeholder quantities (4 × 999, 2 × 9999) |
| order_items | unit_price | no | | | | no — should be > 0, NOT NULL | numeric(12,2) — ok (exact decimal) | snapshot of price at sale, differing from products.price is expected. Found: 148 NULL + 152 zero, prices lost after charging |
| inventory_log | log_id | yes | | | n/a (PK) | no | integer | |
| inventory_log | product_id | no | products | no | | no — should be NOT NULL | integer | found: 120 orphans; 0 NULLs |
| inventory_log | change_qty | no | | | | no — fine, intentional | integer | comment: "Negative for outward movement." Signs all correct per reason. Don't flag negatives. |
| inventory_log | reason | no | | | | optional — one of (sale, restock, return, correction, damage, stock_take) | text | comment: "Free text." Checked: 6 clean values, no variants |
| inventory_log | created_at | no | | | | no — dates checked by query, not CHECK | timestamp — should be timestamptz | found: 40 after extract end |
| inventory_log | note | no | | | | no — fine | text | optional field; ~425 notes filled in |

## Silent failures
- Status has 15 spellings: a naive WHERE status = '...' filter returns 20–26% of the real orders, with no error.
- Category cycles: no standard constraint prevents them; a naive recursive rollup never finishes.
- Orphan rows (692 order lines, 210 orders, 120 log rows) vanish from any inner join: totals built on joins are quietly short.
- A "future date" check against now() undercounts: it missed 8 orders and 7 log rows dated between the extract end and today.
- Revenue built from order lines is wrong in both directions (lost prices understate, double inserts and placeholder quantities overstate), with no error.
- A plain UNIQUE(email) would have blocked only 299 of 533 duplicate groups; the other 234 differ only by case or spaces.

## Checks I could write

All checks below have been written and run (diagnosis/01–04).

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
- orders.total_amount <= 0
- order_items.quantity <= 0, and placeholder values (999/9999)
- order_items.unit_price <= 0

**Duplicates**
- customers: lower(trim(email)), excluding NULL
- categories: (parent_id, category_name), NULL parents treated as equal
- products: same name + same category (for review)
- order_items: duplicate (order_id, product_id) lines (for review, cross-check with totals)

**Vocabulary**
- orders.status: distinct values and counts
- inventory_log.reason: distinct values and counts

**Dates**
- dates after extract end (assumed 2026-08-31)
- orders dated before their customer registered

**Consistency**
- orders.total_amount vs sum(quantity × unit_price) of its lines
- categories: self-parent (parent_id = category_id)
- categories: cycles (A→B→A)
- products: stock_quantity vs sum of inventory movements

**Coverage**
- orders: date range of the extract
- orders with no order_items lines
- units sold in order lines vs units logged as sales, by status
- read the 425 non-null inventory notes: 6 phrases, all on corrections (see Data profile)
- column profile of every table (diagnosis/05_profile.sql)

## Judgement calls
- Negative inventory_log.change_qty is an outward movement, not a fault. Source: schema comment.
- order_items.unit_price is a snapshot of the price at sale; differing from current products.price is expected, not a fault.
- full_name and phone stay non-unique: people share names, households and businesses share phones.
- Email should be unique (on lower(trim(email))): it identifies the account. Risk: two real people sharing an address would be merged, so review before merging.
- NULL categories.parent_id means a top-level category: legitimate. parent_id <> category_id added as a CHECK to block the simplest loop.
- products.category_id stays nullable: uncategorised products are allowed, and race_test inserts NULL there.
- Product names are not unique (variants, suppliers). 377 of 400 same-name groups are genuine variants; only the 23 listings in IDs 9001–9023 are duplicates.
- total_amount must be > 0: a cancelled order keeps its original total, and status marks the cancellation. Confirmed: 0 orders with total <= 0.
- The Monday report's "total spent" excludes cancelled orders by NORMALISED status (a raw 'cancelled' filter catches only 26%).
- Duplicate (order_id, product_id) lines are not blocked by UNIQUE: 75 orders with repeated lines match their total (legitimate splits); 533 do not (double inserts).
- Timestamps should become timestamptz. Assumption: existing values are Accra time (UTC+0), so converting changes no values today. Matters if any system ever writes in another zone or Kloud Kart expands.
- Date checks use the extract end (assumed 2026-08-31), not now(): real data runs Aug 2025 – Aug 2026, then 24 stray on-the-minute orders.
- Future dates and "order before registration" are checked by query rather than CHECK constraints: PostgreSQL advises against time-dependent CHECKs, and the second rule spans two tables.
- 152 zero-price lines are NOT freebies: in 147 of 151 orders the total is higher than the lines, so the customer was charged and the price was lost. Rule unit_price > 0 stands.
- 1,594 orders disagree with their lines, by amounts from GH₵0.05 to over GH₵10,000, for no identified reason. 5 of them turned out to be placeholder-quantity orders (fixed by sql/10), leaving 1,589. Which side is wrong cannot be determined from the data. Bounded, not resolved.
- Decided (ADR-003): "total spent" comes from orders.total_amount, not summed lines. The lines are damaged four ways (F-11 to F-14); the total agrees with them in 98.5% of orders. Cost if wrong: about 1% of orders (F-09).
- Decided (ADR-003): refunded and cancelled orders do not count as spend; pending, shipped and completed do. Flagged to Nana as an assumption to confirm.
- Decided (ADR-003): the 12 months end with the month of the latest order on or before today. That is Aug 2026 on this extract and the current month on live data, so neither gives empty months.
- Optional: a sanity cap on order_items.quantity (all real lines ≤ 20).
- Recounts noted "recount, not applied" are applied only where the gap equals the recount exactly AND the result is not negative (31 of 40). A recount that would leave negative stock means the log is short of movements too, so the right figure is not known.
- City spellings are fixed like status (only capitals and spaces differ); phone layouts are not (fixing them means guessing digits).
- inventory_log.reason is free text but has stayed clean (6 values, correct signs): no fix needed beyond an optional CHECK.
- 90 stock_take rows with zero change: can't tell if takes found no difference or adjustments weren't logged. Stated, not reported as a fault.
- Stock moves only for completed and shipped orders. Refunded orders (21,531 units) have no sale movement and returns total only 1,017 units, so assumed refunded before shipping.
- The 22% gap between order-line units and logged sales is not a fault: split by status, completed + shipped units match logged sales to within 70 units (0.02%).
- place_order will deduct stock at placement (required by race_test), changing today's behaviour of deducting at fulfilment. Cancelling an order must return the stock with a log row. Goes in the concurrency decision record.
- The orphan category has nothing below it: no current cost, ranked lowest.
- Order volume grew from ~70/day (Aug 2025) to ~1,170/day (Aug 2026); performance figures measured on this extract understate the load at the brief's 4,000/day.

## Data profile

Column-by-column profile of the raw load (`diagnosis/05_profile.sql`, saved as `results/profile_before.csv`; text columns reported as lengths, so no personal data).

- **Ranges match the story:** orders 2 Aug 2025 – 20 Aug 2027 (the tail is F-10); prices GH₵5.04–21,961.78; order totals GH₵3.51–227,750.97; stock −4 to 400 (negatives are F-03); stock movements −10 to +82.
- **Ids reveal the orphans:** real customers 100,001–140,420, but orders reference up to 999,997; real orders end at 659,384, but lines reference up to 999,862; real products end at 9,023, but the stock log references up to 99,999. Orphans point at ids that never existed, not at deleted rows.
- **Customers and products stop on 2 Aug 2025,** the day orders start: no registrations or new products during the order year.
- **Emails:** none malformed; 1,314 have stray spaces and 2,183 capitals (together the 3,220 the cleanup normalised).
- **Cities:** 15 values, but Accra is written 4 ways (10,731 customers, 27%); 12 real cities, 2 of them in Nigeria (F-16; normalised by sql/10).
- **Phones:** 5 layouts; 40,418 distinct of 40,420 (2 shared numbers, expected).
- **Names:** only 2,552 distinct names among 40,420 customers: names are shared, so a name alone never identifies a duplicate.
- **Quantities:** 7 distinct values, including 999 and 9999 (F-14).
- **Notes:** 425 filled, 6 phrases, all on `correction` movements: "counted by hand" 86, "see WhatsApp msg" 80, "??" 76, "POS mismatch" 74, "adjusted after complaint" 69, "recount, not applied" 40.

## Measurements

| Date | What | Condition | Result | Notes |
|---|---|---|---|---|
| 24 Nov | Row counts | fresh load | categories 94, products 4,023, customers 40,420, orders 159,384, order_items 336,559, inventory_log 282,352 | baseline; denominators for diagnosis |
| 24 Nov | impossible: products.stock_quantity < 0 | fresh load | 14 | of 4,023 products |
| 24 Nov | orphan: categories.parent_id → categories | fresh load | 1 | of 94 categories |
| 24 Nov | orphan: inventory_log.product_id → products | fresh load | 120 | of 282,352 log rows |
| 24 Nov | orphan: order_items.order_id → orders | fresh load | 692 | of 336,559 order lines |
| 24 Nov | orphan: order_items.product_id → products | fresh load | 0 | clean |
| 24 Nov | orphan: orders.customer_id → customers | fresh load | 210 | of 159,384 orders |
| 24 Nov | orphan: products.category_id → categories | fresh load | 0 | clean |
| 24 Nov | null (fault): order_items.unit_price | fresh load | 148 | of 336,559 order lines |
| 24 Nov | null (info): categories.parent_id | fresh load | 7 | top-level categories: legitimate |
| 24 Nov | null (info): products.category_id | fresh load | 37 | uncategorised: legitimate, but invisible to rollup |
| 24 Nov | null (info): inventory_log.note | fresh load | 281,927 | of 282,352; optional field. ~425 notes worth reading |
| 24 Nov | all other NULL checks | fresh load | 0 | clean |
| 24 Nov | impossible: order_items.unit_price <= 0 | fresh load | 152 | all exactly 0.00; no negatives |
| 24 Nov | impossible: price / total_amount / quantity <= 0 | fresh load | 0 | clean; total_amount > 0 rule confirmed |
| 24 Nov | duplicate: customers.email | fresh load | 533 groups / 1,068 rows | of 40,420 customers; 535 extra rows |
| 24 Nov | duplicate email groups: same name? | fresh load | 533 of 533 same name (531 pairs, 2 triples) | same person registered twice: real fault |
| 24 Nov | duplicate email groups: exact vs normalised | fresh load | 299 exact / 533 normalised | 234 groups differ only by case/spaces; plain UNIQUE(email) would have stopped only 56% |
| 24 Nov | duplicate: categories (parent_id, name) | fresh load | 0 | clean |
| 24 Nov | duplicate (review): products (name, category) | fresh load | 400 groups / 829 rows | of 4,023 products |
| 24 Nov | product name groups: same price? | fresh load | 384 different / 16 same | price alone does not separate duplicates from variants (see ID ≥ 9000 rows) |
| 24 Nov | products with ID ≥ 9000 | fresh load | 24 (9000–9023); 9000 unique; 23 duplicate an existing product | 16 in same-price pairs + 7 hidden in 3–4-copy groups alongside a genuine variant |
| 24 Nov | duplicate listings: both selling? | fresh load | 16 of 16 checked pairs: both copies sell (~70–95 lines each) | live double entry: stock and sales split: real fault. All 23 (including the 7 hidden ones) had a same-price twin and were merged by sql/10 |
| 24 Nov | duplicate listings: created_at | fresh load | spread 2023–2025, not clustered | cause unconfirmed; don't claim a batch import |
| 24 Nov | product name groups: genuine variants | fresh load | 377 of 400 groups | not faults |
| 24 Nov | duplicate (review): order_items (order_id, product_id) | fresh load | 616 groups / 1,233 rows | resolved by total vs lines: 533 double inserts, 75 splits |
| 24 Nov | orders by year | fresh load | 2025: 17,996 (from 2 Aug) / 2026: 141,374 / 2027: 14 | |
| 24 Nov | orders by month | fresh load | thousands/month Aug 2025–Aug 2026; then 24 stray orders Sep 2026–Aug 2027 | extract ends ~31 Aug 2026 |
| 24 Nov | order volume growth | fresh load | ~70/day (Aug 2025) → ~1,170/day (Aug 2026) | growing toward brief's 4,000/day |
| 24 Nov | date: orders.order_date > now() | fresh load | 16 (2026-11-26 → 2027-08-20) | first attempt; undercounts, superseded by extract-end check |
| 24 Nov | date: orders.order_date after extract end (2026-08-31) | fresh load | 24, all exactly on the minute | > now() missed 8 |
| 24 Nov | date: inventory_log.created_at > now() | fresh load | 33 (2026-12-04 → 2027-08-20) | first attempt; same max as orders, likely linked events |
| 24 Nov | date: inventory_log.created_at after extract end (2026-08-31) | fresh load | 40 | > now() missed 7 |
| 24 Nov | date: customers.registered_at after extract end | fresh load | 0 | clean |
| 24 Nov | date: products.created_at after extract end | fresh load | 0 | clean |
| 24 Nov | on-the-minute rate, normal months | fresh load | 1.7–1.8% | matches 1-in-60 chance: no hidden hand-entered dates |
| 24 Nov | date: order placed before customer registered | fresh load | 0 | clean |
| 24 Nov | consistency: categories self-parent | fresh load | 0 | clean |
| 24 Nov | consistency: orders with no order_items | fresh load | 0 | clean |
| 24 Nov | consistency: total_amount <> sum of lines | fresh load | 2,398 orders | of 159,384 (1.5%) |
| 24 Nov | total vs lines: NULL-price orders | fresh load | 118 higher (+323,142.93); 28 not comparable (all lines NULL); 1 lower (−1,130,593.01) | price lost after charging: fault; the 1 lower is a placeholder-quantity order (569332) |
| 24 Nov | total vs lines: zero-price orders | fresh load | 147 higher (+124,127.95); 1 match; 3 lower (−18,521.53) | not freebies, price lost: fault; rule unit_price > 0 stands |
| 24 Nov | total vs lines: duplicate-line orders | fresh load | 533 lower (−883,264.69); 75 match; 2 higher (+866.61) | 533 double inserts: fault; 75 legitimate splits: not a fault |
| 24 Nov | total vs lines: other orders | fresh load | 156,882 match; 789 higher (+420,453.66); 805 lower (−2,313,763.54) | 1,594 unexplained mismatches |
| 24 Nov | other mismatches: size | fresh load | ≤0.05: 0 / 0.05–10: 185 / 10–1,000: 1,222 / 1,000–10,000: 176 / >10,000: 11 | not rounding; both directions: which side is wrong can't be determined |
| 24 Nov | extreme mismatches (>10,000, all kinds) | fresh load | 32 orders: 6 with qty 999/9999; most others ≈ ×2 (double inserts) or total ≫ lines (lost prices) | unit_price = current product price in all 32: prices not corrupted |
| 24 Nov | placeholder quantities | fresh load | 6 lines (4 × 999, 2 × 9999) ≈ GH₵3m of fake line revenue | total_amount correct in each: quantity is the fault |
| 24 Nov | order_items.quantity > 20 | fresh load | 6 lines, exactly the placeholders | all other lines ≤ 20: no hidden absurd values |
| 24 Nov | orders.status distinct values | fresh load | 15 raw values → 5 real statuses: completed 111,351 / pending 16,009 / shipped 12,848 / cancelled 12,697 / refunded 6,479 | variants: case, leading space, complete/completed, canceled/cancelled |
| 24 Nov | status = 'completed' (naive filter) | fresh load | 22,091 of 111,351 (20%) | naive filter misses 80% of completed orders |
| 24 Nov | status = 'cancelled' (naive filter) | fresh load | 3,238 of 12,697 (26%) | ~9,500 cancelled orders would slip into spend |
| 24 Nov | inventory_log.reason distinct values | fresh load | 6 clean values: sale 262,088 / restock 18,857 / return 564 / correction 485 / damage 268 / stock_take 90 | no variants; all signs correct: not a fault |
| 24 Nov | stock_take movements | fresh load | 90 rows, all change_qty = 0 | no-adjustment takes, or adjustments not logged: can't tell |
| 24 Nov | category cycles | fresh load | 1 cycle: 9001 ↔ 9002 | no root reachable; naive rollup loops; CHECK parent_id <> category_id would not catch it |
| 24 Nov | products stranded in cycle 9001 ↔ 9002 | fresh load | 6 products, 0 child categories | invisible to the rollup |
| 24 Nov | orphan category: what hangs below | fresh load | 1 category, 0 children, 0 products | no current cost: rank lowest; FK prevents recurrence |
| 24 Nov | stock vs sum of movements | fresh load | 3,879 match / 122 lower (−2,464 units) / 22 higher (+89) | log is a complete trail for 96.4% of products; 144 don't reconcile |
| 24 Nov | units: order lines vs logged sales | fresh load | 530,457 vs 412,645 (gap ~117,800, 22%) | looked like an audit gap; see split below |
| 24 Nov | units by normalised status | fresh load | completed 369,973 / pending 53,414 / shipped 42,742 / cancelled 41,829 / refunded 21,531 | excludes 6 placeholder lines and 692 orphan lines |
| 24 Nov | completed + shipped units vs logged sales | fresh load | 412,715 vs 412,645 (diff 70, 0.02%) | log matches fulfilled orders: the 22% "gap" is not a fault |
| 24 Nov | consistency: categories in a cycle | fresh load | 2 (9001, 9002) | now tracked in 01 for before/after |
| 24 Nov | consistency: products where stock <> sum of movements | fresh load | 144 | now tracked in 01 |
| 24 Nov | vocabulary: orders.status not in canonical 5 | fresh load | 116,394 of 159,384 (73%) | only 42,990 spelled exactly right |
| 24 Nov | orders with no customer: value | fresh load | 210 orders, GH₵665,180.61 | revenue no customer total includes |
| 24 Nov | cancelled orders: value, all spellings vs naive filter | fresh load | GH₵38,163,973.23 vs GH₵9,396,828.73 | naive filter misses GH₵28,767,144.50 (75% by value) |
| 27 Nov | Row counts after cleanup | sql/00_run_all.sql | categories 93, products 4,000, customers 39,885, orders 159,150, order_items 334,812, inventory_log 282,246 | every difference explained in the Reconciliation table (data_findings.md) |
| 27 Nov | Integrity checks after cleanup | sql/00_run_all.sql | every fault fixed or quarantined shows 0; left by decision: cycle 2, stock drift 113 (144 before the recount fix), total ≠ lines 1,864, NULL price 148, zero price 151, placeholder 1 | log dated after extract end 40 → 54: the 14 F-03 correction rows, dated at cleanup |
| 27 Nov | Monday report before (500 customers) | raw load, measurement/x50 | 38.5 s; plan 37,937 ms; 7,000 full scans of orders | scaled to all customers: about 52 min |
| 27 Nov | Monday report after | measurement/x90, 10 runs | median 872 ms, p95 1,041, worst 1,096; top 100 135 ms; running total 294 ms | plan: orders read once, 914.664 ms |
| 27 Nov | Low-stock rollup | measurement/x90, 10 runs | median 5.1 ms, worst 6.0 ms | plan 8.128 ms |
| 27 Nov | race_test.py, unmodified | after sql/00_run_all.sql | PASSED: test 1 25/25; test 2 50 sold, 350 refused, 0 errors, 3.48 s; test 3 refused cleanly; test 4 5 sold, 6 movements | 6 movements = opening stock + 5 sales |
| 27 Nov | v_data_health | after race test | drift 113, negative 0, rootless categories 2, unpriced lines 299, total ≠ lines 1,864, future orders 0 | race test added no drift |
| 27 Nov | Column profile, all 31 columns | raw load, diagnosis/05_profile.sql | results/profile_before.csv | summarised under Data profile |
| 27 Nov | City spellings | customers + quarantined customers | 15 values; Accra 4 ways: accra 2,769 / ACCRA 2,727 / Accra 2,622 / Accra (hidden space) 2,613 = 10,731 (27%) | F-16; results/profile_values.csv |
| 27 Nov | Stock-log notes | inventory_log + quarantined movements | 425 notes, 6 phrases | results/profile_values.csv |
| 27 Nov | Notes vs drifting products | after cleanup, v_stock_drift | "recount, not applied": 40 of 40 products drifting; WhatsApp 7 of 80; counted by hand 5 of 86; POS mismatch 4 of 74; ?? 2 of 76; adjusted after complaint 0 of 69 | explains 40 of the 144 (F-01); results/notes_vs_drift.csv |
| 27 Nov | Recount products: gap vs unapplied recount | after cleanup | 40 products: 39 gaps equal the recount exactly, 0 reversed; of the 39, 8 have a negative trail total (applying would make stock negative) | 31 applied by sql/10; 9 left for the count |
| 27 Nov | After recount and city fixes | sql/00_run_all.sql | F-01 recounts applied 31; drift 144 → 113; cities 15 spellings → 12; every other check and row count unchanged | results/cleanup_fix_summary.csv, integrity_checks_after.csv, data_health.csv |
