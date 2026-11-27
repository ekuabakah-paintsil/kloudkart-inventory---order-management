# Data findings — Kloud Kart Ltd.

> Every figure below comes from a fresh load of the extract and can be reproduced with `diagnosis/01_integrity_checks.sql` (one row per check) and the investigation scripts `diagnosis/02`–`04`.

## Summary

The extract covers August 2025 to August 2026: 159,384 orders, 40,420 customer records and 4,023 products. Most of it is sound: 156,882 orders agree exactly with their lines, 3,879 of 4,023 products reconcile exactly with their stock movements, and the stock trail matches fulfilled orders to within 70 units. The dangerous faults are few but sit exactly where Nana's decisions rest. Stock counts are wrong for 144 products and split across duplicate listings for 23 more, which undermines any no-overselling guarantee. Order status is written 15 different ways, so a report that "excludes cancelled orders" in the obvious way still counts GH₵28.8 million of cancelled orders as customer spending. 533 customers are registered twice, which splits their spending and distorts the top-100 ranking. None of these faults raises an error; each produces a plausible, wrong number.

**Severity scale**

- **Critical** — breaks one of Nana's four criteria now and costs money or customers if not fixed before the flash sale.
- **High** — silently distorts a number Nana decides with.
- **Medium** — damages a figure in a bounded way, or is a hazard the solution must guard against.
- **Low** — no effect on Nana's numbers given the chosen design; fixed to stop it recurring.

## Reconciliation

| Stage | Rows | Delta | Reason |
|---|---|---|---|
| Raw load: categories | 94 | — | as delivered |
| Raw load: products | 4,023 | — | as delivered |
| Raw load: customers | 40,420 | — | as delivered |
| Raw load: orders | 159,384 | — | as delivered |
| Raw load: order_items | 336,559 | — | as delivered |
| Raw load: inventory_log | 282,352 | — | as delivered |
| After fixes: customers | [fill in] | [fill in] | duplicate customers merged (F-05) |
| After fixes: products | [fill in] | [fill in] | duplicate listings merged (F-02) |
| After fixes: orders | [fill in] | [fill in] | no customer (F-06), dated after extract end (F-10) |
| After fixes: order_items | [fill in] | [fill in] | lines of quarantined orders, orphans (F-12), double inserts (F-11) |
| After fixes: inventory_log | [fill in] | [fill in] | orphan movements removed (F-07), negative-stock corrections added (F-03) |
| After fixes: categories | [fill in] | [fill in] | empty orphan category (F-15) |

The "after" counts are printed by `sql/00_run_all.sql`. Every removed row is in a `quarantine_*` table with its finding; every in-place change is in `data_fix_log`.

## Findings, ranked by risk

### F-01: Stock counts do not match the stock trail — Severity: Critical

- **What it is:** For 144 products, the stock figure on the product does not equal the sum of that product's recorded stock movements. No rule ties the two together.
- **How I detected it:** Summed `inventory_log.change_qty` per product and compared it with `products.stock_quantity` (check `consistency: products where stock <> sum of movements`; `diagnosis/04_investigate_stock.sql` query 2).
- **Scale:** 144 of 4,023 products (3.6%). 122 hold less stock than their movements imply (−2,464 units); 22 hold more (+89 units). Net 2,375 units unaccounted for. The other 3,879 products reconcile exactly.
- **Effect on the client's number:** The order-placement fix can only protect the number it is given. For the 22 overstated products, a perfectly locked order can still sell up to 89 units that may not exist; for the 122 understated products, real stock is refused or unrecorded losses go unnoticed. This is the "stock counts no longer match reality" Nana describes, located and sized.
- **What I did about it:** Left the stock figures unchanged: the data cannot say whether the shelf count or the trail is wrong, and resetting either would be guessing (ADR-006). Built `v_stock_drift` (sql/70), which lists every product whose stock does not match its trail, by how much and when it last moved: a ready-made counting list for the warehouse.
- **Residual risk:** Until the 144 products are physically counted, their stock figures may be wrong, so `place_order` protects a number that may not match the shelf. Drift from any new cause appears in `v_stock_drift` and `v_data_health` the day it happens.

