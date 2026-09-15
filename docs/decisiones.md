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

## Pendientes heredados de la sección "Acuerdos" (aún por cerrar en Discovery)

Estos cuatro puntos necesitan una entrada D00X cada uno antes de cerrar el entregable 6:

1. Regla determinista cuando dos señales válidas del mismo `asset`+`measurement.type` tienen el mismo `occurredAt`.
2. Operadores y valores exactos de umbral por `asset.type` + `measurement.type` (van en metadata, no en código).
3. Objeto de intervención: Case, Work Order u otro, y por qué.
4. Modelo de sharing de edificios/activos para el operador (BR-208).

## Riesgos generales del sprint

- **Dependencia de facilitador**: cada entregable requiere aprobación externa; un ciclo de revisión lento puede bloquear el avance a Development.
- **Ambigüedad de "mensaje inválido"** (BR-202): sin definición cerrada, el ejemplo inválido que pide el entregable 5 (contrato del mensaje) queda pendiente de escribir.
- **Frontera formativa vs. tiempo disponible**: Platform Events + Apex bulkificado + LWC + seguridad + tests en 2 semanas es ambicioso; priorizar el recorrido de Laura (historia de referencia) sobre cobertura exhaustiva.
