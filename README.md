# Kloud Kart — Inventory & Order Management

DE03 lab (SQL / PostgreSQL). Kloud Kart is an Accra e-commerce company whose database
oversold stock under contention and whose weekly customer-spending report took about
forty minutes (about 52 when measured on the full extract). This repository diagnoses the data and fixes both problems on the existing
PostgreSQL server: no new infrastructure, no new cost.

| Client criterion | Where it is met | Result |
|---|---|---|
| No overselling | `sql/40_place_order.sql` | `race_test.py` passes unmodified: 400 buyers for 50 units in 3.5 s, 0 errors |
| Fast Monday report | `sql/50_monday_report.sql` | 0.87 s for all customers, from about 52 min |
| Low-stock rollup through the category tree | `sql/60_category_rollup.sql` | any depth, loop-safe, 5 ms |
| Audit trail of every stock movement | `sql/30_audit_trail.sql` | nothing can vanish or change silently |

---

## Requirements

- Docker Desktop
- Python 3 with `psycopg2-binary` (for `race_test.py`)
- The `data/` folder from the Evalu8 bundle (confidential, not committed; see below)

## Setup

### 1. Add the data

`schema.sql`, `load.sql` and `race_test.py` from the Evalu8 bundle are included in this
repository **unmodified**. The `data/` folder (six CSVs) is confidential and **not committed**:
copy it from the bundle into the repository root.

```
kloudkart-lab/
├── schema.sql        ← Evalu8 bundle, unmodified
├── load.sql          ← Evalu8 bundle, unmodified
├── race_test.py      ← Evalu8 bundle, unmodified
├── data/             ← ADD THIS: six CSVs from the bundle (not committed)
├── sql/              ← the solution (00 runs 10-70)
├── diagnosis/        ← the integrity checks and investigations
├── measurement/      ← timing, query plans and CSV exports
├── results/          ← created by the measurement scripts
├── decisions/        ← ADR-001 … ADR-006
└── docs/             ← findings, memo, improvement, measurement report
```

### 2. Start PostgreSQL 18 with connection headroom

`max_connections=500` is required: the race test opens 400 simultaneous connections and
the default of 100 makes it fail with an error that does not mention connections.

```powershell
docker run -d --name kloudkart -e POSTGRES_PASSWORD=kloudkart -p 5432:5432 -v "${PWD}:/lab" postgres:18 -c max_connections=500
docker exec -it kloudkart psql -U postgres -c "SHOW max_connections;"   # must print 500
```

After a restart: `docker start kloudkart`.

### 3. Point Python at the database

```powershell
setx DATABASE_URL "postgresql://postgres:kloudkart@localhost:5432/postgres"
```

Open a new terminal afterwards.

---

## Running the solution

One command builds everything from a fresh load, with no manual steps: it drops and
reloads the extract, cleans it, adds the rules, builds the functions and reports, then
prints the row counts after cleanup and the integrity checks after the fixes.

```powershell
docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f sql/00_run_all.sql
python race_test.py
```

Then, for example:

```sql
SELECT * FROM monday_report_top100;                 -- Adwoa's top 100
SELECT * FROM monday_report WHERE customer_id = 1;  -- one customer, with 12 months
SELECT * FROM v_report_months;                      -- which month each column m01..m12 is
SELECT * FROM v_low_stock_rollup ORDER BY path;     -- low stock by category
SELECT * FROM v_audit_trail WHERE product_id = 1;   -- every movement of one product
SELECT * FROM v_data_health;                        -- is the data still clean?
SELECT * FROM place_order(1, 1, 1);                 -- places a REAL order and takes 1 unit of stock
```

### Measuring and saving the evidence

The full sequence, from raw data to every piece of evidence in `results/`.
In Windows PowerShell, set UTF-8 first, or dashes and arrows in the saved `.txt` files come out garbled (`ΓÇö`):

```powershell
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
```

```powershell
# Before: raw data, no solution
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f schema.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f load.sql
docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f measurement/x01_export_baseline.sql
docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f measurement/x50_monday_report_before.sql | Tee-Object results/before_plan.txt

# Build, test, then after
docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f sql/00_run_all.sql | Tee-Object results/run_all_output.txt
python race_test.py | Tee-Object results/race_test_output.txt
docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f measurement/x90_export_results.sql
docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f measurement/x80_measure.sql | Tee-Object results/after_plans.txt
```