### F-02: The same product is listed twice, and both listings sell — Severity: Critical

- **What it is:** 23 products in the ID range 9001–9023 duplicate an existing product with the same name and category. Each copy carries its own stock count.
- **How I detected it:** Grouped products on `lower(trim(product_name))` and `category_id`, compared prices within groups, then traced the same-price pairs to the 9000-range IDs and counted sales per copy.
- **Scale:** 23 duplicate listings. 16 sit in same-price pairs; 7 sit in groups of three or four alongside a genuine variant. In all 16 checked pairs both copies sell (about 70–95 order lines each). Creation dates span 2023–2025, so the cause is not a single import.
- **Effect on the client's number:** One shelf, two stock counts. Neither count is the real stock, sales history per product is understated by roughly half for these items, and one listing can keep selling after the other reaches zero. No locking strategy prevents overselling across two listings, and flash-sale volume makes it worse.
- **What I did about it:** Merged each duplicate listing into its original (same normalised name, category and price, lower id): order lines and stock movements re-pointed, stock added, the copy moved to `quarantine_products`, each merge recorded in `data_fix_log` (sql/10).
- **Residual risk:** Duplicates whose price has since drifted are not merged by this rule; they remain as separate listings. Nothing in the database stops a new duplicate listing being created; this needs a check in the process that adds products.

### F-03: Products with negative stock — Severity: High

- **What it is:** Stock below zero, which is what an oversell leaves behind. Nothing in the schema prevents it.
- **How I detected it:** `stock_quantity < 0` (check `impossible: products.stock_quantity < 0`).
- **Scale:** 14 of 4,023 products.
- **Effect on the client's number:** Evidence that overselling has already happened on these products. Low-stock figures for them are impossible values, and the customers behind them are owed stock that does not exist.
- **What I did about it:** Reset negative stock to 0 and recorded each adjustment as a `correction` movement, so the trail still explains the figure (sql/10). Added the rule `stock_quantity >= 0` (sql/20) under the new order placement (ADR-001).
- **Residual risk:** None for new sales: the order function cannot take stock it does not have, and the database refuses negative stock from any other path. The customers who bought these phantom units in the past still need to be contacted.

### F-04: Order status written 15 different ways — Severity: High

- **What it is:** `status` is free text with no rule on allowed values. Five real statuses appear under 15 spellings: capitals, a leading space, "complete" vs "completed", "canceled" vs "cancelled".
- **How I detected it:** Counted distinct `status` values, then grouped them on `lower(trim(status))` with the two spelling variants mapped (check `vocabulary: orders.status not in canonical 5`).
- **Scale:** 116,394 of 159,384 orders (73%) are not spelled in one of the five standard forms. Real totals: completed 111,351; pending 16,009; shipped 12,848; cancelled 12,697; refunded 6,479.
- **Effect on the client's number:** A filter written the obvious way, `status = 'cancelled'`, finds 3,238 of 12,697 cancelled orders. Cancelled orders are worth GH₵38,163,973.23 in total; the naive filter catches GH₵9,396,828.73, so **GH₵28,767,144.50 (75% by value) of cancelled orders would be counted as customer spending**, silently, every Monday. `status = 'completed'` finds 20% of completed orders.
- **What I did about it:** Rewrote every status to one of five values (sql/10) and added a rule allowing only those five (sql/20). Reports filter on the clean values.
- **Residual risk:** None for new orders: any other spelling is refused when it is written.

### F-05: Customers registered twice — Severity: High

- **What it is:** No uniqueness rule on email, and no normalisation of case or spaces before comparison.
- **How I detected it:** Grouped customers on `lower(trim(email))` (excluding empty emails) with `HAVING count(*) > 1`; checked whether names match within each group; compared exact-match and normalised group counts.
- **Scale:** 533 email groups covering 1,068 rows (531 pairs, 2 triples), so 535 surplus customer records. All 533 groups have the same name, so they are the same person. 299 groups are identical text; 234 differ only by capitals or spaces.
- **Effect on the client's number:** The customer count is overstated by 535. Each of these 533 people has spending split across two or three records, so their total spent is understated and the top-100 ranking may leave out customers who belong in it. A plain uniqueness rule on raw email would have prevented only 299 of the 533 (56%).
- **What I did about it:** Merged each group into its lowest customer record: orders moved, duplicates moved to `quarantine_customers`, every move recorded in `data_fix_log`. Emails stored normalised and made unique on `lower(trim(email))` (sql/10, sql/20).
- **Residual risk:** Two genuinely different people sharing both an email address and a name would have been merged; every merge is recorded and reversible. A new registration with an existing email (in any capitalisation) is now refused.

