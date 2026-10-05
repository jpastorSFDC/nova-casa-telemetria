@IsTest
private class TelemetriaIngestaTest {
    private static final String CURSOR_SESION = 'cursor-sesion-001';
    private static final String CURSOR_PAGINA_2 = 'cursor-pagina-002';
    private static final String SESION_JSON = '{"cursor":"' + CURSOR_SESION + '","session":{"scenario":"QA_200","seed":42,"batchSize":2}}';

    @IsTest
    static void abrirSesionEnviaEscenarioYTamanoSinSemillaNula() {
        SimuladorMock mock = new SimuladorMock().responder('POST /session', null, 201, SESION_JSON);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SimuladorClient.Sesion sesion = SimuladorClient.abrirSesion('QA_200', null, 2);
        Test.stopTest();

        Assert.areEqual(CURSOR_SESION, sesion.cursor, 'Debe devolver el cursor de la sesión');
        Assert.areEqual('QA_200', sesion.escenario, 'Debe devolver el escenario confirmado por el simulador');
        Assert.areEqual(42, sesion.semilla, 'Debe devolver la semilla que eligió el simulador');
        Assert.areEqual(2, sesion.tamanoLote, 'Debe devolver el tamaño de lote de la sesión');
        Map<String, Object> cuerpo = (Map<String, Object>) JSON.deserializeUntyped(mock.peticiones[0].getBody());
        Assert.areEqual('QA_200', cuerpo.get('scenario'), 'El cuerpo debe llevar el escenario');
        Assert.areEqual(2, cuerpo.get('batchSize'), 'El cuerpo debe llevar el tamaño de lote');
        Assert.isFalse(cuerpo.containsKey('seed'), 'Una semilla nula no debe enviarse');
    }

    @IsTest
    static void recorrerSigueElCursorHastaQueNoHayMas() {
        Test.setMock(HttpCalloutMock.class, new SimuladorMock()
            .responder('GET /telemetry', CURSOR_SESION, 200, paginaJson(2, CURSOR_PAGINA_2, true))
            .responder('GET /telemetry', CURSOR_PAGINA_2, 200, paginaJson(1, 'cursor-final', false)));

        Test.startTest();
        List<SimuladorClient.Lote> lotes = SimuladorClient.recorrer(CURSOR_SESION, 10);
        Test.stopTest();

        Assert.areEqual(2, lotes.size(), 'Debe parar en la página con hasMore=false');
        Assert.areEqual(2, lotes[0].registros.size(), 'La primera página trae 2 registros');
        Assert.areEqual(CURSOR_PAGINA_2, lotes[0].siguienteCursor, 'La primera página apunta a la segunda');
        Assert.areEqual(5000, lotes[0].esperaMs, 'Debe leer pollAfterMs');
        Assert.areEqual(1, lotes[1].registros.size(), 'La segunda página trae 1 registro');
        Assert.isFalse(lotes[1].hayMas, 'La última página no tiene más');
    }

    @IsTest
    static void abrirSesionRechazaTamanoDeLoteFueraDeRango() {
        try {
            SimuladorClient.abrirSesion('QA_200', null, SimuladorClient.TAMANO_LOTE_MAXIMO + 1);
            Assert.fail('Un tamaño de lote mayor a 200 debe rechazarse antes del callout');
        } catch (SimuladorClient.SimuladorException e) {
            Assert.isTrue(e.getMessage().contains('entre 1 y 200'), e.getMessage());
            Assert.isNull(e.codigoEstado, 'No debe haber estado HTTP porque no hubo callout');
        }
    }

    @IsTest
    static void pedirLoteExplicaCredencialesRechazadas() {
        Test.setMock(HttpCalloutMock.class, new SimuladorMock().responder('GET /telemetry', CURSOR_SESION, 401, 'Unauthorized'));

        SimuladorClient.SimuladorException error = pedirLoteConError(CURSOR_SESION);

        Assert.areEqual(401, error.codigoEstado, 'Debe exponer el estado HTTP');
        Assert.isTrue(error.getMessage().contains('HTTP 401: credenciales rechazadas'), error.getMessage());
    }

