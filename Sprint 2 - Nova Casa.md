# Sprint 2
# Nova Casa

De la señal del sensor a la intervención oportuna

Sept 15 - Sept 26

Nova Casa quiere centralizar las señales de sus sensores en Salesforce para reconocer anomalías, consultar el estado más reciente de los equipos y coordinar una intervención antes de que un problema se vuelva crítico.

## Objetivo

Comprender la operación de Nova Casa y explorar una solución suficientemente clara para comenzar a construir. Se entregan prototipos de baja fidelidad, no una aplicación terminada ni una arquitectura productiva exhaustiva.

El facilitador entrega en esta fase el brief y los BR. Las historias de usuario de la fase siguiente son el backlog inicial para preparar el Sprint Planning, no una receta que deba copiarse sin discusión.

Discovery & Design

Development

QA & Delivery

## Brief del cliente

Conoce la operación de Nova Casa y qué necesita centralizar

Nova Casa es una inmobiliaria colombiana con operación en varias ciudades. Además de comercializar vivienda, administra conjuntos residenciales y edificios y coordina servicios para propietarios y residentes.

En algunos edificios utiliza sensores para vigilar equipos importantes. Estos dispositivos pueden reportar:

- Temperatura elevada en un cuarto técnico.
- Consumo inusual de agua o energía.
- Falta de presión en una bomba de agua.
- Pérdida de comunicación con un dispositivo.

Hoy cada proveedor muestra la información en su propio portal o envía alertas por correo. El operador revisa varias fuentes para entender qué ocurre. A veces descubre una falla después de que los residentes ya se quedaron sin agua o reportaron una interrupción del servicio.

Nova Casa quiere centralizar estas señales en Salesforce para reconocer anomalías, consultar el estado más reciente de los equipos y coordinar una intervención antes de que el problema se vuelva crítico.

Los dispositivos pueden enviar datos repetidos, incompletos o atrasados. Una señal equivocada no debe generar trabajo duplicado ni reemplazar información más reciente. Tampoco basta con almacenar información técnica: el operador debe reconocer qué edificio necesita atención, qué tan grave es la situación y qué puede hacer después.

## Problema y personas

Quiénes usan la solución y qué riesgo enfrentan hoy

Cada persona necesita reconocer, desde su rol, qué equipo necesita atención y qué hacer después. Estas son las personas del sprint y el riesgo que enfrentan con la operación actual.

### Operador de edificios

Necesidad

Consultar los equipos bajo su responsabilidad e identificar cuáles necesitan atención

Riesgo actual

Debe revisar varios portales y puede pasar por alto una señal crítica

### Coordinador de mantenimiento

Necesidad

Revisar intervenciones y organizar su seguimiento

Riesgo actual

Recibe avisos repetidos y puede generar trabajo duplicado

### Gerente regional de operaciones

Necesidad

Entender qué edificios concentran situaciones graves

Riesgo actual

Recibe información tardía y le cuesta comparar prioridades

### Administrador de Salesforce

Necesidad

Investigar señales rechazadas y verificar el procesamiento

Riesgo actual

No dispone de una explicación clara de qué falló

## Historia de referencia

El recorrido de Laura orienta la demo

Laura es operadora de dos edificios. Antes de comenzar su turno necesita saber si los equipos están funcionando normalmente. Una bomba reporta presión baja: Laura debe identificar el edificio, entender la severidad y abrir la intervención correspondiente. Si el proveedor envía nuevamente el mismo aviso, no debería existir una segunda intervención. Si después llega una lectura antigua, la pantalla no debería mostrarla como si fuera la condición actual.

Esta historia orienta la demo, pero no impone el modelo de datos ni la distribución de componentes.

## Frontera formativa y alcance

Qué tecnologías son la frontera de aprendizaje

El recorrido central debe incluir:

- Platform Events para recibir señales publicadas realmente desde el simulador.
- Apex, incluido un suscriptor programático y lógica preparada para colecciones, para validar y procesar las señales.
- Lightning Web Components para la experiencia del operador.
- Seguridad de registros, objetos y campos en la interfaz y en las solicitudes al servidor.
- Pruebas automatizadas con resultados verificables, no solamente cobertura.