### F-06: Orders belonging to no customer — Severity: Medium

- **What it is:** Orders whose `customer_id` points at a customer that does not exist. No foreign key.
- **How I detected it:** Anti-join from `orders` to `customers` (check `orphan: orders.customer_id → customers`).
- **Scale:** 210 of 159,384 orders, worth GH₵665,180.61.
- **Effect on the client's number:** Real revenue that appears in no customer's total, no top-100 position and no per-customer monthly figure.
- **What I did about it:** Moved the 210 orders and their lines to `quarantine_orders` / `quarantine_order_items` (kept, not deleted), then made every order require an existing customer (sql/10, sql/20).
- **Residual risk:** GH₵665,180.61 of revenue is outside the customer report until someone identifies the customers. New orders cannot be created without a valid customer.

### F-07: Stock movements for products that do not exist — Severity: Medium

- **What it is:** Inventory log rows pointing at missing products. No foreign key.
- **How I detected it:** Anti-join from `inventory_log` to `products` (check `orphan: inventory_log.product_id → products`).
- **Scale:** 120 of 282,352 movements.
- **Effect on the client's number:** Entries in the audit trail that no auditor can tie to a product, which undermines the "proof of what happened" Nana asked for.
- **What I did about it:** Moved the 120 movements to `quarantine_inventory_log`, then made every movement require an existing product (sql/10, sql/20). All movements are now protected by the archive trigger (ADR-005).
- **Residual risk:** The 120 movements stay unexplained. New ones cannot point at a missing product.

### F-08: A loop in the category tree — Severity: Medium

- **What it is:** Categories 9001 and 9002 are each other's parent. No standard constraint can prevent this: a check on one row cannot see a loop that spans two.
- **How I detected it:** Recursive walk up the tree recording each path and stopping when a category reappears in its own path (`diagnosis/03_category_cycles.sql`; check `consistency: categories in a cycle`).
- **Scale:** 1 cycle, 2 categories, 6 products directly inside it, no subcategories below.
- **Effect on the client's number:** The 6 products roll up to no department, so their low stock is invisible in Nana's view. A rollup written without a loop guard never finishes.
- **What I did about it:** Left the loop in the data (the correct parent is unknown). The low-stock rollup stops a walk as soon as it revisits a category, shows the two categories with `has_root = false`, and `v_data_health` counts them (sql/60, sql/70). A rule now prevents a category being its own parent.
- **Residual risk:** The 6 products in the loop appear in the rollup under their own categories but under no department, until Nana's team gives 9001 or 9002 a real parent. A new two-category loop is still possible: no single-row rule can see it, so it is detected, not prevented.

### F-09: Order totals that disagree with their lines for no identified reason — Severity: Medium

- **What it is:** After explaining mismatches by lost prices (F-13), double inserts (F-11) and placeholder quantities (F-14), a remainder of orders still disagree with the sum of their lines.
- **How I detected it:** Classified every order by what its lines contain, then measured the size and direction of mismatches in the unexplained group (`diagnosis/02_investigate_totals.sql`).
- **Scale:** 1,594 of 159,384 orders (1%): 789 where the total is higher (+GH₵420,453.66) and 805 where it is lower (−GH₵2,313,763.54). No difference is 5 pesewas or less, so it is not rounding. *To verify: this group appears to include 5 placeholder-quantity orders (F-14) worth about −GH₵1.93m of the lower figure; if so, the truly unexplained remainder is 1,589 orders.*
- **Effect on the client's number:** For about 1% of orders, either the stored total or the lines is wrong and the data cannot say which. Spend is taken from the stored total (see the decision records), so the exposure is bounded to these orders.
- **What I did about it:** Left as it is: the correct figure is unknown. Customer spend is taken from the stored total (ADR-004), which bounds the exposure to these orders.
- **Residual risk:** About 1% of orders may carry a wrong spend figure. New orders are written in one step with total and line together, so they always agree.

