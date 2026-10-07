/**
 * Tests for TelemetriaIngesta. HttpCalloutMock only: the real simulator is never called.
 * Cursors are obviously fake placeholders. Test data uses picklist values that are ACTIVE in nova-cdo
 * (WATER_PUMP, WATER_METER, TECHNICAL_ROOM), not the inactive VENTILATION/PRESSURE.
 *
 * Shape notes: a queueable job does all its callouts (several pages) before its DML, so a test cannot run two jobs
 * of the chain in one method (the second callout would follow uncommitted DML). Each job is therefore tested on
 * its own, and the next job is read from TelemetriaIngesta.encolados (the soloCapturar seam). To force a
 * continuation job, a test lowers the per-job message budget (maxMensajesForzado) to one page.
 *
 * The saved cursor lives in Platform Cache, which holds nothing in Apex tests: SesionSimulador.memoriaDePrueba
 * (a map) stands in for it, and SesionSimulador.simularNoDisponible simulates a missing cache.
 *
 * SenialSensorTrigger and SenialSensorHandler are deployed in nova-cdo: Test.stopTest() delivers the published
 * events and the handler then rewrites the log rows (test assets do not exist, so 'Publicada' becomes
 * 'Rechazada'). Only the async iniciar test calls startTest/stopTest (it needs them to run the job), and it
 * asserts only fields the ingestion owns. Every other test skips stopTest so no event is delivered
 * and the rows stay exactly as the ingestion left them.
 *
 * Tests that run execute() directly still call Test.startTest() right before it (never stopTest). Without it
 * the callout failed in nova-cdo with a CalloutException (status code lost because no response existed),
 * which is consistent with pending work in the test transaction; startTest fixes it empirically. Not proven.
 */
@isTest
private class TelemetriaIngestaTest {

    private static final String SOURCE = 'nova-casa-simulator';

