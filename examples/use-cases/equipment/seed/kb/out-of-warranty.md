# Out of Warranty and Excluded Faults

This rule is invented for a demonstration.

Some faults are not covered by the warranty, and some machines are outside it.

## A machine outside the warranty

When the record says a machine is outside the months or hours limit, no warranty claim is drafted. The record refuses a claim for it anyway.

The case still goes ahead as a customer-paid repair:

1. Diagnose the fault and create the work order as usual.
2. Draft the parts order for the part the repair needs.
3. Draft the customer notice. It says the repair is not covered by the warranty and that the dealer manager will confirm the price.
4. Ask for approval with the kind `parts_order`. The kind `parts_order_with_claim` is for a covered machine only.

## Faults that are wear items

These fault codes describe wear items and are never a warranty item, even inside the limits: E-309, E-318, E-327, E-336, E-345 and E-354.

For these, follow the steps above: no claim, a customer-paid order.

## What the agent never does

- It never drafts a claim for a machine the record says is not covered.
- It never promises the customer that the dealer will pay.
