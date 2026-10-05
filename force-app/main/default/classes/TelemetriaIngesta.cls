/**
 * Ingesta de telemetría en segundo plano. Cada ejecución pide una página al simulador, publica
 * sus registros como Senial_Sensor__e en bloque y deja un Log_Senial__c Publicada por cada
 * identidad (source + messageId) nueva. Mientras haya más páginas encola la siguiente con la
 * espera que pide el simulador, sin pasar de maximoPaginas.
 */
public with sharing class TelemetriaIngesta implements Queueable, Database.AllowsCallouts {
    public static final Integer MAXIMO_PAGINAS = 50;

    private static final Integer MAXIMO_REINTENTOS = 3;
    private static final Integer DEMORA_MAXIMA_MINUTOS = 10;
    private static final String RESULTADO_PUBLICADA = 'Publicada';
    private static final Set<String> TIPOS_DE_MENSAJE = new Set<String>{ 'MEASUREMENT', 'CONNECTIVITY' };

    @TestVisible
    private static Integer demoraEncoladaMinutos;

    private final String escenario;
    private final Integer semilla;
    private final Integer tamanoLote;
    private final Integer maximoPaginas;
    private String cursor;
    private Integer paginasProcesadas = 0;
    private Integer reintentos = 0;
    private Boolean sesionReabierta = false;

    @TestVisible
    private TelemetriaIngesta(String escenario, Integer semilla, Integer tamanoLote, Integer maximoPaginas) {
        this.escenario = escenario;
        this.semilla = semilla;
        this.tamanoLote = tamanoLote;
        this.maximoPaginas = maximoPaginas;
    }

    /**
     * @param escenario Escenario del simulador (MIXED, QA_200, BOUNDARIES...).
     * @param semilla Semilla para repetir la secuencia; null deja que el simulador la elija.
     * @param tamanoLote Registros por página, entre 1 y 200.
     * @param maximoPaginas Tope de páginas de la corrida, entre 1 y MAXIMO_PAGINAS.
     * @return Id del primer trabajo encolado.
     * @throws IllegalArgumentException si algún parámetro es inválido.
     * @example
     * Id jobId = TelemetriaIngesta.iniciar('MIXED', null, 20, 1);
     */
    public static Id iniciar(String escenario, Integer semilla, Integer tamanoLote, Integer maximoPaginas) {
        if (String.isBlank(escenario)) {
            throw new IllegalArgumentException('El escenario es obligatorio');
        }
        if (tamanoLote == null || tamanoLote < 1 || tamanoLote > SimuladorClient.TAMANO_LOTE_MAXIMO) {
            throw new IllegalArgumentException('tamanoLote debe estar entre 1 y ' + SimuladorClient.TAMANO_LOTE_MAXIMO + ' (recibido: ' + tamanoLote + ')');
        }
        if (maximoPaginas == null || maximoPaginas < 1 || maximoPaginas > MAXIMO_PAGINAS) {
            throw new IllegalArgumentException('maximoPaginas debe estar entre 1 y ' + MAXIMO_PAGINAS + ' (recibido: ' + maximoPaginas + ')');
        }
        return System.enqueueJob(new TelemetriaIngesta(escenario.trim(), semilla, tamanoLote, maximoPaginas));
    }

    /**
     * Procesa una página y encola la siguiente, o reintenta si el simulador pidió esperar.
     * @param context Contexto del trabajo encolado.
     * @throws SimuladorClient.SimuladorException si el error no admite reintento o se agotaron los reintentos.
     */
    public void execute(QueueableContext context) {
        SimuladorClient.Lote lote;
        try {
            lote = pedirPagina();
        } catch (SimuladorClient.SimuladorException e) {
            reintentarODetener(e);
            return;
        }

        paginasProcesadas++;
        reintentos = 0;
        System.debug(LoggingLevel.INFO, 'TelemetriaIngesta ' + escenario + ' página ' + paginasProcesadas + '/' + maximoPaginas
            + ': ' + publicar(lote.registros));

        if (lote.hayMas && String.isNotBlank(lote.siguienteCursor) && paginasProcesadas < maximoPaginas) {
            cursor = lote.siguienteCursor;
            encolar(lote.esperaMs);
        }
    }

    private SimuladorClient.Lote pedirPagina() {
        if (String.isBlank(cursor)) {
            cursor = SimuladorClient.abrirSesion(escenario, semilla, tamanoLote).cursor;
        }
        try {
            return SimuladorClient.pedirLote(cursor);
        } catch (SimuladorClient.SimuladorException e) {
            Boolean sesionVencida = e.codigoEstado == 409 || e.codigoEstado == 410;
            if (!sesionVencida || sesionReabierta) {
                throw e;
            }
            sesionReabierta = true;
            cursor = SimuladorClient.abrirSesion(escenario, semilla, tamanoLote).cursor;
            return SimuladorClient.pedirLote(cursor);
        }
    }

    private void reintentarODetener(SimuladorClient.SimuladorException e) {
        Boolean reintentable = e.codigoEstado == 429 || e.codigoEstado >= 500;
        if (reintentable && reintentos < MAXIMO_REINTENTOS) {
            reintentos++;
            System.debug(LoggingLevel.WARN, 'TelemetriaIngesta reintento ' + reintentos + '/' + MAXIMO_REINTENTOS
                + ' tras HTTP ' + e.codigoEstado);
            encolar(e.esperaMs ?? SimuladorClient.ESPERA_POR_DEFECTO_MS);
            return;
        }
        System.debug(LoggingLevel.ERROR, 'TelemetriaIngesta detenida tras ' + paginasProcesadas + ' páginas: ' + e.getMessage());
        throw e;
    }

    private void encolar(Integer esperaMs) {
        demoraEncoladaMinutos = Math.min(DEMORA_MAXIMA_MINUTOS, Math.ceil(Math.max(esperaMs ?? 0, 0) / 60000.0).intValue());
        // Un Queueable no puede encolar otro dentro de una prueba (Maximum stack depth has been reached).
        if (!Test.isRunningTest()) {
            System.enqueueJob(this, demoraEncoladaMinutos);
        }
    }

    private static String publicar(List<Object> registros) {
        List<Senial_Sensor__e> seniales = new List<Senial_Sensor__e>();
        for (Object registro : registros) {
            seniales.add(crearSenial(registro instanceof Map<String, Object> ? (Map<String, Object>) registro : new Map<String, Object>()));
        }
        List<Database.SaveResult> publicaciones = EventBus.publish(seniales);

        Datetime publicadoAt = Datetime.now();
        Map<String, Log_Senial__c> logPorIdentidad = new Map<String, Log_Senial__c>();
        Integer publicadas = 0;
        Integer sinIdentidad = 0;
        for (Integer i = 0; i < seniales.size(); i++) {
            if (!publicaciones[i].isSuccess()) {
                continue;
            }
            publicadas++;
            Senial_Sensor__e senial = seniales[i];
            if (String.isBlank(senial.Source__c) || String.isBlank(senial.Message_Id__c)) {
                sinIdentidad++;
                continue;
            }
            String identidad = senial.Source__c + '|' + senial.Message_Id__c;
            if (!logPorIdentidad.containsKey(identidad)) {
                logPorIdentidad.put(identidad, crearLog(identidad, senial, publicadoAt));
            }
        }

        // SYSTEM_MODE: la ingesta es un proceso del sistema; no depende del acceso de quien la lanza.
        for (Log_Senial__c existente : [
            SELECT Identidad__c FROM Log_Senial__c WHERE Identidad__c IN :logPorIdentidad.keySet() WITH SYSTEM_MODE
        ]) {
            logPorIdentidad.remove(existente.Identidad__c);
        }
        Integer logsFallidos = 0;
        for (Database.SaveResult resultado : Database.insert(logPorIdentidad.values(), false, AccessLevel.SYSTEM_MODE)) {
            if (!resultado.isSuccess()) {
                logsFallidos++;
                System.debug(LoggingLevel.WARN, 'TelemetriaIngesta no pudo crear un Log_Senial__c: ' + resultado.getErrors()[0].getMessage());
            }
        }

        Integer logsIntentados = logPorIdentidad.size();
        return registros.size() + ' registros, ' + publicadas + ' eventos publicados (' + sinIdentidad + ' sin source/messageId), '
            + (logsIntentados - logsFallidos) + ' logs nuevos, ' + logsFallidos + ' logs fallidos, '
            + (publicadas - sinIdentidad - logsIntentados) + ' identidades ya registradas';
    }

    private static Senial_Sensor__e crearSenial(Map<String, Object> registro) {
        Map<String, Object> edificio = leerObjeto(registro, 'building');
        Map<String, Object> activo = leerObjeto(registro, 'asset');
        Map<String, Object> medicion = leerObjeto(registro, 'measurement');
        Map<String, Object> comunicacion = leerObjeto(registro, 'communication');
        return new Senial_Sensor__e(
            Delivery_Id__c = texto(registro.get('deliveryId')),
            Message_Id__c = texto(registro.get('messageId')),
            Message_Type__c = texto(registro.get('messageType')),
            Source__c = texto(registro.get('source')),
            Building_Id__c = texto(edificio.get('id')),
            Asset_Id__c = texto(activo.get('id')),
            Asset_Type__c = texto(activo.get('type')),
            Sensor_Id__c = texto(registro.get('sensorId')),
            Measurement_Type__c = texto(medicion.get('type')),
            Value__c = texto(medicion.get('value')),
            Unit__c = texto(medicion.get('unit')),
            Comm_Status__c = texto(comunicacion.get('status')),
            Gap_Seconds__c = texto(comunicacion.get('gapSeconds')),
            Last_Seen_At__c = texto(comunicacion.get('lastSeenAt')),
            Episode_Id__c = texto(comunicacion.get('episodeId')),
            Occurred_At__c = texto(registro.get('occurredAt')),
            Published_At__c = texto(registro.get('publishedAt'))
        );
    }

    private static Log_Senial__c crearLog(String identidad, Senial_Sensor__e senial, Datetime publicadoAt) {
        return new Log_Senial__c(
            Identidad__c = identidad,
            Message_Id__c = senial.Message_Id__c,
            Source__c = senial.Source__c,
            Delivery_Id__c = senial.Delivery_Id__c,
            Message_Type__c = TIPOS_DE_MENSAJE.contains(senial.Message_Type__c) ? senial.Message_Type__c : null,
            Occurred_At__c = convertirFecha(senial.Occurred_At__c),
            Publicado_At__c = publicadoAt,
            Resultado__c = RESULTADO_PUBLICADA
        );
    }

    private static Map<String, Object> leerObjeto(Map<String, Object> registro, String clave) {
        Object valor = registro.get(clave);
        return valor instanceof Map<String, Object> ? (Map<String, Object>) valor : new Map<String, Object>();
    }

    private static String texto(Object valor) {
        return valor == null ? null : String.valueOf(valor);
    }

    private static Datetime convertirFecha(String texto) {
        if (String.isBlank(texto)) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize('"' + texto.trim() + '"', Datetime.class);
        } catch (JSONException e) {
            return null;
        }
    }
}