### F-10: Orders and stock movements dated after the extract ends — Severity: Medium

- **What it is:** Real activity runs from August 2025 to August 2026. After that, a handful of rows are dated up to August 2027.
- **How I detected it:** Counted orders by month, which showed thousands per month to August 2026 then a trickle; checked the seconds of each timestamp; counted rows on or after 2026-09-01 (checks `date: ... after extract end`).
- **Scale:** 24 orders and 40 stock movements. Every bad-dated order is exactly on the minute, against 1.7–1.8% on the minute in normal months, which points to hand entry rather than the checkout clock. A check against today's date found only 16 and 33, missing 8 and 7.
- **Effect on the client's number:** Spend lands in months that have not happened, distorting the trailing-12-months view, and the audit trail contains movements with impossible dates.
- **What I did about it:** Moved the 24 orders and their lines to quarantine, since their real date is unknown (sql/10). The 40 bad-dated stock movements stay in the trail because the movements are real and the stock reconciles with them; they are listed here. Timestamps are now stored with a time zone (sql/20).
- **Residual risk:** The 40 movements carry impossible dates in the trail. The report window ends at the latest order up to today, so a future date can no longer push spend into months that have not happened (`v_data_health` counts any that appear).

### F-11: Order lines saved twice — Severity: Low

- **What it is:** The same product appears on two lines of one order where the customer paid for it once.
- **How I detected it:** Found orders with repeated `(order_id, product_id)` lines, then compared each order's stored total with its lines: a split sale matches the total, a double insert exceeds it.
- **Scale:** 616 repeated-line groups (1,233 rows). In 533 orders the lines exceed the total by GH₵883,264.69 in all (double inserts); 75 match their total (legitimate splits at different prices, not faults).
- **Effect on the client's number:** Overstates units and revenue per product for these items. Customer spend is unaffected because it is taken from the stored total.
- **What I did about it:** Moved each exact copy to `quarantine_order_items` where the order total shows it was charged once (sql/10). Repeated lines in orders whose total matches (legitimate split sales) were left alone.
- **Residual risk:** Per-product sales for the remaining lines are correct. Nothing stops a new double insert by another application path; `place_order` writes each line once.

### F-12: Order lines belonging to no order — Severity: Low

- **What it is:** Lines whose `order_id` points at an order that does not exist. No foreign key.
- **How I detected it:** Anti-join from `order_items` to `orders` (check `orphan: order_items.order_id → orders`).
- **Scale:** 692 of 336,559 lines.
- **Effect on the client's number:** Dropped by any report that joins lines to orders. Customer spend is unaffected; per-product sales are slightly off.
- **What I did about it:** Moved the 692 lines to `quarantine_order_items`, then made every line require an existing order (sql/10, sql/20).
- **Residual risk:** None for new lines.

### F-13: Order lines that lost their price — Severity: Low

- **What it is:** Lines with an empty price (148) or a price of exactly zero (152). Zero looks like a free item but is not: in 147 of the 151 orders containing one, the stored total is higher than the lines, so the customer was charged.
- **How I detected it:** `unit_price IS NULL` and `unit_price <= 0` checks, then compared the totals of the orders containing them with their lines.
- **Scale:** 300 lines. Orders with them are under-represented by GH₵447,270.88 at line level (GH₵323,142.93 for empty prices, GH₵124,127.95 for zero prices); 28 orders have no priced line at all.
- **Effect on the client's number:** Line-level revenue is understated. Customer spend is unaffected because it is taken from the stored total.
- **What I did about it:** Left the lines as they are: the price actually paid is unknown, and today's product price is not it. Customer spend uses the stored order total, so the report is unaffected (ADR-004). A rule now requires a positive price on every new or changed line; history is not rechecked (`NOT VALID`).
- **Residual risk:** Line-level revenue for these 300 lines stays understated. New lines always carry the price at sale.

