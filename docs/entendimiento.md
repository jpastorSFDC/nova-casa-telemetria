# Entendimiento del problema (Entregable 1)

Personas, historia de referencia (Laura) y frontera formativa: ver `Sprint 2 - Nova Casa.md`, secciones "Problema y personas" e "Historia de referencia". No se repiten aquí para no duplicar la fuente verbatim.

Lo que sigue es interpretación propia del par, no texto de MDSS.

## Problema prioritario

**El operador de edificios no tiene una fuente única y confiable del estado actual de sus equipos, por lo que reacciona tarde o duplica intervenciones.**

Por qué este y no otro de los cuatro riesgos del brief:

- Es el riesgo de la persona que protagoniza la historia de referencia (Laura). El facilitador la eligió como recorrido obligatorio de la demo, no las otras tres.
- Los otros tres riesgos son consecuencia de este, no problemas independientes:
  - El coordinador duplica trabajo *porque* el operador (o el sistema) no reconoce que un aviso ya se atendió.
  - El gerente compara tarde *porque* la señal no llegó a tiempo al operador en primer lugar.
  - El administrador no puede explicar un fallo *porque* no hay evidencia de qué pasó con la señal cuando llegó.
- Resolver la fuente única y confiable resuelve, como efecto secundario, la mayoría de BR-202 a BR-209.

## Indicadores de éxito del prototipo

No son resultados de producción (no hay producción todavía). Son lo que este prototipo de Discovery debe poder demostrar:

1. **Recepción real, no simulada**: la arquitectura documentada muestra cómo una señal publicada de verdad por el simulador llega a Salesforce y se refleja en el prototipo de UI, sin captura manual (evidencia de BR-201).
2. **Severidad y antigüedad visibles sin ambigüedad**: el prototipo de baja fidelidad distingue, para los cuatro mensajes del ejemplo del contrato (MSG-000101 a MSG-000104), cuál es la lectura vigente de cada activo y cuál quedó atrasada.
3. **Los dos comportamientos de la historia de Laura quedan explicados en el diseño**: cómo se evita una segunda intervención por reenvío, y cómo una lectura atrasada no pisa el estado actual — sin necesidad de código para verificarlo, solo con el modelo y la arquitectura.

## Preguntas abiertas

Las 4 preguntas ya registradas como pendientes en `docs/decisiones.md` (regla de empate en `occurredAt`, valores de umbral, objeto de intervención, modelo de sharing) no se repiten aquí. Además de esas:

- El contrato documentado es un `GET /api/v1/telemetry` (HTTP síncrono). El brief exige "Platform Events publicados realmente desde el simulador". ¿El simulador publica el PE directamente, o hace falta un puente (algo que consulte el endpoint y republique como PE)? Esto define media arquitectura y no está resuelto.
- ¿Existen ya objetos de Edificio/Activo en esta org (de un sprint anterior), o se parte de una org limpia para este dominio?
- ¿"Operador", "Coordinador", "Gerente" y "Administrador" son Profiles/Permission Sets ya provisionados por MDSS, o hay que definirlos nosotros?

## Supuestos

- Edificio y Activo son conceptos nuevos para esta org; no hay objetos de sprints previos que representen mantenimiento de edificios (el sprint anterior modelaba venta de unidades, no activos).
- El simulador se puede apuntar a nuestra org de destino (token, endpoint) sin trabajo adicional de nuestra parte; eso lo provee MDSS.
- El límite de 200 señales por lote (BR-202) no es arbitrario: coincide con el límite de Salesforce por contexto de trigger, y el diseño debe apoyarse en eso, no pelear contra otro número.