Estas tecnologías son la frontera de aprendizaje. Fuera de ella, las parejas deben elegir y justificar qué capacidades estándar reutilizan, qué metadata necesitan y qué decisiones requieren código. No se exige utilizar todos los patrones de diseño ni crear objetos personalizados para conceptos que ya tengan una representación adecuada.

## Requirements

### Requerimiento de negocio

BR-201: Recibir señales

Nova Casa debe recibir mensajes del simulador e identificar edificio, activo, tipo de medición, valor, unidad, momento de origen y clave del mensaje. La recepción debe ser real, no una captura manual durante la demo.

### Requerimiento de negocio

BR-202: Procesar colecciones y aislar datos inválidos

La solución debe manejar hasta 200 señales. Una señal con datos inválidos no debe impedir que las demás señales válidas continúen. Debe existir evidencia de cuál falló y por qué.

### Requerimiento de negocio

BR-203: Conservar información reciente

Una lectura de las 10:02 que llega después de otra de las 10:05 no debe reemplazar el estado actual. El equipo debe definir qué significa «última señal» cuando un activo tiene más de una medición.

### Requerimiento de negocio

BR-204: Administrar límites

Los límites de normalidad, advertencia y criticidad varían por tipo de activo y medición. Una persona autorizada debe cambiarlos sin modificar ni volver a desplegar código.

### Requerimiento de negocio

BR-205: Evitar intervenciones duplicadas

Una señal crítica nueva genera una intervención. Reenviar el mismo mensaje no crea otra y debe permitir reconocer el resultado ya existente.

### Requerimiento de negocio

BR-206: Diferenciar la respuesta

Una señal normal actualiza la condición conocida. Una advertencia se muestra para monitoreo. Una señal crítica produce una intervención operativa.

### Requerimiento de negocio

BR-207: Facilitar el trabajo del operador

El operador consulta los activos a su cargo, distingue severidades, reconoce la antigüedad de la información, filtra por edificio o severidad y abre el activo o la intervención. La experiencia explica los estados de carga, ausencia de datos y error.

### Requerimiento de negocio

BR-208: Proteger datos y acciones

Cada usuario accede únicamente a los datos y acciones autorizados. La restricción también debe funcionar cuando se solicita información directamente al servidor.

### Requerimiento de negocio

BR-209: Explicar el procesamiento

El administrador identifica qué señal se recibió, su resultado, el motivo de rechazo y si es seguro intentar procesarla nuevamente, sin exponer secretos.

### Requerimiento de negocio

BR-210: Demostrar calidad

Las pruebas automatizadas verifican clasificación, intervención, volumen, mensajes inválidos, duplicados, orden temporal y seguridad. Deben fallar si se rompe el comportamiento que afirman comprobar.

## Acuerdos

Decisiones antes de Development

| Tema | Acuerdo mínimo para el prototipo |
|------|----------------------------------|
| Última lectura | Se conserva por combinación de activo y tipo de medición. Una temperatura reciente no sustituye la última lectura de presión. |
| Severidad del activo | Si hay varias mediciones, el resumen utiliza la mayor severidad de sus últimas lecturas válidas. Otra política es válida si se justifica, se documenta y se prueba. |
| Identidad del mensaje | La clave es única dentro del proveedor; si se incluyen varios orígenes, se combina origen y clave. El reenvío conserva la identidad. |
| Mensaje repetido | No vuelve a actualizar el estado ni a generar una intervención. Una misma clave con contenido distinto se identifica como conflicto, no como un nuevo aviso. |
| Incidente | En el alcance base se garantiza una intervención como máximo por mensaje crítico único. Consolidar varias lecturas con claves distintas en un solo incidente abierto es un extra; debe explicarse la limitación del diseño base. |
| Señal atrasada | Se conserva su evidencia sin reemplazar el estado actual. La política inicial es no crear una intervención nueva por una crítica atrasada; una alternativa es admisible si distingue revisión histórica de estado actual y cuenta con criterios y pruebas explícitos. |
| Igual momento de origen | Se define una regla determinista para señales con la misma fecha y hora; no se deja al orden accidental de llegada. |
| Límites | Se acuerdan operadores de comparación y valores exactos que separan normal, advertencia y crítico. Para el base se usa una unidad compatible por tipo de medición. |
| Recepción y procesamiento | Publicar correctamente un evento no prueba que se haya procesado. La evidencia distingue ambos momentos. |
| Seguridad | Se distingue la autorización del proceso de ingesta del acceso de operadores al LWC y Apex. La automatización no depende de que un operador tenga permisos de administrador. |