    private class Mock implements HttpCalloutMock {
        public Integer estadoSesion = 200;
        public String cuerpoSesion = '{"cursor":"fake-session-cursor"}';
        public Integer estadoTelemetria = 200;
        // Statuses for the first GET /telemetry calls, in order; once empty, estadoTelemetria applies.
        public List<Integer> estadosTelemetriaEnOrden = new List<Integer>();
        public String cuerpoTelemetria = '{"data":[]}';
        public Integer llamadasSesion = 0;
        public Integer llamadasTelemetria = 0;
        public String ultimoCursorEnviado;
        public String ultimoCuerpoSesion;
        public String ultimaUrlTelemetria;
        // Per-cursor overrides, so a multi-page run can be scripted: the cursor sent selects the body / status.
        public Map<String, String> cuerpoPorCursor = new Map<String, String>();
        public Map<String, Integer> estadoPorCursor = new Map<String, Integer>();
        public List<String> cursoresLeidos = new List<String>();
        // Limits.getDmlStatements() at the moment each GET /telemetry was answered (same transaction as the job).
        public List<Integer> dmlEnCadaLectura = new List<Integer>();

        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            if (request.getEndpoint().contains('/session')) {
                llamadasSesion++;
                ultimoCuerpoSesion = request.getBody();
                response.setStatusCode(estadoSesion);
                response.setBody(cuerpoSesion);
            } else {
                llamadasTelemetria++;
                ultimaUrlTelemetria = request.getEndpoint();
                ultimoCursorEnviado = request.getHeader(SimuladorClient.CURSOR_HEADER);
                cursoresLeidos.add(ultimoCursorEnviado);
                dmlEnCadaLectura.add(Limits.getDmlStatements());
                Integer estado = estadosTelemetriaEnOrden.isEmpty() ? estadoTelemetria : estadosTelemetriaEnOrden.remove(0);
                if (estadoPorCursor.containsKey(ultimoCursorEnviado)) {
                    estado = estadoPorCursor.get(ultimoCursorEnviado);
                }
                response.setStatusCode(estado);
                response.setBody(cuerpoPorCursor.containsKey(ultimoCursorEnviado) ? cuerpoPorCursor.get(ultimoCursorEnviado) : cuerpoTelemetria);
            }
            return response;
        }
    }

    private static Mock preparar(List<Object> mensajes, String siguiente, Boolean hayMas) {
        Mock mock = new Mock();
        mock.cuerpoTelemetria = pagina(mensajes, siguiente, hayMas);
        Test.setMock(HttpCalloutMock.class, mock);
        TelemetriaIngesta.soloCapturar = true; // a test cannot run a real chain: keep the next job instead
        SesionSimulador.memoriaDePrueba = new Map<String, String>(); // Platform Cache stand-in
        return mock;
    }

    // The key a job started for QA_200 with the default seed and batch size saves its cursor under.
    private static String claveQa200() {
        return SesionSimulador.clave('QA_200', null, 200);
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
        // A publish that failed earlier: the row stays 'Fallida' until the handler decides what to do with a resend.
        insert new Log_Senial__c(
            Identidad__c = SOURCE + '|msg_fallida',
            Source__c = SOURCE,
            Message_Id__c = 'msg_fallida',
            Resultado__c = 'Fallida',
            Motivo__c = 'No se pudo publicar el evento (UNKNOWN_EXCEPTION)'
        );
        // A user with no access to Log_Senial__c, to prove ingestion does not depend on operator permissions.
        // Any standard, non-admin profile will do: no hard-coded profile name, and nothing that grants
        // Modify All Data / View All Data (that would hide a missing-permission bug).
        Profile perfil = [
            SELECT Id FROM Profile
            WHERE UserType = 'Standard' AND PermissionsModifyAllData = false AND PermissionsViewAllData = false
            AND PermissionsCustomizeApplication = false
            ORDER BY Name LIMIT 1
        ];
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
        Mock mock = preparar(mensajes(3, 'msg_a'), null, false);

        Test.startTest();
        Id trabajo = TelemetriaIngesta.iniciar('QA_200', 3);
        Test.stopTest();

        Assert.isNotNull(trabajo);
        Assert.areEqual(1, mock.llamadasSesion);
        Assert.areEqual(1, mock.llamadasTelemetria);
        Assert.areEqual('fake-session-cursor', mock.ultimoCursorEnviado);

        List<Log_Senial__c> filas = [
            SELECT Identidad__c, Publicado_At__c, Occurred_At__c, Message_Type__c, Delivery_Id__c
            FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_a%' ORDER BY Message_Id__c
        ];
        // Resultado__c is not asserted here: stopTest delivers the events to the deployed handler, which owns
        // the row from then on. 'Publicada' before delivery is asserted by the tests that skip stopTest.
        Assert.areEqual(3, filas.size());
        for (Log_Senial__c fila : filas) {
            Assert.isNotNull(fila.Publicado_At__c);
            Assert.areEqual(Datetime.newInstanceGmt(2026, 9, 30, 16, 46, 21).getTime() / 1000, fila.Occurred_At__c.getTime() / 1000);
            Assert.areEqual('MEASUREMENT', fila.Message_Type__c);
        }
        Assert.areEqual(SOURCE + '|msg_a0', filas[0].Identidad__c);

        Assert.areEqual(3, TelemetriaIngesta.ultimoResumen.publicados);
        Assert.areEqual(0, TelemetriaIngesta.ultimoResumen.fallosPublicacion);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(), 'hasMore=false ends the run');
        Assert.areEqual('fake-session-cursor', SesionSimulador.memoriaDePrueba.get(claveQa200()),
            'The session cursor is saved for the next run');
    }

    @isTest
    static void unTrabajoQueAgotaSuPresupuestoDeMensajesEncolaLaContinuacionConElCursor() {
        Mock mock = preparar(mensajes(2, 'msg_b'), 'fake-cursor-3', true);
        TelemetriaIngesta.maxMensajesForzado = 2; // one page of 2 messages fills the job
        TelemetriaIngesta primero = new TelemetriaIngesta(null, 'fake-cursor-2', 2, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        primero.execute(null);

        Assert.areEqual(0, mock.llamadasSesion, 'A job that already has a cursor must not open a new session');
        Assert.areEqual('fake-cursor-2', mock.ultimoCursorEnviado, 'The request carries the previous page nextCursor');
        Assert.areEqual(1, TelemetriaIngesta.encolados.size());
        TelemetriaIngesta siguiente = TelemetriaIngesta.encolados[0];
        Assert.areEqual('fake-cursor-3', siguiente.cursor);
        Assert.areEqual(3, siguiente.pagina);
        Assert.areEqual(5, siguiente.maxPaginas);
        Assert.areEqual(1, siguiente.acumulado.paginas);
        Assert.areEqual(2, siguiente.acumulado.publicados);
        Assert.areEqual(0, TelemetriaIngesta.retrasosCapturados[0], 'pollAfterMs is not honored: no minute delay (D024)');
        Assert.areEqual(1, mock.llamadasTelemetria, 'The job stopped reading at its budget');
        Assert.areEqual('fake-cursor-3', SesionSimulador.memoriaDePrueba.get(SesionSimulador.clave(null, null, 200)),
            'The cursor of the next page is saved even if the continuation job never runs');
    }

    @isTest
    static void laUltimaPaginaNoEncolaOtroTrabajo() {
        preparar(mensajes(2, 'msg_c'), 'fake-cursor-9', false);
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 2, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_c%']);
        Assert.areEqual('fake-cursor-2', SesionSimulador.memoriaDePrueba.get(SesionSimulador.clave(null, null, 200)),
            'At the end of the stream the cursor of the last page stays, so the next run re-polls it');
        Assert.isTrue(TelemetriaIngesta.ultimoResumen.flujoTerminado);
    }

    @isTest
    static void elTopeDePaginasDetieneLaCadena() {
        preparar(mensajes(1, 'tope-'), 'fake-cursor-3', true);
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 5, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(), 'pagina == maxPaginas: the run must stop');
        Assert.areEqual(1, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'tope-%']);
        Assert.areEqual('fake-cursor-3', SesionSimulador.memoriaDePrueba.get(SesionSimulador.clave(null, null, 200)),
            'The next run continues after the last page read');
    }

    @isTest
    static void unaPaginaVaciaNoEscribeNadaNiEncola() {
        preparar(new List<Object>(), 'fake-cursor-3', true);
        Integer antes = [SELECT COUNT() FROM Log_Senial__c];
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(antes, [SELECT COUNT() FROM Log_Senial__c]);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(), 'An empty page ends the run even if hasMore is true');
        Assert.areEqual(0, TelemetriaIngesta.ultimoResumen.publicados);
    }

    @isTest
    static void unEstadoDistintoDe200FallaSinEscribirNiEncolar() {
        Mock mock = new Mock();
        mock.estadoTelemetria = 400;
        mock.cuerpoTelemetria = '{"error":"boom"}';
        Test.setMock(HttpCalloutMock.class, mock);
        Integer antes = [SELECT COUNT() FROM Log_Senial__c];
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        try {
            trabajo.execute(null);
            Assert.fail('Expected the client exception to propagate so the job shows as failed');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(400, e.statusCode);
        }

        Assert.areEqual(antes, [SELECT COUNT() FROM Log_Senial__c]);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
    }

    @isTest
    static void un429ReintentaLaMismaPaginaSinEscribirNada() {
        Mock mock = preparar(mensajes(2, 'r429-'), 'fake-cursor-3', true);
        mock.estadosTelemetriaEnOrden = new List<Integer>{ 429 };
        Integer antes = [SELECT COUNT() FROM Log_Senial__c];
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 4, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, TelemetriaIngesta.encolados.size(), 'A 429 must schedule a retry of the same page');
        TelemetriaIngesta reintento = TelemetriaIngesta.encolados[0];
        Assert.areEqual(4, reintento.pagina, 'The retry reads the same page, not the next one');
        Assert.areEqual('fake-cursor-2', reintento.cursor, 'The retry keeps the same cursor');
        Assert.areEqual(1, reintento.intento);
        Assert.areEqual(1, TelemetriaIngesta.retrasosCapturados[0], 'The retry waits a minute');
        Assert.areEqual(antes, [SELECT COUNT() FROM Log_Senial__c], 'Nothing is written before the page is read');
        Assert.areEqual(0, reintento.acumulado.paginas, 'A failed attempt does not count as a page');
        Assert.areEqual(1, reintento.acumulado.reintentos, 'The retry is visible in the summary');

        // Second failure of the same page: the delay grows to 2 minutes.
        mock.estadosTelemetriaEnOrden = new List<Integer>{ 429 };
        reintento.execute(null);
        Assert.areEqual(2, TelemetriaIngesta.encolados[1].intento);
        Assert.areEqual(2, TelemetriaIngesta.retrasosCapturados[1]);
    }

    @isTest
    static void un503ReintentaYElReintentoLeeLaPagina() {
        Mock mock = preparar(mensajes(2, 'r503-'), null, false);
        mock.estadosTelemetriaEnOrden = new List<Integer>{ 503 };
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);
        TelemetriaIngesta reintento = TelemetriaIngesta.encolados[0];
        TelemetriaIngesta.encolados.clear();
        reintento.execute(null);

        Assert.areEqual(2, mock.llamadasTelemetria);
        Assert.areEqual(2, TelemetriaIngesta.ultimoResumen.publicados, 'The retried page is published once');
        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.paginas);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
    }

    @isTest
    static void alAgotarLosIntentosElTrabajoFalla() {
        Mock mock = preparar(mensajes(1, 'agot-'), null, false);
        mock.estadoTelemetria = 503;
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());
        trabajo.intento = TelemetriaIngesta.MAX_INTENTOS - 1;

        Test.startTest(); // no stopTest: see the class note on event delivery
        try {
            trabajo.execute(null);
            Assert.fail('The last attempt must fail the job, not retry again');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(503, e.statusCode);
        }

        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
    }

    @isTest
    static void unReintentoTambienCuentaParaLaProfundidadDeCola() {
        Mock mock = preparar(mensajes(1, 'prof-'), null, false);
        mock.estadoTelemetria = 429;
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 2, 60, new TelemetriaIngesta.Resumen());
        trabajo.trabajos = 27; // retries and pages share the same chain depth

        Test.startTest(); // no stopTest: see the class note on event delivery
        try {
            trabajo.execute(null);
            Assert.fail('At the local depth ceiling a retry cannot be enqueued');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(429, e.statusCode);
        }

        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
    }

    @isTest
    static void un409AbreUnaSesionNuevaYReleeLaPagina() {
        Mock mock = preparar(mensajes(2, 'r409-'), null, false);
        mock.estadosTelemetriaEnOrden = new List<Integer>{ 409 };
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 'fake-expired-cursor', 3, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, mock.llamadasSesion, 'One new session');
        Assert.areEqual(2, mock.llamadasTelemetria, 'The page is read again');
        Assert.areEqual('fake-session-cursor', mock.ultimoCursorEnviado, 'The reread uses the new cursor');
        Assert.areEqual(2, TelemetriaIngesta.ultimoResumen.publicados);
        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.sesionesReabiertas, 'The reopen is visible in the summary');
    }

    @isTest
    static void unaPaginaYaReabiertaNoReabreLaSesionEnUnReintento() {
        Mock mock = preparar(mensajes(1, 'unavez-'), null, false);
        mock.estadoTelemetria = 409;
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-expired-cursor', 1, 5, new TelemetriaIngesta.Resumen());
        trabajo.sesionReabierta = true;

        Test.startTest(); // no stopTest: see the class note on event delivery
        try {
            trabajo.execute(null);
            Assert.fail('A page that already reopened its session must not reopen it again');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(409, e.statusCode);
        }

        Assert.areEqual(0, mock.llamadasSesion);
    }

    @isTest
    static void un410SeguidoDeOtro410NoAbreUnaTerceraSesion() {
        Mock mock = preparar(mensajes(1, 'r410-'), null, false);
        mock.estadoTelemetria = 410;
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-expired-cursor', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        try {
            trabajo.execute(null);
            Assert.fail('A session that is rejected again must fail the job');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(410, e.statusCode);
        }

        Assert.areEqual(1, mock.llamadasSesion, 'The session is reopened only once per attempt');
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(), 'A 410 is not retried as a job');
    }

    @isTest
    static void laSemillaYElTamanoDeLoteViajanEnLaSesionYEnLaLectura() {
        Mock mock = preparar(mensajes(2, 'param-'), 'fake-cursor-3', true);
        TelemetriaIngesta.maxMensajesForzado = 2; // one page, then a continuation job
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);
        trabajo.semilla = 42;
        trabajo.tamanoLote = 50;

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Map<String, Object> cuerpo = (Map<String, Object>) JSON.deserializeUntyped(mock.ultimoCuerpoSesion);
        Assert.areEqual(42, cuerpo.get('seed'));
        Assert.areEqual(50, cuerpo.get('batchSize'));
        Assert.isTrue(mock.ultimaUrlTelemetria.endsWith('limit=50'), 'The page is requested with the batch size');
        TelemetriaIngesta siguiente = TelemetriaIngesta.encolados[0];
        Assert.areEqual(42, siguiente.semilla, 'The next page keeps the seed');
        Assert.areEqual(50, siguiente.tamanoLote, 'The next page keeps the batch size');
    }

    @isTest
    static void unaSesionReabiertaPideLoMismoQueLaOriginal() {
        Mock mock = preparar(mensajes(1, 'reabre-'), null, false);
        mock.estadosTelemetriaEnOrden = new List<Integer>{ 410 };
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 'fake-expired-cursor', 2, 5, new TelemetriaIngesta.Resumen());
        trabajo.semilla = 42;
        trabajo.tamanoLote = 50;

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Map<String, Object> cuerpo = (Map<String, Object>) JSON.deserializeUntyped(mock.ultimoCuerpoSesion);
        Assert.areEqual(42, cuerpo.get('seed'), 'A replay asks for the same sequence');
        Assert.areEqual(50, cuerpo.get('batchSize'));
    }

    @isTest
    static void unReintentoConservaLaSemillaYElTamanoDeLote() {
        Mock mock = preparar(mensajes(1, 'reint-'), null, false);
        mock.estadosTelemetriaEnOrden = new List<Integer>{ 429 };
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());
        trabajo.semilla = 42;
        trabajo.tamanoLote = 50;

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(42, TelemetriaIngesta.encolados[0].semilla);
        Assert.areEqual(50, TelemetriaIngesta.encolados[0].tamanoLote);
    }

    @isTest
    static void elTamanoDeLoteSeValidaYPorDefectoEs200() {
        Assert.areEqual(200, TelemetriaIngesta.validarTamanoLote(null));
        Assert.areEqual(1, TelemetriaIngesta.validarTamanoLote(1));
        Assert.areEqual(200, TelemetriaIngesta.validarTamanoLote(200));
        for (Integer invalido : new List<Integer>{ 0, -5, 201 }) {
            try {
                TelemetriaIngesta.validarTamanoLote(invalido);
                Assert.fail('Expected IllegalArgumentException for ' + invalido);
            } catch (IllegalArgumentException e) {
                Assert.isTrue(e.getMessage().contains('between 1 and 200'));
            }
        }
        Assert.areEqual(200, new TelemetriaIngesta('QA_200', 3).tamanoLote, 'A job built without parameters asks for 200');
    }

    @isTest
    static void iniciarRechazaUnTamanoDeLoteInvalidoSinEncolar() {
        Test.startTest();
        try {
            TelemetriaIngesta.iniciar('QA_200', 42, 500, 3);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('500'));
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta'], 'Nothing was enqueued');
    }

    @isTest
    static void unJsonInvalidoFallaSinEscribirNiEncolar() {
        Mock mock = new Mock();
        mock.cuerpoTelemetria = '<<not json>>';
        Test.setMock(HttpCalloutMock.class, mock);
        Integer antes = [SELECT COUNT() FROM Log_Senial__c];
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        try {
            trabajo.execute(null);
            Assert.fail('Expected a parse exception');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.isFalse(e.getMessage().contains('fake-cursor-2'));
        }

        Assert.areEqual(antes, [SELECT COUNT() FROM Log_Senial__c]);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
    }

    @isTest
    static void laSesionFallidaDetieneElTrabajo() {
        Mock mock = new Mock();
        mock.estadoSesion = 401;
        Test.setMock(HttpCalloutMock.class, mock);
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        try {
            trabajo.execute(null);
            Assert.fail('Expected the session failure to propagate');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(401, e.statusCode);
        }

        Assert.areEqual(0, mock.llamadasTelemetria, 'No page may be read without a session');
    }

    @isTest
    static void losElementosQueNoSonObjetosDejanUnaFilaRechazada() {
        preparar(new List<Object>{ 'texto', mensaje('msg_e0'), 42 }, null, false);
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 4, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(2, TelemetriaIngesta.ultimoResumen.descartados);
        Assert.areEqual(2, TelemetriaIngesta.ultimoResumen.rechazados);
        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.publicados);
        List<Log_Senial__c> filas = [
            SELECT Identidad__c, Source__c, Message_Id__c, Motivo__c, Publicado_At__c FROM Log_Senial__c
            WHERE Resultado__c = 'Rechazada' AND Identidad__c LIKE 'DESCARTE|%' ORDER BY Motivo__c
        ];
        Assert.areEqual(2, filas.size());
        Assert.isTrue(filas[0].Motivo__c.contains('elemento 0'));
        Assert.areEqual('(descartado)', filas[0].Source__c);
        Assert.areEqual('elemento-0-pagina-4', filas[0].Message_Id__c);
        Assert.isTrue(filas[0].Motivo__c.contains('pagina 4'));
        Assert.isTrue(filas[0].Motivo__c.contains('string'));
        Assert.isTrue(filas[1].Motivo__c.contains('elemento 2'));
        Assert.isNull(filas[0].Publicado_At__c, 'A rejected element was never published');
        Assert.isFalse(filas[0].Motivo__c.contains('texto'), 'The element content is not stored');
    }

    @isTest
    static void masDe200EventosSePublicanEnLotes() {
        List<Object> lista = mensajes(250, 'lote250-');

        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(comoMapas(lista));

        Assert.areEqual(250, resumen.recibidos);
        Assert.areEqual(250, resumen.logsCreados);
        Assert.areEqual(250, resumen.publicados);
        Assert.areEqual(0, resumen.fallosPublicacion);
        Assert.areEqual(250, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'lote250-%' AND Resultado__c = 'Publicada']);
    }

    @isTest
    static void elFalloDePublicacionMarcaLaFilaComoFallida() {
        List<Object> lista = mensajes(3, 'msg_g');
        TelemetriaIngesta.resultadosForzados = new List<Database.SaveResult>{
            resultadoExitoso(), resultadoFallido(), resultadoExitoso()
        };

        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(comoMapas(lista));

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

        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(comoMapas(lista));

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
    static void losValoresMuyLargosSeRechazanConFilaOSeTruncanSinLanzar() {
        Map<String, Object> messageIdLargo = mensaje('x'.repeat(81));
        Map<String, Object> sourceLargo = mensaje('msg_i1');
        sourceLargo.put('source', 's'.repeat(81));
        Map<String, Object> identidadLarga = mensaje('m'.repeat(45)); // 19 + 1 + 45 = 65 > 60
        Map<String, Object> entregaLarga = mensaje('msg_i2');
        entregaLarga.put('deliveryId', 'd'.repeat(55));
        Map<String, Object> activoLargo = mensaje('msg_i3');
        activoLargo.put('asset', new Map<String, Object>{ 'id' => 'A'.repeat(60), 'type' => 'WATER_PUMP' });
        Map<String, Object> sinMessageId = mensaje('msg_i4');
        sinMessageId.remove('messageId');

        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(
            comoMapas(new List<Object>{ messageIdLargo, sourceLargo, identidadLarga, entregaLarga, activoLargo, sinMessageId })
        );

        Assert.areEqual(4, resumen.rechazados);
        Assert.areEqual(2, resumen.publicados);
        Assert.areEqual(2, resumen.logsCreados);
        Assert.areEqual(0, resumen.logsFallidos);
        List<Log_Senial__c> rechazadas = [
            SELECT Identidad__c, Source__c, Message_Id__c, Motivo__c, Publicado_At__c FROM Log_Senial__c
            WHERE Resultado__c = 'Rechazada' AND (Identidad__c LIKE 'ID-LARGA|%' OR Identidad__c LIKE 'SIN-ID|%')
        ];
        Assert.areEqual(4, rechazadas.size());
        for (Log_Senial__c fila : rechazadas) {
            Assert.isTrue(fila.Identidad__c.length() <= 60);
            Assert.isNotNull(fila.Motivo__c);
            Assert.isNull(fila.Publicado_At__c);
            Assert.isTrue(fila.Message_Id__c.length() <= 80, 'Message_Id__c is required and must fit');
            Assert.isTrue(fila.Source__c.length() <= 80, 'Source__c is required and must fit');
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Log_Senial__c WHERE Identidad__c LIKE 'SIN-ID|%' AND Message_Id__c = '(sin messageId)' AND Source__c = :SOURCE]);
        Assert.areEqual(40, [SELECT Delivery_Id__c FROM Log_Senial__c WHERE Message_Id__c = 'msg_i2'].Delivery_Id__c.length());
        Assert.areEqual('Publicada', [SELECT Resultado__c FROM Log_Senial__c WHERE Message_Id__c = 'msg_i3'].Resultado__c);
    }

    @isTest
    static void unMensajeLargoRechazadoDosVecesDejaUnaSolaFila() {
        List<Object> lista = new List<Object>{ mensaje('x'.repeat(81)) };

        TelemetriaIngesta.procesarPagina(comoMapas(lista));
        TelemetriaIngesta.Resumen segunda = TelemetriaIngesta.procesarPagina(comoMapas(lista));

        Assert.areEqual(1, segunda.yaExistentes, 'A replay of a rejected message dedupes on its hash key');
        Assert.areEqual(1, [SELECT COUNT() FROM Log_Senial__c WHERE Identidad__c LIKE 'ID-LARGA|%']);
    }

    @isTest
    static void unInsertDeLogFallidoNoPublicaElEvento() {
        TelemetriaIngesta.identidadesConFalloDeLog = new Set<String>{ SOURCE + '|msg_l1' };
        List<Object> lista = new List<Object>{ mensaje('msg_l0'), mensaje('msg_l1'), mensaje('msg_l2') };

        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(comoMapas(lista));

        Assert.areEqual(2, resumen.logsCreados);
        Assert.areEqual(1, resumen.logsFallidos);
        Assert.areEqual(1, resumen.noPublicadosPorLog, 'No event may go out without a log row');
        Assert.areEqual(2, resumen.publicados);
        Assert.areEqual(0, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c = 'msg_l1']);
        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c IN ('msg_l0', 'msg_l2') AND Resultado__c = 'Publicada']);
    }

    @isTest
    static void unInsertDeLogFallidoQuedaEnElResumenDelTrabajo() {
        TelemetriaIngesta.identidadesConFalloDeLog = new Set<String>{ SOURCE + '|msg_m0' };
        preparar(mensajes(2, 'msg_m'), 'fake-cursor-3', true);
        TelemetriaIngesta.maxMensajesForzado = 2;
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.noPublicadosPorLog);
        Assert.isTrue(TelemetriaIngesta.ultimoResumen.cursorSinAvanzar);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(), 'No continuation past messages that must be read again');
    }

    @isTest
    static void elCursorNoAvanzaSiUnInsertDeLogFallo() {
        TelemetriaIngesta.identidadesConFalloDeLog = new Set<String>{ SOURCE + '|msg_cf1' };
        preparar(mensajes(2, 'msg_cf'), 'fake-cursor-next', true);
        SesionSimulador.guardar(claveQa200(), 'fake-cursor-prev');
        // One page: the mock serves the same page on every read, so more pages would count the failure again.
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 1);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.logsFallidos);
        Assert.isTrue(TelemetriaIngesta.ultimoResumen.cursorSinAvanzar);
        Assert.areEqual('fake-cursor-prev', SesionSimulador.memoriaDePrueba.get(claveQa200()),
            'A failed log insert must keep the previous cursor so the next run reads the page again');
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
    }

    @isTest
    static void elCursorNoAvanzaSiUnaPublicacionFallo() {
        preparar(mensajes(2, 'msg_cp'), 'fake-cursor-next', true);
        TelemetriaIngesta.resultadosForzados = new List<Database.SaveResult>{ resultadoExitoso(), resultadoFallido() };
        SesionSimulador.guardar(claveQa200(), 'fake-cursor-prev');
        // One page: the mock serves the same page on every read, so more pages would count the failure again.
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 1);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.fallosPublicacion);
        Assert.isTrue(TelemetriaIngesta.ultimoResumen.cursorSinAvanzar);
        Assert.areEqual('fake-cursor-prev', SesionSimulador.memoriaDePrueba.get(claveQa200()),
            'A failed publish must keep the previous cursor so the next run reads the page again');
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
    }

    @isTest
    static void elCursorAvanzaSiNingunMensajeFallo() {
        preparar(mensajes(2, 'msg_ok'), 'fake-cursor-next', true);
        SesionSimulador.guardar(claveQa200(), 'fake-cursor-prev');
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 1);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.isFalse(TelemetriaIngesta.ultimoResumen.cursorSinAvanzar);
        Assert.areEqual('fake-cursor-next', SesionSimulador.memoriaDePrueba.get(claveQa200()));
    }

    @isTest
    static void unTrabajoNoEmpiezaUnaPaginaQueSePasariaDelPresupuestoDeMensajes() {
        Mock mock = preparar(mensajes(2, 'msg_bp'), 'fake-cursor-b', true);
        mock.cuerpoPorCursor.put('fake-cursor-b', pagina(mensajes(2, 'msg_bq'), 'fake-cursor-c', true));
        TelemetriaIngesta.maxMensajesForzado = 100; // 2 read so far, and a page of up to 200 would not fit
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, mock.llamadasTelemetria, 'Only the first page: the second could exceed the budget');
        Assert.areEqual(1, TelemetriaIngesta.encolados.size(), 'The rest goes to a continuation job');
    }

    @isTest
    static void unTrabajoQueAgotaSuTiempoDeLecturaDejaDeLeerYEncolaLaContinuacion() {
        Mock mock = preparar(mensajes(2, 'msg_tp'), 'fake-cursor-b', true);
        mock.cuerpoPorCursor.put('fake-cursor-b', pagina(mensajes(2, 'msg_tq'), 'fake-cursor-c', true));
        TelemetriaIngesta.msTranscurridosForzados = 45000L;
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, mock.llamadasTelemetria, 'The first page is always read; the time budget stops the rest');
        Assert.areEqual(1, TelemetriaIngesta.encolados.size());
        Assert.areEqual('fake-cursor-b', SesionSimulador.memoriaDePrueba.get(claveQa200()));
    }

    @isTest
    static void elMismoMensajeConOtroContenidoSePublicaYNoTocaLaFilaExistente() {
        Map<String, Object> cambiado = mensaje('msg_dup');
        cambiado.put('measurement', new Map<String, Object>{ 'type' => 'WATER_PRESSURE', 'value' => 9.99, 'unit' => 'BAR' });

        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(comoMapas(new List<Object>{ cambiado }));

        // Ingestion does not judge content: the conflict (same identity, different fingerprint) is the handler's call.
        Assert.areEqual(1, resumen.yaExistentes);
        Assert.areEqual(1, resumen.publicados, 'The changed resend must reach the handler so it can flag the conflict');
        Assert.areEqual('9.99', TelemetriaIngesta.aEvento(cambiado).Value__c);
        Log_Senial__c fila = [SELECT Resultado__c, Huella__c, Occurred_At__c FROM Log_Senial__c WHERE Identidad__c = :SOURCE + '|msg_dup'];
        Assert.areEqual('Procesada', fila.Resultado__c);
        Assert.isNull(fila.Huella__c);
        Assert.isNull(fila.Occurred_At__c, 'The existing row was not overwritten with the new content');
    }

    @isTest
    static void unReenvioDeUnaFilaFallidaNoLaTocaYSePublica() {
        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.procesarPagina(
            comoMapas(new List<Object>{ mensaje('msg_fallida') })
        );

        Assert.areEqual(0, resumen.logsCreados);
        Assert.areEqual(1, resumen.yaExistentes);
        Assert.areEqual(1, resumen.publicados);
        Log_Senial__c fila = [SELECT Resultado__c, Publicado_At__c FROM Log_Senial__c WHERE Identidad__c = :SOURCE + '|msg_fallida'];
        Assert.areEqual('Fallida', fila.Resultado__c, 'Ingestion leaves the retry decision to the handler');
        Assert.isNull(fila.Publicado_At__c);
    }

    @isTest
    static void laProfundidadMaximaDeColaDetieneLaCadena() {
        preparar(mensajes(2, 'msg_n'), 'fake-cursor-3', true);
        TelemetriaIngesta.maxMensajesForzado = 2;
        TelemetriaIngesta.profundidadForzada = true;
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(), 'At max stack depth the next job must not be enqueued');
        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_n%'], 'The current page is still ingested');
        Assert.areEqual('fake-cursor-3', SesionSimulador.memoriaDePrueba.get(SesionSimulador.clave(null, null, 200)),
            'Without a continuation job the saved cursor lets the next run carry on');
    }

    @isTest
    static void laProfundidadLocalMaximaDetieneLaCadenaSinSenalDePlataforma() {
        preparar(mensajes(2, 'msg_o'), 'fake-cursor-3', true);
        TelemetriaIngesta.maxMensajesForzado = 2;
        // pagina == PROFUNDIDAD_LOCAL_MAXIMA (27), maxPaginas well above it, profundidadForzada left at its
        // default (null): only the local backstop can stop this chain, not topeDePaginas and not the platform seam.
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 27, 60, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(),
            'At the local depth backstop the next job must not be enqueued, even without a platform signal');
        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_o%'], 'The current page is still ingested');
    }

    @isTest
    static void unaPaginaDe200SeProcesaEnUnSoloExecute() {
        preparar(mensajes(200, 'msg_p'), 'fake-cursor-3', true);
        TelemetriaIngesta.maxMensajesForzado = 200;
        TelemetriaIngesta trabajo = new TelemetriaIngesta(null, 'fake-cursor-2', 1, 5, new TelemetriaIngesta.Resumen());

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);
        Integer dml = Limits.getDmlStatements();

        Assert.isTrue(dml <= 5, 'Bulk: a page costs a handful of DML statements, not one per message (used ' + dml + ')');
        Assert.areEqual(200, TelemetriaIngesta.ultimoResumen.logsCreados);
        Assert.areEqual(200, TelemetriaIngesta.ultimoResumen.publicados);
        Assert.areEqual(200, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_p%' AND Resultado__c = 'Publicada']);
        Assert.areEqual(1, TelemetriaIngesta.encolados.size());
    }

    @isTest
    static void laIngestaNoDependeDePermisosDeOperador() {
        User sinPermisos = [SELECT Id FROM User WHERE LastName = 'IngestaSinPermisos' LIMIT 1];
        TelemetriaIngesta.Resumen resumen;

        System.runAs(sinPermisos) {
            resumen = TelemetriaIngesta.procesarPagina(comoMapas(mensajes(2, 'msg_j')));
        }

        // The DML is SYSTEM_MODE, so the rows exist whatever the user can see.
        Assert.areEqual(2, resumen.logsCreados);
        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_j%']);
        // Publishing is the open point: this user may lack Create on Senial_Sensor__e. Either way nothing is lost:
        // an event that did not go out leaves its row as 'Fallida' (checked in the next assertion). Which branch
        // the platform takes for this profile is not confirmed yet (see D013).
        Assert.areEqual(2, resumen.publicados + resumen.fallosPublicacion);
        Assert.areEqual(resumen.fallosPublicacion, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'msg_j%' AND Resultado__c = 'Fallida']);
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

    // ─── HP-05 / D024: the session continues across runs, one job reads several pages ───────────────

    @isTest
    static void unaCorridaNuevaContinuaDesdeElCursorGuardadoSinAbrirSesion() {
        Mock mock = preparar(mensajes(2, 'cont-'), null, false);
        SesionSimulador.memoriaDePrueba.put(claveQa200(), 'fake-saved-cursor');
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(0, mock.llamadasSesion, 'A saved cursor means no POST /session: the stream is not restarted');
        Assert.areEqual('fake-saved-cursor', mock.ultimoCursorEnviado, 'The first page is read from the saved cursor');
        Assert.isTrue(TelemetriaIngesta.ultimoResumen.sesionContinuada, 'The summary says the session was continued');
        Assert.isFalse(TelemetriaIngesta.ultimoResumen.sesionReiniciada);
    }

    @isTest
    static void sinCursorGuardadoAbreUnaSesionNueva() {
        Mock mock = preparar(mensajes(2, 'nueva-'), null, false);
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, mock.llamadasSesion);
        Assert.areEqual('fake-session-cursor', mock.ultimoCursorEnviado);
        Assert.isFalse(TelemetriaIngesta.ultimoResumen.sesionContinuada);
        Assert.isFalse(TelemetriaIngesta.ultimoResumen.cacheNoDisponible);
    }

    @isTest
    static void unSoloTrabajoLeeVariasPaginasYGuardaElCursorDeLaSiguiente() {
        Mock mock = preparar(mensajes(2, 'multi1-'), 'fake-cursor-b', true);
        mock.cuerpoPorCursor.put('fake-cursor-b', pagina(mensajes(2, 'multi2-'), 'fake-cursor-c', true));
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 2); // two pages asked for

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, mock.llamadasSesion);
        Assert.areEqual(new List<String>{ 'fake-session-cursor', 'fake-cursor-b' }, mock.cursoresLeidos,
            'The second page is read with the nextCursor of the first, in the same job');
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty(), 'No second job is needed');
        Assert.areEqual(2, TelemetriaIngesta.ultimoResumen.paginas);
        Assert.areEqual(4, TelemetriaIngesta.ultimoResumen.recibidos);
        Assert.areEqual(4, TelemetriaIngesta.ultimoResumen.logsCreados);
        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'multi1-%']);
        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'multi2-%']);
        Assert.areEqual('fake-cursor-c', SesionSimulador.memoriaDePrueba.get(claveQa200()),
            'The run ends where the next one has to start');
    }

    @isTest
    static void todosLosCalloutsVanAntesDelPrimerDml() {
        Mock mock = preparar(mensajes(2, 'orden1-'), 'fake-cursor-b', true);
        mock.cuerpoPorCursor.put('fake-cursor-b', pagina(mensajes(2, 'orden2-'), 'fake-cursor-c', true));
        mock.cuerpoPorCursor.put('fake-cursor-c', pagina(mensajes(2, 'orden3-'), 'fake-cursor-d', true));
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        Integer dmlAntes = Limits.getDmlStatements();
        trabajo.execute(null);

        Assert.areEqual(3, mock.dmlEnCadaLectura.size(), 'Three pages, three reads, one job');
        for (Integer dml : mock.dmlEnCadaLectura) {
            Assert.areEqual(dmlAntes, dml, 'A callout must never follow DML: it would fail in production');
        }
        Assert.isTrue(Limits.getDmlStatements() > dmlAntes, 'The DML came after the callouts');
        Assert.areEqual(6, TelemetriaIngesta.ultimoResumen.publicados);
    }

    @isTest
    static void reiniciarBorraElCursorGuardadoTrasEncolar() {
        preparar(mensajes(1, 'reinic-'), null, false);
        SesionSimulador.memoriaDePrueba.put(claveQa200(), 'fake-saved-cursor');
        SesionSimulador.memoriaDePrueba.put(SesionSimulador.clave('MIXED', null, 200), 'fake-other-scenario-cursor');

        Test.startTest();
        TelemetriaIngesta.iniciar('QA_200', null, null, 1, true);

        Assert.isFalse(SesionSimulador.memoriaDePrueba.containsKey(claveQa200()), 'The saved session of this scenario is cleared');
        Assert.isTrue(SesionSimulador.memoriaDePrueba.containsKey(SesionSimulador.clave('MIXED', null, 200)),
            'Another scenario keeps its own session');
        Test.stopTest();

        Assert.isTrue(TelemetriaIngesta.ultimoResumen.sesionReiniciada);
        Assert.isFalse(TelemetriaIngesta.ultimoResumen.sesionContinuada);
    }

    @isTest
    static void iniciarSinReiniciarConservaElCursorYElTrabajoLoUsa() {
        Mock mock = preparar(mensajes(1, 'sinreinic-'), null, false);
        SesionSimulador.memoriaDePrueba.put(claveQa200(), 'fake-saved-cursor');

        Test.startTest();
        TelemetriaIngesta.iniciar('QA_200', null, null, 1, false);
        Test.stopTest();

        Assert.areEqual(0, mock.llamadasSesion, 'The queued job continued the saved session');
        Assert.areEqual('fake-saved-cursor', mock.ultimoCursorEnviado);
        Assert.isTrue(TelemetriaIngesta.ultimoResumen.sesionContinuada);
    }

    @isTest
    static void laSesionGuardadaDependeDeEscenarioSemillaYLote() {
        Set<String> claves = new Set<String>{
            SesionSimulador.clave('QA_200', null, 200),
            SesionSimulador.clave('MIXED', null, 200),
            SesionSimulador.clave('QA_200', 42, 200),
            SesionSimulador.clave('QA_200', null, 50)
        };
        Assert.areEqual(4, claves.size(), 'Different scenario, seed or batch size must not share a stream');
        Assert.areEqual(SesionSimulador.clave('QA_200', 42, 50), SesionSimulador.clave('QA_200', 42, 50), 'The key is stable');
    }

    @isTest
    static void sinCacheLaCorridaAbreUnaSesionNuevaYLoDiceEnElResumen() {
        Mock mock = preparar(mensajes(2, 'sincache-'), null, false);
        SesionSimulador.simularNoDisponible = true;
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(1, mock.llamadasSesion, 'No cache: a new session is opened, the run does not fail');
        Assert.isTrue(TelemetriaIngesta.ultimoResumen.cacheNoDisponible, 'The summary says why the session was not continued');
        Assert.isFalse(TelemetriaIngesta.ultimoResumen.sesionContinuada);
        Assert.areEqual(2, TelemetriaIngesta.ultimoResumen.logsCreados, 'The run still ingests');
    }

    @isTest
    static void un410ConElCursorGuardadoLoBorraYAbreUnaSesionNueva() {
        Mock mock = preparar(mensajes(2, 'exp410-'), null, false);
        mock.estadoPorCursor.put('fake-saved-cursor', 410);
        SesionSimulador.memoriaDePrueba.put(claveQa200(), 'fake-saved-cursor');
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(new List<String>{ 'fake-saved-cursor', 'fake-session-cursor' }, mock.cursoresLeidos);
        Assert.areEqual(1, mock.llamadasSesion, 'One new session after the saved one expired');
        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.sesionesReabiertas);
        Assert.isTrue(TelemetriaIngesta.ultimoResumen.sesionContinuada, 'The run did start from the saved cursor');
        Assert.areEqual('fake-session-cursor', SesionSimulador.memoriaDePrueba.get(claveQa200()),
            'The expired cursor is gone: the new session is what gets saved');
        Assert.areEqual(2, TelemetriaIngesta.ultimoResumen.publicados);
    }

    @isTest
    static void unFalloALaMitadEscribeLoLeidoGuardaElCursorYReintentaLaPaginaQueFallo() {
        Mock mock = preparar(mensajes(2, 'mitad1-'), 'fake-cursor-b', true);
        mock.estadoPorCursor.put('fake-cursor-b', 503);
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'mitad1-%'], 'Page 1 was written');
        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.paginas);
        Assert.areEqual(1, TelemetriaIngesta.encolados.size(), 'The failing page is retried as a job');
        TelemetriaIngesta reintento = TelemetriaIngesta.encolados[0];
        Assert.areEqual(2, reintento.pagina, 'The retry is for page 2, the one that failed');
        Assert.areEqual('fake-cursor-b', reintento.cursor);
        Assert.areEqual(1, reintento.intento, 'Page 2 spends its first retry, not the attempts of page 1');
        Assert.areEqual('fake-cursor-b', SesionSimulador.memoriaDePrueba.get(claveQa200()), 'The next run resumes at page 2');
    }

    @isTest
    static void unErrorNoReintentableDespuesDeLeerPaginasLasEscribeYNoFallaElTrabajo() {
        Mock mock = preparar(mensajes(2, 'mitad2-'), 'fake-cursor-b', true);
        mock.estadoPorCursor.put('fake-cursor-b', 400);
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null); // must not throw: an uncaught exception would roll page 1 back

        Assert.areEqual(2, [SELECT COUNT() FROM Log_Senial__c WHERE Message_Id__c LIKE 'mitad2-%']);
        Assert.areEqual(400, TelemetriaIngesta.ultimoResumen.interrumpidaPorEstado);
        Assert.isTrue(TelemetriaIngesta.encolados.isEmpty());
        Assert.areEqual('fake-cursor-b', SesionSimulador.memoriaDePrueba.get(claveQa200()));
    }

    @isTest
    static void unTrabajoQueFallaSinLeerNadaNoTocaElCursorGuardado() {
        Mock mock = preparar(mensajes(1, 'nada-'), null, false);
        mock.estadoTelemetria = 400;
        SesionSimulador.memoriaDePrueba.put(claveQa200(), 'fake-saved-cursor');
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        try {
            trabajo.execute(null);
            Assert.fail('Expected the client exception');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(400, e.statusCode);
        }

        Assert.areEqual('fake-saved-cursor', SesionSimulador.memoriaDePrueba.get(claveQa200()));
    }

    @isTest
    static void elCursorNuncaApareceEnElResumenNiEnLosMensajes() {
        String secreto = 'SECRET-CURSOR-XYZ';
        Mock mock = preparar(mensajes(2, 'leak-'), secreto + '-next', true);
        mock.estadoPorCursor.put(secreto + '-next', 400);
        SesionSimulador.memoriaDePrueba.put(claveQa200(), secreto);
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 3);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        TelemetriaIngesta.Resumen resumen = TelemetriaIngesta.ultimoResumen;
        Assert.isFalse(TelemetriaIngesta.resumenComoTexto(resumen).contains(secreto), 'The debug summary line has counters only');
        Assert.isFalse(JSON.serialize(resumen).contains(secreto), 'The summary kept in the cache has counters only');
        Assert.isFalse(SesionSimulador.leerResumen().contains(secreto), 'The cached summary has counters only');
        Assert.isFalse(JSON.serialize(new IngestaController.Detalle(resumen)).contains(secreto), 'The UI detail has counters only');

        // A failure with nothing read: the exception text carries the status only.
        mock.estadoTelemetria = 500;
        mock.estadoPorCursor.clear();
        TelemetriaIngesta sinIntentos = new TelemetriaIngesta('QA_200', secreto, 1, 3, new TelemetriaIngesta.Resumen());
        sinIntentos.intento = TelemetriaIngesta.MAX_INTENTOS - 1;
        try {
            sinIntentos.execute(null);
            Assert.fail('Expected the client exception');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.isFalse(e.getMessage().contains(secreto), 'The exception message must not carry the cursor');
        }
    }

    @isTest
    static void unaPaginaConElMismoMensajeQueYaEstabaSoloSumaYaExistentes() {
        // The bug this story fixes: a run that re-reads stored messages registers nothing new, and now says why.
        preparar(new List<Object>{ mensaje('msg_dup') }, null, false);
        TelemetriaIngesta trabajo = new TelemetriaIngesta('QA_200', 1);

        Test.startTest(); // no stopTest: see the class note on event delivery
        trabajo.execute(null);

        Assert.areEqual(0, TelemetriaIngesta.ultimoResumen.logsCreados);
        Assert.areEqual(1, TelemetriaIngesta.ultimoResumen.yaExistentes);
    }

    @isTest
    static void elTopeDePaginasSeAjusta() {
        Assert.areEqual(25, TelemetriaIngesta.topeDePaginas(null));
        Assert.areEqual(25, TelemetriaIngesta.topeDePaginas(0));
        Assert.areEqual(7, TelemetriaIngesta.topeDePaginas(7));
        Assert.areEqual(100, TelemetriaIngesta.topeDePaginas(5000));
    }
}
