# Fault Code Handling Guide

This guide is invented for a demonstration.

How the service agent works one fault or one service request, in order.

1. Read the case and the machine. A fault code that shows more than once in the last 90 days is a repeated fault. Say so in the diagnosis.
2. Read the fault code. If it is safety critical, stop and send the case to a person.
3. Read the service bulletins that match the fault code and the model.
4. Read the telematics for the last 30 days. Compare the mean coolant temperature of the last 7 days with the mean of days 23 to 30 ago. A rise of 8 degrees or more is a steady rise (a real fault). Single spikes that fall back are a sensor or a connector. If `get_machine` says `has_telemetry` is false, the machine reports no telematics: there is no rise to read. Say so, never claim a rise you did not read, and make the work order ask the technician to read the coolant over several days. Then either draft the order for the usual part and say that the diagnosis is not confirmed, or send the case to a person with that reason. Both are acceptable, and the manager decides.
5. Ask the record for the warranty decision. Do not decide it yourself.
6. Find the part. If it is superseded, use the replacement. Ask the record for the stock at every dealer and take the nearest dealer that has the quantity.
7. Record the diagnosis and create the work order.
8. Draft the parts order, the warranty claim (only when the record says covered) and the customer notice.
9. Hold a technician slot at the case's dealer.
10. Ask the dealer manager for approval. Then stop.

## Rules

- The agent never orders a part, submits a claim, sends a notice or confirms a slot. The dealer manager approves first.
- A fault code that is not in the table, or a case you cannot work, goes to a person. Say "needs human review".
