import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import ASSET_OBJECT from '@salesforce/schema/Asset';
import TIPO_ACTIVO from '@salesforce/schema/Asset.Tipo_Activo__c';
import getAssets from '@salesforce/apex/ActivosOperadorController.getAssets';
import getBuildings from '@salesforce/apex/ActivosOperadorController.getBuildings';
import getHistorial from '@salesforce/apex/ActivosOperadorController.getHistorial';
import getCapacidades from '@salesforce/apex/ActivosOperadorController.getCapacidades';
import crearIntervencion from '@salesforce/apex/IntervencionOperadorController.crearIntervencion';
import actualizarSeguimiento from '@salesforce/apex/IntervencionOperadorController.actualizarSeguimiento';
import traerSenales from '@salesforce/apex/IngestaController.traerSenales';
import estadoIngesta from '@salesforce/apex/IngestaController.estadoIngesta';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const TICK_MS = 30000;
const INGEST_POLL_MS = 5000;
// A signal dated further ahead than this is flagged: the simulator clock or the source is wrong (display only).
const FUTURE_TOLERANCE_MS = 5 * 60000;
const DEFAULT_INGEST_PAGES = 5;
// Scenarios of the simulator contract; IngestaController validates the same list on the server.
const SCENARIOS = ['MIXED', 'QA_200', 'BOUNDARIES', 'CRITICAL_BURST', 'LATE_MESSAGES', 'DUPLICATES', 'CONFLICT', 'INVALID_DATA', 'CAMERA_OUTAGE'];
// Follow-up statuses the controller accepts.
const FOLLOW_UP_OPTIONS = [
    { label: 'En curso', value: 'En curso' },
    { label: 'En espera', value: 'On Hold' },
    { label: 'Cerrada', value: 'Closed' }
];
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

// Log_Senial__c.Message_Type__c values; unknown ones fall back to the raw value.
const SIGNAL_TYPE_LABELS = {
    MEASUREMENT: 'Medición',
    CONNECTIVITY: 'Conectividad'
};
const HISTORY_LIMIT = 20;
const EVIDENCE_RESULTS = ['Atrasada', 'Superada'];

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

