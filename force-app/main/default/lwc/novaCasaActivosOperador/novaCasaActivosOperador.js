import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import ASSET_OBJECT from '@salesforce/schema/Asset';
import TIPO_ACTIVO from '@salesforce/schema/Asset.Tipo_Activo__c';
import getAssets from '@salesforce/apex/ActivosOperadorController.getAssets';
import getBuildings from '@salesforce/apex/ActivosOperadorController.getBuildings';

const TICK_MS = 30000;
// Single source of the stale default (display-only). Keep in sync with the
// staleMinutes default in novaCasaActivosOperador.js-meta.xml.
const DEFAULT_STALE_MINUTES = 15;
const GENERIC_ERROR = 'No se pudo cargar la información. Intenta de nuevo o contacta a tu administrador.';
const RECORD_ID_PATTERN = /^[a-zA-Z0-9]{15,18}$/;

const SEVERITY_OPTIONS = [
    { label: 'Todas', value: '' },
    { label: 'Crítica', value: '2' },
    { label: 'Advertencia', value: '1' },
    { label: 'Normal', value: '0' }
];

// Visual treatment per severity level. Icon + text always accompany the color.
const SEVERITY_UI = {
    2: { badge: 'slds-theme_error', icon: 'utility:error', card: 'nc-card_critical', chip: 'nc-chip_critical' },
    1: { badge: 'slds-theme_warning', icon: 'utility:warning', card: 'nc-card_warning', chip: 'nc-chip_warning' },
    0: { badge: 'slds-theme_success', icon: 'utility:success', card: 'nc-card_normal', chip: 'nc-chip_normal' }
};
const SEVERITY_NONE_UI = { badge: '', icon: 'utility:question', card: '', chip: 'nc-chip_none' };

// Only the controller's AuraHandledException message (body.message) is shown; anything else is generic.
function reduceError(error) {
    if (!error) {
        return '';
    }
    const body = error.body;
    if (body && !Array.isArray(body) && typeof body.message === 'string' && body.message) {
        return body.message;
    }
    return GENERIC_ERROR;
}

// Response shape of getAssets, isolated here: AssetPage { assets, truncated, assetLimit }.
// If the final contract differs, change only this function.
function parseAssetsResponse(data) {
    return {
        assets: data.assets || [],
        truncated: Boolean(data.truncated),
        assetLimit: data.assetLimit,
        totalCount: data.totalCount
    };
}

// Response shape of getBuildings: BuildingListResult { options, truncated }.
function parseBuildingsResponse(data) {
    return { options: data.options || [], truncated: Boolean(data.truncated) };
}

function toMillis(value) {
    if (!value) {
        return null;
    }
    const ms = new Date(value).getTime();
    return Number.isNaN(ms) ? null : ms;
}

function relativeTime(value, nowMs) {
    const ms = toMillis(value);
    if (ms === null) {
        return '';
    }
    const minutes = Math.floor((nowMs - ms) / 60000);
    if (minutes < 1) {
        return 'hace menos de 1 min';
    }
    if (minutes < 60) {
        return `hace ${minutes} min`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 24) {
        return `hace ${hours} h`;
    }
    return `hace ${Math.floor(hours / 24)} d`;
}

export default class NovaCasaActivosOperador extends NavigationMixin(LightningElement) {
    /** Minutes without a signal before the asset is flagged as stale. */
    @api staleMinutes = DEFAULT_STALE_MINUTES;

    buildingId = '';
    severity = '';
    assetType = '';

    assets;
    truncated = false;
    assetLimit;
    totalCount;
    assetsError;
    assetsLoaded = false;
    isRefreshing = true;
    updatedAtMs;
    nowMs = Date.now();

    buildings = [];
    buildingsError = '';
    buildingsTruncated = false;
    buildingsLoaded = false;

    typeLabels = {};
    typeOptionsRaw = [];

    _assetsResult;
    _timer;