Estos acuerdos acotan ambigüedades. La pareja puede proponer cambios durante Discovery, pero debe obtener validación y mantener criterios comprobables.

## Entregables

Prototipos y entregables

1. Entendimiento del problema: una página con personas, problema prioritario, dos o tres indicadores de éxito, preguntas y supuestos. Los indicadores se proponen como objetivos del prototipo; no se inventan resultados de producción.
2. Prototipo de baja fidelidad: dos pantallas principales vista de activos y detalle o navegación al incidente, y variantes simples de carga, vacío y error. Puede elaborarse con diapositivas, dibujos, Figma o HTML sencillo. No se evalúa el acabado gráfico.
3. Arquitectura de una página: simulador, recepción, procesamiento, almacenamiento, intervención y consulta del operador. Marcar qué es síncrono o asíncrono y dónde se aplica seguridad.
4. Modelo de datos inicial: conceptos, relaciones, campos esenciales y justificación de estándar frente a personalizado. No es necesario documentar cada campo auxiliar.
5. Contrato del mensaje: campos, identidad, fechas, unidades y ejemplos válido e inválido.
6. Decisiones y riesgos: al menos dos decisiones con alternativa descartada y trade-off; riesgos principales, dependencia y siguiente acción.

## Contrato

Ejemplo de petición

HTTP

```
GET /api/v1/telemetry?limit=200 HTTP/1.1
Host: <tu-app>.herokuapp.com
Authorization: Bearer <token_asignado>
Accept: application/json
```

Ejemplo de respuesta

JSON

```
{
  "schemaVersion": "1.0",
  "generatedAt": "2026-09-15T15:06:00Z",
  "data": [
    {
      "messageId": "MSG-000101",
      "source": "nova-casa-simulator",
      "building": {
        "externalId": "BLD-BOG-001",
        "name": "Nova Alameda",
        "city": "Bogotá"
      },
      "asset": {
        "externalId": "AST-BOG-001",
        "name": "Ventilación del cuarto técnico",
        "type": "VENTILATION"
      },
      "sensorId": "SNS-TEMP-001",
      "measurement": {
        "type": "TEMPERATURE",
        "value": 22.5,
        "unit": "CELSIUS"
      },
      "occurredAt": "2026-09-15T15:05:00Z"
    },
    {
      "messageId": "MSG-000102",
      "source": "nova-casa-simulator",
      "building": {
        "externalId": "BLD-MDE-001",
        "name": "Nova Mirador",
        "city": "Medellín"
      },
      "asset": {
        "externalId": "AST-MDE-001",
        "name": "Ventilación del cuarto técnico",
        "type": "VENTILATION"
      },
      "sensorId": "SNS-TEMP-002",
      "measurement": {
        "type": "TEMPERATURE",
        "value": 39.0,
        "unit": "CELSIUS"
      },
      "occurredAt": "2026-09-15T15:04:00Z"
    },
    {
      "messageId": "MSG-000103",
      "source": "nova-casa-simulator",
      "building": {
        "externalId": "BLD-BOG-001",
        "name": "Nova Alameda",
        "city": "Bogotá"
      },
      "asset": {
        "externalId": "AST-BOG-002",
        "name": "Bomba principal de agua",
        "type": "WATER_PUMP"
      },
      "sensorId": "SNS-PRESSURE-001",
      "measurement": {
        "type": "PRESSURE",
        "value": 0.7,
        "unit": "BAR"
      },
      "occurredAt": "2026-09-15T15:05:30Z"
    },
    {
      "messageId": "MSG-000104",
      "source": "nova-casa-simulator",
      "building": {
        "externalId": "BLD-BOG-001",
        "name": "Nova Alameda",
        "city": "Bogotá"
      },
      "asset": {
        "externalId": "AST-BOG-001",
        "name": "Ventilación del cuarto técnico",
        "type": "VENTILATION"
      },
      "sensorId": "SNS-TEMP-001",
      "measurement": {
        "type": "TEMPERATURE",
        "value": 20.0,
        "unit": "CELSIUS"
      },
      "occurredAt": "2026-09-15T15:02:00Z"
    }
  ],
  "pagination": {
    "nextCursor": "page-token-002",
    "hasMore": true
  }
}
```

