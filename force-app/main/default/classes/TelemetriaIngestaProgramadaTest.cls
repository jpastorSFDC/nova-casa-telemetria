/**
 * Tests for TelemetriaIngestaProgramada (US-201, BR-201, D039). The simulator is never called: the enqueued
 * Queueable is not run (no Test.stopTest), only enqueued, which is all the "one run at a time" guard looks at.
 * The scheduled jobs are created in the test and read back from CronTrigger; they never fire.
 */
@isTest
private class TelemetriaIngestaProgramadaTest {

    private static final String PREFIJO_LIKE = 'Nova Casa - ingesta automatica%';

    // Keeps the enqueued job harmless if the platform ever runs it: an empty session and an empty page.
    private class EmptySimulatorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(request.getEndpoint().contains('/session') ? '{"cursor":"test-cursor"}' : '{"data":[]}');
            return response;
        }
    }

    private static Integer jobsProgramados() {
        return [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :PREFIJO_LIKE];
    }

    private static Integer jobsDeIngesta() {
        return [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta'];
    }

    @isTest
    static void programaDoceJobsCadaCincoMinutosConElEscenarioEnElNombre() {
        Integer total = TelemetriaIngestaProgramada.programar('MIXED', 5);

        Assert.areEqual(12, total, 'Every 5 minutes needs one job per slot of the hour');
        List<CronTrigger> cts = [
            SELECT CronExpression, CronJobDetail.Name
            FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :PREFIJO_LIKE
        ];
        Assert.areEqual(12, cts.size());
        Set<String> expresiones = new Set<String>();
        for (CronTrigger ct : cts) {
            expresiones.add(ct.CronExpression);
            Assert.isTrue(ct.CronJobDetail.Name.contains('MIXED'), 'The scenario is encoded in the job name: ' + ct.CronJobDetail.Name);
        }
        for (Integer minuto = 0; minuto < 60; minuto += 5) {
            Assert.isTrue(expresiones.contains('0 ' + minuto + ' * * * ?'), 'Missing the cron for minute ' + minuto);
        }
    }

    @isTest
    static void programarDosVecesDejaExactamenteDoceJobs() {
        TelemetriaIngestaProgramada.programar('MIXED', 5);
        TelemetriaIngestaProgramada.programar('MIXED', 5);

        Assert.areEqual(12, jobsProgramados(), 'Re-scheduling first aborts the existing jobs of this prefix');
    }

    @isTest
    static void desprogramarDejaCeroYNoTocaOtroJob() {
        System.schedule('Otro job nocturno', '0 0 1 * * ?', new TelemetriaIngestaProgramada());
        TelemetriaIngestaProgramada.programar('BOUNDARIES', 3);
        Assert.areEqual(12, jobsProgramados());

        Integer abortados = TelemetriaIngestaProgramada.desprogramar();

        Assert.areEqual(12, abortados, 'Only the prefix jobs are aborted');
        Assert.areEqual(0, jobsProgramados());
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'Otro job nocturno'],
            'A job outside the prefix is left alone');
    }

    @isTest
    static void executeCapturaElEscenarioYLasPaginasConfigurados() {
        TelemetriaIngestaProgramada.soloCapturar = true;

        new TelemetriaIngestaProgramada('BOUNDARIES', 3).execute(null);

        Assert.areEqual('BOUNDARIES', TelemetriaIngestaProgramada.ultimoEscenario);
        Assert.areEqual(3, TelemetriaIngestaProgramada.ultimasPaginas);
    }

    @isTest
    static void elConstructorSinArgumentosUsaMixedYCincoPaginas() {
        TelemetriaIngestaProgramada.soloCapturar = true;

        new TelemetriaIngestaProgramada().execute(null);

        Assert.areEqual('MIXED', TelemetriaIngestaProgramada.ultimoEscenario, 'Default scenario for Schedule Apex');
        Assert.areEqual(5, TelemetriaIngestaProgramada.ultimasPaginas, 'Default pages per automatic run');
    }

    @isTest
    static void executeEncolaUnaIngesta() {
        Test.setMock(HttpCalloutMock.class, new EmptySimulatorMock());

        new TelemetriaIngestaProgramada('MIXED', 5).execute(null);

        Assert.areEqual(1, jobsDeIngesta(), 'A scheduled run enqueues exactly one ingestion job');
    }

    @isTest
    static void executeNoEncolaSiYaHayUnaCorridaEnCurso() {
        Test.setMock(HttpCalloutMock.class, new EmptySimulatorMock());
        TelemetriaIngesta.iniciar('MIXED', null, null, 1, false); // one run already queued
        Integer antes = jobsDeIngesta();

        new TelemetriaIngestaProgramada('MIXED', 5).execute(null);

        Assert.areEqual(antes, jobsDeIngesta(), 'A second run is not enqueued while one is in progress');
        Assert.areEqual(1, antes);
    }

    @isTest
    static void proximaEjecucionEsNulaSinNadaProgramado() {
        Assert.isNull(TelemetriaIngestaProgramada.proximaEjecucion());
        Assert.isFalse(TelemetriaIngestaProgramada.estado().activa, 'Nothing scheduled means inactive');
    }
}
