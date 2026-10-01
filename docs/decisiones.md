# Decisiones y riesgos (ADR-lite)

Entregable 6 de Discovery. Cada decisión no obvia se registra aquí con su alternativa descartada y el trade-off, para que nadie —humano o IA— la revierta sin darse cuenta de por qué se tomó.

No confundir con la sección "Acuerdos" de `Sprint 2 - Nova Casa.md` (verbatim de MDSS): esos son los acuerdos **ya cerrados** por el brief/facilitador y no se contradicen sin volver a documentarlos y probarlos aquí. Este archivo es donde el par **propone y registra sus propias decisiones** dentro de esos límites.

## Cómo agregar una entrada

Copiar esta plantilla, numerar secuencialmente, y mantener el estado actualizado.

```markdown
## D00X — <título corto>

- **Estado**: Propuesta | Aceptada | Rechazada | Reemplazada por D0YY
- **Fecha**:
- **Contexto**: ¿qué problema o ambigüedad obliga a decidir?
- **Decisión**: qué se hace.
- **Alternativa descartada**: qué otra opción se consideró.
- **Trade-off**: qué se gana y qué se sacrifica con la decisión elegida.
- **Riesgo / dependencia**: qué podría invalidar esto y de qué depende.
- **Siguiente acción**: qué falta para validarlo o implementarlo.
```

---

## D001 — Objeto de intervención: Case

- **Estado**: Aceptada
- **Fecha**: 2026-09-29
- **Contexto**: BR-205/BR-206 requieren que una señal crítica produzca una intervención operativa que el coordinador de mantenimiento pueda revisar y dar seguimiento. El acuerdo de MDSS ("Incidente") exige el comportamiento (una intervención como máximo por mensaje crítico único) pero no fija el objeto Salesforce que la representa. `CONTRIBUTING.md` ya nombraba `Case` como archivo compartido y hablaba de "cases" creados por la ingesta antes de que esta decisión quedara registrada aquí.
- **Decisión**: la intervención se modela como `Case` (objeto estándar).
- **Alternativa descartada**: `Work Order`.
- **Trade-off**: `Case` viene habilitado en la org sin configuración adicional y reutiliza procesos, permisos, queues y vistas de lista que el equipo ya conoce. Se sacrifican los campos propios de mantenimiento de `Work Order` (Work Type, Service Appointment), que además requieren Field Service — no forman parte del alcance base del sprint y no compensan el costo de habilitar y licenciar Field Service solo para esto.
- **Riesgo / dependencia**: si una fase posterior necesita programar visitas técnicas o asignar recursos de campo, puede que se necesite reabrir esta decisión y evaluar Field Service.
- **Siguiente acción**: ninguna para cerrar la decisión; al implementar BR-205/BR-206 revisar si `Case` necesita campos custom (severidad, activo relacionado, clave del mensaje) y documentarlos en el modelo de datos.

## D002 — Nombre de los componentes de conexión al simulador (HP-01)

- **Estado**: Aceptada
- **Fecha**: 2026-09-30
- **Contexto**: la tarea T1.1 del backlog especificaba crear la External Credential como `Nova_Casa_Simulator_Auth`. Lo que terminó desplegado en `force-app` y en la org (`nova-cdo`) para las tres piezas de conexión —External Credential, Named Credential y Permission Set— usa `Nova_Casa_Simulator` (sin el sufijo `_Auth`). `docs/entendimiento.md` dejó esto como pregunta abierta para John tras el trabajo de T1.4/T1.5/T1.6.
- **Decisión**: se conserva el nombre ya desplegado, `Nova_Casa_Simulator`, para External Credential y Named Credential. No se renombra para igualar el backlog.
- **Alternativa descartada**: renombrar los componentes a `Nova_Casa_Simulator_Auth` para que coincidan con la especificación original de T1.1.
- **Trade-off**: renombrar una External Credential o Named Credential ya desplegada y conectada (BR-201, HP-01 ya mergeado) implica recrear la conexión y volver a resolver el merge field `$Credential.<nombre>.BearerToken` en la Named Credential — riesgo de romper la autenticación ya validada, por un cambio puramente cosmético. Mantener el nombre actual evita ese riesgo; el costo es que el backlog original (T1.1) queda desalineado con lo real hasta que se corrija ahí.
- **Riesgo / dependencia**: ninguno funcional. Cualquier doc o tarea que siga refiriéndose a `Nova_Casa_Simulator_Auth` queda desactualizada.
- **Siguiente acción**: corregir la referencia a `Nova_Casa_Simulator_Auth` en la lista de backlog de Slack (tarea T1.1) para que apunte al nombre real. `docs/entendimiento.md` debe actualizarse para cerrar la pregunta abierta referenciando esta entrada, en la rama donde vive ese archivo.

## D005 — El edificio es `Account`; `External_Id__c` para upsert del catálogo

