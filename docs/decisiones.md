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

## D003 — Empate de `occurredAt`: gana la mayor severidad, luego `messageId`

- **Estado**: Aceptada
- **Fecha**: 2026-10-01
- **Contexto**: el acuerdo de Discovery deja pendiente la regla para cuando dos señales válidas del mismo `asset`+`measurement.type` llegan con el mismo `occurredAt` — exige que sea determinista y prohíbe que el orden de llegada decida.
- **Decisión**: gana la lectura con mayor severidad resultante (comparando contra `Umbral__c` igual que en clasificación normal, usando el mismo nivel numérico que ya alimenta `Severidad_Nivel__c`). Si la severidad también empata, se usa `messageId` como segundo criterio, en orden alfabético ascendente (puramente determinista, sin significado de negocio).
- **Alternativa descartada**: desempatar solo por `messageId` sin pasar primero por severidad — más simple de implementar, pero puede dejar como vigente una lectura menos severa cuando ambas comparten timestamp, lo que iría contra el espíritu de "ver la condición más crítica sin ambigüedad" del problema de Laura. También se descartó marcar el caso como `Conflicto` sin elegir ganadora: el acuerdo pide explícitamente una regla que sí decida, no que aplace la decisión a revisión humana.
- **Trade-off**: la regla de severidad es más fiel al objetivo del producto, a cambio de depender de que la clasificación de severidad ya esté resuelta en el mismo paso de procesamiento (no es un criterio independiente y aislado como lo sería `messageId` solo).
- **Riesgo / dependencia**: depende de que los umbrales (`Umbral__c`, ver pendiente abajo) tengan valores reales antes de poder implementar y probar esta regla con casos concretos.
- **Siguiente acción**: implementar en la lógica de clasificación (Apex, aún sin empezar) y cubrir con un test que falle si el empate se resuelve por orden de llegada en lugar de severidad.

## D004 — `Umbral__c` es objeto custom, no Custom Metadata Type

- **Estado**: Aceptada
- **Fecha**: 2026-10-01
- **Contexto**: BR-204 pide que los límites de clasificación sean administrables sin redesplegar código. Custom Metadata Type (`__mdt`) es la opción por defecto para ese tipo de dato de configuración, pero sus registros solo se editan desde Setup y requieren el permiso de sistema "Customize Application" — exclusivo de administrador. El acuerdo del sprint es que un perfil no-admin (operador/coordinador) pueda ajustar los umbrales sin que se le dé acceso de administrador.
- **Decisión**: `Umbral__c` se modela como objeto custom estándar (`__c`), no como Custom Metadata Type. El acceso de edición se controla con FLS/permission set sobre el objeto, igual que cualquier otro dato operativo.
- **Alternativa descartada**: `Umbral__mdt` (Custom Metadata Type).
- **Trade-off**: se gana poder darle edición a un perfil no-admin sin tocar "Customize Application"; se sacrifica lo que CMDT da gratis (los registros viajan como metadata y se despliegan solos entre entornos, sin Data Loader ni scripts de datos).
- **Riesgo / dependencia**: ninguno funcional. Falta que el permission set que dé acceso a `Umbral__c` quede definido (ver D005/BR-208) para que la edición no-admin sea real y no solo teórica.
- **Siguiente acción**: al definir el permission set del operador/coordinador (D005), incluir CRUD/FLS de `Umbral__c` para el perfil que deba poder ajustar los límites.

## D006 — Siembra de `Umbral__c` desde la carga del catálogo (HP-04)

