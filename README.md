# Sprint 2 — Nova Casa Telemetría

Development · desde el 25 sep 2026 · Path `onboarding-csg` (MDSS)

Equipo: John Alejandro Pastor + Juan Diego Velásquez.

## Qué es este repo ahora

Estamos en **Development**. El repo es un proyecto Salesforce DX: el código y la metadata viven en `force-app/`. Los prototipos de Discovery (15–26 sep) están en `entregables/` y guían el diseño.

## Cómo navegar el repo

| Archivo | Qué es | ¿Se edita a mano? |
|---|---|---|
| `Sprint 2 - Nova Casa.md` | **Fuente de verdad**, verbatim de MDSS: brief, personas, Laura, frontera formativa, BR-201 a 210, acuerdos, entregables, contrato del simulador. | Solo para pegar contenido nuevo tal cual llega de MDSS. No parafrasear. |
| `AGENTS.md` | Instrucciones para agentes de IA: reglas que no se pueden contradecir, frontera formativa, flujo de ramas. | Sí |
| `docs/br-201-210.md` | Los 10 BR, texto idéntico al de `Sprint 2 - Nova Casa.md`, para referencia rápida. | Solo si el texto fuente cambia |
| `docs/decisiones.md` | Decisiones propias del par (ADR-lite): alternativa descartada, trade-off, riesgos. Esto sí lo escribimos nosotros. | Sí |
| `docs/entendimiento.md` | Entregable 1 en formato de notas de trabajo del par: problema prioritario, indicadores, preguntas y supuestos. | Sí |
| `entregables/` | Versiones presentables al facilitador: `01` entendimiento (PDF), `02` prototipo, `03` arquitectura (guía interactiva y diagrama), `04` modelo de datos. Los HTML son autocontenidos y se abren sin servidor. | Sí |
| `force-app/` | Código y metadata de Salesforce: objetos, Apex, LWC, permission sets. | Sí |
| `sfdx-project.json` · `.forceignore` · `config/` | Configuración del proyecto Salesforce DX. | Rara vez |

Si un doc nuevo repite contenido de MDSS con otras palabras, no se agrega: se cita el verbatim.

## Flujo de trabajo

- **Ramas**: `feature/<descripcion-corta>` para trabajo manual del equipo. `cursor/<descripcion>` para agentes de IA.
- **`main` no recibe commits directos de un agente.** El trabajo de un agente queda en su rama hasta que el otro miembro del par lo revisa y mergea.
- **Aprobación de entregables**: el facilitador de MDSS aprueba cada uno de los 6 entregables; el acuerdo interno del par no lo cierra por sí solo.
- **GitHub**: [jpastorSFDC/nova-casa-telemetria](https://github.com/jpastorSFDC/nova-casa-telemetria), público. No asumir que algo se subió hasta confirmarlo en el remoto.

## Cómo trabajar con la org

Requiere la [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`). Cada uno conecta su propia org:

```bash
sf org login web -a nova-cdo --instance-url https://<tu-dominio>.my.salesforce.com
sf config set target-org nova-cdo
```

Desplegar, siempre ensayando primero:

```bash
sf project deploy start --source-dir force-app --dry-run
sf project deploy start --source-dir force-app
```

Correr los tests de Apex:

```bash
sf apex run test --test-level RunLocalTests --result-format human --wait 10
```

Pendiente de documentar cuando exista: la conexión con el simulador de Heroku y cómo ver el procesamiento de los Platform Events.

## Definition of Done de Discovery

Los prototipos de `entregables/`, según la sección "Entregables" de `Sprint 2 - Nova Casa.md`, aprobados por el facilitador.