Significado de los campos

| Campo | Propósito |
|-------|-----------|
| schemaVersion | Identificar la versión del contrato de datos. |
| generatedAt | Momento en que Heroku generó esta respuesta; no es la fecha de cada lectura. |
| messageId + source | Identificar un mensaje y reconocer sus reenvíos. |
| building.externalId | Relacionar la señal con un edificio existente en Salesforce. |
| asset.externalId | Relacionarla con un activo existente. |
| Nombres y ciudad | Facilitar la comprensión del ejemplo y el prototipo. Los IDs, no los nombres, identifican los registros. |
| sensorId | Identificar el dispositivo que produjo la lectura. |
| measurement.type | Saber qué condición se midió. |
| measurement.value | Valor numérico de la lectura. |
| measurement.unit | Interpretar correctamente el valor. |
| occurredAt | Momento en que el sensor generó la lectura, expresado en UTC. |
| nextCursor | Continuar la consulta sin depender de fechas o IDs consecutivos. |

## Development

En la fase de Development, el backlog inicial que preparaste en Discovery se convierte en software funcional. Cada historia de usuario describe un resultado observable para un rol de Nova Casa, con criterios de aceptación que definen cuándo está terminada.

Organiza el trabajo en el tablero: arrastra cada historia por las columnas a medida que avanza, asígnala a un miembro del equipo y registra los acuerdos importantes en sus comentarios. Las historias no se eliminan; se mueven hasta quedar listas.

### US-201: Recibir señales de los edificios

BR-201 · Development · 3 pts

Resultado: Recepción real de señales

Como operador de edificios,

quiero que las lecturas de los dispositivos lleguen automáticamente a Salesforce,

para monitorear los equipos sin revisar múltiples portales de proveedores.

Criterios de aceptación

- El simulador publica Platform Events reales hacia la organización y el suscriptor Apex los recibe.
- El contrato permite reconocer edificio, activo, medición, valor, unidad, fecha de origen y clave del mensaje.
- La fecha de origen se conserva separada de la recepción o procesamiento.
- Una publicación aceptada se distingue de una señal efectivamente procesada.
- La pareja puede ejecutar el recorrido con instrucciones reproducibles y sin crear manualmente el resultado.

Evidencia

Ejecución del simulador y trazabilidad de una clave desde publicación hasta resultado.

Esfuerzo relativo

Integración con un kit ya habilitado y contrato conocido.

### US-202: Procesar señales sin perder las válidas

BR-202 · Development · 5 pts

Resultado: Procesamiento de colecciones y aislamiento de inválidos

Como coordinador de mantenimiento,

quiero que las lecturas válidas de un lote se procesen aunque otra lectura sea inválida,

para que un dispositivo defectuoso no oculte los problemas de los demás.

Criterios de aceptación

- El procesador admite colecciones de hasta 200 señales, incluyendo varias para el mismo activo.
- Una señal incompleta, de activo desconocido o con medición incompatible queda rechazada con motivo.
- Las señales válidas de esa colección producen los resultados esperados.
- No se realizan consultas ni operaciones de escritura de Salesforce una vez por cada elemento de la colección.
- La prueba de volumen incluye resultados verificables, no solamente ausencia de excepciones.

Evidencia

Prueba automatizada de una colección mixta y ejecución real de publicación de 200 mensajes. La prueba no presupone que Salesforce entregará exactamente esos 200 eventos en una única invocación del suscriptor. La obligación de aislamiento se refiere a los errores de datos definidos para el caso; no implica garantizar éxito parcial frente a cualquier falla global de la plataforma.

