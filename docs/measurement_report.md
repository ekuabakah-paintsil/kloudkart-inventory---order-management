# Monday report and low-stock rollup: response-time report

> Figures in [brackets] are to be replaced with measurements on the real extract
> (`measurement/x50_monday_report_before.sql` and `measurement/x80_measure.sql`). The figures already shown
> come from a synthetic extract of the same size and are listed under Caveats.

## Target

| Output | Target (from the brief) |
|---|---|
| Monday report: every customer's total spent, order count, 12 monthly figures, running total and top-100 ranking | "In seconds on an ordinary laptop" (today: about 40 minutes, sometimes does not finish) |
| Low-stock rollup through the category tree | "In a couple of seconds" |

## Method

- **Hardware / container spec:** [laptop model, CPU, RAM], Windows with Docker Desktop, PostgreSQL 18.7 in the official `postgres:18` container started with `-c max_connections=500`; all other settings default.
- **What was timed, from which event to which event:** server-side execution of each query, as reported by psql `\timing`, from the query being sent to the last row returned. Output was discarded (`\o /dev/null`) so screen printing is not measured.
- **Runs, warm or cold, and which figure is reported:** 10 consecutive runs per query in one session. Run 1 is cold (data not yet in memory); runs 2–10 are warm. Median and worst are over all 10 runs; p95 with 10 runs is effectively the worst run, and is reported as such.
- **How to reproduce:**
  1. Before: `schema.sql`, `load.sql`, then `measurement/x50_monday_report_before.sql` (raw load, no solution indexes). It times 500 customers, then prints the plan; the full figure is scaled by customers ÷ 500.
  2. After: `sql/00_run_all.sql`, then `measurement/x80_measure.sql`, which times each report 10 times and prints the plans.

## Results

| Scenario | Runs | Median | p95 | Worst | Target met? |
|---|---|---|---|---|---|
| Monday report, all customers (`monday_report`) | 10 | [ ] | [ ] | [ ] | [ ] |
| Top 100 (`monday_report_top100`) | 10 | [ ] | [ ] | [ ] | [ ] |
| Running total, trailing 12 months (`monday_report_running_total`) | 10 | [ ] | [ ] | [ ] | [ ] |
| Low-stock rollup, all categories (`v_low_stock_rollup`) | 10 | [ ] | [ ] | [ ] | [ ] |

## Before / after

| Query / stage | Before | After | Change |
|---|---|---|---|
| Monday report, all customers | [x50 time for 500 customers × customers/500] (synthetic: 38.8 s × 81 ≈ 52 min) | [median] (synthetic: ≈ 0.1 s) | [ ] (synthetic: ≈ 30,000× faster) |
| Running total | done by hand by Adwoa | [median] (synthetic: 0.14–0.37 s) | now automatic |
| Running total, first version of the view | — | synthetic: 1.53 s | reporting month was recomputed for every row; computing it once (`MATERIALIZED`) cut it to 0.14–0.37 s |
| Low-stock rollup | not available | [median] (synthetic: < 3 ms) | — |

### Query plans (EXPLAIN ANALYZE)

| | Before (`x50`, 500-customer sample) | After (`x80`, all customers) |
|---|---|---|
| Expensive step | [14 SubPlan nodes, each with loops=500] | [one scan of orders feeding one aggregate] |
| Orders table read | [500 × 14 times] | [once] |
| Total execution time in plan | [ ] | [ ] |

Paste the relevant lines of both plans here, or attach them, so the reviewer sees *why* the time changed, not only that it did.

**Why the change is this large:** the slow version searches the orders table 14 times per customer (total, count and each of 12 months), about 560,000 searches for 40,000 customers. The new version reads the table once and computes every figure in that pass (ADR-003). A bigger server would only make each of the 560,000 searches somewhat quicker.

## Caveats

- **Synthetic figures.** The figures already shown were measured on a synthetic extract of the same size (40,533 customers, 160,006 orders, 320,391 order lines), PostgreSQL 16, in a Linux container. They show the shape of the improvement; the real-extract figures in brackets are the ones that count.
- **"Before" is extrapolated** from 500 customers. Running it for every customer would take most of an hour.
- **Growth.** Volume rose from about 70 orders a day (Aug 2025) to about 1,170 (Aug 2026), and the brief expects 4,000. The one-pass report grows in step with the number of orders: roughly ten times today's work at 4,000 a day for a year, still about a second. If it ever exceeds a few seconds, storing the finished report and refreshing it before Monday is the next step (ADR-003, Alternative C).
- **Concurrency is measured separately:** `race_test.py` reports its own wall-clock time (400 buyers, 50 units: [ ] s on the real setup; 1.9 s synthetic).
