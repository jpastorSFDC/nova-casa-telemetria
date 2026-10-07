import { LightningElement, api, wire } from 'lwc';
import getHistorial from '@salesforce/apex/ActivosOperadorController.getHistorial';
import { SIGNAL_TYPE_LABELS, reduceError } from 'c/novaCasaEtiquetas';

const HISTORY_LIMIT = 20;
const EVIDENCE_RESULTS = ['Atrasada', 'Superada'];

function formatUtcDateTime(value) {
    const ms = value ? new Date(value).getTime() : NaN;
    return Number.isNaN(ms) ? '—' : `${new Date(ms).toISOString().slice(0, 16).replace('T', ' ')} UTC`;
}

// Same rendering and wording as the "Historial de señales" card of novaCasaActivosOperador (D024).
export default class NovaCasaHistorialSenales extends LightningElement {
    @api assetId;

    historyData;
    historyError;
    historyLoaded = false;

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
            occurredText: formatUtcDateTime(s.occurredAt),
            resultado: s.resultado || '—',
            // Evidence only: these never change the asset's current state. Tagged with text, not color alone.
            isEvidence: EVIDENCE_RESULTS.includes(s.resultado),
            rowClass: EVIDENCE_RESULTS.includes(s.resultado) ? 'fila-evidencia' : ''
        }));
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
