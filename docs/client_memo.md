# Memo to Nana

**From:** Ekua Micah Abakah-Paintsil

**Date:** 25 November 2026

**Subject:** Overselling, the Monday report, and what I found in your data

## What I found

Most of your records are sound: 98.5% of orders agree with their own line items, and 96% of products' stock figures are explained by their stock history. The problems are few, but they sit exactly where you make decisions:

- **144 products show a stock figure their own history cannot explain**, about 2,400 units in total. This is the mismatch you have been feeling. For 40 of them your own stock log says why: a recount was done but never entered. I entered the 31 where the log proves the figure. 23 more products were listed twice, each listing with its own stock, and 14 had already been sold below zero.
- **Order status was typed 15 different ways.** A report that "leaves out cancelled orders" in the obvious way still counted **GH₵28.8 million** of cancelled orders as customer spending.
- **533 customers were registered twice**, so their spending was split and the top-100 list could miss real top customers.
- **210 orders worth GH₵665,180** belong to no customer on file.

## What I built

| What you asked for | Status | Evidence |
|---|---|---|
| No overselling | Done | The required test (400 buyers for 50 units, and two buyers for the last unit, 25 times): exactly one winner every time, everyone else told "out of stock", no errors. 400 buyers were sorted out in 3.5 seconds. |
| A fast Monday report | Done | All customers in about a second (0.9 s typical, 1.1 s at worst), against about 52 minutes before. |
| Low stock at a glance, by category | Done | Every level of the category tree in five thousandths of a second, however deep marketing makes it. |
| Proof of what happened | Done | Every stock movement records the order behind it and who made it; anything changed or removed is kept in a record that cannot be altered. |

The "triggers" you were told about would not have stopped the overselling on their own: they can block a bad sale, but only by making it fail with an error, not by telling the customer "out of stock". A bigger server would not have fixed the report either: it was slow because it searched your orders over half a million times, not because the machine was small. Neither costs you anything new.

## What I recommend

1. **Count the 113 products** still on the list I built, before the first flash sale, starting with the 9 recounted ones the log could not settle. The count tells us which figure was wrong and closes the gap.
2. **Keep the higher connection limit** your system now runs with, or the flash-sale crowd will be turned away at the door.
3. **Check the data health summary every Monday**, alongside the report. It shows at once if any of these problems return.
4. **Decide two things I assumed:** that refunded orders do not count as spending, and that "low stock" means 10 units or fewer. Both are easy to change.

## What I could not stand behind

- **About 1,600 orders (1%)** have a total that disagrees with their items for no reason I could find. I used the checkout total, but I cannot prove it is the right one.
- **The 113 remaining stock figures** stay as they are until counted. Until then, the system can only protect the number it is given.
- **Your record times have no time zone.** I assumed Accra time; it matters only if a system elsewhere ever writes to your records.
