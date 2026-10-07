import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getEstadoActivo from '@salesforce/apex/ActivosOperadorController.getEstadoActivo';
import { MEASUREMENT_LABELS, severityUi, reduceError, relativeAge } from 'c/novaCasaEtiquetas';

const NUMBER_FORMAT = new Intl.NumberFormat('es', { maximumFractionDigits: 3 });

function formatValue(value, unit) {
    const number = value === null || value === undefined ? '—' : NUMBER_FORMAT.format(value);
    return unit ? `${number} ${unit}` : number;
}

// Read-only state of an asset (Asset record page). Everything comes from the server with the user's own access.
export default class NovaCasaActivoEstado extends NavigationMixin(LightningElement) {
    @api recordId;

    estado;
    errorMessage;
    loaded = false;
    wiredResult;

    @wire(getEstadoActivo, { assetId: '$recordId' })
    wiredEstado(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.estado = data;
            this.errorMessage = undefined;
            this.loaded = true;
        } else if (error) {
            this.estado = undefined;
            this.errorMessage = reduceError(error);
            this.loaded = true;
        }
    }

    handleRefresh() {
        this.loaded = false;
        refreshApex(this.wiredResult);
    }

    handleCaseClick(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.intervention.caseId, objectApiName: 'Case', actionName: 'view' }
        });
    }

    handleMoreClick() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordRelationshipPage',
            attributes: {
                recordId: this.recordId,
                objectApiName: 'Asset',
                relationshipApiName: 'Cases',
                actionName: 'view'
            }
        });
    }

    get isLoading() {
        return !this.loaded;
    }
    get showError() {
        return this.loaded && Boolean(this.errorMessage);
    }
    get hasData() {
        return this.loaded && Boolean(this.estado);
    }
    get isTruncated() {
        return Boolean(this.estado) && this.estado.truncated === true;
    }
    get truncatedText() {
        return `Hay más lecturas de las que caben en el panel; puede haber lecturas que no se muestran.`;
    }
    get readings() {
        const list = this.estado ? this.estado.readings || [] : [];
        const nowMs = Date.now();
        return list.map((r) => {
            const ui = severityUi(r.severityLevel);
            const age = relativeAge(r.occurredAt ? new Date(r.occurredAt).getTime() : NaN, nowMs);
            return {
                key: r.measurementType,
                label: MEASUREMENT_LABELS[r.measurementType] || r.measurementType,
                valueText: formatValue(r.value, r.unit),
                occurredAt: r.occurredAt,
                ageKnown: age.isKnown,
                ageText: age.text,
                isStale: age.isStale,
                sevClass: `sev sev-${ui.key}`,
                sevGlyph: ui.glyph,
                sevLabel: ui.label
            };
        });
    }
    get hasReadings() {
        return this.readings.length > 0;
    }
    get intervention() {
        return this.estado ? this.estado.openIntervention : null;
    }
    get hasIntervention() {
        return Boolean(this.intervention);
    }
    get caseTitle() {
        return this.intervention ? `Caso ${this.intervention.caseNumber}` : '';
    }
    get caseSubject() {
        return this.intervention && this.intervention.subject ? this.intervention.subject : 'Sin asunto';
    }
    get hasMoreInterventions() {
        return Boolean(this.estado) && this.estado.openInterventionCount > 1;
    }
    get moreInterventionsText() {
        const n = this.estado ? this.estado.openInterventionCount - 1 : 0;
        return `y ${n} intervención(es) abierta(s) más`;
    }
}
