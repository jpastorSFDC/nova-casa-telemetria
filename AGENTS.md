# Sprint 2 — Nova Casa Telemetría

Discovery & Design (15–26 sep). Development y QA están bloqueados en MDSS. No generar Apex, LWC ni metadata de producción salvo que John lo pida explícitamente.

Equipo: John Alejandro Pastor + Juan Diego Velásquez. Responder en español.

## Fuente de verdad

Leer esto antes de diseñar o implementar. No inventar campos del PE ni cuerpos de BR. No parafrasear el contenido de MDSS en un doc nuevo: si hace falta citarlo, se cita literal.

- `Sprint 2 - Nova Casa.md` — **verbatim** de la plataforma MDSS: brief, personas, Laura, frontera formativa, BR-201 a 210, acuerdos, entregables, contrato del simulador. Es la fuente que manda si algo no coincide con otro doc. No se edita a mano salvo para pegar contenido nuevo tal cual llega de MDSS.
- `docs/br-201-210.md` — los mismos BR-201 a 210, en archivo aparte para referencia rápida. Texto idéntico al de `Sprint 2 - Nova Casa.md`.
- `docs/decisiones.md` — decisiones propias del par (no de MDSS), con alternativa descartada y trade-off.

## Decisores y flujo

El facilitador de MDSS aprueba cada entregable; el acuerdo interno del par no lo cierra por sí solo. Antes de proponer una alternativa a un acuerdo cerrado, registrarla en `docs/decisiones.md` con justificación y criterios de prueba, no solo aplicarla.

Ramas de agentes de IA: prefijo `cursor/`. Ramas manuales del equipo: `feature/<descripcion>`, revisadas por el otro miembro del par antes de mergear. **`main` no recibe commits directos de un agente**: el trabajo de un agente vive en su rama `cursor/...` hasta que John o Juan Diego lo revisan y mergean.

Remoto: `origin` → github.com/jpastorSFDC/nova-casa-telemetria, **público**. No asumir que algo llegó a GitHub hasta confirmarlo en el remoto. No subir nada con credenciales, tokens ni datos de la org.

## Acuerdos que el agente no puede contradecir

- Última lectura = **activo + tipo de medición**. Temperatura no pisa presión.
- Severidad del activo = **máxima** de las últimas lecturas válidas (otra política solo si se justifica, documenta y prueba).
- Identidad = `source` + `messageId`. Reenvío = misma identidad.
- Misma clave: no actualiza estado ni crea intervención. Misma clave con **contenido distinto** = conflicto, no aviso nuevo.
- Base: **una intervención por mensaje crítico único**. Consolidar claves distintas en un incidente abierto es extra.
- Señal atrasada: se guarda evidencia; **no** pisa estado actual; **no** abre intervención crítica. Alternativa solo si distingue histórico vs actual y tiene pruebas.
- Mismo `occurredAt`: regla **determinista** (aún por definir en decisiones). No dejarlo al orden de llegada.
- Umbrales **fuera de código** (Custom Metadata / equivalente). Operadores y valores exactos aún por acordar.
- Publicar un PE ≠ procesarlo. El log distingue ambos momentos.
- Ingesta no depende de permisos de operador/admin. LWC/Apex de consulta van con otra autorización (BR-208).

## Frontera formativa (obligatoria en Development)

Platform Events reales desde el simulador · Apex subscriber programático y bulkificado (hasta 200) · LWC operador · FLS/CRUD en UI y servidor · tests que fallan si se rompe el comportamiento.

Preferir objetos estándar si alcanzan. Custom solo justificado en el modelo de datos.

## Discovery: no adelantar código

Entregables = prototipos de baja fidelidad (página de entendimiento, 2 pantallas, arquitectura, modelo, contrato, decisiones/riesgos). No se evalúa acabado gráfico ni una app terminada.
