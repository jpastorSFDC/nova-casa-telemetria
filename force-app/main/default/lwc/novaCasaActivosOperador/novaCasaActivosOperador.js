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

// Severity filter labels follow the prototype (Crítico / Precaución / Estable). Values are the controller's levels.
const SEVERITY_OPTIONS = [
    { label: 'Todas', value: '' },
    { label: 'Crítico', value: '2' },
    { label: 'Precaución', value: '1' },
    { label: 'Estable', value: '0' }
];

// Severity treatment per level. The glyph (filled circle / triangle / empty circle) and the text always accompany
// the color, so color is never the only cue. A missing level is never mapped to Estable.
const SEVERITY_UI = {
    2: { key: 'critico', label: 'Crítico', glyph: '\u25CF' },
    1: { key: 'advertencia', label: 'Precaución', glyph: '\u25B2' },
    0: { key: 'normal', label: 'Estable', glyph: '\u25CB' }
};
const SEVERITY_NO_LEVEL_UI = { key: 'nivel', label: 'Sin dato', glyph: '?' };
const SEVERITY_NO_READING_UI = { key: 'nivel', label: 'Sin lecturas', glyph: '?' };

// Labels of measurement.type (Lectura_Vigente__c.Tipo_Medicion__c). Unknown values fall back to the raw value.
const MEASUREMENT_LABELS = {
    TEMPERATURE: 'Temperatura',
    WATER_PRESSURE: 'Presión de agua',
    WATER_CONSUMPTION: 'Consumo de agua',
    ENERGY_CONSUMPTION: 'Consumo de energía',
    CAMERA_CONNECTIVITY: 'Conectividad de cámara'
};
// Active measurement types: the detail table lists the ones an asset has no reading for as "Sin lecturas".
const MEASUREMENT_TYPES = Object.keys(MEASUREMENT_LABELS);

// Asset.Tipo_Activo__c values that have their own icon; any other type gets the neutral icon.
const ICON_PUMP = 'WATER_PUMP';
const ICON_VENTILATION = 'VENTILATION';

const NUMBER_FORMAT = new Intl.NumberFormat('es', { maximumFractionDigits: 3 });

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

function formatUtcTime(value) {
    const ms = toMillis(value);
    return ms === null ? '' : `${new Date(ms).toISOString().slice(11, 19)} UTC`;
}

function formatValue(value, unit) {
    const number = value === null || value === undefined ? '—' : NUMBER_FORMAT.format(value);
    return unit ? `${number} ${unit}` : number;
}

function severityUi(level, hasReadings) {
    if (!hasReadings) {
        return SEVERITY_NO_READING_UI;
    }
    if (level === null || level === undefined) {
        return SEVERITY_NO_LEVEL_UI;
    }
    return SEVERITY_UI[level] || SEVERITY_NO_LEVEL_UI;
}

function rankOf(reading) {
    return reading.severityLevel === null || reading.severityLevel === undefined ? -1 : reading.severityLevel;
}

function plural(count, one, many) {
    return `${count} ${count === 1 ? one : many}`;
}

export default class NovaCasaActivosOperador extends NavigationMixin(LightningElement) {
    /** Minutes without a signal before the asset is flagged as stale. */
    @api staleMinutes = DEFAULT_STALE_MINUTES;

    buildingId = '';
    severity = '';
    assetType = '';

    // Detail view is client-side state: the selected asset comes from the already-loaded getAssets payload.
    selectedAssetId = null;

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
    _focusTarget; // 'detail' or an asset Id whose "Ver activo" button should regain focus

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

