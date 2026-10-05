# Matriz de acceso (US-208)

T8.1. Quién ve y hace qué, y de dónde sale cada acceso (BR-208). El acceso efectivo es siempre la intersección de dos cosas: el permiso de objeto/campo (permission set o perfil) y el acceso al registro (OWD, ownership, role hierarchy o View All). El modelo de edificio como `Account` viene de [D005](decisiones.md#d005--el-edificio-es-account-external_id__c-para-upsert-del-catálogo).

**Estado al 2026-10-05**: roles y permission sets desplegados y asignados; el OWD sigue público, así que hoy todos ven todos los edificios (ver "Línea base"). El cierre llega con T8.2 en el orden de abajo.

## Personas

| Persona | Usuario demo | Rol | Permission sets | Cómo llega a los registros |
|---|---|---|---|---|
| Operador | `novacasa.operador@…` | Operador de Edificios | `Nova_Casa_Operator` | Es dueño (`OwnerId`) del `Account` de su edificio |
| Coordinador | `novacasa.coordinador@…` | Coordinador de Mantenimiento | `Nova_Casa_Coordinator` | Role hierarchy: ve lo de Operador e Integración |
| Gerente regional | `novacasa.gerente@…` | Gerente Regional de Operaciones | `Nova_Casa_Gerente` | Role hierarchy: ve todo lo de abajo |
| Administrador (persona) | `novacasa.admin@…` | ninguno | `Nova_Casa_Admin`, `Nova_Casa_Operator` | View All / Modify All en los objetos Nova Casa |
| Integración | usuario de T2.10 (pendiente) | Integración Telemetría | `Nova_Casa_Simulator_Integration` + permiso de ingesta (T2.10) | Es dueño de los `Case` y `Log_Senial__c` que crea |

El admin persona no lleva rol: View All / Modify All ya le da todos los registros, y un rol lo metería en la jerarquía operativa sin necesidad. La visibilidad de coordinador y gerente sale de la jerarquía, no de View All en sus permission sets.

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

Hoy los archivos de rol no declaran estos niveles: con el OWD público la plataforma rechaza cualquier valor por debajo del OWD ("access level below organization default") y guarda Edit en los tres. Se agregan en T8.2, después del cambio de OWD.

## Matriz por objeto

C/R/E/D = Create/Read/Edit/Delete del permission set; después del punto, de dónde sale el acceso al registro.

| Objeto | OWD hoy → objetivo | Operador | Coordinador | Gerente | Admin (persona) | Integración |
|---|---|---|---|---|---|---|
| `Account` (edificio) | Public Read/Write → **Private** | R · dueño | R · jerarquía | R · jerarquía | CRED · Modify All | T2.10 |
| `Asset` | Public Read/Write → **Controlled by Parent** | R · vía edificio | R · vía edificio | R · vía edificio | CRED · Modify All | T2.10 |
| `Lectura_Vigente__c` | Controlled by Parent (sin cambio) | R · vía activo | R · vía activo | R · vía activo | CRED · Modify All | escribe |
| `Case` (intervención, [D001](decisiones.md#d001--objeto-de-intervención-case)) | Public Read/Write/Transfer → **Private** | R · casos de su edificio (rol) | RE · jerarquía | R · jerarquía | CRED · Modify All | crea, dueño |
| `Log_Senial__c` | Private (sin cambio) | — | — | — | CRED · Modify All | crea, dueño |
| `Umbral__c` | Public Read Only → **Public Read/Write** | — | CRE | — | CRED · Modify All | lee |
| `Contact` / `Opportunity` | Public Read/Write / Read → Controlled by Parent / Private | R / — | R / — | R / — | CRED / — | — |

`Umbral__c` pasa a Public Read/Write porque con Read Only el coordinador solo edita los umbrales que él creó (la línea base lo muestra: Read, no Edit, sobre un umbral sembrado por otro usuario), y eso deja sin efecto [D004](decisiones.md#d004--umbral__c-es-objeto-custom-no-custom-metadata-type). Quién edita lo sigue decidiendo el permiso de objeto: solo Coordinador y Admin lo tienen, y el objeto guarda field history.

## Campos (FLS)

- **Todos los que ven `Lectura_Vigente__c`** ven sus campos requeridos (`Asset__c`, `Tipo_Medicion__c`, `Valor__c`, `Unidad__c`, `Occurred_At__c`): la plataforma no permite FLS sobre campos requeridos.
- **Operador**: lectura en `Asset.AccountId`, `Asset.Tipo_Activo__c`, `Case.AssetId`, `Case.Subject`, `Lectura_Vigente__c.Sensor_Id__c`, `Lectura_Vigente__c.Severidad_Nivel__c`. No ve los resúmenes de `Asset` (`Severidad_Actual__c`, `Severidad_Nivel__c`, `Ultima_Senal__c`): la pantalla calcula la severidad desde las lecturas, pero la página estándar del activo no los muestra.
- **Coordinador**: lo del operador, más edición en `Umbral__c.Activo__c` y lectura en `Umbral__c.Severidad_Nivel__c`.
- **Gerente**: lo del operador, más lectura en los resúmenes de `Asset` y en `Lectura_Vigente__c.Severidad__c`. Nada editable.
- **Solo Admin**: las claves técnicas (`Account.External_Id__c`, `Asset.External_Id__c`, `Lectura_Vigente__c.Clave__c`, `Identidad_Senal__c` en `Case` y `Lectura_Vigente__c`) y todo `Log_Senial__c`.

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

1. **T2.10**: crear el usuario de integración con rol Integración Telemetría y su permission set de ingesta.
2. **T2.2**: `PlatformEventSubscriberConfig` para que el trigger corra como ese usuario. Hoy los casos los crea Automated Process, que no tiene rol: con OWD Private, coordinador y gerente no los verían.
3. **T8.2**: en un solo deploy, `sharingModel` de `Account` Private, `Contact` ControlledByParent, `Opportunity` Private, `Case` Private, `Asset` ControlledByParent y `Umbral__c` ReadWrite. Después, redeploy de los roles con los niveles de la tabla de arriba.
4. **Perfil**: pasar los cuatro usuarios persona a Minimum Access - Salesforce con `Nova_Casa_Lightning` (ver abajo).
5. **T8.6**: repetir las consultas de la línea base y probar la pantalla y Apex con operador y un usuario con acceso insuficiente.

## Perfil Standard User

Los usuarios persona tienen hoy el perfil Standard User, que da CRED en `Account`, `Asset`, `Contact` y `Opportunity`, y CRE en `Case`. Los permission sets solo suman, así que hoy el operador puede editar o borrar edificios y editar casos aunque `Nova_Casa_Operator` sea de solo lectura. El plan es pasarlos a Minimum Access - Salesforce, que no da acceso a objetos pero tampoco Lightning Experience; `Nova_Casa_Lightning` (desplegado, sin asignar) agrega solo `LightningExperienceUser`. Antes del cambio hay que revisar las pestañas estándar `Case` y `Asset`: solo `Nova_Casa_Gerente` las declara.

## Línea base (2026-10-05, OWD público)

`MaxAccessLevel` de `UserRecordAccess` por usuario; "Esperado" es lo que T8.6 debe mostrar después de T8.2 y del cambio de perfil.

| Registro | Operador | Coordinador | Gerente | Admin | Esperado |
|---|---|---|---|---|---|
| BLD-BOG-001 (`Account`, dueño operador) | All | All | All | All | Read para operador, coordinador y gerente |
| BLD-BAQ-001 (`Account`, dueño John) | Edit | Edit | Edit | All | None para los tres |
| `Asset` de BOG | Transfer | Transfer | Transfer | Transfer | Read para los tres |
| `Asset` de BAQ | Edit | Edit | Edit | Transfer | None para los tres |
| `Lectura_Vigente__c` de BOG / BAQ | Read / Read | Read / Read | Read / Read | Delete | BOG Read, BAQ None |
| `Case` de BOG / BAQ | Transfer / Transfer | Transfer / Transfer | Transfer / Transfer | All | Operador: BOG Read, BAQ None; coordinador Edit y gerente Read en los casos de integración |
| `Umbral__c` | None | Read | None | All | Coordinador Edit |
| `Log_Senial__c` | None | None | None | All | Igual |

BLD-BAQ-001 es un edificio de prueba de John (System Administrator, sin rol) y se deja así. Con OWD Private nadie de la jerarquía lo verá hasta que su dueño sea alguien de ella; sirve como el "edificio no autorizado" de T8.6.

## Riesgos

- **Ingesta con OWD Private**: un `SYSTEM_MODE` dentro de una clase `with sharing` sigue aplicando sharing. El usuario de integración no es dueño de los edificios ni está sobre el operador en la jerarquía, así que necesita View All / Modify All en los objetos que lee y escribe, en su propio permission set (T2.10). Eso además deja la autorización de la ingesta explícita y separada del operador, como pide US-208.
- **`Case.AccountId`**: el operador ve un caso porque es dueño de su `Account` (nivel del rol). Si la ingesta crea un caso sin `AccountId`, el operador no lo ve. Los casos actuales sí lo traen.
- **Dueño del edificio**: `CatalogoService` no toca `OwnerId`; un edificio nuevo queda a nombre de quien corre la carga y hay que reasignarlo al operador a mano.
