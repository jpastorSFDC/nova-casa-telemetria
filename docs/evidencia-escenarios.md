# Evidence: end-to-end runs of the simulator scenarios (T9.3)

Runs of `TelemetriaIngesta.iniciar('<scenario>', 10)` against `nova-cdo`, each one on a cleaned org (logs, readings and Cases with `Origin = 'Telemetria'` deleted first). Counts are from SOQL on `Log_Senial__c.Resultado__c`, `Lectura_Vigente__c` and `Case`. Deploys report 0 tests in this org, so unit evidence is `sf apex run test` (see the PRs). The cleanup, the run, the wait for processing and the tables below are reproducible with `scripts/org-check.sh` (`clean`, `run`, `wait`, `evidence`).

## Results — runs of 2026-10-14 (Juan Diego, `scripts/org-check.sh`)

Nine runs in a fixed order, each on a cleaned org: `clean confirm=<org>:<n>` → `run <SCENARIO>` → `wait` → `evidence`, started and read by Juan Diego with his own user, seed 42. Gates for every run: no `AsyncApexJob` in `Failed` and no row left `Publicada`. The tables below are the `evidence` output of each run. All nine finished with no job in `Failed` and no row left `Publicada`.

**The cleans.** The first one removed 10,200 `Log_Senial__c`, 10 `Lectura_Vigente__c` and the 70 `Case` with `Origin = 'Telemetria'`; the 3 other Cases, the buildings, the assets and the thresholds were not part of it. Everything went to the recycle bin. The script's own pass failed on the Apex CPU limit (also with chunks of 500, and nothing was deleted). Juan Diego deleted the logs in passes of 2000 and then ran the script's clean for the Cases and the readings, and both parts worked. The cleans before runs 2, 3 and 4 worked with the script as it was. The clean before run 5 (1929 logs, 9 readings and 12 Cases) failed on the same limit and also deleted nothing, so the failure does not need thousands of logs. The cause was not confirmed (no debug log was read): what the failures have in common is that logs, Cases and readings were deleted in one Apex execution, and what worked every time was deleting each kind on its own. Juan Diego then did the clean in two steps: one pass of logs only, which removed 1962 `Log_Senial__c` (33 more than the preview had shown, because "Traer señales" was pressed after run 4's evidence was captured; run 4's figures are unaffected), and then `clean confirm=<org>:0` for the 12 Cases and the 9 readings. The preview came back at 0 / 0 / 0. The cleans before runs 6, 7, 8 and 9 (previews 1861 / 6 / 2, 1434 / 9 / 27, 600 / 2 / 6 and 500 / 9 / 1) used the same two steps and also ended at 0 / 0 / 0. Run 9 was the last one and no clean followed it. The script now deletes one kind per execution, logs first, and goes on to the Cases and the readings only when no log is left; that version has not been run in the org yet.

### Run 1 — `QA_200` (10 pages requested, batch 200, started 2026-10-14T15:35:30Z)

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `QA_200` | 189 | 10 | 4 | 16 Procesada, 168 Atrasada, 4 Rechazada, 1 Conflicto |

- **Gates:** 1 job (`TelemetriaIngesta`), `Completed`, 0 errors; 0 rows `Publicada`. The job took 13 s from creation to completion; the first `Publicado_At__c` to the last `Procesado_At__c` took 5 s. The stream ended after the first page (`flujoTerminado=true`).
- **Counters:** 200 received, 200 published, 189 log rows created, 11 `yaExistentes`, 0 log failures, 0 publish failures. The 11 are the scenario's own repeats, not leftovers: 10 rows with `Reenvios__c > 0` plus the 1 `Conflicto` (200 = 189 + 10 + 1, the same split as on 2026-10-05). The 189 log rows created equal the 189 identities of the 2026-10-05 run on a clean org, so the recycle bin blocked none.
- **Latest readings by severity (US-206):** 3 `Crítica`, 2 `Advertencia`, 5 `Normal`, 0 without a level.
- **Cases:** 4, all `Critica` and `En curso`, each tied to a `Procesada` log row.
- **`Atrasada` (168):** 167 lost to a newer message of the same batch and 1 to the stored reading (D011 h).
- **`Rechazada` (4), one row each:** `WATER_CONSUMPTION 7476 LITER_PER_15_MIN` above the physical range limit `GT 5000`; `Valor ausente o no numérico: null`; `No hay umbral activo para UNKNOWN TEMPERATURE`; `ENERGY_CONSUMPTION 23.6 WATT` not in the expected unit `KWH_PER_15_MIN`.
- **Against 2026-10-05:** the same 189 log rows and the same 4 `Rechazada` and 1 `Conflicto`, but 16 `Procesada` and 4 Cases against 9 and 2: the split depends on the batch again (see Caveats).

US-201 trace of one `Procesada` row with a Case and one without:

| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Case |
|---|---|---|---|---|---|---|---|
| `nova-casa-simulator\|msg_000007` | Medidor de agua torre única | 2026-10-14T15:42:41Z | 2026-10-14T15:35:40Z | 2026-10-14T15:35:45Z | -421 | 5 | `En curso`, `Critica` |
| `nova-casa-simulator\|msg_000004` | Sala técnica principal | 2026-10-14T15:39:39Z | 2026-10-14T15:35:40Z | 2026-10-14T15:35:45Z | -239 | 5 | none |

