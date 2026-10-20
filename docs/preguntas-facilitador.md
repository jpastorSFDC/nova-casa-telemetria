# Preguntas para el facilitador de MDSS

Estado contra `main` ebc7188 (2026-10-16). Cada bloque citado (`>`) es un comentario para pegar en la tarjeta de MDSS indicada (`CONTRIBUTING.md`, "Board and backlog": los acuerdos importantes van como comentarios en la tarjeta). Las decisiones de abajo están en **Propuesta** en [decisiones.md](decisiones.md), salvo D004 y D022, que el equipo ya aceptó; D005 deja pendiente la aprobación del facilitador sobre el cambio de OWD. Con la respuesta se pasan a Aceptada o se ajustan.

No se cambia código antes de la respuesta. Si una respuesta contradice lo implementado, primero se registra el cambio en `decisiones.md` y después se hace el PR.

| Tarjeta | Decisión | Qué se pregunta | Si la respuesta es "no" |
|---|---|---|---|
| US-201 | D031, D023 | ¿La ingesta disparada a mano y publicada desde Apex cumple "Platform Events reales"? ¿Qué devuelve el simulador al expirar la sesión? | Programar la ingesta; ajustar los reintentos |
| US-202 | D032 | ¿Es esta la definición de señal "inválida"? | Ajustar reglas y pruebas del handler |
| US-205 y US-203 | D039, D011 (h) | Respondida de palabra el 2026-10-17: un caso abierto por activo, y las críticas siguientes solo lo actualizan (D039 Aceptada). Queda dejarlo por escrito en la tarjeta. ¿Una crítica más vieja que otra del mismo lote queda solo como evidencia? | Mantener un caso por mensaje crítico único (D010) y explicar la limitación; si confirma, cambiar el handler, `IntervencionService` y `Case`, y repetir los 5 escenarios |
| US-204 y US-206 | D004, D006, D019 | ¿Operadores, valores y límite exacto? ¿Vale `Umbral__c` como "mecanismo administrativo elegido"? | Cambiar datos de `Umbral__c` (sin código) o el objeto |
| US-208 | D005, D022, D020, D021, D024 | ¿Vale el modelo de sharing y sus tres excepciones en modo sistema? | Rehacer el OWD o las excepciones |
| US-209 | D024, D034, D011 | ¿Pueden los otros roles ver resultado y valor? ¿Cómo se marca un conflicto? | Quitar campos del historial; separar el marcador |

## US-201 — D031 y D023

> **Recepción.** El criterio dice: «El simulador publica Platform Events reales hacia la organización y el suscriptor Apex los recibe.» El simulador, tal como lo usamos (`POST /session`, `GET /telemetry` con cursor y `GET /catalog`), no empuja nada hacia la organización; el ejemplo de contrato del brief solo documenta `GET /telemetry` y no incluye el paso de sesión ni el catálogo. Desde D040 la ingesta corre sola cada 5 minutos (Scheduled Apex) y también se puede lanzar a mano con «Traer señales»; nuestro Apex llama al simulador y publica un `Senial_Sensor__e` por mensaje con `EventBus.publish`, y el suscriptor `SenialSensorTrigger` lo procesa de forma asíncrona (lotes de hasta 200). ¿Cumple esto el criterio 1, aunque el evento lo publique nuestro Apex y no el simulador (D031)?
>
> **Sesión.** ¿Qué devuelve el simulador cuando expira una sesión (suponemos 409/410) o cuando limita la tasa (429/5xx)? ¿Una sesión nueva repite el mismo `source` + `messageId`? ¿Respeta `batchSize`? (`QA_200` devolvió 200 por página aunque pedimos 50.)

Si no cumple: ingesta programada (D031 la descartó por añadir operación y competir por el cursor, D025).

## US-202 — D032

> Una señal queda `Rechazada` con motivo, y las demás del lote siguen, cuando: (1) falta o no es numérico el valor, o falta o no es ISO 8601 `occurredAt`; (2) su activo no está en el catálogo; (3) su edificio no es el del activo; (4) no hay umbral activo para su tipo de activo y medición; (5) su unidad no es la esperada; (6) un campo excede el largo permitido o `Message_Type` no es un valor permitido; (7) el valor cae en un umbral de severidad `Invalida` (rango físico). Una señal sin `source` o sin `messageId` no puede tener fila de log (la identidad es la clave): solo se cuenta. BR-202 dice «Debe existir evidencia de cuál falló y por qué» y US-202 que «Una señal incompleta, de activo desconocido o con medición incompatible queda rechazada con motivo»; para las señales sin identidad solo cumplimos eso en agregado (un conteo), no una por una. ¿Es esta su definición de «inválido»? ¿Aceptan que las señales sin identidad dejen solo un conteo?

