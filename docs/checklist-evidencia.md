# Checklist para guardar la evidencia por historia

Estado contra `main` ebc7188 (2026-10-16). Lo que falta de las historias no es código: son corridas en el org y capturas que solo pueden hacer John o Juan Diego (el agente no corre `sf`). Este checklist dice qué correr, qué mirar y dónde guardarlo. No repite el guion de [demo.md](demo.md) ni los resultados de [evidencia-escenarios.md](evidencia-escenarios.md); los enlaza.

## Antes de empezar

1. **Congelamiento.** Según Slack, la ingesta está congelada desde el 2026-10-14. Confirmar con Juan Diego que ya terminó.
2. **Orden de merges.** La rama local `docs/scenario-evidence` de Juan Diego (corridas 7 a 9) edita `evidencia-escenarios.md` y `demo.md`. Que se mergee primero; después se anotan los resultados en la tabla "Evidencia por historia".
3. **Avisar en Slack** quién corre y a qué hora. Una persona a la vez; las corridas crean filas reales (`CONTRIBUTING.md`).
4. **Todo `sf` va con el prefijo `!`** dentro de Claude Code, o en una terminal normal. El alias del org es `nova-cdo`; las consultas de [acceso.md](acceso.md) todavía dicen `novacasa_sprint_2`: sustituirlo.
5. **Org limpio** antes de cada bloque. `scripts/org-check.sh clean` muestra qué borra y qué queda; `clean confirm=<org>:<n>` lo borra. Borrar datos lo acuerdan los dos.
6. **Pruebas del día** (cubre BR-210 y el criterio de cobertura): `scripts/org-check.sh tests`. Anotar `Tests Ran`, `Pass Rate` y la cobertura por clase. Fijarse en `UmbralValidadorTest.doscientasFilasContradictoriasSeMarcanTodasSinExcederLimites`, que falló por CPU el 2026-10-05.

## Dónde se guarda

El repo es público. **No se commitean capturas, Ids de registros, nombres de usuario del org ni datos del org.** Las capturas y los resultados de consultas van como comentario en la tarjeta de MDSS de la historia. Al repo solo suben resúmenes sin Ids (conteos, "pasó o falló", fecha) y solo en la tabla "Evidencia por historia". Antes de pegar cualquier `Motivo__c` en una tarjeta, hacer la revisión de secretos del paso 1 de US-209.

## Tres bloques de corridas

Cada corrida: `scripts/org-check.sh run <ESCENARIO> 5 42 200` (escenario, páginas, semilla, lote). Imprime el `<since>` y los dos comandos siguientes: `wait <since>` (espera a que todo esté procesado) y `evidence <ESCENARIO> <since>` (la tabla en markdown). Una corrida de varias páginas puede tardar varios minutos (D023, D025); anotar cuánto tardó.

| Bloque | Escenario | Historias que cubre |
|---|---|---|
| A | `QA_200` | US-201, US-202, US-203, US-206, US-207, US-208, US-209 |
| B | `DUPLICATES` | US-205, US-209 (reenvío y conflicto) |
| C | `BOUNDARIES`, dos veces | US-204 |

Entre bloques: `clean`. El simulador no promete el mismo volumen por escenario entre corridas (ver "Caveats" en `evidencia-escenarios.md`); anotar lo que salió, no lo esperado.

## Bloque A — `QA_200`

### US-201 · traza de una clave

1. Elegir una fila `Procesada` y copiar su `Identidad__c`:

   ```bash
   sf data query -o nova-cdo -q "SELECT Identidad__c, Occurred_At__c, Publicado_At__c, Procesado_At__c, Resultado__c, Caso__c FROM Log_Senial__c WHERE Resultado__c = 'Procesada' ORDER BY Occurred_At__c DESC LIMIT 5"
   ```

2. **Pasa si** `Publicado_At__c` es anterior a `Procesado_At__c`. Ese es el recorrido que pide el criterio de evidencia (publicar no es procesar). `Occurred_At__c` es la hora de origen del simulador y puede ir adelantada al reloj real (D033, D037); anotarlo si pasa.
3. Guardar: la fila (sin `Caso__c`) y la captura de la list view **Todas las señales**, en la tarjeta de US-201.

### US-202 · lotes y señales inválidas

