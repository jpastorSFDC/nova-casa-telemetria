@IsTest
private class TelemetriaIngestaTest {
    private static final String CURSOR_SESION = 'cursor-sesion-001';
    private static final String CURSOR_PAGINA_2 = 'cursor-pagina-002';
    private static final String SESION_JSON = '{"cursor":"' + CURSOR_SESION + '","session":{"scenario":"QA_200","seed":42,"batchSize":2}}';
    private static final String FUENTE = 'nova-casa-simulator';

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

    @IsTest
    static void iniciarPublicaLaPaginaYRegistraCadaIdentidadComoPublicada() {
        Test.setMock(HttpCalloutMock.class, new SimuladorMock()
            .responder('POST /session', null, 201, SESION_JSON)
            .responder('GET /telemetry', CURSOR_SESION, 200, paginaJson(new List<Object>{
                medicion('msg_1', 'dlv_1'), conectividad('msg_2'), medicion(null, 'dlv_3')
            }, CURSOR_PAGINA_2, true)));

        Test.startTest();
        Id jobId = TelemetriaIngesta.iniciar('MIXED', 42, 50, 1);
        Test.stopTest();
        Test.getEventBus().deliver();

        Assert.areEqual('Completed', [SELECT Status FROM AsyncApexJob WHERE Id = :jobId].Status, 'El trabajo encolado debe terminar');
        Assert.isNull(TelemetriaIngesta.demoraEncoladaMinutos, 'Con maximoPaginas=1 no se encadena aunque hasMore sea true');
        Assert.areEqual(3, SenialSensorHandler.senialesRecibidas, 'Se publican los 3 registros, también el que no trae messageId');
        Assert.areEqual(182.7, SenialSensorHandler.clasificacionPorMessageId.get('msg_1').valor, 'El evento lleva measurement.value');
        Assert.areEqual(78, SenialSensorHandler.clasificacionPorMessageId.get('msg_2').valor.intValue(), 'El evento lleva communication.gapSeconds');

        List<Log_Senial__c> logs = [
            SELECT Identidad__c, Resultado__c, Message_Type__c, Delivery_Id__c, Occurred_At__c, Publicado_At__c, Procesado_At__c
            FROM Log_Senial__c
            ORDER BY Identidad__c
        ];
        Assert.areEqual(2, logs.size(), 'El registro sin messageId se publica pero no deja log');
        assertLogPublicado(logs[0], 'msg_1', 'MEASUREMENT', Datetime.newInstanceGmt(2026, 9, 30, 16, 45, 21));
        assertLogPublicado(logs[1], 'msg_2', 'CONNECTIVITY', Datetime.newInstanceGmt(2026, 9, 30, 16, 48, 26));
    }

    @IsTest
    static void unReenvioNoCreaOtroLogNiSobrescribeElExistente() {
        insert new Log_Senial__c(Identidad__c = FUENTE + '|msg_1', Message_Id__c = 'msg_1', Source__c = FUENTE,
            Delivery_Id__c = 'dlv_original', Resultado__c = 'Procesada');
        Test.setMock(HttpCalloutMock.class, new SimuladorMock()
            .responder('POST /session', null, 201, SESION_JSON)
            .responder('GET /telemetry', CURSOR_SESION, 200, paginaJson(new List<Object>{
                medicion('msg_1', 'dlv_reenvio'), medicion('msg_2', 'dlv_2'), medicion('msg_2', 'dlv_2_reenvio')
            }, null, false)));

        Test.startTest();
        TelemetriaIngesta.iniciar('MIXED', 42, 50, 1);
        Test.stopTest();

        Map<String, Log_Senial__c> logPorIdentidad = new Map<String, Log_Senial__c>();
        for (Log_Senial__c log : [SELECT Identidad__c, Delivery_Id__c, Resultado__c FROM Log_Senial__c]) {
            logPorIdentidad.put(log.Identidad__c, log);
        }
        Assert.areEqual(2, logPorIdentidad.size(), 'Debe haber un solo log por identidad');
        Assert.areEqual('dlv_original', logPorIdentidad.get(FUENTE + '|msg_1').Delivery_Id__c, 'El log existente no se sobrescribe');
        Assert.areEqual('Procesada', logPorIdentidad.get(FUENTE + '|msg_1').Resultado__c, 'El reenvío no cambia el resultado');
        Assert.areEqual('dlv_2', logPorIdentidad.get(FUENTE + '|msg_2').Delivery_Id__c, 'Dentro de la página queda la primera entrega');
    }

