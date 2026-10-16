import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getResumenEdificio from '@salesforce/apex/ActivosOperadorController.getResumenEdificio';
import { reduceError, relativeAge } from 'c/novaCasaEtiquetas';

const GENERIC_ERROR = 'No se pudo cargar la información. Intenta de nuevo o contacta a tu administrador.';
const TICK_MS = 60000;

function activos(n) {
    return n === 1 ? '1 activo' : `${n} activos`;
}

// Read-only summary of a building (Account record page). Counts come from the server with the user's own access.
export default class NovaCasaEdificioResumen extends LightningElement {
    @api recordId;

    resumen;
    errorMessage;
    loaded = false;
    wiredResult;
    nowMs = Date.now();
    _timer;

    connectedCallback() {
        // Re-render the relative age of the last signal without hitting the server.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setInterval(() => {
            this.nowMs = Date.now();
        }, TICK_MS);
    }

    disconnectedCallback() {
        clearInterval(this._timer);
    }

    @wire(getResumenEdificio, { accountId: '$recordId' })
    wiredResumen(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.resumen = data;
            this.errorMessage = undefined;
            this.loaded = true;
            this.nowMs = Date.now();
        } else if (error) {
            this.resumen = undefined;
            this.errorMessage = reduceError(error) || GENERIC_ERROR;
            this.loaded = true;
        }
    }

    handleRefresh() {
        this.loaded = false;
        this.nowMs = Date.now();
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

    // ---- situation banner (tone = worst state present) ----

    get tono() {
        const r = this.resumen;
        if (!r) {
            return 'neutro';
        }
        if (r.activosCriticos > 0) {
            return 'critico';
        }
        // A cut summary never gets the stable look: there may be critical assets it did not count.
        if (this.isTruncated || r.activosEnAlerta > 0) {
            return 'advertencia';
        }
        return r.activosNormales > 0 ? 'normal' : 'neutro';
    }
    get bannerClass() {
        return `situacion situacion-${this.tono}`;
    }
    get leadGlyph() {
        return { critico: '●', advertencia: '▲', normal: '○' }[this.tono] || '';
    }
    // When cut, every count in the lead reads "al menos" and it never claims "none critical".
    get leadStrong() {
        const r = this.resumen;
        if (!r) {
            return '';
        }
        const pre = this.isTruncated ? 'al menos ' : '';
        switch (this.tono) {
            case 'critico':
                return `${pre}${activos(r.activosCriticos)} en estado crítico`;
            case 'advertencia':
                return r.activosEnAlerta > 0 ? `${pre}${activos(r.activosEnAlerta)} en precaución` : 'Ningún crítico verificado';
            case 'normal':
                return `${r.activosNormales} de ${r.totalActivos} ${r.totalActivos === 1 ? 'activo estable' : 'activos estables'}`;
            default:
                return 'Ningún activo con lectura todavía';
        }
    }
    // Carries its own leading separator (" de …" or "; …"); the template adds none.
    get leadRest() {
        const r = this.resumen;
        if (!r || (this.tono !== 'critico' && this.tono !== 'advertencia')) {
            return '';
        }
        if (this.tono === 'advertencia' && !(r.activosEnAlerta > 0)) {
            return '; puede haber críticos sin mostrar';
        }
        return ` de ${this.isTruncated ? 'al menos ' : ''}${r.totalActivos}`;
    }

    get hasOpenCases() {
        return !!this.resumen && this.resumen.casosAbiertos > 0;
    }
    get openCasesText() {
        const n = this.resumen ? this.resumen.casosAbiertos : 0;
        if (n === 0) {
            return 'Ninguna intervención abierta';
        }
        return n === 1 ? '1 intervención abierta' : n + ' intervenciones abiertas';
    }

    get hasLastSignal() {
        return !!this.resumen && !!this.resumen.ultimaSenal;
    }
    get lastSignalValue() {
        return this.resumen ? this.resumen.ultimaSenal : null;
    }
    get lastSignalAge() {
        return relativeAge(this.hasLastSignal ? new Date(this.resumen.ultimaSenal).getTime() : NaN, this.nowMs);
    }
    get lastSignalText() {
        const age = this.lastSignalAge;
        return age.isKnown ? `Última señal ${age.text}` : 'Última señal';
    }
    get lastSignalStale() {
        return this.lastSignalAge.isStale;
    }

    // ---- distribution bar (decorative; the same figures are in text) ----

    get segmentos() {
        const r = this.resumen;
        if (!r || !(r.totalActivos > 0)) {
            return [];
        }
        return [
            { key: 'critico', count: r.activosCriticos },
            { key: 'advertencia', count: r.activosEnAlerta },
            { key: 'normal', count: r.activosNormales },
            { key: 'nivel', count: (r.activosSinLectura || 0) + (r.activosSinNivel || 0) }
        ]
            .filter((s) => s.count > 0)
            .map((s) => ({
                key: s.key,
                cls: `seg seg-${s.key}`,
                style: `width: ${((s.count * 100) / r.totalActivos).toFixed(2)}%`
            }));
    }

    // Glyph + text always accompany the color (never color alone).
    get items() {
        const r = this.resumen;
        if (!r) {
            return [];
        }
        return [
            { key: 'critico', label: 'Crítico', glyph: '●', count: r.activosCriticos },
            { key: 'advertencia', label: 'Precaución', glyph: '▲', count: r.activosEnAlerta },
            { key: 'normal', label: 'Estable', glyph: '○', count: r.activosNormales }
        ].map((it) => ({
            ...it,
            cardCls: it.count > 0 ? `tarjeta ${it.key}` : 'tarjeta cero',
            cls: `sev sev-${it.key}`
        }));
    }

    get sinLectura() {
        return this.resumen ? this.resumen.activosSinLectura : 0;
    }
    get sinNivel() {
        return this.resumen ? this.resumen.activosSinNivel : 0;
    }
}
