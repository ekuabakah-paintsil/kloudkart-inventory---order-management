# ADR-005: Fix data only where the correct value is known; quarantine the rest; delete nothing

- **Status:** Accepted
- **Date:** 2026-11-25
- **Decision owner:** Ekua Micah Abakah-Paintsil

## Context

The diagnosis found fifteen faults (`docs/data_findings.md`). The rules that prevent them (foreign keys, value checks, uniqueness) cannot be added while the bad rows are still there: PostgreSQL refuses a foreign key while orphans exist. But for several faults, nobody knows what the correct value is.

## Decision

Each fault gets one of three treatments, decided by whether the correct value is known:
- **Fix in place** where the right value is certain: status spellings (F-04), duplicate customers merged into one record (F-05), duplicate product listings merged (F-02), negative stock reset to 0 with a recorded correction (F-03), placeholder quantities set to what the order total implies (F-14), recounts already in the stock log but never applied, for the 31 products where the gap proves it (F-01), and city spellings (F-16).
- **Quarantine**, meaning move to a `quarantine_*` table with the finding and reason, where the row is broken and cannot be repaired: orders with no customer (F-06), orders dated after the extract ends (F-10), lines with no order (F-12), double-inserted lines (F-11), movements for missing products (F-07), the empty orphan category (F-15).
- **Leave and document** where the right value is unknown: the other 113 products whose stock disagrees with their trail (F-01), the category loop (F-08), the unexplained total mismatches (F-09), lost prices (F-13).

Every in-place change is recorded in `data_fix_log`. Nothing is deleted outright.

## Alternatives considered

### Alternative A: Delete the bad rows

- **How it would work:** Remove anything that breaks a rule.
- **Why it is attractive:** Clean tables, simplest scripts.
- **Why rejected:** It destroys evidence. The 210 customerless orders are GH₵665,180.61 of real revenue; deleting them makes that money disappear from the books instead of from one report.

### Alternative B: Fix everything, including the unknowns

- **How it would work:** Reset every stock figure to its trail, fill lost prices from today's product price, re-parent the loop.
- **Why it is attractive:** Every check would show zero.
- **Why rejected:** It would be guessing and calling it a fix. The trail might be the wrong side for F-01; today's price is not the price paid (F-13). The rubric penalises "effort spent fixing what was never broken", and inventing values is worse.

### Alternative C: Leave all data as it is and add rules for new rows only

- **How it would work:** Add every rule as `NOT VALID`, which applies to new and changed rows but does not check history.
- **Why it is attractive:** No data changes at all.
- **Why rejected as the general approach:** The report and the rollup would keep reading broken history. It is used for exactly one rule, `unit_price > 0`, where the historical zero prices are a documented, unfixable fault (F-13).

## Consequences

- **What this buys:** Every rule from the diagnosis is now enforced, so these faults cannot recur; every changed or removed row can be traced; nothing was invented.
- **What this costs:** Seven extra tables, and some checks still show non-zero counts for the faults left by decision.
- **What it costs the client if I am wrong:** A merge could join two real people who share an email and name, or two genuinely separate products listed identically. Both rules require an exact normalised match, and every merge is in `data_fix_log` so it can be reversed.
- **What would make me revisit this:** The physical stock take of the F-01 products (`v_stock_drift` lists them), which will show which side was right.

## What this survives

The cleanup runs once, as part of a fresh load. From then on the rules do the work: under flash-sale volume, a wrong status, an orphan line, a duplicate customer email or negative stock is refused at the moment it is written.