1. `evidence QA_200 <since>` ya trae los conteos por `Resultado__c`. **Pasa si** hay filas `Rechazada` (en la corrida del 2026-10-05, 4), ninguna señal válida del mismo lote quedó `Rechazada` y ninguna quedó sin resultado (`Publicada` sin procesar). `Atrasada`, `Superada`, `Conflicto` y `Fallida` también son resultados esperados; léanse con `evidence`.
2. Los motivos reales:

   ```bash
   sf data query -o nova-cdo -q "SELECT Motivo__c, COUNT(Id) FROM Log_Senial__c WHERE Resultado__c = 'Rechazada' GROUP BY Motivo__c"
   ```

3. Cada motivo debe nombrar la regla de D032 que lo causó. Guardar los conteos y la captura de la list view **Rechazadas**.

### US-203 · última lectura y señal atrasada

1. Tomar una fila `Atrasada` (list view **Atrasadas**) y anotar su `Asset__c`, su `Measurement_Type__c` y su `Occurred_At__c`; su `Motivo__c` dice si es más vieja que la lectura vigente o que la ganadora del lote (D011 h). Luego la lectura vigente de ese activo:

   ```bash
   sf data query -o nova-cdo -q "SELECT Clave__c, Occurred_At__c FROM Lectura_Vigente__c ORDER BY Clave__c"
   ```

   **Pasa si** la `Occurred_At__c` de la vigente de esa clave es igual o posterior a la de la fila `Atrasada`: la atrasada no la pisó.
2. Ninguna fila `Atrasada` abrió una intervención:

   ```bash
   sf data query -o nova-cdo -q "SELECT COUNT(Id) FROM Log_Senial__c WHERE Resultado__c = 'Atrasada' AND Caso__c != null"
   ```

   **Pasa si** da 0.
3. Que temperatura no pisa presión (varios tipos de medición en un mismo activo) lo fija una prueba (`tiposDeMedicionDistintosDelMismoActivoNoSeSobrescriben`) y, con `QA_200`, no se ve en el org (una lectura por activo). Citar la prueba; no inventar la captura.
4. Registrar el conteo de `Atrasada` de la corrida (en `QA_200` del 2026-10-05, 175 de 189) como observado y consistente con D011 (h), que sigue en Propuesta. La pregunta abierta al facilitador está en [preguntas-facilitador.md](preguntas-facilitador.md).

### US-206 · normal, advertencia y crítica

1. ```bash
   sf data query -o nova-cdo -q "SELECT External_Id__c, Severidad_Actual__c FROM Asset ORDER BY External_Id__c"
   ```

2. Entrar como la persona operadora a la pantalla "Activos del operador" y capturar un activo en Advertencia, uno en Crítica y uno Estable. **Pasa si** se distinguen sin depender del color (glifo y texto) y solo el crítico tiene intervención abierta.
3. Si ningún activo sale en Advertencia en esa corrida, no inventar: anotarlo y usar el que tenga esa severidad en otro bloque.

### US-207 · pantalla del operador

Como la persona operadora, con fecha y resultado (pasa / falla) por cada punto. Lista manual de D012:

1. Filtrar por edificio: los chips y el titular cuentan solo las filas visibles.
2. Un activo con `severityLevel` nulo muestra "Sin dato", nunca "Estable".
3. Un activo crítico sin caso muestra "Ninguna abierta" sin prometer un caso.
4. "Caso N" abre el registro del `Case`.
5. Aplicar filtros, abrir un detalle y volver con la miga: los filtros siguen aplicados.
6. Con `truncated` verdadero, el banner se califica ("Al menos N" o "Ningún crítico verificado").
7. Tab hasta "Ver activo" y Enter abre el detalle una sola vez.

Y las comprobaciones manuales de las decisiones posteriores (sus criterios están en `decisiones.md`):

