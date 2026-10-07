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