Esfuerzo relativo

Procesamiento bulk, resultados parciales y validaciones.

### US-203: Mantener el estado actual

BR-203 · Development · 5 pts

Resultado: Estado reciente por activo y medición

Como operador de edificios,

quiero ver la lectura válida más reciente de cada activo y tipo de medición,

para que los mensajes atrasados no me hagan actuar sobre información desactualizada.

Criterios de aceptación

- La última lectura se mantiene por activo y tipo de medición.
- Una lectura más reciente actualiza valor, unidad, fecha de origen y severidad correspondiente.
- Una lectura anterior conserva su evidencia sin reemplazar la lectura actual.
- Varias señales del mismo activo y medición dentro de la colección dejan como resultado la más reciente válida.
- Se aplica la regla documentada para empates de fecha y hora.
- Se respeta la política acordada de acción sobre señales críticas atrasadas.

Evidencia

Llegada en orden y fuera de orden, tanto entre publicaciones como dentro de una colección.

Esfuerzo relativo

Orden temporal, agrupación y consistencia del resumen del activo.

### US-204: Cambiar límites sin desplegar código

BR-204 · Development · 2 pts

Resultado: Límites administrables

Como coordinador de mantenimiento autorizado,

quiero ajustar los límites de advertencia y críticos por activo y tipo de medición,

para que las reglas de monitoreo reflejen los equipos sin requerir un despliegue de código.

Criterios de aceptación

- Los límites no están escritos directamente en el código.
- Una persona autorizada puede modificarlos mediante el mecanismo administrativo elegido.
- Al procesar una nueva señal se aplican los límites vigentes, sin desplegar código.
- Se conocen los resultados para valores exactamente iguales a los límites.
- La falta de configuración o un rango contradictorio producen un resultado explicable; no se clasifican silenciosamente como normales.
- El base no requiere reclasificar todo el historial al cambiar un límite.

Evidencia

Cambiar un límite y publicar un valor que cambie de clasificación.

Esfuerzo relativo

Configuración simple y lectura desde el procesador. Si la elección exige una UI nueva de administración, debe estimarse y acotarse aparte.

### US-205: Generar una sola intervención por mensaje crítico

BR-205 · Development · 5 pts

Resultado: Intervención sin duplicados por mensaje

Como coordinador de mantenimiento,

quiero que cada nuevo mensaje crítico cree una sola intervención operativa y que las entregas repetidas reutilicen ese resultado,

para que el equipo no realice trabajo duplicado.

Criterios de aceptación

- Una señal crítica válida y vigente crea una intervención con activo, edificio, causa, severidad y estado de seguimiento.
- Reenviar su misma identidad no crea una segunda intervención.
- Los duplicados se reconocen tanto dentro de una colección como en entregas posteriores.
- La señal y sus reenvíos pueden relacionarse con el resultado existente.
- Una clave reenviada con contenido diferente se identifica como conflicto.
- Una falla de creación no deja una señal marcada como procesada satisfactoriamente sin su resultado obligatorio.
- El equipo explica el mecanismo de protección frente a duplicados y qué garantías o límites tiene ante entregas concurrentes.

Evidencia

Señal crítica, reenvío, conteo de intervenciones y caso de error controlado.

Esfuerzo relativo

Identidad, consistencia y recuperación segura.

### US-206: Diferenciar normal, advertencia y crítico

BR-206 · Development · 2 pts

Resultado: Respuesta por severidad

Como operador de edificios,

quiero que las lecturas produzcan respuestas diferentes según su severidad,

para priorizar la atención sin tratar cada mensaje como una emergencia.

Criterios de aceptación

- Una señal normal vigente actualiza la lectura sin crear intervención.
- Una advertencia vigente actualiza la lectura y se distingue visualmente, sin crear intervención obligatoria.
- Una crítica vigente utiliza el recorrido de US-205.
- La severidad se obtiene de la configuración de US-204 y no de valores independientes en la UI.
- El resumen del activo utiliza la política de múltiples mediciones acordada en Discovery.

Evidencia

Tres valores representativos y valores de frontera.

Esfuerzo relativo

