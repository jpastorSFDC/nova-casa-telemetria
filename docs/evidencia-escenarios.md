# Evidence: end-to-end runs of the simulator scenarios (T9.3)

Runs of `TelemetriaIngesta.iniciar('<scenario>', 10)` against `nova-cdo`, each one on a cleaned org (logs, readings and Cases with `Origin = 'Telemetria'` deleted first). Counts are from SOQL on `Log_Senial__c.Resultado__c`, `Lectura_Vigente__c` and `Case`. Deploys report 0 tests in this org, so unit evidence is `sf apex run test` (see the PRs).

## Results — final reruns, 2026-10-05 (post chain-depth fix, trigger as integration user)

All five scenarios below were re-run on 2026-10-05 after the Queueable chain-depth fix (D013, point 1.bis, PR #36) was deployed. `SenialSensorTrigger` ran as `novacasa.integracion@novacasa-telemetria.demo` (D017) for all five: `Log_Senial__c` rows are created by the caller (`johnalejandro.pastor24@salesforce.com`, running `iniciar`), `Lectura_Vigente__c` and `Case` rows are created by the integration user as the Platform Event subscriber. None of these five runs produced an `AsyncApexJob` with status `Failed` — the fix held for every chain depth these runs reached.

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `QA_200` | 189 | 9 | 2 | 9 Procesada, 175 Atrasada, 4 Rechazada, 1 Conflicto |
| `DUPLICATES` | 276 | 9 | 7 | 30 Procesada, 232 Atrasada, 10 Conflicto, 4 Rechazada |
| `BOUNDARIES` | 400 | 9 | 2 | 36 Procesada, 364 Atrasada, 0 Conflicto, 0 Rechazada |
| `CRITICAL_BURST` | 391 | 9 | 30 | 36 Procesada, 350 Atrasada, 1 Conflicto, 4 Rechazada |
| `LATE_MESSAGES` | 385 | 9 | 6 | 31 Procesada, 327 Atrasada, 10 Conflicto, 17 Rechazada |

All Cases above are `Priority = Critica`, `Status = En curso`. All five rows are now complete; no cell is "not recorded" for this batch.

## `CAMERA_OUTAGE` (T1.7, 2026-10-06)

Run once with `TelemetriaIngesta.iniciar('CAMERA_OUTAGE', 3)`, announced beforehand. It ended by itself after 2 pages (2 jobs `Completed`, 0 errors).

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `CAMERA_OUTAGE` | 15 | 2 | 4 | 6 Procesada (4 with a Case), 9 Atrasada |

- Loss of communication arrives as ordinary `CONNECTIVITY` messages for `SECURITY_CAMERA` assets (`Cámara azotea`, `Cámara acceso vehicular`), measured as `CAMERA_CONNECTIVITY` in `SECONDS`. There is no separate message type or field for it.
- Latest readings: `Cámara azotea` 57 s `Normal`; `Cámara acceso vehicular` 270 s `Crítica` (rules: Advertencia GT 90, Crítica GT 180).
- The 9 `Atrasada` rows are older than a message already received for the same asset in the same batch: kept as evidence, no Case, no change of state.
- `CAMERA_OUTAGE` is not in the MDSS brief; it only appears in the simulator's scenario list. The brief only says "Pérdida de comunicación con un dispositivo".
- The readings' `Occurred_At__c` are dated 2026-10-07, ahead of the run time (2026-10-06 ~20:31 UTC). The simulator's clock is ahead of real time; same open question as the future-date warning in D020.

## Earlier runs (kept for context — see "Scenario volume is not reproducible" below)

These predate the chain-depth fix and/or ran with `SenialSensorTrigger` as Automated Process, not the integration user. Kept here because, read together with the table above, they are the evidence for the non-reproducibility caveat: the same scenario name does not return the same message volume across separate runs.

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `QA_200` (trigger as Automated Process) | 189 | 10 | 3 | 17 Procesada, 167 Atrasada, 4 Rechazada, 1 Conflicto |
| `QA_200` (trigger as integration user, earlier rerun same day) | 189 | 10 | 2 | 10 Procesada, 174 Atrasada, 4 Rechazada, 1 Conflicto |
| `DUPLICATES` (pre-fix, trigger as Automated Process) | 766 | not recorded | 14 | 154 Conflicto, rest not recorded |
| `CRITICAL_BURST` (pre-fix, trigger as Automated Process) | 955 | not recorded | 51 | not recorded |
| `BOUNDARIES` (pre-fix, trigger as Automated Process) | 1000 | not recorded | 1 | 53 Procesada, 947 Atrasada |
| `LATE_MESSAGES` (pre-fix, trigger as Automated Process) | 963 | 9 | 11 | 86 Procesada, 826 Atrasada, 29 Conflicto, 22 Rechazada |

## What was checked against the agreements

- One Case per unique critical message (identity = `source` + `messageId`); each Case is tied to a `Procesada` log row (e.g. `CRITICAL_BURST`'s final rerun: 30 Cases, each tied to a `Procesada` row).
- A resend does not update state or open a Case; the same key with different content is a `Conflicto`.
- A late signal is kept as evidence (`Atrasada`) and neither overwrites the current reading nor opens a Case.
- Latest reading is per asset + measurement type.
- No run — pre- or post-fix — produced an `AsyncApexJob` with status `Failed` for a reason other than the chain-depth bug itself (see D013, point 1.bis); the final reruns above produced none at all.

## Caveats

- **Scenario volume is not reproducible.** The same named scenario (`DUPLICATES`, `BOUNDARIES`, `CRITICAL_BURST`) returned very different total message counts across separate runs on the same day: e.g. `DUPLICATES` went 766 → 564 → 276 across three runs; `BOUNDARIES` 1000 → 400; `CRITICAL_BURST` 955 → 391. Even `QA_200`, which is meant to be the stable/deterministic scenario, varied slightly between reruns under the same trigger config (10 vs 9 Procesada, 10 vs 9 readings). This means the simulator does not guarantee a fixed dataset per scenario name across runs; absolute counts in this doc describe one specific run, not a scenario's invariant signature. Treat the final-rerun table above as this round's recorded evidence, not as the expected count for a future run of the same scenario name.
- **Batch dependence.** A message older than the winner *of its batch* stays `Atrasada` (D011 h), so counts depend on how the Platform Event stream is split into batches — this compounds with the non-reproducibility caveat above, since batch boundaries also shift between runs. The two `QA_200` rows in "Earlier runs" show it on their own: same nominal scenario, different split between `Procesada` and `Atrasada`. The question of whether an older critical message inside the same batch should open a Case is still open with Juan Diego and the facilitator. If the answer changes, every scenario above must be re-run.
- **Chain-depth fix is live.** D013 point 1.bis (PR #36) raised the requested Queueable stack depth to 30 and added a local backstop at 27. All five final reruns completed without any `Failed` job, but none of them chained past page 2–3, so depths above ~27 remain unvalidated in practice (see D013 for the open item).
- **Who ran the trigger.** All five final reruns in the first table ran with `SenialSensorTrigger` as `novacasa.integracion@novacasa-telemetria.demo` (D017). The "Earlier runs" table mixes Automated Process and integration-user runs — see each row.
- `Conflicto` overwrites `Resultado__c` of the original row. Also pending a decision.
- Scenario runs create real records; they were announced before running and cleaned afterwards. No credentials or org data are stored here.

## Evidencia por historia (T9.3)

Qué prueba cada historia y dónde está. "Tablas de arriba" son las corridas de este documento; las pruebas son clases de `force-app/main/default/classes`. El recorrido en vivo está en [demo.md](demo.md).

| Historia | Qué se demuestra | Escenario del simulador | Evidencia | Estado |
|---|---|---|---|---|
| US-201 | Recepción real por Platform Event; publicar (`Publicado_At__c`) y procesar (`Procesado_At__c`) son momentos distintos; la fecha de origen se guarda aparte | Los cinco de "Results — final reruns" | Tablas de arriba; `TelemetriaIngestaTest`, `SimuladorClientTest`, `SenialSensorHandlerTest.publicarElEventoPersisteATravesDelTrigger`; README "Running the ingestion"; list view Todas las señales; demo paso 2 | Pendiente: falta anotar una clave concreta seguida de la publicación al resultado |
| US-202 | Lotes de hasta 200; una señal inválida queda `Rechazada` con motivo y las válidas siguen | `QA_200` (4 Rechazada), `LATE_MESSAGES` (17) | Tablas de arriba; `SenialSensorHandlerTest` (`doscientosEventosEnUnLoteUsanUnNumeroFijoDeConsultasYDml`, `unaExcepcionEnUnEventoNoTumbaElLote`), `TelemetriaIngestaTest.unaPaginaDe200SeProcesaEnUnSoloExecute`; `SenialSensorHandlerTest.unLoteMixtoDe200SenialesSeparaValidasEInvalidasConUnNumeroFijoDeConsultasYDml` (100 válidas, 100 inválidas de tres motivos y 0 caídas; 5 consultas y 3 DML) y `unaMedicionConUnidadIncompatibleSePersisteRechazadaSinLecturaNiCase`; list view Rechazadas | Pendiente: el facilitador debe confirmar la definición de "inválido" (D032); las señales sin identidad solo se cuentan, no tienen fila de log |
| US-203 | Última lectura por activo + medición; una más vieja queda `Atrasada` sin pisar la actual ni abrir caso; empate D003 | `LATE_MESSAGES`; `Atrasada` en todos | Tablas de arriba; `SenialSensorHandlerTest` (`unaSenialMasAntiguaQueLaVigenteQuedaAtrasadaAunqueSeaCritica`, `elDesempateD003NoDependeDelOrdenDeLlegada`, `tiposDeMedicionDistintosDelMismoActivoNoSeSobrescriben`); list view Atrasadas | Hecha, con pregunta abierta al facilitador: una crítica más vieja que otra del mismo lote no abre caso (D011 h) |
| US-204 | Límites en `Umbral__c`, editables sin desplegar; valor exacto en el límite; rango contradictorio rechazado | `BOUNDARIES` | Tabla de arriba; `SenialSensorHandlerTest.editarElLimiteDeUnUmbralCambiaLaClasificacionSinTocarElHistorico` y las cuatro de frontera; `UmbralValidadorTest`; list view Nova Casa - Umbrales; D018, D019 | Pendiente: no hay corrida real que cambie un límite y publique un valor; operadores y valores sin confirmar por el facilitador (D006); `UmbralValidadorTest.doscientasFilasContradictoriasSeMarcanTodasSinExcederLimites` falló por CPU en corridas del 2026-10-05 (T5.10) |
| US-205 | Una intervención por mensaje crítico único; el reenvío no crea otra; misma clave con otro contenido es `Conflicto`; un fallo deja `Fallida` | `DUPLICATES`, `CRITICAL_BURST` (30 casos, cada uno con su fila `Procesada`); `CONFLICT` solo en pruebas | Tablas de arriba; `IntervencionServiceTest`, `SenialSensorHandlerTest` (`unReenvioIgualSoloSumaReenviosSinTocarLecturaNiCase`, `siFallaElCaseLaIdentidadQuedaFallidaSinLecturaYLasDemasSeProcesan`); list views Intervenciones abiertas, Duplicadas (reenvíos), Conflictos; D010 | Hecha, con la misma pregunta abierta de `CRITICAL_BURST` (D011 h) |
| US-206 | Normal y advertencia solo actualizan la lectura; la crítica abre caso; el activo toma la mayor severidad | `BOUNDARIES`, `QA_200` | `SenialSensorHandlerTest` (`tresValoresRepresentativosDeTemperaturaSonNormalAdvertenciaYCritica`, `unaAdvertenciaEscribeLecturaNivel1SinCaseYElActivoQuedaEnNivel1`, `elActivoMuestraLaMaximaSeveridadEntreAdvertenciaYCritica`) | Hecha |
| US-207 | Pantalla LWC con filtros, antigüedad, navegación al activo y al caso, estados de carga, vacío y error | Cualquiera con datos (`QA_200`) | `ActivosOperadorControllerTest`, `IntervencionOperadorControllerTest`; lista manual de D012; demo paso 3 | Pendiente: sin Jest (fuera del MVP) y la lista manual de D012 no tiene una corrida registrada |
| US-208 | Operador solo su edificio, en pantalla y en Apex; gerente ve los dos en solo lectura; nadie de la jerarquía ve BLD-TEST-NOAUT; la ingesta no usa permisos de operador | No aplica (sirve cualquier corrida) | `docs/acceso.md` ("Resultado (T8.6)", "Jerarquía en vez de View All (D022)"); `ActivosOperadorControllerTest.operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth`, `PermisosProcesamientoTest`, `SenialSensorHandlerTest.laIngestaPersisteConUnUsuarioSinPermisosDeOperador`; login as `novacasa.operador@` por John el 2026-10-06 (backlog T8.6) | `SeguridadTest` (T8.5, 14 pruebas con permission sets reales; Gerente sin View All verificado el 2026-10-07). Pendiente: login as de operador 2, coordinador y gerente sin registrar; volver a medir la visibilidad del gerente (BLD-TEST-NOAUT) |
| US-209 | Motivo, resultado y acción de reintento por señal; búsqueda por identidad; solo para admin; sin secretos | Todos (`Rechazada`, `Conflicto`, `Atrasada`, reenvíos) | List views de `Log_Senial__c` con `Accion_Reintento__c` (D014); `SenialSensorHandlerTest` (T6.4); `IngestaControllerTest`; demo paso 8 | Pendiente: la pestaña "Registros de Señal" (`Log_Senial__c`, declarada visible solo en `Nova_Casa_Admin`) está validada con dry-run y **no desplegada** (Deploy ID `0Afak00000nZmOvCAK`, 2026-10-07); falta verla en el navegador como admin (con la combinación de permission sets que tiene asignada) y comprobar que el operador, el coordinador y el gerente no la ven. "Solo para admin" y "sin secretos" no tienen todavía una inspección registrada: la primera la cubre `SeguridadTest` (T8.5, ya en `main`), la segunda no la prueba nada sobre `Motivo__c`. No hay una inspección registrada en el org de una señal normal, una inválida, una duplicada y una atrasada; ninguna corrida real dejó `Fallida` |
| HP-01 | La pérdida de comunicación llega como `CONNECTIVITY` de cámaras, sin tipo aparte | `CAMERA_OUTAGE` | Sección `CAMERA_OUTAGE` de arriba | Hecha (escenario fuera del brief) |
| HP-05 | Semilla y tamaño de lote; reintento ante 429/5xx y sesión nueva ante 409/410 | Ninguno todavía | `TelemetriaIngestaTest`; D023 | Pendiente: corrida real de varias páginas (D023) y validar más de 27 páginas de profundidad (D013) |

Antes de grabar o repetir esta evidencia, el org tiene que estar limpio: el 2026-10-06 tenía 400 filas de `Log_Senial__c`, todas `Conflicto`, porque el simulador reutiliza `messageId` entre sesiones.
