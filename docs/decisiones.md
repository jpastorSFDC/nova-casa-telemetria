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

## Pendientes heredados de la sección "Acuerdos" (aún por cerrar en Discovery)

Estos cuatro puntos necesitan una entrada D00X cada uno antes de cerrar el entregable 6:

1. Regla determinista cuando dos señales válidas del mismo `asset`+`measurement.type` tienen el mismo `occurredAt`.
2. Operadores y valores exactos de umbral por `asset.type` + `measurement.type` (van en metadata, no en código).
3. Objeto de intervención: Case, Work Order u otro, y por qué.
4. Modelo de sharing de edificios/activos para el operador (BR-208). → ver D005.

## D005 — El edificio es `Account`; activos Controlled by Parent; acceso por permission set + sharing de registro

- **Estado**: Propuesta
- **Fecha**: 2026-09-30
- **Contexto**: BR-208/US-208 exigen que cada usuario acceda solo a los datos y acciones autorizados, y que la restricción se sostenga también al pedir información directamente a Apex, no solo ocultándola en el LWC. Hoy no existe un objeto de edificio (Asset modela el activo/equipo), no hay permission set de operador, ni perfiles, roles ni reglas de sharing — la seguridad actual es solo `Nova_Casa_Admin` (ViewAll/ModifyAll) más `Nova_Casa_Simulator_Integration`, aislado para la ingesta.
- **Decisión**:
  1. El edificio se modela con **`Account`** estándar, relacionado al activo por el lookup estándar `Asset.Account`.
  2. Se agrega `External_Id__c` (Text, `externalId`, `unique`) en `Account` como ID externo del edificio (p.ej. `BLD-BOG-01`), espejando `Asset.External_Id__c`, para upsert del catálogo de edificios.
  3. OWD: `Account` = Private; `Asset` = Controlled by Parent (de `Account`); `Lectura_Vigente__c` mantiene ControlledByParent (hereda de Asset); `Log_Senial__c` sigue Private (solo Admin).
  4. Se crea un permission set de operador, `Nova_Casa_Operator`, con Read (sin ViewAll/ModifyAll) sobre `Account`/`Asset`/`Lectura_Vigente__c` y FLS de solo lectura; sin acceso a `Log_Senial__c` ni a acciones administrativas. La asignación operador → edificios autorizados se hace por **sharing a nivel de registro de `Account`** (grupo público + regla de compartición), no por permisos de objeto.
  5. El cumplimiento en servidor se hace con Apex `with sharing` + FLS/CRUD (`WITH SECURITY_ENFORCED` o `Security.stripInaccessible`) en la ruta de consulta del operador. La ingesta corre en su propio contexto, autorizada por `Nova_Casa_Simulator_Integration`, separada del contexto del operador (Acuerdo "Seguridad").
  6. Se documenta una matriz breve operador/coordinador/administrador como parte de la implementación, para satisfacer las compuertas de aprobación del backlog.
- **Alternativa descartada**: objeto custom `Edificio__c` (un objeto custom debe ganarse su lugar; `Account` es suficiente) · seguridad resuelta solo en el LWC (viola BR-208, que exige protección también en el servidor) · sharing dinámico por múltiples ciudades o regiones (fuera de alcance, según "Esfuerzo relativo" de US-208).
- **Trade-off**: usar `Account` como edificio reutiliza el sharing estándar de Salesforce y evita metadata nueva, a cambio de estirar su semántica habitual; Controlled by Parent simplifica el cascadeo de visibilidad pero acopla la del activo a la del edificio.
- **Riesgo / dependencia**: cambiar el OWD es difícil de revertir, así que su implementación necesita PR propio, acuerdo de John y Juan Diego, y deploy solo desde `main` (regla de CONTRIBUTING.md). Depende de crear el permission set de operador y las reglas de sharing. Requiere aprobación del facilitador MDSS.
- **Siguiente acción**: aprobar D005; implementar en la historia US-208 (`Account.External_Id__c`, cambio de OWD, `Nova_Casa_Operator`, reglas de sharing, Apex `with sharing` y pruebas con dos usuarios de permisos distintos, uno con acceso insuficiente).

## Riesgos generales del sprint

- **Dependencia de facilitador**: cada entregable requiere aprobación externa; un ciclo de revisión lento puede bloquear el avance a Development.
- **Ambigüedad de "mensaje inválido"** (BR-202): sin definición cerrada, el ejemplo inválido que pide el entregable 5 (contrato del mensaje) queda pendiente de escribir.
- **Frontera formativa vs. tiempo disponible**: Platform Events + Apex bulkificado + LWC + seguridad + tests en 2 semanas es ambicioso; priorizar el recorrido de Laura (historia de referencia) sobre cobertura exhaustiva.
