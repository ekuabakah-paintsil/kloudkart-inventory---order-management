# Kloud Kart — Inventory & Order Management

DE03 lab (SQL / PostgreSQL). Kloud Kart is an Accra e-commerce company whose database
oversells stock under contention and whose weekly customer-spending report is too slow
to use. This repository diagnoses the data, and (in progress) fixes both problems on
the existing PostgreSQL server.

**Status:** data diagnosis in progress. Integrity checks are complete; the solution
(order placement, audit trail, Monday report, category rollup) is not yet built.

---

## What the client asked for

1. **No overselling.** Two customers racing for the last unit: exactly one gets it, the other is told "out of stock", every time.
2. **A fast Monday report.** Per customer: total spent, order count, monthly spend for the trailing 12 months, a running total and a top-100 ranking, in seconds.
3. **Low-stock visibility** rolled up through the nested category tree, in a couple of seconds.
4. **An audit trail** of every stock movement (sale, restock, correction).

---

## Requirements

- Docker Desktop
- Python 3 with `psycopg2-binary` (for `race_test.py`)
- The Evalu8 data bundle (not included in this repository; see below)

---

## Setup

### 1. Add the data bundle

The bundle is provided on Evalu8 and is **not committed here**. Place it in the
repository root so the layout is:

```
kloudkart-lab/
├── schema.sql        ← from the bundle
├── load.sql          ← from the bundle
├── race_test.py      ← from the bundle
├── data/             ← from the bundle (six CSVs)
├── sql/
└── docs/
```

### 2. Start PostgreSQL 18 with connection headroom

Run from the repository root. `max_connections=500` is required: the race test opens
400 simultaneous connections and the default of 100 makes it fail.

```powershell
docker run -d --name kloudkart -e POSTGRES_PASSWORD=kloudkart -p 5432:5432 -v "${PWD}:/lab" postgres:18 -c max_connections=500
docker exec -it kloudkart psql -U postgres -c "SHOW max_connections;"   # must print 500
```

After a restart: `docker start kloudkart`.

### 3. Load the data (fresh load)

`schema.sql` drops and recreates every table, so this can be repeated at any time.

```powershell
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f schema.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f load.sql
```

Expected row counts: categories 94, products 4,023, customers 40,420,
orders 159,384, order_items 336,559, inventory_log 282,352.

### 4. Point Python at the database

```powershell
setx DATABASE_URL "postgresql://postgres:kloudkart@localhost:5432/postgres"
```

Open a new terminal afterwards.

---

## Running the integrity checks

```powershell
docker exec -w /lab -i -e PAGER=cat kloudkart psql -U postgres -f sql/01_integrity_checks.sql
```

Returns one row per check (56 checks) with the number of failing rows.
Labels: **fault** should be 0 after fixes; **info** and **review** are counts to read, not errors.
Date checks assume the extract ends on 2026-08-31, the last month with real order volume.

---

## Repository contents

| Path | Purpose |
|---|---|
| `sql/01_integrity_checks.sql` | One-row-per-check diagnosis; rerun after every change for before/after figures |
| `sql/02_investigate_totals.sql` | Investigation: why 2,398 order totals disagree with their lines |
| `sql/03_category_cycles.sql` | Investigation: cycles and orphans in the category tree |
| `sql/04_investigate_stock.sql` | Investigation: is the inventory log a complete trail? |
| `docs/working_notes.md` | Schema review, judgement calls and every measurement taken |

Files `02`–`04` are investigations that support the diagnosis; they are not part of the solution run.

*Coming next:* schema changes, `place_order` function, audit trail, Monday report,
category rollup, `run_all.sql`, and the five written deliverables.

---

## Notes

- The data bundle is confidential and is never committed. `.gitignore` excludes `data/`, `*.csv` and the bundle files.
- No connection strings or passwords are hard-coded in scripts; Python reads `DATABASE_URL` from the environment.

## AI use

AI was used for understanding concepts as well as assitance in set-up, and explaining codes.

## Author

Ekua Micah Abakah-Paintsil
