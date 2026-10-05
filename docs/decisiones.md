# Decisions and risks (ADR-lite)

Deliverable 6 from Discovery. Every non-obvious decision is recorded here with the alternative we dropped and the trade-off, so nobody — human or AI — reverses it without knowing why it was made.

Not to be confused with the "Acuerdos" section of `Sprint 2 - Nova Casa.md` (verbatim from MDSS): those agreements are **already closed** by the brief/facilitator and are not contradicted without being documented and tested here first. This file is where the pair **proposes and records its own decisions** within those limits.

## How to add an entry

Copy this template, number it sequentially, and keep the status up to date.

```markdown
## D00X — <short title>

- **Status**: Proposed | Accepted | Rejected | Superseded by D0YY
- **Date**:
- **Context**: what problem or ambiguity forces a decision?
- **Decision**: what we do.
- **Rejected alternative**: what other option was considered.
- **Trade-off**: what we gain and what we give up with the chosen decision.
- **Risk / dependency**: what could invalidate this and what it depends on.
- **Test criteria**: which test or check fails if the decision stops holding.
- **Next action**: what is still needed to validate or implement it.
```

---

## D001 — Intervention object: Case

- **Status**: Accepted
- **Date**: 2026-09-29
- **Context**: BR-205/BR-206 require a critical signal to produce an operational intervention that the maintenance coordinator can review and follow up on. The MDSS agreement ("Incidente") requires the behavior (at most one intervention per unique critical message) but doesn't fix which Salesforce object represents it. `CONTRIBUTING.md` already named `Case` as a shared file and talked about "cases" created by the ingestion before this decision was recorded here.
- **Decision**: the intervention is modeled as `Case` (standard object).
- **Rejected alternative**: `Work Order`.
- **Trade-off**: `Case` is enabled in the org with no extra setup and reuses processes, permissions, queues and list views the team already knows. We give up the maintenance-specific fields of `Work Order` (Work Type, Service Appointment), which also require Field Service — not part of the base sprint scope and not worth the cost of enabling and licensing Field Service just for this.
- **Risk / dependency**: if a later phase needs to schedule technician visits or assign field resources, this decision may need to be reopened and Field Service evaluated.
- **Test criteria**: not recorded when the decision was taken.
- **Next action**: none to close the decision; when implementing BR-205/BR-206, check whether `Case` needs custom fields (severity, related asset, message key) and document them in the data model.

## D002 — Names of the simulator connection components (HP-01)

- **Status**: Accepted
- **Date**: 2026-09-30
- **Context**: task T1.1 in the backlog specified creating the External Credential as `Nova_Casa_Simulator_Auth`. What ended up deployed in `force-app` and in the org (`nova-cdo`) for the three connection pieces — External Credential, Named Credential and Permission Set — uses `Nova_Casa_Simulator` (no `_Auth` suffix). After the T1.4/T1.5/T1.6 work, `docs/entendimiento.md` left this as an open question for John.
- **Decision**: keep the name already deployed, `Nova_Casa_Simulator`, for the External Credential and the Named Credential. They are not renamed to match the backlog.
- **Rejected alternative**: rename the components to `Nova_Casa_Simulator_Auth` to match the original T1.1 specification.
- **Trade-off**: renaming an External Credential or Named Credential that is already deployed and connected (BR-201, HP-01 already merged) means recreating the connection and re-resolving the `$Credential.<name>.BearerToken` merge field in the Named Credential — a risk of breaking the authentication already validated, for a purely cosmetic change. Keeping the current name avoids that risk; the cost is that the original backlog (T1.1) stays out of line with reality until it is corrected there.
- **Risk / dependency**: none functional. Any doc or task that still refers to `Nova_Casa_Simulator_Auth` is out of date.
- **Test criteria**: the callout to the simulator authenticates through the `Nova_Casa_Simulator` Named Credential (verified live in T1.4).
- **Next action**: none. The Slack backlog row for T1.1 already records the real name (note dated 2026-09-30).

## D003 — `occurredAt` tie: highest severity wins, then `messageId`

