# ADR-004: Protect the stock trail by archiving every change to it, rather than forbidding changes

- **Status:** Accepted
- **Date:** 2026-11-25
- **Decision owner:** Senya (WISDOMSKA)

## Context

Nana wants proof of what happened: a trail of every stock movement that an auditor could walk through afterwards. The existing log covers 96.4% of products exactly, but nothing stops a row from being edited or deleted, and 120 movements point at products that do not exist (F-07).

`race_test.py`, which must run unmodified, deletes the log rows of its own test products when it cleans up.

## Decision

Every UPDATE or DELETE on `inventory_log` first copies the old row, with who and when, into `inventory_log_archive`, which itself refuses all changes. Each movement now records the order behind it and who wrote it. A new product's opening stock is logged automatically. `v_audit_trail` shows live and archived movements together.

## Alternatives considered

### Alternative A: Forbid UPDATE and DELETE on the log

- **How it would work:** A trigger raises an error on any change.
- **Why it is attractive:** The strongest guarantee: history can never change.
- **Why rejected:** The required test deletes its own log rows, so its cleanup would fail. Beyond the test, real corrections are sometimes needed; forbidding them pushes people to work around the database.

### Alternative B: Forbid UPDATE only

- **How it would work:** Rows cannot be edited but can be deleted.
- **Why it is attractive:** Simple, and the test still runs.
- **Why rejected:** A deleted movement disappears without a trace, which is the outcome an auditor most needs to rule out.

### Alternative C: Rely on `place_order` always writing the log

- **How it would work:** No protection; trust the code.
- **Why it is attractive:** No triggers at all.
- **Why rejected:** It protects nothing that bypasses `place_order`, and nothing written before it.

## Consequences

- **What this buys:** Nothing in the trail can vanish or change silently. An auditor sees every movement, every removal and who made it. Verified: the race test's cleanup ran normally and all 240 deleted test movements appeared in the archive; deleting from the archive was refused.
- **What this costs:** Each change to the log writes one extra row. The archive grows with every correction and test run.
- **What it costs the client if I am wrong:** Someone with full administrative rights can still disable the trigger. The archive proves what happened through normal use, not against a determined administrator.
- **What would make me revisit this:** A formal audit requirement (for example tax), which would justify separate database roles so ordinary users cannot touch the triggers.

## What this survives

Under a flash sale the archive is not involved: sales only add rows, and the extra work happens only on edits and deletes. The `order_id` recorded on each sale means an auditor can tie each of the 50 flash-sale units to its order, even if that order is later deleted (it is deliberately not a foreign key, so the trail outlives what it describes).
