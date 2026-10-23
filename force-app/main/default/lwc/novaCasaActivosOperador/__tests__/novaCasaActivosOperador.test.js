import { createElement } from 'lwc';
import NovaCasaActivosOperador from 'c/novaCasaActivosOperador';
import getAssets from '@salesforce/apex/ActivosOperadorController.getAssets';
import getBuildings from '@salesforce/apex/ActivosOperadorController.getBuildings';
import getCapacidades from '@salesforce/apex/ActivosOperadorController.getCapacidades';

// Monitor principal del operador (novaCasaActivosOperador, de Juan Diego). Los metodos Apex @wire se
// reemplazan por test wire adapters; los imperativos por jest.fn. Solo se cubre el comportamiento real
// del componente, sin tocar produccion.
jest.mock(
    '@salesforce/apex/ActivosOperadorController.getAssets',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/ActivosOperadorController.getBuildings',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/ActivosOperadorController.getCapacidades',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/ActivosOperadorController.getHistorial',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/IntervencionOperadorController.getEstadosSeguimiento',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/IntervencionOperadorController.crearIntervencion',
    () => ({ default: jest.fn(() => Promise.resolve({})) }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/IntervencionOperadorController.actualizarSeguimiento',
    () => ({ default: jest.fn(() => Promise.resolve({})) }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/IntervencionOperadorController.cerrarIntervencionesDelActivo',
    () => ({ default: jest.fn(() => Promise.resolve({})) }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/IngestaController.traerSenales',
    () => ({ default: jest.fn(() => Promise.resolve({})) }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/IngestaController.estadoIngesta',
    () => ({ default: jest.fn(() => Promise.resolve({})) }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/IngestaController.getProgramacion',
    () => ({ default: jest.fn(() => Promise.resolve({})) }),
    { virtual: true }
);

const NOW_ISO = new Date().toISOString();

const ASSETS_PAGE = {
    truncated: false,
    assetLimit: 50,
    totalCount: 2,
    assets: [
        {
            assetId: '02i000000000001AAA',
            name: 'Bomba de agua torre A',
            accountId: '001000000000001AAA',
            accountName: 'Edificio Central',
            assetType: 'WATER_PUMP',
            externalId: 'WP-001',
            severityLevel: 2,
            lastSignalAt: NOW_ISO,
            openInterventionCount: 0,
            openIntervention: null,
            lastClosedIntervention: null,
            readings: [
                { measurementType: 'WATER_PRESSURE', value: 0.4, unit: 'BAR', severityLevel: 2, occurredAt: NOW_ISO }
            ]
        },
        {
            assetId: '02i000000000002AAA',
            name: 'Medidor de agua torre B',
            accountId: '001000000000002AAA',
            accountName: 'Edificio Norte',
            assetType: 'WATER_METER',
            externalId: 'WM-002',
            severityLevel: 0,
            lastSignalAt: NOW_ISO,
            openInterventionCount: 0,
            openIntervention: null,
            lastClosedIntervention: null,
            readings: [
                { measurementType: 'WATER_CONSUMPTION', value: 12, unit: 'LITER_PER_15_MIN', severityLevel: 0, occurredAt: NOW_ISO }
            ]
        }
    ]
};

function montar() {
    const element = createElement('c-nova-casa-activos-operador', { is: NovaCasaActivosOperador });
    document.body.appendChild(element);
    return element;
}

// Deja que el microtask del wire y el re-render terminen.
function flush() {
    return Promise.resolve().then(() => Promise.resolve());
}

function emitirBase(element, page = ASSETS_PAGE) {
    getBuildings.emit({ options: [], truncated: false });
    getCapacidades.emit({});
    getAssets.emit(page);
    return flush();
}

describe('c-nova-casa-activos-operador', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('muestra el esqueleto de carga de BR-207 antes de tener activos', () => {
        const element = montar();
        const cargando = element.shadowRoot.querySelector('.esqueleto');
        expect(cargando).not.toBeNull();
        expect(element.shadowRoot.textContent).toContain('Cargando activos');
    });

    it('renderiza una tarjeta por activo con su severidad (Critico / Estable)', async () => {
        const element = montar();
        await emitirBase(element);

        const tarjetas = element.shadowRoot.querySelectorAll('.cuadricula .tarjeta-activo');
        expect(tarjetas.length).toBe(2);

        const estados = [...element.shadowRoot.querySelectorAll('.cuadricula .banda-estado')].map((e) =>
            e.textContent.trim()
        );
        expect(estados.some((t) => t.includes('Crítico'))).toBe(true);
        expect(estados.some((t) => t.includes('Estable'))).toBe(true);
    });

    it('resume la situacion destacando al menos un critico en el banner', async () => {
        const element = montar();
        await emitirBase(element);

        const banner = element.shadowRoot.querySelector('.situacion');
        expect(banner.className).toContain('situacion-critico');
        expect(banner.textContent).toContain('1 crítico');
    });

    it('al filtrar por severidad vuelve a consultar al controlador con el nivel elegido', async () => {
        const element = montar();
        await emitirBase(element);

        const select = element.shadowRoot.querySelector('select[name="severity"]');
        select.value = '2';
        select.dispatchEvent(new CustomEvent('change'));
        await flush();

        expect(getAssets.getLastConfig().severityLevel).toBe(2);
    });

    it('muestra el estado vacio de BR-207 cuando el usuario no tiene activos', async () => {
        const element = montar();
        await emitirBase(element, { truncated: false, assetLimit: 50, totalCount: 0, assets: [] });

        const vacio = element.shadowRoot.querySelector('.estado-centro');
        expect(vacio).not.toBeNull();
        expect(vacio.textContent).toContain('No hay activos para mostrar');
    });

    it('muestra el estado de error de BR-207 ante un fallo del controlador', async () => {
        const element = montar();
        getBuildings.emit({ options: [], truncated: false });
        getCapacidades.emit({});
        getAssets.error({ message: 'No tienes acceso a estos edificios' });
        await flush();

        const alerta = element.shadowRoot.querySelector('[role="alert"]');
        expect(alerta).not.toBeNull();
        expect(alerta.textContent).toContain('No tienes acceso a estos edificios');
    });
});
