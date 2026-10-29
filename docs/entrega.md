# Delivery: status, evidence and demo

Everything needed to close the sprint, in one place: where each story stands, the team decisions behind each card, the message contract, the scenario runs, how to repeat the evidence in the org, and the demo script. The older files it replaces (`entendimiento.md`, `preguntas-facilitador.md`, `contrato-mensaje.md`, `simulador.md`, `evidencia-escenarios.md`, `checklist-evidencia.md`, `demo.md`) are in git history.

The MDSS brief (`Sprint 2 - Nova Casa.md`) is the source of truth. The reason behind each rule is in [decisiones.md](decisiones.md) (the D-numbers below). Who sees and does what is in [acceso.md](acceso.md).

**The repo is public.** No screenshots, record Ids, org usernames or org data in this file. Screenshots and query results go as comments on the story's MDSS card; this file only takes summaries (counts, pass or fail, date).

## Status by story

Status as of 2026-10-28. The code on `main` 1f2ec7b is what runs in `nova-cdo` (drift check of 2026-10-28); the closing PR only changes comments, and two bundle descriptions, in Apex and LWC files, and those reach the org with the next deploy from `main`. Every story is done except the manager dashboard (HP-07, D060), which is deployed from its branch and waiting for review: the decisions that rested on the facilitator's confirmation were approved by John as the person responsible on 2026-10-28 (see [Team decisions behind each story](#team-decisions-behind-each-story)).