    @IsTest
    static void pedirLoteConCursorVencidoNoExponeElCursor() {
        String problema = '{"title":"Cursor alterado, expirado o incompatible","status":409,"detail":"Cursor ' + CURSOR_SESION + ' vencido"}';
        Test.setMock(HttpCalloutMock.class, new SimuladorMock().responder('GET /telemetry', CURSOR_SESION, 409, problema));

        SimuladorClient.SimuladorException error = pedirLoteConError(CURSOR_SESION);

        Assert.areEqual(409, error.codigoEstado, 'Debe exponer el estado HTTP');
        Assert.isTrue(error.getMessage().contains('abrir una sesión nueva'), error.getMessage());
        Assert.isTrue(error.getMessage().contains('Cursor [cursor] vencido'), 'Debe usar el detail del problema: ' + error.getMessage());
        Assert.isFalse(error.getMessage().contains(CURSOR_SESION), 'El mensaje no debe contener el cursor');
    }

    @IsTest
    static void pedirLoteInformaLaEsperaDeUnRateLimit() {
        HttpResponse limite = respuesta(429, '{"title":"Demasiadas solicitudes"}');
        limite.setHeader('Retry-After', '30');
        Test.setMock(HttpCalloutMock.class, new SimuladorMock().responder('GET /telemetry', CURSOR_SESION, limite));

        SimuladorClient.SimuladorException error = pedirLoteConError(CURSOR_SESION);

        Assert.areEqual(429, error.codigoEstado, 'Debe exponer el estado HTTP');
        Assert.areEqual(30000, error.esperaMs, 'Retry-After en segundos debe convertirse a milisegundos');
        Assert.isTrue(error.getMessage().contains('reintentar en 30000 ms'), error.getMessage());
    }

    @IsTest
    static void pedirLoteRechazaUnJsonInvalido() {
        Test.setMock(HttpCalloutMock.class, new SimuladorMock().responder('GET /telemetry', CURSOR_SESION, 200, 'no-es-json'));

        SimuladorClient.SimuladorException error = pedirLoteConError(CURSOR_SESION);

        Assert.isTrue(error.getMessage().contains('JSON inválido'), error.getMessage());
    }

    private static SimuladorClient.SimuladorException pedirLoteConError(String cursor) {
        Test.startTest();
        try {
            SimuladorClient.pedirLote(cursor);
        } catch (SimuladorClient.SimuladorException e) {
            return e;
        } finally {
            Test.stopTest();
        }
        Assert.fail('Se esperaba SimuladorException');
        return null;
    }

    private static String paginaJson(Integer registros, String siguienteCursor, Boolean hayMas) {
        List<Object> data = new List<Object>();
        for (Integer i = 0; i < registros; i++) {
            data.add(new Map<String, Object>{ 'messageId' => 'msg_' + i, 'messageType' => 'MEASUREMENT' });
        }
        return JSON.serialize(new Map<String, Object>{
            'data' => data,
            'pagination' => new Map<String, Object>{ 'nextCursor' => siguienteCursor, 'hasMore' => hayMas, 'pollAfterMs' => 5000 }
        });
    }

    private static HttpResponse respuesta(Integer codigo, String cuerpo) {
        HttpResponse response = new HttpResponse();
        response.setStatusCode(codigo);
        response.setBody(cuerpo);
        return response;
    }

    private class SimuladorMock implements HttpCalloutMock {
        private final Map<String, HttpResponse> respuestaPorRuta = new Map<String, HttpResponse>();
        private final List<HttpRequest> peticiones = new List<HttpRequest>();

        private SimuladorMock responder(String ruta, String cursor, Integer codigo, String cuerpo) {
            return responder(ruta, cursor, respuesta(codigo, cuerpo));
        }

        private SimuladorMock responder(String ruta, String cursor, HttpResponse response) {
            respuestaPorRuta.put(ruta + '|' + cursor, response);
            return this;
        }

        public HttpResponse respond(HttpRequest request) {
            peticiones.add(request);
            String ruta = request.getMethod() + ' ' + request.getEndpoint().removeStart('callout:Nova_Casa_Simulator');
            HttpResponse response = respuestaPorRuta.get(ruta + '|' + request.getHeader('X-Simulator-Cursor'));
            return response ?? respuesta(400, '{"title":"Solicitud inválida","detail":"Ruta o cursor no esperado: ' + ruta + '"}');
        }
    }
}
