/**
 * US-201 ingestion: pages GET /telemetry through SimuladorClient and, for every page,
 *   1) inserts one Log_Senial__c row per message with Resultado__c = 'Publicada' (publishing is not processing),
 *   2) publishes one Senial_Sensor__e per message with EventBus.publish, checking each SaveResult.
 * Processing (classification, Lectura_Vigente__c, Cases) is the Senial_Sensor__e subscriber's job.
 *
 * Queueable chain: one job = one page. Order inside a job is callouts first (POST /session when there is no
 * cursor yet, then GET /telemetry), then DML (log insert, event publish, log update), then enqueue of the next job.
 * Salesforce forbids a callout after uncommitted DML in the same transaction, so a job never callouts after DML;
 * the next page is a new transaction. The chain stops when the simulator says hasMore=false, on an empty page,
 * at maxPaginas, or when the platform's queueable stack depth is exhausted (developer/trial orgs allow 5).
 * The cursor travels only as private state of the next job. It is never logged or stored in a record.
 *
 * Access: without sharing + SYSTEM_MODE. Ingestion must not depend on operator/admin permissions (AGENTS.md,
 * BR-208): whoever starts the chain (or Automated Process) may lack access to Log_Senial__c. The operator query
 * path has its own authorization; this class must not be called from LWC or @AuraEnabled code.
 */