`Delay publish` is negative in every trace row of runs 1 to 3, and it grows with the message number: `msg_000004` is 4 minutes ahead of its publish time, `msg_000007` 7, `msg_000122` 122 and `msg_000176` 176 (run 2). In `QA_200`, `DUPLICATES` and `BOUNDARIES` the simulator's timeline advances one minute per message from the start of the session, so `Occurred_At__c` is in the future when the message is published, by more the later it comes in the stream; it is not a fixed offset of the simulator's clock (D020 covers the future-date warning, and the `CAMERA_OUTAGE` section below shows the same). `LATE_MESSAGES` stamps its messages differently (run 4). The figure that means something is `Latency process`: 5 s from published to processed in run 1.

### Run 2 — `DUPLICATES` (10 pages, batch 200, started 2026-10-14T16:30:52Z)

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `DUPLICATES` | 1437 | 9 | 19 | 83 Procesada, 1270 Atrasada, 50 Conflicto, 34 Rechazada |

- **Gates:** 1 job (`TelemetriaIngesta`), `Completed`, 0 errors; 0 rows `Publicada`. The job took 57 s from creation to completion; the first `Publicado_At__c` to the last `Procesado_At__c` took 71 s. The run read the 10 pages it was given and stopped there (`flujoTerminado=false`): 2000 messages received and published.
- **Counters:** 1437 log rows created, 563 `yaExistentes` (2000 − 1437), 0 log failures, 0 publish failures. 429 rows have `Reenvios__c > 0` and 50 are `Conflicto`.
- **Latest readings by severity (US-206):** 2 `Crítica`, 1 `Advertencia`, 6 `Normal`, 0 without a level.
- **Cases:** 19, all `Critica` and `En curso`, each tied to a `Procesada` log row (19 of 19): the repeats opened no Case of their own (US-205).
- **`Atrasada` (1270):** 1263 lost to a newer message of the same batch and 7 to the stored reading (D011 h).
- **`Rechazada` (34):** the output lists the 10 most common reasons, which cover 22 of the 34 rows: 8 `No hay umbral activo para UNKNOWN WATER_PRESSURE`; 6 `Valor ausente o no numérico: null`; and one each of `WATER_CONSUMPTION 6378` and `5339 LITER_PER_15_MIN` above the physical range limit `GT 5000`, `WATER_CONSUMPTION -229 LITER_PER_15_MIN` below `LT 0`, `TEMPERATURE 101.6 CELSIUS` reaching `GE 81`, `WATER_CONSUMPTION 308 GALLON_PER_15_MIN` and `ENERGY_CONSUMPTION 9.2`, `36.8` and `39.7 WATT` not in the expected unit.
- **Against 2026-10-05:** that run had 276 log rows, 7 Cases and 10 `Conflicto`; this one has 1437, 19 and 50. Another case of the volume changing from run to run (see Caveats).

US-201 trace:

| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Case |
|---|---|---|---|---|---|---|---|
| `nova-casa-simulator\|msg_000122` | Cámara azotea | 2026-10-14T18:32:57Z | 2026-10-14T16:30:58Z | 2026-10-14T16:31:51Z | -7319 | 53 | `En curso`, `Critica` |
| `nova-casa-simulator\|msg_000176` | Medidor de energía torre única | 2026-10-14T19:26:54Z | 2026-10-14T16:30:58Z | 2026-10-14T16:31:51Z | -10556 | 53 | none |

Both rows were processed 53 s after they were published, against 5 s in run 1: this run had 2000 events to process instead of 200.

### Run 3 — `BOUNDARIES` (10 pages, batch 200, started 2026-10-14T17:43:18Z)

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `BOUNDARIES` | 2000 | 9 | 2 | 97 Procesada, 1903 Atrasada, 0 Conflicto, 0 Rechazada |

- **Gates:** 1 job (`TelemetriaIngesta`), `Completed`, 0 errors; 0 rows `Publicada`. The job took 10 s from creation to completion; the first `Publicado_At__c` to the last `Procesado_At__c` took 19 s. The run read the 10 pages it was given (`flujoTerminado=false`): 2000 messages received and published.
- **Counters:** 2000 log rows created, 0 `yaExistentes`, 0 log failures, 0 publish failures, no resends. Every message of this scenario has its own identity.
- **Latest readings by severity (US-206):** 0 `Crítica`, 6 `Advertencia`, 3 `Normal`, 0 without a level.
- **Cases:** 2, both `Critica` and `En curso`, each tied to a `Procesada` log row (2 of 2). No latest reading is `Crítica` now, so the Cases were opened by critical readings that a newer `Procesada` reading of the same asset and measurement replaced later (97 `Procesada` rows wrote 9 readings); the Cases stay open.
- **`Atrasada` (1903):** all 1903 lost to a newer message of the same batch (D011 h), none to the stored reading.
- **`Rechazada`:** none.
- **Against 2026-10-05:** that run had 400 log rows, 9 readings and 2 Cases (36 `Procesada`, 364 `Atrasada`); this one has 2000, 9 and 2 (97 and 1903). The scenario's shape is the same, with more messages read.

US-201 trace:

| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Case |
|---|---|---|---|---|---|---|---|
| `nova-casa-simulator\|msg_000419` | Cámara azotea | 2026-10-15T00:42:17Z | 2026-10-14T17:43:21Z | 2026-10-14T17:43:30Z | -25136 | 9 | `En curso`, `Critica` |
| `nova-casa-simulator\|msg_000007` | Medidor de energía torre única | 2026-10-14T17:50:19Z | 2026-10-14T17:43:19Z | 2026-10-14T17:43:29Z | -420 | 10 | none |

The delays follow the message number again: `msg_000419` is about 419 minutes ahead of its publish time (7 hours, so its `Occurred_At__c` falls on the next day) and `msg_000007` 7 minutes.

### Run 4 — `LATE_MESSAGES` (10 pages, batch 200, started 2026-10-14T17:58:56Z)

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `LATE_MESSAGES` | 1929 | 9 | 12 | 91 Procesada, 1709 Atrasada, 71 Rechazada, 57 Conflicto, 1 Superada |

