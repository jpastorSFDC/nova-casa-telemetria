// Labels shared by the Asset record page components. Values mirror novaCasaActivosOperador (same wording, same glyphs);
// that component keeps its own copy for now, so change both together.

// Lectura_Vigente__c.Tipo_Medicion__c. Unknown values fall back to the raw value.
export const MEASUREMENT_LABELS = {
    TEMPERATURE: 'Temperatura',
    WATER_PRESSURE: 'Presión de agua',
    WATER_CONSUMPTION: 'Consumo de agua',
    ENERGY_CONSUMPTION: 'Consumo de energía',
    CAMERA_CONNECTIVITY: 'Conectividad de cámara'
};

// Glyph + text always accompany the color. A missing level is never mapped to Estable.
const SEVERITY_UI = {
    2: { key: 'critico', label: 'Crítico', glyph: '●' },
    1: { key: 'advertencia', label: 'Precaución', glyph: '▲' },
    0: { key: 'normal', label: 'Estable', glyph: '○' }
};
const SEVERITY_NO_LEVEL_UI = { key: 'nivel', label: 'Sin dato', glyph: '?' };

export function severityUi(level) {
    if (level === null || level === undefined) {
        return SEVERITY_NO_LEVEL_UI;
    }
    return SEVERITY_UI[level] || SEVERITY_NO_LEVEL_UI;
}

// Log_Senial__c.Message_Type__c; unknown values fall back to the raw value.
export const SIGNAL_TYPE_LABELS = {
    MEASUREMENT: 'Medición',
    CONNECTIVITY: 'Conectividad'
};

export const GENERIC_ERROR = 'No se pudo cargar la información. Intenta de nuevo o contacta a tu administrador.';

// Only the controller's AuraHandledException message (body.message) is shown; anything else is generic.
export function reduceError(error) {
    if (!error) {
        return '';
    }
    const body = error.body;
    if (body && !Array.isArray(body) && typeof body.message === 'string' && body.message) {
        return body.message;
    }
    return GENERIC_ERROR;
}

export const STALE_AFTER_MINUTES = 60;

// Relative age of an origin time (BR-207). Pure: takes epoch ms for the reading and for "now".
// An origin time ahead of now (simulator clock) is never shown as a negative age.
// Returns { text, isFuture, isStale, isKnown }.
export function relativeAge(ms, nowMs) {
    if (typeof ms !== 'number' || typeof nowMs !== 'number' || Number.isNaN(ms) || Number.isNaN(nowMs)) {
        return { text: '', isFuture: false, isStale: false, isKnown: false };
    }
    const diff = nowMs - ms;
    if (diff < 0) {
        return { text: 'hora del simulador', isFuture: true, isStale: false, isKnown: true };
    }
    const minutes = Math.floor(diff / 60000);
    let text;
    if (minutes < 1) {
        text = 'hace menos de 1 min';
    } else if (minutes < 60) {
        text = `hace ${minutes} min`;
    } else if (minutes < 1440) {
        text = `hace ${Math.floor(minutes / 60)} h`;
    } else {
        text = `hace ${Math.floor(minutes / 1440)} d`;
    }
    return { text, isFuture: false, isStale: minutes > STALE_AFTER_MINUTES, isKnown: true };
}
