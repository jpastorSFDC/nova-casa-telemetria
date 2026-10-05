/**
 * Tests for TelemetriaIngesta. HttpCalloutMock only: the real simulator is never called.
 * Cursors are obviously fake placeholders. Test data uses picklist values that are ACTIVE in nova-cdo
 * (WATER_PUMP, WATER_METER, TECHNICAL_ROOM), not the inactive VENTILATION/PRESSURE.
 *
 * Shape notes: a queueable job does its callouts before its DML, so a test cannot run two jobs of the chain
 * in one method (the second callout would follow uncommitted DML). Each page is therefore tested as its own
 * job, and the next job is read from TelemetriaIngesta.encolados (the Test.isRunningTest() seam).
 */
@isTest
private class TelemetriaIngestaTest {

    private static final String SOURCE = 'nova-casa-simulator';

    private class Mock implements HttpCalloutMock {
        public Integer estadoSesion = 200;
        public String cuerpoSesion = '{"cursor":"fake-session-cursor"}';
        public Integer estadoTelemetria = 200;
        public String cuerpoTelemetria = '{"data":[]}';
        public Integer llamadasSesion = 0;
        public Integer llamadasTelemetria = 0;
        public String ultimoCursorEnviado;

        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            if (request.getEndpoint().contains('/session')) {
                llamadasSesion++;
                response.setStatusCode(estadoSesion);
                response.setBody(cuerpoSesion);
            } else {
                llamadasTelemetria++;
                ultimoCursorEnviado = request.getHeader(SimuladorClient.CURSOR_HEADER);
                response.setStatusCode(estadoTelemetria);
                response.setBody(cuerpoTelemetria);
            }
            return response;
        }
    }

    private static Mock preparar(List<Object> mensajes, String siguiente, Boolean hayMas) {
        Mock mock = new Mock();
        mock.cuerpoTelemetria = pagina(mensajes, siguiente, hayMas);
        Test.setMock(HttpCalloutMock.class, mock);
        return mock;
    }

    private static String pagina(List<Object> mensajes, String siguiente, Boolean hayMas) {
        Map<String, Object> paginacion = new Map<String, Object>{ 'hasMore' => hayMas, 'pollAfterMs' => 10000 };
        if (siguiente != null) {
            paginacion.put('nextCursor', siguiente);
        }
        return JSON.serialize(new Map<String, Object>{
            'schemaVersion' => '1.0',
            'data' => mensajes,
            'pagination' => paginacion
        });
    }

    private static Map<String, Object> mensaje(String messageId) {
        return new Map<String, Object>{
            'deliveryId' => 'dlv_' + messageId,
            'messageId' => messageId,
            'messageType' => 'MEASUREMENT',
            'source' => SOURCE,
            'building' => new Map<String, Object>{ 'id' => 'BLD-TEST-001', 'name' => 'Edificio Test', 'city' => 'Bogota' },
            'asset' => new Map<String, Object>{ 'id' => 'AST-TEST-002', 'name' => 'Bomba test', 'type' => 'WATER_PUMP' },
            'sensorId' => 'SNS-TEST-002',
            'measurement' => new Map<String, Object>{ 'type' => 'WATER_PRESSURE', 'value' => 3.03, 'unit' => 'BAR' },
            'occurredAt' => '2026-09-30T16:46:21.921Z',
            'publishedAt' => '2026-09-30T16:46:25.693Z'
        };
    }

    private static List<Object> mensajes(Integer cantidad, String prefijo) {
        List<Object> lista = new List<Object>();
        for (Integer i = 0; i < cantidad; i++) {
            lista.add(mensaje(prefijo + i));
        }
        return lista;
    }

    private static List<Map<String, Object>> comoMapas(List<Object> lista) {
        List<Map<String, Object>> mapas = new List<Map<String, Object>>();
        for (Object o : lista) {
            mapas.add((Map<String, Object>) o);
        }
        return mapas;
    }

    private static Database.SaveResult resultadoFallido() {
        return (Database.SaveResult) JSON.deserialize(
            '{"success":false,"errors":[{"message":"simulated","statusCode":"UNKNOWN_EXCEPTION","fields":[]}]}',
            Database.SaveResult.class
        );
    }

    private static Database.SaveResult resultadoExitoso() {
        return (Database.SaveResult) JSON.deserialize('{"success":true,"errors":[]}', Database.SaveResult.class);
    }

    @TestSetup
    static void datosPrevios() {
        // Committed before the tests, so a test can still callout afterwards. One message already logged as processed.
        insert new Log_Senial__c(
            Identidad__c = SOURCE + '|msg_dup',
            Source__c = SOURCE,
            Message_Id__c = 'msg_dup',
            Resultado__c = 'Procesada'
        );
        // A user with no access to Log_Senial__c, to prove ingestion does not depend on operator permissions.
        Profile perfil = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User sinPermisos = new User(
            Alias = 'ingtest',
            Email = 'ingesta.test@novacasa-test.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'IngestaSinPermisos',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = perfil.Id,
            TimeZoneSidKey = 'America/Bogota',
            Username = 'ingesta.test.' + String.valueOf(Crypto.getRandomInteger()).replace('-', 'n') + '@novacasa-test.example.com'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert sinPermisos;
        }
    }

    @isTest
    static void iniciarAbreSesionLeeLaPaginaYPublicaConLogPrimero() {
        Mock mock = preparar(mensajes(3, 'msg_a'), 'fake-cursor-2', true);

        Test.startTest();
        Id trabajo = TelemetriaIngesta.iniciar('QA_200', 3);
        Test.stopTest();

        Assert.isNotNull(trabajo);
        Assert.areEqual(1, mock.llamadasSesion);
        Assert.areEqual(1, mock.llamadasTelemetria);
        Assert.areEqual('fake-session-cursor', mock.ultimoCursorEnviado);

        List<Log_Senial__c> filas = [
            SELECT Identidad__c, Resultado__c, Publicado_At__c, Procesado_At__c, Occurred_At__c, Message_Type__c, Delivery_Id__c
            FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_a%' ORDER BY Message_Id__c
        ];
        Assert.areEqual(3, filas.size());
        for (Log_Senial__c fila : filas) {
            Assert.areEqual('Publicada', fila.Resultado__c, 'Published is not processed');
            Assert.isNotNull(fila.Publicado_At__c);
            Assert.isNull(fila.Procesado_At__c);
            Assert.areEqual(Datetime.newInstanceGmt(2026, 9, 30, 16, 46, 21).getTime() / 1000, fila.Occurred_At__c.getTime() / 1000);
            Assert.areEqual('MEASUREMENT', fila.Message_Type__c);
        }
        Assert.areEqual(SOURCE + '|msg_a0', filas[0].Identidad__c);

        Assert.areEqual(3, TelemetriaIngesta.ultimoResumen.publicados);
        Assert.areEqual(0, TelemetriaIngesta.ultimoResumen.fallosPublicacion);
        Assert.areEqual(1, TelemetriaIngesta.encolados.size(), 'hasMore=true must chain the next page');
    }

    @isTest
    static void elCursorAvanzaAlSiguienteTrabajo() {
        Mock mock = preparar(mensajes(2, 'msg_b'), 'fake-cursor-3', true);
        TelemetriaIngesta primero = new TelemetriaIngesta(null, 'fake-cursor-2', 2, 5, new TelemetriaIngesta.Resumen());

        Test.startTest();
        primero.execute(null);
        Test.stopTest();

        Assert.areEqual(0, mock.llamadasSesion, 'A job that already has a cursor must not open a new session');
        Assert.areEqual('fake-cursor-2', mock.ultimoCursorEnviado, 'The request carries the previous page nextCursor');
        Assert.areEqual(1, TelemetriaIngesta.encolados.size());
        TelemetriaIngesta siguiente = TelemetriaIngesta.encolados[0];
        Assert.areEqual('fake-cursor-3', siguiente.cursor);
        Assert.areEqual(3, siguiente.pagina);
        Assert.areEqual(5, siguiente.maxPaginas);
        Assert.areEqual(1, siguiente.acumulado.paginas);
        Assert.areEqual(2, siguiente.acumulado.publicados);
    }

    @isTest
    static void laUltimaPaginaNoEncolaOtroTrabajo() {
        preparar(mensajes(2, 'msg_c'), 'fake-cursor-9', false);
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 2, 5, new TelemetriaIngesta.Resumen());

        Test.startTest();
        trabajo.execute(null);
        Test.stopTest();

        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_c%']);
    }

    @isTest
    static void elTopeDePaginasDetieneLaCadena() {
        preparar(mensajes(1, 'msg_d'), 'fake-cursor-3', true);
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 5, 5, new TelemetriaIngesta.Resumen());

        Test.startTest();
        trabajo.execute(null);
        Test.stopTest();

        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(), 'pagina == maxPaginas: the chain must stop');
        Assert.areEqual(1, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_d%']);
    }

    @isTest
    static void unaPaginaVaciaNoEscribeNadaNiEncola() {
        preparar(new List<Object>(), 'fake-cursor-3', true);
        Integer antes = [SELECT COUNT() FROM Log_Senial__c];
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest();
        trabajo.execute(null);
        Test.stopTest();

        Assert.areEqual(antes, [SELECT COUNT() FROM Log_Senial__c]);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(), 'An empty page ends the run even if hasMore is true');
        Assert.areEqual(0, TelemetriaIngesta.ultimoResumen.publicados);
    }

    @isTest
    static void unEstadoDistintoDe200FallaSinEscribirNiEncolar() {
        Mock mock = new Mock();
        mock.estadoTelemetria = 500;
        mock.cuerpoTelemetria = '{"error":"boom"}';
        Test.setMock(HttpCalloutMock.class, mock);
        Integer antes = [SELECT COUNT() FROM Log_Senial__c];
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest();
        try {
            trabajo.execute(null);
            Assert.fail('Expected the client exception to propagate so the job shows as failed');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(500, e.statusCode);
        }
        Test.stopTest();

        Assert.areEqual(antes, [SELECT COUNT() FROM Log_Senial__c]);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
    }

    @isTest
    static void unJsonInvalidoFallaSinEscribirNiEncolar() {
        Mock mock = new Mock();
        mock.cuerpoTelemetria = '<<not json>>';
        Test.setMock(HttpCalloutMock.class, mock);
        Integer antes = [SELECT COUNT() FROM Log_Senial__c];
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest();
        try {
            trabajo.execute(null);
            Assert.fail('Expected a parse exception');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.isFalse(e.getMessage().contains('fake-cursor-2'));
        }
        Test.stopTest();

        Assert.areEqual(antes, [SELECT COUNT() FROM Log_Senial__c]);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
    }

    @isTest
    static void laSesionFallidaDetieneElTrabajo() {
        Mock mock = new Mock();
        mock.estadoSesion = 401;
        Test.setMock(HttpCalloutMock.class, mock);
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest();
        try {
            trabajo.execute(null);
            Assert.fail('Expected the session failure to propagate');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(401, e.statusCode);
        }
        Test.stopTest();

        Assert.areEqual(0, mock.llamadasTelemetria, 'No page may be read without a session');
    }

    @isTest
    static void losElementosQueNoSonObjetosSeContabilizan() {
        preparar(new List<Object>{ 'texto', mensaje('msg_e0') }, null, false);
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest();
        trabajo.execute(null);
        Test.stopTest();

        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.descartados);
        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.publicados);
    }

    @isTest
    static void masDe200EventosSePublicanEnLotes() {
        List<Object> lista = mensajes(250, 'msg_f');

        Test.startTest();
        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(comoMapas(lista));
        Test.stopTest();

        Assert.areEqual(250, resumen.recibidos);
        Assert.areEqual(250, resumen.logsCreados);
        Assert.areEqual(250, resumen.publicados);
        Assert.areEqual(0, resumen.fallosPublicacion);
        Assert.areEqual(250, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_f%' AND Resultado__c = 'Publicada']);
    }

    @isTest
    static void elFalloDePublicacionMarcaLaFilaComoFallida() {
        List<Object> lista = mensajes(3, 'msg_g');
        TelemetriaIngesta.resultadosForzados = new List<Database.SaveResult>{
            resultadoExitoso(), resultadoFallido(), resultadoExitoso()
        };

        Test.startTest();
        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(comoMapas(lista));
        Test.stopTest();

        Assert.areEqual(2, resumen.publicados);
        Assert.areEqual(1, resumen.fallosPublicacion);
        Map<String, Log_Senial__c> porMensaje = new Map<String, Log_Senial__c>();
        for (Log_Senial__c fila : [SELECT Message_Id__c, Resultado__c, Motivo__c FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_g%']) {
            porMensaje.put(fila.Message_Id__c, fila);
        }
        Assert.areEqual('Publicada', porMensaje.get('msg_g0').Resultado__c);
        Assert.areEqual('Fallida', porMensaje.get('msg_g1').Resultado__c);
        Assert.isTrue(porMensaje.get('msg_g1').Motivo__c.contains('UNKNOWN_EXCEPTION'));
        Assert.areEqual('Publicada', porMensaje.get('msg_g2').Resultado__c);
    }

    @isTest
    static void unReenvioDejaLaFilaExistenteIntactaYSePublicaDeTodosModos() {
        List<Object> lista = new List<Object>{ mensaje('msg_dup'), mensaje('msg_h0'), mensaje('msg_h0') };

        Test.startTest();
        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(comoMapas(lista));
        Test.stopTest();

        Assert.areEqual(1, resumen.logsCreados);
        Assert.areEqual(2, resumen.yaExistentes);
        Assert.areEqual(0, resumen.logsFallidos);
        Assert.areEqual(3, resumen.publicados, 'Resends are published so the subscriber can count them');
        Log_Senial__c existente = [SELECT Resultado__c, Publicado_At__c FROM Log_Senial__c WHERE Identidad__c = :SOURCE + '|msg_dup'];
        Assert.areEqual('Procesada', existente.Resultado__c, 'An existing row must not go back to Publicada');
        Assert.isNull(existente.Publicado_At__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Log_Senial__c WHERE Identidad__c = :SOURCE + '|msg_h0']);
    }

    @isTest
    static void losValoresMuyLargosSeManejanSinLanzar() {
        String largo81 = 'x'.repeat(81);
        Map<String, Object> messageIdLargo = mensaje(largo81);
        Map<String, Object> identidadLarga = mensaje('m'.repeat(45)); // 19 + 1 + 45 = 65 > 60
        Map<String, Object> entregaLarga = mensaje('msg_i2');
        entregaLarga.put('deliveryId', 'd'.repeat(55));
        Map<String, Object> activoLargo = mensaje('msg_i3');
        activoLargo.put('asset', new Map<String, Object>{ 'id' => 'A'.repeat(60), 'type' => 'WATER_PUMP' });
        Map<String, Object> sinMessageId = mensaje('msg_i4');
        sinMessageId.remove('messageId');

        Test.startTest();
        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(
            comoMapas(new List<Object>{ messageIdLargo, identidadLarga, entregaLarga, activoLargo, sinMessageId })
        );
        Test.stopTest();

        Assert.areEqual(1, resumen.omitidosPorLongitud, 'messageId over 80 cannot be published without changing the identity');
        Assert.areEqual(4, resumen.publicados);
        Assert.areEqual(2, resumen.logsCreados, 'Only msg_i2 and msg_i3 have an identity that fits Identidad__c');
        Assert.areEqual(0, resumen.logsFallidos);
        Log_Senial__c conEntrega = [SELECT Delivery_Id__c FROM Log_Senial__c WHERE Message_Id__c = 'msg_i2'];
        Assert.areEqual(40, conEntrega.Delivery_Id__c.length());
    }

    @isTest
    static void laIngestaNoDependeDePermisosDeOperador() {
        User sinPermisos = [SELECT Id FROM User WHERE LastName = 'IngestaSinPermisos' LIMIT 1];
        TelemetriaIngesta.Resumen resumen;

        Test.startTest();
        System.runAs(sinPermisos) {
            resumen = TelemetriaIngesta.procesarPagina(comoMapas(mensajes(2, 'msg_j')));
        }
        Test.stopTest();

        Assert.areEqual(2, resumen.logsCreados);
        Assert.areEqual(2, resumen.publicados);
        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_j%']);
    }

    @isTest
    static void aEventoMapeaMedicionYConectividad() {
        Senial_Sensor__e medicion = TelemetriaIngesta.aEvento(mensaje('msg_k0'));
        Assert.areEqual('msg_k0', medicion.Message_Id__c);
        Assert.areEqual(SOURCE, medicion.Source__c);
        Assert.areEqual('BLD-TEST-001', medicion.Building_Id__c);
        Assert.areEqual('AST-TEST-002', medicion.Asset_Id__c);
        Assert.areEqual('WATER_PUMP', medicion.Asset_Type__c);
        Assert.areEqual('WATER_PRESSURE', medicion.Measurement_Type__c);
        Assert.areEqual('3.03', medicion.Value__c);
        Assert.areEqual('BAR', medicion.Unit__c);
        Assert.areEqual('2026-09-30T16:46:21.921Z', medicion.Occurred_At__c);
        Assert.areEqual('2026-09-30T16:46:25.693Z', medicion.Published_At__c);

        Map<String, Object> conectividad = new Map<String, Object>{
            'deliveryId' => 'dlv_1', 'messageId' => 'msg_k1', 'messageType' => 'CONNECTIVITY', 'source' => SOURCE,
            'building' => new Map<String, Object>{ 'externalId' => 'BLD-TEST-001' },
            'asset' => new Map<String, Object>{ 'externalId' => 'AST-TEST-005', 'type' => 'SECURITY_CAMERA' },
            'sensorId' => 'SNS-TEST-005',
            'communication' => new Map<String, Object>{
                'status' => 'HEALTHY', 'gapSeconds' => 78, 'lastSeenAt' => '2026-09-30T16:47:09.163Z', 'episodeId' => 'EPI-1'
            },
            'occurredAt' => '2026-09-30T16:48:26.037Z'
        };
        Senial_Sensor__e conexion = TelemetriaIngesta.aEvento(conectividad);
        Assert.areEqual('CONNECTIVITY', conexion.Message_Type__c);
        Assert.areEqual('AST-TEST-005', conexion.Asset_Id__c, 'externalId is accepted when id is absent');
        Assert.areEqual('HEALTHY', conexion.Comm_Status__c);
        Assert.areEqual('78', conexion.Gap_Seconds__c);
        Assert.areEqual('2026-09-30T16:47:09.163Z', conexion.Last_Seen_At__c);
        Assert.areEqual('EPI-1', conexion.Episode_Id__c);
        Assert.isNull(conexion.Measurement_Type__c);
        Assert.isNull(conexion.Value__c);
    }

    @isTest
    static void elTopeDePaginasSeAjusta() {
        Assert.areEqual(25, TelemetriaIngesta.topeDePaginas(null));
        Assert.areEqual(25, TelemetriaIngesta.topeDePaginas(0));
        Assert.areEqual(7, TelemetriaIngesta.topeDePaginas(7));
        Assert.areEqual(100, TelemetriaIngesta.topeDePaginas(5000));
    }
}