Reglas acotadas que reutilizan el procesamiento y los límites.

### US-207: Consultar el estado desde una experiencia propia

BR-207 · Development · 5 pts

Resultado: Experiencia del operador

Como operador de edificios,

quiero una vista clara de mis edificios y activos con la severidad y la información de la última lectura,

para identificar qué necesita atención y abrir los registros relevantes.

Criterios de aceptación

- La vista principal está implementada en LWC y consulta datos reales.
- Permite filtrar por edificio y severidad.
- Muestra activo, edificio, severidad y fecha de la lectura de origen, con etiquetas comprensibles.
- Distingue un activo sin lecturas de un filtro sin resultados.
- Ofrece navegación al activo y a la intervención disponible.
- Tiene estados de carga, datos, vacío y error, con mensajes y opción de recuperación apropiados.
- Permite actualizar la información bajo demanda. La actualización automática es extra.
- Reutiliza componentes base cuando cubren la necesidad y no requiere un diseño gráfico complejo.

Evidencia

LWC con datos de varias severidades, filtros y estados alternativos.

Esfuerzo relativo

Interfaz, consulta Apex, navegación y manejo de estados.

### US-208: Respetar la autorización del usuario

BR-208 · Development · 3 pts

Resultado: Acceso autorizado en interfaz y servidor

Como gerente de operaciones,

quiero que los usuarios accedan solo a los registros, campos y acciones operativos que están autorizados a usar,

para que la información restringida esté protegida más allá de lo que muestra la pantalla.

Criterios de aceptación

- Existe una matriz breve de acceso para operador, coordinador y administrador.
- El operador no puede obtener datos de un edificio no autorizado mediante el LWC ni solicitándolos directamente a Apex.
- Se respetan permisos de objeto y campo además del acceso al registro.
- Las acciones administrativas, como cambiar límites o consultar errores técnicos, tienen una autorización definida.
- Se prueba con dos usuarios de permisos diferentes, incluyendo acceso insuficiente.
- El procesamiento de ingesta tiene una autorización explícita y separada del contexto del operador.

Evidencia

Resultados diferentes por usuario y pruebas de solicitudes sin acceso. Usar un usuario distinto en una prueba no demuestra por sí solo que se estén respetando todos los permisos: deben comprobarse resultados concretos.

Esfuerzo relativo

Una frontera de consulta y acciones limitada. Compartición dinámica por múltiples ciudades o regiones es extra.

### US-209: Investigar el procesamiento

BR-209 · Development · 3 pts

Resultado: Trazabilidad de procesamiento

Como administrador de Salesforce,

quiero inspeccionar el resultado de procesamiento y el motivo de rechazo de cada mensaje,

para investigar las fallas y determinar si un reintento es seguro.

Criterios de aceptación

- Es posible buscar la señal por su identidad y reconocer su fecha de origen y procesamiento.
- Se distingue entre procesada, rechazada, duplicada, atrasada o fallida, o estados equivalentes explicados por el equipo.
- Se registra una causa útil de rechazo o falla y el resultado relacionado cuando exista.
- Se identifica si un reintento sería seguro o qué condición debe corregirse primero.
- No se almacenan contraseñas, tokens ni datos innecesarios en la evidencia.
- La vista de investigación está restringida a personas autorizadas.
- La información persiste después de la ejecución; no depende únicamente de logs temporales.

Evidencia

Inspección de señales normal, inválida, duplicada y atrasada. No se exige una consola LWC nueva ni un botón de reproceso.

Esfuerzo relativo

Modelo de trazabilidad y presentación administrativa simple.

### US-210: Validación integrada y evidencia de entrega

BR-210 · QA & Delivery · 5 pts

Resultado: Validación integrada y evidencia de entrega

Esta historia pertenece a la fase Testing & Delivery; su detalle completo se definirá en esa fase.

## My Team

John Alejandro Pastor

Tú

Juan Diego Velasquez

Teammate

Un equipo comparte un mismo sprint. Una persona solo puede pertenecer a un equipo a la vez.

## Sprint Evaluation

N/A

Review Feedback

Individual Comments

El feedback de este sprint aún no está disponible.