- **Status**: Accepted
- **Date**: 2026-10-01
- **Context**: the Discovery agreement leaves open the rule for when two valid signals for the same `asset` + `measurement.type` arrive with the same `occurredAt` — it requires the rule to be deterministic and forbids arrival order from deciding.
- **Decision**: the reading with the higher resulting severity wins (compared against `Umbral__c` the same way as in normal classification, using the same numeric level that already feeds `Severidad_Nivel__c`). If severity also ties, `messageId` is the second criterion, in ascending alphabetical order (purely deterministic, no business meaning).
- **Rejected alternative**: break the tie with `messageId` alone, without going through severity first — simpler to implement, but it can leave a less severe reading as current when both share a timestamp, which goes against the "see the most critical condition without ambiguity" spirit of Laura's problem. We also rejected marking the case as `Conflicto` without picking a winner: the agreement explicitly asks for a rule that does decide, not one that defers the decision to human review.
- **Trade-off**: the severity rule is more faithful to the product goal, at the cost of depending on severity classification already being resolved in the same processing step (it is not an independent, isolated criterion the way `messageId` alone would be).
- **Risk / dependency**: depends on the thresholds (`Umbral__c`, see the pending item below) having real values before this rule can be implemented and tested with concrete cases.
- **Test criteria**: a test that fails if the tie is resolved by arrival order instead of severity.
- **Next action**: implement in the classification logic (Apex) and cover it with that test.

## D004 — `Umbral__c` is a custom object, not a Custom Metadata Type

- **Status**: Accepted
- **Date**: 2026-10-01
- **Context**: BR-204 asks for classification limits to be manageable without redeploying code. Custom Metadata Type (`__mdt`) is the default option for that kind of configuration data, but its records can only be edited from Setup and require the "Customize Application" system permission — admin-only. The sprint agreement is that a non-admin profile (operator/coordinator) can adjust the thresholds without being given admin access.
- **Decision**: `Umbral__c` is modeled as a standard custom object (`__c`), not as a Custom Metadata Type. Edit access is controlled with FLS/permission set on the object, like any other operational data.
- **Rejected alternative**: `Umbral__mdt` (Custom Metadata Type).
- **Trade-off**: we gain the ability to give a non-admin profile edit access without touching "Customize Application"; we give up what CMDT gives for free (records travel as metadata and deploy on their own between environments, with no Data Loader or data scripts).
- **Risk / dependency**: none functional. The permission set that grants access to `Umbral__c` still has to be defined (see D005/BR-208) so that non-admin editing is real and not just theoretical.
- **Test criteria**: not recorded when the decision was taken.
- **Next action**: when defining the operator/coordinator permission set (D005), include CRUD/FLS on `Umbral__c` for the profile that must be able to adjust the limits.

## D005 — The building is an `Account`; `External_Id__c` for catalog upsert

