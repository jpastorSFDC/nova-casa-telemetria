/**
 * HTTP client for the Nova Casa Simulator (POST /session, GET /telemetry) through the
 * Nova_Casa_Simulator Named Credential. It only talks HTTP: no DML, no publishing.
 *
 * Credentials: the Bearer token is added by the Named Credential / External Credential and never
 * touches Apex. The session cursor (X-Simulator-Cursor header, pagination.nextCursor) is sensitive too:
 * it is never logged, never put in an exception message and never stored. Exception messages carry only
 * the operation name and the HTTP status code. They deliberately omit the response body and the JSON
 * parser's own message, because a JSONException message quotes part of the body, and a telemetry
 * body contains the next cursor.
 *
 * Contract (Sprint 2 - Nova Casa.md, "Contrato", plus docs/entendimiento.md "Simulator connection notes"):
 * the stream starts with POST /session, which returns a cursor. Every GET /telemetry?limit=N sends it
 * in X-Simulator-Cursor, and the response's pagination.nextCursor is the cursor for the next page.
 */
public inherited sharing class SimuladorClient {

    public static final String CURSOR_HEADER = 'X-Simulator-Cursor';
    public static final Integer MAX_LIMIT = 200; // BR-202: a page never exceeds one trigger batch

    private static final String BASE_ENDPOINT = 'callout:Nova_Casa_Simulator';
    private static final Integer TIMEOUT_MS = 60000;

    public class SimuladorClientException extends Exception {
        // HTTP status when the failure came from a response; null for callout/parse failures.
        public Integer statusCode;
    }

    /** One parsed GET /telemetry page. */
    public class Pagina {
        // Each element of "data" that is a JSON object, untyped. Field mapping is TelemetriaIngesta's job.
        public List<Map<String, Object>> mensajes = new List<Map<String, Object>>();
        // Elements of "data" that were not JSON objects and were skipped.
        public Integer descartados = 0;
        public Boolean hayMas = false;
        // Only set when hayMas is true. Sensitive: do not log.
        public String siguienteCursor;
        public Integer pollAfterMs;
    }

    /**
     * Starts a simulator session.
     * @param escenario Optional scenario name (for example QA_200). Blank sends no body.
     * @return The session cursor to use for the first page. Sensitive: do not log.
     * @throws SimuladorClientException on callout failure, non-200/201 status or a response without a cursor
     */
    public static String abrirSesion(String escenario) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(BASE_ENDPOINT + '/session');
        request.setMethod('POST');
        request.setTimeout(TIMEOUT_MS);
        request.setHeader('Accept', 'application/json');
        if (String.isNotBlank(escenario)) {
            request.setHeader('Content-Type', 'application/json');
            request.setBody(JSON.serialize(new Map<String, Object>{ 'scenario' => escenario }));
        } else {
            request.setBody('');
        }

        HttpResponse response = enviar(request, 'POST /session');
        Integer status = response.getStatusCode();
        if (status != 200 && status != 201) {
            throw conEstado('POST /session returned status ' + status, status);
        }

        Object cuerpo = parsear(response.getBody(), 'POST /session');
        String cursor = cuerpo instanceof Map<String, Object> ? texto(((Map<String, Object>) cuerpo).get('cursor')) : null;
        if (String.isBlank(cursor)) {
            cursor = response.getHeader(CURSOR_HEADER);
        }
        if (String.isBlank(cursor)) {
            throw new SimuladorClientException('POST /session response has no cursor');
        }
        return cursor;
    }

    /**
     * Reads one page of GET /telemetry.
     * @param cursor Cursor from abrirSesion or from the previous page's siguienteCursor
     * @param limite Page size; clamped to 1..200
     * @throws SimuladorClientException on blank cursor, callout failure, non-200 status,
     *         unparsable body, a body without a "data" array, or hasMore=true without nextCursor
     */
    public static Pagina leerPagina(String cursor, Integer limite) {
        if (String.isBlank(cursor)) {
            throw new SimuladorClientException('GET /telemetry needs a cursor: open a session first');
        }
        Integer tamano = limite == null ? MAX_LIMIT : Math.max(1, Math.min(limite, MAX_LIMIT));

        HttpRequest request = new HttpRequest();
        request.setEndpoint(BASE_ENDPOINT + '/telemetry?limit=' + tamano);
        request.setMethod('GET');
        request.setTimeout(TIMEOUT_MS);
        request.setHeader('Accept', 'application/json');
        request.setHeader(CURSOR_HEADER, cursor);

        HttpResponse response = enviar(request, 'GET /telemetry');
        if (response.getStatusCode() != 200) {
            throw conEstado('GET /telemetry returned status ' + response.getStatusCode(), response.getStatusCode());
        }

        Object cuerpo = parsear(response.getBody(), 'GET /telemetry');
        if (!(cuerpo instanceof Map<String, Object>)) {
            throw new SimuladorClientException('GET /telemetry body is not a JSON object');
        }
        Map<String, Object> raiz = (Map<String, Object>) cuerpo;
        if (!(raiz.get('data') instanceof List<Object>)) {
            throw new SimuladorClientException('GET /telemetry body has no "data" array');
        }

        Pagina pagina = new Pagina();
        for (Object elemento : (List<Object>) raiz.get('data')) {
            if (elemento instanceof Map<String, Object>) {
                pagina.mensajes.add((Map<String, Object>) elemento);
            } else {
                pagina.descartados++;
            }
        }

        if (raiz.get('pagination') instanceof Map<String, Object>) {
            Map<String, Object> paginacion = (Map<String, Object>) raiz.get('pagination');
            Object hasMore = paginacion.get('hasMore');
            pagina.hayMas = hasMore instanceof Boolean && (Boolean) hasMore;
            pagina.pollAfterMs = entero(paginacion.get('pollAfterMs'));
            if (pagina.hayMas) {
                pagina.siguienteCursor = texto(paginacion.get('nextCursor'));
                if (String.isBlank(pagina.siguienteCursor)) {
                    throw new SimuladorClientException('GET /telemetry says hasMore but gave no nextCursor');
                }
            }
        }
        return pagina;
    }

    // ─── Private helpers ─────────────────────────────────────────────────

    private static HttpResponse enviar(HttpRequest request, String operacion) {
        try {
            return new Http().send(request);
        } catch (CalloutException e) {
            throw new SimuladorClientException(operacion + ' callout failed: ' + e.getMessage(), e);
        }
    }

    // The parser's message is dropped on purpose: it can quote the body, and the body carries the cursor.
    private static Object parsear(String cuerpo, String operacion) {
        if (String.isBlank(cuerpo)) {
            throw new SimuladorClientException(operacion + ' returned an empty body');
        }
        try {
            return JSON.deserializeUntyped(cuerpo);
        } catch (JSONException e) {
            throw new SimuladorClientException(operacion + ' returned an unparsable body');
        }
    }

    private static SimuladorClientException conEstado(String mensaje, Integer estado) {
        SimuladorClientException ex = new SimuladorClientException(mensaje);
        ex.statusCode = estado;
        return ex;
    }

    private static String texto(Object valor) {
        return valor == null ? null : String.valueOf(valor);
    }

    private static Integer entero(Object valor) {
        if (valor == null) {
            return null;
        }
        try {
            return Integer.valueOf(String.valueOf(valor));
        } catch (Exception e) {
            return null;
        }
    }
}