- **Estado**: Propuesta
- **Fecha**: 2026-10-05
- **Contexto**: T3.2 pide un umbral por cada combinación del catálogo. `Umbral__c` no tiene campo de id externo y `/catalog` entrega `thresholdsReference` como rangos (min/max), no como operador + valor.
- **Decisión**: `CatalogoService.loadCatalog()` siembra `Umbral__c` con la tabla de referencia del equipo (T2.7), una vez por cada `asset.type` + `measurement` del catálogo (la unidad sale del catálogo). Si esa combinación ya tiene cualquier `Umbral__c` (editado, desactivado o no), no se siembra nada para ella.
- **Alternativa descartada**: clave natural completa (tipo, medición, severidad, operador, valor, unidad): un umbral editado dejaría de coincidir y se duplicaría. Un campo de id externo: cambio de modelo sin necesidad.
- **Trade-off**: se gana idempotencia y respeto a lo que el usuario cambió; se sacrifica que un umbral borrado a mano no se restituye solo, ni se agregan reglas nuevas a una combinación ya sembrada.
- **Riesgo / dependencia**: operadores y valores siguen "por acordar" (ver pendiente 1 abajo); la tabla vive en el código como valor inicial, la fuente operativa es el objeto.
- **Criterios de prueba**: `CatalogoServiceTest` demuestra la regla: un umbral por combinación (`shouldSeedOneThresholdSetPerCombination_WhenCatalogIsValid`), recargar no duplica (`shouldNotDuplicateThresholds_WhenLoadedTwice`), un umbral editado o desactivado se conserva (`shouldKeepEditedThreshold_WhenCatalogIsReloaded`), un conjunto parcial no se completa (`shouldNotCompletePartialSet_WhenCatalogIsReloaded`) y un usuario sin acceso a `Umbral__c` recibe una `CatalogoServiceException` envuelta (`shouldThrowException_WhenRunningAsUserWithoutUmbralAccess`).
- **Nota**: sembrar estos operadores y valores significa que el equipo ya los escogió en la práctica; siguen pendientes de confirmación del facilitador.
- **Siguiente acción**: confirmar operadores y valores con el facilitador.
## D007 — La antigüedad de la señal se marca con un parámetro de presentación (`staleMinutes`), no con un umbral

- **Estado**: Propuesta
- **Fecha**: 2026-10-05
- **Contexto**: BR-207 pide que el operador reconozca la antigüedad de la información. La pantalla necesita un corte para marcar una señal como "desactualizada". El acuerdo "Umbrales fuera del código" cubre los límites de clasificación de severidad (D004), no este corte.
- **Decisión**: el corte es una propiedad de diseño del LWC (`staleMinutes`, 15 por defecto), editable en Lightning App Builder para páginas App y Home. Solo decide si se muestra la marca "(desactualizada)"; no influye en la severidad ni en ninguna decisión del servidor. El valor por defecto vive en una sola constante del JS, con el mismo valor en `js-meta.xml`.
- **Alternativa descartada**: valor por tipo de activo o de medición en `Umbral__c` o Custom Metadata. Agrega un objeto o un despliegue y no hay una cadencia de emisión por sensor acordada que lo justifique.
- **Trade-off**: se gana una pantalla simple y ajustable sin tocar código ni datos; se sacrifica un corte distinto por tipo de sensor, de modo que un sensor lento puede verse "desactualizado" sin estarlo. Con la ubicación Tab no hay configuración y rige el valor por defecto.
- **Riesgo / dependencia**: si la cadencia real del simulador supera los 15 minutos, habrá falsos "desactualizada". Hay que contrastar el valor con la cadencia de emisión del simulador.
- **Siguiente acción**: validar los 15 minutos contra el simulador. Criterio de prueba: una señal por debajo del corte no lleva marca, una por encima la lleva, y la ubicación Tab usa el valor por defecto.

## D008 — La pantalla del operador se aparta del prototipo de baja fidelidad

