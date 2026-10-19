import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LAST_MODIFIED_FIELD from '@salesforce/schema/Case.LastModifiedDate';
import getIntervencion from '@salesforce/apex/ActivosOperadorController.getIntervencion';
import getSenalesDeIntervencion from '@salesforce/apex/ActivosOperadorController.getSenalesDeIntervencion';
import actualizarSeguimiento from '@salesforce/apex/IntervencionOperadorController.actualizarSeguimiento';
import { MEASUREMENT_LABELS, UNIT_LABELS, severityUi, reduceError, relativeAge } from 'c/novaCasaEtiquetas';

const SIGNAL_LIMIT = 20;
const TICK_MS = 60000;
// Case.Status API values. The path shows these first, in this order, then any other active value, then Closed last.
// The values themselves come from the server (getEstadosSeguimiento, D036).
const PATH_FIRST = ['New', 'En curso', 'On Hold', 'Escalated'];
const STATUS_IN_PROGRESS = 'En curso';
const STATUS_CLOSED = 'Closed';
const PRIORITY_CRITICAL = 'Critica';
// Case.Priority API values; unknown values fall back to the raw value.
const PRIORITY_LABELS = { Critica: 'Crítica', High: 'Alta', Medium: 'Media', Low: 'Baja' };
// Same limit as COMMENT_MAX in IntervencionOperadorController.
const COMMENT_MAX = 4000;
const RECORD_ID_PATTERN = /^[a-zA-Z0-9]{15,18}$/;
const FOLLOW_UP_DATE = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}:\d{2})$/;

const NUMBER_FORMAT = new Intl.NumberFormat('es', { maximumFractionDigits: 4 });
// Case dates (opened, closed) in the browser's time zone, like the operator screen; origin times stay in UTC.
const DAY_MONTH_FORMAT = new Intl.DateTimeFormat('es', { day: '2-digit', month: '2-digit' });
const TIME_FORMAT = new Intl.DateTimeFormat('es', { hour: '2-digit', minute: '2-digit' });

function toMillis(value) {
    if (!value) {
        return null;
    }
    const ms = new Date(value).getTime();
    return Number.isNaN(ms) ? null : ms;
}

// dd/mm hh:mm in the browser's time zone.
function formatLocal(value) {
    const ms = toMillis(value);
    return ms === null ? '' : `${DAY_MONTH_FORMAT.format(ms)} ${TIME_FORMAT.format(ms)}`;
}

// Origin time as the asset panel shows it: only the UTC time when it falls on the browser's current day.
function formatOrigin(value, nowMs) {
    const ms = toMillis(value);
    if (ms === null) {
        return '—';
    }
    const iso = new Date(ms).toISOString();
    const time = `${iso.slice(11, 16)} UTC`;
    return new Date(ms).toDateString() === new Date(nowMs).toDateString() ? time : `${iso.slice(8, 10)}/${iso.slice(5, 7)} ${time}`;
}

// "3 h 20 min", "2 d 4 h"; never negative.
function durationText(fromMs, toMs) {
    const minutes = Math.max(0, Math.floor((toMs - fromMs) / 60000));
    if (minutes < 1) {
        return 'menos de 1 min';
    }
    if (minutes < 60) {
        return `${minutes} min`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 24) {
        const rest = minutes % 60;
        return rest ? `${hours} h ${rest} min` : `${hours} h`;
    }
    const days = Math.floor(hours / 24);
    const restHours = hours % 24;
    return restHours ? `${days} d ${restHours} h` : `${days} d`;
}

function formatValue(value, unit) {
    if (value === null || value === undefined || Number.isNaN(Number(value))) {
        return '—';
    }
    const number = NUMBER_FORMAT.format(Number(value));
    return unit ? `${number} ${UNIT_LABELS[unit] || unit}` : number;
}

function measurementLabel(code) {
    return code ? MEASUREMENT_LABELS[code] || code : '—';
}

// Subject written by the ingestion ("Señal crítica: WATER_PRESSURE en …") with each measurement code made readable.
function readableSubject(subject) {
    if (!subject) {
        return 'Sin asunto';
    }
    return Object.keys(MEASUREMENT_LABELS).reduce((text, code) => text.split(code).join(MEASUREMENT_LABELS[code]), subject);
}

