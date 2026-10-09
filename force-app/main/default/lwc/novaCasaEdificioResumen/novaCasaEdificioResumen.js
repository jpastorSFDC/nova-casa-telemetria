import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getResumenEdificio from '@salesforce/apex/ActivosOperadorController.getResumenEdificio';
import { reduceError } from 'c/novaCasaEtiquetas';

const GENERIC_ERROR = 'No se pudo cargar la información. Intenta de nuevo o contacta a tu administrador.';

// Read-only summary of a building (Account record page). Counts come from the server with the user's own access.
export default class NovaCasaEdificioResumen extends LightningElement {
    @api recordId;

    resumen;
    errorMessage;
    loaded = false;
    wiredResult;

    @wire(getResumenEdificio, { accountId: '$recordId' })
    wiredResumen(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.resumen = data;
            this.errorMessage = undefined;
            this.loaded = true;
        } else if (error) {
            this.resumen = undefined;
            this.errorMessage = reduceError(error) || GENERIC_ERROR;
            this.loaded = true;
        }
    }

    handleRefresh() {
        this.loaded = false;
        refreshApex(this.wiredResult);
    }

    get isLoading() {
        return !this.loaded;
    }
    get showError() {
        return this.loaded && !!this.errorMessage;
    }
    get hasData() {
        return this.loaded && !!this.resumen;
    }
    get isEmpty() {
        return this.hasData && this.resumen.totalActivos === 0;
    }
    get showSummary() {
        return this.hasData && this.resumen.totalActivos > 0;
    }
    get isTruncated() {
        return !!this.resumen && this.resumen.truncated === true;
    }
    get hasLastSignal() {
        return !!this.resumen && !!this.resumen.ultimaSenal;
    }
    get lastSignalValue() {
        return this.resumen ? this.resumen.ultimaSenal : null;
    }
    get hasOpenCases() {
        return !!this.resumen && this.resumen.casosAbiertos > 0;
    }
    get openCasesText() {
        const n = this.resumen ? this.resumen.casosAbiertos : 0;
        if (n === 0) {
            return 'Ninguna abierta';
        }
        return n === 1 ? '1 intervención abierta' : n + ' intervenciones abiertas';
    }
    get totalText() {
        const n = this.resumen ? this.resumen.totalActivos : 0;
        return n === 1 ? '1 activo' : n + ' activos';
    }
    // Glyph + text always accompany the color (never color alone).
    get items() {
        const r = this.resumen;
        if (!r) {
            return [];
        }
        return [
            { key: 'critico', label: 'Crítico', glyph: '●', count: r.activosCriticos, cls: 'sev sev-critico' },
            { key: 'advertencia', label: 'Precaución', glyph: '▲', count: r.activosEnAlerta, cls: 'sev sev-advertencia' },
            { key: 'normal', label: 'Estable', glyph: '○', count: r.activosNormales, cls: 'sev sev-normal' },
            { key: 'sinlectura', label: 'Sin lecturas', glyph: '?', count: r.activosSinLectura, cls: 'sev sev-nivel' },
            { key: 'sinnivel', label: 'Señal sin nivel', glyph: '◇', count: r.activosSinNivel, cls: 'sev sev-nivel' }
        ];
    }
}