    connectedCallback() {
        // Re-render relative times without hitting the server.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setInterval(() => {
            this.nowMs = Date.now();
        }, TICK_MS);
    }

    disconnectedCallback() {
        clearInterval(this._timer);
    }

    // ---- data ----

    @wire(getAssets, {
        accountId: '$accountIdParam',
        severityLevel: '$severityParam',
        assetType: '$assetTypeParam'
    })
    wiredAssets(result) {
        this._assetsResult = result;
        const { data, error } = result;
        if (data) {
            const page = parseAssetsResponse(data);
            this.assets = page.assets;
            this.truncated = page.truncated;
            this.assetLimit = page.assetLimit;
            this.totalCount = page.totalCount;
            this.assetsError = undefined;
            this.assetsLoaded = true;
            this.updatedAtMs = Date.now();
            this.nowMs = this.updatedAtMs;
        } else if (error) {
            this.assets = undefined;
            this.truncated = false;
            this.assetsError = error;
            this.assetsLoaded = true;
        }
        if (data || error) {
            this.isRefreshing = false;
        }
    }

    @wire(getBuildings)
    wiredBuildings({ data, error }) {
        if (data) {
            const result = parseBuildingsResponse(data);
            this.buildings = result.options;
            this.buildingsTruncated = result.truncated;
            this.buildingsError = '';
            this.buildingsLoaded = true;
        } else if (error) {
            this.buildings = [];
            this.buildingsTruncated = false;
            this.buildingsError = reduceError(error);
            this.buildingsLoaded = true;
        }
    }

    @wire(getObjectInfo, { objectApiName: ASSET_OBJECT })
    assetInfo;

    @wire(getPicklistValues, {
        recordTypeId: '$defaultRecordTypeId',
        fieldApiName: TIPO_ACTIVO
    })
    wiredTypes({ data }) {
        // If the user cannot read the field the picklist never arrives and the filter stays hidden.
        if (data) {
            this.typeOptionsRaw = data.values;
            const labels = {};
            data.values.forEach((v) => {
                labels[v.value] = v.label;
            });
            this.typeLabels = labels;
        }
    }

    get defaultRecordTypeId() {
        return this.assetInfo?.data?.defaultRecordTypeId;
    }

    // Wire params: null means "no filter" for the controller.
    get accountIdParam() {
        return this.buildingId || null;
    }
    get severityParam() {
        return this.severity === '' ? null : Number(this.severity);
    }
    get assetTypeParam() {
        return this.assetType || null;
    }

    // ---- filters ----

    get buildingOptions() {
        return [{ label: 'Todos', value: '' }, ...this.buildings];
    }
    get buildingsDisabled() {
        return !this.buildingsLoaded || this.buildings.length === 0;
    }
    get severityOptions() {
        return SEVERITY_OPTIONS;
    }
    get typeOptions() {
        return [{ label: 'Todos', value: '' }, ...this.typeOptionsRaw];
    }
    get hasTypeOptions() {
        return this.typeOptionsRaw.length > 0;
    }
    get filtersActive() {
        return Boolean(this.buildingId || this.severity !== '' || this.assetType);
    }

    handleFilterChange(event) {
        const { name } = event.target;
        const value = event.detail.value;
        if (this[name] === value) {
            return;
        }
        this[name] = value;
        this.isRefreshing = true;
    }

    handleClearFilters() {
        this.buildingId = '';
        this.severity = '';
        this.assetType = '';
        this.isRefreshing = true;
    }

    async handleRefresh() {
        this.isRefreshing = true;
        try {
            await refreshApex(this._assetsResult);
        } catch (e) {
            // The wire re-emits the error; nothing else to do here.
        }
        this.isRefreshing = false;
    }

    // ---- state ----

    get isBusy() {
        return this.isRefreshing || !this.assetsLoaded;
    }
    get showError() {
        return !this.isBusy && Boolean(this.assetsError);
    }
    get errorMessage() {
        return reduceError(this.assetsError);
    }
    get hasAssets() {
        return Boolean(this.assets && this.assets.length);
    }
    get showEmptyNoData() {
        return !this.isBusy && !this.assetsError && this.assets && !this.hasAssets && !this.filtersActive;
    }
    get showEmptyNoMatch() {
        return !this.isBusy && !this.assetsError && this.assets && !this.hasAssets && this.filtersActive;
    }
    get showList() {
        return !this.isBusy && !this.assetsError && this.hasAssets;
    }
    get showTruncated() {
        return this.showList && this.truncated;
    }
    get truncatedText() {
        const shown = this.assets ? this.assets.length : 0;
        if (this.totalCount != null && this.totalCount > shown) {
            return `Mostrando ${shown} de ${this.totalCount} activos; afina los filtros para ver el resto.`;
        }
        // No page cut (scan ceiling or row cap): do not claim any total.
        return 'Puede haber activos o lecturas que no se muestran; afina los filtros.';
    }
    get showSummary() {
        return this.showList;
    }
    get updatedText() {
        return this.updatedAtMs ? relativeTime(this.updatedAtMs, this.nowMs) : '';
    }

    // ---- summary (over the rows returned for the current filters) ----

    countWhere(predicate) {
        return (this.assets || []).filter(predicate).length;
    }
    get criticalCount() {
        return this.countWhere((a) => a.severityLevel === 2);
    }
    get warningCount() {
        return this.countWhere((a) => a.severityLevel === 1);
    }
    get normalCount() {
        return this.countWhere((a) => a.severityLevel === 0);
    }
    get noReadingCount() {
        return this.countWhere((a) => a.severityLevel == null);
    }
    get criticalChip() {
        return `${this.criticalCount} crítico(s) en esta vista`;
    }
    get warningChip() {
        return `${this.warningCount} advertencia(s) en esta vista`;
    }
    get normalChip() {
        return `${this.normalCount} normal(es) en esta vista`;
    }
    get noReadingChip() {
        return `${this.noReadingCount} sin dato en esta vista`;
    }
    get summaryLead() {
        const total = this.assets ? this.assets.length : 0;
        const crit = this.criticalCount;
        if (crit > 0) {
            return `${crit} de ${total} activos de esta vista en estado crítico necesitan atención ahora`;
        }
        if (this.warningCount > 0) {
            return `Sin activos críticos en esta vista; ${this.warningCount} en advertencia`;
        }
        return `${total} activos en esta vista, ninguno en estado crítico`;
    }

    // ---- rows ----

    get rows() {
        const staleMs = (Number(this.staleMinutes) > 0 ? Number(this.staleMinutes) : DEFAULT_STALE_MINUTES) * 60000;
        return (this.assets || []).map((a) => {
            const readings = a.readings || [];
            const hasReadings = readings.length > 0;
            const level = a.severityLevel;
            const ui = level == null ? SEVERITY_NONE_UI : SEVERITY_UI[level] || SEVERITY_NONE_UI;

            const lastMs = toMillis(a.lastSignalAt);
            let signalText;
            let signalIcon = 'utility:clock';
            let signalClass = '';
            let signalAlt = 'Última señal';
            if (!hasReadings || lastMs === null) {
                signalText = 'Sin señal recibida todavía';
                signalIcon = 'utility:dash';
                signalClass = 'slds-text-color_weak';
            } else if (this.nowMs - lastMs > staleMs) {
                signalText = `Última señal ${relativeTime(a.lastSignalAt, this.nowMs)} (desactualizada)`;
                signalIcon = 'utility:warning';
                signalClass = 'slds-text-color_error';
                signalAlt = 'Información desactualizada';
            } else {
                signalText = `Última señal ${relativeTime(a.lastSignalAt, this.nowMs)}`;
            }

            const count = a.openInterventionCount || 0;
            const inv = a.openIntervention;
            return {
                key: a.assetId,
                assetId: a.assetId,
                name: a.name,
                accountName: a.accountName || '',
                typeLabel: this.typeLabels[a.assetType] || a.assetType || '',
                cardClass: `slds-item nc-card ${ui.card}`,
                severityClass: ui.badge,
                severityIcon: ui.icon,
                severityText: hasReadings ? a.severityLabel || 'Sin dato' : 'Sin lecturas',
                signalText,
                signalIcon,
                signalClass,
                signalAlt,
                hasReadings,
                readings: readings.map((r) => {
                    const rUi = r.severityLevel == null ? SEVERITY_NONE_UI : SEVERITY_UI[r.severityLevel] || SEVERITY_NONE_UI;
                    return {
                        key: `${a.assetId}-${r.measurementType}`,
                        measurementType: r.measurementType,
                        valueText: `${r.value ?? '—'}${r.unit ? ' ' + r.unit : ''}`,
                        ageText: relativeTime(r.occurredAt, this.nowMs),
                        severityLabel: r.severityLabel,
                        chipClass: `nc-chip ${rUi.chip}`
                    };
                }),
                hasIntervention: Boolean(inv),
                caseId: inv ? inv.caseId : null,
                caseNumber: inv ? inv.caseNumber : '',
                caseStatus: inv ? inv.status : '',
                caseAgeText: inv ? `abierta ${relativeTime(inv.createdDate, this.nowMs)}` : '',
                hasMoreInterventions: count > 1,
                moreInterventionsText: `y ${count - 1} intervención(es) abierta(s) más`
            };
        });
    }

    // ---- navigation (record access is enforced by the platform and the controller) ----

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
}