- **Estado**: Propuesta
- **Fecha**: 2026-10-05
- **Contexto**: `entregables/02-prototipo-baja-fidelidad.html` guía el diseño pero no es la especificación. La implementación de US-207 difiere en varios puntos.
- **Decisión**: (1) tarjetas con `lightning-card`, insignias e íconos de utilidad SLDS en lugar de tarjetas e íconos SVG propios; (2) se agregan un filtro por tipo de activo, un botón de actualizar y la marca de señal desactualizada; (3) cada tarjeta lista una lectura por tipo de medición, en lugar de una sola; (4) la intervención se abre con el enlace "Caso N" y su estado, en lugar de un botón "Ver intervención"; (5) la interfaz va en español y los errores del controlador en inglés; (6) los contadores del resumen cubren solo los activos de la vista filtrada y así se rotulan ("en esta vista"); (7) si se alcanza el tope del controlador, la pantalla lo avisa.
- **Alternativa descartada**: reproducir el prototipo tal cual; obliga a componentes propios y pierde accesibilidad y mantenimiento de los componentes base.
- **Trade-off**: se gana consistencia con SLDS y la cobertura de BR-207 (antigüedad, filtros, estados); se sacrifica fidelidad visual al prototipo.
- **Riesgo / dependencia**: el facilitador MDSS podría pedir el aspecto del prototipo. Los mensajes de error en inglés y la interfaz en español son inconsistentes.
- **Siguiente acción**: mostrar la pantalla al facilitador; unificar el idioma de los errores si lo pide.

## D009 — La pantalla del operador asume lecturas válidas en `Lectura_Vigente__c` y desempata por Id

- **Estado**: Propuesta
- **Fecha**: 2026-10-05
- **Contexto**: el acuerdo dice que la severidad del activo es la más alta de sus últimas lecturas válidas. `Lectura_Vigente__c` no tiene un campo de validez. Además, D003 desempata por mayor severidad y luego por `messageId`, dato que este objeto no guarda.
- **Decisión**: (1) `ActivosOperadorController` asume que `Lectura_Vigente__c` solo contiene lecturas válidas: los mensajes inválidos se rechazan antes de escribir (T2.12), por lo que la pantalla no vuelve a validar. (2) Si dos lecturas del mismo activo y tipo empatan en `occurredAt` y severidad, gana el menor Id de registro, de forma determinista y sin depender del orden de llegada. Es una red de seguridad de lectura: `Clave__c` es único, así que normalmente hay una sola fila por clave.
- **Alternativa descartada**: agregar un campo de validez a `Lectura_Vigente__c` o guardar `messageId` en la lectura; sumaría datos al modelo por un caso que la ingesta ya evita.
- **Trade-off**: pantalla simple y sin lógica de ingesta duplicada; se sacrifica la defensa en profundidad si la ingesta llegara a escribir una lectura inválida.
- **Riesgo / dependencia**: depende de que la ingesta rechace de verdad los mensajes inválidos y no escriba conflictos en `Lectura_Vigente__c`. Si eso cambia, la pantalla mostraría una severidad basada en una lectura inválida.
- **Siguiente acción**: confirmar que las pruebas de ingesta (T2.12) fallan si una lectura inválida llega a `Lectura_Vigente__c`.

## D010 — Una intervención (`Case`) por mensaje crítico único, idempotente por identidad y en modo sistema

