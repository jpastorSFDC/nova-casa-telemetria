# Discovery deliverables (frozen)

These are the deliverables handed in at the close of Discovery (Sep 15–26, 2026), in Spanish, as the MDSS facilitator saw them. They are a snapshot: **don't edit them** to match the code. When the build departs from them, the departure is recorded in [`docs/decisiones.md`](../docs/decisiones.md) and listed below.

They guide the design but aren't the spec. For what the system does today, read the D-entries and the code in `force-app/`.

## Which file answers which MDSS deliverable

The numbering follows the "Entregables" section of `Sprint 2 - Nova Casa.md`.

| # | MDSS deliverable | File | Notes |
|---|---|---|---|
| 1 | Entendimiento del problema | [`01-entendimiento-del-problema.pdf`](01-entendimiento-del-problema.pdf) | The version handed in. [`docs/entendimiento.md`](../docs/entendimiento.md) only tracks what happened to its open questions and assumptions. |
| 2 | Prototipo de baja fidelidad | [`02-prototipo-baja-fidelidad.html`](02-prototipo-baja-fidelidad.html) | Clickable mock of the operator LWC: asset list, asset detail, loading, empty and error states. |
| 3 | Arquitectura de una página | [`03-diagrama-solucion.html`](03-diagrama-solucion.html) | **This is deliverable 3**: the one-page diagram plus rules R1–R4. |
| 3 (supporting) | — | [`03-arquitectura-flujo-datos.html`](03-arquitectura-flujo-datos.html) | Interactive walkthrough with illustrative Apex for each piece. Not a deliverable on its own, and superseded: most of its code no longer matches the build (see below). Where it disagrees with `03-diagrama-solucion.html` or `04-modelo-de-datos.html`, those two win. |
| 4 | Modelo de datos inicial | [`04-modelo-de-datos.html`](04-modelo-de-datos.html) | ERD and standard-vs-custom justification. The closest of the four to what was built. |
| 5 | Contrato del mensaje | [`docs/contrato-mensaje.md`](../docs/contrato-mensaje.md) | Not handed in as a separate file during Discovery. The team's notes on the contract live there. |
| 6 | Decisiones y riesgos | [`docs/decisiones.md`](../docs/decisiones.md) | A living file, not frozen: every decision since Discovery is added there. |

## What changed since Discovery

Each row is something one or more deliverables say that is no longer true. D-numbers are entries in [`docs/decisiones.md`](../docs/decisiones.md), which has the reasoning; this table doesn't repeat it.

| Topic | What the deliverables say | What was built | Decision |
|---|---|---|---|
| Intervention object | Still open: Case, WorkOrder or Incident (all four) | `Case` | D001 |
| Thresholds | Custom Metadata `Umbral__mdt` (01, 03-arquitectura, 04) | Custom object `Umbral__c`, edited by the coordinator, with save-time validation of contradictory ranges | D004, D018, D019 |
| Tie-break on equal `occurredAt` | Open (04), or "the highest `messageId` wins" as an example (01) | Higher severity, then `messageId` in ascending alphabetical order; the loser is `Superada` | D003, D011 |
| Where the current reading lives | Fields on `Asset` (03-arquitectura only) | `Lectura_Vigente__c`, one row per asset + measurement type, as 01, 03-diagrama and 04 already said | D011 |
| Deduplication | SOQL lookup on `messageId` (03-arquitectura only) | Unique `Log_Senial__c.Identidad__c` (`source\|messageId`) written with upsert, as 04 already said; same key with other content is `Conflicto` | D010, D011 |
| When a Case opens | Only if the asset has no open Case (03-arquitectura only) | One Case per unique critical message, keyed by `Case.Identidad_Senal__c`; consolidating per asset is extra scope | D010, D033 |
| Platform Event | 12 fields, no `Source` (03-arquitectura, 03-diagrama) | `Senial_Sensor__e`, 17 text fields including `Source__c`, `Delivery_Id__c` and the connectivity fields | [contrato-mensaje.md](../docs/contrato-mensaje.md) |
| Simulator call | `GET /api/v1/telemetry?limit=200&cursor=…` | `POST /session`, then `GET /telemetry` with the cursor in the `X-Simulator-Cursor` header | [contrato-mensaje.md](../docs/contrato-mensaje.md), D025 |
| Who publishes the event | A synchronous callout class that loops over every page (03-arquitectura) | `TelemetriaIngesta`, a chain of Queueables, started by a person; a `Publicada` log row is written before each publish | D013, D023, D031 |
| Buildings and assets | Upserted from each signal (03-arquitectura) | Loaded from the simulator catalog by `CatalogoService`; a signal for an unknown asset is `Rechazada` | D005, D032 |
| Subscriber user | Automated Process (03-arquitectura) | The integration user, via `PlatformEventSubscriberConfig`, batch 200 | D017 |
| Severity levels | 1/2/3 (04) | 0 Normal, 1 Advertencia, 2 Crítica, rolled up to `Asset` | D020 |
| Loss of communication | `Asset.StatusReason` (04) | `CONNECTIVITY` messages measured as `CAMERA_CONNECTIVITY` | [evidencia-escenarios.md](../docs/evidencia-escenarios.md) (`CAMERA_OUTAGE`) |
| Log result values | Procesada, Duplicada, Atrasada, Invalida, Publicacion rechazada (03-arquitectura) | Publicada, Procesada, Rechazada, Atrasada, Superada, Conflicto, Fallida (Duplicada is reserved) | D011, D013, D014 |
| Operator screen | Two filters, "Crear intervención" always refuses (02) | Adds an asset-type filter, a building summary, a per-asset signal history and actions behind custom permissions (manual intervention, follow-up, bulk close, "Traer señales") | D008, D012, D020, D024, D028, D030, D033–D037 |
| Operator visibility | Account sharing rules (03-arquitectura) | OWD Private, one owner operator per building, role hierarchy for coordinator and manager | D022, [acceso.md](../docs/acceso.md) |
| Apex and LWC names | `TelemetriaCalloutService`, `Umbrales`, `ActivosOperadorController.misActivos`, `listaActivosOperador` (03-arquitectura) | `SimuladorClient`, `TelemetriaIngesta`, `SenialSensorHandler`, `IntervencionService`, `ActivosOperadorController`, `novaCasaActivosOperador` and the other `novaCasa*` components | — |