`results/` holds counts, timings and plans (committed as evidence).
`results/client_data/` holds customer-level report exports and is **never committed**.

---

## Repository contents

**Solution** (`sql/`, run in this order by `sql/00_run_all.sql`)

| File | Purpose |
|---|---|
| `sql/00_run_all.sql` | Fresh load, then every script below, then the checks |
| `sql/10_cleanup.sql` | Fixes faults where the correct value is known; moves the rest to `quarantine_*` tables; logs every change in `data_fix_log` |
| `sql/20_constraints.sql` | Foreign keys, value rules, uniqueness, time zones, generated ids: the rules that stop each fault recurring |
| `sql/30_audit_trail.sql` | Order and author on every movement; archive of every change; `v_audit_trail` |
| `sql/40_place_order.sql` | `place_order` (concurrency-safe) and `cancel_order` |
| `sql/50_monday_report.sql` | `monday_report`, `monday_report_top100`, `monday_report_running_total` |
| `sql/60_category_rollup.sql` | `v_low_stock_rollup`, `v_low_stock_products`, loop-safe category paths |
| `sql/70_improvement.sql` | `v_stock_drift` and `v_data_health` (improvement beyond the brief) |

**Diagnosis and measurement** (run by hand; not part of the build, except `01`, which `00` reruns at the end)

| File | Purpose |
|---|---|
| `diagnosis/01_integrity_checks.sql` | One row per check (56 checks); run before and after for the before/after figures |
| `diagnosis/02_investigate_totals.sql` | Why 2,398 order totals disagree with their lines |
| `diagnosis/03_category_cycles.sql` | Cycles and orphans in the category tree |
| `diagnosis/04_investigate_stock.sql` | Is the stock trail complete? |
| `measurement/x01_export_baseline.sql` | Saves the 56 checks and row counts on the raw data as CSV (the "before") |
| `measurement/x50_monday_report_before.sql` | The slow "before" version of the report, timed, with its query plan |
| `measurement/x80_measure.sql` | Timed runs of each report, with query plans (the "after") |
| `measurement/x90_export_results.sql` | Saves the checks, row counts, cleanup summary, data health and median/p95/worst timings as CSV (the "after"), plus confidential report exports to `results/client_data/` |

**Written deliverables**

| File | Deliverable |
|---|---|
| `docs/data_findings.md` | 1. Data diagnosis: 15 findings ranked by risk |
| `sql/` (run by `sql/00_run_all.sql`) | 2. Working SQL solution; `race_test.py` passes unmodified |
| `decisions/ADR-001` … `ADR-006` | 3. Key decisions, including whether triggers alone would have worked |
| `docs/client_memo.md` | 4. One-page memo to Nana |
| `docs/improvement.md` | 5. Improvement beyond the brief |
| `docs/measurement_report.md` | Before/after performance figures |
| `docs/working_notes.md` | Schema review, judgement calls and every measurement taken |

---

## Assumptions (decided because the brief did not settle them)

- The extract ends on 2026-08-31, the last month with real order volume.
- Stored timestamps are Accra time (UTC+0).
- Spend = the order's checkout total, counting pending, shipped and completed orders; cancelled and refunded orders excluded.
- The report's twelve months end with the month of the latest order up to today.
- "Low stock" = 10 units or fewer, adjustable per product.

Each is explained, with what it costs if wrong, in `decisions/`.

## Notes

- The client data is confidential and never committed. `.gitignore` excludes `data/`, every CSV except the summary files directly in `results/`, and the customer-level exports in `results/client_data/`. The bundle's scripts (`schema.sql`, `load.sql`, `race_test.py`) are committed unmodified so the build runs from a fresh clone.
- No connection strings or passwords are hard-coded in scripts; Python reads `DATABASE_URL` from the environment.

## AI use

AI was used to understand concepts and polish queries for easy understanding

## Author

Ekua Micah Abakah-Paintsil
