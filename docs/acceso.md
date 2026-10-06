# Matriz de acceso (US-208)

T8.1. Quién ve y hace qué, y de dónde sale cada acceso (BR-208). El acceso efectivo es siempre la intersección de dos cosas: el permiso de objeto/campo (permission set o perfil) y el acceso al registro (OWD, ownership, role hierarchy o View All). El modelo de edificio como `Account` viene de [D005](decisiones.md#d005--el-edificio-es-account-external_id__c-para-upsert-del-catálogo).

**Estado al 2026-10-06**: OWD Private aplicado (T8.2, PR #38), los usuarios persona en Minimum Access - Salesforce y cada edificio a nombre de un operador ([D022](decisiones.md#d022--coordinador-y-gerente-ven-por-role-hierarchy-cada-edificio-es-de-un-operador-personas-en-minimum-access-us-208)). En el org el gerente todavía tiene View All: el deploy de `Nova_Casa_Gerente` sin View All espera el OK de John (dry-run `0Afak00000nUWcXCAW`). Ver "Jerarquía en vez de View All (D022)".

## Personas

| Persona | Usuario demo | Rol | Permission sets | Cómo llega a los registros |
|---|---|---|---|---|
| Operador | `novacasa.operador@…` | Operador de Edificios | `Nova_Casa_Operator`, `Nova_Casa_Lightning` | Es dueño (`OwnerId`) del `Account` de su edificio (BLD-BOG-001) |
| Operador 2 | `novacasa.operador2@…` | Operador de Edificios | `Nova_Casa_Operator`, `Nova_Casa_Lightning` | Es dueño de BLD-BAQ-001 (T8.4, dos operadores con edificios distintos) |
| Coordinador | `novacasa.coordinador@…` | Coordinador de Mantenimiento | `Nova_Casa_Coordinator`, `Nova_Casa_Lightning` | Role hierarchy: ve los edificios de los operadores y lo de Integración |
| Gerente regional | `novacasa.gerente@…` | Gerente Regional de Operaciones | `Nova_Casa_Gerente`, `Nova_Casa_Lightning` | Role hierarchy (todo lo de coordinador, operadores e integración) en solo lectura, más Run Reports |
| Administrador (persona) | `novacasa.admin@…` | ninguno | `Nova_Casa_Admin`, `Nova_Casa_Operator`, `Nova_Casa_Lightning` | View All / Modify All en los objetos Nova Casa |
| Integración | `novacasa.integracion@…` | Integración Telemetría | `Nova_Casa_Simulator_Integration` + permiso de ingesta (T2.10) | Es dueño de los `Case` y `Log_Senial__c` que crea |

El admin persona no lleva rol: View All / Modify All ya le da todos los registros, y un rol lo metería en la jerarquía operativa sin necesidad.

`novacasa.operador2@novacasa-telemetria.demo` es dato del org, no está en el repo. Se creó el 2026-10-06 (Id `005ak00000kPZmTAAW`) con perfil Minimum Access - Salesforce, rol `Operador_Edificios`, alias `ncoper2`, locale `es_CO`, zona `America/Bogota`, y los permission sets `Nova_Casa_Operator` y `Nova_Casa_Lightning`; después se le pasó el `OwnerId` de BLD-BAQ-001 (antes de John). Los `Asset` y `Case` de BAQ no cambiaron de dueño (`Asset` es Controlled by Parent). Para reproducirlo:

```bash
sf data create record -o novacasa_sprint_2 -s User -v "Username='novacasa.operador2@novacasa-telemetria.demo' FirstName='Operador 2' LastName='Nova Casa' Alias='ncoper2' Email='<email>' TimeZoneSidKey='America/Bogota' LocaleSidKey='es_CO' LanguageLocaleKey='es' EmailEncodingKey='UTF-8' ProfileId='<Id de Minimum Access - Salesforce>' UserRoleId='<Id de Operador_Edificios>'"
sf org assign permset -o novacasa_sprint_2 -n Nova_Casa_Operator -n Nova_Casa_Lightning -b novacasa.operador2@novacasa-telemetria.demo
sf data update record -o novacasa_sprint_2 -s Account -w "External_Id__c='BLD-BAQ-001'" -v "OwnerId='<Id de operador2>'"
```

**Edificio no autorizado (T8.6)**: `Edificio de prueba (fuera de jerarquía)`, `External_Id__c` `BLD-TEST-NOAUT` (Id `001ak00003qlUtRAAU`), dueño Juan Diego (System Administrator, sin rol), sin activos. Nadie de la jerarquía debe verlo: es el registro de prueba de coordinador y gerente. No choca con el catálogo, que solo hace upsert de los `External_Id__c` que manda el simulador.

- **Gerente** ([D022](decisiones.md#d022--coordinador-y-gerente-ven-por-role-hierarchy-cada-edificio-es-de-un-operador-personas-en-minimum-access-us-208)): Read en `Account`, `Asset`, `Case`, `Contact` y `Lectura_Vigente__c`, sin View All, Create, Edit, Delete ni Modify All, y Run Reports sin Export. Ve todos los edificios porque cada uno es de un operador, que está bajo él en la jerarquía. Un reporte solo le muestra lo que puede ver.
- **Coordinador**: sin View All. Ve los edificios de los operadores por jerarquía y todas las intervenciones porque las crea el usuario de integración, que también está bajo él. Si un edificio no es de un operador pero tiene casos de integración, lo ve en lectura por implicit parent sharing.

## Jerarquía de roles

```
Gerente Regional de Operaciones
└── Coordinador de Mantenimiento
    ├── Operador de Edificios
    └── Integración Telemetría
```

Integración va bajo Coordinador para que los casos y logs que cree el usuario de integración queden visibles para coordinador y gerente sin abrir el OWD.

Acceso del dueño del edificio a los objetos hijos (`caseAccessLevel` / `opportunityAccessLevel` / `contactAccessLevel` del rol), valores objetivo:

| Rol | Case | Opportunity | Contact |
|---|---|---|---|
| Gerente Regional de Operaciones | Read | None | Read |
| Coordinador de Mantenimiento | Edit | None | Read |
| Operador de Edificios | **Read** | None | Read |
| Integración Telemetría | None | None | None |

Operador queda en **Read**: `Nova_Casa_Operator` es de solo lectura y el seguimiento de la intervención es del coordinador. Edit en el rol no cambiaría nada hoy (el permiso de objeto lo limita a lectura) y abriría edición sin querer si algún día se le da Edit en `Case` al operador. Si el operador debe seguir intervenciones, se cambian los dos a la vez. Contact solo aplica si Contact queda Private; el plan es Controlled by Parent.

Los archivos de rol declaran Case y Opportunity desde T8.2; Contact no se declara porque queda Controlled by Parent. Van en un segundo deploy, después del de OWD: mientras el OWD siga público la plataforma rechaza cualquier valor por debajo de él ("Opportunity access level below organization default", visto en el dry-run de T8.2).

## Matriz por objeto

C/R/E/D = Create/Read/Edit/Delete del permission set; después del punto, de dónde sale el acceso al registro.

| Objeto | OWD hoy → objetivo | Operador | Coordinador | Gerente | Admin (persona) | Integración |
|---|---|---|---|---|---|---|
| `Account` (edificio) | Public Read/Write → **Private** | R · dueño | R · jerarquía | R · jerarquía | CRED · Modify All | T2.10 |
| `Asset` | Controlled by Parent (sin cambio; hereda el Private de `Account`) | R · vía edificio | R · vía edificio | R · vía edificio | CRED · Modify All | T2.10 |
| `Lectura_Vigente__c` | Controlled by Parent (sin cambio) | R · vía activo | R · vía activo | R · vía activo | CRED · Modify All | escribe |
| `Case` (intervención, [D001](decisiones.md#d001--objeto-de-intervención-case)) | Public Read/Write/Transfer → **Private** | R · casos de su edificio (rol) | RE · jerarquía | R · jerarquía | CRED · Modify All | crea, dueño |
| `Log_Senial__c` | Private (sin cambio) | — | — | — | CRED · Modify All | crea, dueño |
| `Umbral__c` | Public Read Only → **Public Read/Write** | — | CRE | — | CRED · Modify All | lee |
| `Contact` / `Opportunity` | Controlled by Parent (sin cambio) / Public Read Only → **Private** | R / — | R / — | R / — | CRED / — | — |

`Asset` y `Contact` ya estaban en Controlled by Parent en la metadata (y `Organization.DefaultContactAccess`); `EntityDefinition` los mostraba como Public Read/Write porque reporta el valor efectivo que heredan de `Account`. `Opportunity` y `Case` pasan a Private porque no pueden quedar más abiertos que `Account`.

`Umbral__c` pasa a Public Read/Write porque con Read Only el coordinador solo edita los umbrales que él creó (la línea base lo muestra: Read, no Edit, sobre un umbral sembrado por otro usuario), y eso deja sin efecto [D004](decisiones.md#d004--umbral__c-es-objeto-custom-no-custom-metadata-type). Quién edita lo sigue decidiendo el permiso de objeto: solo Coordinador y Admin lo tienen, y el objeto guarda field history.

## Campos (FLS)

- **Todos los que ven `Lectura_Vigente__c`** ven sus campos requeridos (`Asset__c`, `Tipo_Medicion__c`, `Valor__c`, `Unidad__c`, `Occurred_At__c`): la plataforma no permite FLS sobre campos requeridos.
- **Operador**: lectura en `Asset.AccountId`, `Asset.Tipo_Activo__c`, los resúmenes de `Asset` (`Severidad_Actual__c`, `Severidad_Nivel__c`, `Ultima_Senal__c`), `Case.AssetId`, `Case.Subject`, `Lectura_Vigente__c.Sensor_Id__c`, `Lectura_Vigente__c.Severidad_Nivel__c`, `Lectura_Vigente__c.Severidad__c` y las claves técnicas.
- **Coordinador**: lo del operador, más edición en `Umbral__c.Activo__c` y lectura en `Umbral__c.Severidad_Nivel__c`.
- **Gerente**: lo del operador. Nada editable.
- **Claves técnicas** (`Account.External_Id__c`, `Asset.External_Id__c`, `Lectura_Vigente__c.Clave__c`, `Identidad_Senal__c` en `Case` y `Lectura_Vigente__c`): solo lectura para todas las personas (alineado con PR #26); solo Admin las edita. La pantalla del operador consulta `Asset.External_Id__c` en `USER_MODE`, así que sin esa FLS muestra error de acceso; las otras cuatro son para los layouts de `Case`, `Account` y `Lectura_Vigente__c`.
- **Solo Admin**: todo `Log_Senial__c`.

## Acciones

| Acción | Quién | Autorización |
|---|---|---|
| Ver la pantalla "Activos del operador" | Operador, Coordinador, Gerente, Admin | Tab + `classAccesses` a `ActivosOperadorController`; el controlador es `with sharing` y consulta en `USER_MODE` |
| Seguir una intervención (editar `Case`) | Coordinador, Admin | Edit en `Case` en `Nova_Casa_Coordinator`; nadie la crea a mano, la crea la ingesta |
| Cambiar umbrales | Coordinador (crear/editar), Admin (todo) | CRUD de `Umbral__c` en el permission set; requiere el OWD Public Read/Write de arriba |
| Ver errores técnicos y motivo de rechazo | Admin | `Log_Senial__c` solo en `Nova_Casa_Admin` |
| Reintentar una señal | Admin | Edit en `Log_Senial__c` (`Reintento_Seguro__c`); el mecanismo de reintento es de BR-209 |
| Ingestar señales | Usuario de integración | `Nova_Casa_Simulator_Integration` + permiso de ingesta propio (T2.10), separado del operador |

## Orden de pasos

1. **T2.10** (hecho): crear el usuario de integración con rol Integración Telemetría y su permission set de ingesta. Verificado el 2026-10-06: `novacasa.integracion@novacasa-telemetria.demo`, activo, rol `Integracion_Telemetria`, perfil Minimum Access - Salesforce, con `Nova_Casa_Simulator_Integration` y `Nova_Casa_Procesamiento`.
2. **T2.2** (hecho): `PlatformEventSubscriberConfig` para que el trigger corra como ese usuario. `Nova_Casa_Procesamiento` (PR #28) corre `SenialSensorTrigger` como ese usuario, con batch 200. El último caso de Automated Process es del 2026-10-05 18:07Z; desde las 18:14Z los `Case` y `Lectura_Vigente__c` nuevos los crea el usuario de integración (65 casos hasta las 21:48Z, contando los borrados en la limpieza). Con OWD Private, coordinador y gerente ven esos `Case` por jerarquía porque el usuario de integración está bajo el coordinador. Las `Lectura_Vigente__c` no: son Controlled by Parent y se ven por el edificio, así que dependen de quién es dueño del `Account` (D022), no de quién las crea.
3. **T8.2** (hecho, PR #38): en un solo deploy, `sharingModel` de `Account` Private, `Contact` ControlledByParent, `Opportunity` Private, `Case` Private, `Asset` ControlledByParent y `Umbral__c` ReadWrite. Después, redeploy de los roles con los niveles de la tabla de arriba.
4. **Perfil** (hecho 2026-10-06): los cuatro usuarios persona en Minimum Access - Salesforce con `Nova_Casa_Lightning` (ver abajo).
5. **T8.6** (hecho 2026-10-06): consultas repetidas antes y después del cambio de perfil, ver "Resultado (T8.6)".
6. **Segundo operador y dueños** (hecho 2026-10-06, D022): `novacasa.operador2@` creado y dueño de BLD-BAQ-001; BLD-TEST-NOAUT creado como edificio fuera de la jerarquía.
7. **Gerente sin View All** (pendiente del OK de John): deploy de `Nova_Casa_Gerente`, dry-run `0Afak00000nUWcXCAW`; después repetir las consultas de "Jerarquía en vez de View All (D022)".

## Perfil Minimum Access

Los usuarios persona tenían el perfil Standard User, que da CRED en `Account`, `Asset`, `Contact` y `Opportunity`, y CRE en `Case`. Los permission sets solo suman, así que el operador podía editar o borrar edificios aunque `Nova_Casa_Operator` sea de solo lectura. Ahora están en Minimum Access - Salesforce, que no da acceso a objetos ni Lightning Experience; `Nova_Casa_Lightning` agrega solo `LightningExperienceUser`. Las pestañas estándar `Account`, `Asset`, `Case` y Reports ya vienen en DefaultOn en ese perfil. `Nova_Casa_Gerente` declara igual `standard-Account`, `standard-Asset` y `standard-Case` como Visible, para no depender del perfil; los demás permission sets no las declaran y dependen de Minimum Access.

El perfil y las asignaciones son datos del org, no metadata. Para reproducirlos (2026-10-06, en `novacasa.operador@`, `novacasa.coordinador@`, `novacasa.gerente@` y `novacasa.admin@`, todos `@novacasa-telemetria.demo`; `novacasa.integracion@` ya estaba en Minimum Access):

```bash
sf data update record -o novacasa_sprint_2 -s User -w "Username='<username>'" -v "ProfileId=<Id de Minimum Access - Salesforce>"
sf org assign permset -o novacasa_sprint_2 -n Nova_Casa_Lightning -b <username>
```

Para revertir, el mismo `sf data update record` con el `ProfileId` de Standard User.

## Línea base (2026-10-05, OWD público)

`MaxAccessLevel` de `UserRecordAccess` por usuario. "Esperado" es el objetivo con D022 (BLD-BAQ-001 de `novacasa.operador2@`); "lectura" quiere decir sin Edit ni Delete efectivos, aunque `MaxAccessLevel` diga All por la jerarquía. Lo verificado está en "Resultado (T8.6)" y "Jerarquía en vez de View All (D022)".

| Registro | Operador | Coordinador | Gerente | Admin | Esperado |
|---|---|---|---|---|---|
| BLD-BOG-001 (`Account`, dueño operador) | All | All | All | All | Lectura para operador, coordinador y gerente |
| BLD-BAQ-001 (`Account`, dueño John) | Edit | Edit | Edit | All | Operador None; coordinador y gerente lectura por jerarquía |
| `Asset` de BOG | Transfer | Transfer | Transfer | Transfer | Read para los tres |
| `Asset` de BAQ | Edit | Edit | Edit | Transfer | Operador None; coordinador y gerente Read |
| `Lectura_Vigente__c` de BOG / BAQ | Read / Read | Read / Read | Read / Read | Delete | BOG Read para los tres; BAQ None para el operador, Read para coordinador y gerente |
| `Case` de BOG / BAQ | Transfer / Transfer | Transfer / Transfer | Transfer / Transfer | All | Operador: BOG Read, BAQ None; coordinador Edit y gerente Read en los casos de integración |
| `Umbral__c` | None | Read | None | All | Coordinador Edit |
| `Log_Senial__c` | None | None | None | All | Igual |

En la línea base BLD-BAQ-001 era de John (System Administrator, sin rol). Desde el 2026-10-06 es de `novacasa.operador2@` (D022) y el "edificio no autorizado" de T8.6 es BLD-TEST-NOAUT.

## Cómo verificar (T8.6)

Después de los dos deploys de T8.2 (objetos, luego roles), desde `main`.

1. OWD: `Account`, `Case` y `Opportunity` en `Private`, `Umbral__c` en `ReadWrite`. `Asset` y `Contact` salen con el valor que heredan de `Account`.

   ```bash
   sf data query --use-tooling-api -o novacasa_sprint_2 -q "SELECT QualifiedApiName, InternalSharingModel, ExternalSharingModel FROM EntityDefinition WHERE QualifiedApiName IN ('Account','Asset','Case','Contact','Opportunity','Umbral__c')"
   ```

2. Ids de las personas y de un registro de cada edificio:

   ```bash
   sf data query -o novacasa_sprint_2 -q "SELECT Id, Username FROM User WHERE Username LIKE 'novacasa.%'"
   sf data query -o novacasa_sprint_2 -q "SELECT Id, External_Id__c, Owner.Username FROM Account WHERE External_Id__c IN ('BLD-BOG-001','BLD-BAQ-001','BLD-TEST-NOAUT')"
   sf data query -o novacasa_sprint_2 -q "SELECT Id, Account.External_Id__c FROM Asset WHERE Account.External_Id__c IN ('BLD-BOG-001','BLD-BAQ-001') ORDER BY Account.External_Id__c"
   sf data query -o novacasa_sprint_2 -q "SELECT Id, Asset__r.Account.External_Id__c FROM Lectura_Vigente__c WHERE Asset__r.Account.External_Id__c IN ('BLD-BOG-001','BLD-BAQ-001') ORDER BY Asset__r.Account.External_Id__c"
   sf data query -o novacasa_sprint_2 -q "SELECT Id, Account.External_Id__c, Owner.Name FROM Case WHERE Account.External_Id__c IN ('BLD-BOG-001','BLD-BAQ-001') ORDER BY CreatedDate DESC LIMIT 10"
   sf data query -o novacasa_sprint_2 -q "SELECT Id, CreatedBy.Name FROM Umbral__c LIMIT 1"
   ```

3. Una consulta por persona (operador, coordinador, gerente). `UserRecordAccess` solo acepta Ids literales: un `UserId` y una lista de `RecordId`.

   ```bash
   sf data query -o novacasa_sprint_2 -q "SELECT RecordId, MaxAccessLevel FROM UserRecordAccess WHERE UserId = '<UserId>' AND RecordId IN ('<Id1>','<Id2>')"
   ```

## Resultado (T8.6)

2026-10-06, antes de D022 (BLD-BAQ-001 todavía de John). "Antes" es con OWD Private y perfil Standard User; "Después", con Minimum Access + `Nova_Casa_Lightning` y el View All del gerente, que D022 retira. Valor = `MaxAccessLevel`; (E/D) = `HasEditAccess` y `HasDeleteAccess` en true, (E) = solo Edit.

| Registro | Operador | Coordinador | Gerente | Admin |
|---|---|---|---|---|
| BLD-BOG-001 (`Account`, dueño operador) | All (E/D) → All | All (E/D) → All | All (E/D) → All | All (E/D), igual |
| BLD-BAQ-001 (`Account`, dueño John) | None → None | Read → Read | Read → Read | All (E/D), igual |
| `Asset` de BOG | Transfer (E/D) → Read | Transfer (E/D) → Read | Transfer (E/D) → Read | Transfer (E/D), igual |
| `Asset` de BAQ | None → None | Read → Read | Read → Read | Transfer (E/D), igual |
| `Lectura_Vigente__c` de BOG | Read → Read | Read → Read | Read → Read | Delete (E/D), igual |
| `Lectura_Vigente__c` de BAQ | None → None | Read → Read | Read → Read | Delete (E/D), igual |
| `Case` abierto de BOG (dueño John) | Read → Read | Read → Read | Read → Read | All (E/D), igual |
| `Case` abierto de BAQ (dueño integración) | None → None | All (E) → All (E) | All (E) → All | All (E/D), igual |

- **"All" sin (E/D)** es el nivel de sharing del dueño o de quien está sobre él en la jerarquía; el permiso de objeto lo deja en lectura (`HasAllAccess` true, `HasEditAccess`, `HasDeleteAccess` y `HasTransferAccess` false). Ninguna persona puede ya editar ni borrar edificios ni activos, y el gerente ya no puede editar casos.
- **Coordinador y gerente ven BLD-BAQ-001** aunque no sean dueños: implicit parent sharing de los casos del usuario de integración (coordinador) y View All (gerente).
- **View All del gerente**: en `salesforce.com`, un `Account` de John sin casos, el gerente tiene Read y operador y coordinador None.
- **CRUD efectivo**: el perfil Minimum Access no aporta `ObjectPermissions` en estos objetos; solo cuentan los permission sets Nova Casa.
- **Tests**: `ActivosOperadorControllerTest` e `IntervencionOperadorControllerTest`, 34/34 en verde (run `707ak00001y0oZd`).

Pendiente: abrir "Activos del operador" con el operador en el navegador (debe salir solo BLD-BOG-001). `Umbral__c` y `Log_Senial__c` no se volvieron a medir.

## Jerarquía en vez de View All (D022)

2026-10-06, después de crear `novacasa.operador2@` y pasarle BLD-BAQ-001, y antes del deploy de `Nova_Casa_Gerente` sin View All. "Hoy" es lo medido (el gerente todavía con View All); "Esperado" es tras el deploy. Valor = `MaxAccessLevel`; en todas las filas `HasEditAccess` y `HasDeleteAccess` son false. "All" es el nivel de sharing que da la jerarquía o la propiedad; el permiso de objeto lo deja en lectura.

Edificios:

| Edificio (dueño) | Operador | Operador 2 | Coordinador | Gerente hoy | Gerente esperado |
|---|---|---|---|---|---|
| BLD-BOG-001 (`novacasa.operador@`) | All | None | All | All | All (lectura) |
| BLD-BAQ-001 (`novacasa.operador2@`) | None | All | All | All | All (lectura) |
| BLD-TEST-NOAUT (Juan Diego, sin rol) | None | None | None | **Read** (View All) | **None** |

Solo lectura del gerente sobre registros de otro dueño:

| Registro (dueño) | Gerente hoy | Gerente esperado |
|---|---|---|
| BLD-BAQ-001, `Account` (`novacasa.operador2@`) | All, sin Edit/Delete | All, sin Edit/Delete |
| AST-BAQ-TEMP-001, `Asset` (John) | Read | Read |
| `Lectura_Vigente__c` de BAQ (`a03ak00002FSarvAAD`, vía activo) | Read | Read |
| `Case` 00003260 de BAQ (`novacasa.integracion@`) | All, sin Edit/Delete | All, sin Edit/Delete |
| `Case` 00002946 de BOG (John) | Read | Read |
| `salesforce.com`, `Account` demo del CDO (John) | **Read** (View All) | **None** |

- Operador 2 ve en lectura el activo, la lectura vigente y el caso de BAQ, y nada de BOG; el operador, al revés.
- Lo único que cambia con el deploy es lo que hoy llega por View All: BLD-TEST-NOAUT y las cuentas que no son de Nova Casa.
- Para medir de nuevo, las consultas de "Cómo verificar (T8.6)" con estos Ids: BLD-BOG-001 `001ak00003q9p0bAAA`, BLD-BAQ-001 `001ak00003q9p0cAAA`, BLD-TEST-NOAUT `001ak00003qlUtRAAU`.

## Dueño de los edificios

`CatalogoService` hace upsert de `Account` sin tocar `OwnerId`: un edificio nuevo queda a nombre de quien corre la carga del catálogo y, hasta reasignarlo, ni la jerarquía ni su operador lo ven (D022). El administrador de Salesforce (Juan Diego o John) asigna el operador dueño justo después de cada carga:

```bash
sf data query -o novacasa_sprint_2 -q "SELECT Id, External_Id__c, Name, Owner.Username FROM Account WHERE External_Id__c LIKE 'BLD-%' AND External_Id__c != 'BLD-TEST-NOAUT' AND Owner.UserRole.DeveloperName != 'Operador_Edificios'"
sf data update record -o novacasa_sprint_2 -s Account -w "External_Id__c='<BLD-…>'" -v "OwnerId='<Id del operador>'"
```

La primera consulta debe volver vacía. Los `Asset` no se tocan: son Controlled by Parent.

## Riesgos

- **Ingesta con OWD Private**: un `SYSTEM_MODE` dentro de una clase `with sharing` sigue aplicando sharing. El usuario de integración no es dueño de los edificios ni está sobre el operador en la jerarquía, así que necesita View All / Modify All en los objetos que lee y escribe, en su propio permission set (T2.10). Eso además deja la autorización de la ingesta explícita y separada del operador, como pide US-208.
- **`Case.AccountId`**: el operador ve un caso porque es dueño de su `Account` (nivel del rol). Si la ingesta crea un caso sin `AccountId`, el operador no lo ve. Los casos actuales sí lo traen.
- **Tests con `System.runAs`**: `ActivosOperadorControllerTest` e `IntervencionOperadorControllerTest` crean el edificio como el usuario que corre el test y consultan como otro usuario sin rol ni ownership. Con `Account` Private ese usuario no ve el edificio y los asserts de conteo fallan. Resuelto en PR #39: el edificio de prueba queda a nombre del usuario del `runAs`.
- **Dueño del edificio**: `CatalogoService` no toca `OwnerId`; un edificio nuevo queda a nombre de quien corre la carga y es invisible para la jerarquía hasta que el administrador lo reasigne a un operador (ver "Dueño de los edificios" y D022).

## Acciones de la pantalla (D020)

Todos ven la misma pantalla y los mismos datos; cambian las acciones. Cada acción vive detrás de una custom permission y el servidor la vuelve a comprobar.

| Acción | Operador | Coordinador | Gerente | Admin |
|---|---|---|---|---|
| Ver activos, lecturas, intervención abierta y resumen por edificio | sí | sí | sí | sí |
| Crear intervención manual (`Nova_Casa_Crear_Intervencion`) | sí | sí | no | sí |
| Cambiar estado de la intervención (`Nova_Casa_Seguir_Intervencion`) | no | sí (necesita además Edit en `Case`) | no | sí |
| Ir a los límites (`Umbral__c`, por permiso de objeto) | no | sí | no | sí |
| Traer señales del simulador (`Nova_Casa_Traer_Senales`) | no | no | no | sí (necesita además `Nova_Casa_Simulator_Integration`) |

La creación del `Case` corre en modo sistema porque el operador no tiene Create sobre `Case`; la custom permission es su única llave (ver D020).

