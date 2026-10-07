# Guion de la demo (T9.2)

Recorrido de punta a punta de la historia de referencia de `Sprint 2 - Nova Casa.md`: Sara, operadora de edificios (usuario Operador Nova Casa), empieza su turno, ve qué equipo necesita atención, la señal crítica abre una sola intervención, el reenvío no abre otra y la lectura atrasada no reemplaza la actual. Después, cada rol ve lo suyo.

Duración: unos 14 minutos, más la preparación. La evidencia por historia está en [evidencia-escenarios.md](evidencia-escenarios.md#evidencia-por-historia-t93).

## Antes de la demo (no cuenta en el tiempo)

1. **Avisar en Slack** quién corre la ingesta y a qué hora. La corre Juan Diego (o John) con su propio usuario: los dos tienen `Nova_Casa_Admin` y `Nova_Casa_Simulator_Integration`. `novacasa.admin@` no tiene `Nova_Casa_Simulator_Integration`, así que "Traer señales" con ese usuario falla. Una corrida a la vez.
2. **Org limpio.** El simulador reutiliza `messageId` entre sesiones: si quedan filas de corridas anteriores, todo sale como `Conflicto` o reenvío. El 2026-10-06 el org tenía 400 filas de `Log_Senial__c`, todas `Conflicto`. Antes de la demo se borran los `Log_Senial__c`, las `Lectura_Vigente__c` y los `Case` con `Origin = 'Telemetria'`, como en `evidencia-escenarios.md`. Borrar datos lo acuerdan John y Juan Diego (`CONTRIBUTING.md`).
3. **Catálogo cargado** (README, "Loading the building/asset catalog"): `CatalogoService.loadCatalog();` desde Execute Anonymous. Después, la consulta de "Dueño de los edificios" en `docs/acceso.md` debe volver vacía: BLD-BOG-001 (Edificio Nova Alameda) es de `novacasa.operador@` y BLD-BAQ-001 (Edificio Nova Caribe) de `novacasa.operador2@`. BLD-TEST-NOAUT (Edificio de prueba, fuera de jerarquía) sigue a nombre de Juan Diego, sin activos.
4. **Usuarios persona** (`docs/acceso.md`, "Personas"), todos `@novacasa-telemetria.demo` y activos: `novacasa.operador`, `novacasa.operador2`, `novacasa.coordinador`, `novacasa.gerente`, `novacasa.admin`. "Log in as" ya está activo en el org (T8.7). Probarlo una vez con cada uno.
5. **Pruebas corridas el mismo día** y el resultado a mano (paso 9):

   ```bash
   sf apex run test --class-names SenialSensorHandlerTest --class-names IntervencionServiceTest --class-names TelemetriaIngestaTest --class-names ActivosOperadorControllerTest --class-names IntervencionOperadorControllerTest --class-names PermisosProcesamientoTest --class-names UmbralValidadorTest --code-coverage --result-format human --wait 15
   ```

6. **Pestañas abiertas** en el navegador del presentador: Setup > Users, Setup > Apex Jobs, Developer Console (Execute Anonymous) y la app **Nova Casa Telemetry**.

## Guion

| # | Min | Quién | Qué se demuestra | BR / US |
|---|---|---|---|---|
| 1 | 1 | Presentador | El problema y la historia de referencia | — |
| 2 | 2 | Juan Diego (admin) | Recepción real y procesamiento | BR-201, BR-202 · US-201, US-202 |
| 3 | 3 | Sara (Operador Nova Casa) | Pantalla del operador, severidad, filtros, estados | BR-206, BR-207, BR-208 · US-206, US-207, US-208 |
| 4 | 1,5 | Juan Diego + Sara | Una sola intervención; el reenvío no abre otra | BR-205 · US-205 |
| 5 | 1 | Juan Diego (admin) | La señal atrasada no reemplaza la actual | BR-203 · US-203 |
| 6 | 1,5 | Coordinador | Intervenciones abiertas, seguimiento y límites | BR-204, BR-205 · US-204, US-205 |
| 7 | 1,5 | Gerente y Operador 2 | Cada quien ve solo lo autorizado | BR-208 · US-208 |
| 8 | 1,5 | Juan Diego (admin) | Por qué se rechazó una señal y si es seguro reintentar | BR-209 · US-209 |
| 9 | 1 | Presentador | Pruebas automatizadas | BR-210 |

### 1. Contexto (1 min)

- Hoy cada proveedor tiene su portal y el operador se entera tarde. Leer en voz alta la historia de referencia (`Sprint 2 - Nova Casa.md`, "Historia de referencia"): Sara, una operadora con dos edificios, una bomba con presión baja, un reenvío y una lectura antigua.
- Mostrar en una frase el flujo: simulador → `Senial_Sensor__e` (Platform Event) → `SenialSensorTrigger` como usuario de integración → `Lectura_Vigente__c`, `Log_Senial__c` y `Case` → pantalla "Activos del operador".

### 2. Llegan las señales (2 min) · BR-201, BR-202

1. Developer Console > Debug > Open Execute Anonymous Window, con el usuario de Juan Diego:

   ```apex
   TelemetriaIngesta.iniciar('QA_200', 42, 200, 5); // escenario, semilla, tamaño de lote, páginas
   ```

2. Setup > Apex Jobs: aparecen los trabajos de `TelemetriaIngesta`, uno por página, en `Completed`.
3. App Nova Casa Telemetry > pestaña **Registros de Señal** (solo la ve el admin) y elegir la vista **Todas las señales** (la pestaña puede abrir en otra vista; confirmarlo en la verificación en el navegador). También se llega por URL: `/lightning/o/Log_Senial__c/list?filterName=Todas_las_senales`.

**Qué debe ver el público**

- Cada mensaje tiene una fila con su identidad (`source|messageId`), `Occurred_At__c` (origen), `Publicado_At__c` y `Procesado_At__c`: publicar no es procesar.
- Las filas pasan de `Publicada` a `Procesada` sin que nadie cree nada a mano.
- Unas pocas filas quedan `Rechazada` con `Motivo__c` y las demás siguen: una señal mala no tumba el lote. En la corrida de `QA_200` del 2026-10-05 fueron 4 de 189.

### 3. Sara empieza su turno (3 min) · BR-206, BR-207, BR-208

1. Setup > Users > `novacasa.operador@…` > **Login**.
2. App **Nova Casa Telemetry** > pestaña **Activos del operador**.

**Qué debe ver el público**

- Solo aparece **BLD-BOG-001, Edificio Nova Alameda**. Nada de BLD-BAQ-001 ni de BLD-TEST-NOAUT.
- El banner y el resumen por edificio dicen cuántos activos están en Crítica, Precaución o Sin dato. La severidad del activo es la mayor de sus últimas lecturas.
- Mientras carga, el esqueleto "Cargando activos" (botón **Actualizar**).
- Filtrar por **Severidad** = Crítica, después por **Edificio**. Elegir una combinación sin resultados: "Ningún activo coincide con esos filtros" y **Limpiar filtros**. Es distinto de "Sin lecturas todavía", que es un activo sin datos.
- Cada tarjeta muestra la fecha de origen de la lectura y la marca "(desactualizada)" si pasó el corte de 15 minutos (D007).
- **Ver activo**: el detalle muestra la lectura vigente por tipo de medición (la temperatura no pisa la presión) y, si es crítico, la intervención como "Caso N", que abre el `Case`.
- Sara no tiene "Actualizar seguimiento" ni "Ver límites"; sí tiene "Crear intervención" para un activo sin intervención abierta (D020).

Si en la corrida la bomba no salió crítica, se sigue con el activo crítico que haya: el recorrido es el mismo.

### 4. Una sola intervención, aunque llegue repetida (1,5 min) · BR-205

1. Antes, como Juan Diego: Cases > list view **Intervenciones abiertas**. Anotar el número de casos.
2. Repetir la misma corrida, con la misma semilla:

   ```apex
   TelemetriaIngesta.iniciar('QA_200', 42, 200, 5);
   ```

3. Cuando los trabajos terminen, volver a **Intervenciones abiertas** y abrir `/lightning/o/Log_Senial__c/list?filterName=Duplicadas`.

**Qué debe ver el público**

- El número de casos de **Intervenciones abiertas** no cambia.
- En **Duplicadas (reenvíos)** las filas tienen `Reenvios__c` > 0 y `Ultimo_Reenvio__c`. El resultado (`Procesada`) y el caso (`Caso__c`) siguen siendo los mismos.
- Si el simulador no repite el mismo contenido con esa semilla, la misma clave llega con otro contenido y la fila queda `Conflicto` (list view **Conflictos**), también sin caso nuevo. Las dos cosas son lo que pide el acuerdo "Mensaje repetido".
- De vuelta como Sara, **Actualizar**: la tarjeta sigue mostrando un solo "Caso N".

### 5. Una lectura vieja no es la condición actual (1 min) · BR-203

1. `/lightning/o/Log_Senial__c/list?filterName=Atrasadas`. Abrir una fila y su activo.

**Qué debe ver el público**

- La fila `Atrasada` tiene un `Occurred_At__c` más viejo que la lectura vigente del mismo activo y tipo de medición, y su motivo lo dice.
- La lectura vigente no cambió y la fila no tiene caso, aunque su valor sea crítico.
- En una corrida completa casi todas las filas quedan `Atrasada`: es lo esperado de D011 (h), porque solo gana la más reciente de cada activo y medición del lote.

`LATE_MESSAGES` muestra esto mismo con más casos, pero necesita el org limpio otra vez (los `messageId` se repiten entre escenarios). Su corrida está en `evidencia-escenarios.md`.

### 6. El coordinador organiza el trabajo (1,5 min) · BR-204, BR-205

1. Setup > Users > `novacasa.coordinador@…` > **Login**.
2. Pestaña Cases > list view **Intervenciones abiertas**.
3. Pestaña **Activos del operador** > un activo crítico > **Actualizar seguimiento** (estado En espera, con comentario) > **Guardar**.
4. **Ver límites** (o pestaña Umbrales > **Nova Casa - Umbrales**).

**Qué debe ver el público**

- Todas las intervenciones abiertas de los dos edificios en un solo lugar, una por mensaje crítico.
- El coordinador sí puede cambiar el estado de la intervención; Sara no podía.
- Los límites por tipo de activo y medición son registros de `Umbral__c` que el coordinador edita sin desplegar código. Un rango contradictorio (Advertencia GT 40 con Crítica GT 35) se rechaza al guardar (D018). No cambiar un límite en la demo sin dejarlo como estaba; la prueba de que un cambio cambia la clasificación siguiente es `SenialSensorHandlerTest` (paso 9).

### 7. Cada quien ve lo suyo (1,5 min) · BR-208

1. Setup > Users > `novacasa.gerente@…` > **Login** > **Activos del operador**, y pestaña Accounts > **Nova Casa - Edificios**.
2. Setup > Users > `novacasa.operador2@…` > **Login** > **Activos del operador**.

**Qué debe ver el público**

- El gerente ve **BLD-BOG-001 y BLD-BAQ-001** y el resumen por edificio para comparar, sin "Crear intervención", "Actualizar seguimiento" ni "Ver límites": solo lectura.
- En **Nova Casa - Edificios** no aparece **BLD-TEST-NOAUT**: nadie de la jerarquía lo ve (D022).
- Operador 2 ve solo **BLD-BAQ-001, Edificio Nova Caribe**, al revés que Sara.
- La restricción también está en el servidor: el controlador es `with sharing` y consulta en `USER_MODE`. Lo prueban `ActivosOperadorControllerTest.operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth` y las consultas de `UserRecordAccess` de `docs/acceso.md`.

### 8. El administrador investiga (1,5 min) · BR-209

Con el usuario de Juan Diego (o `novacasa.admin@…` por Login).

1. `/lightning/o/Log_Senial__c/list?filterName=Rechazadas`, después `Conflictos` y `Fallidas`.
2. Buscar una señal por su identidad en la búsqueda global.

**Qué debe ver el público**

- Cada fila dice su resultado, el **Motivo** y la **Acción de reintento** (`Accion_Reintento__c`, D014): una `Rechazada` dice "No: corregir el dato en origen…", una `Fallida` dice "Sí: reintentar…", una procesada dice "No hace falta".
- Reintentar es volver a correr la ingesta: la identidad evita duplicar el caso (paso 4).
- No hay token, cursor ni secreto en ninguna fila. La bitácora es solo del admin: el operador, el coordinador y el gerente no tienen acceso a `Log_Senial__c`.

### 9. Calidad (1 min) · BR-210

Mostrar el resultado del `sf apex run test` de la preparación (`Tests Ran`, `Pass Rate`, cobertura por clase). Nombrar las pruebas que fallan si se rompe lo que acaban de ver:

- Clasificación y frontera: `tresValoresRepresentativosDeTemperaturaSonNormalAdvertenciaYCritica`, `operadorGTUnValorIgualAlLimiteNoLoCumpleYElSiguienteSi`, `editarElLimiteDeUnUmbralCambiaLaClasificacionSinTocarElHistorico`.
- Duplicados y conflicto: `unReenvioIgualSoloSumaReenviosSinTocarLecturaNiCase`, `mismaIdentidadConOtroContenidoEsConflictoSinCambiarEstado`, `IntervencionServiceTest`.
- Volumen: `doscientosEventosEnUnLoteUsanUnNumeroFijoDeConsultasYDml`.
- Orden temporal: `unaSenialMasAntiguaQueLaVigenteQuedaAtrasadaAunqueSeaCritica`, `elDesempateD003NoDependeDelOrdenDeLlegada`.
- Seguridad: `ActivosOperadorControllerTest`, `PermisosProcesamientoTest`.

Cierre: lo que falta está en la tabla de evidencia, columna Estado.

## Si algo falla

| Qué pasa | Qué hacer |
|---|---|
| El simulador no responde o un trabajo queda `Failed` en Apex Jobs | Leer el error en Apex Jobs. Volver a correr el mismo `iniciar`: la identidad evita duplicados (D013, punto 8). Si sigue, mostrar la corrida guardada en `evidencia-escenarios.md` y los datos que ya están en el org. |
| Todo sale `Conflicto` o reenvío | El org no estaba limpio. Mostrar **Conflictos** y **Duplicadas (reenvíos)** como prueba de BR-205 y seguir con los datos que haya. |
| No salió ninguna señal crítica, o ningún caso nuevo | El resultado depende de cómo se parten los lotes (D011 h). Mostrar `CRITICAL_BURST` en `evidencia-escenarios.md` (30 casos, cada uno con su fila `Procesada`). |
| "Traer señales" da error | Con `novacasa.admin@` falta `Nova_Casa_Simulator_Integration`. Usar Execute Anonymous con el usuario de Juan Diego. |
| "Login" no aparece en Setup > Users | Revisar "Administrators Can Log in as Any User". Si no se puede, mostrar las tablas de `UserRecordAccess` de `docs/acceso.md`. |
| La pantalla dice "No pudimos cargar tus activos" | **Reintentar**. Si sigue, es falta de permisos del usuario (FLS): se muestra como el estado de error que pide BR-207 y se sigue con otro rol. |
| La corrida tarda | Con más de una página, cada página espera `pollAfterMs` redondeado a minutos (D023). Usar `QA_200` con pocas páginas. |

Las corridas crean registros reales. No borrar lo que creó otra persona; la limpieza se acuerda en Slack.
