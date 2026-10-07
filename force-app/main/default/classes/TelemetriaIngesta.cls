/**
 * US-201 ingestion: pages GET /telemetry through SimuladorClient and, for every page,
 *   1) inserts one Log_Senial__c row per message with Resultado__c = 'Publicada' (publishing is not processing),
 *   2) publishes one Senial_Sensor__e per message with EventBus.publish, checking each SaveResult.
 * Processing (classification, Lectura_Vigente__c, Cases) is the Senial_Sensor__e subscriber's job.
 *
 * Nothing is dropped silently (BR-202, BR-209): a message that cannot be published (no identity, source or
 * messageId longer than its field, identity longer than 60) and every non-object element of "data" get a
 * Log_Senial__c row with Resultado__c = 'Rechazada' and a Motivo__c, keyed by a hash so it stays unique and
 * dedupes on replay. A message whose log row cannot be inserted (anything other than a duplicate) is NOT
 * published, because an event without a log row would be untraceable; it is counted and reported in the
 * final WARN debug line (counts only).
 *
 * One job reads SEVERAL pages (HP-05, D024). Order inside a job is: restore the saved cursor, then ALL the callouts
 * (POST /session only when there is no cursor, then GET /telemetry once per page, each page turned into log rows
 * and events in memory right away so the raw messages are released), then ALL the DML (log insert, event publish,
 * log update, page by page), then the cache write and, if the run is not done, the enqueue of a continuation job.
 * Salesforce forbids a callout after uncommitted DML in the same transaction, so a job never callouts after DML.
 * The reading stops at maxPaginas, when the simulator says hasMore=false, on an empty page, when the job has
 * gathered maxMensajesPorTrabajo messages (keeps log rows + events under the 10,000 DML-row limit) or when heap,
 * CPU or callouts run short. A job that stopped for budget enqueues a continuation. The platform caps the queueable
 * stack depth (observed: 2 jobs in nova-cdo), so the chain is only for continuation and retries; if it is cut, the
 * saved cursor lets the next run continue.
 *
 * The session continues across runs (HP-05, D024). The cursor of the next page to read is kept OUTSIDE any record,
 * in Platform Cache (SesionSimulador), keyed by scenario+seed+batch and with a TTL. It is written after the DML of
 * the pages it follows, so a failed job re-reads its pages (idempotent by source+messageId). A run asked to restart
 * clears it. When the cache is unavailable the run opens a new session and says so (Resumen.cacheNoDisponible).
 * When the stream ends (hasMore=false) the cursor of the last page read is kept, so the next run re-polls it.
 * The cursor also travels as private state of the next job. It is never logged, returned or stored in a record.
 *
 * Resilience (T4.7). The simulator contract does not document these codes; they are the failures a long run
 * meets in practice. A 429 or 5xx on a callout is retried as a new job for the SAME page (same cursor, same
 * pagina) up to MAX_INTENTOS times: pages read before the failing one are written first, and the callouts of the
 * retry come before any DML, so a retry never repeats a write. If the session is rejected with 409/410 the saved
 * cursor is cleared, the job opens a new session once per page (retries included) and rereads; the new stream
 * restarts from the beginning, which is safe only if the simulator replays the same source+messageId (unconfirmed,
 * D023). A failure on the first page of a job still fails the job; a non-retryable failure after some pages were
 * read cannot fail the job (it would roll the DML back), so the job writes what it read, stops and reports the
 * status in Resumen.interrumpidaPorEstado. Retries wait 1 minute, then 2; Retry-After is not read. The simulator's
 * pollAfterMs is no longer honored with minute delays (D024 supersedes that part of D023). Every enqueue counts
 * against the chain depth (trabajos).
 *
 * Access: without sharing + SYSTEM_MODE makes the DML independent of operator/admin object permissions
 * (AGENTS.md, BR-208). The CALLOUT is not independent: the user who calls iniciar() (the job runs as that
 * user) needs the Nova_Casa_Simulator_Integration permission set, which grants access to the Named
 * Credential's external credential principal. Without it the first callout fails. Publishing needs Create on
 * Senial_Sensor__e for that user; see D013. Not for operator-facing LWC/@AuraEnabled code; the one exception is
 * IngestaController (admin-only manual start, D020).
 */
