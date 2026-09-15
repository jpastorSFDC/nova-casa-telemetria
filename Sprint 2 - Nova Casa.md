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