| Decisión | Qué mirar | Como |
|---|---|---|
| D033 | El historial con conflictos muestra el resumen por resultado y el filtro; la tarjeta del activo muestra la antigüedad y el enlace a los casos | operador |
| D034 | El historial muestra las columnas Medición y Valor (con unidad); una fila anterior a D034 muestra "—" | operador |
| D035 | Cerrar en bloque las intervenciones abiertas de un activo: pide confirmar el número, cierra solo las de ese activo | coordinador |
| D036 | El desplegable "Estado" ofrece los mismos valores que la página del `Case` | coordinador |
| D037 | "Lectura vigente por tipo" muestra "Antigüedad"; una hora futura sale como "hora del simulador" | operador |
| D038 | Un activo con casos cerrados y ninguno abierto muestra "Última intervención: Caso N" y el botón "Abrir nueva intervención" | operador |
| D041 | Tarjetas en cuadrícula, dona "Salud de la flota", tabla por edificio con "Filtrar" y "Ver edificio", panel "Traer señales" con tiles | operador y admin |
| D042 | Banda de color por estado (rojo, amarillo, verde, gris), pulso de 3 veces en los críticos, "Subió a crítico" al cambiar de nivel, refresco cada 60 s | operador |

Guardar: capturas de la lista, el detalle y los estados de carga, vacío y error, con varias severidades.

### US-208 · autorización (login as)

"Log in as" ya está activo (T8.7). Probar con cada persona de [acceso.md](acceso.md) ("Personas"):

| Persona | Qué debe ver en "Activos del operador" |
|---|---|
| Operador 1 | Solo BLD-BOG-001; ni rastro de BLD-BAQ-001 |
| Operador 2 | Solo BLD-BAQ-001 |
| Coordinador | Los dos edificios; puede cambiar estados |
| Gerente | Los dos edificios, solo lectura (sin botones de acción) |

Ocultar un botón en la pantalla no prueba que el servidor niegue. El brief pide «solicitándolos directamente a Apex» y una autorización de ingesta «explícita y separada del contexto del operador»; en el org eso lo prueban las clases de prueba, no el login as. Correr `scripts/org-check.sh tests` y citar, con su resultado: `ActivosOperadorControllerTest.operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth`, `IntervencionOperadorControllerTest` (gerente y operador rechazados por permiso), `SeguridadTest` (T8.5), y para la ingesta `PermisosProcesamientoTest`, `SenialSensorHandlerTest.laIngestaPersisteConUnUsuarioSinPermisosDeOperador` y D017.

Además, con los Ids del paso 2 de "Cómo verificar (T8.6)" en `acceso.md`, la consulta de `UserRecordAccess` por persona sobre BLD-BOG-001, BLD-BAQ-001 y BLD-TEST-NOAUT. **Pasa si** coincide con la columna "Gerente esperado" de "Jerarquía en vez de View All (D022)": el gerente ve None en BLD-TEST-NOAUT y en `salesforce.com`, y `HasEditAccess` y `HasDeleteAccess` son false para él. Esa es la medición que D022 dejó pendiente. Guardar la tabla resultante en la tarjeta de US-208 (sin los Ids).

### US-209 · inspección como admin

Como la persona administradora (o con un usuario con `Nova_Casa_Admin`), en la pestaña **Registros de Señal**:

1. **Sin secretos, antes de capturar nada:** revisar a ojo todos los motivos distintos y confirmar que ninguno trae un token, un cursor ni un dato de personas. Si alguno lo trae, no se pega en ninguna tarjeta y se avisa:

   ```bash
   sf data query -o nova-cdo -q "SELECT Motivo__c, COUNT(Id) FROM Log_Senial__c WHERE Motivo__c != null GROUP BY Motivo__c"
   ```

2. Encontrar y capturar, con identidad, resultado, motivo y acción de reintento: una señal **normal** (`Procesada`), una **inválida** (`Rechazada`), una **atrasada** (`Atrasada`). La duplicada y la conflictiva salen del bloque B.

3. **Solo admin:** entrar como operador, coordinador y gerente y comprobar que la pestaña **Registros de Señal** no aparece y que `/lightning/o/Log_Senial__c/list` no los deja ver filas. La pantalla del operador sí les muestra el historial por activo (D024); no es la misma cosa.
4. Si la pestaña no aparece ni para el admin, avisar antes de desplegar nada: según [evidencia-escenarios.md](evidencia-escenarios.md) (US-209) está en `main` desde el PR #62 y el retrieve de `Nova_Casa_Admin` del 2026-10-09 coincidió con `main`.

## Bloque B — `DUPLICATES`

### US-205 · una intervención abierta por activo (D039)

Desde D039, un activo tiene un solo caso de telemetría abierto: las críticas siguientes se enlazan a él (`Caso__c`) y actualizan sus campos `Ultima_Critica_*`. El org todavía tiene casos abiertos acumulados de antes de D039; anotar la hora de inicio de la corrida (UTC) y usarla en las consultas, o cerrarlos antes con «Cerrar las N abiertas» (D035).