- **Estado**: Propuesta (parcial — ver alcance abajo)
- **Fecha**: 2026-10-01
- **Contexto**: BR-208/US-208 exigen que el operador acceda solo a edificios/activos autorizados. Hoy no existe un objeto de edificio en el modelo (`Asset` modela el activo/equipo, no el edificio que lo contiene), y Juan Diego necesita identificarlo para su trabajo en curso. Una propuesta anterior sobre este mismo tema (sharing completo: OWD, permission set de operador, reglas de sharing) se registró y se perdió al mergear `main` dentro de esa rama (PR #9, cerrada sin mergear) — no llegó a quedar en este archivo.
- **Decisión** (alcance de este commit, bajo riesgo y reversible): el edificio se modela con **`Account`** estándar. Se agrega `Account.External_Id__c` (Text(50), external ID, unique), espejando `Asset.External_Id__c`, para upsert del catálogo de edificios (p.ej. `BLD-BOG-01`).
- **Alternativa descartada**: objeto custom `Edificio__c` — un objeto custom debe ganarse su lugar (ver "formativa" en `AGENTS.md`); `Account` estándar es suficiente para representar un edificio.
- **Trade-off**: reutiliza sharing y metadata estándar de Salesforce, a cambio de estirar la semántica habitual de `Account`.
- **Riesgo / dependencia**: **fuera de alcance de este commit, todavía pendiente y sin aprobar**: el lookup `Asset.Account`, el cambio de OWD (Account = Private, Asset/Lectura_Vigente__c = Controlled by Parent), el permission set `Nova_Casa_Operator`, las reglas de sharing a nivel de registro, y el cumplimiento `with sharing`/FLS en Apex. El cambio de OWD es difícil de revertir — necesita PR propio, acuerdo de John y Juan Diego, deploy solo desde `main` (regla de `CONTRIBUTING.md`), y aprobación del facilitador MDSS por tocar BR-208. Solo se adelanta aquí el campo de identidad porque es de bajo riesgo y reversible por sí solo.
- **Siguiente acción**: aprobar el resto del modelo de sharing (OWD, permission set, reglas de sharing, Apex `with sharing`) antes de implementar US-208; documentar y probar con dos usuarios de permisos distintos cuando se implemente.

## Pendientes heredados de la sección "Acuerdos" (abiertos desde Discovery, sin cerrar en Development)

Estos puntos necesitaban una entrada D00X cada uno antes de cerrar el entregable 6 de Discovery. El entregable se aprobó y ya estamos en Development (ver `AGENTS.md`), pero solo el objeto de intervención (ver D001 arriba) y el edificio (ver D005 arriba, parcial) tienen entrada; los otros dos siguen sin ella:

1. Regla determinista cuando dos señales válidas del mismo `asset`+`measurement.type` tienen el mismo `occurredAt`.
2. Operadores y valores exactos de umbral por `asset.type` + `measurement.type` (van en metadata, no en código).
## D003 — Empate de `occurredAt`: gana la mayor severidad, luego `messageId`

- **Estado**: Aceptada
- **Fecha**: 2026-10-01
- **Contexto**: el acuerdo de Discovery deja pendiente la regla para cuando dos señales válidas del mismo `asset`+`measurement.type` llegan con el mismo `occurredAt` — exige que sea determinista y prohíbe que el orden de llegada decida.
- **Decisión**: gana la lectura con mayor severidad resultante (comparando contra `Umbral__c` igual que en clasificación normal, usando el mismo nivel numérico que ya alimenta `Severidad_Nivel__c`). Si la severidad también empata, se usa `messageId` como segundo criterio, en orden alfabético ascendente (puramente determinista, sin significado de negocio).
- **Alternativa descartada**: desempatar solo por `messageId` sin pasar primero por severidad — más simple de implementar, pero puede dejar como vigente una lectura menos severa cuando ambas comparten timestamp, lo que iría contra el espíritu de "ver la condición más crítica sin ambigüedad" del problema de Laura. También se descartó marcar el caso como `Conflicto` sin elegir ganadora: el acuerdo pide explícitamente una regla que sí decida, no que aplace la decisión a revisión humana.
- **Trade-off**: la regla de severidad es más fiel al objetivo del producto, a cambio de depender de que la clasificación de severidad ya esté resuelta en el mismo paso de procesamiento (no es un criterio independiente y aislado como lo sería `messageId` solo).
- **Riesgo / dependencia**: depende de que los umbrales (`Umbral__c`, ver pendiente abajo) tengan valores reales antes de poder implementar y probar esta regla con casos concretos.
- **Siguiente acción**: implementar en la lógica de clasificación (Apex, aún sin empezar) y cubrir con un test que falle si el empate se resuelve por orden de llegada en lugar de severidad.

## Pendientes heredados de la sección "Acuerdos" (abiertos desde Discovery, sin cerrar en Development)

Estos puntos necesitaban una entrada D00X cada uno antes de cerrar el entregable 6 de Discovery. El entregable se aprobó y ya estamos en Development (ver `AGENTS.md`), pero solo el objeto de intervención (D001) y el empate de `occurredAt` (D003 arriba) tienen entrada; los otros dos siguen sin ella:

1. Operadores y valores exactos de umbral por `asset.type` + `measurement.type` (van en metadata, no en código).
2. Modelo de sharing de edificios/activos para el operador (BR-208).

## Riesgos generales del sprint

- **Dependencia de facilitador**: cada entregable requiere aprobación externa; un ciclo de revisión lento puede bloquear el avance a Development.
- **Ambigüedad de "mensaje inválido"** (BR-202): sin definición cerrada, el ejemplo inválido que pide el entregable 5 (contrato del mensaje) queda pendiente de escribir.
- **Frontera formativa vs. tiempo disponible**: Platform Events + Apex bulkificado + LWC + seguridad + tests en 2 semanas es ambicioso; priorizar el recorrido de Laura (historia de referencia) sobre cobertura exhaustiva.