// "2026-10-19 10:02" (as the server wrote it, in the writer's time zone) -> "19/10 10:02". No time-zone conversion.
function formatFollowUpDate(fecha) {
    const match = fecha ? FOLLOW_UP_DATE.exec(fecha) : null;
    return match ? `${match[3]}/${match[2]} ${match[4]}` : fecha || '';
}

function plural(count, one, many) {
    return `${count} ${count === 1 ? one : many}`;
}

// Intervention (Case) record page: what is happening, what to do next and the signals behind it (HP-07).
// Everything comes from the server with the user's own access; actions are re-checked there (BR-208).
export default class NovaCasaIntervencion extends NavigationMixin(LightningElement) {
    @api recordId;

    detalle;
    errorMessage;
    loaded = false;
    wiredDetalle;

    senales;
    senalesError;
    senalesLoaded = false;
    wiredSenales;

    nowMs = Date.now();
    formMode = null; // 'seguir' or 'cerrar'
    nuevoEstado = '';
    comentario = '';
    isSaving = false;
    actionError = '';
    liveMessage = '';

    _timer;
    _focusTarget; // CSS selector of the element to focus after the next render
    _returnFocus; // data-return value of the control that opened the form
    _lastModified;

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
        const element = this.template.querySelector(this._focusTarget);
        if (element) {
            element.focus();
        }
        this._focusTarget = undefined;
    }

    get signalLimit() {
        return SIGNAL_LIMIT;
    }

    @wire(getIntervencion, { caseId: '$recordId' })
    wiredIntervencion(result) {
        this.wiredDetalle = result;
        const { data, error } = result;
        if (data) {
            this.detalle = data;
            this.errorMessage = undefined;
            this.loaded = true;
            this.nowMs = Date.now();
        } else if (error) {
            this.detalle = undefined;
            this.errorMessage = reduceError(error);
            this.loaded = true;
        }
    }

    @wire(getSenalesDeIntervencion, { caseId: '$recordId', limite: '$signalLimit' })
    wiredSenalesDeIntervencion(result) {
        this.wiredSenales = result;
        const { data, error } = result;
        if (data) {
            this.senales = data;
            this.senalesError = undefined;
            this.senalesLoaded = true;
        } else if (error) {
            this.senales = undefined;
            this.senalesError = error;
            this.senalesLoaded = true;
        }
    }

    // A change saved from the standard tabs below (e.g. Status edited in Details) refreshes this component too.
    @wire(getRecord, { recordId: '$recordId', optionalFields: [LAST_MODIFIED_FIELD] })
    wiredCaseRecord({ data }) {
        const stamp = data ? getFieldValue(data, LAST_MODIFIED_FIELD) : null;
        if (!stamp) {
            return;
        }
        const changed = this._lastModified && stamp !== this._lastModified;
        this._lastModified = stamp;
        if (changed && !this.isSaving) {
            this.refreshData();
        }
    }

    refreshData() {
        const results = [this.wiredDetalle, this.wiredSenales].filter(Boolean);
        return Promise.resolve()
            .then(() => Promise.all(results.map((r) => refreshApex(r))))
            .catch(() => undefined);
    }

    handleRetry() {
        this.loaded = false;
        // An unchanged result does not call the wire handler again, so the loading state is ended here too.
        this.refreshData().then(() => {
            this.loaded = true;
        });
    }

    // ---- states ----

    get isLoading() {
        return !this.loaded;
    }
    get showError() {
        return this.loaded && Boolean(this.errorMessage);
    }
    get hasData() {
        return this.loaded && Boolean(this.detalle);
    }
    get isClosed() {
        return Boolean(this.detalle && this.detalle.isClosed);
    }
    get isOpen() {
        return Boolean(this.detalle) && !this.detalle.isClosed;
    }
    get isTelemetry() {
        return Boolean(this.detalle && this.detalle.esTelemetria);
    }
    get isManual() {
        return Boolean(this.detalle) && !this.detalle.esTelemetria;
    }
    get hasAsset() {
        return Boolean(this.detalle && this.detalle.assetId);
    }
    get assetLevel() {
        const level = this.detalle ? this.detalle.assetLevel : null;
        return level === undefined ? null : level;
    }

    // ---- band: the asset's current state, also on a closed intervention ----

    get currentReading() {
        return this.detalle && this.detalle.lecturaActual ? this.detalle.lecturaActual : null;
    }
    // Without a reading the band is the gray "Sin dato" one, whatever the level says.
    get bandUi() {
        return severityUi(this.currentReading ? this.assetLevel : null);
    }
    get bandClass() {
        return `banda banda-${this.bandUi.key}`;
    }
    get bandGlyph() {
        return this.bandUi.glyph;
    }
    get bandLabel() {
        return this.bandUi.label;
    }
    get bandReading() {
        const r = this.currentReading;
        if (!r) {
            return this.hasAsset ? '· Sin lecturas todavía' : '· Intervención sin activo';
        }
        const value = r.value === null || r.value === undefined ? '' : ` ${formatValue(r.value, r.unit)}`;
        return `· ${measurementLabel(r.measurementType)}${value}`;
    }
    // Same age rules as novaCasaActivoEstado: "hora del simulador" for a future origin time, stale past 60 min.
    get bandAge() {
        const ms = this.currentReading ? toMillis(this.currentReading.occurredAt) : null;
        return relativeAge(ms === null ? NaN : ms, this.nowMs);
    }
    get hasBandAge() {
        return this.bandAge.isKnown;
    }
    get bandAgeText() {
        return this.bandAge.text;
    }
    get bandStale() {
        return this.bandAge.isStale;
    }
    // With a cut, a reading left out could be more severe: below critical the level is qualified (D042, point 7).
    get showBandIncomplete() {
        return this.hasAsset && Boolean(this.detalle.lecturasIncompletas) && this.assetLevel !== 2;
    }

    // ---- header ----

    get eyebrow() {
        if (this.isClosed) {
            const when = formatLocal(this.detalle.closedDate);
            return when ? `Intervención cerrada el ${when}` : 'Intervención cerrada';
        }
        return this.isTelemetry ? 'Intervención · abierta por la telemetría' : 'Intervención manual';
    }
    get caseTitle() {
        return this.detalle ? `Caso ${this.detalle.caseNumber}` : '';
    }
    get subjectText() {
        return readableSubject(this.detalle ? this.detalle.subject : null);
    }
    get assetName() {
        return (this.detalle && this.detalle.assetName) || 'Activo';
    }
    get hasExternalId() {
        return Boolean(this.detalle && this.detalle.assetExternalId);
    }
    get hasBuilding() {
        return Boolean(this.detalle && this.detalle.accountId);
    }
    get buildingName() {
        return (this.detalle && this.detalle.accountName) || 'Edificio';
    }
    get statusLabel() {
        const d = this.detalle;
        if (!d) {
            return '';
        }
        const option = (d.estados || []).find((o) => o.value === d.status);
        return option ? option.label : d.status || '—';
    }
    get statusClass() {
        return this.isClosed ? 'estado estado-cerrada' : 'estado';
    }

    // ---- path ----

    // Picklist options in path order: PATH_FIRST, then any other active value, then Closed.
    get orderedEstados() {
        const estados = (this.detalle && this.detalle.estados) || [];
        const first = PATH_FIRST.map((v) => estados.find((o) => o.value === v)).filter(Boolean);
        const others = estados.filter((o) => !PATH_FIRST.includes(o.value) && o.value !== STATUS_CLOSED);
        const closed = estados.filter((o) => o.value === STATUS_CLOSED);
        return [...first, ...others, ...closed];
    }
    get hasPath() {
        return this.orderedEstados.length > 0;
    }
    get pathSteps() {
        const steps = this.orderedEstados;
        const status = this.detalle ? this.detalle.status : null;
        const currentIndex = steps.findIndex((o) => o.value === status);
        const last = steps.length - 1;
        return steps.map((o, i) => {
            const isCurrent = i === currentIndex;
            const isDone = currentIndex >= 0 && i < currentIndex;
            let name;
            if (o.value === STATUS_CLOSED) {
                name = `${o.label}: cerrar la intervención`;
            } else if (isCurrent) {
                name = `${o.label} (estado actual): actualizar seguimiento`;
            } else {
                name = `Pasar a ${o.label}`;
            }
            let cls = 'paso';
            if (i === 0) {
                cls += ' paso-primero';
            }
            if (i === last) {
                cls += ' paso-ultimo';
            }
            if (isDone) {
                cls += ' hecho';
            }
            if (isCurrent) {
                cls += ' actual';
            }
            let srState = '';
            if (isCurrent) {
                srState = ' (estado actual)';
            } else if (isDone) {
                srState = ' (paso anterior)';
            }
            return {
                key: o.value,
                value: o.value,
                label: o.label,
                isDone,
                ariaCurrent: isCurrent ? 'step' : null,
                cls,
                name,
                srState,
                returnKey: `paso-${i}`
            };
        });
    }
    handleStep(event) {
        const value = event.currentTarget.dataset.value;
        const returnKey = event.currentTarget.dataset.return;
        if (value === STATUS_CLOSED) {
            this.openClose(returnKey);
        } else {
            this.openFollowUp(value, returnKey);
        }
    }

    // ---- strip ----

    get openTileLabel() {
        return this.isClosed ? 'Estuvo abierta' : 'Abierta';
    }
    get openTileValue() {
        const d = this.detalle;
        const created = d ? toMillis(d.createdDate) : null;
        if (created === null) {
            return '—';
        }
        if (d.isClosed) {
            const closed = toMillis(d.closedDate);
            return closed === null ? '—' : durationText(created, closed);
        }
        return `hace ${durationText(created, this.nowMs)}`;
    }
    get openTileSub() {
        const d = this.detalle;
        if (!d) {
            return '';
        }
        const from = formatLocal(d.createdDate);
        if (d.isClosed) {
            const to = formatLocal(d.closedDate);
            return from && to ? `del ${from} al ${to}` : '';
        }
        return from ? `desde el ${from}` : '';
    }

    // Neutral text: red is only for a current critical (D041, point 1), and priority is not the asset's state.
    get priorityText() {
        const d = this.detalle;
        if (!d || !d.priority) {
            return '—';
        }
        return PRIORITY_LABELS[d.priority] || d.priority;
    }
    get prioritySub() {
        return this.detalle && this.detalle.priority === PRIORITY_CRITICAL && this.isTelemetry ? 'la abrió una señal crítica' : '';
    }

    // Last critical recorded on the Case (D039): history, never shown as the current reading.
    get lastCritical() {
        return this.detalle && this.detalle.ultimaCritica ? this.detalle.ultimaCritica : null;
    }
    get hasLastCritical() {
        return Boolean(this.lastCritical);
    }
    get lastCriticalValue() {
        return this.lastCritical ? formatValue(this.lastCritical.value, this.lastCritical.unit) : '—';
    }
    get lastCriticalSub() {
        const c = this.lastCritical;
        if (!c) {
            return '';
        }
        const ms = toMillis(c.occurredAt);
        const parts = [measurementLabel(c.measurementType)];
        if (ms !== null) {
            const age = relativeAge(ms, this.nowMs);
            parts.push(formatOrigin(c.occurredAt, this.nowMs));
            parts.push(age.text);
        }
        return parts.join(' · ');
    }

    get linkedCount() {
        return this.detalle && typeof this.detalle.senalesEnlazadas === 'number' ? this.detalle.senalesEnlazadas : 0;
    }
    get signalsTileSub() {
        if (this.linkedCount === 0) {
            if (!this.isTelemetry) {
                return 'intervención manual';
            }
            return this.isClosed ? 'ninguna' : 'ninguna todavía';
        }
        const first = this.signalRows.length ? this.signalRows[0] : null;
        if (!first || !first.ageKnown) {
            return '';
        }
        return first.isFuture ? 'la última con hora del simulador' : `la última ${first.ageText}`;
    }

    get followUp() {
        return this.detalle ? this.detalle.ultimoSeguimiento : null;
    }
    get followTileValue() {
        return this.followUp ? formatFollowUpDate(this.followUp.fecha) : '—';
    }
    get followTileSub() {
        return this.followUp ? this.followUp.autor : '';
    }

    // ---- what to do now ----

    get canFollow() {
        return this.isOpen && this.detalle.puedeSeguir === true;
    }
    get followUpOptions() {
        return this.orderedEstados
            .filter((o) => o.value !== STATUS_CLOSED)
            .map((o) => {
                const checked = o.value === this.nuevoEstado;
                return {
                    key: o.value,
                    value: o.value,
                    label: o.label,
                    checked,
                    cls: checked ? 'seg seg-sel' : 'seg'
                };
            });
    }
    get hasFollowUpOptions() {
        return this.followUpOptions.length > 0;
    }
    get canClose() {
        return this.canFollow && this.orderedEstados.some((o) => o.value === STATUS_CLOSED);
    }
    get actionsNote() {
        if (this.canFollow) {
            return 'Coordinación';
        }
        return this.isOpen ? 'Solo lectura' : '';
    }
    get hasActionsNote() {
        return Boolean(this.actionsNote);
    }
    get isFollowing() {
        return this.canFollow && this.formMode === 'seguir';
    }
    get isClosing() {
        return this.canClose && this.formMode === 'cerrar';
    }
    get showFollowUpEmpty() {
        return this.isFollowing && !this.hasFollowUpOptions;
    }
    get followButtonExpanded() {
        return String(this.isFollowing);
    }
    get closeButtonExpanded() {
        return String(this.isClosing);
    }
    get saveFollowDisabled() {
        return this.isSaving || !this.nuevoEstado || this.comentario.length > COMMENT_MAX;
    }
    get saveCloseDisabled() {
        return this.isSaving || this.comentario.length > COMMENT_MAX;
    }
    get commentMax() {
        return COMMENT_MAX;
    }
    get closeTitle() {
        return this.detalle ? `¿Cerrar el Caso ${this.detalle.caseNumber}?` : '';
    }
    // Close confirmation. Never promises that an intervention will open (D038, point 3).
    get closeWarnsTelemetryCritical() {
        return this.isTelemetry && this.assetLevel === 2;
    }
    get closeWarnsManualCritical() {
        return this.isManual && this.assetLevel === 2;
    }
    get showActionError() {
        return Boolean(this.actionError);
    }
    // Only on the open telemetry Case that new criticals of the asset are linked to (D039).
    get showReceivesCriticalsNote() {
        return this.isOpen && this.detalle.recibeCriticas === true;
    }
    get closedAssetStillCritical() {
        return this.isClosed && this.hasAsset && this.assetLevel === 2;
    }
    get showStableNote() {
        return this.isOpen && this.hasAsset && this.assetLevel === 0;
    }
    get showReadOnlyNote() {
        return this.isOpen && this.hasAsset && !this.canFollow;
    }
    get showNoAssetNote() {
        return this.isOpen && !this.hasAsset;
    }
    get hasClosingQuote() {
        return this.isClosed && Boolean(this.followUp && this.followUp.texto);
    }
    get closingQuote() {
        return this.hasClosingQuote ? `«${this.followUp.texto}»` : '';
    }
    get closingMeta() {
        if (!this.hasClosingQuote) {
            return '';
        }
        return [this.followUp.autor, formatFollowUpDate(this.followUp.fecha)].filter(Boolean).join(' · ');
    }
    get closedDurationText() {
        const d = this.detalle;
        const created = d ? toMillis(d.createdDate) : null;
        const closed = d ? toMillis(d.closedDate) : null;
        return created === null || closed === null ? '' : `Estuvo abierta ${durationText(created, closed)}.`;
    }

    // Default of the follow-up form: the step clicked, else the current status if it is open, else "En curso", else the first.
    defaultFollowUpState(preferred) {
        const values = this.followUpOptions.map((o) => o.value);
        if (preferred && values.includes(preferred)) {
            return preferred;
        }
        const current = this.detalle ? this.detalle.status : null;
        if (current && values.includes(current)) {
            return current;
        }
        if (values.includes(STATUS_IN_PROGRESS)) {
            return STATUS_IN_PROGRESS;
        }
        return values.length ? values[0] : '';
    }

    // The textarea is not bound to `comentario`: each form starts empty when it mounts. Re-opening the form that is
    // already open keeps what was typed and only changes the selected status.
    // _focusTarget is only set when the form mounts (a render is certain); an already-open form is focused directly.
    openFollowUp(preferred, returnKey) {
        if (this.formMode === 'seguir') {
            if (preferred) {
                this.nuevoEstado = this.defaultFollowUpState(preferred);
            }
            const radios = [...this.template.querySelectorAll('input[name="nuevoEstado"]')];
            const selected = radios.find((r) => r.value === this.nuevoEstado);
            if (selected) {
                selected.focus();
            }
            return;
        }
        this.formMode = 'seguir';
        this.nuevoEstado = this.defaultFollowUpState(preferred);
        this.comentario = '';
        this.actionError = '';
        this._returnFocus = returnKey || 'seguir';
        this._focusTarget = this.nuevoEstado ? 'input[name="nuevoEstado"]:checked' : '[data-focus="seguir"]';
    }
    openClose(returnKey) {
        if (this.formMode === 'cerrar') {
            const heading = this.template.querySelector('[data-focus="cerrar"]');
            if (heading) {
                heading.focus();
            }
            return;
        }
        this.formMode = 'cerrar';
        this.comentario = '';
        this.actionError = '';
        this._returnFocus = returnKey || 'cerrar';
        this._focusTarget = '[data-focus="cerrar"]';
    }
    handleOpenFollowUp(event) {
        this.openFollowUp(null, event.currentTarget.dataset.return);
    }
    handleOpenClose(event) {
        this.openClose(event.currentTarget.dataset.return);
    }
    handleCancel() {
        this.formMode = null;
        this.comentario = '';
        this.actionError = '';
        this._focusTarget = this._returnFocus ? `[data-return="${this._returnFocus}"]` : '[data-focus="acciones"]';
    }
    handleEstado(event) {
        this.nuevoEstado = event.target.value;
    }
    handleComentario(event) {
        this.comentario = event.target.value;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    handleSaveFollowUp() {
        if (!this.saveFollowDisabled) {
            this.save(this.nuevoEstado, 'Seguimiento actualizado');
        }
    }
    handleSaveClose() {
        if (!this.saveCloseDisabled) {
            this.save(STATUS_CLOSED, 'Intervención cerrada');
        }
    }

    async save(estado, successTitle) {
        const caseNumber = this.detalle ? this.detalle.caseNumber : '';
        this.isSaving = true;
        this.actionError = '';
        this.liveMessage = '';
        try {
            await actualizarSeguimiento({ caseId: this.recordId, estado, comentario: this.comentario });
            this.formMode = null;
            this.comentario = '';
            this.toast(successTitle, `Caso ${caseNumber}`, 'success');
            this.liveMessage = `${successTitle}: Caso ${caseNumber}.`;
            this._focusTarget = '[data-focus="acciones"]';
        } catch (e) {
            this.actionError = reduceError(e);
        }
        // Also after an error: the intervention may have changed under us (someone else closed it).
        await this.refreshData();
        // The standard tabs below re-read the Case; if this fails they show the change on the next load.
        await Promise.resolve(notifyRecordUpdateAvailable([{ recordId: this.recordId }])).catch(() => undefined);
        this.isSaving = false;
    }

    // ---- signals ----

    get signalRows() {
        const list = (this.senales && this.senales.signals) || [];
        return list.map((s, i) => {
            const ms = toMillis(s.occurredAt);
            const age = relativeAge(ms === null ? NaN : ms, this.nowMs);
            const resends = typeof s.resends === 'number' ? s.resends : 0;
            const result = s.result || '—';
            return {
                key: `${i}-${s.occurredAt}`,
                timeText: formatOrigin(s.occurredAt, this.nowMs),
                isFuture: age.isFuture,
                ageKnown: age.isKnown,
                ageText: age.text,
                measurementLabel: measurementLabel(s.measurementType),
                valueText: formatValue(s.value, s.unit),
                valueClass: i === 0 ? 'num fuerte' : 'num',
                resultText: resends > 0 ? `${result} · ${plural(resends, 'reenvío', 'reenvíos')}` : result,
                isLatest: i === 0,
                abrio: s.abrio === true,
                rowClass: i === 0 ? 'fila-ultima' : ''
            };
        });
    }
    get signalsCountText() {
        return `${plural(this.linkedCount, 'señal', 'señales')} · de la más nueva a la más antigua`;
    }
    get signalsLoading() {
        return this.isTelemetry && !this.senalesLoaded;
    }
    get showSignalsError() {
        return this.isTelemetry && Boolean(this.senalesError);
    }
    get signalsErrorMessage() {
        return reduceError(this.senalesError);
    }
    get showSignalsTable() {
        return this.isTelemetry && !this.senalesError && this.signalRows.length > 0;
    }
    get showSignalsEmpty() {
        return this.isTelemetry && this.senalesLoaded && !this.senalesError && this.signalRows.length === 0;
    }
    get signalsEmptyText() {
        return this.isClosed
            ? 'Esta intervención no tiene señales enlazadas.'
            : 'Esta intervención todavía no tiene señales enlazadas.';
    }
    get showSignalsTruncated() {
        return this.showSignalsTable && Boolean(this.senales && this.senales.truncated);
    }
    get signalsTruncatedText() {
        return `Se muestran las ${this.signalRows.length} más recientes de ${this.linkedCount}.`;
    }
    get hasMotivo() {
        return this.isManual && Boolean(this.detalle.motivo);
    }
    get motivo() {
        return this.hasMotivo ? this.detalle.motivo : '';
    }

    // ---- navigation (record access is enforced by the platform) ----

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
    handleOpenBuilding(event) {
        this.navigateToRecord(event, 'Account');
    }
}
