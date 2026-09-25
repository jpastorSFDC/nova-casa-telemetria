# Sprint 2 — Nova Casa Telemetría

Discovery & Design · 15–26 sep 2026 · Path `onboarding-csg` (MDSS)

Equipo: John Alejandro Pastor + Juan Diego Velásquez.

## Qué es este repo ahora

Estamos en **Discovery**, no en Development. No hay código de producción todavía (ni Apex, ni LWC, ni metadata real) salvo pedido explícito. El entregable de esta fase son **prototipos de baja fidelidad**: documentos, diagramas y mockups — no una app funcional.

## Cómo navegar el repo

| Archivo | Qué es | ¿Se edita a mano? |
|---|---|---|
| `Sprint 2 - Nova Casa.md` | **Fuente de verdad**, verbatim de MDSS: brief, personas, Laura, frontera formativa, BR-201 a 210, acuerdos, entregables, contrato del simulador. | Solo para pegar contenido nuevo tal cual llega de MDSS. No parafrasear. |
| `AGENTS.md` | Instrucciones para agentes de IA: reglas que no se pueden contradecir, frontera formativa, flujo de ramas. | Sí |
| `docs/br-201-210.md` | Los 10 BR, texto idéntico al de `Sprint 2 - Nova Casa.md`, para referencia rápida. | Solo si el texto fuente cambia |
| `docs/decisiones.md` | Decisiones propias del par (ADR-lite): alternativa descartada, trade-off, riesgos. Esto sí lo escribimos nosotros. | Sí |
| `docs/entendimiento.md` | Entregable 1 en formato de notas de trabajo del par: problema prioritario, indicadores, preguntas y supuestos. | Sí |
| `entregables/` | Versiones presentables al facilitador: `01` entendimiento (PDF), `02` prototipo, `03` arquitectura (guía interactiva y diagrama), `04` modelo de datos. Los HTML son autocontenidos y se abren sin servidor. | Sí |

Si un doc nuevo repite contenido de MDSS con otras palabras, no se agrega: se cita el verbatim.

## Flujo de trabajo

- **Ramas**: `feature/<descripcion-corta>` para trabajo manual del equipo. `cursor/<descripcion>` para agentes de IA.
- **`main` no recibe commits directos de un agente.** El trabajo de un agente queda en su rama hasta que el otro miembro del par lo revisa y mergea.
- **Aprobación de entregables**: el facilitador de MDSS aprueba cada uno de los 6 entregables; el acuerdo interno del par no lo cierra por sí solo.
- **GitHub**: [jpastorSFDC/nova-casa-telemetria](https://github.com/jpastorSFDC/nova-casa-telemetria), público. No asumir que algo se subió hasta confirmarlo en el remoto.

## Definition of Done (esta fase)

Ver sección "Entregables" en `Sprint 2 - Nova Casa.md`: 6 prototipos (entendimiento del problema, mockup de baja fidelidad, arquitectura de una página, modelo de datos inicial, contrato del mensaje, decisiones y riesgos), aprobados por el facilitador.

## Próxima fase (Development)

Cuando arranque, esta sección se actualiza con: cómo instalar/desplegar (org Salesforce, simulador Heroku), cómo correr y ver logs de Platform Events, y cómo correr los tests de Apex.