- **Gates:** 1 job (`TelemetriaIngesta`), `Completed`, 0 errors; 0 rows `Publicada`. The job took 37 s from creation to completion; the first `Publicado_At__c` to the last `Procesado_At__c` took 48 s. The run read the 10 pages it was given (`flujoTerminado=false`): 2000 messages received and published.
- **Counters:** 1929 log rows created, 71 `yaExistentes` (2000 − 1929), 0 log failures, 0 publish failures. 13 rows have `Reenvios__c > 0` and 57 are `Conflicto`.
- **Latest readings by severity (US-206):** 1 `Crítica`, 1 `Advertencia`, 7 `Normal`, 0 without a level.
- **Cases:** 12, all `Critica` and `En curso`, each tied to a `Procesada` log row (12 of 12).
- **`Atrasada` (1709), US-203:** 1703 lost to a newer message of the same batch (D011 h) and 6 to the reading already stored from an earlier batch. Those 6 are the case the agreement describes: a signal that arrives after a newer one for the same asset and measurement, kept as evidence without changing the current state or opening a Case.
- **`Superada` (1), US-203, D003:** a signal with the same `occurredAt` as the stored reading or the batch winner that loses the tie-break (D011, points 3 and 6). It is the first row of this result in a real run; before, only tests covered it. The `Atrasada` and `Superada` rows are separate results: `Superada` is reserved for the tie.
- **`Rechazada` (71):** the output lists the 10 most common reasons, which cover 36 of the 71 rows: 17 `Valor ausente o no numérico: null`; 11 `No hay umbral activo para UNKNOWN WATER_PRESSURE`; and one each of `WATER_CONSUMPTION 6219 LITER_PER_15_MIN` above `GT 5000`, `WATER_CONSUMPTION -377 LITER_PER_15_MIN` below `LT 0`, `TEMPERATURE 119.5 CELSIUS` reaching `GE 81`, `TEMPERATURE -26.8` and `-39.6 CELSIUS` reaching `LE -11`, `WATER_CONSUMPTION 281` and `225 GALLON_PER_15_MIN` and `ENERGY_CONSUMPTION 21.7 WATT` not in the expected unit.
- **Against 2026-10-05:** that run had 385 log rows, 6 Cases, 10 `Conflicto` and 17 `Rechazada`, and no `Superada`; this one has 1929, 12, 57 and 71.

US-201 trace:

| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Case |
|---|---|---|---|---|---|---|---|
| `nova-casa-simulator\|msg_000016` | Sala técnica principal | 2026-10-14T18:00:02Z | 2026-10-14T17:58:58Z | 2026-10-14T17:59:35Z | -64 | 37 | `En curso`, `Critica` |
| `nova-casa-simulator\|msg_000022` | Cámara azotea | 2026-10-14T17:44:01Z | 2026-10-14T17:58:58Z | 2026-10-14T17:59:35Z | 897 | 37 | none |

Here the delays do not follow the message number: `msg_000016` is 64 s ahead of its publish time, and `msg_000022` was published 897 s (about 15 minutes) after it occurred, a message stamped in the past. It was still `Procesada`: by D011 (h) that means it was the newest of its asset and measurement in its batch and not older than the reading stored at that moment.

### Run 5 — `INVALID_DATA` (10 pages, batch 200, started 2026-10-14T21:12:26Z)

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `INVALID_DATA` | 1861 | 6 | 2 | 1203 Rechazada, 563 Atrasada, 63 Procesada, 32 Conflicto |

