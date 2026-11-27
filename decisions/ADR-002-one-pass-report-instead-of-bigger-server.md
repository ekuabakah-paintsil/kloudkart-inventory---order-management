# ADR-002: Make the Monday report fast by computing it in one pass, not with a bigger server

- **Status:** Accepted
- **Date:** 2026-11-25
- **Decision owner:** Ekua Micah Abakah-Paintsil

## Context

Adwoa's report takes about forty minutes and some Mondays does not finish, so Nana decides without it. Someone has priced a bigger server. The brief rules out new infrastructure and any monthly bill, and asks for the report "in seconds on an ordinary laptop".

The report needs, for every customer: total spent, order count, spend per month for the trailing twelve months, a running total, and a top-100 ranking.

A deliberately naive version (`measurement/x50_monday_report_before.sql`) looks each figure up separately: per customer, one search for the total, one for the count and one for each of the twelve months, i.e. 14 searches of the orders table for each of about 40,000 customers. On the real extract it took **38.5 s for 500 customers**, which scales to **about 52 minutes for all 40,420**, matching Adwoa's "about forty minutes, and some Mondays it does not finish". The query plan shows why: each of the 14 lookups is a full scan of the orders table that reads all 159,384 orders and discards 159,381 of them to find a customer's 3 or so (`Seq Scan on orders … loops=500`, `Rows Removed by Filter: 159381`). That is 7,000 full scans for 500 customers, about 566,000 for everyone.

## Decision

The report is a set of views that read the orders table once: one grouped pass per customer produces the total, the count and all twelve months together; window functions add the ranking and the running total. Foreign-key and date indexes support the joins and the reporting window.

## Alternatives considered

### Alternative A: A bigger server

- **How it would work:** Same report, more CPU and memory.
- **Why it is attractive:** No change to the report.
- **Why rejected:** The cost is in the shape of the query, not the size of the machine: roughly 560,000 separate searches. A server twice as fast still takes twenty minutes, and the brief forbids the bill.

### Alternative B: Add indexes and keep the per-customer lookups

- **How it would work:** An index on `orders(customer_id)` lets each lookup find a customer's orders directly.
- **Why it is attractive:** A one-line change that helps a lot.
- **Why rejected as the whole answer:** It still performs 14 lookups per customer. The index is kept, because joins and foreign-key checks need it, but the main gain comes from doing the work once.

### Alternative C: A materialised view refreshed before Monday

- **How it would work:** Store the finished report and refresh it on a schedule.
- **Why it is attractive:** Reading it is instant whatever its size.
- **Why rejected:** The figures are only as fresh as the last refresh, and someone has to own the schedule. The one-pass version is already fast enough to be computed live. It remains the next step if volume grows (see below).

### Alternative D: A summary table updated by every order

- **How it would work:** `place_order` adds each sale to a per-customer, per-month total.
- **Why it is attractive:** Always current and instant.
- **Why rejected:** Every order would then also lock that customer's summary row, adding work and a second place for the figures to disagree. Not justified at current speed.

## Consequences

- **What this buys:** The full report for all 40,420 customers in **0.87 s** (median of 10 runs; worst 1.10 s), against about 52 minutes before, roughly 3,600 times faster. The top 100 takes 0.13 s and the running total 0.29 s. Measured on the real extract (`docs/measurement_report.md`). Always current, nothing to refresh, no new server.
- **What this costs:** A few indexes, which make each new order very slightly slower to write.
- **What it costs the client if I am wrong:** If live computation becomes too slow as volume grows, Adwoa's Monday slips again. That would show up gradually, not suddenly, and the switch to Alternative C is small.
- **What would make me revisit this:** The report taking more than a few seconds.

## What this survives

Volume grew from about 70 orders a day (August 2025) to about 1,170 (August 2026), and the brief expects 4,000. At 4,000 a day the table gains about 1.5 million orders a year. One pass grows in step with the table: roughly ten times today's work, so about 9 seconds from today's 0.87 s. That is still "seconds", but near the edge of what Adwoa should wait for. That point is the trigger to adopt Alternative C (store the finished report and refresh it before Monday), and it can be seen coming in the weekly timing. The naive version grows with customers × months and would be measured in hours.

**What a naive build would have cost later:** the per-customer version is fine on a test database with a few hundred customers. It fails only on real volume, and it fails worse every week the business grows: the forty minutes Adwoa has today would keep climbing.
