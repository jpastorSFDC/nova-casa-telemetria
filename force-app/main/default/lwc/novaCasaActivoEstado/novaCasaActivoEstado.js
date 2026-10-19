import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue, getFieldDisplayValue } from 'lightning/uiRecordApi';
import TIPO_ACTIVO_FIELD from '@salesforce/schema/Asset.Tipo_Activo__c';
import getEstadoActivo from '@salesforce/apex/ActivosOperadorController.getEstadoActivo';
import { MEASUREMENT_LABELS, severityUi, reduceError, relativeAge } from 'c/novaCasaEtiquetas';

const NUMBER_FORMAT = new Intl.NumberFormat('es', { maximumFractionDigits: 3 });
// Same wording as the operator screen for an asset without readings; c/novaCasaEtiquetas only has "Sin dato".
const SEVERITY_NO_READING_UI = { key: 'nivel', label: 'Sin lecturas', glyph: '?' };

function formatValue(value, unit) {
    const number = value === null || value === undefined ? '—' : NUMBER_FORMAT.format(value);
    return unit ? `${number} ${unit}` : number;
}

// Whether an origin time falls on the browser's current calendar day (then only the UTC time is shown).
function isSameLocalDay(ms, nowMs) {
    return new Date(ms).toDateString() === new Date(nowMs).toDateString();
}

// Read-only state of an asset (Asset record page). Everything comes from the server with the user's own access.
export default class NovaCasaActivoEstado extends NavigationMixin(LightningElement) {
    @api recordId;

    estado;
    errorMessage;
    loaded = false;
    wiredResult;

    // Only for the illustration and its label. Optional: without FLS on the field the card still loads, with the
    // neutral illustration and no type text.
    @wire(getRecord, { recordId: '$recordId', optionalFields: [TIPO_ACTIVO_FIELD] })
    assetRecord;

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
            const ms = r.occurredAt ? new Date(r.occurredAt).getTime() : NaN;
            const age = relativeAge(ms, nowMs);
            const today = !Number.isNaN(ms) && isSameLocalDay(ms, nowMs);
            return {
                key: r.measurementType,
                label: MEASUREMENT_LABELS[r.measurementType] || r.measurementType,
                valueText: formatValue(r.value, r.unit),
                occurredAt: r.occurredAt,
                isToday: today,
                timeText: today ? `${new Date(ms).toISOString().slice(11, 16)} UTC` : '',
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

    // ---- header: illustration, traffic light and asset severity ----

    get assetType() {
        const record = this.assetRecord && this.assetRecord.data;
        return (record && getFieldValue(record, TIPO_ACTIVO_FIELD)) || '';
    }
    get typeLabel() {
        const record = this.assetRecord && this.assetRecord.data;
        return (record && (getFieldDisplayValue(record, TIPO_ACTIVO_FIELD) || getFieldValue(record, TIPO_ACTIVO_FIELD))) || '';
    }
    get hasTypeLabel() {
        return Boolean(this.typeLabel);
    }
    // Asset severity = the highest level among its latest readings (null when none has a level).
    get assetLevel() {
        const list = this.estado ? this.estado.readings || [] : [];
        return list.reduce((max, r) => {
            const level = r.severityLevel;
            return level !== null && level !== undefined && (max === null || level > max) ? level : max;
        }, null);
    }
    get assetSeverity() {
        return this.hasReadings ? severityUi(this.assetLevel) : SEVERITY_NO_READING_UI;
    }
    get assetSevClass() {
        return `sev sev-${this.assetSeverity.key}`;
    }
    // With a cut, a reading left out could be more severe: below critical the level is qualified, never an all-clear.
    get levelMayBeIncomplete() {
        return this.isTruncated && this.assetLevel !== 2;
    }
    get incompleteText() {
        return '(lecturas incompletas)';
    }
    get incompleteSuffix() {
        return this.levelMayBeIncomplete ? this.incompleteText : '';
    }

    get intervention() {
        return this.estado ? this.estado.openIntervention : null;
    }
    get hasIntervention() {
        return Boolean(this.intervention);
    }
    // Red is reserved for critical (D041, D042): the band is neutral unless the asset is critical.
    get caseHeadClass() {
        return this.assetLevel === 2 ? 'caso-cabecera caso-critico' : 'caso-cabecera';
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