1. Ningún activo con más de un caso de telemetría abierto creado en la corrida, y ninguna identidad con más de un caso. **Pasa si** las dos devuelven 0 filas (cambiar `<inicio>` por la hora anotada, p. ej. `2026-10-18T22:00:00Z`):

   ```bash
   sf data query -o nova-cdo -q "SELECT AssetId, COUNT(Id) FROM Case WHERE Origin = 'Telemetria' AND IsClosed = false AND CreatedDate >= <inicio> GROUP BY AssetId HAVING COUNT(Id) > 1"
   sf data query -o nova-cdo -q "SELECT Identidad_Senal__c, COUNT(Id) FROM Case WHERE Origin = 'Telemetria' GROUP BY Identidad_Senal__c HAVING COUNT(Id) > 1"
   ```

2. Reenvíos: filas con `Reenvios__c > 0` (list view **Duplicadas (reenvíos)**). **Pasa si** su `Resultado__c` no cambió por el reenvío y sigue con un solo `Caso__c` (si lo tenía).
3. Conflictos: list view **Conflictos**. Una fila `Conflicto` conserva el `Caso__c` original, así que la columna no prueba nada. **Pasa si** el total de `Case` con `Origin = 'Telemetria'` es igual antes y después de que lleguen los conflictos: anotar el conteo de `Case` justo después de `wait` y compararlo con el del paso 1.
4. Guardar: el conteo de casos creados en la corrida frente al de activos con alguna fila `Procesada` crítica (deben coincidir si esos activos no tenían caso abierto antes), la captura de un caso con su sección **Última señal crítica** igual a la crítica más reciente de su activo en `evidence`, la captura de la list view **Intervenciones abiertas** y las cifras de las consultas del paso 1.

### US-209 · duplicada y conflicto

Capturar una fila con `Reenvios__c > 0` y una `Conflicto`, con su acción de reintento (D014: `Conflicto` no es seguro reintentar). Añadir las dos al registro del bloque A.

## Bloque C — `BOUNDARIES` dos veces

### US-204 · cambiar un límite sin desplegar

1. `run BOUNDARIES 5 42 200` y, con `wait`/`evidence`, anotar la severidad de una medición cuyo valor esté entre el límite de Advertencia y el de Crítica (`Lectura_Vigente__c` o el historial del activo).
2. Como la persona coordinadora, en la pestaña **Umbrales**, bajar el límite de Crítica de esa medición por debajo de ese valor. No se despliega nada.
3. `clean`, y otra vez `run BOUNDARIES 5 42 200` con la misma semilla.
4. **Pasa si** la misma medición (mismo `Identidad__c`) sale ahora `Crítica` y abre su intervención. Compararla con lo anotado en el paso 1: las filas de la primera corrida ya no existen después de `clean`. Si el simulador no repite el flujo con la misma semilla (caveat de reproducibilidad), anotarlo y comparar solo la clasificación de otro valor de la misma medición.
5. **Restaurar el límite** al valor original y confirmarlo. Los umbrales son de todos.
6. Guardar: valor, límite viejo y nuevo, y la severidad antes y después, sin Ids.

Los valores en el límite exacto ya los fijan las pruebas (D019); esta corrida demuestra que cambiar el dato cambia la clasificación sin desplegar.

## Opcional

- **HP-05**: las corridas de 5 páginas sirven para anotar cuánto tardaron (D023) y si hubo reintentos o sesiones reabiertas (contadores `reintentos` y `sesionesReabiertas` del debug log). La profundidad de más de 27 páginas (D013) sigue sin validarse y exigiría una corrida mucho más larga; no es parte de este checklist.
- **US-210**: sigue bloqueada en MDSS; no hay nada que capturar.

## Al terminar

1. `clean confirm=...` para dejar el org como estaba, y avisar en Slack.
2. Pegar la evidencia en la tarjeta de cada historia y moverla (`CONTRIBUTING.md`, "Board and backlog": QA → Ready cuando la evidencia esté guardada). Las historias con pregunta abierta quedan en QA hasta que el facilitador conteste.
3. Si alguna comprobación falla, no se arregla aquí: se anota, se abre rama por historia y, si cambia el comportamiento acordado, se registra primero en `decisiones.md`.
