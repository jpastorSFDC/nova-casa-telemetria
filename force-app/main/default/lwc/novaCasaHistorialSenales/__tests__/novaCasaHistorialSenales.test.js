import { createElement } from 'lwc';
import NovaCasaHistorialSenales from 'c/novaCasaHistorialSenales';
import getHistorial from '@salesforce/apex/ActivosOperadorController.getHistorial';

// getHistorial es un metodo Apex @wire cacheable: se mockea con el test wire adapter de sfdx-lwc-jest.
jest.mock(
    '@salesforce/apex/ActivosOperadorController.getHistorial',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

// Datos de prueba que imitan la respuesta del controlador (Log_Senial__c).
const HISTORY = {
    truncated: false,
    signals: [
        {
            resultado: 'Procesada',
            messageType: 'MEASUREMENT',
            measurementType: 'TEMPERATURE',
            value: 24.5,
            unit: 'CELSIUS',
            occurredAt: '2026-10-20T12:00:00.000Z'
        },
        {
            resultado: 'Atrasada',
            messageType: 'MEASUREMENT',
            measurementType: 'WATER_PRESSURE',
            value: 3.1,
            unit: 'BAR',
            occurredAt: '2026-10-20T11:30:00.000Z'
        },
        {
            resultado: 'Rechazada',
            messageType: 'MEASUREMENT',
            measurementType: 'TEMPERATURE',
            value: null,
            unit: 'CELSIUS',
            occurredAt: '2026-10-20T11:00:00.000Z'
        }
    ]
};

function montar() {
    const element = createElement('c-nova-casa-historial-senales', { is: NovaCasaHistorialSenales });
    element.assetId = '001000000000001AAA';
    document.body.appendChild(element);
    return element;
}

function flush() {
    return Promise.resolve();
}

describe('c-nova-casa-historial-senales', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renderiza una fila por senal con su resultado y valor', async () => {
        const element = montar();
        getHistorial.emit(HISTORY);
        await flush();

        const filas = element.shadowRoot.querySelectorAll('tbody tr');
        expect(filas.length).toBe(3);

        const resultados = element.shadowRoot.querySelectorAll('.celda-resultado .res');
        expect(resultados[0].textContent).toContain('Procesada');
        expect(resultados[1].textContent).toContain('Atrasada');
        expect(resultados[2].textContent).toContain('Rechazada');
    });

    it('etiqueta las senales de solo evidencia y las no aceptadas', async () => {
        const element = montar();
        getHistorial.emit(HISTORY);
        await flush();

        const etiquetas = [...element.shadowRoot.querySelectorAll('tbody .etiqueta')].map((e) =>
            e.textContent.trim()
        );
        expect(etiquetas).toContain('solo evidencia');
        expect(etiquetas).toContain('no aceptada');
    });

    it('filtra la tabla al pulsar un chip de resultado', async () => {
        const element = montar();
        getHistorial.emit(HISTORY);
        await flush();

        const chipRechazada = [...element.shadowRoot.querySelectorAll('.filtro')].find(
            (c) => c.dataset.value === 'Rechazada'
        );
        expect(chipRechazada).toBeTruthy();
        chipRechazada.click();
        await flush();

        const filas = element.shadowRoot.querySelectorAll('tbody tr');
        expect(filas.length).toBe(1);
        expect(filas[0].textContent).toContain('Rechazada');
    });

    it('muestra el estado vacio de BR-207 cuando no hay senales', async () => {
        const element = montar();
        getHistorial.emit({ truncated: false, signals: [] });
        await flush();

        const tabla = element.shadowRoot.querySelector('tbody');
        expect(tabla).toBeNull();
        const vacio = element.shadowRoot.querySelector('.nota');
        expect(vacio.textContent).toContain('todavía no tiene señales');
    });

    it('muestra el estado de error de BR-207 ante un fallo del controlador', async () => {
        const element = montar();
        getHistorial.error({ message: 'Sin acceso al historial' });
        await flush();

        const alerta = element.shadowRoot.querySelector('[role="alert"]');
        expect(alerta).not.toBeNull();
        expect(alerta.textContent).toContain('Sin acceso al historial');
    });
});
