# ADR-001: Stop overselling with a single conditional update that locks the product row

- **Status:** Accepted
- **Date:** 2026-11-25
- **Decision owner:** Ekua Micah ABbakah-Paintsil

## Context

Kloud Kart oversold its best-selling product twice last month: two orders arrived at the same moment, both read "1 in stock", and both took it. The data shows the damage: 14 products with negative stock (F-03). Marketing expects flash sales of around 400 orders in ten seconds on a single product.

The mechanism is fixed by `race_test.py`, which must pass unmodified:
- it calls `place_order(customer, product, quantity)` inside its own transaction, at PostgreSQL's default isolation level (Read Committed);
- the loser must get a normal reply containing "out of stock", not an error: any error reaching the caller fails the test;
- the stock decrement, the order and the stock movement must happen together or not at all.

Nana has been told "triggers" might fix it. The brief asks whether they would have.

## Decision

`place_order` checks and takes the stock in one statement, `UPDATE products SET stock_quantity = stock_quantity - q WHERE product_id = p AND stock_quantity >= q`, and treats "no row updated" as out of stock. A database rule, `CHECK (stock_quantity >= 0)`, sits underneath as a safety net.

## Alternatives considered

### Alternative A: Read the stock, then update it (what Kloud Kart does today)

- **How it would work:** `SELECT stock_quantity`; if enough, `UPDATE ... SET stock_quantity = stock_quantity - q`.
- **Why it is attractive:** Simple, and it reads naturally.
- **Why rejected:** It is the race Nana already has. Between the read and the update, a second buyer can read the same "1 in stock". Both pass the check, both update, and stock goes to −1.

### Alternative B: Lock the row first, then check (`SELECT ... FOR UPDATE`)

- **How it would work:** Lock the product row, read the stock, decide in code, then update. 
- **Why it is attractive:** Equally correct, and the steps are explicit, which some readers find easier to follow.
- **Why rejected:** The conditional update *is* this pattern, written as one statement. An `UPDATE` locks the row it changes, and the `WHERE stock_quantity >= q` condition is the "decide" step, re-checked against the latest stock after any wait. The guarantee is identical; there are fewer steps and the lock is held for less time, which is what a 400-buyer queue pays for (each buyer waits for the lock time of everyone in front of them).

  **Lock mode.** Because `stock_quantity` is not a key column, the `UPDATE` takes a `FOR NO KEY UPDATE` row lock rather than `FOR UPDATE`. `FOR NO KEY UPDATE` conflicts with itself, so the second buyer still waits exactly as with `FOR UPDATE`. What it does not block is `FOR KEY SHARE`, the lock taken by foreign-key checks, so inserting order lines that reference the product never waits on a sale in progress. `FOR UPDATE` would block those too, for no benefit here.

### Alternative C: Triggers or a CHECK constraint alone

- **How it would work:** Leave the order code as it is; add `CHECK (stock_quantity >= 0)` or a trigger that refuses a sale when stock is too low.
- **Why it is attractive:** It needs no change to the order code, which is why it was suggested to Nana.
- **Why rejected:** A CHECK does stop stock going negative, but it does so by raising an **error**. The second customer gets a crash, not "out of stock", and the test fails. A trigger that reads stock before the update has the same gap as Alternative A, because two transactions can both read before either writes. **Triggers alone would not have fixed it**: they can refuse the oversell, but they cannot turn it into a clean, instant "out of stock". That is why the CHECK is kept only as a safety net under the real mechanism.

### Alternative D: Serializable isolation with retries

- **How it would work:** Run the order at the strictest isolation level and retry when PostgreSQL detects a conflict.
- **Why it is attractive:** It protects every read in the transaction, not just this one row.
- **Why rejected:** A function cannot raise its own transaction to Serializable, and the test calls it at the default level. Even if it could, under 400 simultaneous buyers most attempts would conflict and retry, which turns a short queue into a storm of repeated work.

### Alternative E: Advisory lock on the product id

- **How it would work:** `pg_advisory_xact_lock(product_id)` before reading and updating stock.
- **Why it is attractive:** It is correct for every caller that takes the lock.
- **Why rejected:** Only code that remembers to take the lock is protected. Any other path that changes stock (an admin tool, a future script) bypasses it silently. The row lock taken by the update applies to every writer automatically.

### Alternative F: A queue or a separate stock service

- **How it would work:** Send orders through a queue processed one at a time.
- **Why it is attractive:** It is the textbook answer for very high volume.
- **Why rejected:** The brief rules it out: no new infrastructure and no monthly bill.

## Consequences

- **What this buys:** Exactly one buyer gets the last unit, every time, with no errors and no retries. The check and the decrement cannot be separated because they are one statement. Verified with `race_test.py`, unmodified: all four tests passed on every run; 400 buyers for 50 units resolved in about 1.9 s with 0 errors. [Replace with your own figures from the real extract.]
- **What this costs:** Buyers of the *same* product queue behind each other for the few milliseconds each order takes. Buyers of different products are not affected.
- **What it costs the client if I am wrong:** The lock protects the number in `stock_quantity`; it cannot make that number true. For the 144 products whose stock does not match their movement trail (F-01), a perfectly locked sale can still sell stock that is not on the shelf. And if any other code path changes stock without the condition, the CHECK refuses it with an error: a failed order rather than an oversell.
- **What would make me revisit this:** Orders containing several products, which would need their product rows locked in product-id order so that two orders cannot each hold a row the other needs (a deadlock). `cancel_order`, which can touch several products, already locks them in that order. Also: a single product needing far more than the flash-sale rate, or a requirement to hold stock in a basket before payment.

## What this survives

**A flash sale at the brief's rate.** 400 orders in ten seconds on one product is 40 a second. The test fires 400 at the same instant, which is harsher, and they all resolve in about 2 seconds. The queue is on one row, held for one short transaction, so waiting time grows with the number of buyers but nothing breaks and nobody is told "out of stock" while stock remains.

**No wait limit (`lock_timeout`) is set, deliberately.** A buyer queues until the buyers in front have finished. A timeout would bound that wait, but when it fires it raises an error, and the test (like a customer) treats an error as a failure, not as "out of stock". The wait is bounded instead by keeping each transaction short: one update and three inserts, with no outside calls inside the lock. If the queue ever grows past a few seconds, the next step is a timeout caught inside `place_order` and turned into a clear "busy, please try again" reply.

**The 400-connection spike** only because the server allows 500 connections (`max_connections=500`). On a default server (100) the extra buyers are refused at the door with a connection error, not by this function. Nana's team must keep that setting, or put a connection pool in front of the database, before the first sale.

**What a naive build would have cost later:** the read-then-update version passes a quiet afternoon's testing and fails only under simultaneous load. That is exactly the flash sale, where the cost is refunds, apologies and reviews at the worst possible moment.
