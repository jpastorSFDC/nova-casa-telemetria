import { LightningElement, api, wire } from 'lwc';
import getHistorial from '@salesforce/apex/ActivosOperadorController.getHistorial';
import { SIGNAL_TYPE_LABELS, MEASUREMENT_LABELS, UNIT_LABELS, reduceError } from 'c/novaCasaEtiquetas';

const HISTORY_LIMIT = 20;
const EVIDENCE_RESULTS = ['Atrasada', 'Superada', 'Conflicto'];
const ALL = 'Todas';
const RESULT_HELP = {
    Conflicto:
        'Conflicto: llegó un mensaje con la misma identidad que otro ya recibido, pero con contenido distinto. Se guarda como evidencia; no cambia el estado del activo ni abre una intervención.',
    Duplicada:
        'Duplicada: llegó el mismo mensaje otra vez. No cambia el estado del activo ni abre una intervención.'
};

function formatUtcDateTime(value) {
    const ms = value ? new Date(value).getTime() : NaN;
    return Number.isNaN(ms) ? '—' : `${new Date(ms).toISOString().slice(0, 16).replace('T', ' ')} UTC`;
}

const NUMBER_FORMAT = new Intl.NumberFormat('es', { maximumFractionDigits: 4 });

function formatValue(value, unit) {
    if (value === null || value === undefined || Number.isNaN(Number(value))) {
        return '—';
    }
    const number = NUMBER_FORMAT.format(Number(value));
    return unit ? `${number} ${UNIT_LABELS[unit] || unit}` : number;
}

// Same rendering and wording as the "Historial de señales" card of novaCasaActivosOperador (D024).
export default class NovaCasaHistorialSenales extends LightningElement {
    @api assetId;

    historyData;
    historyError;
    historyLoaded = false;
    selectedResult = ALL;

    get historyLimit() {
        return HISTORY_LIMIT;
    }

    @wire(getHistorial, { assetId: '$assetId', limite: '$historyLimit' })
    wiredHistory({ data, error }) {
        if (data) {
            this.historyData = data;
            this.historyError = undefined;
            this.historyLoaded = true;
        } else if (error) {
            this.historyData = undefined;
            this.historyError = error;
            this.historyLoaded = true;
        } else {
            this.historyData = undefined;
            this.historyError = undefined;
            this.historyLoaded = false;
        }
    }

    get historyLoading() {
        return !this.historyLoaded && !this.historyError;
    }
    get showHistoryError() {
        return Boolean(this.historyError);
    }
    get historyErrorMessage() {
        return reduceError(this.historyError);
    }
    get historyRows() {
        const signals = this.historyData?.signals || [];
        return signals.map((s, i) => ({
            key: `${i}-${s.occurredAt}`,
            typeLabel: SIGNAL_TYPE_LABELS[s.messageType] || s.messageType || '—',
            measurementLabel: s.measurementType ? MEASUREMENT_LABELS[s.measurementType] || s.measurementType : '—',
            valueText: formatValue(s.value, s.unit),
            occurredText: formatUtcDateTime(s.occurredAt),
            resultado: s.resultado || '—',
            // Evidence only: these never change the asset's current state. Tagged with text, not color alone.
            isEvidence: EVIDENCE_RESULTS.includes(s.resultado),
            rowClass: EVIDENCE_RESULTS.includes(s.resultado) ? 'fila-evidencia' : ''
        }));
    }
    // Counts per result over the loaded rows, so a run of identical results cannot hide the rest.
    get resultChips() {
        const counts = new Map();
        this.historyRows.forEach((r) => counts.set(r.resultado, (counts.get(r.resultado) || 0) + 1));
        const chips = [{ value: ALL, count: this.historyRows.length }];
        [...counts.entries()].sort((a, b) => b[1] - a[1]).forEach(([value, count]) => chips.push({ value, count }));
        return chips.map((c) => {
            const pressed = c.value === this.activeResult;
            return {
                ...c,
                key: c.value,
                label: `${c.value} ${c.count}`,
                pressed: String(pressed),
                chipClass: pressed ? 'chip chip-activo' : 'chip'
            };
        });
    }
    // A filter whose result is no longer in the loaded rows falls back to "Todas" instead of an empty table.
    get activeResult() {
        return this.selectedResult === ALL || this.historyRows.some((r) => r.resultado === this.selectedResult)
            ? this.selectedResult
            : ALL;
    }
    get visibleRows() {
        return this.activeResult === ALL
            ? this.historyRows
            : this.historyRows.filter((r) => r.resultado === this.activeResult);
    }
    get helpTexts() {
        const present = new Set(this.historyRows.map((r) => r.resultado));
        return Object.keys(RESULT_HELP)
            .filter((k) => present.has(k))
            .map((k) => ({ key: k, text: RESULT_HELP[k] }));
    }
    get hasHelp() {
        return this.helpTexts.length > 0;
    }
    get summaryScopeText() {
        return `Resumen de las ${this.historyRows.length} señales más recientes. Toca un resultado para filtrar la tabla.`;
    }
    handleChip(event) {
        this.selectedResult = event.currentTarget.dataset.value;
    }
    get showHistoryTable() {
        return !this.historyError && this.historyRows.length > 0;
    }
    get showHistoryEmpty() {
        return this.historyLoaded && !this.historyError && this.historyRows.length === 0;
    }
    get showHistoryTruncated() {
        return this.showHistoryTable && Boolean(this.historyData?.truncated);
    }
    get historyTruncatedText() {
        return `Mostrando las ${this.historyRows.length} señales más recientes.`;
    }
}
