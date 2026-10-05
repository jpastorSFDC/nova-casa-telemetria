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
 * Queueable chain: one job = one page. Order inside a job is callouts first (POST /session when there is no
 * cursor yet, then GET /telemetry), then DML (log insert, event publish, log update), then enqueue of the next job.
 * Salesforce forbids a callout after uncommitted DML in the same transaction, so a job never callouts after DML;
 * the next page is a new transaction. The chain stops when the simulator says hasMore=false, on an empty page,
 * at maxPaginas, when the platform's queueable stack depth is exhausted, or at our own PROFUNDIDAD_LOCAL_MAXIMA.
 * The enqueueJob of the next job asks the platform to raise its default chain-depth cap (5) to
 * PROFUNDIDAD_COLA_SOLICITADA via AsyncOptions.MaximumQueueableStackDepth, but that request is not trusted
 * blindly: AsyncInfo.hasMaxStackDepth() was observed in nova-cdo reporting false one job before the platform
 * actually refused to run the next one (an uncaught LimitException, not our graceful WARN stop), so pagina is
 * also checked against our own, more conservative local ceiling regardless of what the platform reports.
 * The cursor travels only as private state of the next job. It is never logged or stored in a record.
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
    // Identities whose log row is sent with an invalid Resultado__c so the insert fails (not a duplicate).
    @TestVisible
    private static Set<String> identidadesConFalloDeLog = new Set<String>();
    @TestVisible
    private static Resumen ultimoResumen;

    // Job state. cursor is sensitive: never log it.
    @TestVisible
    private String escenario;
    @TestVisible
    private String cursor;
    @TestVisible
    private Integer pagina;
    @TestVisible
    private Integer maxPaginas;
    @TestVisible
    private Resumen acumulado;

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
        return System.enqueueJob(new TelemetriaIngesta(escenario, topeDePaginas(maxPaginas)));
    }

    @TestVisible
    private static Integer topeDePaginas(Integer pedido) {
        return (pedido == null || pedido < 1) ? DEFAULT_MAX_PAGINAS : Math.min(pedido, HARD_MAX_PAGINAS);
    }

    public void execute(QueueableContext contexto) {
        // 1) Callouts, before any DML in this transaction.
        if (String.isBlank(cursor)) {
            cursor = SimuladorClient.abrirSesion(escenario);
        }
        SimuladorClient.Pagina leida = SimuladorClient.leerPagina(cursor, PAGE_SIZE);

        // 2) DML: log rows first, then the events.
        Resumen deEstaPagina = procesarPagina(leida.mensajes, leida.descartes, pagina);
        acumulado.sumar(deEstaPagina);
        acumulado.paginas++;
        ultimoResumen = acumulado;
        if (acumulado.logsFallidos > 0 || acumulado.noPublicadosPorLog > 0 || acumulado.fallosPublicacion > 0) {
            System.debug(LoggingLevel.WARN, 'Ingesta con mensajes sin rastro completo: ' + resumenComoTexto(acumulado));
        }

        // 3) Chain.
        Boolean hayOtra = leida.hayMas && !leida.mensajes.isEmpty() && pagina < maxPaginas;
        if (!hayOtra) {
            System.debug(LoggingLevel.INFO, 'Ingesta terminada: ' + resumenComoTexto(acumulado)
                + ', hayMas=' + leida.hayMas + ', paginaVacia=' + leida.mensajes.isEmpty());
            return;
        }
        if (profundidadAgotada()) {
            System.debug(LoggingLevel.WARN, 'Ingesta detenida: profundidad maxima de cola alcanzada, ' + resumenComoTexto(acumulado));
            return;
        }
        TelemetriaIngesta siguiente = new TelemetriaIngesta(escenario, leida.siguienteCursor, pagina + 1, maxPaginas, acumulado);
        if (soloCapturar) {
            encolados.add(siguiente);
        } else {
            AsyncOptions opciones = new AsyncOptions();
            opciones.MaximumQueueableStackDepth = PROFUNDIDAD_COLA_SOLICITADA;
            System.enqueueJob(siguiente, opciones);
        }
    }

    private Boolean profundidadAgotada() {
        // Local backstop first: independent of PROFUNDIDAD_COLA_SOLICITADA and of what the platform reports below,
        // so a bug or a real per-org cap lower than requested still stops the chain gracefully (see class comment).
        if (pagina >= PROFUNDIDAD_LOCAL_MAXIMA) {
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

    /**
     * Logs then publishes one page of raw simulator messages. Bulk-safe: one insert, one update at most,
     * and one EventBus.publish per 200 events, whatever the page size.
     */
    @TestVisible
    private static Resumen procesarPagina(
        List<Map<String, Object>> mensajes,
        List<SimuladorClient.Descarte> descartes,
        Integer numeroPagina
    ) {
        Resumen resumen = new Resumen();
        resumen.recibidos = mensajes.size() + descartes.size();
        Datetime ahora = Datetime.now();

        List<Senial_Sensor__e> candidatos = new List<Senial_Sensor__e>();
        List<Log_Senial__c> filasCandidatas = new List<Log_Senial__c>(); // parallel to candidatos
        List<Log_Senial__c> rechazos = new List<Log_Senial__c>();

        for (Map<String, Object> mensaje : mensajes) {
            String motivo = motivoDeRechazo(mensaje);
            if (motivo != null) {
                rechazos.add(filaRechazada(mensaje, motivo));
                continue;
            }
            Senial_Sensor__e evento = aEvento(mensaje);
            candidatos.add(evento);
            filasCandidatas.add(aFilaDeLog(evento, ahora));
        }
        for (SimuladorClient.Descarte descarte : descartes) {
            rechazos.add(filaDeDescarte(descarte, numeroPagina));
            resumen.descartados++;
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

    private static String resumenComoTexto(Resumen r) {
        return 'paginas=' + r.paginas + ', recibidos=' + r.recibidos + ', logsCreados=' + r.logsCreados
            + ', yaExistentes=' + r.yaExistentes + ', logsFallidos=' + r.logsFallidos
            + ', noPublicadosPorLog=' + r.noPublicadosPorLog + ', publicados=' + r.publicados
            + ', fallosPublicacion=' + r.fallosPublicacion + ', rechazados=' + r.rechazados
            + ', descartados=' + r.descartados;
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
