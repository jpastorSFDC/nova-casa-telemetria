# Access matrix (US-208)

T8.1. Who sees and does what, and where each access comes from (BR-208). Effective access is always the intersection of two things: the object/field permission (permission set or profile) and record access (OWD, ownership, role hierarchy or View All). The model of the building as `Account` comes from [D005](decisiones.md#d005--the-building-is-account-external_id__c-for-catalog-upsert).

**Status as of 2026-10-07**: OWD Private applied (T8.2, PR #38), the persona users on Minimum Access - Salesforce, each building owned by an operator, and the manager without View All ([D022](decisiones.md#d022--coordinator-and-manager-see-through-the-role-hierarchy-each-building-belongs-to-one-operator-personas-on-minimum-access-us-208)). What's left is in "Order of steps", step 7.

**Since then**: the personas were walked through by hand on 2026-10-13 ([entrega.md](entrega.md#manual-walkthrough-of-2026-10-13)). The `UserRecordAccess` queries were not repeated after the manager lost View All.

## Personas

| Persona | Demo user | Role | Permission sets | How it reaches the records |
|---|---|---|---|---|
| Operator | `<operator-username>` | Operador de Edificios | `Nova_Casa_Operator`, `Nova_Casa_Lightning` | Owns (`OwnerId`) the `Account` of their building (BLD-BOG-001) |
| Operator 2 | `<operator-2-username>` | Operador de Edificios | `Nova_Casa_Operator`, `Nova_Casa_Lightning` | Owns BLD-BAQ-001 (T8.4, two operators with different buildings) |
| Coordinator | `<coordinator-username>` | Coordinador de Mantenimiento | `Nova_Casa_Coordinator`, `Nova_Casa_Lightning` | Role hierarchy: sees the operators' buildings and what Integration owns |
| Regional manager | `<manager-username>` | Gerente Regional de Operaciones | `Nova_Casa_Gerente`, `Nova_Casa_Lightning` | Role hierarchy (everything the coordinator, operators and integration own) read-only, plus Run Reports |
| Administrator (persona) | `<admin-username>` | none | `Nova_Casa_Admin`, `Nova_Casa_Operator`, `Nova_Casa_Lightning` | Create, Read, Edit, Delete, View All and Modify All on `Account`, `Asset`, `Case`, `Contact`, `Lectura_Vigente__c`, `Log_Senial__c` and `Umbral__c` |
| Integration | `<integration-username>` | Integración Telemetría | `Nova_Casa_Simulator_Integration`, `Nova_Casa_Procesamiento` ([D017](decisiones.md#d017--nova_casa_procesamiento-permission-set-for-the-integration-user-t210), T2.10) | Owns the `Case` and `Log_Senial__c` records it creates |

The persona admin has no role: View All / Modify All already gives them every record, and a role would put them in the operating hierarchy for no reason. `Account`, `Asset`, `Case` and `Contact` are standard objects, so `Nova_Casa_Admin` reaches every record of those objects in the org, not only the Nova Casa ones.

The second operator is org data, not metadata in the repo. It was created on 2026-10-06 with the Minimum Access - Salesforce profile, role `Operador_Edificios`, alias `ncoper2`, locale `es_CO`, time zone `America/Bogota`, and the permission sets `Nova_Casa_Operator` and `Nova_Casa_Lightning`; then it was given the `OwnerId` of BLD-BAQ-001 (previously John's). The BAQ `Asset` and `Case` records didn't change owner (`Asset` is Controlled by Parent). To reproduce it without publishing the org username:

```bash
sf data create record -o nova-cdo -s User -v "Username='<operator-2-username>' FirstName='Operador 2' LastName='Nova Casa' Alias='ncoper2' Email='<email>' TimeZoneSidKey='America/Bogota' LocaleSidKey='es_CO' LanguageLocaleKey='es' EmailEncodingKey='UTF-8' ProfileId='<Id de Minimum Access - Salesforce>' UserRoleId='<Id de Operador_Edificios>'"
sf org assign permset -o nova-cdo -n Nova_Casa_Operator -n Nova_Casa_Lightning -b <operator-2-username>
sf data update record -o nova-cdo -s Account -w "External_Id__c='BLD-BAQ-001'" -v "OwnerId='<Id de operador2>'"
```

**Unauthorized building (T8.6)**: `Edificio de prueba (fuera de jerarquía)`, `External_Id__c` `BLD-TEST-NOAUT`, owned by Juan Diego (System Administrator, no role), no assets. Nobody in the hierarchy should see it: it's the test record for coordinator and manager. It doesn't clash with the catalog, which only upserts the `External_Id__c` values the simulator sends.

- **Manager** ([D022](decisiones.md#d022--coordinator-and-manager-see-through-the-role-hierarchy-each-building-belongs-to-one-operator-personas-on-minimum-access-us-208)): Read on `Account`, `Asset`, `Case`, `Contact` and `Lectura_Vigente__c`, without View All, Create, Edit, Delete or Modify All, and Run Reports without Export. They see all buildings because each one belongs to an operator, who is below them in the hierarchy. A report only shows them what they can see.
- **Coordinator**: no View All. They see the operators' buildings through the hierarchy and all interventions because the integration user creates them, and that user is also below them. If a building doesn't belong to an operator but has integration Cases, they see it read-only through implicit parent sharing.

## Role hierarchy

```
Gerente Regional de Operaciones
└── Coordinador de Mantenimiento
    ├── Operador de Edificios
    └── Integración Telemetría
```

Integración sits under Coordinador so that the Cases and logs the integration user creates are visible to coordinator and manager without opening up the OWD.

Building owner's access to child objects (the role's `caseAccessLevel` / `opportunityAccessLevel` / `contactAccessLevel`), target values. The role files declare only the Case and Opportunity levels; the Contact column is what the role would carry if Contact were Private, and it is not deployed because Contact stays Controlled by Parent (see below):

| Role | Case | Opportunity | Contact |
|---|---|---|---|
| Gerente Regional de Operaciones | Read | None | Read |
| Coordinador de Mantenimiento | Edit | None | Read |
| Operador de Edificios | **Read** | None | Read |
| Integración Telemetría | None | None | None |

The operator stays at **Read**: `Nova_Casa_Operator` is read-only and follow-up on the intervention belongs to the coordinator. Edit on the role wouldn't change anything today (the object permission limits it to read) and would open up editing by accident if the operator is ever given Edit on `Case`. If the operator has to follow up on interventions, both change at the same time. Contact only applies if Contact stays Private; the plan is Controlled by Parent.

The role files declare Case and Opportunity since T8.2; Contact isn't declared because it stays Controlled by Parent. They go in a second deploy, after the OWD one: while the OWD is still public, the platform rejects any value below it ("Opportunity access level below organization default", seen in the T8.2 dry-run).

## Matrix by object

C/R/E/D = Create/Read/Edit/Delete from the permission set; after the dot, where record access comes from.

| Object | OWD before → after T8.2 | Operator | Coordinator | Manager | Admin (persona) | Integration (`Nova_Casa_Procesamiento`) |
|---|---|---|---|---|---|---|
| `Account` (building) | Public Read/Write → **Private** | R · owner | R · hierarchy | R · hierarchy | CRED · Modify All | R · View All |
| `Asset` | Controlled by Parent (no change; inherits Private from `Account`) | R · via building | R · via building | R · via building | CRED · Modify All | R · View All |
| `Lectura_Vigente__c` | Controlled by Parent (no change) | R · via asset | R · via asset | R · via asset | CRED · Modify All | CRE |
| `Case` (intervention, [D001](decisiones.md#d001--intervention-object-case)) | Public Read/Write/Transfer → **Private** | R · Cases of their building (role) | RE · hierarchy | R · hierarchy | CRED · Modify All | CRE · View All · owner of what it creates |
| `Log_Senial__c` | Private (no change) | — | — | — | CRED · Modify All | CRE · owner of what it creates |
| `Umbral__c` | Public Read Only → **Public Read/Write** | — | CRE | — | CRED · Modify All | R |
| `Contact` / `Opportunity` | Controlled by Parent (no change) / Public Read Only → **Private** | R / — | R / — | R / — | CRED · Modify All / — | R / — |
| `Senial_Sensor__e` (platform event) | n/a | — | — | — | — (see "Actions") | CR |

`Asset` and `Contact` were already Controlled by Parent in the metadata (and `Organization.DefaultContactAccess`); `EntityDefinition` showed them as Public Read/Write because it reports the effective value they inherit from `Account`. `Opportunity` and `Case` move to Private because they can't stay more open than `Account`.

`Umbral__c` moves to Public Read/Write because with Read Only the coordinator can only edit the thresholds they created (the baseline shows it: Read, not Edit, on a threshold seeded by another user), and that defeats [D004](decisiones.md#d004--umbral__c-is-a-custom-object-not-a-custom-metadata-type). Who can edit is still decided by the object permission: only Coordinator and Admin have it, and the object keeps field history.

## Fields (FLS)

- **Everyone who sees `Lectura_Vigente__c`** sees its required fields (`Asset__c`, `Tipo_Medicion__c`, `Valor__c`, `Unidad__c`, `Occurred_At__c`): the platform doesn't allow FLS on required fields.
- **Operator**: read on `Asset.AccountId`, `Asset.Tipo_Activo__c`, the `Asset` summaries (`Severidad_Actual__c`, `Severidad_Nivel__c`, `Ultima_Senal__c`), `Case.AssetId`, `Case.Subject`, `Case.ClosedDate`, `Lectura_Vigente__c.Sensor_Id__c`, `Lectura_Vigente__c.Severidad_Nivel__c`, `Lectura_Vigente__c.Severidad__c`, the read-only summary fields listed below and the technical keys. `Case.ClosedDate` is read-only and the coordinator, manager and `Nova_Casa_Admin` have it too (D038): the operator screen queries it in `USER_MODE` for the "Última intervención" line, so without that FLS the list shows the access error as soon as an asset on the page has no open intervention.
- **Read-only summary fields** (D029, D039): operator, coordinator, manager and `Nova_Casa_Admin` read `Asset.Minutos_Sin_Senal__c`, `Case.Edificio__c`, `Case.Tipo_Activo__c`, `Case.Severidad_Activo__c`, `Case.Tiempo_Abierto_Horas__c`, `Lectura_Vigente__c.Edificio__c` and `Lectura_Vigente__c.Antiguedad_Minutos__c` (formulas), and `Case.Ultima_Critica_At__c`, `Ultima_Critica_Medicion__c`, `Ultima_Critica_Unidad__c` and `Ultima_Critica_Valor__c` (the latest critical signal, written by ingestion). `Nova_Casa_Admin` also reads `Case.Ultima_Critica_Identidad__c`. Only `Nova_Casa_Procesamiento` edits the `Ultima_Critica_*` fields.
- **Intervention page (D043)**: operator, coordinator, manager and `Nova_Casa_Admin` read `Case.Origin` and `Case.Priority` (read-only). `Case.Description` is read and edited by the coordinator and `Nova_Casa_Admin`; the others don't see it, and the page omits the last follow-up and the reason.
- **Coordinator**: what the operator has, plus edit on `Umbral__c.Activo__c` and `Case.Description`, and read on `Umbral__c.Severidad_Nivel__c` and `Umbral__c.Descripcion__c`.
- **Manager**: what the operator has. Nothing editable.
- **Technical keys** (`Account.External_Id__c`, `Asset.External_Id__c`, `Lectura_Vigente__c.Clave__c`, and `Identidad_Senal__c` on `Case` and `Lectura_Vigente__c`): read-only for operator, coordinator and manager (aligned with PR #26). `Nova_Casa_Admin` edits all five. `Nova_Casa_Procesamiento` edits `Lectura_Vigente__c.Clave__c` and `Identidad_Senal__c` on both objects, because ingestion writes them, and only reads the two `External_Id__c`. The operator screen queries `Asset.External_Id__c` in `USER_MODE`, so without that FLS it shows an access error; the other four are for the `Case`, `Account` and `Lectura_Vigente__c` layouts.
- **Only Admin among the personas**: all of `Log_Senial__c`. `Nova_Casa_Procesamiento` also holds Create, Read and Edit on it, because ingestion writes the log, and has no tab. Exception (D024): operator, coordinator and manager see the "Historial de señales" in the asset detail (signal type, origin date, result and, since D034, measurement type, value and unit) for the assets they already see, read by Apex without giving them any permission on the object. The same on the intervention page (D043): the signals linked to an intervention they see, and only if they also see its asset, with the resends and which one opened it. And on the building and asset pages (D045): the signal that opened each intervention they see (measurement type, value, unit and origin time), only if they also see its asset; for that, `Case.Ultima_Critica_Identidad__c` and the log row of that same asset are read in system mode, and the identity is never returned.

## Actions

Everyone sees the same "Activos del operador" screen and the same data from the records their access lets them see; what changes is the actions. Each action on the screen sits behind a custom permission or an object permission, and the server checks it again (D020).

| Action | Operator | Coordinator | Manager | Admin | Authorization |
|---|---|---|---|---|---|
| See assets, readings, open intervention and summary by building | yes | yes | yes | yes | Tab + `classAccesses` to `ActivosOperadorController`; the controller is `with sharing` and queries in `USER_MODE` |
| See an asset's signal history (without reason or technical detail) | yes | yes | yes | yes | `ActivosOperadorController.getHistorial`: checks the asset in `USER_MODE` and reads the log in system mode (D024) |
| See which signal opened an intervention (building and asset pages) | yes | yes | yes | yes | `ActivosOperadorController.getAperturasDeIntervencion`: checks the Case and its asset in `USER_MODE`, then reads the opener in system mode (D045) |
| Create a manual intervention (operator screen detail or asset page) | yes | yes | no | yes | Custom permission `Nova_Casa_Crear_Intervencion`. Creation runs in system mode because the operator doesn't have Create on `Case`; the custom permission is their only key (D020). Interventions for critical signals are created by ingestion |
| Change an intervention's status, or bulk close an asset's open ones | no | yes (also needs Edit on `Case`) | no | yes | Custom permission `Nova_Casa_Seguir_Intervencion` (D035). The status options are the active values of `Case.Status` (D036); everyone who can open an intervention reads the list (operator, coordinator and admin through `IntervencionOperadorController.getEstadosSeguimiento`; the manager, who has no access to that class, through the `estados` of `ActivosOperadorController.getIntervencion`), but only someone with the permission can change the status |
| Change thresholds ("Ver límites") | no | yes (create and edit) | no | yes (everything) | CRUD on `Umbral__c` in the permission set; requires the Public Read/Write OWD from the matrix by object |
| Fetch signals from the simulator | no | no | no | yes (also needs `Nova_Casa_Simulator_Integration` and Create on `Senial_Sensor__e`) | Custom permission `Nova_Casa_Traer_Senales`. `Nova_Casa_Admin` doesn't include Create on `Senial_Sensor__e`: among the Nova Casa permission sets only `Nova_Casa_Procesamiento` has it, so the person pressing the button needs it from somewhere else |
| See technical errors and rejection reason | no | no | no | yes | `Log_Senial__c` only in `Nova_Casa_Admin`; the "Registros de Señal" tab of the Nova Casa Telemetry app is declared visible only in that permission set (`tabSettings`); without Read on the object nobody else gets to the data even if they see the tab. Measured in the org on 2026-10-07 (`ObjectPermissions`): Read on `Log_Senial__c` only in `Nova_Casa_Admin`, `Nova_Casa_Procesamiento` and Salesforce's administration and integration profiles or permission sets; no Operator, Coordinator or Manager permission set has it. Whether the Minimum Access profile hides the tab is checked in the org after the deploy |
| Know whether a signal can be retried, and retry it | no | no | no | yes | The `Accion_Reintento__c` column of `Log_Senial__c` (read-only formula, read-only FLS in `Nova_Casa_Admin`, D014) says whether the retry is safe or what to fix first. Retrying means running ingestion again ("Traer señales"), which requires the custom permission `Nova_Casa_Traer_Senales` plus `Nova_Casa_Simulator_Integration` and Create on `Senial_Sensor__e` (header of `IngestaController`). The unused `Reintento_Seguro__c` checkbox was removed (#95) after the 2026-10-19 production preflight found no record with it set to `true`. |

Processing doesn't use any of these permissions: `SenialSensorTrigger` runs as the integration user with `Nova_Casa_Procesamiento` (T2.10), separate from the operator. Fetching and publishing the signals runs as whoever starts or schedules it, who needs `Nova_Casa_Simulator_Integration` and Create on `Senial_Sensor__e` (see "Fetch signals from the simulator").

## Order of steps

1. **T2.10** (done): create the integration user with the Integración Telemetría role and its ingestion permission set. Verified on 2026-10-06: the active Nova Casa integration user has role `Integracion_Telemetria`, profile Minimum Access - Salesforce, `Nova_Casa_Simulator_Integration` and `Nova_Casa_Procesamiento`.
2. **T2.2** (done): `PlatformEventSubscriberConfig` so the trigger runs as that user. `Nova_Casa_Procesamiento` (PR #28) runs `SenialSensorTrigger` as that user, with batch size 200. The last Automated Process Case is from 2026-10-05 18:07Z; since 18:14Z the new `Case` and `Lectura_Vigente__c` records are created by the integration user (65 Cases up to 21:48Z, counting the ones deleted in the cleanup). With OWD Private, coordinator and manager see those `Case` records through the hierarchy because the integration user is below the coordinator. The `Lectura_Vigente__c` records don't: they're Controlled by Parent and visible through the building, so they depend on who owns the `Account` (D022), not on who creates them.
3. **T8.2** (done, PR #38): in a single deploy, `sharingModel` of `Account` Private, `Contact` ControlledByParent, `Opportunity` Private, `Case` Private, `Asset` ControlledByParent and `Umbral__c` ReadWrite. Then, a redeploy of the roles with the levels from the table above.
4. **Profile** (done 2026-10-06): the four persona users on Minimum Access - Salesforce with `Nova_Casa_Lightning` (see below).
5. **T8.6** (done 2026-10-06): queries repeated before and after the profile change, see "Result (T8.6)".
6. **Second operator and owners** (done 2026-10-06, D022): the second operator was created and made owner of BLD-BAQ-001; BLD-TEST-NOAUT was created as a building outside the hierarchy.
7. **Manager without View All** (permissions done, verified 2026-10-07): `Nova_Casa_Gerente` deployed with the rest of `main`; a query on `ObjectPermissions` in `nova-cdo` returned read-only (`PermissionsViewAllRecords`, `ModifyAll`, `Edit`, `Create` and `Delete` false) on `Account`, `Asset`, `Case`, `Contact` and `Lectura_Vigente__c`. Checked by hand on 2026-10-13 ([entrega.md](entrega.md#manual-walkthrough-of-2026-10-13)): the manager saw both buildings read-only and not the test building. Pending: repeat the `UserRecordAccess` queries from "Hierarchy instead of View All (D022)", which that walkthrough didn't do.

## Minimum Access profile

The persona users had the Standard User profile, which gives CRED on `Account`, `Asset`, `Contact` and `Opportunity`, and CRE on `Case`. Permission sets only add, so the operator could edit or delete buildings even though `Nova_Casa_Operator` is read-only. Now they're on Minimum Access - Salesforce, which gives neither object access nor Lightning Experience; `Nova_Casa_Lightning` adds only `LightningExperienceUser`. The standard `Account`, `Asset`, `Case` and Reports tabs already come as DefaultOn in that profile (org state: the versioned profile file carries only layout assignments and a few user permissions, no `tabVisibilities`, so the repo can't confirm it). `Nova_Casa_Gerente` still declares `standard-Account`, `standard-Asset` and `standard-Case` as Visible, so it doesn't depend on the profile; the other permission sets don't declare them and depend on Minimum Access.

The profile and the assignments are org data, not metadata. To reproduce them, use the operator, coordinator, manager and admin usernames from Setup; the integration user was already on Minimum Access:

```bash
sf data update record -o nova-cdo -s User -w "Username='<username>'" -v "ProfileId=<Id de Minimum Access - Salesforce>"
sf org assign permset -o nova-cdo -n Nova_Casa_Lightning -b <username>
```

To revert, run the same `sf data update record` with the Standard User `ProfileId`.

**Layouts by profile (D026).** Minimum Access came with no page layout assignment, and the persona users saw "One or more profiles have no page layout assigned" when opening a `Case` or an `Asset` (the admin didn't, because their profile has them). The assignment is by profile, not by role or permission set. Now the versioned profile `Minimum Access - Salesforce.profile-meta.xml` assigns `Asset-Asset Layout`, `Case-Case Layout`, `Lectura_Vigente__c-Lectura Vigente Layout`, `Log_Senial__c-Registro de Señal Layout` and `Umbral__c-Umbral Layout`. `Account` isn't in the profile and the building opens fine with the standard layout (verified with the operator persona, 2026-10-07). Having the layout assigned doesn't grant access: access still comes from permission sets, FLS and sharing (BR-208).

## Baseline (2026-10-05, public OWD)

`MaxAccessLevel` from `UserRecordAccess` per user. "Expected" is the target with D022 (BLD-BAQ-001 owned by the second operator); "read-only" means no effective Edit or Delete, even if `MaxAccessLevel` says All because of the hierarchy. What was verified is in "Result (T8.6)" and "Hierarchy instead of View All (D022)".

| Record | Operator | Coordinator | Manager | Admin | Expected |
|---|---|---|---|---|---|
| BLD-BOG-001 (`Account`, owned by operator) | All | All | All | All | Read-only for operator, coordinator and manager |
| BLD-BAQ-001 (`Account`, owned by John) | Edit | Edit | Edit | All | Operator None; coordinator and manager read-only through the hierarchy |
| BOG `Asset` | Transfer | Transfer | Transfer | Transfer | Read for all three |
| BAQ `Asset` | Edit | Edit | Edit | Transfer | Operator None; coordinator and manager Read |
| BOG / BAQ `Lectura_Vigente__c` | Read / Read | Read / Read | Read / Read | Delete | BOG Read for all three; BAQ None for the operator, Read for coordinator and manager |
| BOG / BAQ `Case` | Transfer / Transfer | Transfer / Transfer | Transfer / Transfer | All | Operator: BOG Read, BAQ None; coordinator Edit and manager Read on the integration Cases |
| `Umbral__c` | None | Read | None | All | Coordinator Edit |
| `Log_Senial__c` | None | None | None | All | Same |

In the baseline BLD-BAQ-001 belonged to John (System Administrator, no role). Since 2026-10-06 it belongs to the second operator (D022) and the "unauthorized building" of T8.6 is BLD-TEST-NOAUT.

## How to verify (T8.6)

After the two T8.2 deploys (objects, then roles), from `main`.

1. OWD: `Account`, `Case` and `Opportunity` at `Private`, `Umbral__c` at `ReadWrite`. `Asset` and `Contact` come out with the value they inherit from `Account`.

   ```bash
   sf data query --use-tooling-api -o nova-cdo -q "SELECT QualifiedApiName, InternalSharingModel, ExternalSharingModel FROM EntityDefinition WHERE QualifiedApiName IN ('Account','Asset','Case','Contact','Opportunity','Umbral__c')"
   ```

2. Ids of the personas and of one record from each building:

   ```bash
   sf data query -o nova-cdo -q "SELECT Id, Username FROM User WHERE Username IN ('<operator-username>','<operator-2-username>','<coordinator-username>','<manager-username>','<admin-username>')"
   sf data query -o nova-cdo -q "SELECT Id, External_Id__c, Owner.Username FROM Account WHERE External_Id__c IN ('BLD-BOG-001','BLD-BAQ-001','BLD-TEST-NOAUT')"
   sf data query -o nova-cdo -q "SELECT Id, Account.External_Id__c FROM Asset WHERE Account.External_Id__c IN ('BLD-BOG-001','BLD-BAQ-001') ORDER BY Account.External_Id__c"
   sf data query -o nova-cdo -q "SELECT Id, Asset__r.Account.External_Id__c FROM Lectura_Vigente__c WHERE Asset__r.Account.External_Id__c IN ('BLD-BOG-001','BLD-BAQ-001') ORDER BY Asset__r.Account.External_Id__c"
   sf data query -o nova-cdo -q "SELECT Id, Account.External_Id__c, Owner.Name FROM Case WHERE Account.External_Id__c IN ('BLD-BOG-001','BLD-BAQ-001') ORDER BY CreatedDate DESC LIMIT 10"
   sf data query -o nova-cdo -q "SELECT Id, CreatedBy.Name FROM Umbral__c LIMIT 1"
   ```

3. One query per persona (operator, coordinator, manager). `UserRecordAccess` only accepts literal Ids: one `UserId` and a list of `RecordId`.

   ```bash
   sf data query -o nova-cdo -q "SELECT RecordId, MaxAccessLevel FROM UserRecordAccess WHERE UserId = '<UserId>' AND RecordId IN ('<Id1>','<Id2>')"
   ```

## Result (T8.6)

2026-10-06, before D022 (BLD-BAQ-001 still John's). "Before" is with OWD Private and the Standard User profile; "After", with Minimum Access + `Nova_Casa_Lightning` and the manager's View All, which D022 removes. Value = `MaxAccessLevel`; (E/D) = `HasEditAccess` and `HasDeleteAccess` true, (E) = Edit only.

| Record | Operator | Coordinator | Manager | Admin |
|---|---|---|---|---|
| BLD-BOG-001 (`Account`, owned by operator) | All (E/D) → All | All (E/D) → All | All (E/D) → All | All (E/D), same |
| BLD-BAQ-001 (`Account`, owned by John) | None → None | Read → Read | Read → Read | All (E/D), same |
| BOG `Asset` | Transfer (E/D) → Read | Transfer (E/D) → Read | Transfer (E/D) → Read | Transfer (E/D), same |
| BAQ `Asset` | None → None | Read → Read | Read → Read | Transfer (E/D), same |
| BOG `Lectura_Vigente__c` | Read → Read | Read → Read | Read → Read | Delete (E/D), same |
| BAQ `Lectura_Vigente__c` | None → None | Read → Read | Read → Read | Delete (E/D), same |
| Open BOG `Case` (owned by John) | Read → Read | Read → Read | Read → Read | All (E/D), same |
| Open BAQ `Case` (owned by integration) | None → None | All (E) → All (E) | All (E) → All | All (E/D), same |

- **"All" without (E/D)** is the sharing level of the owner or of whoever is above them in the hierarchy; the object permission keeps it at read (`HasAllAccess` true, `HasEditAccess`, `HasDeleteAccess` and `HasTransferAccess` false). No persona can edit or delete buildings or assets anymore, and the manager can no longer edit Cases.
- **Coordinator and manager see BLD-BAQ-001** even though they aren't owners: implicit parent sharing from the integration user's Cases (coordinator) and View All (manager).
- **Manager's View All**: on `salesforce.com`, an `Account` of John's with no Cases, the manager has Read and operator and coordinator have None.
- **Effective CRUD**: the Minimum Access profile contributes no `ObjectPermissions` on these objects; only the Nova Casa permission sets count.
- **Tests**: `ActivosOperadorControllerTest` and `IntervencionOperadorControllerTest`, 34/34 green in a test run in the org on that date (`sf apex run test` in `nova-cdo`). `SeguridadTest` (what each persona permission set grants, who reaches `Log_Senial__c`, the custom permissions per persona, no View All or Modify All in the operator, coordinator and manager sets, the manager not reading records outside the hierarchy) and `PermisosProcesamientoTest` ([D017](decisiones.md#d017--nova_casa_procesamiento-permission-set-for-the-integration-user-t210): the integration set gets no delete or Modify All, and processing works without operator or admin permissions) check the permission sets themselves.

Operator check in the browser, done by hand on 2026-10-13 ([entrega.md](entrega.md#manual-walkthrough-of-2026-10-13)): operator 1 saw only their own building (Nova Alameda), read-only, and operator 2 only theirs; neither got Registros de Señal or Umbrales. `Umbral__c` and `Log_Senial__c` weren't measured again with `UserRecordAccess`.

## Hierarchy instead of View All (D022)

2026-10-06, after creating the second operator and giving it BLD-BAQ-001, and before the deploy of `Nova_Casa_Gerente` without View All. "Today" is what was measured (the manager still with View All); "Expected" is after the deploy. Value = `MaxAccessLevel`; in every row `HasEditAccess` and `HasDeleteAccess` are false. "All" is the sharing level the hierarchy or ownership gives; the object permission keeps it at read.

Buildings:

| Building (owner) | Operator | Operator 2 | Coordinator | Manager today | Manager expected |
|---|---|---|---|---|---|
| BLD-BOG-001 (operator) | All | None | All | All | All (read-only) |
| BLD-BAQ-001 (operator 2) | None | All | All | All | All (read-only) |
| BLD-TEST-NOAUT (Juan Diego, no role) | None | None | None | **Read** (View All) | **None** |

The manager's read-only access to records owned by someone else:

| Record (owner) | Manager today | Manager expected |
|---|---|---|
| BLD-BAQ-001, `Account` (operator 2) | All, no Edit/Delete | All, no Edit/Delete |
| AST-BAQ-TEMP-001, `Asset` (John) | Read | Read |
| BAQ `Lectura_Vigente__c` (via asset) | Read | Read |
| BAQ telemetry `Case` (integration owner) | All, no Edit/Delete | All, no Edit/Delete |
| BOG telemetry `Case` (system administrator owner) | Read | Read |
| `salesforce.com`, CDO demo `Account` (John) | **Read** (View All) | **None** |

- Operator 2 sees the BAQ asset, current reading and Case read-only, and nothing from BOG; the operator, the other way around.
- The only thing the deploy changes is what arrives today through View All: BLD-TEST-NOAUT and the accounts that aren't Nova Casa's.
- To measure again, use the queries in "How to verify (T8.6)": step 2 gives the Ids of BLD-BOG-001, BLD-BAQ-001 and BLD-TEST-NOAUT in the org.

## Building owners

`CatalogoService` upserts `Account` without touching `OwnerId`: a new building is owned by whoever runs the catalog load and, until it's reassigned, neither the hierarchy nor its operator sees it (D022). The Salesforce administrator (Juan Diego or John) assigns the owning operator right after each load:

```bash
sf data query -o nova-cdo -q "SELECT Id, External_Id__c, Name, Owner.Username FROM Account WHERE External_Id__c LIKE 'BLD-%' AND External_Id__c != 'BLD-TEST-NOAUT' AND Owner.UserRole.DeveloperName != 'Operador_Edificios'"
sf data update record -o nova-cdo -s Account -w "External_Id__c='<BLD-…>'" -v "OwnerId='<Id del operador>'"
```

The first query should come back empty. The `Asset` records aren't touched: they're Controlled by Parent.

## Risks

- **Ingestion with OWD Private**: a `SYSTEM_MODE` inside a `with sharing` class still applies sharing. The integration user doesn't own the buildings and isn't above the operator in the hierarchy, so if the ingestion classes were `with sharing` it would need View All on what it reads and writes. Today it doesn't: `SenialSensorHandler`, `IntervencionService` and `TelemetriaIngesta` are `without sharing` ([D017](decisiones.md#d017--nova_casa_procesamiento-permission-set-for-the-integration-user-t210)). `Nova_Casa_Procesamiento` keeps View All, and no Modify All, on `Account`, `Asset` and `Case` as a margin in case one of them moves to `with sharing`, and so the ingestion's authorization stays explicit and separate from the operator, as US-208 asks.
- **`Case.AccountId`**: the operator sees a Case because they own its `Account` (role level). If ingestion creates a Case without `AccountId`, the operator doesn't see it. Current Cases do have it.
- **Tests with `System.runAs`**: `ActivosOperadorControllerTest` and `IntervencionOperadorControllerTest` create the building as the user running the test and query as another user with no role or ownership. With `Account` Private that user doesn't see the building and the count asserts fail. Resolved in PR #39: the test building is owned by the `runAs` user.
- **Building owner**: a new building from the catalog is invisible to the hierarchy until it's reassigned; the step is in "Building owners".