public without sharing class TelemetriaIngesta implements Queueable, Database.AllowsCallouts {

    public static final Integer PAGE_SIZE = 200;
    public static final Integer DEFAULT_MAX_PAGINAS = 25;
    private static final Integer HARD_MAX_PAGINAS = 100;

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

    // Test seams. In production: encolados is unused and resultadosForzados stays null.
    // Tests cannot chain real queueables, so under Test.isRunningTest() the next job is captured here.
    @TestVisible
    private static List<TelemetriaIngesta> encolados = new List<TelemetriaIngesta>();
    @TestVisible
    private static List<Database.SaveResult> resultadosForzados;
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
        public Integer recibidos = 0;
        public Integer logsCreados = 0;
        public Integer yaExistentes = 0;
        public Integer logsFallidos = 0;
        public Integer publicados = 0;
        public Integer fallosPublicacion = 0;
        public Integer descartados = 0;
        public Integer omitidosPorLongitud = 0;

        public void sumar(Resumen otro) {
            recibidos += otro.recibidos;
            logsCreados += otro.logsCreados;
            yaExistentes += otro.yaExistentes;
            logsFallidos += otro.logsFallidos;
            publicados += otro.publicados;
            fallosPublicacion += otro.fallosPublicacion;
            descartados += otro.descartados;
            omitidosPorLongitud += otro.omitidosPorLongitud;
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
        Resumen deEstaPagina = procesarPagina(leida.mensajes);
        deEstaPagina.descartados += leida.descartados;
        acumulado.sumar(deEstaPagina);
        acumulado.paginas++;
        ultimoResumen = acumulado;

        // 3) Chain.
        Boolean hayOtra = leida.hayMas && !leida.mensajes.isEmpty() && pagina < maxPaginas;
        if (!hayOtra) {
            System.debug(LoggingLevel.INFO, 'Ingesta terminada: ' + resumenComoTexto(acumulado)
                + ', hayMas=' + leida.hayMas + ', paginaVacia=' + leida.mensajes.isEmpty());
            return;
        }
        if (!Test.isRunningTest() && AsyncInfo.hasMaxStackDepth()) {
            System.debug(LoggingLevel.WARN, 'Ingesta detenida: profundidad maxima de cola alcanzada, ' + resumenComoTexto(acumulado));
            return;
        }
        TelemetriaIngesta siguiente = new TelemetriaIngesta(escenario, leida.siguienteCursor, pagina + 1, maxPaginas, acumulado);
        if (Test.isRunningTest()) {
            encolados.add(siguiente);
        } else {
            System.enqueueJob(siguiente);
        }
    }

    /**
     * Logs then publishes one page of raw simulator messages. Bulk-safe: one insert, one update at most,
     * and one EventBus.publish per 200 events, whatever the page size.
     */
    @TestVisible
    private static Resumen procesarPagina(List<Map<String, Object>> mensajes) {
        Resumen resumen = new Resumen();
        resumen.recibidos = mensajes.size();

        List<Senial_Sensor__e> eventos = new List<Senial_Sensor__e>();
        List<Log_Senial__c> filas = new List<Log_Senial__c>(); // parallel to eventos; null = no identity, no row
        List<Log_Senial__c> porInsertar = new List<Log_Senial__c>();
        Datetime ahora = Datetime.now();

        for (Map<String, Object> mensaje : mensajes) {
            Senial_Sensor__e evento = aEvento(mensaje);
            if (evento == null) {
                resumen.omitidosPorLongitud++;
                continue;
            }
            eventos.add(evento);
            Log_Senial__c fila = aFilaDeLog(mensaje, evento, ahora);
            filas.add(fila);
            if (fila != null) {
                porInsertar.add(fila);
            }
        }

        // Step 1: log rows as 'Publicada'. Partial success: a duplicate identity (resend) leaves the existing row alone.
        if (!porInsertar.isEmpty()) {
            List<Database.SaveResult> resultados = Database.insert(porInsertar, false, AccessLevel.SYSTEM_MODE);
            for (Database.SaveResult resultado : resultados) {
                if (resultado.isSuccess()) {
                    resumen.logsCreados++;
                } else if (!resultado.getErrors().isEmpty() && resultado.getErrors()[0].getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                    resumen.yaExistentes++;
                } else {
                    resumen.logsFallidos++;
                }
            }
        }

        // Step 2: publish. Every event goes out, even a resend, so the subscriber can count it.
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
                if (fila != null && fila.Id != null) { // only rows this run created
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
     * Maps one simulator message to an event, or returns null when source or messageId is longer than its
     * field: those two make up the identity, so truncating would merge different messages. Other text is
     * truncated to its field length, except the asset/building keys, which become null (the subscriber then
     * rejects the message with a reason instead of matching a truncated key to another asset).
     */
    @TestVisible
    private static Senial_Sensor__e aEvento(Map<String, Object> mensaje) {
        String source = texto(mensaje.get('source'));
        String messageId = texto(mensaje.get('messageId'));
        if ((source != null && source.length() > MAX_SOURCE) || (messageId != null && messageId.length() > MAX_MESSAGE_ID)) {
            return null;
        }
        Map<String, Object> edificio = mapa(mensaje.get('building'));
        Map<String, Object> activo = mapa(mensaje.get('asset'));
        Map<String, Object> medicion = mapa(mensaje.get('measurement'));
        Map<String, Object> comunicacion = mapa(mensaje.get('communication'));

        return new Senial_Sensor__e(
            Source__c = source,
            Message_Id__c = messageId,
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

    // No row without a full identity (source|messageId) that fits Identidad__c; the subscriber rejects those events.
    private static Log_Senial__c aFilaDeLog(Map<String, Object> mensaje, Senial_Sensor__e evento, Datetime publicadoAt) {
        if (String.isBlank(evento.Source__c) || String.isBlank(evento.Message_Id__c)) {
            return null;
        }
        String identidad = evento.Source__c + '|' + evento.Message_Id__c;
        if (identidad.length() > MAX_IDENTIDAD) {
            return null;
        }
        return new Log_Senial__c(
            Identidad__c = identidad,
            Source__c = evento.Source__c,
            Message_Id__c = evento.Message_Id__c,
            Delivery_Id__c = evento.Delivery_Id__c,
            Message_Type__c = TIPOS_LOG.contains(evento.Message_Type__c) ? evento.Message_Type__c : null,
            Occurred_At__c = fecha(evento.Occurred_At__c),
            Resultado__c = PUBLICADA,
            Publicado_At__c = publicadoAt
        );
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    private static String resumenComoTexto(Resumen r) {
        return 'paginas=' + r.paginas + ', recibidos=' + r.recibidos + ', logsCreados=' + r.logsCreados
            + ', yaExistentes=' + r.yaExistentes + ', logsFallidos=' + r.logsFallidos + ', publicados=' + r.publicados
            + ', fallosPublicacion=' + r.fallosPublicacion + ', descartados=' + r.descartados
            + ', omitidosPorLongitud=' + r.omitidosPorLongitud;
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
