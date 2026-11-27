# Evidence Needed by Reason Code

This list is invented for a demonstration.

## Duplicate processing (P20)

- Both charges: ids, times, amounts, card, merchant.
- The gap in time between them.
- The merchant's refund history.

## Not recognised (F10)

- The charge: channel (chip and PIN, contactless, online, phone), time, merchant.
- Card status at the time.
- The device fingerprint, if the charge was online.
- Linked cases on the same merchant or the same device.

## Goods or services not received (S30)

- The charge and the date the goods were due.
- Any refund the merchant already posted.
- The merchant's dispute ratio.

## Cancelled subscription (R40)

- The earlier charges of the same subscription.
- The date of the cancellation.

## Wrong amount (A50)

- The agreed price and the charged amount.

When an item cannot be found, attach an evidence item of kind gap and name what is missing.