    @IsTest
    static void iniciarRechazaParametrosInvalidosSinEncolar() {
        assertParametroInvalido(' ', 50, 1, 'escenario');
        assertParametroInvalido('MIXED', 0, 1, 'tamanoLote');
        assertParametroInvalido('MIXED', SimuladorClient.TAMANO_LOTE_MAXIMO + 1, 1, 'tamanoLote');
        assertParametroInvalido('MIXED', 50, null, 'maximoPaginas');
        assertParametroInvalido('MIXED', 50, TelemetriaIngesta.MAXIMO_PAGINAS + 1, 'maximoPaginas');
        Assert.areEqual(0, Limits.getQueueableJobs(), 'Un parámetro inválido no debe encolar trabajos');
    }

    @IsTest
    static void encadenaLaSiguientePaginaConLaEsperaEnMinutos() {
        Test.setMock(HttpCalloutMock.class, new SimuladorMock()
            .responder('POST /session', null, 201, SESION_JSON)
            .responder('GET /telemetry', CURSOR_SESION, 200, paginaJson(1, CURSOR_PAGINA_2, true)));

        Test.startTest();
        TelemetriaIngesta.iniciar('BOUNDARIES', 42, 50, 2);
        Test.stopTest();

        Assert.areEqual(1, TelemetriaIngesta.demoraEncoladaMinutos, 'pollAfterMs=5000 se redondea hacia arriba a 1 minuto');
    }

    @IsTest
    static void reabreLaSesionUnaVezSiElCursorVence() {
        SimuladorMock mock = new SimuladorMock()
            .responder('POST /session', null, 201, SESION_JSON)
            .responder('POST /session', null, 201, SESION_JSON.replace(CURSOR_SESION, CURSOR_PAGINA_2))
            .responder('GET /telemetry', CURSOR_SESION, 409, '{"title":"Cursor alterado, expirado o incompatible"}')
            .responder('GET /telemetry', CURSOR_PAGINA_2, 200, paginaJson(new List<Object>{ medicion('msg_1', 'dlv_1') }, null, false));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new TelemetriaIngesta('MIXED', 42, 50, 1).execute(null);
        Test.stopTest();

        Assert.areEqual(4, mock.peticiones.size(), 'Debe abrir sesión, recibir 409, abrir otra y pedir la página');
        Assert.areEqual(1, [SELECT COUNT() FROM Log_Senial__c], 'La página de la sesión nueva se publica');
    }

    @IsTest
    static void reintentaUnRateLimitConLaEsperaDelSimulador() {
        HttpResponse limite = respuesta(429, '{"title":"Demasiadas solicitudes"}');
        limite.setHeader('Retry-After', '90');
        Test.setMock(HttpCalloutMock.class, new SimuladorMock()
            .responder('POST /session', null, 201, SESION_JSON)
            .responder('GET /telemetry', CURSOR_SESION, limite));

        Test.startTest();
        new TelemetriaIngesta('MIXED', 42, 50, 1).execute(null);
        Test.stopTest();

        Assert.areEqual(2, TelemetriaIngesta.demoraEncoladaMinutos, '90 s de Retry-After se redondean a 2 minutos');
        Assert.areEqual(0, [SELECT COUNT() FROM Log_Senial__c], 'Sin página no hay logs');
    }

    @IsTest
    static void seDetieneSinReintentarSiLasCredencialesSonRechazadas() {
        Test.setMock(HttpCalloutMock.class, new SimuladorMock().responder('POST /session', null, 401, 'Unauthorized'));

        Test.startTest();
        try {
            new TelemetriaIngesta('MIXED', 42, 50, 1).execute(null);
            Assert.fail('Un 401 debe detener la ingesta');
        } catch (SimuladorClient.SimuladorException e) {
            Assert.areEqual(401, e.codigoEstado, e.getMessage());
        }
        Test.stopTest();

        Assert.isNull(TelemetriaIngesta.demoraEncoladaMinutos, 'Un 401 no se reintenta');
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

    private static void assertParametroInvalido(String escenario, Integer tamanoLote, Integer maximoPaginas, String parametro) {
        try {
            TelemetriaIngesta.iniciar(escenario, null, tamanoLote, maximoPaginas);
            Assert.fail('Se esperaba IllegalArgumentException por ' + parametro);
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains(parametro), e.getMessage());
        }
    }

