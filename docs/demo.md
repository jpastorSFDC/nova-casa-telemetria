# Demo script (T9.2)

End-to-end walkthrough of the reference story in `Sprint 2 - Nova Casa.md`: Sara, a building operator (Operador Nova Casa user), starts her shift, sees which equipment needs attention, the critical signal opens a single intervention, the resend doesn't open another one and the late reading doesn't replace the current one. Then each role sees its own data.

Duration: about 14 minutes, plus preparation. The evidence by story is in [evidencia-escenarios.md](evidencia-escenarios.md#evidence-by-story-t93).

## Before the demo (not timed)

1. **Post in Slack** who runs the ingestion and at what time. Juan Diego (or John) runs it with their own user: both have `Nova_Casa_Admin` and `Nova_Casa_Simulator_Integration`. `novacasa.admin@` doesn't have `Nova_Casa_Simulator_Integration`, so "Traer señales" with that user fails. One run at a time.
2. **Clean org**, as the README says in "Cleaning the org before a demo or a recorded run". The cleanup only deletes telemetry `Case` records: interventions created by hand (`Origin` other than `Telemetria`) stay open, so close them by hand before the demo if you don't want them to show up. For backup runs: `scripts/org-check.sh run <ESCENARIO>`, `wait <desde>` and `evidence`.
3. **Catalog loaded** (README, "Loading the building/asset catalog"): `CatalogoService.loadCatalog();` from Execute Anonymous. Afterwards, the "Building owners" query in `docs/acceso.md` should come back empty: BLD-BOG-001 (Edificio Nova Alameda) belongs to `novacasa.operador@` and BLD-BAQ-001 (Edificio Nova Caribe) to `novacasa.operador2@`. BLD-TEST-NOAUT (Edificio de prueba, fuera de jerarquía) is still owned by Juan Diego, with no assets.
4. **Persona users** (`docs/acceso.md`, "Personas"), all `@novacasa-telemetria.demo` and active: `novacasa.operador`, `novacasa.operador2`, `novacasa.coordinador`, `novacasa.gerente`, `novacasa.admin`. "Log in as" is already enabled in the org (T8.7). Try it once with each one and open the **Nova Casa Telemetry** app at least once: on 2026-10-13, each persona's first session landed in the "Servicio" app with "No tiene acceso a este registro", and Lightning then opens the last app used (to be checked in the rehearsal).
5. **Tests run the same day**, with the result at hand (step 9):

   ```bash
   sf apex run test --class-names SenialSensorHandlerTest --class-names IntervencionServiceTest --class-names TelemetriaIngestaTest --class-names ActivosOperadorControllerTest --class-names IntervencionOperadorControllerTest --class-names PermisosProcesamientoTest --class-names UmbralValidadorTest --code-coverage --result-format human --wait 15
   ```

6. **Tabs open** in the presenter's browser: Setup > Users, Setup > Apex Jobs, Developer Console (Execute Anonymous) and the **Nova Casa Telemetry** app.

## Script

| # | Min | Who | What it shows | BR / US |
|---|---|---|---|---|
| 1 | 1 | Presenter | The problem and the reference story | — |
| 2 | 2 | Juan Diego (admin) | Real reception and processing | BR-201, BR-202 · US-201, US-202 |
| 3 | 3 | Sara (Operador Nova Casa) | Operator screen, severity, filters, states | BR-206, BR-207, BR-208 · US-206, US-207, US-208 |
| 4 | 1.5 | Juan Diego + Sara | A single intervention; the resend doesn't open another one | BR-205 · US-205 |
| 5 | 1 | Juan Diego (admin) | The late signal doesn't replace the current one | BR-203 · US-203 |
| 6 | 1.5 | Coordinator | Open interventions, follow-up and thresholds | BR-204, BR-205 · US-204, US-205 |
| 7 | 1.5 | Manager and Operator 2 | Each one sees only what they're authorized to see | BR-208 · US-208 |
| 8 | 1.5 | Juan Diego (admin) | Why a signal was rejected and whether it's safe to retry | BR-209 · US-209 |
| 9 | 1 | Presenter | Automated tests | BR-210 |

### 1. Context (1 min)

- Today each vendor has its own portal and the operator finds out late. Read the reference story aloud (`Sprint 2 - Nova Casa.md`, "Historia de referencia"): Sara, an operator with two buildings, a pump with low pressure, a resend and an old reading.
- Show the flow in one sentence: simulator → `Senial_Sensor__e` (Platform Event) → `SenialSensorTrigger` as the integration user → `Lectura_Vigente__c`, `Log_Senial__c` and `Case` → "Activos del operador" screen.

### 2. The signals arrive (2 min) · BR-201, BR-202

1. Developer Console > Debug > Open Execute Anonymous Window, with Juan Diego's user:

   ```apex
   TelemetriaIngesta.iniciar('QA_200', 42, 200, 5); // scenario, seed, batch size, pages
   ```

2. Setup > Apex Jobs: the `TelemetriaIngesta` job shows up as `Completed`; a single job reads several pages (D025).
3. Nova Casa Telemetry app > **Registros de Señal** tab (only the admin sees it), then pick the **Todas las señales** view (the tab may open on another view; confirm it during the browser check). You can also get there by URL: `/lightning/o/Log_Senial__c/list?filterName=Todas_las_senales`.

**What the audience should see**

- Each message has a row with its identity (`source|messageId`), `Occurred_At__c` (at origin), `Publicado_At__c` and `Procesado_At__c`: publishing isn't processing.
- Rows go from `Publicada` to `Procesada` without anyone creating anything by hand.
- A few rows stay `Rechazada` with `Motivo__c` and the rest carry on: one bad signal doesn't bring down the batch. In the `QA_200` run on 2026-10-05 it was 4 of 189.

### 3. Sara starts her shift (3 min) · BR-206, BR-207, BR-208

1. Setup > Users > `novacasa.operador@…` > **Login**.
2. **Nova Casa Telemetry** app > **Activos del operador** tab.

**What the audience should see**

- Only **BLD-BOG-001, Edificio Nova Alameda** shows up. Nothing from BLD-BAQ-001 or BLD-TEST-NOAUT.
- The banner and the per-building summary say how many assets are in Crítica, Precaución or Sin dato. The asset's severity is the highest of its latest readings.
- While it loads, the "Cargando activos" skeleton shows (**Actualizar** button).
- Filter by **Severidad** = Crítica, then by **Edificio**. Pick a combination with no results: "Ningún activo coincide con esos filtros" and **Limpiar filtros**. That's different from "Sin lecturas todavía", which is an asset with no data.
- Each card shows the reading's origin date and the "(desactualizada)" mark if it's past the 15-minute cutoff (D007).
- **Ver activo**: the detail shows the current reading by measurement type (temperature doesn't overwrite pressure) and, if it's critical, the intervention as "Caso N", which opens the `Case`.
- Sara doesn't have "Actualizar seguimiento" or "Ver límites"; she does have "Crear intervención" for an asset with no open intervention (D020).

If the pump didn't come out critical in the run, carry on with whatever critical asset there is: the walkthrough is the same.

### 4. A single intervention, even if it arrives twice (1.5 min) · BR-205

1. First, as Juan Diego: Cases > **Intervenciones abiertas** list view. Write down the number of Cases.
2. Repeat the same run, with the same seed:

   ```apex
   TelemetriaIngesta.iniciar('QA_200', 42, 200, 5);
   ```

3. When the jobs finish, go back to **Intervenciones abiertas** and open `/lightning/o/Log_Senial__c/list?filterName=Duplicadas`.

**What the audience should see**

- The number of Cases in **Intervenciones abiertas** doesn't change.
- In **Duplicadas (reenvíos)** the rows have `Reenvios__c` > 0 and `Ultimo_Reenvio__c`. The result (`Procesada`) and the Case (`Caso__c`) stay the same.
- If the simulator doesn't repeat the same content with that seed, the same key arrives with different content and the row stays `Conflicto` (**Conflictos** list view), also with no new Case. Both are what the "Mensaje repetido" agreement asks for.
- Back as Sara, **Actualizar**: the card still shows a single "Caso N".

### 5. An old reading isn't the current condition (1 min) · BR-203

1. `/lightning/o/Log_Senial__c/list?filterName=Atrasadas`. Open a row and its asset.

**What the audience should see**

- The `Atrasada` row has an `Occurred_At__c` older than the current reading for the same asset and measurement type, and its reason says so.
- The current reading didn't change and the row has no Case, even if its value is critical.
- In a full run almost every row ends up `Atrasada`: that's expected from D011 (h), because only the most recent one per asset and measurement in the batch wins (John's decision of 2026-10-05; the MDSS facilitator hasn't confirmed it).

`LATE_MESSAGES` shows the same thing with more examples, but it needs a clean org again (the `messageId` values repeat across scenarios). Its run is in `evidencia-escenarios.md`.

### 6. The coordinator organizes the work (1.5 min) · BR-204, BR-205

1. Setup > Users > `novacasa.coordinador@…` > **Login**.
2. Cases tab > **Intervenciones abiertas** list view.
3. **Activos del operador** tab > a critical asset > **Actualizar seguimiento** (status On Hold, with a comment) > **Guardar**. If the asset has several open interventions, the **Cerrar las N abiertas** button closes them all at once, up to 200 at a time (D035).
4. **Ver límites** (or Umbrales tab > **Nova Casa - Umbrales**).

**What the audience should see**

- All open interventions for both buildings in one place, one per critical message.
- The coordinator can change the intervention's status; Sara couldn't.
- The thresholds per asset type and measurement are `Umbral__c` records that the coordinator edits without deploying code. A contradictory range (Advertencia GT 40 with Crítica GT 35) is rejected on save (D018). Don't change a threshold in the demo without putting it back the way it was; the test that proves a change alters the next classification is `SenialSensorHandlerTest` (step 9).

### 7. Everyone sees their own data (1.5 min) · BR-208

1. Setup > Users > `novacasa.gerente@…` > **Login** > **Activos del operador**, and Accounts tab > **Nova Casa - Edificios**.
2. Setup > Users > `novacasa.operador2@…` > **Login** > **Activos del operador**.

**What the audience should see**

- The manager sees **BLD-BOG-001 and BLD-BAQ-001** and the per-building summary to compare them, without "Crear intervención", "Actualizar seguimiento" or "Ver límites": read-only.
- **BLD-TEST-NOAUT** doesn't show up in **Nova Casa - Edificios**: nobody in the hierarchy sees it (D022).
- Operator 2 sees only **BLD-BAQ-001, Edificio Nova Caribe**, the opposite of Sara.
- The restriction is also on the server: the controller is `with sharing` and queries in `USER_MODE`. This is proven by `ActivosOperadorControllerTest.operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth` and the `UserRecordAccess` queries in `docs/acceso.md`.

### 8. The administrator investigates (1.5 min) · BR-209

With Juan Diego's user (or `novacasa.admin@…` via Login).

1. `/lightning/o/Log_Senial__c/list?filterName=Rechazadas`, then `Conflictos` and `Fallidas`.
2. Look up a signal by its identity in global search.

**What the audience should see**

- Each row shows its result, the **Motivo** and the **Acción de reintento** (`Accion_Reintento__c`, D014): a `Rechazada` row says "No: corregir el dato en origen…", a `Fallida` row says "Sí: reintentar…", a processed row says "No hace falta".
- Retrying means running the ingestion again: the identity prevents a duplicate Case (step 4).
- There's no token, cursor or secret in any row. The log is admin-only: the operator, the coordinator and the manager have no access to `Log_Senial__c`.

### 9. Quality (1 min) · BR-210

Show the result of the `sf apex run test` from the preparation (`Tests Ran`, `Pass Rate`, coverage per class). Name the tests that fail if what the audience just saw breaks:

- Classification and boundary: `tresValoresRepresentativosDeTemperaturaSonNormalAdvertenciaYCritica`, `operadorGTUnValorIgualAlLimiteNoLoCumpleYElSiguienteSi`, `editarElLimiteDeUnUmbralCambiaLaClasificacionSinTocarElHistorico`.
- Duplicates and conflict: `unReenvioIgualSoloSumaReenviosSinTocarLecturaNiCase`, `mismaIdentidadConOtroContenidoEsConflictoSinCambiarEstado`, `IntervencionServiceTest`.
- Volume: `doscientosEventosEnUnLoteUsanUnNumeroFijoDeConsultasYDml`.
- Time order: `unaSenialMasAntiguaQueLaVigenteQuedaAtrasadaAunqueSeaCritica`, `elDesempateD003NoDependeDelOrdenDeLlegada`.
- Security: `ActivosOperadorControllerTest`, `PermisosProcesamientoTest`.

Wrap-up: what's still missing is in the evidence table, Status column.

## If something goes wrong

| What happens | What to do |
|---|---|
| The simulator doesn't respond or a job ends up `Failed` in Apex Jobs | Read the error in Apex Jobs. Run the same `iniciar` again: the identity prevents duplicates (D013, point 8). If it keeps failing, show the saved run in `evidencia-escenarios.md` and the data already in the org. |
| Everything comes out as `Conflicto` or resend | The org wasn't clean. Show **Conflictos** and **Duplicadas (reenvíos)** as proof of BR-205 and carry on with whatever data there is. |
| No critical signal came out, or no new Case | The result depends on how the batches are split (D011 h, not confirmed by the facilitator). Show a `CRITICAL_BURST` run in `evidencia-escenarios.md` (each Case with its `Procesada` row). |
| "Traer señales" gives an error | `novacasa.admin@` is missing `Nova_Casa_Simulator_Integration`. Use Execute Anonymous with Juan Diego's user. |
| "Login" doesn't show up in Setup > Users | Check "Administrators Can Log in as Any User". If that's not possible, show the `UserRecordAccess` tables in `docs/acceso.md`. |
| The screen says "No pudimos cargar tus activos" | **Reintentar**. If it persists, the user is missing permissions (FLS): it shows as the error state BR-207 asks for, and you carry on with another role. |
| The run is slow | Pages are requested back to back, without waiting for `pollAfterMs` (D025); the 10-page runs on 2026-10-14 took up to 72 s in the job and 77 s until the last processed row. Use `QA_200` with few pages. |

Runs create real records. Don't delete what someone else created; cleanup is agreed on in Slack.
