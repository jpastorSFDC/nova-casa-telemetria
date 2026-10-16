# Understanding the problem (deliverable 1): what happened since

The deliverable itself is [`entregables/01-entendimiento-del-problema.pdf`](../entregables/01-entendimiento-del-problema.pdf): personas, the priority problem (the building operator), success indicators, questions, assumptions, decisions and risks. It's frozen as handed in, and this file doesn't repeat it. Personas, Laura's story and the formative frontier are in `Sprint 2 - Nova Casa.md`.

This file only tracks what happened, during Development, to the open questions and assumptions from Discovery. Each answer points to where it was settled.

## Open questions

| Question | Where it stands | Where |
|---|---|---|
| Which object is the intervention? | Closed: `Case` | D001 |
| How to break a tie on the same `occurredAt`? | Closed: higher severity, then `messageId` | D003 |
| Exact threshold operators and values per asset type and measurement type | Open. The values live in `Umbral__c` and are seeded from the team's reference table; the facilitator hasn't confirmed them | D004, D006, D019 |
| Sharing model for buildings and assets (BR-208) | Implemented; the facilitator hasn't approved the OWD change | D022, [acceso.md](acceso.md) |
| Does the simulator publish the Platform Event, or do we need a bridge? | Our Apex calls the simulator and publishes `Senial_Sensor__e`; the facilitator hasn't confirmed this meets US-201 criterion 1 | D031 |
| Do Building/Asset objects already exist in the org? | We use the standard `Account` (building) and `Asset`, loaded from the simulator catalog | D005 |
| Did MDSS provision the persona profiles and permission sets? | No. We defined the roles, the `Nova_Casa_*` permission sets and the Minimum Access profile setup ourselves | D022, [acceso.md](acceso.md) |
| What counts as an invalid message? | Our list of rules; the facilitator hasn't confirmed it | D032 |

## Assumptions

| Assumption | Did it hold? |
|---|---|
| Building and Asset are new concepts for this org | Yes. Standard `Account` and `Asset` with an `External_Id__c` each (D005) |
| The simulator can be pointed at our org with no extra work on our side | Partly. It needed a session bootstrap and a cursor header that the MDSS contract doesn't show, and an exact authentication parameter name ([contrato-mensaje.md](contrato-mensaje.md)) |
| The 200-signal batch (BR-202) matches the Platform Event trigger batch | Yes. The `Nova_Casa_Procesamiento` subscriber config runs the trigger with batch size 200 (D017), and a simulator page never exceeds 200 (D013) |

## Simulator connection notes

Moved to [contrato-mensaje.md](contrato-mensaje.md), "Connection".