- **Estado**: Propuesta
- **Fecha**: 2026-10-05
- **Contexto**: BR-205 y el acuerdo "Incidente" piden como máximo una intervención por mensaje crítico único; D001 fijó `Case` como objeto. `Case.Identidad_Senal__c` (único, id externo, 60 caracteres) ya existe para impedir dos Cases del mismo mensaje. Hay que decidir cómo se abre el Case en un lote de hasta 200 y con qué permisos.
- **Decisión**: (1) `IntervencionService.abrir` abre un `Case` por identidad (`source` + `|` + `messageId`), sin consolidar identidades distintas en un incidente abierto. (2) Idempotencia por identidad: una consulta busca los Cases existentes por `Identidad_Senal__c`; si existe, la identidad apunta a ese Case y no se crea ni se actualiza nada; una identidad repetida dentro del lote crea un solo Case. (3) Corre `without sharing` y con `SYSTEM_MODE` (consulta y DML) porque la ingesta se ejecuta como Automated Process y no depende de permisos de operador/admin; la autorización de consulta (BR-208) es otra ruta. (4) Éxito parcial: un solo `Database.insert(..., false)`; cada fallo se devuelve por identidad en `errorPorIdentidad` sin revertir las demás filas. Si el fallo es `DUPLICATE_VALUE` (otra ejecución ganó la carrera), se resuelve al Case ganador con una consulta extra. Los Cases nuevos llevan `Origin` = `Telemetria`, `Status` = `En curso`, `Priority` = `Critica`.
- **Alternativa descartada**: consolidar varias identidades en un incidente abierto por activo (alcance extra sin decisión); `allOrNone` (una fila mala tumbaría el lote de 200); `with sharing` (la ingesta dependería de permisos de usuario).
- **Trade-off**: se gana idempotencia garantizada por la restricción única y aislamiento de errores por fila; se sacrifica una intervención por activo (varias señales críticas distintas abren varios Cases) y que el modo sistema omite FLS/CRUD en esta ruta.
- **Riesgo / dependencia**: el llamador decide qué señal es crítica y no tardía; este servicio no lo valida. Los valores `Telemetria`, `En curso` y `Critica` viven en los standard value sets versionados del repo y deben estar desplegados. La detección de conflicto de contenido (misma identidad, distinto `Huella__c`) pertenece al handler, que no debe llamar a `abrir` para un Conflicto, una señal tardía (Atrasada), un perdedor de desempate (D003) o una señal Rechazada: `abrir` solo recibe señales críticas que ganaron. `abrir` nunca compara contenido y devuelve el Case existente para una identidad conocida. Riesgos: la carrera concurrente `DUPLICATE_VALUE` está resuelta en código pero no tiene prueba.
- **Siguiente acción**: criterios de prueba: reenviar la misma identidad no crea un segundo Case y devuelve el existente; identidad duplicada en el lote crea uno; una solicitud sin identidad o sin `assetId` cae en `errorPorIdentidad` sin afectar a las demás; 200 solicitudes no consumen SOQL/DML por fila.

## D011 — El handler persiste log y lectura vigente, y es dueño de la detección de reenvío, conflicto y señal atrasada