Si no: se ajustan las reglas y las pruebas de `SenialSensorHandlerTest`.

## US-205 y US-203 — D039 y D011 (h)

Esta tarjeta tenía una pregunta sobre D011 (h) (cuántas intervenciones salen según cómo se parta el flujo en lotes). La indicación verbal del facilitador de consolidar la reemplaza como pregunta principal; D039 la recoge en [decisiones.md](decisiones.md). Los puntos 1 y 3 los precisó John el 2026-10-16 (un caso abierto por activo, que sigue abierto mientras no se resuelva); los puntos 2, 4 y 5 son una **propuesta del equipo** donde nadie precisó nada. Tienen la misma numeración que "Por confirmar" en D039: ajustarlos antes de pegar si John o Juan Diego piensan otra cosa. Los puntos 6 a 8 de D039 (identidad del caso, casos manuales, empate entre mediciones) son decisiones internas y no se le preguntan.

> **Consolidación.** El acuerdo «Incidente» dice: «En el alcance base se garantiza una intervención como máximo por mensaje crítico único. Consolidar varias lecturas con claves distintas en un solo incidente abierto es un extra; debe explicarse la limitación del diseño base.» Hoy implementamos el alcance base: un caso por mensaje crítico único, así que un activo con varias señales críticas distintas tiene varios casos abiertos a la vez. Nos indicó de palabra que no hay que abrir muchas intervenciones: la misma intervención sigue abierta y registra la señal más actual mientras siga siendo crítica. Queremos dejarlo por escrito y confirmar lo que no se precisó:
>
> 1. **Alcance.** Entendemos que es un caso abierto por activo, no por activo y tipo de medición: si llega otra señal crítica mientras el caso no se ha resuelto, no se abre otra intervención y solo se actualiza la información del caso. ¿Es así? Es lo mismo que ya hace la comprobación «ya hay una intervención abierta» de la pantalla del operador. Si dos mediciones del mismo activo son críticas, el caso muestra la más reciente y la otra queda en el registro de señales.
> 2. **Qué se registra.** Proponemos tipo de medición, valor, unidad y hora de origen de la última señal crítica en el caso; las anteriores quedan en el registro de señales, enlazadas al caso.
> 3. **Cuando deja de ser crítica.** Entendemos que el caso sigue abierto mientras no se resuelva y que lo cierra una persona, no la llegada de una lectura normal. ¿Es así?
> 4. **Después de cerrarlo.** ¿Una crítica nueva abre un caso nuevo? Proponemos que sí.
> 5. **Qué no actualiza el caso.** Proponemos que no lo cambien un reenvío de la misma clave, la misma clave con otro contenido (conflicto) ni una señal más vieja que la lectura vigente.
>
> **¿Implementarlo o explicarlo?** El acuerdo pide explicar la limitación del diseño base y trata la consolidación como un extra. ¿Quieren que la implementemos, o basta con explicar la limitación?
>
> ¿Lo confirma por escrito en esta tarjeta?
>
> **Señal atrasada.** El acuerdo dice: «Se conserva su evidencia sin reemplazar el estado actual. La política inicial es no crear una intervención nueva por una crítica atrasada; una alternativa es admisible si distingue revisión histórica de estado actual y cuenta con criterios y pruebas explícitos.» Hoy una lectura queda `Atrasada` si su `occurredAt` es menor que el de la vigente guardada **o que el de la ganadora de su mismo lote** para el mismo activo y medición (D011 h, decidido por John el 2026-10-05; el facilitador no lo ha confirmado). Con una sola intervención abierta por activo, esa regla ya no multiplicaría los casos de un activo, pero sigue decidiendo si se abre el primero y qué señal registra el caso: una crítica más vieja que una normal más nueva del mismo lote queda `Atrasada` y sin caso, y si llega en otro lote sí lo abre. ¿Confirma que una crítica más vieja que otra del mismo lote o que la lectura vigente queda solo como evidencia y no actualiza el caso?

Si no confirma: se mantiene un caso por mensaje crítico único (D010) y la limitación se sigue explicando (D033, punto 6). D039 pasa a Rechazada, con la fecha y el motivo.