    private static void assertLogPublicado(Log_Senial__c log, String messageId, String tipo, Datetime ocurrido) {
        Assert.areEqual(FUENTE + '|' + messageId, log.Identidad__c, 'La identidad es source|messageId');
        Assert.areEqual('Publicada', log.Resultado__c, messageId + ' debe quedar Publicada');
        Assert.areEqual(tipo, log.Message_Type__c, messageId + ' conserva su messageType');
        Assert.areEqual(ocurrido, log.Occurred_At__c, messageId + ' guarda el occurredAt de origen');
        Assert.isNotNull(log.Publicado_At__c, messageId + ' guarda cuándo se publicó');
        Assert.isTrue(log.Publicado_At__c > log.Occurred_At__c, 'La fecha de publicación es nuestra, no la de origen');
        Assert.isNull(log.Procesado_At__c, 'El procesamiento lo marca el handler después');
    }

    private static Map<String, Object> medicion(String messageId, String deliveryId) {
        return new Map<String, Object>{
            'deliveryId' => deliveryId, 'messageId' => messageId, 'messageType' => 'MEASUREMENT', 'source' => FUENTE,
            'building' => new Map<String, Object>{ 'id' => 'BLD-BAQ-001', 'name' => 'Edificio Nova Caribe', 'city' => 'Barranquilla' },
            'asset' => new Map<String, Object>{ 'id' => 'AST-BAQ-ENERGY-001', 'type' => 'ENERGY_METER' },
            'sensorId' => 'SNS-BAQ-ENERGY-001',
            'measurement' => new Map<String, Object>{ 'type' => 'ENERGY_CONSUMPTION', 'value' => 182.7, 'unit' => 'KWH_PER_15_MIN' },
            'occurredAt' => '2026-09-30T16:45:21.000Z', 'publishedAt' => '2026-09-30T16:45:24.826Z'
        };
    }

    private static Map<String, Object> conectividad(String messageId) {
        return new Map<String, Object>{
            'deliveryId' => 'dlv_' + messageId, 'messageId' => messageId, 'messageType' => 'CONNECTIVITY', 'source' => FUENTE,
            'building' => new Map<String, Object>{ 'id' => 'BLD-BAQ-001' },
            'asset' => new Map<String, Object>{ 'id' => 'AST-BAQ-CAM-001', 'type' => 'SECURITY_CAMERA' },
            'sensorId' => 'SNS-BAQ-CAM-001',
            'communication' => new Map<String, Object>{
                'status' => 'HEALTHY', 'gapSeconds' => 78, 'lastSeenAt' => '2026-09-30T16:47:09.163Z', 'episodeId' => 'EPI-BAQ-hb'
            },
            'occurredAt' => '2026-09-30T16:48:26.000Z', 'publishedAt' => '2026-09-30T16:48:27.163Z'
        };
    }

    private static String paginaJson(Integer registros, String siguienteCursor, Boolean hayMas) {
        List<Object> data = new List<Object>();
        for (Integer i = 0; i < registros; i++) {
            data.add(new Map<String, Object>{ 'messageId' => 'msg_' + i, 'messageType' => 'MEASUREMENT' });
        }
        return paginaJson(data, siguienteCursor, hayMas);
    }

    private static String paginaJson(List<Object> data, String siguienteCursor, Boolean hayMas) {
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
        private final Map<String, List<HttpResponse>> respuestasPorRuta = new Map<String, List<HttpResponse>>();
        private final List<HttpRequest> peticiones = new List<HttpRequest>();

        private SimuladorMock responder(String ruta, String cursor, Integer codigo, String cuerpo) {
            return responder(ruta, cursor, respuesta(codigo, cuerpo));
        }

        // Varias respuestas para la misma ruta y cursor se entregan en orden; la última se repite.
        private SimuladorMock responder(String ruta, String cursor, HttpResponse response) {
            String clave = ruta + '|' + cursor;
            if (!respuestasPorRuta.containsKey(clave)) {
                respuestasPorRuta.put(clave, new List<HttpResponse>());
            }
            respuestasPorRuta.get(clave).add(response);
            return this;
        }

        public HttpResponse respond(HttpRequest request) {
            peticiones.add(request);
            String ruta = request.getMethod() + ' ' + request.getEndpoint().removeStart('callout:Nova_Casa_Simulator');
            List<HttpResponse> respuestas = respuestasPorRuta.get(ruta + '|' + request.getHeader('X-Simulator-Cursor'));
            if (respuestas == null) {
                return respuesta(400, '{"title":"Solicitud inválida","detail":"Ruta o cursor no esperado: ' + ruta + '"}');
            }
            return respuestas.size() > 1 ? respuestas.remove(0) : respuestas[0];
        }
    }
}
