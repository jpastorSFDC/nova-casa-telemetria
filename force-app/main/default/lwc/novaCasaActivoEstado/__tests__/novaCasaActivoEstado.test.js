import { createElement } from 'lwc';
import NovaCasaActivoEstado from 'c/novaCasaActivoEstado';
import getEstadoActivo from '@salesforce/apex/ActivosOperadorController.getEstadoActivo';
import { getRecord } from 'lightning/uiRecordApi';

// getEstadoActivo (estado del activo) y getHistorial (historial del hijo) son @wire Apex: test wire adapter.
jest.mock(
    '@salesforce/apex/ActivosOperadorController.getEstadoActivo',
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

const ESTADO = {
    truncated: false,
    openInterventionCount: 1,
    openIntervention: {
        caseId: '500000000000001AAA',
        caseNumber: '00001234',
        status: 'En curso',
        subject: 'Temperatura critica en cuarto tecnico'
    },
    readings: [
        {
            measurementType: 'TEMPERATURE',
            value: 38.2,
            unit: 'CELSIUS',
            severityLevel: 2,
            occurredAt: '2026-10-20T12:00:00.000Z'
        },
        {
            measurementType: 'WATER_PRESSURE',
            value: 3.0,
            unit: 'BAR',
            severityLevel: 0,
            occurredAt: '2026-10-20T11:00:00.000Z'
        }
    ]
};

function montar() {
    const element = createElement('c-nova-casa-activo-estado', { is: NovaCasaActivoEstado });
    element.recordId = '001000000000001AAA';
    document.body.appendChild(element);
    return element;
}

function flush() {
    return Promise.resolve();
}

describe('c-nova-casa-activo-estado', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('muestra el estado de carga de BR-207 antes de recibir datos', () => {
        const element = montar();
        const spinner = element.shadowRoot.querySelector('lightning-spinner');
        expect(spinner).not.toBeNull();
    });

    it('lista una fila por lectura con su severidad', async () => {
        const element = montar();
        getRecord.emit({ fields: {} });
        getEstadoActivo.emit(ESTADO);
        await flush();

        const filas = element.shadowRoot.querySelectorAll('tbody tr');
        expect(filas.length).toBe(2);
        expect(filas[0].textContent).toContain('Temperatura');
        expect(filas[0].textContent).toContain('Crítico');
    });

    it('la severidad del activo es la mayor entre sus lecturas vigentes', async () => {
        const element = montar();
        getRecord.emit({ fields: {} });
        getEstadoActivo.emit(ESTADO);
        await flush();

        // Tiene una lectura critica (2) y una estable (0): el activo debe mostrarse como Critico.
        const banda = element.shadowRoot.querySelector('.banda-estado');
        expect(banda.textContent).toContain('Crítico');
    });

    it('muestra la intervencion abierta cuando existe', async () => {
        const element = montar();
        getRecord.emit({ fields: {} });
        getEstadoActivo.emit(ESTADO);
        await flush();

        const enlaceCaso = element.shadowRoot.querySelector('.caso-enlace');
        expect(enlaceCaso).not.toBeNull();
        expect(enlaceCaso.textContent).toContain('00001234');
    });

    it('indica cuando el activo no tiene lecturas', async () => {
        const element = montar();
        getRecord.emit({ fields: {} });
        getEstadoActivo.emit({ truncated: false, openInterventionCount: 0, openIntervention: null, readings: [] });
        await flush();

        const texto = element.shadowRoot.textContent;
        expect(texto).toContain('todavía no tiene lecturas');
    });

    it('muestra el estado de error de BR-207 ante un fallo del controlador', async () => {
        const element = montar();
        getEstadoActivo.error({ message: 'Sin acceso a este activo' });
        await flush();

        const alerta = element.shadowRoot.querySelector('[role="alert"]');
        expect(alerta).not.toBeNull();
        expect(alerta.textContent).toContain('Sin acceso a este activo');
    });
});
