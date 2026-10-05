# Evidence: end-to-end runs of the simulator scenarios (T9.3)

Runs of `TelemetriaIngesta.iniciar('<scenario>', 5)` against `nova-cdo` on 2026-10-05, each one on a cleaned org (logs, readings and Cases with `Origin = 'Telemetria'` deleted first). Counts are from SOQL on `Log_Senial__c.Resultado__c`, `Lectura_Vigente__c` and `Case`. Deploys report 0 tests in this org, so unit evidence is `sf apex run test` (see the PRs).

## Results

| Scenario | Log rows | Readings | Cases | Breakdown of logs |
|---|---|---|---|---|
| `QA_200` (latest, trigger as integration user) | 189 | 10 | 2 | 10 Procesada, 174 Atrasada, 4 Rechazada, 1 Conflicto |
| `QA_200` (first run, trigger as Automated Process) | 189 | 10 | 3 | 17 Procesada, 167 Atrasada, 4 Rechazada, 1 Conflicto |
| `DUPLICATES` | 766 | not recorded | 14 | 154 Conflicto |
| `CRITICAL_BURST` | 955 | not recorded | 51 | not recorded |
| `BOUNDARIES` | 1000 | not recorded | 1 | 53 Procesada, 947 Atrasada |
| `LATE_MESSAGES` | 963 | 9 | 11 | 86 Procesada, 826 Atrasada, 29 Conflicto, 22 Rechazada |

Cells marked "not recorded" were verified against the agreements at the time but the full breakdown was not saved. Re-run the scenario on a clean org to fill them in.

## What was checked against the agreements

- One Case per unique critical message (identity = `source` + `messageId`); each Case is tied to a `Procesada` log row (`LATE_MESSAGES`: 11 Cases, each tied to a `Procesada` row).
- A resend does not update state or open a Case; the same key with different content is a `Conflicto`.
- A late signal is kept as evidence (`Atrasada`) and neither overwrites the current reading nor opens a Case.
- Latest reading is per asset + measurement type.

## Caveats

- **Batch dependence.** A message older than the winner *of its batch* stays `Atrasada` (D011 h), so counts depend on how the Platform Event stream is split into batches. The two `QA_200` rows show it: same 189 messages, 17 vs 10 `Procesada`. The question of whether an older critical message inside the same batch should open a Case is still open with Juan Diego and the facilitator. If the answer changes, `CRITICAL_BURST` and `LATE_MESSAGES` must be re-run.
- **Who ran the trigger.** Only the latest `QA_200` ran with `SenialSensorTrigger` as `novacasa.integracion@novacasa-telemetria.demo` (D017). All other rows ran as Automated Process. Re-run them to have the whole set under the integration user.
- `Conflicto` overwrites `Resultado__c` of the original row. Also pending a decision.
- Scenario runs create real records; they were announced before running and cleaned afterwards. No credentials or org data are stored here.
