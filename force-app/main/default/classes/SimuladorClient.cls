/**
 * Cliente del simulador de Nova Casa vía la Named Credential Nova_Casa_Simulator: abre una
 * sesión (POST /session) y pagina GET /telemetry enviando el cursor en X-Simulator-Cursor.
 * Devuelve los registros tal como llegan; convertirlos en Senial_Sensor__e es de quien llama.
 */
public with sharing class SimuladorClient {
    public static final Integer TAMANO_LOTE_MAXIMO = 200;
    public static final Integer ESPERA_POR_DEFECTO_MS = 10000;

    private static final String ENDPOINT_BASE = 'callout:Nova_Casa_Simulator';
    private static final String RUTA_SESION = '/session';
    private static final String RUTA_TELEMETRIA = '/telemetry';
    private static final String CABECERA_CURSOR = 'X-Simulator-Cursor';
    private static final Integer LARGO_MAXIMO_DETALLE = 200;

    /**
     * @param escenario Escenario del catálogo (MIXED, QA_200, BOUNDARIES...).
     * @param semilla Semilla para repetir la secuencia; null deja que el simulador la elija.
     * @param tamanoLote Registros por página, entre 1 y 200.
     * @return Sesión con el cursor de la primera página.
     * @throws SimuladorException si los parámetros son inválidos o el simulador rechaza la petición.
     */
    public static Sesion abrirSesion(String escenario, Integer semilla, Integer tamanoLote) {
        if (String.isBlank(escenario)) {
            throw new SimuladorException('El escenario es obligatorio para abrir una sesión');
        }
        if (tamanoLote == null || tamanoLote < 1 || tamanoLote > TAMANO_LOTE_MAXIMO) {
            throw new SimuladorException('tamanoLote debe estar entre 1 y ' + TAMANO_LOTE_MAXIMO + ' (recibido: ' + tamanoLote + ')');
        }

        Map<String, Object> cuerpo = new Map<String, Object>{ 'scenario' => escenario, 'batchSize' => tamanoLote };
        if (semilla != null) {
            cuerpo.put('seed', semilla);
        }
        HttpRequest request = crearPeticion('POST', RUTA_SESION);
        request.setHeader('Content-Type', 'application/json');
        request.setBody(JSON.serialize(cuerpo));
        HttpResponse response = enviar(request, null);

        Sesion sesion = new Sesion();
        try {
            Map<String, Object> respuesta = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
            Map<String, Object> datos = (Map<String, Object>) respuesta.get('session') ?? new Map<String, Object>();
            sesion.cursor = (String) respuesta.get('cursor');
            sesion.escenario = (String) datos.get('scenario') ?? escenario;
            sesion.semilla = datos.containsKey('seed') ? Integer.valueOf(datos.get('seed')) : semilla;
            sesion.tamanoLote = datos.containsKey('batchSize') ? Integer.valueOf(datos.get('batchSize')) : tamanoLote;
        } catch (JSONException e) {
            throw new SimuladorException('POST /session devolvió un JSON inválido', e);
        } catch (TypeException e) {
            throw new SimuladorException('POST /session devolvió un JSON con formato inesperado', e);
        }
        if (String.isBlank(sesion.cursor)) {
            throw new SimuladorException('POST /session respondió sin cursor');
        }
        return sesion;
    }

    /**
     * @param cursor Cursor de la sesión o el siguienteCursor del lote anterior.
     * @return Registros de la página y datos para pedir la siguiente.
     * @throws SimuladorException si falta el cursor, el simulador lo rechaza o la respuesta no es válida.
     */
    public static Lote pedirLote(String cursor) {
        if (String.isBlank(cursor)) {
            throw new SimuladorException('Se necesita un cursor para pedir telemetría; abrir una sesión con abrirSesion()');
        }
        HttpRequest request = crearPeticion('GET', RUTA_TELEMETRIA);
        request.setHeader(CABECERA_CURSOR, cursor);
        HttpResponse response = enviar(request, cursor);

        try {
            Map<String, Object> respuesta = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
            Map<String, Object> paginacion = (Map<String, Object>) respuesta.get('pagination') ?? new Map<String, Object>();
            Lote lote = new Lote();
            lote.registros = (List<Object>) respuesta.get('data') ?? new List<Object>();
            lote.siguienteCursor = (String) paginacion.get('nextCursor');
            lote.hayMas = (Boolean) paginacion.get('hasMore') ?? false;
            lote.esperaMs = paginacion.containsKey('pollAfterMs') ? Integer.valueOf(paginacion.get('pollAfterMs')) : ESPERA_POR_DEFECTO_MS;
            return lote;
        } catch (JSONException e) {
            throw new SimuladorException('GET /telemetry devolvió un JSON inválido', e);
        } catch (TypeException e) {
            throw new SimuladorException('GET /telemetry devolvió un JSON con formato inesperado', e);
        }
    }

    /**
     * Sigue siguienteCursor mientras hayMas, sin pasar de maximoPaginas ni del límite de callouts.
     * Para continuar, usar siguienteCursor del último lote si su hayMas sigue en true.
     * @param cursor Cursor desde el que empezar.
     * @param maximoPaginas Tope de páginas a pedir en esta transacción.
     * @return Lotes en el orden recibido.
     * @throws SimuladorException si maximoPaginas es inválido o falla alguna página.
     */
    public static List<Lote> recorrer(String cursor, Integer maximoPaginas) {
        if (maximoPaginas == null || maximoPaginas < 1) {
            throw new SimuladorException('maximoPaginas debe ser mayor que 0 (recibido: ' + maximoPaginas + ')');
        }
        List<Lote> lotes = new List<Lote>();
        String cursorActual = cursor;
        while (lotes.size() < maximoPaginas && Limits.getCallouts() < Limits.getLimitCallouts()) {
            Lote lote = pedirLote(cursorActual);
            lotes.add(lote);
            if (!lote.hayMas || String.isBlank(lote.siguienteCursor)) {
                break;
            }
            cursorActual = lote.siguienteCursor;
        }
        return lotes;
    }

    private static HttpRequest crearPeticion(String metodo, String ruta) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(ENDPOINT_BASE + ruta);
        request.setMethod(metodo);
        request.setHeader('Accept', 'application/json');
        return request;
    }

    private static HttpResponse enviar(HttpRequest request, String cursor) {
        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (CalloutException e) {
            throw new SimuladorException(describirOperacion(request) + ' falló sin respuesta del simulador: ' + e.getMessage(), e);
        }
        Integer codigo = response.getStatusCode();
        if (codigo < 200 || codigo > 299) {
            throw crearErrorHttp(request, response, cursor);
        }
        return response;
    }

    private static SimuladorException crearErrorHttp(HttpRequest request, HttpResponse response, String cursor) {
        Integer codigo = response.getStatusCode();
        Map<String, Object> problema = leerProblema(response);
        Integer esperaMs;
        String causa;
        switch on codigo {
            when 401, 403 {
                causa = 'credenciales rechazadas; revisar la External Credential Nova_Casa_Simulator y el acceso del usuario a su principal';
            }
            when 404 {
                causa = 'recurso no encontrado; revisar la URL de la Named Credential Nova_Casa_Simulator';
            }
            when 409, 410 {
                causa = 'sesión o cursor vencido o inválido; abrir una sesión nueva';
            }
            when 429 {
                esperaMs = leerEsperaMs(response, problema);
                causa = 'límite de peticiones alcanzado; reintentar en ' + esperaMs + ' ms';
            }
            when else {
                causa = codigo >= 500 ? 'error del simulador; reintentar más tarde' : 'solicitud rechazada';
            }
        }

        String mensaje = describirOperacion(request) + ' respondió HTTP ' + codigo + ': ' + causa
            + '. Detalle: ' + extraerDetalle(response, problema, cursor);
        String correlacion = response.getHeader('X-Correlation-Id');
        if (String.isNotBlank(correlacion)) {
            mensaje += ' (X-Correlation-Id: ' + correlacion + ')';
        }
        SimuladorException error = new SimuladorException(mensaje);
        error.codigoEstado = codigo;
        error.esperaMs = esperaMs;
        return error;
    }

    private static Map<String, Object> leerProblema(HttpResponse response) {
        String cuerpo = response.getBody();
        if (String.isBlank(cuerpo)) {
            return null;
        }
        try {
            Object valor = JSON.deserializeUntyped(cuerpo);
            return valor instanceof Map<String, Object> ? (Map<String, Object>) valor : null;
        } catch (JSONException e) {
            return null;
        }
    }

    private static Integer leerEsperaMs(HttpResponse response, Map<String, Object> problema) {
        Object pollAfterMs = problema?.get('pollAfterMs');
        if (pollAfterMs instanceof Integer) {
            return (Integer) pollAfterMs;
        }
        String retryAfter = response.getHeader('Retry-After')?.trim();
        if (String.isNotBlank(retryAfter) && retryAfter.isNumeric()) {
            return Integer.valueOf(retryAfter) * 1000;
        }
        return ESPERA_POR_DEFECTO_MS;
    }

    private static String extraerDetalle(HttpResponse response, Map<String, Object> problema, String cursor) {
        Object texto = problema?.get('detail') ?? problema?.get('title');
        String detalle = texto != null ? String.valueOf(texto) : response.getBody();
        if (String.isBlank(detalle)) {
            return 'sin detalle';
        }
        detalle = detalle.stripHtmlTags().normalizeSpace();
        if (String.isNotBlank(cursor)) {
            detalle = detalle.replace(cursor, '[cursor]');
        }
        return detalle.abbreviate(LARGO_MAXIMO_DETALLE);
    }

    private static String describirOperacion(HttpRequest request) {
        return request.getMethod() + ' ' + request.getEndpoint().removeStart(ENDPOINT_BASE);
    }

    /**
     * Sesión abierta en el simulador. El cursor da acceso a la sesión: no registrarlo en logs.
     */
    public class Sesion {
        public String cursor;
        public String escenario;
        public Integer semilla;
        public Integer tamanoLote;
    }

    /**
     * Página de GET /telemetry. registros son los objetos de data sin transformar.
     */
    public class Lote {
        public List<Object> registros;
        public String siguienteCursor;
        public Boolean hayMas;
        public Integer esperaMs;
    }

    /**
     * Error de parámetros, de conexión o de respuesta del simulador. codigoEstado solo viene
     * cuando el simulador respondió un HTTP de error, y esperaMs solo en HTTP 429.
     */
    public class SimuladorException extends Exception {
        public Integer codigoEstado;
        public Integer esperaMs;
    }
}
