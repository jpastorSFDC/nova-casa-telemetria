# Message contract (deliverable 5)

MDSS asks for: "Contrato del mensaje: campos, identidad, fechas, unidades y ejemplos válido e inválido." The documented contract is the "Contrato" section of `Sprint 2 - Nova Casa.md` (request, response example and field meanings). It isn't repeated here.

This file records what the simulator really sends, which differs from that example in a few places, and how each field lands in Salesforce. The real responses are in [`muestras/`](muestras/), captured on 2026-09-30: `telemetry.json` (one page of 200 messages) and `catalog.json`. The reasoning behind each rule is in the D-entries of [`decisiones.md`](decisiones.md).

## Connection

- **Named Credential and External Credential**: `Nova_Casa_Simulator` (D002), base path `/api/sprint-2/simulator/v1`. The External Credential's authentication parameter has to be named exactly `BearerToken` (case-sensitive), because the Named Credential's Authorization header formula uses `$Credential.Nova_Casa_Simulator.BearerToken`. The token lives only in Setup.
- **Session bootstrap**: `POST /session` returns a `cursor`. The body can carry `scenario`, `seed` and `batchSize`; the simulator decides whether it honors the last two.
- **Paging**: every `GET /telemetry?limit=N` (N from 1 to 200) sends the cursor in the `X-Simulator-Cursor` header. The response's `pagination.nextCursor` is the cursor for the next page, and `pagination.pollAfterMs` suggests how long to wait. The ingestion doesn't wait for it: one job requests the pages back to back and relies on the 429 retry (D025). The stream ends on `hasMore = false`.
- **Catalog**: `GET /catalog` needs only the Bearer token, no cursor. It lists buildings and assets with their measurement type and unit, and the scenario names.
- **The cursor is a secret**, like the token: it is never stored in a record, a setting or a log (D013, D025).
- Retries on 429/5xx and reopening the session on 409/410 are in D023.

None of this is in the MDSS example, which shows a single `GET /api/v1/telemetry?limit=200` with no session and no cursor header. It's a gap worth raising with the facilitator.

## How the real message differs from the MDSS example

| MDSS example | Real message (`muestras/telemetry.json`) | What we do |
|---|---|---|
| `building.externalId`, `asset.externalId` | `building.id`, `asset.id` | `TelemetriaIngesta` reads `id` and falls back to `externalId` |
| — | `deliveryId` (changes on every resend of the same `messageId`) | Kept on the event and the log; left out of the content fingerprint |
| — | `messageType`: `MEASUREMENT` or `CONNECTIVITY` | `CONNECTIVITY` messages have no `measurement`; they carry `communication` instead |
| — | `communication`: `status` (`HEALTHY`/`LOST`), `gapSeconds`, `lastSeenAt`, `episodeId` | `gapSeconds` is compared with the `CAMERA_CONNECTIVITY` thresholds |
| — | `publishedAt` | When the simulator published it; distinct from `occurredAt` |
| `PRESSURE`, `CELSIUS` and IDs like `AST-BOG-002`, `MSG-000101` | `WATER_PRESSURE`, `KWH_PER_15_MIN`, `LITER_PER_15_MIN`… and IDs like `AST-BOG-PUMP-001`, `msg_000001` | Thresholds (`Umbral__c`) use the real names |
| — | `pagination.pollAfterMs` | Read but not waited for; pages are requested back to back (D025) |

## Fields: from the simulator to `Senial_Sensor__e`

`TelemetriaIngesta` turns each message into one `Senial_Sensor__e` (High Volume, Publish After Commit). All fields are Text: values arrive raw, so the subscriber can reject a bad one with a reason instead of failing the publish. Building and asset names and the city don't travel on the event; they come from the catalog.

| Event field | From | Note |
|---|---|---|
| `Source__c` | `source` | Half of the identity |
| `Message_Id__c` | `messageId` | Other half of the identity |
| `Delivery_Id__c` | `deliveryId` | |
| `Message_Type__c` | `messageType` | `MEASUREMENT` or `CONNECTIVITY` |
| `Building_Id__c` | `building.id` | Must be the building of the asset in the catalog (D032) |
| `Asset_Id__c` | `asset.id` | Matched with `Asset.External_Id__c` |
| `Asset_Type__c` | `asset.type` | |
| `Sensor_Id__c` | `sensorId` | |
| `Measurement_Type__c` | `measurement.type` | Empty on `CONNECTIVITY` |
| `Value__c` | `measurement.value` | Raw text; null or non-numeric is rejected with a reason |
| `Unit__c` | `measurement.unit` | |
| `Occurred_At__c` | `occurredAt` | ISO 8601 |
| `Published_At__c` | `publishedAt` | ISO 8601 |
| `Comm_Status__c` | `communication.status` | `CONNECTIVITY` only |
| `Gap_Seconds__c` | `communication.gapSeconds` | `CONNECTIVITY` only |
| `Last_Seen_At__c` | `communication.lastSeenAt` | `CONNECTIVITY` only |
| `Episode_Id__c` | `communication.episodeId` | Groups the messages of one outage |

## Identity

- The identity is `source|messageId`. It is the unique key of `Log_Senial__c.Identidad__c` (Text 60), written with upsert, and of `Case.Identidad_Senal__c`, so a critical message opens at most one intervention (D010, D011).
- A resend is the same identity with the same content fingerprint (`Huella__c`, SHA-256 of the content without `deliveryId` and `publishedAt`): it only adds to `Reenvios__c`. The same identity with different content is `Conflicto` (D011).
- A message with no `source` or `messageId`, or whose identity doesn't fit in 60 characters, is never published. How it is left as evidence is in D013 (ingestion) and D032 (subscriber).

## Dates

| Moment | Where it's kept | Meaning |
|---|---|---|
| `occurredAt` | `Occurred_At__c` on the event, the log and the reading | When the sensor took the reading. The only date that orders signals (BR-203). Ties: D003 |
| `publishedAt` | `Published_At__c` on the event | When the simulator published it |
| `generatedAt` | Not kept | When the simulator built the response; it isn't the date of any reading |
| Published in Salesforce | `Log_Senial__c.Publicado_At__c` | When our ingestion wrote the `Publicada` row, just before publishing the event (D013) |
| Processed | `Log_Senial__c.Procesado_At__c` | When the subscriber handled it. Publishing isn't processing |

## Units

Each threshold in `Umbral__c` names the unit it expects for its asset type and measurement type (`Unidad_Esperada__c`). A reading in a different unit is `Rechazada` (D032 rule 5). There's no unit conversion.

## Examples

**Valid**: `msg_000002` in `muestras/telemetry.json`, a `WATER_PUMP` reading `WATER_PRESSURE` in `BAR`. `msg_000004` is a valid `CONNECTIVITY` message from a `SECURITY_CAMERA`.

**Invalid** (D032 has the full list of rules), all in the same sample:

| Message | Why it is `Rechazada` |
|---|---|
| `msg_000051` | Asset `AST-UNKNOWN-0001` isn't in the catalog |
| `msg_000057` | `ENERGY_CONSUMPTION` in `WATT`, not the expected `KWH_PER_15_MIN` |
| `msg_000096` | `measurement.value` is null |