- **Estado**: Propuesta
- **Fecha**: 2026-10-05
- **Contexto**: hasta ahora `SenialSensorHandler` solo clasificaba en memoria. US-201/202/205/206 exigen registrar cada mensaje (publicar no es procesar), mantener la última lectura por activo + medición y abrir una intervención por mensaje crítico único (D010), sin dejar que el orden de llegada decida.
- **Decisión**: (1) Orden de persistencia por lote: consultas (logs por `Identidad__c`, activos por `External_Id__c`, lecturas por `Clave__c`), decisión en memoria, una sola llamada a `IntervencionService.abrir`, upsert de `Lectura_Vigente__c` por `Clave__c`, upsert final de `Log_Senial__c` por `Identidad__c`; todo en `SYSTEM_MODE` con éxito parcial. (2) Una fila en `Publicada` o `Fallida` (o ausente) es primer procesamiento. Una identidad ya procesada con la misma `Huella__c` es reenvío: solo sube `Reenvios__c` y se fija `Ultimo_Reenvio__c`; sin cambio de estado ni intervención. Con distinta huella es `Conflicto`: se marca el log, sin cambio de estado ni intervención. La huella es SHA-256 del contenido sin `deliveryId` ni `publishedAt`. Dentro de un lote, el primer evento de una identidad fija la huella original. (3) Atrasada: una lectura válida estrictamente más antigua (`occurredAt` menor) que la vigente guardada, o que la ganadora del mismo lote para la misma clave, queda en el log como evidencia; `Superada`: la que tiene el mismo `occurredAt` y pierde el desempate D003 contra la vigente o contra la ganadora del lote. Ninguna de las dos sobrescribe la lectura ni abre intervención. Rechazada: dato inválido, sin umbral, unidad incompatible, fuera de rango físico o activo fuera del catálogo. (4) Fallida (T5.16): si no se puede abrir el Case de una crítica ganadora, su log queda `Fallida`, su lectura no se escribe (la vigente anterior sigue intacta) y las demás identidades del lote no se afectan; no hay rollback: si el Case ya se creó (p. ej. falló después el upsert de la lectura), el Case **no se borra** y queda abierto; el reintento con el mismo contenido lo reutiliza porque `abrir` devuelve el Case existente por `Identidad_Senal__c`. Lo mismo si falla el upsert de su lectura. (5) La detección de conflicto de contenido es del handler; `IntervencionService` no compara contenido y solo recibe críticas ganadoras. (6) Endurecimiento: una identidad en `Conflicto` no gana ni abre Case, también dentro del mismo lote (el original y el duplicado distinto quedan fuera de la competencia), y ninguna marca posterior (`Fallida`, `Atrasada`, `Superada`, `Rechazada`) pisa un `Conflicto`. Un reenvío con otra huella sobre una fila `Fallida` o `Publicada` con huella guardada es `Conflicto`, no reemplazo silencioso. `Atrasada` queda solo para lo más antiguo que la lectura (o que la ganadora del lote); perder el desempate D003 con el mismo `occurredAt` es `Superada` (valor nuevo en `Resultado__c`, debe desplegarse antes que el handler). El desempate compara `occurredAt`, severidad, `messageId` y, si aún empatan, el `source`. Las identidades, activos y claves se comparan normalizados (mayúsculas/minúsculas, espacios); `Clave__c` usa el `External_Id__c` del catálogo. Un evento cuyos campos no caben en el destino (identidad/clave 60, `Message_Id__c`/`Source__c` 80, `Delivery_Id__c` 40, `Sensor_Id__c` 50) se rechaza con motivo; si la identidad excede 60 no hay fila de log posible y solo queda evidencia en memoria. El trabajo por evento y cada DML están protegidos con try/catch para que un evento malo no descarte los 200 del lote; un fallo del upsert del log deja contador y detalle (`fallosDeLog`, `erroresDeLog`). El texto no confiable que entra a `Motivo__c` se limpia (sin caracteres de control, máx. 255). La clase es `without sharing` (BR-208: la ingesta no depende de permisos de operador).
- **Alternativa descartada**: escribir la lectura primero y revertirla si falla el Case (un `Savepoint` revertiría también las demás identidades del lote); dejar que `IntervencionService` detecte el conflicto (no conoce la huella ni el estado anterior).
- **Trade-off**: se garantiza que no hay lectura crítica sin intervención y se mantiene el éxito parcial; se sacrifica que, si la crítica ganadora falla, las señales del mismo lote que ella superó quedan `Atrasada` (o `Superada` si empataban en `occurredAt`) y no se promueve la siguiente mejor; una fila `Fallida` que recibe un reenvío con otro contenido pasa a `Conflicto` y ya no se reintenta por reenvío igual; y el reenvío no refresca `Procesado_At__c`.
- **Riesgo / dependencia**: el log solo puede dar fe de un reenvío si la fila ya existe (la ingesta la inserta en `Publicada`); el orden dentro del lote decide cuál evento es el original si una misma identidad llega dos veces con contenido distinto en el mismo lote. Una fila ya `Procesada` que recibe un conflicto pasa a `Conflicto` y conserva `Caso__c`. Implementado con pruebas en `SenialSensorHandlerTest`; pendiente de compilar y ejecutar en el org (sin despliegue todavía).
- **Límites conocidos (aceptados)**: (a) un evento sin `source` o `messageId`, o con identidad de más de 60 caracteres, no deja evidencia persistente: solo contadores y mapas de la transacción (`senialesSinIdentidad`, `rechazadasSinLog`). (b) `Duplicada` sigue en la picklist `Resultado__c` pero el handler nunca la escribe (reservada): el reenvío se registra con `Reenvios__c` y `Ultimo_Reenvio__c`, sin cambiar `Resultado__c`. (c) Se aparta de los valores de `Resultado__c` del prototipo `entregables/03-arquitectura-flujo-datos.html` (Procesada · Duplicada · Atrasada · Invalida · Publicacion rechazada): el handler usa Publicada, Procesada, Rechazada, Atrasada, Superada, Conflicto y Fallida; el prototipo guía el diseño pero no es la especificación. (d) Si el `source` contiene `|`, `desdeVigente` parte mal la identidad guardada (`source|messageId`) y el desempate D003 contra la lectura vigente puede comparar un `messageId` incorrecto; el simulador no usa `|` en `source`. (e) `Lectura_Vigente__c.Unidad__c` y `Log_Senial__c.Message_Type__c` son picklists restringidas sin longitud propia. `Message_Type__c` se valida contra los valores de la picklist (`Schema` describe, sin SOQL/DML): un valor no vacío fuera de ella queda `Rechazada` con motivo que nombra el campo, no se copia a la fila de log, no escribe lectura ni abre Case; un valor vacío se comporta como antes. Para `Unit__c` el handler solo rechaza más de 255 caracteres: un valor corto fuera de la picklist no se valida y haría fallar el upsert de esa fila (queda en `fallosDeLog`). (f) `Occurred_At__c` de Salesforce no guarda milisegundos: el handler trunca `occurredAt` a segundos al leer el evento, de modo que la comparación con la lectura vigente guardada usa la misma precisión y el empate D003 no lo decide el orden de llegada; dos señales que solo difieren en milisegundos cuentan como el mismo `occurredAt`. (g) Si falla el procesamiento de un evento en la etapa de decisión, su fila `Fallida` lleva `Source__c`, `Message_Id__c`, `Occurred_At__c` y `Procesado_At__c` (los dos primeros son obligatorios); no se escribe `Huella__c`, así que no se pisa la original.
- **Siguiente acción**: criterios de prueba: reenvío igual no cambia lectura ni Case y suma `Reenvios__c`; misma identidad con otro valor queda `Conflicto` sin cambios; señal más antigua queda `Atrasada` sin tocar la lectura ni abrir Case; empate de `occurredAt` lo decide D003 sin importar el orden y el perdedor queda `Superada` (no `Atrasada`); un Case que falla deja `Fallida` y sin lectura mientras otra identidad del lote sí se procesa; 200 eventos usan un número fijo de SOQL/DML.

