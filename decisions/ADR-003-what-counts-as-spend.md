# ADR-003: Spend is the checkout total of non-cancelled, non-refunded orders, over the twelve months up to the latest order

- **Status:** Accepted
- **Date:** 2026-11-25
- **Decision owner:** Ekua Micah Abakah-Paintsil

## Context

The brief asks for "total spent" and "monthly spend for the trailing twelve months" without defining either, and Nana is not available to ask. The data forces three choices:

1. **Which figure.** Each order has a stored total (`total_amount`, written at checkout) and a set of lines (quantity × price). They disagree on 2,398 orders, because the lines are damaged in four ways: lost prices (F-13), double-inserted lines (F-11), lines with no order (F-12) and placeholder quantities (F-14), the last alone worth about GH₵3.07 m of revenue that does not exist.
2. **Which orders.** Cancelled orders keep their total (status marks the cancellation), and so do refunded ones.
3. **Which twelve months.** The extract ends in August 2026; today is November 2026.

## Decision

- Spend is `orders.total_amount`.
- Pending, shipped and completed orders count; cancelled and refunded do not.
- The twelve months end with the month of the latest order on or before today (August 2026 on this extract; the current month on live data).

## Alternatives considered

### Alternative A: Sum the order lines

- **How it would work:** spend = Σ quantity × unit price.
- **Why it is attractive:** It is the detailed figure and can be broken down by product.
- **Why rejected:** It is wrong in both directions on known orders: understated where prices were lost, overstated by double inserts and by about GH₵3.07 m of placeholder quantities. The stored total agrees with the lines on 98.5% of orders, and in every extreme mismatch the total was the believable figure.

### Alternative B: Count refunded orders as spend

- **How it would work:** Only cancelled orders are excluded.
- **Why it is attractive:** The customer did place and pay for the order.
- **Why rejected:** The money went back. Ranking customers by money they no longer spent would put the wrong people in the top 100.

### Alternative C: Exclude pending orders too

- **How it would work:** Only shipped and completed orders count.
- **Why it is attractive:** Only fulfilled sales.
- **Why rejected:** Stock is now committed at placement (ADR-001), so a pending order is a real commitment, and leaving it out understates this week's spenders. It is a one-word change if Adwoa prefers fulfilled-only.

### Alternative D: Twelve months ending today

- **How it would work:** Window = the last twelve calendar months from today.
- **Why it is attractive:** It is what "trailing twelve months" means on a live system.
- **Why rejected for this extract:** The data ends in August 2026, so the last three months would be empty and the report would look like sales collapsed. Anchoring on the latest order gives the same answer as "today" on live data and the right answer on an extract.

## Consequences

- **What this buys:** A spend figure that survives every line-level fault found, a ranking that matches money actually kept, and a window that is right whether the report runs on live data or on an extract.
- **What this costs:** Spend cannot be broken down by product from the same figure; product-level revenue still depends on the lines.
- **What it costs the client if I am wrong:** On the 1,589 orders whose total and lines disagree for no identified reason (F-09), about 1% of orders, either figure may be the wrong one; the exposure is bounded to those orders. If Nana wanted refunds counted, the 6,479 refunded orders would be missing from spend.
- **What would make me revisit this:** Nana or Adwoa defining spend differently. Each choice is one line in `v_spend_orders`.

## What this survives

New orders are written in one step by `place_order`, total and line together, so the disagreement between them cannot grow. The cleaned status values (F-04) and the status rule in the database mean "exclude cancelled" cannot again miss 75% of cancelled value through spelling.