function formatUtcDateTime(value) {
    const ms = toMillis(value);
    return ms === null ? '—' : `${new Date(ms).toISOString().slice(0, 16).replace('T', ' ')} UTC`;
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

    // What the user may do; all false until getCapacidades answers (and if it fails). The server re-checks each action.
    caps = {};

    // Inline forms of the detail view: null, 'crear' or 'seguir'.
    formMode = null;
    motivo = '';
    nuevoEstado = 'En curso';
    comentario = '';
    isSaving = false;
    actionError = '';

    // Admin ingestion panel.
    ingestOpen = false;
    scenario = 'MIXED';
    ingestPages = String(DEFAULT_INGEST_PAGES);
    ingestRestart = false;
    ingestStarting = false;
    ingestError = '';
    ingestState = null;
    _ingestSince;
    _ingestTimer;

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
        clearInterval(this._ingestTimer);
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

    // Signal history of the open detail. Undefined (not null) while no asset is open, so the wire does not fire.
    historyData;
    historyError;
    historyLoaded = false;

    get historyAssetId() {
        return this.selectedAssetId || undefined;
    }
    get historyLimit() {
        return HISTORY_LIMIT;
    }

    @wire(getHistorial, { assetId: '$historyAssetId', limite: '$historyLimit' })
    wiredHistory({ data, error }) {
        if (data) {
            this.historyData = data;
            this.historyError = undefined;
            this.historyLoaded = true;
        } else if (error) {
            // Only the history section shows the error; the rest of the detail is unaffected.
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
            // Evidence only: these never change the asset's current state. Muted and tagged with text, not color alone.
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

    @wire(getCapacidades)
    wiredCaps({ data }) {
        this.caps = data || {};
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
    get updatedClock() {
        return this.updatedAtMs
            ? new Date(this.updatedAtMs).toLocaleTimeString('es', { hour: '2-digit', minute: '2-digit' })
            : '';
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
    get knownCount() {
        return this.countWhere((a) => a.severityLevel != null);
    }
    get criticalChip() {
        return plural(this.criticalCount, 'crítico', 'críticos');
    }
    get warningChip() {
        return `${this.warningCount} precaución`;
    }
    get normalChip() {
        return plural(this.normalCount, 'estable', 'estables');
    }
    get noReadingChip() {
        return `${this.noReadingCount} sin dato`;
    }
    get bannerClass() {
        if (this.criticalCount > 0) {
            return 'situacion situacion-critico';
        }
        // Without any asset of known severity nothing can be called stable: neutral look.
        if (this.knownCount === 0) {
            return 'situacion situacion-neutro';
        }
        // A cut result never gets the all-clear look: there may be critical assets we did not see.
        return this.warningCount > 0 || this.truncated ? 'situacion situacion-advertencia' : 'situacion situacion-normal';
    }
    // When the result is cut (page, scan ceiling or readings cap; the payload does not say which) the banner
    // never claims "none critical": it says "al menos" / that it could not verify everything.
    get leadStrong() {
        const crit = this.criticalCount;
        if (crit > 0) {
            const text = crit === 1 ? '1 crítico' : `${crit} críticos`;
            return this.truncated ? `Al menos ${text}` : text;
        }
        if (this.knownCount === 0) {
            return 'Severidad no determinada';
        }
        return this.truncated ? 'Ningún crítico verificado' : 'Ningún crítico';
    }
    get leadRest() {
        const crit = this.criticalCount;
        if (crit > 0) {
            const rest = `de ${plural(this.assets.length, 'activo', 'activos')} en esta vista ${crit === 1 ? 'necesita' : 'necesitan'} atención ahora`;
            return this.truncated ? `${rest}; no se pudo verificar todo` : rest;
        }
        if (this.knownCount === 0) {
            const none = 'ningún activo de esta vista tiene lecturas con nivel conocido; no se pudo determinar la severidad';
            return this.truncated ? `${none}; puede haber críticos sin mostrar` : none;
        }
        let base = this.warningCount > 0 ? `en esta vista; ${this.warningCount} en precaución` : 'en esta vista';
        if (this.noReadingCount > 0) {
            base += `; ${this.noReadingCount} sin dato`;
        }
        return this.truncated ? `${base}; no se pudo verificar todo, puede haber críticos sin mostrar` : base;
    }

    // ---- summary per building (same rows as the list: the current filtered view, and it says so when cut) ----

    get buildingSummary() {
        const byBuilding = new Map();
        (this.assets || []).forEach((a) => {
            const key = a.accountId || a.accountName || '—';
            if (!byBuilding.has(key)) {
                byBuilding.set(key, { key, name: a.accountName || 'Sin edificio', total: 0, critical: 0, warning: 0, noData: 0, stale: 0 });
            }
            const b = byBuilding.get(key);
            b.total += 1;
            if (a.severityLevel === 2) {
                b.critical += 1;
            } else if (a.severityLevel === 1) {
                b.warning += 1;
            } else if (a.severityLevel == null) {
                b.noData += 1;
            }
            const lastMs = toMillis(a.lastSignalAt);
            if (lastMs !== null && this.nowMs - lastMs > this.staleMs) {
                b.stale += 1;
            }
        });
        return [...byBuilding.values()]
            .sort((x, y) => y.critical - x.critical || y.warning - x.warning || x.name.localeCompare(y.name))
            .map((b) => ({
                ...b,
                totalText: plural(b.total, 'activo', 'activos'),
                rowClass: b.critical > 0 ? 'edif-fila edif-critico' : b.warning > 0 ? 'edif-fila edif-advertencia' : 'edif-fila'
            }));
    }
    get showBuildingSummary() {
        return this.showList && this.buildingSummary.length > 0;
    }
    get buildingSummaryNote() {
        return this.truncated ? 'Resumen parcial: hay activos que no se muestran.' : 'Resumen de la vista actual.';
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
        } else if (lastMs - this.nowMs > FUTURE_TOLERANCE_MS) {
            signalText = `Fecha de origen en el futuro (${formatUtcTime(a.lastSignalAt)}): revisa el reloj de la fuente`;
            signalClass = 'senal senal-vieja';
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
            sevSub: this.severitySub(level, hasReadings),
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
            noInterventionText: this.noInterventionText(level, hasReadings),
            canCreate: Boolean(this.caps.puedeCrearIntervencion) && hasReadings && !inv,
            canFollow: Boolean(this.caps.puedeSeguirIntervencion) && Boolean(inv)
        };
    }

    // Sub-line under the detail severity (wording from the prototype, without promising an intervention).
    severitySub(level, hasReadings) {
        if (!hasReadings || level == null) {
            return 'Sin nivel de severidad conocido';
        }
        if (level === 1) {
            return 'Vigilar';
        }
        if (level === 0) {
            return 'Sin acción requerida';
        }
        return 'La mayor de sus mediciones vigentes';
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
    handleOpenThresholds(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Umbral__c', actionName: 'list' },
            state: { filterName: 'Nova_Casa_Umbrales' }
        });
    }

    // ---- in-component detail ----

    openDetail(assetId) {
        if (!assetId || !RECORD_ID_PATTERN.test(assetId)) {
            return;
        }
        this.selectedAssetId = assetId;
        this.historyData = undefined;
        this.historyError = undefined;
        this.historyLoaded = false;
        this.formMode = null;
        this.actionError = '';
        this._focusTarget = 'detail';
    }

    // Click anywhere on the card (pointer users).
    handleViewAsset(event) {
        this.openDetail(event.currentTarget.dataset.id);
    }

    // The "Ver activo" button is the keyboard path; it stops the click so the card handler does not run twice.
    handleViewAssetButton(event) {
        event.stopPropagation();
        this.openDetail(event.currentTarget.dataset.id);
    }

    handleBackToList() {
        this._focusTarget = this.selectedAssetId || undefined;
        this.selectedAssetId = null;
        this.formMode = null;
    }

    // ---- interventions (actions re-checked on the server) ----

    get showActionError() {
        return Boolean(this.actionError);
    }
    get isCreating() {
        return this.formMode === 'crear';
    }
    get isFollowing() {
        return this.formMode === 'seguir';
    }
    get followUpOptions() {
        return FOLLOW_UP_OPTIONS.map((o) => ({ ...o, selected: o.value === this.nuevoEstado }));
    }
    get saveDisabled() {
        return this.isSaving || (this.isCreating && !this.motivo.trim());
    }

    openForm(event) {
        this.formMode = event.currentTarget.dataset.mode;
        this.motivo = '';
        this.comentario = '';
        this.nuevoEstado = 'En curso';
        this.actionError = '';
    }
    closeForm() {
        this.formMode = null;
        this.actionError = '';
    }
    handleMotivo(event) {
        this.motivo = event.target.value;
    }
    handleComentario(event) {
        this.comentario = event.target.value;
    }
    handleEstado(event) {
        this.nuevoEstado = event.target.value;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    async handleSaveForm() {
        if (this.saveDisabled || !this.selectedRow) {
            return;
        }
        this.isSaving = true;
        this.actionError = '';
        try {
            if (this.isCreating) {
                const result = await crearIntervencion({ assetId: this.selectedRow.assetId, motivo: this.motivo });
                this.toast('Intervención creada', `Caso ${result.caseNumber}`, 'success');
            } else {
                await actualizarSeguimiento({
                    caseId: this.selectedRow.caseId,
                    estado: this.nuevoEstado,
                    comentario: this.comentario
                });
                this.toast('Seguimiento actualizado', '', 'success');
            }
            this.formMode = null;
            await this.handleRefresh();
        } catch (e) {
            this.actionError = reduceError(e);
            // The state may have changed under us (another person opened one first): show the real state.
            await this.handleRefresh();
        }
        this.isSaving = false;
    }

    // ---- admin: pull signals from the simulator ----

    get showIngest() {
        return Boolean(this.caps.puedeTraerSenales);
    }
    get ingestToggleLabel() {
        return this.ingestOpen ? 'Ocultar traer señales' : 'Traer señales';
    }
    get scenarioOptions() {
        return SCENARIOS.map((v) => ({ label: v, value: v, selected: v === this.scenario }));
    }
    get ingestRunning() {
        return this.ingestStarting || Boolean(this.ingestState && this.ingestState.enCurso);
    }
    get hasIngestState() {
        return Boolean(this.ingestState);
    }
    get ingestSummary() {
        const st = this.ingestState;
        if (!st) {
            return '';
        }
        const parts = Object.keys(st.porResultado || {})
            .sort()
            .map((k) => `${k}: ${st.porResultado[k]}`);
        const head = st.enCurso ? 'En curso' : 'Terminada';
        return `${head} · ${plural(st.total, 'señal registrada', 'señales registradas')}${parts.length ? ' · ' + parts.join(' · ') : ''}`;
    }

    // What the last run did, so a run with no new signals is explained (duplicates, saved session, end of stream).
    get ingestDetail() {
        const d = this.ingestState && this.ingestState.detalle;
        if (!d) {
            return '';
        }
        const parts = [`Leyó ${plural(d.paginas, 'página', 'páginas')} (${plural(d.recibidos, 'mensaje', 'mensajes')})`];
        if (d.yaExistentes > 0) {
            parts.push(`${plural(d.yaExistentes, 'ya existía', 'ya existían')} y se omitieron`);
        }
        if (d.sesionReiniciada) {
            parts.push('sesión reiniciada: empezó desde el primer mensaje del simulador');
        } else if (d.sesionContinuada) {
            parts.push('continuó la sesión guardada');
        } else if (d.cacheNoDisponible) {
            parts.push('sin caché de plataforma: abrió una sesión nueva y releyó desde el inicio');
        } else {
            parts.push('abrió una sesión nueva');
        }
        if (d.flujoTerminado) {
            parts.push('el simulador no tiene más mensajes en esta sesión; usa «Reiniciar sesión» para empezar de nuevo');
        }
        if (d.interrumpidaPorEstado !== null && d.interrumpidaPorEstado !== undefined) {
            parts.push(`se interrumpió por un error del simulador (estado ${d.interrumpidaPorEstado}); la próxima corrida sigue desde ahí`);
        }
        if (d.logsFallidos > 0 || d.fallosPublicacion > 0 || d.noPublicadosPorLog > 0) {
            const failed = [];
            if (d.logsFallidos > 0) {
                failed.push(`${plural(d.logsFallidos, 'registro de log falló', 'registros de log fallaron')}`);
            }
            if (d.fallosPublicacion > 0) {
                failed.push(`${plural(d.fallosPublicacion, 'publicación falló', 'publicaciones fallaron')}`);
            }
            parts.push(`${failed.join(' y ')}; el cursor guardado no avanzó y la próxima corrida volverá a leer esos mensajes`);
        }
        return `${parts.join(' · ')}.`;
    }
    get hasIngestDetail() {
        return Boolean(this.ingestDetail);
    }

    toggleIngest() {
        this.ingestOpen = !this.ingestOpen;
    }
    handleScenario(event) {
        this.scenario = event.target.value;
    }
    handleIngestPages(event) {
        this.ingestPages = event.target.value;
    }
    handleIngestRestart(event) {
        this.ingestRestart = event.target.checked;
    }

    async handleStartIngest() {
        if (this.ingestRunning) {
            return;
        }
        this.ingestStarting = true;
        this.ingestError = '';
        try {
            const pages = Number.parseInt(this.ingestPages, 10);
            const started = await traerSenales({
                escenario: this.scenario,
                paginas: Number.isNaN(pages) ? null : pages,
                reiniciar: this.ingestRestart
            });
            // A restart is a one-off: the next press continues the session again.
            this.ingestRestart = false;
            this._ingestSince = started.iniciadaEn;
            this.ingestState = { enCurso: true, total: 0, porResultado: {} };
            this.startIngestPolling();
        } catch (e) {
            this.ingestError = reduceError(e);
        }
        this.ingestStarting = false;
    }

    startIngestPolling() {
        clearInterval(this._ingestTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._ingestTimer = setInterval(() => this.pollIngest(), INGEST_POLL_MS);
    }

    async pollIngest() {
        try {
            const state = await estadoIngesta({ desde: this._ingestSince });
            this.ingestState = state;
            if (!state.enCurso) {
                clearInterval(this._ingestTimer);
                await this.handleRefresh();
            }
        } catch (e) {
            clearInterval(this._ingestTimer);
            this.ingestError = reduceError(e);
        }
    }
}
