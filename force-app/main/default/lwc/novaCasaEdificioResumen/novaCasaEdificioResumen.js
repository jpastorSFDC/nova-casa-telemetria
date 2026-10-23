import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getResumenEdificio from '@salesforce/apex/ActivosOperadorController.getResumenEdificio';
import getAssets from '@salesforce/apex/ActivosOperadorController.getAssets';
import getAperturasDeIntervencion from '@salesforce/apex/ActivosOperadorController.getAperturasDeIntervencion';
import { MEASUREMENT_LABELS, UNIT_LABELS, severityUi, reduceError, relativeAge, openingText } from 'c/novaCasaEtiquetas';

const GENERIC_ERROR = 'No se pudo cargar la información. Intenta de nuevo o contacta a tu administrador.';
const TICK_MS = 60000;
const MAX_ATTENTION_CARDS = 4;
const MAX_CASE_CARDS = 4;
// ActivosOperadorController.MAX_APERTURAS
const MAX_OPENING_LOOKUP = 50;
const RECORD_ID_PATTERN = /^[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?$/;
const NUMBER_FORMAT = new Intl.NumberFormat('es', { maximumFractionDigits: 3 });

function activos(n) {
    return n === 1 ? '1 activo' : `${n} activos`;
}

function levelOf(reading) {
    return reading.severityLevel === null || reading.severityLevel === undefined ? -1 : reading.severityLevel;
}

function timeOf(reading) {
    const ms = reading.occurredAt ? new Date(reading.occurredAt).getTime() : NaN;
    return Number.isNaN(ms) ? -Infinity : ms;
}

// The reading that sets the asset's severity; among equals, the most recent.
function worstReading(readings) {
    let worst = null;
    for (const r of readings || []) {
        if (!worst || levelOf(r) > levelOf(worst) || (levelOf(r) === levelOf(worst) && timeOf(r) > timeOf(worst))) {
            worst = r;
        }
    }
    return worst;
}

function formatValue(value, unit) {
    const number = value === null || value === undefined ? '—' : NUMBER_FORMAT.format(value);
    return unit ? `${number} ${unit}` : number;
}

// Read-only summary of a building (Account record page). Counts come from the server with the user's own access.
export default class NovaCasaEdificioResumen extends NavigationMixin(LightningElement) {
    @api recordId;

    resumen;
    errorMessage;
    loaded = false;
    wiredResult;
    assetPage;
    assetsError;
    wiredAssetsResult;
    // Case Id -> how it started (getAperturasDeIntervencion). Empty until it arrives or when it fails.
    aperturas = {};
    aperturasFailed = false;
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

    // Current readings and open case per asset, most severe first (same source as the operator console).
    @wire(getAssets, { accountId: '$recordId', severityLevel: null, assetType: null })
    wiredAssets(result) {
        this.wiredAssetsResult = result;
        const { data, error } = result;
        if (data) {
            this.assetPage = data;
            this.assetsError = undefined;
            this.loadAperturas();
        } else if (error) {
            this.assetPage = undefined;
            this.assetsError = reduceError(error) || GENERIC_ERROR;
            this.aperturas = {};
        }
    }

    // Only the Cases of the cards on screen.
    async loadAperturas() {
        const caseIds = [...this.attentionAssets.slice(0, MAX_ATTENTION_CARDS), ...this.caseAssets.slice(0, MAX_CASE_CARDS)]
            .filter((a) => a.openIntervention)
            .map((a) => a.openIntervention.caseId)
            .slice(0, MAX_OPENING_LOOKUP);
        this.aperturasFailed = false;
        if (!caseIds.length) {
            this.aperturas = {};
            return;
        }
        try {
            const list = await getAperturasDeIntervencion({ caseIds });
            const byCase = {};
            for (const apertura of list || []) {
                byCase[apertura.caseId] = apertura;
            }
            this.aperturas = byCase;
        } catch (e) {
            this.aperturas = {};
            this.aperturasFailed = true;
        }
    }

    handleRefresh() {
        this.loaded = false;
        this.nowMs = Date.now();
        refreshApex(this.wiredResult);
        if (this.wiredAssetsResult) {
            refreshApex(this.wiredAssetsResult);
        }
    }

    navigateToRecord(event, objectApiName) {
        event.preventDefault();
        const recordId = event.currentTarget.dataset.id;
        if (!recordId || !RECORD_ID_PATTERN.test(recordId)) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, objectApiName, actionName: 'view' }
        });
    }
    handleOpenAsset(event) {
        this.navigateToRecord(event, 'Asset');
    }
    handleOpenCase(event) {
        this.navigateToRecord(event, 'Case');
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

    // ---- cards: what needs attention and the last signal (current readings only, never a late one) ----

    get assetsList() {
        return this.assetPage && this.assetPage.assets ? this.assetPage.assets : [];
    }
    get showCards() {
        return this.showSummary && !!this.assetPage;
    }
    get showAssetsError() {
        return this.showSummary && !!this.assetsError;
    }
    get assetsTruncated() {
        return !!this.assetPage && this.assetPage.truncated === true;
    }

    // With the reading shown on the card, an opener that is that same reading gets one line instead of the block.
    openingFor(intervention, reading) {
        const opening = openingText(intervention ? this.aperturas[intervention.caseId] : null);
        const sameAsShown = Boolean(
            reading && opening.known && !opening.manual && opening.occurredAt &&
                new Date(opening.occurredAt).getTime() === timeOf(reading) &&
                opening.valueText === formatValue(reading.value, UNIT_LABELS[reading.unit] || reading.unit)
        );
        return {
            hasOrigen: opening.known && !sameAsShown,
            origenEsLaMostrada: sameAsShown,
            origenManual: opening.manual,
            origenMedicion: opening.measurement,
            origenValor: opening.valueText,
            origenAt: opening.occurredAt,
            hasOrigenAt: Boolean(opening.occurredAt)
        };
    }

    toCard(asset, reading, kind) {
        const ui = severityUi(reading.severityLevel);
        const intervention = asset.openIntervention;
        return {
            ...this.openingFor(intervention, reading),
            key: `${kind}-${asset.assetId}`,
            assetId: asset.assetId,
            assetName: asset.name,
            measurement: MEASUREMENT_LABELS[reading.measurementType] || reading.measurementType || '',
            valueText: formatValue(reading.value, UNIT_LABELS[reading.unit] || reading.unit),
            occurredAt: reading.occurredAt,
            simulatorTime: relativeAge(timeOf(reading), this.nowMs).isFuture,
            cardCls: `ficha ficha-${ui.key}`,
            sevCls: `sev sev-${ui.key}`,
            sevLabel: ui.label,
            sevGlyph: ui.glyph,
            hasCase: !!intervention,
            caseId: intervention ? intervention.caseId : null,
            caseLabel: intervention ? `Caso ${intervention.caseNumber}` : ''
        };
    }

    // The server already sorts most severe first, then by name.
    get attentionAssets() {
        return this.assetsList.filter((a) => a.severityLevel >= 1 && worstReading(a.readings));
    }
    get attentionCards() {
        return this.attentionAssets.slice(0, MAX_ATTENTION_CARDS).map((a) => this.toCard(a, worstReading(a.readings), 'atencion'));
    }
    get hasAttention() {
        return this.attentionCards.length > 0;
    }
    get attentionOverflowText() {
        const extra = this.attentionAssets.length - MAX_ATTENTION_CARDS;
        if (extra <= 0) {
            return '';
        }
        return extra === 1 ? 'Y 1 activo más necesita atención.' : `Y ${extra} activos más necesitan atención.`;
    }

    // Open interventions of assets that are not in "Necesita atención" (those already carry their case).
    get caseAssets() {
        return this.assetsList.filter((a) => a.openIntervention && !(a.severityLevel >= 1 && worstReading(a.readings)));
    }
    get caseCards() {
        return this.caseAssets.slice(0, MAX_CASE_CARDS).map((a) => {
            const hasReadings = (a.readings || []).length > 0;
            const ui = hasReadings ? severityUi(a.severityLevel) : { key: 'nivel', label: 'Sin lecturas', glyph: '?' };
            const intervention = a.openIntervention;
            return {
                ...this.openingFor(intervention),
                key: `caso-${a.assetId}`,
                assetId: a.assetId,
                assetName: a.name,
                cardCls: `ficha ficha-${ui.key}`,
                sevCls: `sev sev-${ui.key}`,
                sevLabel: `${ui.label} ahora`,
                sevGlyph: ui.glyph,
                statusText: intervention.status ? `Estado: ${intervention.status}` : '',
                caseId: intervention.caseId,
                caseLabel: `Caso ${intervention.caseNumber}`
            };
        });
    }
    get caseOverflowText() {
        const extra = this.caseAssets.length - MAX_CASE_CARDS;
        if (extra <= 0) {
            return '';
        }
        return extra === 1 ? 'Y 1 intervención abierta más.' : `Y ${extra} intervenciones abiertas más.`;
    }

    get lastCard() {
        let best = null;
        for (const a of this.assetsList) {
            for (const r of a.readings || []) {
                if (r.occurredAt && (!best || timeOf(r) > timeOf(best.reading))) {
                    best = { asset: a, reading: r };
                }
            }
        }
        return best ? this.toCard(best.asset, best.reading, 'ultima') : null;
    }
    get lastCardCls() {
        return this.lastCard ? this.lastCard.cardCls : 'ficha ficha-nivel';
    }
}
