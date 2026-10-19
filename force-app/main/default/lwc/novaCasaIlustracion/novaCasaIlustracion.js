import { LightningElement, api } from 'lwc';

// Asset.Tipo_Activo__c values with their own drawing, plus BUILDING; anything else gets the neutral device.
const TECHNICAL_ROOM = 'TECHNICAL_ROOM';
const WATER_PUMP = 'WATER_PUMP';
const WATER_METER = 'WATER_METER';
const ENERGY_METER = 'ENERGY_METER';
const SECURITY_CAMERA = 'SECURITY_CAMERA';
const VENTILATION = 'VENTILATION';
const BUILDING = 'BUILDING';
const KNOWN_TYPES = [TECHNICAL_ROOM, WATER_PUMP, WATER_METER, ENERGY_METER, SECURITY_CAMERA, VENTILATION, BUILDING];

const TONE_BY_LEVEL = { 2: 'critico', 1: 'advertencia', 0: 'normal' };
const SIZES = ['sm', 'md', 'lg'];

function toLevel(value) {
    if (value === null || value === undefined || value === '') {
        return null;
    }
    const level = Number(value);
    return level === 0 || level === 1 || level === 2 ? level : null;
}

// Decorative illustration of an asset type or a building (D042). The type and the name are always text next to it.
export default class NovaCasaIlustracion extends LightningElement {
    /** Asset.Tipo_Activo__c value, or BUILDING. */
    @api tipo;
    /** Severity level (2, 1, 0) that tints the tile; null keeps it neutral (blue for BUILDING). */
    @api nivel;
    /** sm (32px), md (56px) or lg (72px). */
    @api tamano = 'md';

    get tileClass() {
        const size = SIZES.includes(this.tamano) ? this.tamano : 'md';
        const level = toLevel(this.nivel);
        let tone = 'nivel';
        if (level !== null) {
            tone = TONE_BY_LEVEL[level];
        } else if (this.tipo === BUILDING) {
            tone = 'edificio';
        }
        return `ilu ilu-${size} ilu-${tone}`;
    }

    get isTechnicalRoom() {
        return this.tipo === TECHNICAL_ROOM;
    }
    get isWaterPump() {
        return this.tipo === WATER_PUMP;
    }
    get isWaterMeter() {
        return this.tipo === WATER_METER;
    }
    get isEnergyMeter() {
        return this.tipo === ENERGY_METER;
    }
    get isSecurityCamera() {
        return this.tipo === SECURITY_CAMERA;
    }
    get isVentilation() {
        return this.tipo === VENTILATION;
    }
    get isBuilding() {
        return this.tipo === BUILDING;
    }
    get isFallback() {
        return !KNOWN_TYPES.includes(this.tipo);
    }
}