| Story | Status | Evidence | Left |
|---|---|---|---|
| US-201 | Done | `TelemetriaIngestaTest`, `SimuladorClientTest`, `SenialSensorHandlerTest.publicarElEventoPersisteATravesDelTrigger`; 2026-10-27 `QA_200` run: 200 received, 200 published, all processed in 7 s, none left `Publicada`; key `nova-casa-simulator|msg_000007` traced from publication to its Case in 6 s; list view Todas las señales | A trace from a scheduled run (D040): the scheduler stays off for the demo |
| US-202 | Done | `SenialSensorHandlerTest` (`unLoteMixtoDe200SenialesSeparaValidasEInvalidasConUnNumeroFijoDeConsultasYDml`, `doscientosEventosEnUnLoteUsanUnNumeroFijoDeConsultasYDml`, `unaExcepcionEnUnEventoNoTumbaElLote`); 2026-10-27 runs: 4 (`QA_200`) and 17 (`DUPLICATES`) rejected with a D032 reason while the rest were processed; list view Rechazadas | — |
| US-203 | Done | `SenialSensorHandlerTest` (`unaSenialMasAntiguaQueLaVigenteQuedaAtrasadaAunqueSeaCritica`, `elDesempateD003NoDependeDelOrdenDeLlegada`, `tiposDeMedicionDistintosDelMismoActivoNoSeSobrescriben`, the batch-order tests of D011 h); 2026-10-27 `QA_200`: 169 `Atrasada`, none newer than its current reading, none with a Case; list view Atrasadas | — |
| US-204 | Done | `SenialSensorHandlerTest.editarElLimiteDeUnUmbralCambiaLaClasificacionSinTocarElHistorico`, the boundary tests (D019), `UmbralValidadorTest`, `CatalogoServiceTest` (seed from the static resource, D054); 2026-10-27 `BOUNDARIES` twice: the coordinator lowered TECHNICAL_ROOM TEMPERATURE Crítica from GT 35 to GT 34 in the UI and the same 35 °C signal went from Advertencia to Crítica with its intervention; limit restored; every current reading on an exact limit followed D019 | — |
| US-205 | Done | `IntervencionServiceTest` (incl. the `DUPLICATE_VALUE` race), `SenialSensorHandlerTest` (`unReenvioIgualSoloSumaReenviosSinTocarLecturaNiCase`, `siFallaElCaseLaIdentidadQuedaFallidaSinLecturaYLasDemasSeProcesan`); 2026-10-27 `DUPLICATES`: 1000 deliveries, 717 identities, 207 rows resent with their result unchanged, 27 `Conflicto` without a Case, 5 Cases for the 5 assets with a processed critical, never two open on one asset; list views Intervenciones abiertas, Duplicadas (reenvíos), Conflictos | — |
| US-206 | Done | `SenialSensorHandlerTest` (`tresValoresRepresentativosDeTemperaturaSonNormalAdvertenciaYCritica`, `unaAdvertenciaEscribeLecturaNivel1SinCaseYElActivoQuedaEnNivel1`, `elActivoMuestraLaMaximaSeveridadEntreAdvertenciaYCritica`); 2026-10-27 `QA_200`: 3 critical, 2 warning (no Case) and 5 normal current readings, told apart on screen by symbol and text | — |
| US-207 | Done | `ActivosOperadorControllerTest`, `IntervencionOperadorControllerTest`, Jest 29 of 29 (4 suites); [walkthrough of 2026-10-27](#walkthrough-of-2026-10-27): filters, age, states, navigation and actions per persona; the custom design without base components accepted by John (D012) | «Cerrar todas» in the panel hasn't been tried by hand (D059) |
| US-208 | Done | [acceso.md](acceso.md); `ActivosOperadorControllerTest`, `IntervencionOperadorControllerTest` (incl. the building reassignment of D053), `SeguridadTest`, `AccesoFueraDeJerarquiaTest`, `PermisosProcesamientoTest`; security review of 2026-10-26 with no High finding, its two Medium ones fixed in D053; walkthrough of 2026-10-27 with five personas | — |
| US-209 | Done | `LogAccionReintentoTest` (incl. D055), `SeguridadTest`; 2026-10-27 walkthrough as admin: normal, rejected, resent, late and conflicting rows found by identity with result, reason, retry action and Case; every stored reason scanned, nothing secret-shaped; the history gives values only for accepted readings (D056) | — |
| HP-01 | Done | `CAMERA_OUTAGE`: loss of communication arrives as normal `CONNECTIVITY` messages | — |
| HP-05 | Done in tests | `TelemetriaIngestaTest`; the 2026-10-27 runs used one job each (up to 18 s for 1000 messages) | No retry or reopened session has been seen live (D023); chain depth beyond 27 is unvalidated (D013) |
| HP-07 (manager dashboard) | Deployed from its branch, in review | D060: "Nova Casa: Gerencia regional", 5 components on 5 reports, each answering a question in plain Spanish (how each building's assets are, state of all assets, open interventions, the 10 oldest, which building had the most interventions in the last 30 days); static, running as the manager persona, refreshed daily at 6:00 Bogotá time by a subscription. 2026-10-28: full Apex suite 462 of 462 and `SeguridadTest` again after the last changes, every component returned data running as the manager, and "Iniciar sesión como" showed the manager the dashboard with no export option and the operator and coordinator no Reports or Dashboards tabs | Juan Diego's review, push and PR (John reviews), deploy from `main` with `NOVA_CASA_GERENTE_USERNAME` set (`CONTRIBUTING.md`). Charts use the default palette: Lightning has no fixed color per state, so Crítica isn't red (D060) |

**Review of 2026-10-27.** The body of PR #117 records that the facilitator's review of that day left four criteria Partial: US-204.AC1 (the seed limits were written in Apex), US-208.AC2 (after a building changed operator, the previous operator kept their manual Case, and `getIntervencion` returned a hidden asset's Id and last critical reading), US-209.AC4 (the retry action said to fix the data at the source for a rejection caused by configuration) and BR-210 (no test for the `DUPLICATE_VALUE` race). PR #117, merged and deployed on 2026-10-28, changes the code for each one (D054, D053, D055 and a test); D053 traces the US-208.AC2 gap to the team's own security review of 2026-10-26 as well. The table above lists the evidence for each criterion.

**Tests.** Last full run on 2026-10-28, on `main` (1f2ec7b): 460 of 460 passing, 90 % org coverage, no class of ours below 87 % (the lowest are `CatalogoService` and `SesionSimulador`). Jest: 29 of 29 in 4 suites. `scripts/org-check.sh tests` runs the Apex suite again. A deploy proves none of this: in `nova-cdo` it reports `Running Tests - Skipped` (`CONTRIBUTING.md`).

## Team decisions behind each story

The brief leaves some readings open. The team closed each one as a decision on 2026-10-27 ([decisiones.md](decisiones.md)). On 2026-10-28 John, as the person responsible, approved those that had rested on the facilitator's confirmation (each Status line says so); the ones the delivery relies on are listed in "Confirmaciones del facilitador" at the end of that file. Two answers changed something: the low temperature warning is LT 18 (D054), and the history gives values only for accepted readings (D056). If a reading changes, the last column says what has to change.

| Card | Decision | What the team decided | If the reading changes |
|---|---|---|---|
| US-201 | D031, D023, D040 | Ingestion that our Apex publishes (every 5 minutes when the scheduled job is on, D040; it has been off since 2026-10-21 and the demo starts reception by hand; or by hand with "Traer señales") meets "Platform Events reales": the simulator can only be read (`GET /telemetry`), so our Apex publishes one `Senial_Sensor__e` per message and the subscriber processes them in batches of up to 200 | The simulator would have to push events itself, which its contract doesn't offer (D031, alternative dropped); our subscriber already processes any published event |
| US-202 | D032 | Our 7 rules are the definition of "invalid" (a signal is `Rechazada` with a reason and the rest of the batch carries on); a signal with no `source` or `messageId` is rejected before publishing, under a key derived from a hash | Adjust the handler rules and `SenialSensorHandlerTest` |
| US-205, US-203 | D039, D011 (h) | D039, confirmed verbally on 10-16 and 10-17: one open telemetry Case per asset; later critical signals link to it and update its last critical reading; a resend, a conflict or a signal older than the current reading doesn't touch it. D011 (h): a critical reading older than another of the same batch, or than the current reading, stays as evidence only; this departs from the letter of the agreement, and D011 (h) explains why and the tests pin it | Change the handler and repeat the scenario runs |
| US-204, US-206 | D004, D006, D019 | `Umbral__c` is the administrative mechanism (editable by coordinator and admin without deploying); the seeded operators and values are the team's reference table; at the exact limit `GT` and `LT` don't meet and `GE` and `LE` do | Other operators or values are a data change in `Umbral__c`, no code; replacing the object means a migration |
| US-208 | D005, D022, D020, D021, D024 | `Account` and `Case` Private, `Asset` Controlled by Parent, one operator per building, coordinator and manager through the role hierarchy; three system-mode operations (manual `Case` insert, open-intervention check, history read), each after checking in user mode that the person sees the asset (D043, D045, D053 and D056 later added reads and a user lookup of the same kind); ingestion doesn't depend on operator permissions | The OWD change is hard to revert: its own PR, agreed by both, deployed only from `main` |
| US-209 | D024, D034, D047 | `getHistorial` gives operator, coordinator and manager the type, date and result of every signal, and the measurement, value and unit only of accepted readings (D056), for the assets they already see, never the reason, fingerprint or identity; a conflict on an already processed identity keeps the original row's result and adds to `Conflictos__c` | Remove fields from the history, or add a separate conflict flag |
| US-205, US-207 | D059, D035, D039 | The panel keeps «Cerrar todas»: since D039 it only shows when an asset has more than one open intervention (Cases accumulated before D039, a manual Case plus a telemetry Case, or a Case reopened from Details). It hasn't been tried by hand in the panel | Removing it is its own story: it breaks `cerrarIntervencionesDelActivo`, 10 tests and what D035, D046 and D052 say |

Closed since Discovery: the intervention is `Case` (D001); a tie on `occurredAt` goes to the higher severity, then `messageId` (D003); buildings and assets are the standard `Account` and `Asset` (D005); MDSS didn't provision personas or permission sets, so we built them (D022). Of the Discovery assumptions, the 200-signal batch matches the subscriber's batch size (D017), and the simulator needed more than the contract shows (session, cursor header, exact auth parameter name; see [Message contract](#message-contract)).

## Message contract

MDSS deliverable 5. The documented contract is the "Contrato" section of `Sprint 2 - Nova Casa.md`; this section records what the simulator really sends and how each field lands in Salesforce. Real responses captured on 2026-09-30 are in [`muestras/`](muestras/) (`telemetry.json`, one page of 200 messages, and `catalog.json`).

### Connection

- **Named Credential and External Credential** `Nova_Casa_Simulator` (D002), base path `/api/sprint-2/simulator/v1`. The External Credential's authentication parameter must be named exactly `BearerToken` (case-sensitive) to match `$Credential.Nova_Casa_Simulator.BearerToken` in the Authorization header formula. The token lives only in Setup.
- **Session:** `POST /session` returns a `cursor`. The body can carry `scenario`, `seed` and `batchSize`; the simulator decides whether to honor the last two.
- **Paging:** every `GET /telemetry?limit=N` (1 to 200) sends the cursor in the `X-Simulator-Cursor` header; `pagination.nextCursor` is the next one. `pagination.pollAfterMs` is read but not waited for: one job requests pages back to back and relies on the 429 retry (D025). The stream ends on `hasMore = false`.
- **Catalog:** `GET /catalog` needs only the Bearer token, no cursor.
- **The cursor is a secret**, like the token: never stored in a record, a setting or a log (D013, D025). Retries on 429/5xx and the new session on 409/410 are in D023.

None of this is in the MDSS example, which shows a single `GET /api/v1/telemetry?limit=200`.

### How the real message differs from the MDSS example

| MDSS example | Real message | What we do |
|---|---|---|
| `building.externalId`, `asset.externalId` | `building.id`, `asset.id` | `TelemetriaIngesta` reads `id` and falls back to `externalId` |
| — | `deliveryId` (changes on every resend of the same `messageId`) | Kept on the event and the log; left out of the content fingerprint |
| — | `messageType`: `MEASUREMENT` or `CONNECTIVITY` | `CONNECTIVITY` has no `measurement`; it carries `communication` |
| — | `communication`: `status`, `gapSeconds`, `lastSeenAt`, `episodeId` | `gapSeconds` is compared with the `CAMERA_CONNECTIVITY` thresholds |
| — | `publishedAt` | When the simulator published it; not `occurredAt` |
| `PRESSURE`, `CELSIUS`, `AST-BOG-002`, `MSG-000101` | `WATER_PRESSURE`, `KWH_PER_15_MIN`, `LITER_PER_15_MIN`…, `AST-BOG-PUMP-001`, `msg_000001` | Thresholds (`Umbral__c`) use the real names |

### Fields: from the simulator to `Senial_Sensor__e`

`TelemetriaIngesta` turns each message into one `Senial_Sensor__e` (High Volume, Publish After Commit). All fields are Text: values arrive raw, so the subscriber can reject a bad one with a reason instead of failing the publish. Names and city come from the catalog, not the event.

| Event field | From | Note |
|---|---|---|
| `Source__c`, `Message_Id__c` | `source`, `messageId` | Together, the identity |
| `Delivery_Id__c` | `deliveryId` | |
| `Message_Type__c` | `messageType` | `MEASUREMENT` or `CONNECTIVITY` |
| `Building_Id__c` | `building.id` | Must be the asset's building in the catalog (D032) |
| `Asset_Id__c`, `Asset_Type__c` | `asset.id`, `asset.type` | Matched with `Asset.External_Id__c` |
| `Sensor_Id__c` | `sensorId` | |
| `Measurement_Type__c`, `Value__c`, `Unit__c` | `measurement.type`, `.value`, `.unit` | Empty on `CONNECTIVITY`; a null or non-numeric value is rejected with a reason |
| `Occurred_At__c`, `Published_At__c` | `occurredAt`, `publishedAt` | ISO 8601 |
| `Comm_Status__c`, `Gap_Seconds__c`, `Last_Seen_At__c`, `Episode_Id__c` | `communication.*` | `CONNECTIVITY` only; `Episode_Id__c` groups the messages of one outage |

### Identity, dates and units

- **Identity** is `source|messageId`: the unique key of `Log_Senial__c.Identidad__c` (Text 60, written with upsert) and of `Case.Identidad_Senal__c` (D010, D011). A resend is the same identity with the same content fingerprint (`Huella__c`, SHA-256 of the content without `deliveryId` and `publishedAt`) and only adds to `Reenvios__c`; the same identity with different content is `Conflicto`. A message with no identity, or one longer than 60 characters, is never published (D013, D032).
- **Dates:** `occurredAt` (on the event, the log and the reading) is when the sensor took the reading and the only date that orders signals (BR-203; ties in D003). `publishedAt` is when the simulator published it. `generatedAt` isn't kept. `Log_Senial__c.Publicado_At__c` is when our ingestion wrote the `Publicada` row, just before publishing (D013), and `Procesado_At__c` when the subscriber handled it: publishing isn't processing.
- **Units:** each `Umbral__c` names the unit it expects (`Unidad_Esperada__c`); a reading in another unit is `Rechazada` (D032 rule 5). There's no conversion.

### Examples

Valid: `msg_000002` in `muestras/telemetry.json`, a `WATER_PUMP` reading `WATER_PRESSURE` in `BAR`; `msg_000004`, a `CONNECTIVITY` message from a `SECURITY_CAMERA`. Invalid, in the same sample: `msg_000051` (asset `AST-UNKNOWN-0001` isn't in the catalog), `msg_000057` (`ENERGY_CONSUMPTION` in `WATT`, not `KWH_PER_15_MIN`), `msg_000096` (`measurement.value` is null).

## Scenario runs

### Runs of 2026-10-27

Four runs by John's session with `scripts/org-check.sh run <SCENARIO> 5 42 200`, each on a cleaned org with a fresh simulator session, after D039, D047 and D049. All passed the gates: one `TelemetriaIngesta` job `Completed` with 0 errors, no row left `Publicada`.

| # | Scenario | Received | Log rows | Readings | Cases | Breakdown | Processing |
|---|---|---|---|---|---|---|---|
| A | `QA_200` | 200 | 189 | 10 (3 crit, 2 warn, 5 normal) | 4 | 16 Procesada, 169 Atrasada, 4 Rechazada; 10 resends, 1 conflict counted | 7 s |
| B | `DUPLICATES` | 1000 | 717 | 9 | 5 | 51 Procesada, 622 Atrasada, 27 Conflicto, 17 Rechazada; 207 rows resent | 24 s |
| C1 | `BOUNDARIES` (Crítica GT 35) | 1000 | 1000 | 9, all on an exact limit | 1 | 53 Procesada, 947 Atrasada | — |
| C2 | `BOUNDARIES` (Crítica GT 34) | 1000 | 1000 | 9 | 3 | 53 Procesada, 947 Atrasada; the 35 °C reading now Crítica with its Case | — |

The org was cleaned after the last run and left demo-ready; the threshold changed for C2 was restored and all 21 matched the previous day.

### Runs of 2026-10-14 (before D039 and D047)

Nine runs on 2026-10-14 by Juan Diego with `scripts/org-check.sh`, in this order, each on a cleaned org, seed 42. Counts are SOQL on `Log_Senial__c.Resultado__c`, `Lectura_Vigente__c` and `Case`. All nine passed the gates: one `TelemetriaIngesta` job `Completed` with 0 errors, no row left `Publicada`, no log or publish failure. **They predate D039**, so the Case counts follow the old rule of one Case per unique critical message.

| # | Scenario | Pages × batch | Log rows | Readings | Cases | Breakdown | Job |
|---|---|---|---|---|---|---|---|
| 1 | `QA_200` | 10 × 200 (stream ended after 1) | 189 | 10 | 4 | 16 Procesada, 168 Atrasada, 4 Rechazada, 1 Conflicto | 13 s |
| 2 | `DUPLICATES` | 10 × 200 | 1437 | 9 | 19 | 83 Procesada, 1270 Atrasada, 50 Conflicto, 34 Rechazada | 57 s |
| 3 | `BOUNDARIES` | 10 × 200 | 2000 | 9 | 2 | 97 Procesada, 1903 Atrasada | 10 s |
| 4 | `LATE_MESSAGES` | 10 × 200 | 1929 | 9 | 12 | 91 Procesada, 1709 Atrasada, 71 Rechazada, 57 Conflicto, 1 Superada | 37 s |
| 5 | `INVALID_DATA` | 10 × 200 | 1861 | 6 | 2 | 1203 Rechazada, 563 Atrasada, 63 Procesada, 32 Conflicto | 48 s |
| 6 | `CONFLICT` | 10 × 200 | 1434 | 9 | 27 | 865 Atrasada, 405 Conflicto, 84 Rechazada, 80 Procesada | 46 s |
| 7 | `CAMERA_OUTAGE` | 3 × 200 | 600 | 2 | 6 | 592 Atrasada, 8 Procesada | 15 s |
| 8 | `BOUNDARIES` | 10 × 50 | 500 | 9 | 1 | 465 Atrasada, 35 Procesada | 4 s |
| 9 | `CRITICAL_BURST` | 10 × 200 | 1926 | 9 | 58 | 1802 Atrasada, 85 Procesada, 21 Rechazada, 18 Conflicto | 72 s |

What they show:

- **Publishing isn't processing (US-201).** In run 1, `nova-casa-simulator|msg_000007` was published at 15:35:40Z and processed 5 s later, and opened a Case. Processing took 3 to 65 s from publish depending on volume.
- **The simulator's clock.** In most scenarios its timeline advances one minute per message from the start of the session, so `Occurred_At__c` is in the future when the message is published, by more the later it comes (`msg_000419` is about 7 hours ahead). `LATE_MESSAGES` stamps some messages in the past instead (`msg_000022`, 15 minutes). That's why the screen shows "hora del simulador" for a future time (D033, D037).
- **One bad signal doesn't stop the batch (US-202).** `INVALID_DATA` left 1203 rows `Rechazada` next to 63 `Procesada` that wrote 6 readings. The listed reasons cover rules 1, 4, 5 and 7 of D032; rules 2, 3 and 6 are covered by tests only. The ingestion itself rejected nothing in any run.
- **Late signals (US-203).** Most rows end up `Atrasada` because only the newest per asset and measurement in a batch wins (D011 h). `LATE_MESSAGES` had 6 rows `Atrasada` against a reading stored by an earlier batch, which is the agreement's case, and the first live `Superada` (the D003 tie).
- **Repeats open nothing (US-205).** Every Case is tied to a `Procesada` row; no `Conflicto` row or resend opened one. `CONFLICT` produced 405 `Conflicto` rows and no Case from them. `CRITICAL_BURST` opened 58 Cases for 5 critical readings, which D039 now prevents.
- **Cameras (HP-01).** Loss of communication arrives as normal `CONNECTIVITY` messages for `SECURITY_CAMERA` assets, measured as `CAMERA_CONNECTIVITY` in `SECONDS` (Advertencia GT 90, Crítica GT 180). Seen first on 2026-10-06 (T1.7). `CAMERA_OUTAGE` isn't in the brief, only in the simulator's scenario list.
- **Batch size.** Run 8 read 500 messages in 10 pages of 50 and the same stream as run 3. The page `limit` is the reliable bound; this doesn't show whether the simulator honors `batchSize` in `POST /session` (D023).

Caveats:

- **Volume isn't reproducible.** The same scenario returns different message counts across runs (`DUPLICATES` gave 766, 564 and 276 in earlier runs and 1437 here). Each row describes that run, not what a future run will give. The earlier runs of 2026-10-05 and 10-06 are in git history.
- **Batch dependence.** Counts depend on how the stream is split into batches (D011 h). If the reading of D011 (h) changes, every run has to be repeated.
- **The clean.** On 10-14 the script's clean failed on the Apex CPU limit when it deleted logs, Cases and readings in one execution; deleting each kind on its own always worked. The script now deletes one kind per execution, logs first; that version ran five times on 2026-10-27, each in one pass.
- The simulator reuses `messageId` across sessions: on a dirty org everything comes out `Conflicto` or as a resend.

### Manual walkthrough of 2026-10-13

Juan Diego, with "Iniciar sesión como", on the data that existed then. No screenshots were kept.

| Persona | What they saw |
|---|---|
| Operator 1 | Only Nova Alameda (5 assets), read-only; the Cases of their building, even those created by the ingestion. No Registros de Señal or Umbrales |
| Operator 2 | Only Nova Caribe (5 assets) and its open Cases; couldn't find Nova Alameda. No Registros de Señal or Umbrales |
| Coordinator | Both buildings and their open Cases; edited a threshold and put it back. No Registros de Señal |
| Manager | Both buildings, read-only; not the test building, not Umbrales; can open Reports. No Registros de Señal |

Findings: each persona's first session lands on the "Servicio" app with "No tiene acceso a este registro" (opening Nova Casa Telemetry once fixes it, so the demo prep includes it). A custom profile, an app icon and manager reports were proposed and not done. Two manual interventions in Nova Alameda aren't removed by the clean (it only deletes `Origin = 'Telemetria'`): close them by hand before the demo.

### Walkthrough of 2026-10-27

John, with "Iniciar sesión como", on the `QA_200` data of block A, following the checklists below (US-207, US-208 and US-209 checks). Every check passed:

| Persona | What they saw |
|---|---|
| Operator 1 | Only Nova Alameda; loading, data and empty states; filters by building and severity; age and "hora del simulador"; "Ver activo" and "Caso N"; "Crear intervención" but no follow-up or thresholds; no Registros de Señal; Nova Caribe not found |
| Operator 2 | Only Nova Caribe; critical, warning and normal told apart without relying on color |
| Coordinator | Both buildings and Intervenciones abiertas; a status change without a comment is rejected, with one it saves; a contradictory limit is rejected on save; no Registros de Señal; the accounts outside the hierarchy not found |
| Manager | Both buildings, read-only, no action buttons; no Registros de Señal or Umbrales |
| Admin | Registros de Señal and its list views; a signal found by identity with its three times; result, reason, retry action and Case on processed, rejected, late, resent and conflicting rows; no secret anywhere |

## Repeating the evidence

Done on 2026-10-27: blocks A, B and C and the checks per persona (results in [Scenario runs](#scenario-runs) and the walkthrough above). This section stays as the procedure to repeat them. Each check says what passes.

**Before starting**

1. Say in Slack who runs and when. One person at a time; runs create real records.
2. Turn off the scheduled ingestion (D040) so it doesn't bring `MIXED` in the middle: `sf apex run --file scripts/apex/desprogramar-ingesta.apex -o nova-cdo`. Turn it back on at the end with `programar-ingesta.apex`.
3. Clean the org before each block: `scripts/org-check.sh clean` shows what it would delete, `clean confirm=<org>:<n>` deletes it. Deleting data is agreed by both of us.
4. Run the tests of the day: `scripts/org-check.sh tests`, and note `Tests Ran`, `Pass Rate` and the coverage.

**Each run:** `scripts/org-check.sh run <SCENARIO> 5 42 200` (scenario, pages, seed, batch). It prints the `<since>` for `wait <since>` and `evidence <SCENARIO> <since>`. Note what came out, not what was expected.

| Block | Scenario | Stories |
|---|---|---|
| A | `QA_200` | US-201, US-202, US-203, US-206, US-207, US-208, US-209 |
| B | `DUPLICATES` | US-205, US-209 (resend and conflict) |
| C | `BOUNDARIES`, twice | US-204 |

### Block A — `QA_200`

- **US-201.** `sf data query -o nova-cdo -q "SELECT Identidad__c, Occurred_At__c, Publicado_At__c, Procesado_At__c, Resultado__c FROM Log_Senial__c WHERE Resultado__c = 'Procesada' ORDER BY Occurred_At__c DESC LIMIT 5"`. Passes if `Publicado_At__c` is before `Procesado_At__c`. Save the row and a screenshot of Todas las señales on the card.
- **US-202.** `evidence` gives the counts. Passes if there are `Rechazada` rows, no valid signal was rejected and nothing stayed `Publicada`. Reasons: `sf data query -o nova-cdo -q "SELECT Motivo__c, COUNT(Id) FROM Log_Senial__c WHERE Resultado__c = 'Rechazada' GROUP BY Motivo__c"`; each one names a D032 rule.
- **US-203.** Take an `Atrasada` row and compare it with the current reading of its key (`SELECT Clave__c, Occurred_At__c FROM Lectura_Vigente__c`): passes if the current one is the same age or newer. `SELECT COUNT(Id) FROM Log_Senial__c WHERE Resultado__c = 'Atrasada' AND Caso__c != null` must be 0. Temperature not overwriting pressure is proven by `tiposDeMedicionDistintosDelMismoActivoNoSeSobrescriben`; `QA_200` can't show it.
- **US-206.** As the operator, capture an asset in warning, one critical and one stable. Passes if they're told apart without relying on color (glyph and text) and only the critical one has an open intervention. If no asset comes out in warning, say so; don't invent it.

#### US-207 checks

As the operator, with date and pass or fail for each:

1. Filtering by building: the counts and the banner only count the visible assets.
2. An asset with no level shows "Sin dato", never stable.
3. A critical asset with no visible Case doesn't promise one.
4. "Caso N" opens the `Case`; going back with the breadcrumb keeps the filters.
5. With a truncated list, the banner is qualified ("Al menos N" or "Ningún crítico verificado").
6. Tab to "Ver activo" and Enter opens the detail once.
7. Later decisions: the history summary and filter (D033); the Medición and Valor columns (D034); "Cerrar las N abiertas" closes only that asset's Cases (D035, coordinator); the status list matches the `Case` page (D036); "Antigüedad" and "hora del simulador" (D037); "Última intervención: Caso N" with "Abrir nueva intervención" (D038); grid cards, the "Salud de la flota" donut, the building table and the "Traer señales" panel (D041); the color band by state, the 3-pulse critical, "Subió a crítico" and the 60 s refresh (D042); once PR #97 is merged and deployed, a `Conflicto` row tagged "valor original" (D034).

Save screenshots of the list, the detail and the loading, empty and error states, with several severities.

#### US-208 checks

Log in as each persona from [acceso.md](acceso.md) ("Personas"). Operator 1 sees only BLD-BOG-001, operator 2 only BLD-BAQ-001, the coordinator both and can change statuses, the manager both with no action buttons. Hiding a button doesn't prove the server refuses, so also cite the tests with their result (`ActivosOperadorControllerTest.operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth`, `IntervencionOperadorControllerTest`, `SeguridadTest`, `PermisosProcesamientoTest`, `SenialSensorHandlerTest.laIngestaPersisteConUnUsuarioSinPermisosDeOperador`) and run the `UserRecordAccess` query of `acceso.md` ("How to verify (T8.6)"). Passes if it matches "Hierarchy instead of View All (D022)".

#### US-209 checks

As the admin, in Registros de Señal:

1. **No secrets, before capturing anything:** read every distinct reason (`SELECT Motivo__c, COUNT(Id) FROM Log_Senial__c WHERE Motivo__c != null GROUP BY Motivo__c`). If one carries a token, a cursor or personal data, don't paste it anywhere and raise it.
2. Capture a `Procesada`, a `Rechazada` and an `Atrasada` row with identity, result, reason and retry action.
3. As operator, coordinator and manager: the tab doesn't show up and `/lightning/o/Log_Senial__c/list` shows them no rows. The per-asset history on the operator screen is a different thing (D024).
4. If the tab doesn't show up even for the admin, say so before deploying anything: it's been on `main` since PR #62, and the 10-09 retrieve of `Nova_Casa_Admin` matched `main`.

### Block B — `DUPLICATES`

With D039 an asset has one open telemetry Case; later critical signals link to it (`Caso__c`) and update its `Ultima_Critica_*` fields. Note the run's start time (UTC) and use it as `<inicio>`:

- Passes if both return no rows: `SELECT AssetId, COUNT(Id) FROM Case WHERE Origin = 'Telemetria' AND IsClosed = false AND CreatedDate >= <inicio> GROUP BY AssetId HAVING COUNT(Id) > 1` and `SELECT Identidad_Senal__c, COUNT(Id) FROM Case WHERE Origin = 'Telemetria' GROUP BY Identidad_Senal__c HAVING COUNT(Id) > 1`.
- Resends (Duplicadas (reenvíos)): `Resultado__c` didn't change and the row keeps a single `Caso__c`.
- Conflicts: a `Conflicto` row keeps the original's `Caso__c`, so that column proves nothing. Passes if the count of telemetry Cases is the same right after `wait` and once the conflicts have arrived.
- Passes if the number of Cases created in the run equals the number of assets with at least one critical `Procesada` row (if those assets had no open Case before). The two queries above also pass when no Case opened at all, so this one is the positive check.
- Save a Case whose "Última señal crítica" matches the newest critical of its asset, the Intervenciones abiertas list and, for US-209, a resent row and a `Conflicto` row with their retry action.

### Block C — `BOUNDARIES` twice

1. Run it and note the severity of a reading whose value is between the warning and critical limits.
2. As the coordinator, in Umbrales, lower that measurement's critical limit below the value. Nothing is deployed.
3. `clean`, then the same run with the same seed.
4. Passes if the same reading (same `Identidad__c`) now comes out critical and opens its intervention. If the simulator doesn't repeat the stream, compare another value of the same measurement and say so.
5. **Put the limit back** and confirm it: the thresholds are shared. Save value, old and new limit, and severity before and after, with no Ids.

**At the end:** `clean`, turn the scheduled ingestion back on, tell Slack, paste the evidence on each card and move it (QA → Ready, `CONTRIBUTING.md`). A story with an open question stays in QA. A failed check isn't fixed here: note it and open a branch for the story.

## Demo script

It follows the brief's "Historia de referencia" (`Sprint 2 - Nova Casa.md`): Laura, an operator, starts her shift and sees which equipment needs attention; the critical signal opens a single intervention, the resend doesn't open another and the old reading doesn't replace the current one. Operator 1 plays Laura (in our org she has one building, not two). The role-by-role part after that is ours, not the brief's. About 15 minutes.

**Before the demo (not timed)**

1. Say in Slack who runs the ingestion and when. Juan Diego or John runs it with his own user: both have `Nova_Casa_Admin` and `Nova_Casa_Simulator_Integration`. The admin persona doesn't have the second one, so "Traer señales" fails with that user.
2. Turn off the scheduled ingestion (`desprogramar-ingesta.apex`) and turn it back on afterwards, only if the team wants it on (it is off on 2026-10-28).
3. Clean org: `scripts/org-check.sh clean` shows what it would delete, and `clean confirm=<org>:<n>` deletes it, once John and Juan Diego agree. It only deletes telemetry Cases: close the manual interventions by hand if they shouldn't show. On 2026-10-28 the org is clean: 0 log rows, readings and telemetry Cases, no open Case, every asset "Sin lecturas".
4. Catalog loaded (`CatalogoService.loadCatalog();`, README) and the "Building owners" query of `acceso.md` returns nothing: BLD-BOG-001 (Edificio Nova Alameda) belongs to operator 1 and BLD-BAQ-001 (Edificio Nova Caribe) to operator 2.
5. Persona users active. Log in as each one once and open the Nova Casa Telemetry app, or their first session lands on "Servicio".
6. Tests run the same day (`scripts/org-check.sh tests`); keep the result for step 9.
7. Tabs open: Setup > Users, Setup > Apex Jobs, Developer Console and the Nova Casa Telemetry app.

| # | Min | Who | What it shows | BR |
|---|---|---|---|---|
| 1 | 1 | Presenter | The problem and the reference story | — |
| 2 | 2 | Juan Diego (admin) | Real reception and processing | BR-201, BR-202 |
| 3 | 3 | Laura (operator 1) | Operator screen, severity, filters, states | BR-206, BR-207, BR-208 |
| 4 | 1.5 | Juan Diego + Laura | A single intervention; the resend doesn't open another | BR-205 |
| 5 | 1 | Juan Diego | The late signal doesn't replace the current one | BR-203 |
| 6 | 1.5 | Coordinator | Open interventions, follow-up and thresholds | BR-204, BR-205 |
| 7 | 2.5 | Manager and operator 2 | Each one sees only what they're authorized to see; the manager compares buildings in their dashboard | BR-208 |
| 8 | 1.5 | Juan Diego | Why a signal was rejected and whether to retry it | BR-209 |
| 9 | 1 | Presenter | Automated tests | BR-210 |

1. **Context.** Each vendor has its own portal and the operator finds out late. Read the reference story aloud. The flow in one sentence: simulator → `Senial_Sensor__e` → `SenialSensorTrigger` as the integration user → `Lectura_Vigente__c`, `Log_Senial__c` and `Case` → "Activos del operador".
2. **The signals arrive.** In Execute Anonymous, as Juan Diego: `TelemetriaIngesta.iniciar('QA_200', 42, 200, 5, true);` (`true` opens a fresh simulator session; without it the run continues the saved one, D025). Apex Jobs shows one `TelemetriaIngesta` job `Completed`. In Registros de Señal > Todas las señales (`/lightning/o/Log_Senial__c/list?filterName=Todas_las_senales`): each row has its identity, `Occurred_At__c`, `Publicado_At__c` and `Procesado_At__c`; rows go from `Publicada` to `Procesada` by themselves; a few stay `Rechazada` with a reason and the rest carry on.
3. **Laura starts her shift.** Log in as operator 1 > Activos del operador. Only BLD-BOG-001 shows up. The banner and the building summary count assets in Crítica, Precaución and Sin dato; the asset takes the highest severity of its latest readings. Filter by severity, then by building; a combination with no results says "Ningún activo coincide con esos filtros" with "Limpiar filtros", which isn't the same as "Sin lecturas todavía". Cards show the reading's age and "(desactualizada)" past 15 minutes (D007). "Ver activo" shows the current reading per measurement type and, if critical, "Caso N". Laura can "Crear intervención" but has no "Actualizar seguimiento" or "Ver límites" (D020). If the pump isn't critical in this run, use whichever asset is (on 2026-10-27 it was the camera).
4. **One intervention, even if it arrives twice.** As Juan Diego, note the count in Cases > Intervenciones abiertas. Run exactly the same `iniciar` again, with `true`: a fresh session with the same seed sends the same messages. The count doesn't change; Duplicadas (reenvíos) shows rows with `Reenvios__c` > 0 and the same result and Case. If the simulator sends different content with the same key, the row keeps its result and counts the conflict (list view Conflictos, "Detalle del último conflicto", D047), also with no new Case. Back as Laura, "Actualizar": still a single "Caso N".
5. **An old reading isn't the current condition.** Open a row in Atrasadas and its asset: the row's `Occurred_At__c` is older than the current reading, its reason says so, the current reading didn't change and the row has no Case even if it's critical. Almost every row ends up `Atrasada` in a full run; that's D011 (h).
6. **The coordinator organizes the work.** Log in as the coordinator > Intervenciones abiertas: one open intervention per asset for both buildings (D039). On a critical asset, "Actualizar seguimiento" (On Hold, with a comment) > Guardar; Laura couldn't. On the Case page the status changes in Detalles and needs a comment too (D046); closing needs the follow-up permission (D052). "Ver límites": thresholds are `Umbral__c` records edited without deploying; a contradictory range is rejected on save (D018). Don't leave a threshold changed.
7. **Everyone sees their own data.** The manager sees BLD-BOG-001 and BLD-BAQ-001 read-only, with no action buttons, and a global search for an account outside the hierarchy (Acme, Global Media) finds nothing (D022). Then, as the manager, Paneles > Nova Casa: Gerencia regional (it's static and refreshes every day at 6:00; "Actualizar" brings it up to date after the run, D060). Read it top to bottom: "¿Cómo están los activos de cada edificio?" shows each building's assets by state (Crítica, Advertencia, Normal, Sin lecturas) and "Estado de todos los activos" the total; then the open interventions (including those whose asset is back to Normal) next to the 10 oldest, with their building and asset type; and at the end which building had the most interventions in the last 30 days, automatic and manual. Under the title, "Visualización como" names the manager persona: it never runs as an administrator, and the report menu has no Export. Operator 2 sees only BLD-BAQ-001 and has no Informes or Paneles tab. The restriction is also on the server: the controller is `with sharing` and queries in `USER_MODE` (`ActivosOperadorControllerTest.operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth`), and `SeguridadTest.soloElGerenteEjecutaReportesYNadieLosExporta` fails if another persona gets Run Reports.
8. **The administrator investigates.** Rechazadas, Conflictos and Fallidas, then look up a signal by its identity in global search: each row shows the reading it brought (measurement, value, unit, D049), its result, Motivo and Acción de reintento (D014): a rejected row says to fix the data at the source, or the configuration when the threshold or the asset is missing (D055); a failed one says to retry; a processed one says there's nothing to do. Retrying means running the ingestion again; the identity prevents a duplicate Case. No token, cursor or secret in any row, and only the admin sees the log.
9. **Quality.** Show the test result from the preparation and name the tests that fail if what the audience saw breaks: `tresValoresRepresentativosDeTemperaturaSonNormalAdvertenciaYCritica`, `operadorGTUnValorIgualAlLimiteNoLoCumpleYElSiguienteSi`, `editarElLimiteDeUnUmbralCambiaLaClasificacionSinTocarElHistorico`, `unReenvioIgualSoloSumaReenviosSinTocarLecturaNiCase`, `mismaIdentidadConOtroContenidoEsConflictoSinCambiarEstado`, `IntervencionServiceTest` (one open Case per asset, D039, and the concurrent first Case), `IntervencionOperadorControllerTest.shouldFollowTheBuildingNotTheCreator_WhenTheBuildingChangesOperator` (D053), `doscientosEventosEnUnLoteUsanUnNumeroFijoDeConsultasYDml`, `unaSenialMasAntiguaQueLaVigenteQuedaAtrasadaAunqueSeaCritica`, `elDesempateD003NoDependeDelOrdenDeLlegada`, `ActivosOperadorControllerTest`, `PermisosProcesamientoTest`. The suite is 460 tests, all passing on 2026-10-28; what's still open is in [Status by story](#status-by-story).

**If something goes wrong**

- **The simulator doesn't respond or a job is `Failed`:** read the error in Apex Jobs and run the same `iniciar` again; the identity prevents duplicates. If it keeps failing, show the [scenario runs](#scenario-runs) and the data already in the org.
- **Everything is `Conflicto` or a resend:** the org wasn't clean. Show Conflictos and Duplicadas (reenvíos) as proof of BR-205 and carry on.
- **No critical signal or no new Case:** it depends on how the batches are split (D011 h). Show block A or B of the [runs of 2026-10-27](#runs-of-2026-10-27).
- **"Traer señales" fails:** the admin persona lacks `Nova_Casa_Simulator_Integration`; use Execute Anonymous with Juan Diego's user.
- **No "Login" in Setup > Users:** check "Administrators Can Log in as Any User", or show the `UserRecordAccess` tables in `acceso.md`.
- **"No pudimos cargar tus activos":** "Reintentar". If it persists, the user lacks FLS: it's the error state BR-207 asks for; carry on with another role.
- **The run is slow:** 1000 messages took 24 s on 2026-10-27; use `QA_200` with few pages.

Runs create real records. Don't delete what someone else created; the clean is agreed in Slack.