- **Gates:** 1 job (`TelemetriaIngesta`), `Completed`, 0 errors; 0 rows `Publicada`. The job took 48 s from creation to completion; the first `Publicado_At__c` to the last `Procesado_At__c` took 58 s. The run read the 10 pages it was given (`flujoTerminado=false`): 2000 messages received and published. It is the first live run of this scenario in this evidence: the 2026-10-05 batch below did not include it.
- **Counters:** 1861 log rows created, 139 `yaExistentes` (2000 − 1861), 0 log failures, 0 publish failures. `rechazados=0` and `descartados=0`: the ingestion itself rejected nothing, every message had a usable identity, so all 1203 `Rechazada` rows come from the handler (D032). 105 rows have `Reenvios__c > 0` and 32 are `Conflicto`.
- **Latest readings by severity (US-206):** 0 `Crítica`, 0 `Advertencia`, 6 `Normal`, 0 without a level.
- **Cases:** 2, both `Critica` and `En curso`, each tied to a `Procesada` log row (2 of 2). As in run 3, no latest reading is `Crítica` now, so the Cases were opened by critical readings that a newer `Procesada` reading of the same asset and measurement replaced later (63 `Procesada` rows wrote 6 readings); the Cases stay open.
- **`Atrasada` (563), US-203:** all 563 lost to a newer message of the same batch (D011 h), none to the stored reading.
- **`Rechazada` (1203), US-202, D032:** the output lists the 10 most common reasons, which cover 622 of the 1203 rows: 309 `Valor ausente o no numérico: null` (rule 1); 293 `No hay umbral activo para UNKNOWN WATER_PRESSURE` (rule 4); 14 with a unit that is not the expected one (`ENERGY_CONSUMPTION` in `WATT` instead of `KWH_PER_15_MIN`, 12 rows, and `WATER_CONSUMPTION` in `GALLON_PER_15_MIN` instead of `LITER_PER_15_MIN`, 2 rows; rule 5); and 6 outside the physical range (`TEMPERATURE 104.6 CELSIUS` reaching `GE 81`, and `WATER_CONSUMPTION` of -491 and -263 `LITER_PER_15_MIN` below `LT 0`, 2 rows each; rule 7). The other 581 rows are not listed, so this run does not show rules 2 (unknown asset), 3 (building that is not the asset's) or 6 (field too long or `Message_Type` not allowed), nor a bad date; the tests listed in D032 are the evidence for those.
- **Valid signals went on:** 63 `Procesada` rows wrote the 6 readings next to the 1203 rejected ones, so a bad signal did not stop the others (BR-202).

US-201 trace:

| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Case |
|---|---|---|---|---|---|---|---|
| `nova-casa-simulator\|msg_000224` | Sala técnica principal | 2026-10-15T00:56:28Z | 2026-10-14T21:12:31Z | 2026-10-14T21:13:16Z | -13437 | 45 | `En curso`, `Critica` |
| `nova-casa-simulator\|msg_000016` | Sala técnica principal | 2026-10-14T21:28:25Z | 2026-10-14T21:12:27Z | 2026-10-14T21:13:16Z | -958 | 49 | none |

The delays follow the message number again: `msg_000224` is about 224 minutes ahead of its publish time (3 h 44 min, so its `Occurred_At__c` falls on the next day) and `msg_000016` about 16 minutes.

### Run 6 — `CONFLICT` (10 pages, batch 200, started 2026-10-14T21:17:52Z)

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `CONFLICT` | 1434 | 9 | 27 | 865 Atrasada, 405 Conflicto, 84 Rechazada, 80 Procesada |

- **Gates:** 1 job (`TelemetriaIngesta`), `Completed`, 0 errors; 0 rows `Publicada`. The job took 46 s from creation to completion; the first `Publicado_At__c` to the last `Procesado_At__c` took 49 s. The run read the 10 pages it was given (`flujoTerminado=false`): 2000 messages received and published. It is the first live run of this scenario: until now `CONFLICT` was covered only by tests.
- **Counters:** 1434 log rows created, 566 `yaExistentes` (2000 − 1434), 0 log failures, 0 publish failures, nothing rejected by the ingestion (`rechazados=0`, `descartados=0`). 104 rows have `Reenvios__c > 0` and 405 are `Conflicto`.
- **Latest readings by severity (US-206):** 3 `Crítica`, 0 `Advertencia`, 6 `Normal`, 0 without a level.
- **Cases:** 27, all `Critica` and `En curso`, each tied to a `Procesada` log row (27 of 27). No `Conflicto` row points to a Case, and the repeats opened none of their own: 27 Cases for 27 `Procesada` rows with a Case (US-205).
- **`Conflicto` (405), US-205:** the same `source` + `messageId` arrived again with different content. It is the largest count of any run (`DUPLICATES` had 50, `LATE_MESSAGES` 57). The output does not list the reasons of these rows or what differs from the original, so this run shows the count and the absence of Cases, not the content difference; `SenialSensorHandlerTest.mismaIdentidadConOtroContenidoEsConflictoSinCambiarEstado` is the test for that.
- **`Atrasada` (865), US-203:** 851 lost to a newer message of the same batch and 14 to the stored reading (D011 h).
- **`Rechazada` (84), US-202, D032:** the output lists the 10 most common reasons, which cover 27 of the 84 rows: 10 `Valor ausente o no numérico: null` (rule 1); 8 `No hay umbral activo para UNKNOWN WATER_PRESSURE` (rule 4); 7 `WATER_PRESSURE` above the physical range limit `GT 20` BAR (22.05 twice, and 43.4, 21.65, 26.8, 25.67 and 35.77 once each; rule 7); and 2 `WATER_CONSUMPTION` in `GALLON_PER_15_MIN` instead of `LITER_PER_15_MIN` (363 and 428.67; rule 5). The other 57 are not listed.

US-201 trace:

| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Case |
|---|---|---|---|---|---|---|---|
| `nova-casa-simulator\|msg_000003` | Medidor de agua torre única | 2026-10-14T21:20:59Z | 2026-10-14T21:18:01Z | 2026-10-14T21:18:40Z | -178 | 39 | `En curso`, `Critica` |
| `nova-casa-simulator\|msg_000011` | Medidor de agua torre A | 2026-10-14T21:29:01Z | 2026-10-14T21:18:01Z | 2026-10-14T21:18:40Z | -660 | 39 | none |

The delays follow the message number again: `msg_000003` is about 3 minutes ahead of its publish time and `msg_000011` about 11.

### Run 7 — `CAMERA_OUTAGE` (3 pages, batch 200, started 2026-10-14T22:11:56Z)

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `CAMERA_OUTAGE` | 600 | 2 | 6 | 592 Atrasada, 8 Procesada |

- **Gates:** 1 job (`TelemetriaIngesta`), `Completed`, 0 errors; 0 rows `Publicada`. The job took 15 s from creation to completion; the first `Publicado_At__c` to the last `Procesado_At__c` took 8 s. The run read the 3 pages it was given (`flujoTerminado=false`): 600 messages received and published.
- **Counters:** 600 log rows created, 0 `yaExistentes`, 0 log failures, 0 publish failures, no resends, no `Conflicto`, no `Rechazada`, and nothing rejected by the ingestion (`rechazados=0`, `descartados=0`).
- **Latest readings by severity (US-206):** 2 `Crítica`, 0 `Advertencia`, 0 `Normal`, 0 without a level.
- **Cases:** 6, all `Critica` and `En curso`, each tied to a `Procesada` log row (6 of 6). Both trace rows are cameras (`Cámara azotea` and `Cámara acceso vehicular`), and there are only 2 readings, so the 600 messages cover two asset and measurement pairs: the 6 Cases are on the two cameras. The base design opens one Case per unique critical message, not one per outage, so a camera that stays down opens several (D010 trade-off; consolidating them is the extra scope of the "Incidente" agreement).
- **`Atrasada` (592):** all 592 lost to a newer message of the same batch (D011 h), none to the stored reading. Only 8 messages were `Procesada`, 6 of them critical.
- **Against 2026-10-06:** that run (T1.7, above) had 15 log rows and ended by itself after 2 pages, with `Cámara azotea` `Normal` and `Cámara acceso vehicular` `Crítica`; this one has 600 rows, three full pages without the stream ending, and both cameras `Crítica`. Another case of the volume changing from run to run (see Caveats). The output does not print the measurement type or the value, so this run does not re-check that the gap arrives as `CAMERA_CONNECTIVITY` in seconds; Juan Diego reports it for the two trace rows.

US-201 trace:

| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Case |
|---|---|---|---|---|---|---|---|
| `nova-casa-simulator\|msg_000024` | Cámara azotea | 2026-10-14T22:36:10Z | 2026-10-14T22:12:07Z | 2026-10-14T22:12:12Z | -1443 | 5 | `En curso`, `Critica` |
| `nova-casa-simulator\|msg_000027` | Cámara acceso vehicular | 2026-10-14T22:39:08Z | 2026-10-14T22:12:07Z | 2026-10-14T22:12:12Z | -1621 | 5 | none |

The delays follow the message number again: `msg_000024` is about 24 minutes ahead of its publish time and `msg_000027` about 27.

### Run 8 — `BOUNDARIES` with batch 50 (10 pages, started 2026-10-14T22:18:52Z)

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `BOUNDARIES` (batch 50) | 500 | 9 | 1 | 465 Atrasada, 35 Procesada |

- **Gates:** 1 job (`TelemetriaIngesta`), `Completed`, 0 errors; 0 rows `Publicada`. The job took 4 s from creation to completion; the first `Publicado_At__c` to the last `Procesado_At__c` took 6 s. The run read the 10 pages it was given (`flujoTerminado=false`): with a batch of 50 that is 500 messages received and published, against 2000 in run 3 with a batch of 200.
- **Counters:** 500 log rows created, 0 `yaExistentes`, 0 log failures, 0 publish failures, no resends, no `Conflicto`, no `Rechazada`, and nothing rejected by the ingestion (`rechazados=0`, `descartados=0`).
- **The batch size:** 10 pages and 500 messages mean 50 per page. The page limit sent to `GET /telemetry` is the batch size, and D023 (1d) treats that limit as the reliable bound, so this does not show whether the simulator also honors `batchSize` in `POST /session`.
- **Latest readings by severity (US-206):** 0 `Crítica`, 1 `Advertencia`, 8 `Normal`, 0 without a level.
- **Cases:** 1, `Critica` and `En curso`, tied to a `Procesada` log row (1 of 1). No latest reading is `Crítica`, so, as in runs 3 and 5, the Case was opened by a critical reading that a newer `Procesada` reading of the same asset and measurement replaced later.
- **`Atrasada` (465):** all 465 lost to a newer message of the same batch (D011 h), none to the stored reading.
- **Against run 3 (same scenario and seed, batch 200):** that run had 2000 log rows, 9 readings, 2 Cases (97 `Procesada`, 1903 `Atrasada`); this one has 500, 9, 1 (35 and 465). The trace Case is the same message, `msg_000419` of `Cámara azotea`, with the same delay of -25136 s, so the two runs read the same stream from the start. The shape is the same (almost every row `Atrasada` to the batch); the counts follow the number of messages read.

US-201 trace:

| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Case |
|---|---|---|---|---|---|---|---|
| `nova-casa-simulator\|msg_000419` | Cámara azotea | 2026-10-15T05:17:51Z | 2026-10-14T22:18:55Z | 2026-10-14T22:18:58Z | -25136 | 3 | `En curso`, `Critica` |
| `nova-casa-simulator\|msg_000016` | Medidor de agua torre única | 2026-10-14T22:34:52Z | 2026-10-14T22:18:53Z | 2026-10-14T22:18:56Z | -959 | 3 | none |

The delays follow the message number again: `msg_000419` is about 419 minutes ahead of its publish time (7 hours, so its `Occurred_At__c` falls on the next day) and `msg_000016` about 16.

### Run 9 — `CRITICAL_BURST` (10 pages, batch 200, started 2026-10-14T22:33:35Z)

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `CRITICAL_BURST` | 1926 | 9 | 58 | 1802 Atrasada, 85 Procesada, 21 Rechazada, 18 Conflicto |

- **Gates:** 1 job (`TelemetriaIngesta`), `Completed`, 0 errors; 0 rows `Publicada`. The job took 72 s from creation to completion; the first `Publicado_At__c` to the last `Procesado_At__c` took 77 s. The run read the 10 pages it was given (`flujoTerminado=false`): 2000 messages received and published.
- **Counters:** 1926 log rows created, 74 `yaExistentes` (2000 − 1926), 0 log failures, 0 publish failures, nothing rejected by the ingestion (`rechazados=0`, `descartados=0`). 56 rows have `Reenvios__c > 0` and 18 are `Conflicto`.
- **Latest readings by severity (US-206):** 5 `Crítica`, 1 `Advertencia`, 3 `Normal`, 0 without a level.
- **Cases:** 58, all `Critica` and `En curso`, each tied to a `Procesada` log row (58 of 58). 27 of the 85 `Procesada` rows have no Case. No `Conflicto` row points to a Case, and the repeats opened none of their own: 58 Cases for 58 `Procesada` rows with a Case (US-205). It is the largest number of Cases in these runs, and there are only 5 `Crítica` readings: the base design opens one Case per unique critical message, not one per asset (D010 trade-off, as in run 7).
- **`Atrasada` (1802), US-203:** 1790 lost to a newer message of the same batch and 12 to the stored reading (D011 h).
- **`Rechazada` (21), US-202, D032:** the output lists the 10 most common reasons, which cover 18 of the 21 rows: 6 `No hay umbral activo para UNKNOWN WATER_PRESSURE` (rule 4); 4 `Valor ausente o no numérico: null` (rule 1); 6 values past a physical range limit (rule 7), namely `WATER_CONSUMPTION` above `GT 5000` LITER_PER_15_MIN (8755, 5812, 6646 and 8119), `TEMPERATURE` 85.7 CELSIUS at `GE 81` and `TEMPERATURE` -21.8 CELSIUS at `LE -11`; and 2 `ENERGY_CONSUMPTION` in `WATT` instead of `KWH_PER_15_MIN` (33.6 and 3.7; rule 5). The other 3 are not listed.
- **Against 2026-10-05:** that run (above) had 391 log rows, 9 readings and 30 Cases (36 `Procesada`, 350 `Atrasada`, 1 `Conflicto`, 4 `Rechazada`); this one has 1926, 9 and 58 (85, 1802, 18 and 21). Another case of the volume changing from run to run (see Caveats).
- **State left in the org:** this was the last run and no clean followed it. The org holds these 1926 log rows, 9 readings and 58 Cases (plus the Cases created by hand, which no clean touches).
US-201 trace:

| Identidad__c | Asset | Occurred_At__c | Publicado_At__c | Procesado_At__c | Delay publish (s) | Latency process (s) | Case |
|---|---|---|---|---|---|---|---|
| `nova-casa-simulator\|msg_000011` | Sala técnica principal | 2026-10-14T22:44:44Z | 2026-10-14T22:33:44Z | 2026-10-14T22:34:49Z | -660 | 65 | `En curso`, `Critica` |
| `nova-casa-simulator\|msg_000019` | Sala técnica principal | 2026-10-14T22:52:45Z | 2026-10-14T22:33:44Z | 2026-10-14T22:34:49Z | -1141 | 65 | none |

The delays follow the message number again: `msg_000011` is about 11 minutes ahead of its publish time and `msg_000019` about 19. `Latency process` is 65 s for both rows, longer than the 3 to 39 s of runs 6 to 8; this is the run with the most Cases.

## Results — final reruns, 2026-10-05 (post chain-depth fix, trigger as integration user)

All five scenarios below were re-run on 2026-10-05 after the Queueable chain-depth fix (D013, point 1.bis, PR #36) was deployed. `SenialSensorTrigger` ran as `novacasa.integracion@novacasa-telemetria.demo` (D017) for all five: `Log_Senial__c` rows are created by the caller (John's System Administrator user, running `iniciar`), `Lectura_Vigente__c` and `Case` rows are created by the integration user as the Platform Event subscriber. None of these five runs produced an `AsyncApexJob` with status `Failed` — the fix held for every chain depth these runs reached.

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
| US-201 | Criterio 1: "El simulador publica Platform Events reales hacia la organización y el suscriptor Apex los recibe." Hoy nuestro Apex consulta al simulador y publica `Senial_Sensor__e` (D031, Propuesta); publicar (`Publicado_At__c`) y procesar (`Procesado_At__c`) son momentos distintos; la fecha de origen se guarda aparte | Los cinco de "Results — final reruns" | Tablas de arriba; `TelemetriaIngestaTest`, `SimuladorClientTest`, `SenialSensorHandlerTest.publicarElEventoPersisteATravesDelTrigger`; README "Running the ingestion"; list view Todas las señales; demo paso 2 | Pendiente: falta anotar una clave concreta seguida de la publicación al resultado |
| US-202 | Lotes de hasta 200; una señal inválida queda `Rechazada` con motivo y las válidas siguen | `QA_200` (4 Rechazada), `LATE_MESSAGES` (17) | Tablas de arriba; `SenialSensorHandlerTest` (`doscientosEventosEnUnLoteUsanUnNumeroFijoDeConsultasYDml`, `unaExcepcionEnUnEventoNoTumbaElLote`), `TelemetriaIngestaTest.unaPaginaDe200SeProcesaEnUnSoloExecute`; `SenialSensorHandlerTest.unLoteMixtoDe200SenialesSeparaValidasEInvalidasConUnNumeroFijoDeConsultasYDml` (100 válidas, 100 inválidas de tres motivos y 0 caídas; 5 consultas y 3 DML) y `unaMedicionConUnidadIncompatibleSePersisteRechazadaSinLecturaNiCase`; list view Rechazadas | Pendiente: el facilitador debe confirmar la definición de "inválido" (D032); las señales sin identidad solo se cuentan, no tienen fila de log |
| US-203 | Última lectura por activo + medición; una más vieja queda `Atrasada` sin pisar la actual ni abrir caso; empate D003 | `LATE_MESSAGES`; `Atrasada` en todos | Tablas de arriba; `SenialSensorHandlerTest` (`unaSenialMasAntiguaQueLaVigenteQuedaAtrasadaAunqueSeaCritica`, `elDesempateD003NoDependeDelOrdenDeLlegada`, `tiposDeMedicionDistintosDelMismoActivoNoSeSobrescriben`, `unaCriticaMasViejaEnElMismoLoteQuedaAtrasadaYSoloLaMasNuevaAbreCase` y `unaCriticaMasViejaEnElMismoLoteQuedaAtrasadaAunqueLlegueDespuesDeLaNueva` (los dos órdenes del lote, D011 h), `unaLecturaMasNuevaActualizaValorUnidadFechaYSeveridadDeLaMismaFila`); list view Atrasadas | Hecha, con pregunta abierta al facilitador: una crítica más vieja que otra del mismo lote no abre caso (D011 h). La decisión es de John del 2026-10-05; el facilitador del MDSS no la ha confirmado |
| US-204 | Límites en `Umbral__c`, editables sin desplegar; valor exacto en el límite; rango contradictorio rechazado | `BOUNDARIES` | Tabla de arriba; `SenialSensorHandlerTest.editarElLimiteDeUnUmbralCambiaLaClasificacionSinTocarElHistorico` y las cuatro de frontera; `UmbralValidadorTest`; list view Nova Casa - Umbrales; D018, D019 | Pendiente: no hay corrida real que cambie un límite y publique un valor; operadores y valores sin confirmar por el facilitador (D006); `UmbralValidadorTest.doscientasFilasContradictoriasSeMarcanTodasSinExcederLimites` falló por CPU en corridas del 2026-10-05 (T5.10); el PR #52 (2026-10-07) lo corrigió y la corrida completa del 2026-10-13 no tuvo fallos |
| US-205 | Una intervención por mensaje crítico único; el reenvío no crea otra; misma clave con otro contenido es `Conflicto`; un fallo deja `Fallida` | `DUPLICATES`, `CRITICAL_BURST` (30 casos, cada uno con su fila `Procesada`); `CONFLICT` (405 filas `Conflicto`, ninguna con caso) | Tablas de arriba; `IntervencionServiceTest`, `SenialSensorHandlerTest` (`unReenvioIgualSoloSumaReenviosSinTocarLecturaNiCase`, `siFallaElCaseLaIdentidadQuedaFallidaSinLecturaYLasDemasSeProcesan`); list views Intervenciones abiertas, Duplicadas (reenvíos), Conflictos; D010 | Hecha, con la misma pregunta abierta de `CRITICAL_BURST` (D011 h). La carrera `DUPLICATE_VALUE` de `IntervencionService` (D010) no tiene prueba: la que se intentó el 2026-10-09 falló en la org y se retiró |
| US-206 | Normal y advertencia solo actualizan la lectura; la crítica abre caso; el activo toma la mayor severidad | `BOUNDARIES`, `QA_200` | `SenialSensorHandlerTest` (`tresValoresRepresentativosDeTemperaturaSonNormalAdvertenciaYCritica`, `unaAdvertenciaEscribeLecturaNivel1SinCaseYElActivoQuedaEnNivel1`, `elActivoMuestraLaMaximaSeveridadEntreAdvertenciaYCritica`) y las cuatro de frontera por operador de US-204 (`operadorGTUnValorIgualAlLimiteNoLoCumpleYElSiguienteSi`, `operadorLTUnValorIgualAlLimiteNoLoCumpleYElAnteriorSi`, `operadorGEUnValorIgualAlLimiteSiLoCumpleYSeRechazaComoInvalido`, `operadorLEUnValorIgualAlLimiteSiLoCumpleYSeRechazaComoInvalido`) | Hecha en las pruebas. Pendiente: la corrida `BOUNDARIES` solo tiene totales en este documento (36 Procesada, 364 Atrasada, 2 casos), sin desglose por nivel de severidad; las pruebas de frontera solo usan `TECHNICAL_ROOM` + `TEMPERATURE`, no las demás combinaciones de tipo de activo y medición; operadores y valores siguen sin confirmar por el facilitador (D006); no hay registro de haber visto en pantalla un activo en advertencia |
| US-207 | Pantalla LWC con filtros, antigüedad, navegación al activo y al caso, estados de carga, vacío y error | Cualquiera con datos (`QA_200`) | `ActivosOperadorControllerTest`, `IntervencionOperadorControllerTest`; lista manual de D012; demo paso 3. Trabajo posterior de HP-07 sobre la misma pantalla: historial por activo (#48), panel del edificio y del activo (#53, #58), resumen del historial y antigüedad (D033, #61), historial con tipo, valor y unidad (D034, #63), cierre en bloque (D035, #64), seguimiento desde `Case.Status` (D036, #67) y columna de antigüedad del detalle (D037, #68) | Pendiente: sin Jest (fuera del MVP); la lista manual de D012 no tiene una corrida registrada, y este documento tampoco registra la comprobación manual de lo agregado después (D033 a D037), en particular la columna "Antigüedad" y la carga del resumen del edificio en el `Account` (D037) |
| US-208 | Operador solo su edificio, en pantalla y en Apex; gerente ve los dos en solo lectura; nadie de la jerarquía ve BLD-TEST-NOAUT; la ingesta no usa permisos de operador | No aplica (sirve cualquier corrida) | `docs/acceso.md` ("Resultado (T8.6)", "Jerarquía en vez de View All (D022)"); `ActivosOperadorControllerTest.operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth`, `PermisosProcesamientoTest`, `SenialSensorHandlerTest.laIngestaPersisteConUnUsuarioSinPermisosDeOperador`, `TelemetriaIngestaTest.laIngestaPublicaTodoConUnUsuarioSinPermisosDeOperador` (un Standard User con solo `Nova_Casa_Procesamiento` publica todo; es una prueba de regresión de BR-208 y no prueba que ese permission set sea lo que habilita publicar, D013); login as `novacasa.operador@` por John el 2026-10-06 (backlog T8.6); `SeguridadTest` (T8.5, 14 pruebas con permission sets reales); recorrido a mano con "Iniciar sesión como" del 2026-10-13 (sección de abajo) | Gerente sin View All verificado el 2026-10-07. Verificado a mano el 2026-10-13 por Juan Diego con operador 1, operador 2, coordinador y gerente: cada uno ve los edificios y casos que le corresponden, y el gerente no ve el edificio de prueba (BLD-TEST-NOAUT). Pendiente: no se anotó si las demás personas ven BLD-TEST-NOAUT en la búsqueda, ni el paso A6 (el historial de señales de un activo carga para cada persona) |
| US-209 | Motivo, resultado y acción de reintento por señal; búsqueda por identidad; solo para admin; sin secretos | Todos (`Rechazada`, `Conflicto`, `Atrasada`, reenvíos) | List views de `Log_Senial__c` con `Accion_Reintento__c` (D014); `LogAccionReintentoTest`; `SenialSensorHandlerTest` (T6.4); `IngestaControllerTest`; demo paso 8 | Pendiente: la pestaña "Registros de Señal" (`Log_Senial__c`, declarada visible solo en `Nova_Casa_Admin`) está en `main` desde el PR #62, y el 2026-10-09 un retrieve de `Nova_Casa_Admin` de la org coincidió con `main`, que ya declara esa pestaña; no se retrievó la app Nova Casa. Falta verla en el navegador como admin (con la combinación de permission sets que tiene asignada). El 2026-10-13 Juan Diego comprobó con "Iniciar sesión como" que el operador 1, el operador 2, el coordinador y el gerente no tienen "Registros de Señal"; no se anotaron la URL directa, la búsqueda global ni la lista relacionada del activo. "Solo para admin" y "sin secretos" no tienen todavía una inspección registrada: la primera la cubre `SeguridadTest` (T8.5, ya en `main`), la segunda no la prueba nada sobre `Motivo__c`. No hay una inspección registrada en el org de una señal normal, una inválida, una duplicada y una atrasada; ninguna corrida real dejó `Fallida` |
| HP-01 | La pérdida de comunicación llega como `CONNECTIVITY` de cámaras, sin tipo aparte | `CAMERA_OUTAGE` | Sección `CAMERA_OUTAGE` de arriba | Hecha (escenario fuera del brief) |
| HP-05 | Semilla y tamaño de lote; reintento ante 429/5xx y sesión nueva ante 409/410 | Ninguno todavía | `TelemetriaIngestaTest`; D023 | Pendiente: corrida real de varias páginas (D023) y validar más de 27 páginas de profundidad (D013) |

Última corrida de pruebas registrada: el 2026-10-13, con la org igual a `main` (un retrieve contra `main` el mismo día no mostró diferencias), `sf apex run test` sobre todas las clases de prueba del repo dio 328 de 328 pruebas en verde y 82 % de cobertura de la org. No se guardó el desglose por clase ni la cobertura de cada clase, así que las filas de arriba citan las pruebas por nombre y no por esa corrida; `scripts/org-check.sh tests` lo vuelve a producir. La anterior fue el 2026-10-09, tras el deploy del PR #68: 157 de 157 sobre 4 clases. El deploy en sí no prueba nada de esto: en `nova-cdo` informa `Running Tests - Skipped` (ver `CONTRIBUTING.md`).

Antes de grabar o repetir esta evidencia, el org tiene que estar limpio: el 2026-10-06 tenía 400 filas de `Log_Senial__c`, todas `Conflicto`, porque el simulador reutiliza `messageId` entre sesiones.

## Recorrido manual del 2026-10-13 (Juan Diego)

Lo que vio cada persona en la app Nova Casa Telemetry con "Iniciar sesión como", sobre los datos que había antes de la limpieza (los números dependen de ellos). Lo anotó Juan Diego; no se guardaron capturas.

| Persona | Qué vio |
|---|---|
| Operador 1 | Solo Nova Alameda (5 activos), en solo lectura: el edificio, el activo y el caso sin botón Edit. Ve los casos de su edificio aunque los haya creado la ingesta. No tiene Registros de Señal ni Umbrales |
| Operador 2 | Solo Nova Caribe (5 activos: 1 crítico, 2 en precaución y 2 estables) y sus 45 casos abiertos. No encuentra Nova Alameda. No tiene Registros de Señal ni Umbrales |
| Coordinador | Los dos edificios y 47 casos abiertos, los mismos en "Todos los casos abiertos" y en la vista "Intervenciones abiertas". Puede editar umbrales (probó una edición y la devolvió al valor original). No tiene Registros de Señal |
| Gerente | Los dos edificios sin poder editarlos. No ve el edificio de prueba ni Umbrales. Puede abrir Informes. No tiene Registros de Señal |

Siguen sin registrar: los pasos 14 y 15 del coordinador (seguimiento y cierre en bloque, sobre un caso desechable), el recorrido del operador 1 por la pantalla (US-207) y la inspección de las cuatro señales como admin (US-209).

Hallazgos del recorrido y qué se hizo con ellos:

- **App por defecto.** La primera sesión de cada persona cae en la app "Servicio" con "No tiene acceso a este registro". No se cambia metadata: se espera que Lightning abra después la última app usada (a comprobar en el ensayo), y `demo.md` pide abrir Nova Casa Telemetry una vez con cada persona antes de la demo.
- **Perfil propio, ícono de la app y reportes del gerente.** Se propusieron; no se hacen ahora. El perfil nuevo cambiaría permisos de cinco usuarios para algo cosmético, `entregables/` no trae logo ni color de marca de Nova Casa, y los reportes no están en el backlog (el gerente ya tiene permiso para correr reportes).
- **Dos intervenciones manuales abiertas en Nova Alameda** (el medidor de energía y la bomba). La limpieza solo borra `Case` con `Origin = 'Telemetria'`, así que se cierran a mano antes de la demo; sirven como casos desechables para los pasos 14 y 15.
