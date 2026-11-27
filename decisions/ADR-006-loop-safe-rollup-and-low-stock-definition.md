# ADR-006: Roll low stock up the category tree with a loop-safe recursive walk; "low" means at or below a per-product threshold of 10

- **Status:** Accepted
- **Date:** 2026-11-25
- **Decision owner:** Ekua Micah Abakah-Paintsil

## Context

Nana wants low stock at a glance, rolled up through categories (Electronics → Phones → Phone Accessories → Cases), in a couple of seconds. The brief forbids hard-coding the depth because marketing keeps adding levels. The data contains a loop (categories 9001 and 9002 are each other's parent, F-08) and 37 products with no category. The brief does not define "low stock".

## Decision

- A recursive query walks the tree to any depth. PostgreSQL's `CYCLE` clause stops a walk the moment it revisits a category, so the loop cannot make the rollup run forever. Categories that never reach a top-level department are shown and flagged, not hidden. A depth limit of 50 levels is a second guard: `CYCLE` reports that a loop exists, and the depth limit guarantees the walk ends whatever else goes wrong. The tree is 3–4 levels deep, so the limit never cuts a real path short.
- Each category's figures mean "products anywhere beneath it, counted once", never a mix of "directly in it" and "beneath it", and never the same product counted at several levels within one row.
- Uncategorised products get their own row.
- "Low stock" means stock at or below `products.low_stock_threshold`, a new column defaulting to 10 that Nana's team can set per product.

## Alternatives considered

### Alternative A: Fixed joins for four levels

- **How it would work:** Join categories to itself four times.
- **Why it is attractive:** Easy to read.
- **Why rejected:** The brief forbids it, and the next subcategory marketing adds would silently drop out of the totals.

### Alternative B: Recursive walk without a loop guard

- **How it would work:** The textbook recursive query.
- **Why it is attractive:** Shorter.
- **Why rejected:** On this data it never finishes: 9001 → 9002 → 9001 → …

### Alternative C: Store each category's path in a column

- **How it would work:** Keep a precomputed path on every category.
- **Why it is attractive:** The rollup becomes a simple grouped query.
- **Why rejected:** It must be rebuilt whenever marketing moves a category, which is one more thing to keep in step. With 93 categories and about 4,000 products the live walk takes milliseconds.

### Alternative D: One fixed low-stock number for everything

- **How it would work:** Low = fewer than 10, hard-coded.
- **Why it is attractive:** Simplest.
- **Why rejected:** Ten phone cases and ten televisions are not the same warning. A per-product column with a default costs nothing and lets the team tune it.

## Consequences

- **What this buys:** Low-stock counts at every level, for any depth, in milliseconds: **5.1 ms** median, 6.0 ms worst, on the real extract, against a target of "a couple of seconds". The loop is visible instead of fatal, and uncategorised products are no longer invisible.
- **What this costs:** The threshold of 10 is a guess until Nana's team sets real values.
- **What it costs the client if I am wrong:** If 10 is too low for fast sellers, they appear healthy until it is too late to reorder.
- **What would make me revisit this:** Thousands of categories, or the team wanting reorder quantities, which would extend the threshold into a reorder plan.

## What this survives

Marketing adding levels: no change needed. Another loop: flagged, not fatal, and counted in `v_data_health`. A flash sale: the rollup reads current stock, so a product sold out at 10:00:05 shows as out of stock on the next look.