public without sharing class TelemetriaIngesta implements Queueable, Database.AllowsCallouts {

    public static final Integer PAGE_SIZE = 200;
    public static final Integer DEFAULT_MAX_PAGINAS = 25;
    private static final Integer HARD_MAX_PAGINAS = 100;

    // Depth we ask the platform to honor for this chain (System.AsyncOptions.MaximumQueueableStackDepth on the
    // enqueueJob of the next job), above the platform default of 5. Chosen conservatively: this is a trial/dev
    // org and its real hard ceiling is not confirmed, so we ask for comfortably more than the observed failure
    // point (job6, i.e. depth 5) without assuming the org will honor something as high as HARD_MAX_PAGINAS (100).
    // Must stay above DEFAULT_MAX_PAGINAS (25) with margin, or the backstop below would silently shrink the
    // default run length instead of only guarding against the platform ceiling.
    private static final Integer PROFUNDIDAD_COLA_SOLICITADA = 30;
    // Our own ceiling on pagina, independent of PROFUNDIDAD_COLA_SOLICITADA and of what the platform reports via
    // AsyncInfo.hasMaxStackDepth(). Margin of 3 below PROFUNDIDAD_COLA_SOLICITADA so a bug, a late platform signal,
    // or a real per-org cap lower than requested can never again surface as an uncaught Failed job instead of our
    // WARN stop (see class comment: this is exactly what happened with job6 in nova-cdo). Still above
    // DEFAULT_MAX_PAGINAS (25): a default-sized run (no explicit maxPaginas) must not be cut short by this
    // backstop. A run asking for more than this (up to HARD_MAX_PAGINAS, 100) has not been empirically validated
    // past this ceiling yet; see docs/decisiones.md D013.
    private static final Integer PROFUNDIDAD_LOCAL_MAXIMA = 27;

    // Messages (and discarded elements) one job gathers before it stops reading. Each message costs a log row and an
    // event in the DML-row budget (10,000 per transaction), so 4000 leaves room for rejections and updates; it is
    // 20 full pages. The rest of a 25-page run goes to a continuation job.
    private static final Integer MAX_MENSAJES_POR_TRABAJO = 4000;

    // Wall-clock time a job spends reading before it stops. The platform allows 120 s of cumulative callout time per
    // transaction and one request may last up to 60 s (SimuladorClient.TIMEOUT_MS), so stopping at 45 s keeps the
    // worst case (45 s + one slow page) under 120 s. Wall-clock overestimates callout time, which is the safe side.
    private static final Long MAX_MS_DE_LECTURA = 45000L;

    // Callout failures worth another job: attempts per page (the first one included) and the delay cap.
    @TestVisible
    private static final Integer MAX_INTENTOS = 3;
    private static final Integer MAX_RETRASO_MINUTOS = 10;

    // Field lengths of Log_Senial__c and Senial_Sensor__e.
    private static final Integer MAX_IDENTIDAD = 60;
    private static final Integer MAX_SOURCE = 80;
    private static final Integer MAX_MESSAGE_ID = 80;
    private static final Integer MAX_DELIVERY_ID = 40;
    private static final Integer MAX_LLAVE_EXTERNA = 50; // Asset_Id__c, Building_Id__c
    private static final Integer MAX_SENSOR_ID = 50;
    private static final Integer MAX_TIPO_ACTIVO = 40;
    private static final Integer MAX_MEDICION = 40;
    private static final Integer MAX_UNIDAD = 40;
    private static final Integer MAX_VALOR = 40;
    private static final Integer MAX_FECHA_TEXTO = 40;
    private static final Integer MAX_TIPO_MENSAJE = 20;
    private static final Integer MAX_ESTADO_COM = 20;
    private static final Integer MAX_GAP = 20;
    private static final Integer MAX_EPISODIO = 80;

    private static final String PUBLICADA = 'Publicada';
    private static final String FALLIDA = 'Fallida';
    private static final Set<String> TIPOS_LOG = new Set<String>{ 'MEASUREMENT', 'CONNECTIVITY' };

    private static final String RECHAZADA = 'Rechazada';
    private static final Integer MAX_MOTIVO = 255;

    // Test seams. In production: soloCapturar is false, the other two are null/empty.
    // Tests cannot run a real chain, so with soloCapturar the next job is kept in encolados instead of enqueued.
    @TestVisible
    private static Boolean soloCapturar = false;
    @TestVisible
    private static List<TelemetriaIngesta> encolados = new List<TelemetriaIngesta>();
    // Replaces the EventBus.publish results when its size matches the chunk.
    @TestVisible
    private static List<Database.SaveResult> resultadosForzados;
    // Replaces AsyncInfo.hasMaxStackDepth() when not null.
    @TestVisible
    private static Boolean profundidadForzada;
    // With soloCapturar: the delay (minutes) each job in encolados was enqueued with, in the same order.
    @TestVisible
    private static List<Integer> retrasosCapturados = new List<Integer>();
    // Identities whose log row is sent with an invalid Resultado__c so the insert fails (not a duplicate).
    @TestVisible
    private static Set<String> identidadesConFalloDeLog = new Set<String>();
    @TestVisible
    private static Resumen ultimoResumen;
    // Replaces MAX_MENSAJES_POR_TRABAJO when not null, so a test can force the continuation job.
    @TestVisible
    private static Integer maxMensajesForzado;
    // Replaces the elapsed milliseconds of the reading phase when not null, so a test can exhaust the time budget.
    @TestVisible
    private static Long msTranscurridosForzados;

    // Job state. cursor is sensitive: never log it.
    @TestVisible
    private String escenario;
    @TestVisible
    private String cursor;
    // Number of the next page to read (1-based). A retry keeps the number of the page that failed.
    @TestVisible
    private Integer pagina;
    // Last page number of the run.
    @TestVisible
    private Integer maxPaginas;
    @TestVisible
    private Resumen acumulado;
    // Attempts already spent on this page (0 on the first try) and jobs enqueued so far in the chain.
    @TestVisible
    private Integer intento = 0;
    @TestVisible
    private Integer trabajos;
    // Session parameters (T4.2). semilla null lets the simulator pick; tamanoLote is the page size asked for.
    // Both travel to every job of the chain and to a reopened session; with a seed a replay asks for the same
    // stream, without one a reopened session may start a different stream (see D023).
    @TestVisible
    private Integer semilla;
    @TestVisible
    private Integer tamanoLote = PAGE_SIZE;
    // True once the page being read already reopened its session, so retries of the same page do not reopen it again.
    @TestVisible
    private Boolean sesionReabierta = false;

    /** Counters only: no cursor, no token, no message content. */
    public class Resumen {
        public Integer paginas = 0;
        public Integer recibidos = 0; // elements of "data", objects or not
        public Integer logsCreados = 0; // 'Publicada' rows created
        public Integer yaExistentes = 0; // rows skipped because the identity already existed (resends, replays)
        public Integer logsFallidos = 0; // rows that failed for a reason other than duplicate, plus failed updates
        public Integer noPublicadosPorLog = 0; // events not published because their log row failed
        public Integer publicados = 0;
        public Integer fallosPublicacion = 0;
        public Integer rechazados = 0; // messages/elements rejected here with a 'Rechazada' row
        public Integer descartados = 0; // subset of rechazados: non-object elements of "data"
        public Integer reintentos = 0; // pages re-enqueued after a 429/5xx
        public Integer sesionesReabiertas = 0; // sessions reopened after a 409/410
        // Where the run started reading (D024). No cursor value ever goes here: only flags and counters.
        public Boolean sesionContinuada = false; // the first page came from the saved cursor
        public Boolean sesionReiniciada = false; // the run was asked to start from a new session
        public Boolean cacheNoDisponible = false; // the cursor could not be read or saved: a new session was used
        public Boolean flujoTerminado = false; // the simulator said hasMore=false
        public Boolean cursorSinAvanzar = false; // some message left no complete trace, so the saved cursor was kept (D024)
        public Integer interrumpidaPorEstado; // HTTP status that stopped the run after some pages were written
        public Datetime actualizadoEn; // when the summary was last written (lets the UI ignore an older run)

        /** True when a message of the run could not be logged or published: its page must be read again. */
        public Boolean conFallos() {
            return logsFallidos > 0 || noPublicadosPorLog > 0 || fallosPublicacion > 0;
        }

        public void sumar(Resumen otro) {
            recibidos += otro.recibidos;
            logsCreados += otro.logsCreados;
            yaExistentes += otro.yaExistentes;
            logsFallidos += otro.logsFallidos;
            noPublicadosPorLog += otro.noPublicadosPorLog;
            publicados += otro.publicados;
            fallosPublicacion += otro.fallosPublicacion;
            rechazados += otro.rechazados;
            descartados += otro.descartados;
        }
    }

    public TelemetriaIngesta(String escenario, Integer maxPaginas) {
        this(escenario, null, 1, maxPaginas, new Resumen());
    }

    @TestVisible
    private TelemetriaIngesta(String escenario, String cursor, Integer pagina, Integer maxPaginas, Resumen acumulado) {
        this.escenario = escenario;
        this.cursor = cursor;
        this.pagina = pagina;
        this.maxPaginas = maxPaginas;
        this.acumulado = acumulado;
        this.trabajos = pagina;
    }

    /**
     * Starts an ingestion run: opens a session (optionally for a scenario such as QA_200) and reads pages.
     * The caller needs the Nova_Casa_Simulator_Integration permission set (see class comment).
     * @param escenario Scenario name, or blank for the simulator default
     * @param maxPaginas Upper bound on pages for this run; null or less than 1 means 25; capped at 100
     * @return Id of the first queueable job
     * @example
     * TelemetriaIngesta.iniciar('QA_200', 5);
     */
    public static Id iniciar(String escenario, Integer maxPaginas) {
        return iniciar(escenario, null, null, maxPaginas);
    }

    /**
     * Same as iniciar(escenario, maxPaginas) with the session parameters.
     * @param semilla Seed to repeat a sequence; null lets the simulator choose
     * @param tamanoLote Records per page, 1 to 200; null means 200
     * @throws IllegalArgumentException when tamanoLote is outside 1..200
     * @example
     * TelemetriaIngesta.iniciar('QA_200', 42, 50, 5);
     */
    public static Id iniciar(String escenario, Integer semilla, Integer tamanoLote, Integer maxPaginas) {
        return iniciar(escenario, semilla, tamanoLote, maxPaginas, false);
    }

    /**
     * Same as the four-argument iniciar, choosing whether to start a new session.
     * @param reiniciar true clears the saved cursor first, so the run opens a new session and the simulator
     *        restarts from its first message; false (or null) continues from the saved cursor when there is one
     * @example
     * TelemetriaIngesta.iniciar('QA_200', null, null, 5, true);
     */
    public static Id iniciar(String escenario, Integer semilla, Integer tamanoLote, Integer maxPaginas, Boolean reiniciar) {
        TelemetriaIngesta trabajo = new TelemetriaIngesta(escenario, topeDePaginas(maxPaginas));
        trabajo.semilla = semilla;
        trabajo.tamanoLote = validarTamanoLote(tamanoLote);
        if (reiniciar == true) {
            trabajo.acumulado.sesionReiniciada = true;
        }
        // The saved cursor is cleared only once the job is really enqueued: if enqueueJob throws (limits, platform),
        // the session the operator had stays intact.
        Id idTrabajo = System.enqueueJob(trabajo);
        if (reiniciar == true) {
            SesionSimulador.borrar(SesionSimulador.clave(escenario, trabajo.semilla, trabajo.tamanoLote));
        }
        return idTrabajo;
    }

    @TestVisible
    private static Integer validarTamanoLote(Integer pedido) {
        if (pedido == null) {
            return PAGE_SIZE;
        }
        if (pedido < 1 || pedido > PAGE_SIZE) {
            throw new IllegalArgumentException('tamanoLote must be between 1 and ' + PAGE_SIZE + ' (received ' + pedido + ')');
        }
        return pedido;
    }

    /** The job for another page (or a retry) keeps this run's session parameters. */
    private TelemetriaIngesta conParametrosDeSesion(TelemetriaIngesta otro) {
        otro.semilla = semilla;
        otro.tamanoLote = tamanoLote;
        return otro;
    }

    @TestVisible
    private static Integer topeDePaginas(Integer pedido) {
        return (pedido == null || pedido < 1) ? DEFAULT_MAX_PAGINAS : Math.min(pedido, HARD_MAX_PAGINAS);
    }

    public void execute(QueueableContext contexto) {
        String clave = SesionSimulador.clave(escenario, semilla, tamanoLote);
        restaurarSesion(clave);

        // 1) Callouts only, as many pages as the budget allows. Each page is turned into rows and events in memory
        // right away so the raw messages do not pile up in the heap.
        List<PaginaPreparada> preparadas = new List<PaginaPreparada>();
        Integer mensajesDelTrabajo = 0;
        Integer tope = maxMensajesForzado != null ? maxMensajesForzado : MAX_MENSAJES_POR_TRABAJO;
        Boolean flujoTerminado = false;
        Boolean paginaVacia = false;
        SimuladorClient.SimuladorClientException falla;
        Integer intentoDeLaPagina = intento; // attempts already spent on the first page of this job
        Long inicioDeLectura = System.currentTimeMillis();
        Boolean sinPresupuesto = false;
        while (pagina <= maxPaginas && !flujoTerminado && !paginaVacia && !sinPresupuesto) {
            // Checked before each page (so a job never starts a page it cannot afford: the overshoot is bounded to
            // zero messages past the budget, except that the first page is always read) and again after it, below.
            if (mensajesDelTrabajo > 0 && mensajesDelTrabajo + tamanoLote > tope) {
                break;
            }
            if (sinHolguraDeLimites() || (mensajesDelTrabajo > 0 && tiempoAgotado(inicioDeLectura))) {
                break; // the first page is always read: a job that reads nothing would never make progress
            }
            SimuladorClient.Pagina leida;
            try {
                leida = leerPaginaConSesion(clave);
            } catch (SimuladorClient.SimuladorClientException e) {
                falla = e;
                if (!preparadas.isEmpty()) {
                    intentoDeLaPagina = 0; // the failing page is a new one
                }
                break;
            }
            preparadas.add(preparar(leida.mensajes, leida.descartes, pagina));
            mensajesDelTrabajo += leida.mensajes.size() + leida.descartes.size();
            paginaVacia = leida.mensajes.isEmpty();
            if (leida.hayMas) {
                cursor = leida.siguienteCursor;
            } else {
                flujoTerminado = true; // the cursor stays: the next run re-polls the last page
            }
            pagina++;
            sesionReabierta = false;
            // After the page: count and time are re-checked with what this page actually cost.
            sinPresupuesto = mensajesDelTrabajo >= tope || sinHolguraDeLimites() || tiempoAgotado(inicioDeLectura);
        }

        Boolean reintentar = falla != null && esReintentable(falla) && intentoDeLaPagina + 1 < MAX_INTENTOS && !profundidadAgotada();
        if (falla != null && preparadas.isEmpty() && !reintentar) {
            if (esReintentable(falla)) {
                System.debug(LoggingLevel.WARN, 'Ingesta detenida: la pagina ' + pagina + ' agoto sus intentos (estado '
                    + falla.statusCode + '), ' + resumenComoTexto(acumulado));
            }
            throw falla; // nothing was read in this job: fail it so it shows in Apex Jobs
        }

        // 2) DML: per page, log rows first, then the events.
        for (PaginaPreparada preparada : preparadas) {
            acumulado.sumar(escribir(preparada));
            acumulado.paginas++;
        }
        acumulado.flujoTerminado = flujoTerminado;
        ultimoResumen = acumulado;

        // 3) The session continues from here in the next run: saved only after the pages are written, and only when
        // every message of the run left a complete trace. Otherwise the previous cursor stays, so the next run reads
        // those pages again (identity source + messageId skips what was already stored).
        if (acumulado.conFallos()) {
            acumulado.cursorSinAvanzar = true;
            System.debug(LoggingLevel.WARN, 'Ingesta con mensajes sin rastro completo, el cursor guardado no avanza: '
                + resumenComoTexto(acumulado));
            guardarResumen();
            return; // no retry or continuation either: they would read past the messages that must be read again
        }
        if (!preparadas.isEmpty() && String.isNotBlank(cursor) && !SesionSimulador.guardar(clave, cursor)) {
            acumulado.cacheNoDisponible = true;
        }

        // 4) Retry, stop or continue.
        if (falla != null) {
            if (reintentar) {
                System.debug(LoggingLevel.WARN, 'Ingesta: estado ' + falla.statusCode + ' en la pagina ' + pagina
                    + ', reintento ' + (intentoDeLaPagina + 1) + ' de ' + (MAX_INTENTOS - 1));
                TelemetriaIngesta reintento = conParametrosDeSesion(
                    new TelemetriaIngesta(escenario, cursor, pagina, maxPaginas, acumulado));
                reintento.intento = intentoDeLaPagina + 1;
                reintento.sesionReabierta = sesionReabierta;
                acumulado.reintentos++;
                reintento.trabajos = trabajos + 1;
                guardarResumen();
                encolar(reintento, reintento.intento);
                return;
            }
            // Pages were written: failing the job would roll them back, so stop and report. The next run resumes here.
            acumulado.interrumpidaPorEstado = falla.statusCode == null ? 0 : falla.statusCode;
            System.debug(LoggingLevel.WARN, 'Ingesta interrumpida en la pagina ' + pagina + ' (estado '
                + acumulado.interrumpidaPorEstado + '), ' + resumenComoTexto(acumulado));
            guardarResumen();
            return;
        }
        Boolean hayOtra = !flujoTerminado && !paginaVacia && pagina <= maxPaginas;
        if (!hayOtra) {
            System.debug(LoggingLevel.INFO, 'Ingesta terminada: ' + resumenComoTexto(acumulado)
                + ', paginaVacia=' + paginaVacia);
            guardarResumen();
            return;
        }
        if (profundidadAgotada()) {
            System.debug(LoggingLevel.WARN, 'Ingesta detenida: profundidad maxima de cola alcanzada, ' + resumenComoTexto(acumulado)
                + ' (la sesion guardada continua en la proxima corrida)');
            guardarResumen();
            return;
        }
        TelemetriaIngesta siguiente = conParametrosDeSesion(
            new TelemetriaIngesta(escenario, cursor, pagina, maxPaginas, acumulado));
        siguiente.trabajos = trabajos + 1;
        guardarResumen();
        encolar(siguiente, 0); // pollAfterMs is not honored (D024): the next job goes straight to the queue
    }

    /**
     * Decides where this job starts reading. A job that already carries a cursor (continuation or retry) keeps it;
     * the first job of a run takes the saved one. Without it (first run, expired, cleared or cache unavailable)
     * leerPaginaConSesion opens a new session.
     */
    private void restaurarSesion(String clave) {
        if (!SesionSimulador.disponible()) {
            acumulado.cacheNoDisponible = true;
        }
        if (String.isBlank(cursor)) {
            String guardado = SesionSimulador.leerCursor(clave);
            if (String.isNotBlank(guardado)) {
                cursor = guardado;
                acumulado.sesionContinuada = true;
            }
        }
    }

    private static Boolean tiempoAgotado(Long inicio) {
        Long transcurrido = msTranscurridosForzados != null ? msTranscurridosForzados : System.currentTimeMillis() - inicio;
        return transcurrido >= MAX_MS_DE_LECTURA;
    }

    private void guardarResumen() {
        acumulado.actualizadoEn = Datetime.now();
        SesionSimulador.guardarResumen(JSON.serialize(acumulado));
    }

    /** True when the job should stop reading to keep heap, CPU and callouts clear of their governor limits. */
    private static Boolean sinHolguraDeLimites() {
        return Limits.getCallouts() + 3 >= Limits.getLimitCallouts()
            || Limits.getHeapSize() > Limits.getLimitHeapSize() / 2
            || Limits.getCpuTime() > Limits.getLimitCpuTime() * 6 / 10;
    }

    /**
     * Opens the session when there is no cursor and reads one page. A 409/410 on the read means the session
     * expired: clear the saved cursor, open a new session once and read again (the cursor field is replaced so a
     * later retry reuses it).
     */
    private SimuladorClient.Pagina leerPaginaConSesion(String clave) {
        if (String.isBlank(cursor)) {
            cursor = SimuladorClient.abrirSesion(escenario, semilla, tamanoLote);
        }
        try {
            return SimuladorClient.leerPagina(cursor, tamanoLote);
        } catch (SimuladorClient.SimuladorClientException e) {
            if ((e.statusCode != 409 && e.statusCode != 410) || sesionReabierta) {
                throw e;
            }
            sesionReabierta = true;
            acumulado.sesionesReabiertas++;
            System.debug(LoggingLevel.WARN, 'Ingesta: sesion rechazada (' + e.statusCode + '), se abre una nueva en la pagina ' + pagina);
            SesionSimulador.borrar(clave);
            cursor = SimuladorClient.abrirSesion(escenario, semilla, tamanoLote);
            return SimuladorClient.leerPagina(cursor, tamanoLote);
        }
    }

    private static Boolean esReintentable(SimuladorClient.SimuladorClientException e) {
        return e.statusCode != null && (e.statusCode == 429 || e.statusCode >= 500);
    }

    private static void encolar(TelemetriaIngesta trabajo, Integer minutosDeRetraso) {
        if (soloCapturar) {
            encolados.add(trabajo);
            retrasosCapturados.add(minutosDeRetraso);
            return;
        }
        AsyncOptions opciones = new AsyncOptions();
        opciones.MaximumQueueableStackDepth = PROFUNDIDAD_COLA_SOLICITADA;
        if (minutosDeRetraso > 0) {
            opciones.MinimumQueueableDelayInMinutes = Math.min(minutosDeRetraso, MAX_RETRASO_MINUTOS);
        }
        System.enqueueJob(trabajo, opciones);
    }

    private Boolean profundidadAgotada() {
        // Local backstop first: independent of PROFUNDIDAD_COLA_SOLICITADA and of what the platform reports below,
        // so a bug or a real per-org cap lower than requested still stops the chain gracefully (see class comment).
        if (trabajos >= PROFUNDIDAD_LOCAL_MAXIMA) {
            return true;
        }
        if (profundidadForzada != null) {
            return profundidadForzada;
        }
        try {
            return AsyncInfo.hasMaxStackDepth();
        } catch (AsyncException e) {
            // Called outside a Queueable/Finalizer (for example execute() invoked directly): there is no chain
            // to exhaust, so the depth limit cannot have been reached.
            return false;
        }
    }

    /** Convenience for pages with no discarded elements. */
    @TestVisible
    private static Resumen procesarPagina(List<Map<String, Object>> mensajes) {
        return procesarPagina(mensajes, new List<SimuladorClient.Descarte>(), 1);
    }

    /** One page already mapped to rows and events, waiting for the DML phase. No DML, no callout. */
    private class PaginaPreparada {
        List<Senial_Sensor__e> candidatos = new List<Senial_Sensor__e>();
        List<Log_Senial__c> filasCandidatas = new List<Log_Senial__c>(); // parallel to candidatos
        List<Log_Senial__c> rechazos = new List<Log_Senial__c>();
        Integer recibidos = 0;
        Integer descartados = 0;
    }

    /** Logs then publishes one page of raw simulator messages: preparar then escribir. */
    @TestVisible
    private static Resumen procesarPagina(
        List<Map<String, Object>> mensajes,
        List<SimuladorClient.Descarte> descartes,
        Integer numeroPagina
    ) {
        return escribir(preparar(mensajes, descartes, numeroPagina));
    }

    /** Maps the messages of a page to log rows and events. Pure CPU: safe before the callouts end. */
    private static PaginaPreparada preparar(
        List<Map<String, Object>> mensajes,
        List<SimuladorClient.Descarte> descartes,
        Integer numeroPagina
    ) {
        PaginaPreparada p = new PaginaPreparada();
        p.recibidos = mensajes.size() + descartes.size();
        for (Map<String, Object> mensaje : mensajes) {
            String motivo = motivoDeRechazo(mensaje);
            if (motivo != null) {
                p.rechazos.add(filaRechazada(mensaje, motivo));
                continue;
            }
            Senial_Sensor__e evento = aEvento(mensaje);
            p.candidatos.add(evento);
            p.filasCandidatas.add(aFilaDeLog(evento, null));
        }
        for (SimuladorClient.Descarte descarte : descartes) {
            p.rechazos.add(filaDeDescarte(descarte, numeroPagina));
            p.descartados++;
        }
        return p;
    }

    /**
     * Writes one prepared page. Bulk-safe: one insert, one update at most, and one EventBus.publish per 200 events,
     * whatever the page size.
     */
    private static Resumen escribir(PaginaPreparada p) {
        Resumen resumen = new Resumen();
        resumen.recibidos = p.recibidos;
        resumen.descartados = p.descartados;
        Datetime ahora = Datetime.now();
        List<Senial_Sensor__e> candidatos = p.candidatos;
        List<Log_Senial__c> filasCandidatas = p.filasCandidatas;
        List<Log_Senial__c> rechazos = p.rechazos;
        for (Log_Senial__c fila : filasCandidatas) {
            fila.Publicado_At__c = ahora;
        }
        resumen.rechazados = rechazos.size();

        // Step 1: log rows. Partial success: a duplicate identity (resend/replay) leaves the existing row alone.
        List<Log_Senial__c> porInsertar = new List<Log_Senial__c>(filasCandidatas);
        porInsertar.addAll(rechazos);
        List<Boolean> conFila = new List<Boolean>(); // parallel to candidatos: may the event be published?
        if (!porInsertar.isEmpty()) {
            List<Database.SaveResult> resultados = Database.insert(porInsertar, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < resultados.size(); i++) {
                Boolean esCandidato = i < candidatos.size();
                Database.SaveResult resultado = resultados[i];
                Boolean publicable = true;
                if (resultado.isSuccess()) {
                    if (esCandidato) {
                        resumen.logsCreados++;
                    }
                } else if (esDuplicado(resultado)) {
                    resumen.yaExistentes++;
                } else {
                    resumen.logsFallidos++;
                    publicable = false;
                    if (esCandidato) {
                        resumen.noPublicadosPorLog++;
                    }
                }
                if (esCandidato) {
                    conFila.add(publicable);
                }
            }
        }

        List<Senial_Sensor__e> eventos = new List<Senial_Sensor__e>();
        List<Log_Senial__c> filas = new List<Log_Senial__c>(); // parallel to eventos
        for (Integer i = 0; i < candidatos.size(); i++) {
            if (conFila[i]) {
                eventos.add(candidatos[i]);
                filas.add(filasCandidatas[i]);
            }
        }

        // Step 2: publish. Every event with a log row goes out, even a resend, so the subscriber can count it.
        List<Log_Senial__c> aMarcarFallidas = new List<Log_Senial__c>();
        for (Integer desde = 0; desde < eventos.size(); desde += 200) {
            Integer hasta = Math.min(desde + 200, eventos.size());
            List<Senial_Sensor__e> trozo = new List<Senial_Sensor__e>();
            for (Integer i = desde; i < hasta; i++) {
                trozo.add(eventos[i]);
            }
            List<Database.SaveResult> resultados = EventBus.publish(trozo);
            if (resultadosForzados != null && resultadosForzados.size() == trozo.size()) {
                resultados = resultadosForzados;
            }
            for (Integer j = 0; j < resultados.size(); j++) {
                if (resultados[j].isSuccess()) {
                    resumen.publicados++;
                    continue;
                }
                resumen.fallosPublicacion++;
                Log_Senial__c fila = filas[desde + j];
                if (fila.Id != null) { // only rows this run created
                    String codigo = resultados[j].getErrors().isEmpty()
                        ? 'UNKNOWN' : String.valueOf(resultados[j].getErrors()[0].getStatusCode());
                    aMarcarFallidas.add(new Log_Senial__c(
                        Id = fila.Id,
                        Resultado__c = FALLIDA,
                        Motivo__c = 'No se pudo publicar el evento (' + codigo + ')'
                    ));
                }
            }
        }

        // Step 3: a row left as 'Publicada' for an event that never went out would lie, so mark it.
        if (!aMarcarFallidas.isEmpty()) {
            for (Database.SaveResult r : Database.update(aMarcarFallidas, false, AccessLevel.SYSTEM_MODE)) {
                if (!r.isSuccess()) {
                    resumen.logsFallidos++;
                }
            }
        }
        return resumen;
    }

    /**
     * Why a message cannot be published, or null when it can. The identity (source|messageId) has to fit
     * Identidad__c (60) and source/messageId have to fit their own fields (80): truncating would merge
     * different messages, so these are rejected instead.
     */
    private static String motivoDeRechazo(Map<String, Object> mensaje) {
        String source = texto(mensaje.get('source'));
        String messageId = texto(mensaje.get('messageId'));
        if (String.isBlank(source) || String.isBlank(messageId)) {
            return 'Rechazada en la ingesta: falta source o messageId';
        }
        if (source.length() > MAX_SOURCE || messageId.length() > MAX_MESSAGE_ID) {
            return 'Rechazada en la ingesta: source (' + source.length() + ') o messageId (' + messageId.length()
                + ') excede ' + MAX_SOURCE + ' caracteres';
        }
        if (source.length() + 1 + messageId.length() > MAX_IDENTIDAD) {
            return 'Rechazada en la ingesta: la identidad source|messageId (' + (source.length() + 1 + messageId.length())
                + ') excede ' + MAX_IDENTIDAD + ' caracteres';
        }
        return null;
    }

    // The row key is a hash because the real identity does not fit (or does not exist). Same message, same key.
    private static Log_Senial__c filaRechazada(Map<String, Object> mensaje, String motivo) {
        String source = texto(mensaje.get('source'));
        String messageId = texto(mensaje.get('messageId'));
        String base = String.isBlank(source) || String.isBlank(messageId)
            ? 'SIN-ID|' + hash(JSON.serialize(mensaje))
            : 'ID-LARGA|' + hash(source + '|' + messageId);
        String entrega = cortar(texto(mensaje.get('deliveryId')), MAX_DELIVERY_ID);
        String tipo = texto(mensaje.get('messageType'));
        return new Log_Senial__c(
            Identidad__c = base.left(MAX_IDENTIDAD),
            // Source__c and Message_Id__c are required on Log_Senial__c, so a missing value gets a visible placeholder.
            Source__c = String.isBlank(source) ? '(sin source)' : cortar(source, MAX_SOURCE),
            Message_Id__c = String.isBlank(messageId) ? '(sin messageId)' : cortar(messageId, MAX_MESSAGE_ID),
            Delivery_Id__c = entrega,
            Message_Type__c = TIPOS_LOG.contains(tipo) ? tipo : null,
            Occurred_At__c = fecha(cortar(texto(mensaje.get('occurredAt')), MAX_FECHA_TEXTO)),
            Resultado__c = RECHAZADA,
            Motivo__c = cortar(motivo, MAX_MOTIVO)
        );
    }

    private static Log_Senial__c filaDeDescarte(SimuladorClient.Descarte descarte, Integer numeroPagina) {
        return new Log_Senial__c(
            Identidad__c = ('DESCARTE|' + hash(descarte.huella + '@' + descarte.posicion)).left(MAX_IDENTIDAD),
            // Required fields: no source/messageId exist for a non-object element, so say where it was.
            Source__c = '(descartado)',
            Message_Id__c = 'elemento-' + descarte.posicion + '-pagina-' + numeroPagina,
            Resultado__c = RECHAZADA,
            Motivo__c = cortar('Rechazada en la ingesta: el elemento ' + descarte.posicion + ' de data (pagina '
                + numeroPagina + ') no es un objeto JSON (' + descarte.tipo + ')', MAX_MOTIVO)
        );
    }

    /**
     * Maps one simulator message (already checked by motivoDeRechazo) to an event. Asset/building keys that do
     * not fit become null (the subscriber then rejects the message with a reason instead of matching a
     * truncated key to another asset); the remaining text is truncated to its field length.
     */
    @TestVisible
    private static Senial_Sensor__e aEvento(Map<String, Object> mensaje) {
        Map<String, Object> edificio = mapa(mensaje.get('building'));
        Map<String, Object> activo = mapa(mensaje.get('asset'));
        Map<String, Object> medicion = mapa(mensaje.get('measurement'));
        Map<String, Object> comunicacion = mapa(mensaje.get('communication'));

        return new Senial_Sensor__e(
            Source__c = texto(mensaje.get('source')),
            Message_Id__c = texto(mensaje.get('messageId')),
            Delivery_Id__c = cortar(texto(mensaje.get('deliveryId')), MAX_DELIVERY_ID),
            Message_Type__c = cortar(texto(mensaje.get('messageType')), MAX_TIPO_MENSAJE),
            Building_Id__c = soloSiCabe(texto(primero(edificio, 'id', 'externalId')), MAX_LLAVE_EXTERNA),
            Asset_Id__c = soloSiCabe(texto(primero(activo, 'id', 'externalId')), MAX_LLAVE_EXTERNA),
            Asset_Type__c = cortar(texto(activo.get('type')), MAX_TIPO_ACTIVO),
            Sensor_Id__c = cortar(texto(mensaje.get('sensorId')), MAX_SENSOR_ID),
            Measurement_Type__c = cortar(texto(medicion.get('type')), MAX_MEDICION),
            Value__c = cortar(texto(medicion.get('value')), MAX_VALOR),
            Unit__c = cortar(texto(medicion.get('unit')), MAX_UNIDAD),
            Occurred_At__c = cortar(texto(mensaje.get('occurredAt')), MAX_FECHA_TEXTO),
            Published_At__c = cortar(texto(mensaje.get('publishedAt')), MAX_FECHA_TEXTO),
            Comm_Status__c = cortar(texto(comunicacion.get('status')), MAX_ESTADO_COM),
            Gap_Seconds__c = cortar(texto(comunicacion.get('gapSeconds')), MAX_GAP),
            Last_Seen_At__c = cortar(texto(comunicacion.get('lastSeenAt')), MAX_FECHA_TEXTO),
            Episode_Id__c = cortar(texto(comunicacion.get('episodeId')), MAX_EPISODIO)
        );
    }

    private static Log_Senial__c aFilaDeLog(Senial_Sensor__e evento, Datetime publicadoAt) {
        String identidad = evento.Source__c + '|' + evento.Message_Id__c;
        Boolean forzarFallo = identidadesConFalloDeLog.contains(identidad);
        return new Log_Senial__c(
            Identidad__c = identidad,
            Source__c = evento.Source__c,
            Message_Id__c = evento.Message_Id__c,
            Delivery_Id__c = evento.Delivery_Id__c,
            Message_Type__c = TIPOS_LOG.contains(evento.Message_Type__c) ? evento.Message_Type__c : null,
            Occurred_At__c = fecha(evento.Occurred_At__c),
            Resultado__c = forzarFallo ? 'ValorInvalidoDePrueba' : PUBLICADA,
            Publicado_At__c = publicadoAt
        );
    }

    private static Boolean esDuplicado(Database.SaveResult resultado) {
        return !resultado.getErrors().isEmpty() && resultado.getErrors()[0].getStatusCode() == StatusCode.DUPLICATE_VALUE;
    }

    private static String hash(String valor) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(valor)));
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    // Counters and flags only: never the cursor.
    @TestVisible
    private static String resumenComoTexto(Resumen r) {
        return 'paginas=' + r.paginas + ', recibidos=' + r.recibidos + ', logsCreados=' + r.logsCreados
            + ', yaExistentes=' + r.yaExistentes + ', logsFallidos=' + r.logsFallidos
            + ', noPublicadosPorLog=' + r.noPublicadosPorLog + ', publicados=' + r.publicados
            + ', fallosPublicacion=' + r.fallosPublicacion + ', rechazados=' + r.rechazados
            + ', descartados=' + r.descartados + ', reintentos=' + r.reintentos
            + ', sesionesReabiertas=' + r.sesionesReabiertas + ', sesionContinuada=' + r.sesionContinuada
            + ', sesionReiniciada=' + r.sesionReiniciada + ', cacheNoDisponible=' + r.cacheNoDisponible
            + ', flujoTerminado=' + r.flujoTerminado + ', interrumpidaPorEstado=' + r.interrumpidaPorEstado
            + ', cursorSinAvanzar=' + r.cursorSinAvanzar;
    }

    private static Map<String, Object> mapa(Object valor) {
        return valor instanceof Map<String, Object> ? (Map<String, Object>) valor : new Map<String, Object>();
    }

    private static Object primero(Map<String, Object> origen, String clave, String alternativa) {
        return origen.get(clave) != null ? origen.get(clave) : origen.get(alternativa);
    }

    private static String texto(Object valor) {
        return valor == null ? null : String.valueOf(valor);
    }

    private static String cortar(String valor, Integer maximo) {
        return valor != null && valor.length() > maximo ? valor.left(maximo) : valor;
    }

    private static String soloSiCabe(String valor, Integer maximo) {
        return valor != null && valor.length() > maximo ? null : valor;
    }

    private static Datetime fecha(String iso) {
        if (String.isBlank(iso)) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize(JSON.serialize(iso), Datetime.class);
        } catch (Exception e) {
            return null;
        }
    }
}
