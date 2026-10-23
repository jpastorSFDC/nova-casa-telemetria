import {
    MEASUREMENT_LABELS,
    UNIT_LABELS,
    SIGNAL_TYPE_LABELS,
    GENERIC_ERROR,
    STALE_AFTER_MINUTES,
    severityUi,
    reduceError,
    relativeAge
} from 'c/novaCasaEtiquetas';

// Pruebas directas de las funciones puras de la biblioteca de etiquetas (D012/D033/D041-D043).
// Son la base compartida por el monitor del operador y las tarjetas del Asset record page.

describe('severityUi', () => {
    it('mapea cada nivel conocido a su color, glifo y texto', () => {
        expect(severityUi(2)).toEqual({ key: 'critico', label: 'Crítico', glyph: '●' });
        expect(severityUi(1)).toEqual({ key: 'advertencia', label: 'Precaución', glyph: '▲' });
        expect(severityUi(0)).toEqual({ key: 'normal', label: 'Estable', glyph: '○' });
    });

    it('nunca degrada un nivel ausente a Estable: usa "Sin dato"', () => {
        const sinDato = { key: 'nivel', label: 'Sin dato', glyph: '?' };
        expect(severityUi(null)).toEqual(sinDato);
        expect(severityUi(undefined)).toEqual(sinDato);
    });

    it('un nivel desconocido tampoco se trata como Estable', () => {
        expect(severityUi(99).label).toBe('Sin dato');
    });
});

describe('relativeAge', () => {
    const NOW = 1_000_000_000_000;

    it('marca como no conocida una entrada que no es un número válido', () => {
        const result = relativeAge('no-numero', NOW);
        expect(result).toEqual({ text: '', isFuture: false, isStale: false, isKnown: false });
        expect(relativeAge(NaN, NOW).isKnown).toBe(false);
    });

    it('tolera una fecha de origen en el futuro (reloj del simulador) sin edad negativa', () => {
        const result = relativeAge(NOW + 60_000, NOW);
        expect(result.isFuture).toBe(true);
        expect(result.isKnown).toBe(true);
        expect(result.text).toBe('hora del simulador');
        expect(result.text).not.toContain('-');
    });

    it('describe la antigüedad en minutos, horas y días', () => {
        expect(relativeAge(NOW - 30_000, NOW).text).toBe('hace menos de 1 min');
        expect(relativeAge(NOW - 5 * 60_000, NOW).text).toBe('hace 5 min');
        expect(relativeAge(NOW - 3 * 3_600_000, NOW).text).toBe('hace 3 h');
        expect(relativeAge(NOW - 2 * 86_400_000, NOW).text).toBe('hace 2 d');
    });

    it('marca como desactualizada (stale) solo cuando supera el umbral', () => {
        expect(relativeAge(NOW - STALE_AFTER_MINUTES * 60_000, NOW).isStale).toBe(false);
        expect(relativeAge(NOW - (STALE_AFTER_MINUTES + 1) * 60_000, NOW).isStale).toBe(true);
    });
});

describe('reduceError', () => {
    it('devuelve cadena vacía cuando no hay error', () => {
        expect(reduceError(null)).toBe('');
        expect(reduceError(undefined)).toBe('');
    });

    it('muestra el mensaje de la AuraHandledException (body.message)', () => {
        const error = { body: { message: 'Sin acceso a este edificio' } };
        expect(reduceError(error)).toBe('Sin acceso a este edificio');
    });

    it('cae al mensaje genérico cuando el body no trae un message de texto', () => {
        expect(reduceError({ body: [{ message: 'x' }] })).toBe(GENERIC_ERROR);
        expect(reduceError({ body: {} })).toBe(GENERIC_ERROR);
        expect(reduceError({})).toBe(GENERIC_ERROR);
    });
});

describe('diccionarios de etiquetas', () => {
    it('traducen los tipos de medición del contrato', () => {
        expect(MEASUREMENT_LABELS.TEMPERATURE).toBe('Temperatura');
        expect(MEASUREMENT_LABELS.WATER_PRESSURE).toBe('Presión de agua');
        expect(MEASUREMENT_LABELS.CAMERA_CONNECTIVITY).toBe('Conectividad de cámara');
    });

    it('traducen unidades y tipos de señal', () => {
        expect(UNIT_LABELS.CELSIUS).toBe('°C');
        expect(UNIT_LABELS.BAR).toBe('bar');
        expect(SIGNAL_TYPE_LABELS.MEASUREMENT).toBe('Medición');
        expect(SIGNAL_TYPE_LABELS.CONNECTIVITY).toBe('Conectividad');
    });
});