Si confirma: D039 pasa a Aceptada con los detalles que responda. Hay que cambiar `IntervencionService`, `SenialSensorHandler` y campos de `Case`, que es metadata compartida: avisar antes en Slack. Después, revisar `IntervencionServiceTest` y las pruebas de `SenialSensorHandlerTest` que cuentan casos (incluidas `unaCriticaMasViejaEnElMismoLoteQuedaAtrasadaYSoloLaMasNuevaAbreCase` y `...AunqueLlegueDespuesDeLaNueva`, que fijan el comportamiento actual a propósito) y volver a correr `QA_200`, `DUPLICATES`, `BOUNDARIES`, `CRITICAL_BURST` y `LATE_MESSAGES`. Queda por resolver cómo se evita que dos lotes abran a la vez el primer caso de un mismo activo (D039, riesgo 5).

## US-204 y US-206 — D004, D006, D019

> US-204 pide que «Los límites no están escritos directamente en el código» y que «Una persona autorizada puede modificarlos mediante el mecanismo administrativo elegido». Elegimos un objeto personalizado, `Umbral__c`, editable por coordinador y admin sin desplegar; no Custom Metadata, que exigiría permisos de administrador (D004). Los valores iniciales salen de la tabla de referencia del equipo; por ejemplo, cámaras: Advertencia GT 90 y Crítica GT 180 segundos; temperatura: Advertencia GT 30 y Crítica GT 35; Inválida en GE 81 y LE −11 (D019). En el límite exacto, `GT` y `LT` no lo cumplen (30 es Normal, 35 es Advertencia) y `GE` y `LE` sí lo cumplen. ¿Confirman operadores y valores por tipo de activo y medición? ¿Aceptan `Umbral__c` como el mecanismo administrativo elegido?

Si no: cambiar operadores o valores es un cambio de datos, no de código (D004). Si rechazan el objeto, es una migración.

## US-208 — D005, D022, D020, D021, D024

> Para BR-208, `Account` y `Case` están en Private y `Asset` en Controlled by Parent; el coordinador y el gerente ven por jerarquía de roles, sin View All (D022), y cada edificio es de un operador. Tres operaciones de la pantalla corren en modo sistema a propósito, siempre después de comprobar en modo usuario que la persona ve el activo: crear la intervención manual, porque el operador no tiene Create sobre `Case` y su llave es una custom permission (D020); la comprobación de «ya hay una intervención abierta», que solo devuelve un Boolean (D021, `OpenCaseCheck`); y el historial por activo, que no devuelve motivo, huella ni identidad (D024). Aparte, la ingesta no depende de permisos de operador: el handler es `without sharing` y el suscriptor corre como un usuario de integración con su propio permission set (D011, D017). ¿Aceptan este modelo de sharing y estas tres excepciones?

Si no: el cambio de OWD es difícil de revertir (D005): va en su propio PR, con acuerdo de los dos y deploy solo desde `main`.

## US-209 — D024, D034, D011

> **Qué ven los otros roles.** BR-209 habla del administrador. El historial por activo muestra al operador, al coordinador y al gerente, solo de los activos que ya ven: tipo de señal, fecha, resultado (`Rechazada`, `Conflicto`…), tipo de medición, valor y unidad. Nunca el motivo, la huella ni la identidad. ¿Es aceptable que esos roles vean el resultado y el valor de una señal rechazada o en conflicto?
>
> **Conflicto.** Cuando llega la misma clave con otro contenido, la fila original, aunque ya fuera `Procesada`, pasa a `Resultado = Conflicto`; conserva su caso, su tipo de medición, valor y unidad originales (D034), y el contenido nuevo no se guarda. Sin cambio de estado ni intervención. ¿Basta con eso, o la fila original debe seguir `Procesada` con el conflicto marcado aparte?

Si no: quitar campos del historial (D034 los agregó) o añadir un campo de marca de conflicto.

## Al recibir las respuestas

1. Pasar la decisión a **Aceptada** (o ajustarla) con la fecha y quién respondió. Si la respuesta sigue siendo verbal, decirlo en la decisión: sin comentario en la tarjeta no queda registro de que se dio.
2. Quitar de [evidencia](evidencia-escenarios.md) la nota «Pendiente: el facilitador debe confirmar…» de la historia.
3. Solo si hay un cambio de comportamiento: registrar el cambio en `decisiones.md`, y después el PR con su prueba.