    renderedCallback() {
        if (!this._focusTarget) {
            return;
        }
        const target = this._focusTarget;
        let element = null;
        if (target === 'detail') {
            element = this.template.querySelector('[data-focus="detail"]');
        } else if (RECORD_ID_PATTERN.test(target)) {
            element = this.template.querySelector(`button[data-id="${target}"]`);
        }
        if (element) {
            element.focus();
            this._focusTarget = undefined;
        }
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
            // The selected asset left the payload (filters or data changed): fall back to the list.
            if (this.selectedAssetId && !page.assets.some((a) => a.assetId === this.selectedAssetId)) {
                this.selectedAssetId = null;
            }
        } else if (error) {
            this.assets = undefined;
            this.truncated = false;
            this.assetsError = error;
            this.assetsLoaded = true;
            this.selectedAssetId = null;
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

    // ---- filters (native selects styled as pills; `selected` is precomputed, templates cannot compare) ----

    markSelected(options, current) {
        return options.map((o) => ({ label: o.label, value: o.value, selected: o.value === current }));
    }
    get buildingOptions() {
        return this.markSelected([{ label: 'Todos', value: '' }, ...this.buildings], this.buildingId);
    }
    get buildingsDisabled() {
        return !this.buildingsLoaded || this.buildings.length === 0;
    }
    get severityOptions() {
        return this.markSelected(SEVERITY_OPTIONS, this.severity);
    }
    get typeOptions() {
        return this.markSelected([{ label: 'Todos', value: '' }, ...this.typeOptionsRaw], this.assetType);
    }
    get hasTypeOptions() {
        return this.typeOptionsRaw.length > 0;
    }
    get filtersActive() {
        return Boolean(this.buildingId || this.severity !== '' || this.assetType);
    }

    handleFilterChange(event) {
        const { name, value } = event.target;
        if (name !== 'buildingId' && name !== 'severity' && name !== 'assetType') {
            return;
        }
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
    get showDetail() {
        return !this.isBusy && !this.assetsError && Boolean(this.selectedRow);
    }
    get showList() {
        return !this.isBusy && !this.assetsError && this.hasAssets && !this.showDetail;
    }
    get showFilters() {
        return !this.showDetail;
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
    get countText() {
        if (this.isBusy) {
            return 'Cargando activos…';
        }
        if (this.assetsError) {
            return 'No disponible';
        }
        const list = this.assets || [];
        const buildingKeys = new Set(list.map((a) => a.accountId || a.accountName).filter(Boolean));
        return `${plural(list.length, 'activo', 'activos')} · ${plural(buildingKeys.size, 'edificio', 'edificios')}`;
    }

    // ---- banner (counts cover the rows returned for the current filtered view, and say so) ----

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
        return `${this.criticalCount} crítico(s)`;
    }
    get warningChip() {
        return `${this.warningCount} precaución`;
    }
    get normalChip() {
        return `${this.normalCount} estable(s)`;
    }
    get noReadingChip() {
        return `${this.noReadingCount} sin dato`;
    }
    get bannerClass() {
        if (this.criticalCount > 0) {
            return 'situacion situacion-critico';
        }
        return this.warningCount > 0 ? 'situacion situacion-advertencia' : 'situacion situacion-normal';
    }
    get leadStrong() {
        const crit = this.criticalCount;
        if (crit > 0) {
            return crit === 1 ? '1 crítico' : `${crit} críticos`;
        }
        return 'Ningún crítico';
    }
    get leadRest() {
        const crit = this.criticalCount;
        if (crit > 0) {
            return `de ${plural(this.assets.length, 'activo', 'activos')} en esta vista ${crit === 1 ? 'necesita' : 'necesitan'} atención ahora`;
        }
        if (this.warningCount > 0) {
            return `en esta vista; ${this.warningCount} en precaución`;
        }
        return 'en esta vista';
    }

    // ---- view models ----

    get staleMs() {
        return (Number(this.staleMinutes) > 0 ? Number(this.staleMinutes) : DEFAULT_STALE_MINUTES) * 60000;
    }

    buildReading(a, r) {
        const ui = severityUi(r.severityLevel, true);
        return {
            key: `${a.assetId}-${r.measurementType}`,
            measurementType: r.measurementType,
            measurementLabel: MEASUREMENT_LABELS[r.measurementType] || r.measurementType,
            valueText: formatValue(r.value, r.unit),
            ageText: relativeTime(r.occurredAt, this.nowMs),
            timeText: formatUtcTime(r.occurredAt),
            occurredMs: toMillis(r.occurredAt),
            rank: rankOf(r),
            sevClass: `sev sev-${ui.key}`,
            sevGlyph: ui.glyph,
            sevLabel: ui.label,
            hasReading: true
        };
    }

    buildRow(a) {
        const readings = (a.readings || []).map((r) => this.buildReading(a, r));
        const hasReadings = readings.length > 0;
        const level = a.severityLevel;
        const ui = severityUi(level, hasReadings);

        // Headline reading on the card: the one that sets the severity (highest level, then the newest).
        let headline = null;
        let latest = null;
        readings.forEach((r) => {
            if (!headline || r.rank > headline.rank || (r.rank === headline.rank && (r.occurredMs || 0) > (headline.occurredMs || 0))) {
                headline = r;
            }
            if (!latest || (r.occurredMs || 0) > (latest.occurredMs || 0)) {
                latest = r;
            }
        });

        // Table: readings most severe first, then the measurement types this asset has no reading for.
        const sorted = [...readings].sort((x, y) => y.rank - x.rank || x.measurementLabel.localeCompare(y.measurementLabel));
        const present = new Set(readings.map((r) => r.measurementType));
        const missing = MEASUREMENT_TYPES.filter((t) => !present.has(t)).map((t) => ({
            key: `${a.assetId}-${t}-none`,
            measurementLabel: MEASUREMENT_LABELS[t],
            hasReading: false
        }));

        const lastMs = toMillis(a.lastSignalAt);
        let signalText;
        let signalClass = 'senal';
        if (!hasReadings || lastMs === null) {
            signalText = 'Sin señal recibida todavía';
        } else if (this.nowMs - lastMs > this.staleMs) {
            signalText = `Última señal ${relativeTime(a.lastSignalAt, this.nowMs)} (desactualizada)`;
            signalClass = 'senal senal-vieja';
        } else {
            signalText = `Última señal ${relativeTime(a.lastSignalAt, this.nowMs)}`;
        }

        const typeLabel = this.typeLabels[a.assetType] || a.assetType || '';
        const metaParts = [typeLabel, a.externalId].filter(Boolean);
        const count = a.openInterventionCount || 0;
        const inv = a.openIntervention;
        const unreadable = !hasReadings;
        return {
            key: a.assetId,
            assetId: a.assetId,
            name: a.name,
            buildingName: a.accountName || '',
            hasBuilding: Boolean(a.accountName),
            externalId: a.externalId || '',
            hasExternalId: Boolean(a.externalId),
            typeLabel,
            hasTypeLabel: Boolean(typeLabel),
            metaText: metaParts.join(' · '),
            isPump: a.assetType === ICON_PUMP,
            isVentilation: a.assetType === ICON_VENTILATION,
            isOtherType: a.assetType !== ICON_PUMP && a.assetType !== ICON_VENTILATION,
            cardClass: `tarjeta-activo ${ui.key}`,
            heroClass: `hero-activo ${ui.key}`,
            viewButtonClass: level === 2 ? 'boton urgente' : 'boton secundario',
            sevClass: `sev sev-${ui.key}`,
            sevGlyph: ui.glyph,
            sevLabel: ui.label,
            sevValueClass: `val val-${ui.key}`,
            viewLabel: `Ver activo ${a.name || ''}`.trim(),
            signalText,
            signalClass,
            hasReadings,
            hasHeadline: Boolean(headline),
            headValue: headline ? headline.valueText : '',
            headMeasure: headline ? `${headline.measurementLabel} · ${headline.ageText}` : '',
            noReadingsText: unreadable ? 'Sin lecturas todavía' : '',
            hasMoreReadings: readings.length > 1,
            moreReadingsText: `+${readings.length - 1} medición(es) más en el detalle`,
            lastValue: latest ? latest.valueText : '',
            lastSub: latest ? `${latest.measurementLabel} · ${latest.ageText} · ${latest.timeText}` : 'Sin lecturas todavía',
            hasLast: Boolean(latest),
            tableRows: [...sorted, ...missing],
            hasIntervention: Boolean(inv),
            caseId: inv ? inv.caseId : null,
            caseNumber: inv ? inv.caseNumber : '',
            caseStatus: inv ? inv.status : '',
            caseSubject: inv && inv.subject ? inv.subject : '',
            hasCaseSubject: Boolean(inv && inv.subject),
            caseAgeText: inv ? `Abierta ${relativeTime(inv.createdDate, this.nowMs)}` : '',
            hasMoreInterventions: count > 1,
            moreInterventionsText: `y ${count - 1} intervención(es) abierta(s) más`,
            noInterventionText: this.noInterventionText(level, hasReadings)
        };
    }

    // Wording of the "Ninguna abierta" card. Never claims a case exists or will be created.
    noInterventionText(level, hasReadings) {
        if (!hasReadings || level == null) {
            return 'Sin severidad conocida: no hay lecturas con nivel para evaluar este activo.';
        }
        if (level === 2) {
            return 'El activo está en estado crítico y no hay una intervención abierta visible para ti. Revisa el estado del procesamiento o consulta con tu administrador.';
        }
        if (level === 1) {
            return 'No es crítica: el sistema no la abre de forma automática.';
        }
        return 'El equipo está en rango.';
    }

    get rows() {
        return (this.assets || []).map((a) => this.buildRow(a));
    }

    get selectedRow() {
        if (!this.selectedAssetId || !this.assets) {
            return null;
        }
        const asset = this.assets.find((a) => a.assetId === this.selectedAssetId);
        return asset ? this.buildRow(asset) : null;
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

    // ---- in-component detail ----

    handleViewAsset(event) {
        const assetId = event.currentTarget.dataset.id;
        if (!assetId || !RECORD_ID_PATTERN.test(assetId)) {
            return;
        }
        this.selectedAssetId = assetId;
        this._focusTarget = 'detail';
    }

    handleBackToList() {
        this._focusTarget = this.selectedAssetId || undefined;
        this.selectedAssetId = null;
    }
}
