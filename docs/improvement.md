# Improvement beyond the brief: a standing stock-drift watch and data health check

## The problem it solves

Nana's complaint was that his stock counts "no longer match reality closely enough to trust", and nobody could say which products, by how much, or since when. The audit found the answer, 144 products whose stock does not equal the sum of their recorded movements (F-01), but only through a one-off investigation. The cleanup could not fix them, because the data cannot say whether the shelf figure or the history is wrong. Without something standing, the next drift would be discovered the same way the last ones were: after an oversell.

The same is true of the other faults found: the new rules stop most of them, but a few (a category loop, a change to stock made outside order placement, a future-dated order) can still happen and would again go unnoticed.

## What I built

`sql/70_improvement.sql`, two views that need no new software or schedule:

- **`v_stock_drift`**: every product whose stock on record differs from what its movement history says it should be, with the difference, what it means in plain words ("more on record than the trail explains: may sell stock that is not there" or "less on record…: unrecorded loss, or stock refused") and the date of its last movement. Empty means every stock figure is explained by its history.
- **`v_data_health`**: one row per rule that matters to Nana, with today's count of breaches and the action to take: products drifting from their trail, negative stock, categories that reach no department, unpriced order lines, orders whose total differs from their lines, orders dated in the future.

Supporting changes make the watch trustworthy from day one: a new product's opening stock is recorded automatically as its first movement (sql/30), and every sale and cancellation records its movement in the same step as the stock change (sql/40). So a product added or sold through the normal route never appears as drift; anything that does appear was changed some other way.

Tested on a synthetic extract: products created and sold through `place_order`, including 400 simultaneous buyers, added no drift; a product whose stock was changed directly appeared immediately.

## What it is worth to Nana

- **A counting list today.** The 144 products become a concrete job for the warehouse: count these, sorted by the size of the gap. The count settles which side was wrong and closes F-01.
- **Early warning afterwards.** Any stock change made outside order placement shows up the day it happens, not after the next oversell. Each oversell cost a refund, an apology and reviews that cannot be undone; one avoided during a flash sale pays for the feature.
- **One place to look.** `SELECT * FROM v_data_health;` answers "is the data still clean?" in a single line, without re-running the audit. For Adwoa, it is a check to run before trusting a Monday report.

## What it cost

- About 80 lines of code and one extra trigger, roughly 50 minutes of work.
- No new infrastructure, storage or schedule: the views are computed when read, in milliseconds at current size.
- It detects problems; it does not fix them. Someone has to look at it. The recommendation to Nana is to make it part of the Monday routine, alongside the report.
