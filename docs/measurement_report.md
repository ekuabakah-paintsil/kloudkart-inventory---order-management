# Monday report and low-stock rollup: response-time report

> All timings below were measured on the real extract unless marked "synthetic". The one synthetic figure is a
> development note, explained under Caveats.

## Target

| Output | Target (from the brief) |
|---|---|
| Monday report: every customer's total spent, order count, 12 monthly figures, running total and top-100 ranking | "In seconds on an ordinary laptop" (today: about 40 minutes, sometimes does not finish) |
| Low-stock rollup through the category tree | "In a couple of seconds" |

## Method

- **Hardware / container spec:** HP EliteBook 850 G7 laptop, Intel Core i7-10510U (4 cores, 1.8 GHz), 32 GB RAM,, Windows with Docker Desktop, PostgreSQL 18.7 in the official `postgres:18` container started with `-c max_connections=500`; all other settings default.
- **What was timed, from which event to which event:** the Results table comes from `measurement/x90_export_results.sql`, which runs each query inside the database and times it with `clock_timestamp()` from start to last row; nothing is sent to the screen. `measurement/x80_measure.sql` repeats the runs with psql `\timing`, which also counts sending the rows to psql: 914–1,271 ms for the full report, 143–195 ms for the top 100, 334–376 ms for the running total and 6.6–8.1 ms for the rollup. Both sets are within the target.
- **Runs, warm or cold, and which figure is reported:** 10 consecutive runs per query in one session. Run 1 is cold (data not yet in memory); runs 2–10 are warm. Median and worst are over all 10 runs; p95 with 10 runs is effectively the worst run, and is reported as such.
- **How to reproduce:**
  1. Before: `schema.sql`, `load.sql`, then `measurement/x50_monday_report_before.sql` (raw load, no solution indexes). It times 500 customers, then prints the plan; the full figure is scaled by customers ÷ 500.
  2. After: `sql/00_run_all.sql`, then `measurement/x80_measure.sql` (10 timed runs per report and the plans) and `measurement/x90_export_results.sql` (10 timed runs per report saved to `results/report_timings_runs.csv` and `results/report_timings_summary.csv`).

## Results

| Scenario | Runs | Median | p95 | Worst | Target met? |
|---|---|---|---|---|---|
| Monday report, all customers (`monday_report`) | 10 | 872 ms | 1,041 ms | 1,096 ms | Yes: about 1 s against "seconds" |
| Top 100 (`monday_report_top100`) | 10 | 135 ms | 139 ms | 143 ms | Yes |
| Running total, trailing 12 months (`monday_report_running_total`) | 10 | 294 ms | 310 ms | 310 ms | Yes |
| Low-stock rollup, all categories (`v_low_stock_rollup`) | 10 | 5.1 ms | 5.7 ms | 6.0 ms | Yes: against "a couple of seconds" |

## Before / after

| Query / stage | Before | After | Change |
|---|---|---|---|
| Monday report, all customers | **≈ 52 min**: 38.5 s for 500 customers × (40,420 ÷ 500) (real extract) | **0.87 s** (median) | about **3,600× faster** |
| Running total | done by hand by Adwoa | **0.29 s** (median) | now automatic |
| Running total, first version of the view (synthetic, during development) | — | 1.53 s | reporting month was recomputed for every row; computing it once (`MATERIALIZED`) cut it fivefold |
| Low-stock rollup | not available | **5.1 ms** (median) | — |

### Query plans (EXPLAIN ANALYZE)

| | Before (`x50`, 500-customer sample) | After (`x80`, all customers) |
|---|---|---|
| Expensive step | 14 SubPlan nodes, each a `Seq Scan on orders` with `loops=500`, ~5.2 ms per loop | One `Index Scan using orders_customer_id_idx on orders` (`loops=1`) feeding one `GroupAggregate` (828 ms), which computes every figure for every customer |
| Orders table read | 500 × 14 = 7,000 full scans; each reads 159,384 rows and discards 159,381 (`Rows Removed by Filter: 159381`); 8,933,286 buffer reads | **Once**, for all 39,885 customers: 140,008 orders kept, 19,142 refunded or cancelled removed; 158,100 buffer reads |
| Total execution time in plan | 37,937 ms (500 customers) | **914.664 ms** (all customers); rollup plan 8.128 ms |

Full plans: `results/before_plan.txt` and `results/after_plans.txt`.

One detail in the after plan: the final sort by spend spilled to disk (`Sort Method: external merge  Disk: 2952kB`) because the default sort memory (`work_mem`, 4 MB) is small. Raising it for this query would keep the sort in memory and save a little more time. Not done, because the report already meets the target with default settings.

**Why the change is this large:** the slow version searches the orders table 14 times per customer (total, count and each of 12 months), about 560,000 searches for 40,000 customers. The new version reads the table once and computes every figure in that pass (ADR-002). A bigger server would only make each of the 560,000 searches somewhat quicker.

## Caveats

- **One synthetic figure.** The "first version of the view" row was measured during development on a synthetic extract of the same size, to choose between two versions of the running total. Every other figure is from the real extract.
- **"Before" is extrapolated** from 500 customers. Running it for every customer would take most of an hour.
- **Growth.** Volume rose from about 70 orders a day (Aug 2025) to about 1,170 (Aug 2026), and the brief expects 4,000. The one-pass report grows in step with the number of orders: roughly ten times today's work at 4,000 a day for a year, so about 9 seconds from today's 0.87 s. Still "seconds", but near the edge; storing the finished report and refreshing it before Monday is the next step when it gets there (ADR-002, Alternative C).
- **Concurrency is measured separately:** `race_test.py` reports its own wall-clock time (400 buyers, 50 units: **3.48 s** on the real setup, 0 errors, 50 sold and 350 refused; `results/race_test_output.txt`).
