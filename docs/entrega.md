# Delivery: status, evidence and demo

Everything needed to close the sprint, in one place: where each story stands, what we still have to ask the MDSS facilitator, the message contract, the scenario runs, how to collect the evidence that is missing, and the demo script. The older files it replaces (`entendimiento.md`, `preguntas-facilitador.md`, `contrato-mensaje.md`, `simulador.md`, `evidencia-escenarios.md`, `checklist-evidencia.md`, `demo.md`) are in git history.

The MDSS brief (`Sprint 2 - Nova Casa.md`) is the source of truth. The reason behind each rule is in [decisiones.md](decisiones.md) (the D-numbers below). Who sees and does what is in [acceso.md](acceso.md).

**The repo is public.** No screenshots, record Ids, org usernames or org data in this file. Screenshots and query results go as comments on the story's MDSS card; this file only takes summaries (counts, pass or fail, date).

## Status by story

Status as of 2026-10-20. "Facilitator pending" means the code is done and tested, but the decision it rests on is still a team position (see [Open questions](#open-questions-for-the-facilitator)).

| Story | Status | Evidence | Missing |
|---|---|---|---|
| US-201 | Done, facilitator pending (D031) | `TelemetriaIngestaTest`, `SimuladorClientTest`, `SenialSensorHandlerTest.publicarElEventoPersisteATravesDelTrigger`; key traced in the 10-14 `QA_200` run (published to processed in 5 s); list view Todas las señales | Trace one key from a scheduled run (D040) |
| US-202 | Done, facilitator pending (D032) | `SenialSensorHandlerTest` (`unLoteMixtoDe200SenialesSeparaValidasEInvalidasConUnNumeroFijoDeConsultasYDml`, `doscientosEventosEnUnLoteUsanUnNumeroFijoDeConsultasYDml`, `unaExcepcionEnUnEventoNoTumbaElLote`), `TelemetriaIngestaTest.unaPaginaDe200SeProcesaEnUnSoloExecute`; `INVALID_DATA` run; list view Rechazadas | Decide whether ingestion and subscriber treat signals with no identity the same way (D032, note of 10-16) |
| US-203 | Done, facilitator pending (D011 h) | `SenialSensorHandlerTest` (`unaSenialMasAntiguaQueLaVigenteQuedaAtrasadaAunqueSeaCritica`, `elDesempateD003NoDependeDelOrdenDeLlegada`, `tiposDeMedicionDistintosDelMismoActivoNoSeSobrescriben`, and the two batch-order tests of D011 h); `LATE_MESSAGES` run; list view Atrasadas | — |
| US-204 | Evidence pending | `SenialSensorHandlerTest.editarElLimiteDeUnUmbralCambiaLaClasificacionSinTocarElHistorico` and the four boundary tests (D019); `UmbralValidadorTest` (D018); list view Nova Casa - Umbrales | A real run that changes a limit without deploying ([block C](#block-c--boundaries-twice)) |
| US-205 | Done (D039, accepted verbally on 10-17, deployed in #92) | `IntervencionServiceTest`, `SenialSensorHandlerTest` (`unReenvioIgualSoloSumaReenviosSinTocarLecturaNiCase`, `siFallaElCaseLaIdentidadQuedaFallidaSinLecturaYLasDemasSeProcesan`); `CONFLICT` run (405 `Conflicto`, none with a Case); list views Intervenciones abiertas, Duplicadas (reenvíos), Conflictos | Paste D039 as a comment on the MDSS card; rerun `DUPLICATES` and `CRITICAL_BURST` with D039 ([block B](#block-b--duplicates)); the `DUPLICATE_VALUE` race in `IntervencionService` has no test (D010) |
| US-206 | Done in tests | `SenialSensorHandlerTest` (`tresValoresRepresentativosDeTemperaturaSonNormalAdvertenciaYCritica`, `unaAdvertenciaEscribeLecturaNivel1SinCaseYElActivoQuedaEnNivel1`, `elActivoMuestraLaMaximaSeveridadEntreAdvertenciaYCritica`) and the boundary tests | See an asset in warning on screen; the boundary tests only use `TECHNICAL_ROOM` + `TEMPERATURE` |
| US-207 | Evidence pending | `ActivosOperadorControllerTest`, `IntervencionOperadorControllerTest`; no Jest (D012) | The manual screen checks, including the D041/D042 redesign deployed on 10-19 ([US-207 checks](#us-207-checks)) |
| US-208 | Done, facilitator pending (D005) | [acceso.md](acceso.md) ("Result (T8.6)", "Hierarchy instead of View All (D022)"); `ActivosOperadorControllerTest.operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth`, `SeguridadTest`, `PermisosProcesamientoTest`, `SenialSensorHandlerTest.laIngestaPersisteConUnUsuarioSinPermisosDeOperador`, `TelemetriaIngestaTest.laIngestaPublicaTodoConUnUsuarioSinPermisosDeOperador`; the [login-as walkthrough of 10-13](#manual-walkthrough-of-2026-10-13) | Whether the other personas find BLD-TEST-NOAUT in search; that the signal history loads for each persona |
| US-209 | Evidence pending | List views of `Log_Senial__c` with `Accion_Reintento__c` (D014); `LogAccionReintentoTest`, `IngestaControllerTest`, `SeguridadTest`; on 10-13 operators, coordinator and manager had no "Registros de Señal" tab | See the tab as admin; inspect a normal, invalid, resent and late signal as admin ([US-209 checks](#us-209-checks)); nothing tests `Motivo__c` for secrets; no real run has left a `Fallida` row; question 6.1 (D024) |
| HP-01 | Done | `CAMERA_OUTAGE`: loss of communication arrives as normal `CONNECTIVITY` messages | — |
| HP-05 | Evidence pending | `TelemetriaIngestaTest`; the 10-page runs of 10-14 used one job each (up to 72 s) | No retry or reopened session has been seen live (D023); chain depth beyond 27 is unvalidated (D013) |

**Tests.** Last full run on 2026-10-19, on `main` (f524cee): 424 of 424 passing, 89 % org coverage, no class of ours below 87 % (the lowest is `SesionSimulador`). `scripts/org-check.sh tests` runs it again. A deploy proves none of this: in `nova-cdo` it reports `Running Tests - Skipped` (`CONTRIBUTING.md`).

## Open questions for the facilitator

The team answered these on 2026-10-19 and 10-20 (John); PR #97 records each answer as one line in its decision. They were team positions, not the facilitator's answer. On 2026-10-28 John, as the person responsible, approved every one of them in place of the facilitator's confirmation (each Status line in [decisiones.md](decisiones.md) says so): none is open. Two answers changed something: the low temperature warning is LT 18 (D054), and question 6.1 is settled by D056 (the history gives values only for accepted readings). The table and the card comments below stay as the record of what was asked.

| Card | Decision | Question | Team position | If the answer is "no" |
|---|---|---|---|---|
| US-201 | D031, D023 | Does ingestion that our Apex publishes (every 5 minutes, D040, or by hand) meet "Platform Events reales"? What does the simulator return when a session expires or it limits the rate? | It meets criterion 1 | The simulator would have to push events itself, which its contract doesn't offer (D031, alternative dropped); our subscriber already processes any published event |
| US-202 | D032 | Is our list of 7 rules the definition of "invalid"? | The 7 rules | Adjust the handler rules and `SenialSensorHandlerTest` |
| US-205, US-203 | D039, D011 (h) | D039 was accepted verbally: confirm it in writing. Does a critical reading older than another of the same batch, or than the current reading, stay as evidence only? | Yes to both | Change the handler and repeat the scenario runs |
| US-204, US-206 | D004, D006, D019 | Operators, values and the exact boundary; `Umbral__c` as "el mecanismo administrativo elegido"? | Yes | Other operators or values are a data change in `Umbral__c`, no code; rejecting the object means a migration |
| US-208 | D005, D022, D020, D021, D024 | The sharing model and its three system-mode exceptions? | Accepted (D021 still waits on Juan Diego's confirmation) | The OWD change is hard to revert: its own PR, agreed by both, deployed only from `main` |
| US-209 | D024, D034 | 6.1: may operator, coordinator and manager see the result and value of a rejected or conflicting signal? 6.2: how is a conflict marked? | 6.1 not asked yet; 6.2 fix the screen (PR #97) | Remove fields from the history, or add a separate conflict flag |

Closed since Discovery: the intervention is `Case` (D001); a tie on `occurredAt` goes to the higher severity, then `messageId` (D003); buildings and assets are the standard `Account` and `Asset` (D005); MDSS didn't provision personas or permission sets, so we built them (D022). Of the Discovery assumptions, the 200-signal batch matches the subscriber's batch size (D017), and the simulator needed more than the contract shows (session, cursor header, exact auth parameter name; see [Message contract](#message-contract)).

### Comments to paste on the MDSS cards

- **US-201:** «El simulador, tal como lo usamos (`POST /session`, `GET /telemetry` con cursor y `GET /catalog`), no empuja nada hacia la organización. Nuestro Apex lo consulta cada 5 minutos (y a mano con «Traer señales») y publica un `Senial_Sensor__e` por mensaje; el suscriptor Apex los procesa en lotes de hasta 200. ¿Cumple esto el criterio 1 aunque el evento lo publique nuestro Apex? ¿Qué devuelve el simulador al expirar una sesión (suponemos 409/410) o al limitar la tasa (429)? ¿Una sesión nueva repite el mismo `source` + `messageId`? ¿Respeta `batchSize`? (`QA_200` devolvió 200 por página aunque pedimos 50.)»
- **US-202:** «Una señal queda `Rechazada` con motivo, y las demás del lote siguen, cuando: falta o no es numérico el valor, o falta o no es ISO 8601 `occurredAt`; su activo no está en el catálogo; su edificio no es el del activo; no hay umbral activo para su tipo de activo y medición; su unidad no es la esperada; un campo excede el largo o `Message_Type` no es válido; o el valor cae en un umbral `Invalida` (rango físico). Una señal sin `source` o sin `messageId` no puede tener su propia fila con su identidad: la ingesta la deja `Rechazada` con una clave derivada antes de publicar. ¿Es esta su definición de «inválido»? ¿Les basta esa evidencia para las señales sin identidad?»
- **US-205 y US-203:** «Dejamos por escrito lo que nos indicó de palabra el 2026-10-16 y el 2026-10-17: la primera crítica de un activo abre la intervención y, mientras siga abierta, otra crítica del mismo activo no abre otra; solo actualiza la información del caso. Lo que no se precisó lo fijamos nosotros: un caso abierto por activo, sin importar la medición; el caso guarda la última crítica (medición, valor, unidad, hora e identidad); sigue abierto hasta que una persona lo cierra; después de cerrarlo, una crítica nueva abre otro; un reenvío, un conflicto o una señal más vieja que la lectura vigente no lo actualizan. ¿Lo confirma? ¿Y que una crítica más vieja que otra del mismo lote, o que la lectura vigente, queda solo como evidencia?»
- **US-204 y US-206:** «Los límites viven en `Umbral__c`, editable por coordinador y admin sin desplegar (no Custom Metadata, que exige permisos de administrador). Ejemplos: cámaras Advertencia GT 90 y Crítica GT 180 segundos; temperatura Advertencia GT 30, Crítica GT 35, Inválida GE 81 y LE −11. En el límite exacto `GT` y `LT` no se cumplen (30 °C es Normal) y `GE` y `LE` sí. ¿Confirman operadores, valores y el objeto como mecanismo administrativo?»
- **US-208:** «`Account` y `Case` en Private, `Asset` Controlled by Parent; cada edificio es de un operador, y coordinador y gerente ven por jerarquía de roles, sin View All. Tres operaciones corren en modo sistema, siempre después de comprobar en modo usuario que la persona ve el activo: crear la intervención manual, comprobar si ya hay una abierta (solo sí o no) y el historial por activo (sin motivo, huella ni identidad). La ingesta no depende de permisos de operador. ¿Aceptan este modelo?»
- **US-209:** «El historial por activo muestra a operador, coordinador y gerente, solo de los activos que ya ven, el tipo de señal, la fecha, el resultado, la medición, el valor y la unidad; nunca el motivo, la huella ni la identidad. ¿Es aceptable que vean el resultado y el valor de una señal rechazada o en conflicto? Cuando llega la misma clave con otro contenido, la fila original pasa a `Conflicto`, conserva su valor y su caso, y el contenido nuevo no se guarda; la pantalla la marca como «valor original». ¿Basta con eso, o la fila original debe seguir `Procesada` con el conflicto marcado aparte?»

When an answer arrives: record it in the decision's Status line with the date and who answered (or adjust the decision); if it's still verbal, say so in the decision. Only a change of behavior needs code: log it in `decisiones.md` first, then the PR with its test.

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
- **Batch dependence.** Counts depend on how the stream is split into batches (D011 h). If the facilitator answers differently, every run has to be repeated.
- **The clean.** On 10-14 the script's clean failed on the Apex CPU limit when it deleted logs, Cases and readings in one execution; deleting each kind on its own always worked. The script now deletes one kind per execution, logs first. That version hasn't been run in the org yet.
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

## Collecting the remaining evidence

What's missing isn't code: it's runs in the org and screenshots that only John or Juan Diego can do. Each check says what passes.

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

It follows the brief's "Historia de referencia" (`Sprint 2 - Nova Casa.md`): Laura, an operator, starts her shift and sees which equipment needs attention; the critical signal opens a single intervention, the resend doesn't open another and the old reading doesn't replace the current one. Operator 1 plays Laura (in our org she has one building, not two). The role-by-role part after that is ours, not the brief's. About 14 minutes.

**Before the demo (not timed)**

1. Say in Slack who runs the ingestion and when. Juan Diego or John runs it with his own user: both have `Nova_Casa_Admin` and `Nova_Casa_Simulator_Integration`. The admin persona doesn't have the second one, so "Traer señales" fails with that user.
2. Turn off the scheduled ingestion (`desprogramar-ingesta.apex`) and turn it back on afterwards.
3. Clean org: `scripts/org-check.sh clean` shows what it would delete, and `clean confirm=<org>:<n>` deletes it, once John and Juan Diego agree. It only deletes telemetry Cases: close the manual interventions by hand if they shouldn't show.
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
| 7 | 1.5 | Manager and operator 2 | Each one sees only what they're authorized to see | BR-208 |
| 8 | 1.5 | Juan Diego | Why a signal was rejected and whether to retry it | BR-209 |
| 9 | 1 | Presenter | Automated tests | BR-210 |

1. **Context.** Each vendor has its own portal and the operator finds out late. Read the reference story aloud. The flow in one sentence: simulator → `Senial_Sensor__e` → `SenialSensorTrigger` as the integration user → `Lectura_Vigente__c`, `Log_Senial__c` and `Case` → "Activos del operador".
2. **The signals arrive.** In Execute Anonymous, as Juan Diego: `TelemetriaIngesta.iniciar('QA_200', 42, 200, 5);`. Apex Jobs shows one `TelemetriaIngesta` job `Completed`. In Registros de Señal > Todas las señales (`/lightning/o/Log_Senial__c/list?filterName=Todas_las_senales`): each row has its identity, `Occurred_At__c`, `Publicado_At__c` and `Procesado_At__c`; rows go from `Publicada` to `Procesada` by themselves; a few stay `Rechazada` with a reason and the rest carry on.
3. **Laura starts her shift.** Log in as operator 1 > Activos del operador. Only BLD-BOG-001 shows up. The banner and the building summary count assets in Crítica, Precaución and Sin dato; the asset takes the highest severity of its latest readings. Filter by severity, then by building; a combination with no results says "Ningún activo coincide con esos filtros" with "Limpiar filtros", which isn't the same as "Sin lecturas todavía". Cards show the reading's age and "(desactualizada)" past 15 minutes (D007). "Ver activo" shows the current reading per measurement type and, if critical, "Caso N". Laura can "Crear intervención" but has no "Actualizar seguimiento" or "Ver límites" (D020). If the pump isn't critical in this run, use whichever asset is.
4. **One intervention, even if it arrives twice.** As Juan Diego, note the count in Cases > Intervenciones abiertas. Run the same `iniciar` again. The count doesn't change; Duplicadas (reenvíos) shows rows with `Reenvios__c` > 0 and the same result and Case. If the simulator sends different content with the same key, the row is `Conflicto` (list view Conflictos), also with no new Case. Back as Laura, "Actualizar": still a single "Caso N".
5. **An old reading isn't the current condition.** Open a row in Atrasadas and its asset: the row's `Occurred_At__c` is older than the current reading, its reason says so, the current reading didn't change and the row has no Case even if it's critical. Almost every row ends up `Atrasada` in a full run; that's D011 (h).
6. **The coordinator organizes the work.** Log in as the coordinator > Intervenciones abiertas: one open intervention per asset for both buildings (D039). On a critical asset, "Actualizar seguimiento" (On Hold, with a comment) > Guardar; Laura couldn't. "Ver límites": thresholds are `Umbral__c` records edited without deploying; a contradictory range is rejected on save (D018). Don't leave a threshold changed.
7. **Everyone sees their own data.** The manager sees BLD-BOG-001 and BLD-BAQ-001 read-only, with no action buttons, and not BLD-TEST-NOAUT in Nova Casa - Edificios (D022). Operator 2 sees only BLD-BAQ-001. The restriction is also on the server: the controller is `with sharing` and queries in `USER_MODE` (`ActivosOperadorControllerTest.operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth`).
8. **The administrator investigates.** Rechazadas, Conflictos and Fallidas, then look up a signal by its identity in global search: each row shows its result, Motivo and Acción de reintento (D014): a rejected row says to fix the data at the source, a failed one says to retry, a processed one says there's nothing to do. Retrying means running the ingestion again; the identity prevents a duplicate Case. No token, cursor or secret in any row, and only the admin sees the log.
9. **Quality.** Show the test result from the preparation and name the tests that fail if what the audience saw breaks: `tresValoresRepresentativosDeTemperaturaSonNormalAdvertenciaYCritica`, `operadorGTUnValorIgualAlLimiteNoLoCumpleYElSiguienteSi`, `editarElLimiteDeUnUmbralCambiaLaClasificacionSinTocarElHistorico`, `unReenvioIgualSoloSumaReenviosSinTocarLecturaNiCase`, `mismaIdentidadConOtroContenidoEsConflictoSinCambiarEstado`, `IntervencionServiceTest` (one open Case per asset, D039), `doscientosEventosEnUnLoteUsanUnNumeroFijoDeConsultasYDml`, `unaSenialMasAntiguaQueLaVigenteQuedaAtrasadaAunqueSeaCritica`, `elDesempateD003NoDependeDelOrdenDeLlegada`, `ActivosOperadorControllerTest`, `PermisosProcesamientoTest`. What's still missing is in [Status by story](#status-by-story).

**If something goes wrong**

- **The simulator doesn't respond or a job is `Failed`:** read the error in Apex Jobs and run the same `iniciar` again; the identity prevents duplicates. If it keeps failing, show the [scenario runs](#scenario-runs) and the data already in the org.
- **Everything is `Conflicto` or a resend:** the org wasn't clean. Show Conflictos and Duplicadas (reenvíos) as proof of BR-205 and carry on.
- **No critical signal or no new Case:** it depends on how the batches are split (D011 h). Show `CRITICAL_BURST` in the scenario runs.
- **"Traer señales" fails:** the admin persona lacks `Nova_Casa_Simulator_Integration`; use Execute Anonymous with Juan Diego's user.
- **No "Login" in Setup > Users:** check "Administrators Can Log in as Any User", or show the `UserRecordAccess` tables in `acceso.md`.
- **"No pudimos cargar tus activos":** "Reintentar". If it persists, the user lacks FLS: it's the error state BR-207 asks for; carry on with another role.
- **The run is slow:** 10-page runs took up to 72 s; use `QA_200` with few pages.

Runs create real records. Don't delete what someone else created; the clean is agreed in Slack.