### F-14: Placeholder quantities — Severity: Low

- **What it is:** Lines with quantity 999 or 9999 where the customer bought one.
- **How I detected it:** Investigating the largest total-vs-lines mismatches, then listing every line with quantity above 20.
- **Scale:** 6 lines (4 × 999, 2 × 9999). Every other line in the table has quantity 20 or less. In each affected order, the stored total matches a quantity of one.
- **Effect on the client's number:** About GH₵3.07 million of revenue that does not exist, in any figure built from lines. Customer spend is unaffected because it is taken from the stored total.
- **What I did about it:** Set each placeholder quantity to the quantity the order total implies, where that comes out as a whole number between 1 and 20; any line where it does not is left and listed in `data_fix_log` for review (sql/10). A rule now requires quantity above 0.
- **Residual risk:** A line left for review keeps its placeholder until checked by hand. Nothing yet caps how large a quantity can be; an optional cap is listed under recommendations.

### F-15: A category whose parent does not exist — Severity: Low

- **What it is:** One category points at a missing parent. No foreign key.
- **How I detected it:** Anti-join on the category tree, then a recursive walk down from it to count what it contains (`diagnosis/03_category_cycles.sql`).
- **Scale:** 1 of 94 categories, with no subcategories and no products below it.
- **Effect on the client's number:** None today. Any product filed under it later would disappear from the low-stock view.
- **What I did about it:** Moved the empty category to `quarantine_categories` and made every category's parent a real category (sql/10, sql/20).
- **Residual risk:** None.

## Looked wrong, is not wrong

| Apparent problem | Why it looks wrong | Why it is actually fine |
|---|---|---|
| Negative quantities in the stock log | Stock movements below zero | Outward movements are recorded as negative by design (schema comment). Every sign matches its reason: sales and damage negative, restocks and returns positive. |
| Price paid differs from today's product price | Same product, two prices | The line records the price at the moment of sale; prices change over time. |
| 22% fewer units logged as sold than appear on order lines | Looks like 117,800 units missing from the audit trail | Stock moves only for completed and shipped orders. Their units (412,715) match logged sales (412,645) to within 70 units (0.02%). |
| 377 groups of products sharing a name | Looks like duplicate products | Different prices within each group: sizes, colours, capacities or suppliers. Only the 23 listings in F-02 are true duplicates. |
| 75 orders with the same product on two lines | Looks like a double insert | Each matches its stored total: the item was sold at two prices (e.g. part on promotion). |
| Customers sharing a name or phone number | Looks like duplicate customers | People share names; households and businesses share phones. Only shared email plus name (F-05) identifies a duplicate. |
| 37 products with no category | Looks like missing data | Uncategorised products are allowed (the concurrency test itself creates them). They do need a place in the low-stock view. |
| 7 categories with no parent | Looks like orphans | These are the top-level departments. |
| Stock-movement reason is free text | Free text usually drifts | It has stayed clean: six consistent values, no variants. |
| No orders with a zero or negative total | (Checked because cancelled orders might be zeroed) | Cancelled orders keep their total; the status marks the cancellation. |
| ~330 orders a day on average vs "4,000 a day" in the brief | Looks like missing data | Volume grew from about 70 a day (Aug 2025) to about 1,170 a day (Aug 2026). The business is growing toward the brief's figure. |

## Could not verify

- **The 1,594 orders whose total disagrees with their lines (F-09):** which figure is correct cannot be determined from the data.
- **90 stock takes recorded with zero change:** either every count matched the system, or adjustments were not logged.
- **Refunded orders:** 21,531 units on refunded orders have no sale movement and returns total only 1,017 units. Assumed refunded before shipping; not provable from the data.
- **The time zone of stored timestamps:** none is recorded. Assumed Accra time (UTC+0), which makes the missing zone harmless today.
- **The cause of the 23 duplicate listings (F-02):** the IDs are contiguous but creation dates span three years.
- **The extract end date:** assumed 31 August 2026, the last month with real order volume.
- **About 425 inventory notes** have not been read; they may explain some corrections.
