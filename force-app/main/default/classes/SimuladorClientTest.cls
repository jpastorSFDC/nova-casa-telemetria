/**
 * Tests for SimuladorClient. HttpCalloutMock only: the real simulator is never called.
 * Cursors below are obviously fake placeholders, never live values.
 */
@isTest
private class SimuladorClientTest {

    private class Mock implements HttpCalloutMock {
        public Integer status;
        public String body;
        public Map<String, String> headers = new Map<String, String>();
        public Boolean lanzar = false;
        public HttpRequest ultima;

        public Mock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            ultima = request;
            if (lanzar) {
                throw new CalloutException('simulated timeout');
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            for (String nombre : headers.keySet()) {
                response.setHeader(nombre, headers.get(nombre));
            }
            return response;
        }
    }

    private static Mock preparar(Integer status, String body) {
        Mock mock = new Mock(status, body);
        Test.setMock(HttpCalloutMock.class, mock);
        return mock;
    }

    private static final String DOS_MENSAJES =
        '{"schemaVersion":"1.0","data":[{"messageId":"m1","source":"s"},{"messageId":"m2","source":"s"}],' +
        '"pagination":{"nextCursor":"fake-cursor-2","hasMore":true,"pollAfterMs":10000}}';

    @isTest
    static void leerPaginaParseaMensajesYAvanzaElCursor() {
        Mock mock = preparar(200, DOS_MENSAJES);
        Test.startTest();
        SimuladorClient.Pagina pagina = SimuladorClient.leerPagina('fake-cursor-1', 200);
        Test.stopTest();

        Assert.areEqual(2, pagina.mensajes.size());
        Assert.areEqual('m1', pagina.mensajes[0].get('messageId'));
        Assert.isTrue(pagina.hayMas);
        Assert.areEqual('fake-cursor-2', pagina.siguienteCursor);
        Assert.areEqual(10000, pagina.pollAfterMs);
        Assert.areEqual(0, pagina.descartados);
        Assert.areEqual('GET', mock.ultima.getMethod());
        Assert.areEqual('callout:Nova_Casa_Simulator/telemetry?limit=200', mock.ultima.getEndpoint());
        Assert.areEqual('fake-cursor-1', mock.ultima.getHeader(SimuladorClient.CURSOR_HEADER));
        Assert.isNull(mock.ultima.getHeader('Authorization'), 'The token comes from the Named Credential, never from Apex');
    }

    @isTest
    static void ultimaPaginaNoTrae_cursorSiguiente() {
        preparar(200, '{"data":[{"messageId":"m1"}],"pagination":{"nextCursor":"fake-cursor-9","hasMore":false}}');
        Test.startTest();
        SimuladorClient.Pagina pagina = SimuladorClient.leerPagina('fake-cursor-1', 200);
        Test.stopTest();

        Assert.isFalse(pagina.hayMas);
        Assert.isNull(pagina.siguienteCursor, 'With hasMore=false the stream must not advance');
    }

    @isTest
    static void paginaVaciaEsValida() {
        preparar(200, '{"data":[],"pagination":{"nextCursor":"fake-cursor-2","hasMore":false}}');
        Test.startTest();
        SimuladorClient.Pagina pagina = SimuladorClient.leerPagina('fake-cursor-1', 200);
        Test.stopTest();

        Assert.isTrue(pagina.mensajes.isEmpty());
        Assert.isFalse(pagina.hayMas);
    }

    @isTest
    static void sinPaginacionNoHayMas() {
        preparar(200, '{"data":[{"messageId":"m1"}]}');
        Test.startTest();
        SimuladorClient.Pagina pagina = SimuladorClient.leerPagina('fake-cursor-1', 200);
        Test.stopTest();

        Assert.areEqual(1, pagina.mensajes.size());
        Assert.isFalse(pagina.hayMas);
    }

    @isTest
    static void elementosQueNoSonObjetosSeDescartan() {
        preparar(200, '{"data":["texto",{"messageId":"m1"},5,null]}');
        Test.startTest();
        SimuladorClient.Pagina pagina = SimuladorClient.leerPagina('fake-cursor-1', 200);
        Test.stopTest();

        Assert.areEqual(1, pagina.mensajes.size());
        Assert.areEqual(3, pagina.descartados);
        Assert.areEqual(3, pagina.descartes.size());
        Assert.areEqual(0, pagina.descartes[0].posicion);
        Assert.areEqual('string', pagina.descartes[0].tipo);
        Assert.areEqual(2, pagina.descartes[1].posicion);
        Assert.areEqual('number', pagina.descartes[1].tipo);
        Assert.areEqual('null', pagina.descartes[2].tipo);
        Assert.areEqual(64, pagina.descartes[0].huella.length(), 'SHA-256 hex, not the element content');
        Assert.isFalse(pagina.descartes[0].huella.contains('texto'));
    }

    @isTest
    static void elLimiteSeAjustaEntre1Y200() {
        Mock mock = preparar(200, '{"data":[]}');
        Test.startTest();
        SimuladorClient.leerPagina('fake-cursor-1', 500);
        Assert.isTrue(mock.ultima.getEndpoint().endsWith('limit=200'));
        SimuladorClient.leerPagina('fake-cursor-1', 0);
        Assert.isTrue(mock.ultima.getEndpoint().endsWith('limit=1'));
        SimuladorClient.leerPagina('fake-cursor-1', null);
        Assert.isTrue(mock.ultima.getEndpoint().endsWith('limit=200'));
        Test.stopTest();
    }