- **Status**: Proposed (partial — see scope below)
- **Date**: 2026-10-01
- **Context**: BR-208/US-208 require the operator to access only authorized buildings/assets. Today there is no building object in the model (`Asset` models the asset/equipment, not the building that contains it), and Juan Diego needs to identify it for his work in progress. An earlier proposal on this same topic (full sharing: OWD, operator permission set, sharing rules) was recorded and lost when `main` was merged into that branch (PR #9, closed without merging) — it never made it into this file.
- **Decision** (scope of this commit, low risk and reversible): the building is modeled with the standard **`Account`**. `Account.External_Id__c` is added (Text(50), external ID, unique), mirroring `Asset.External_Id__c`, for the building catalog upsert (e.g. `BLD-BOG-01`).
- **Rejected alternative**: custom object `Edificio__c` — a custom object has to earn its place (see "formative frontier" in `AGENTS.md`); the standard `Account` is enough to represent a building.
- **Trade-off**: reuses standard Salesforce sharing and metadata, at the cost of stretching the usual semantics of `Account`.
- **Risk / dependency**: **out of scope for this commit, still pending and unapproved**: the `Asset.Account` lookup, the OWD change (Account = Private, Asset/Lectura_Vigente__c = Controlled by Parent), the `Nova_Casa_Operator` permission set, record-level sharing rules, and `with sharing`/FLS compliance in Apex. The OWD change is hard to reverse — it needs its own PR, agreement from John and Juan Diego, deploy only from `main` (`CONTRIBUTING.md` rule), and MDSS facilitator approval because it touches BR-208. Only the identity field is brought forward here because it is low risk and reversible on its own.
- **Test criteria**: when the rest is implemented, document and test it with two users with different permissions.
- **Next action**: approve the rest of the sharing model (OWD, permission set, sharing rules, `with sharing` Apex) before implementing US-208.

## D006 — Seeding `Umbral__c` from the catalog load (HP-04)

- **Status**: Proposed
- **Date**: 2026-10-05
- **Context**: T3.2 asks for one threshold per catalog combination. `Umbral__c` has no external ID field and `/catalog` delivers `thresholdsReference` as ranges (min/max), not as operator + value.
- **Decision**: `CatalogoService.loadCatalog()` seeds `Umbral__c` from the team's reference table (T2.7), once for each `asset.type` + `measurement` in the catalog (the unit comes from the catalog). If that combination already has any `Umbral__c` (edited, deactivated or not), nothing is seeded for it.
- **Rejected alternative**: a full natural key (type, measurement, severity, operator, value, unit): an edited threshold would stop matching and get duplicated. An external ID field: a model change with no need.
- **Trade-off**: we gain idempotency and respect for what the user changed; we give up the fact that a threshold deleted by hand isn't restored on its own, and new rules aren't added to an already-seeded combination.
- **Risk / dependency**: operators and values are still "to be agreed" (see pending item 1 below); the table lives in code as an initial value, the operational source is the object.
- **Test criteria**: `CatalogoServiceTest` proves the rule: one threshold per combination (`shouldSeedOneThresholdSetPerCombination_WhenCatalogIsValid`), reloading doesn't duplicate (`shouldNotDuplicateThresholds_WhenLoadedTwice`), an edited or deactivated threshold is kept (`shouldKeepEditedThreshold_WhenCatalogIsReloaded`), a partial set isn't completed (`shouldNotCompletePartialSet_WhenCatalogIsReloaded`), and a user without access to `Umbral__c` gets a wrapped `CatalogoServiceException` (`shouldThrowException_WhenRunningAsUserWithoutUmbralAccess`).
- **Next action**: confirm operators and values with the facilitator. Note: seeding these operators and values means the team has in practice already chosen them; they are still pending the facilitator's confirmation.

## D007 — Signal staleness is marked with a presentation parameter (`staleMinutes`), not a threshold

- **Status**: Proposed
- **Date**: 2026-10-05
- **Context**: BR-207 asks the operator to recognize how old the information is. The screen needs a cutoff to mark a signal as "stale". The agreement "Umbrales fuera del código" covers the severity classification limits (D004), not this cutoff.
- **Decision**: the cutoff is a design property of the LWC (`staleMinutes`, default 15), editable in Lightning App Builder for App and Home pages. It only decides whether the "(desactualizada)" mark is shown; it has no effect on severity or on any server-side decision. The default value lives in a single JS constant, with the same value in `js-meta.xml`.
- **Rejected alternative**: a value per asset or measurement type in `Umbral__c` or Custom Metadata. It adds an object or a deployment and there is no agreed per-sensor emission cadence to justify it.
- **Trade-off**: we gain a simple, adjustable screen without touching code or data; we give up a different cutoff per sensor type, so a slow sensor can look "stale" without being so. With the Tab placement there is no configuration and the default applies.
- **Risk / dependency**: if the simulator's real cadence exceeds 15 minutes there will be false "stale" marks. The value must be checked against the simulator's emission cadence.
- **Test criteria**: a signal below the cutoff carries no mark, one above it does, and the Tab placement uses the default.
- **Next action**: validate the 15 minutes against the simulator.

## D008 — The operator screen departs from the low-fidelity prototype

- **Status**: Proposed (point 1 is superseded by D012; point 3 is modified by D012)
- **Date**: 2026-10-05
- **Context**: `entregables/02-prototipo-baja-fidelidad.html` guides the design but is not the specification. The US-207 implementation differs on several points.
- **Decision**: (1) cards use `lightning-card`, badges and SLDS utility icons instead of custom cards and SVG icons; (2) an asset-type filter, a refresh button and the stale-signal mark are added; (3) each card lists one reading per measurement type, instead of a single one; (4) the intervention opens with the "Caso N" link and its status, instead of a "Ver intervención" button; (5) the interface is in Spanish and the controller errors in English; (6) the summary counters cover only the assets in the filtered view and are labeled that way ("en esta vista"); (7) if the controller cap is reached, the screen says so.
- **Rejected alternative**: reproduce the prototype as is; it forces custom components and loses the accessibility and maintainability of the base components.
- **Trade-off**: we gain consistency with SLDS and BR-207 coverage (staleness, filters, states); we give up visual fidelity to the prototype.
- **Risk / dependency**: the MDSS facilitator might ask for the prototype's look. Controller errors in English and the interface in Spanish are inconsistent.
- **Test criteria**: not recorded when the decision was taken.
- **Next action**: show the screen to the facilitator; unify the language of the errors if asked.

## D009 — The operator screen assumes valid readings in `Lectura_Vigente__c` and breaks ties by Id

- **Status**: Proposed
- **Date**: 2026-10-05
- **Context**: the agreement says asset severity is the highest of its latest valid readings. `Lectura_Vigente__c` has no validity field. Also, D003 breaks ties by higher severity and then by `messageId`, a value this object doesn't store.
- **Decision**: (1) `ActivosOperadorController` assumes `Lectura_Vigente__c` only contains valid readings: invalid messages are rejected before writing (T2.12), so the screen doesn't validate again. (2) If two readings of the same asset and type tie on `occurredAt` and severity, the lowest record Id wins, deterministically and without depending on arrival order. It is a read-side safety net: `Clave__c` is unique, so normally there is a single row per key.
- **Rejected alternative**: add a validity field to `Lectura_Vigente__c` or store `messageId` in the reading; it would add data to the model for a case the ingestion already prevents.
- **Trade-off**: a simple screen with no duplicated ingestion logic; we give up defense in depth if the ingestion were to write an invalid reading.
- **Risk / dependency**: depends on the ingestion really rejecting invalid messages and not writing conflicts into `Lectura_Vigente__c`. If that changes, the screen would show a severity based on an invalid reading.
- **Test criteria**: the ingestion tests (T2.12) must fail if an invalid reading reaches `Lectura_Vigente__c`.
- **Next action**: confirm that those tests do fail in that case.

## D014 — Parts of `entregables/` superseded by later decisions

- **Status**: Proposed
- **Date**: 2026-10-05
- **Context**: `entregables/` holds the Discovery deliverables approved by the facilitator. `AGENTS.md` says the prototypes guide the design but aren't the spec, and that any departure from them must be logged here. Several decisions taken since have left parts of the deliverables out of date, with no single place listing them.
- **Decision**: the HTML/PDF deliverables are not edited (they are facilitator-facing and approved). Where they disagree with the repo, the decisions in this file and the code in `force-app/` win. Known superseded points: (1) `04-modelo-de-datos.html` models thresholds as `Umbral__mdt` (Custom Metadata) — superseded by D004, `Umbral__c` custom object; (2) `03-arquitectura-flujo-datos.html` and `03-diagrama-solucion.html` mention `WorkOrder` for the intervention — superseded by D001, `Case`; (3) `04-modelo-de-datos.html` doesn't list `Umbral__c` as an object or `Senial_Sensor__e`; (4) `02-prototipo-baja-fidelidad.html` — see D008/D012 for the operator screen.
- **Rejected alternative**: edit the deliverables to match the current model; it rewrites approved documents and `mdss-verbatim-guard` treats `entregables/` as untouchable without agreement.
- **Trade-off**: we keep the approved deliverables intact; we give up a single consistent set of documents, so readers must check this entry.
- **Risk / dependency**: the list above comes from a keyword scan of the HTML files, not a full read; other departures may exist. `entregables/01-entendimiento-del-problema.pdf` was not compared.
- **Test criteria**: none (documentation). Reviewing this list is part of preparing each demo.
- **Next action**: complete the list when another decision departs from a deliverable; ask the facilitator whether updated versions of the deliverables are expected.

## Pending items inherited from the "Acuerdos" section (open since Discovery, not closed in Development)

These points each needed a D00X entry before closing Discovery deliverable 6. The deliverable was approved and we are now in Development (see `AGENTS.md`), but only the intervention object (D001), the simulator connection names (D002), the `occurredAt` tie (D003) and the `Umbral__c` object type (D004) are accepted; the building (D005 above) has an entry but only resolves the identity field, not the sharing model. Still open:

1. Exact operators and values of the threshold per `asset.type` + `measurement.type` (they go in metadata, not in code).
2. Sharing model of buildings/assets for the operator (BR-208) — partial: D005 defines the building as `Account`, but the OWD, the `Nova_Casa_Operator` permission set, the sharing rules and `with sharing`/FLS in Apex are still pending and unapproved (see D005, "Risk / dependency").

## General sprint risks

- **Facilitator dependency**: every deliverable requires external approval; a slow review cycle can block progress to Development.
- **Ambiguity of "invalid message"** (BR-202): without a closed definition, the invalid example that deliverable 5 (message contract) asks for is still to be written.
- **Formative frontier vs. available time**: Platform Events + bulkified Apex + LWC + security + tests in 2 weeks is ambitious; prioritize Laura's path (the reference story) over exhaustive coverage.
