import {
    GENERIC_ERROR,
    MEASUREMENT_LABELS,
    STALE_AFTER_MINUTES,
    UNIT_LABELS,
    SIGNAL_TYPE_LABELS,
    reduceError,
    relativeAge,
    severityUi
} from 'c/novaCasaEtiquetas';

const MINUTE = 60000;
const NOW = Date.UTC(2026, 9, 16, 12, 0, 0);

describe('severityUi', () => {
    it('maps the three levels to their label and glyph', () => {
        expect(severityUi(2)).toMatchObject({ key: 'critico', label: 'Crítico', glyph: '●' });
        expect(severityUi(1)).toMatchObject({ key: 'advertencia', label: 'Precaución', glyph: '▲' });
        expect(severityUi(0)).toMatchObject({ key: 'normal', label: 'Estable', glyph: '○' });
    });

    it('never turns a missing or unknown level into Estable', () => {
        for (const level of [null, undefined, 3, -1, NaN]) {
            const ui = severityUi(level);
            expect(ui.key).toBe('nivel');
            expect(ui.label).toBe('Sin dato');
            expect(ui.label).not.toBe('Estable');
        }
    });
});

describe('reduceError', () => {
    it('returns an empty string when there is no error', () => {
        expect(reduceError(undefined)).toBe('');
        expect(reduceError(null)).toBe('');
    });

    it('shows the controller message when body.message is a non-empty string', () => {
        expect(reduceError({ body: { message: 'No tienes acceso a este activo.' } })).toBe(
            'No tienes acceso a este activo.'
        );
    });

    it('falls back to the generic message for anything else, so no internals reach the screen', () => {
        const cases = [
            {},
            { body: null },
            { body: [{ message: 'DML failed: FIELD_CUSTOM_VALIDATION_EXCEPTION' }] },
            { body: { message: '' } },
            { body: { message: 42 } },
            { message: 'System.QueryException: secret detail', stack: 'at line 1' },
            new Error('Script-thrown exception')
        ];
        for (const error of cases) {
            expect(reduceError(error)).toBe(GENERIC_ERROR);
        }
    });
});

describe('relativeAge', () => {
    it('is unknown when either time is not a number', () => {
        for (const [ms, now] of [
            [undefined, NOW],
            [null, NOW],
            ['1', NOW],
            [NaN, NOW],
            [NOW, undefined],
            [NOW, NaN]
        ]) {
            expect(relativeAge(ms, now)).toEqual({ text: '', isFuture: false, isStale: false, isKnown: false });
        }
    });

    it('never shows a negative age: an origin time ahead of now is labelled as the simulator clock', () => {
        expect(relativeAge(NOW + MINUTE, NOW)).toEqual({
            text: 'hora del simulador',
            isFuture: true,
            isStale: false,
            isKnown: true
        });
    });

    it('writes the age in minutes, hours and days', () => {
        expect(relativeAge(NOW, NOW).text).toBe('hace menos de 1 min');
        expect(relativeAge(NOW - 59 * 1000, NOW).text).toBe('hace menos de 1 min');
        expect(relativeAge(NOW - MINUTE, NOW).text).toBe('hace 1 min');
        expect(relativeAge(NOW - 59 * MINUTE, NOW).text).toBe('hace 59 min');
        expect(relativeAge(NOW - 60 * MINUTE, NOW).text).toBe('hace 1 h');
        expect(relativeAge(NOW - 1439 * MINUTE, NOW).text).toBe('hace 23 h');
        expect(relativeAge(NOW - 1440 * MINUTE, NOW).text).toBe('hace 1 d');
        expect(relativeAge(NOW - 3 * 1440 * MINUTE, NOW).text).toBe('hace 3 d');
    });

    it('marks a reading stale only after STALE_AFTER_MINUTES, not at the limit', () => {
        expect(STALE_AFTER_MINUTES).toBe(60);
        expect(relativeAge(NOW - STALE_AFTER_MINUTES * MINUTE, NOW).isStale).toBe(false);
        expect(relativeAge(NOW - (STALE_AFTER_MINUTES + 1) * MINUTE, NOW).isStale).toBe(true);
        expect(relativeAge(NOW - 5 * MINUTE, NOW).isStale).toBe(false);
    });
});

describe('label tables', () => {
    it('cover every measurement type, unit and signal type the simulator contract uses', () => {
        expect(Object.keys(MEASUREMENT_LABELS).sort()).toEqual([
            'CAMERA_CONNECTIVITY',
            'ENERGY_CONSUMPTION',
            'TEMPERATURE',
            'WATER_CONSUMPTION',
            'WATER_PRESSURE'
        ]);
        expect(Object.keys(UNIT_LABELS).sort()).toEqual(['BAR', 'CELSIUS', 'KWH_PER_15_MIN', 'LITER_PER_15_MIN', 'SECONDS']);
        expect(Object.keys(SIGNAL_TYPE_LABELS).sort()).toEqual(['CONNECTIVITY', 'MEASUREMENT']);
    });
});