    @isTest
    static void estadoDistintoDe200LanzaExcepcionSinCuerpoNiCursor() {
        for (Integer estado : new List<Integer>{ 204, 401, 404, 429, 500 }) {
            preparar(estado, '{"error":"cuerpo-secreto","echo":"fake-cursor-1"}');
            try {
                SimuladorClient.leerPagina('fake-cursor-1', 200);
                Assert.fail('Expected an exception for status ' + estado);
            } catch (SimuladorClient.SimuladorClientException e) {
                Assert.areEqual(estado, e.statusCode);
                Assert.isTrue(e.getMessage().contains(String.valueOf(estado)));
                Assert.isFalse(e.getMessage().contains('cuerpo-secreto'), 'The body must not leak into the message');
                Assert.isFalse(e.getMessage().contains('fake-cursor-1'), 'The cursor must not leak into the message');
            }
        }
    }

    @isTest
    static void jsonInvalidoLanzaExcepcionSinCitarElCuerpo() {
        preparar(200, '<html>fake-cursor-1 {{{');
        Test.startTest();
        try {
            SimuladorClient.leerPagina('fake-cursor-1', 200);
            Assert.fail('Expected a parse exception');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.isNull(e.statusCode);
            Assert.isTrue(e.getMessage().contains('unparsable'));
            Assert.isFalse(e.getMessage().contains('fake-cursor-1'));
        }
        Test.stopTest();
    }

    @isTest
    static void cuerpoVacioOSinDataLanzaExcepcion() {
        for (String cuerpo : new List<String>{ '', '[]', '{"pagination":{}}', '{"data":{"a":1}}' }) {
            preparar(200, cuerpo);
            try {
                SimuladorClient.leerPagina('fake-cursor-1', 200);
                Assert.fail('Expected an exception for body: ' + cuerpo);
            } catch (SimuladorClient.SimuladorClientException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
    }

    @isTest
    static void hasMoreSinNextCursorViolaElContrato() {
        preparar(200, '{"data":[{"messageId":"m1"}],"pagination":{"hasMore":true}}');
        Test.startTest();
        try {
            SimuladorClient.leerPagina('fake-cursor-1', 200);
            Assert.fail('Expected a contract exception');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.isTrue(e.getMessage().contains('nextCursor'));
        }
        Test.stopTest();
    }

    @isTest
    static void cursorEnBlancoLanzaExcepcion() {
        Test.startTest();
        try {
            SimuladorClient.leerPagina(' ', 200);
            Assert.fail('Expected an exception for a blank cursor');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.isNotNull(e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void falloDeCalloutSeEnvuelve() {
        Mock mock = new Mock(200, '');
        mock.lanzar = true;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        try {
            SimuladorClient.leerPagina('fake-cursor-1', 200);
            Assert.fail('Expected a wrapped callout exception');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.isTrue(e.getMessage().contains('callout failed'));
            Assert.isTrue(e.getMessage().contains('CalloutException'), 'Only the exception type name is kept');
            Assert.isFalse(e.getMessage().contains('simulated timeout'), 'The exception message must not be copied');
            Assert.isFalse(e.getMessage().contains('fake-cursor-1'));
        }
        Test.stopTest();
    }

    @isTest
    static void abrirSesionEnviaElEscenarioYDevuelveElCursor() {
        Mock mock = preparar(200, '{"cursor":"fake-session-cursor"}');
        Test.startTest();
        String cursor = SimuladorClient.abrirSesion('QA_200');
        Test.stopTest();

        Assert.areEqual('fake-session-cursor', cursor);
        Assert.areEqual('POST', mock.ultima.getMethod());
        Assert.areEqual('callout:Nova_Casa_Simulator/session', mock.ultima.getEndpoint());
        Assert.isTrue(mock.ultima.getBody().contains('QA_200'));
        Assert.isNull(mock.ultima.getHeader('Authorization'));
    }

    @isTest
    static void abrirSesionSinEscenarioNoEnviaCuerpo() {
        Mock mock = preparar(201, '{"cursor":"fake-session-cursor"}');
        Test.startTest();
        String cursor = SimuladorClient.abrirSesion(null);
        Test.stopTest();

        Assert.areEqual('fake-session-cursor', cursor);
        Assert.isTrue(String.isBlank(mock.ultima.getBody()));
    }

    @isTest
    static void abrirSesionAceptaElCursorEnLaCabecera() {
        Mock mock = new Mock(200, '{}');
        mock.headers.put(SimuladorClient.CURSOR_HEADER, 'fake-header-cursor');
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        String cursor = SimuladorClient.abrirSesion('QA_200');
        Test.stopTest();

        Assert.areEqual('fake-header-cursor', cursor);
    }

    @isTest
    static void abrirSesionFallaSinCursorOConEstadoMalo() {
        Test.startTest();
        preparar(200, '{"otro":"valor"}');
        try {
            SimuladorClient.abrirSesion('QA_200');
            Assert.fail('Expected an exception when the response has no cursor');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.isTrue(e.getMessage().contains('no cursor'));
        }

        preparar(200, 'no es json');
        try {
            SimuladorClient.abrirSesion('QA_200');
            Assert.fail('Expected a parse exception');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.isTrue(e.getMessage().contains('unparsable'));
        }

        preparar(403, '{"cursor":"fake-session-cursor"}');
        try {
            SimuladorClient.abrirSesion('QA_200');
            Assert.fail('Expected a status exception');
        } catch (SimuladorClient.SimuladorClientException e) {
            Assert.areEqual(403, e.statusCode);
            Assert.isFalse(e.getMessage().contains('fake-session-cursor'));
        }
        Test.stopTest();
    }
}