## Pendientes heredados de la sección "Acuerdos" (abiertos desde Discovery, sin cerrar en Development)

Estos puntos necesitaban una entrada D00X cada uno antes de cerrar el entregable 6 de Discovery. El entregable se aprobó y ya estamos en Development (ver `AGENTS.md`), pero solo el objeto de intervención (D001) y el empate de `occurredAt` (D003 arriba) están cerrados del todo; el edificio (D005 arriba) tiene entrada pero solo resuelve el campo de identidad, no el modelo de sharing. Siguen sin cerrar:

1. Operadores y valores exactos de umbral por `asset.type` + `measurement.type` (van en metadata, no en código).
2. Modelo de sharing de edificios/activos para el operador (BR-208) — parcial: D005 define el edificio como `Account`, pero el OWD, el permission set `Nova_Casa_Operator`, las reglas de sharing y el `with sharing`/FLS en Apex siguen pendientes y sin aprobar (ver D005, "Riesgo / dependencia").

## Riesgos generales del sprint

- **Dependencia de facilitador**: cada entregable requiere aprobación externa; un ciclo de revisión lento puede bloquear el avance a Development.
- **Ambigüedad de "mensaje inválido"** (BR-202): sin definición cerrada, el ejemplo inválido que pide el entregable 5 (contrato del mensaje) queda pendiente de escribir.
- **Frontera formativa vs. tiempo disponible**: Platform Events + Apex bulkificado + LWC + seguridad + tests en 2 semanas es ambicioso; priorizar el recorrido de Laura (historia de referencia) sobre cobertura exhaustiva.
