/**
 * Tests for TelemetriaIngestaProgramada (US-201, BR-201, D040). The simulator is never called: the enqueued
 * Queueable is not run (no Test.stopTest), only enqueued, which is all the "one run at a time" guard looks at.
 * The scheduled jobs are created in the test and read back from CronTrigger; they never fire. The panel marker goes
 * through SesionSimulador.memoriaDePrueba because Platform Cache holds nothing in Apex tests.
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

    private static void conCacheEnMemoria() {
        SesionSimulador.memoriaDePrueba = new Map<String, String>();
    }

    private static Integer jobsProgramados() {
        return [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :PREFIJO_LIKE];
    }

    private static Integer jobsDeIngesta() {
        return [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta'];
    }

    @isTest
    static void programaDoceJobsCadaCincoMinutosConElEscenarioEnElNombre() {
        conCacheEnMemoria();

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
        conCacheEnMemoria();
        TelemetriaIngestaProgramada.programar('MIXED', 5);
        TelemetriaIngestaProgramada.programar('MIXED', 5);

        Assert.areEqual(12, jobsProgramados(), 'Re-scheduling first aborts the existing jobs of this prefix');
    }

    @isTest
    static void desprogramarDejaCeroYNoTocaOtroJob() {
        conCacheEnMemoria();
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
        conCacheEnMemoria();
        TelemetriaIngestaProgramada.soloCapturar = true;

        new TelemetriaIngestaProgramada('BOUNDARIES', 3).execute(null);

        Assert.areEqual('BOUNDARIES', TelemetriaIngestaProgramada.ultimoEscenario);
        Assert.areEqual(3, TelemetriaIngestaProgramada.ultimasPaginas);
    }

    @isTest
    static void elConstructorSinArgumentosUsaMixedYCincoPaginas() {
        conCacheEnMemoria();
        TelemetriaIngestaProgramada.soloCapturar = true;

        new TelemetriaIngestaProgramada().execute(null);

        Assert.areEqual('MIXED', TelemetriaIngestaProgramada.ultimoEscenario, 'Default scenario for Schedule Apex');
        Assert.areEqual(5, TelemetriaIngestaProgramada.ultimasPaginas, 'Default pages per automatic run');
    }

    @isTest
    static void executeEncolaUnaIngesta() {
        conCacheEnMemoria();
        Test.setMock(HttpCalloutMock.class, new EmptySimulatorMock());

        new TelemetriaIngestaProgramada('MIXED', 5).execute(null);

        Assert.areEqual(1, jobsDeIngesta(), 'A scheduled run enqueues exactly one ingestion job');
    }

    @isTest
    static void executeNoEncolaSiYaHayUnaCorridaEnCurso() {
        conCacheEnMemoria();
        Test.setMock(HttpCalloutMock.class, new EmptySimulatorMock());
        TelemetriaIngesta.iniciar('MIXED', null, null, 1, false); // one run already queued
        Integer antes = jobsDeIngesta();

        new TelemetriaIngestaProgramada('MIXED', 5).execute(null);

        Assert.areEqual(antes, jobsDeIngesta(), 'A second run is not enqueued while one is in progress');
        Assert.areEqual(1, antes);
    }

    @isTest
    static void sinNadaProgramadoElEstadoEsInactivoYNoHayProximaEjecucion() {
        conCacheEnMemoria();

        Assert.isNull(TelemetriaIngestaProgramada.proximaEjecucion());
        TelemetriaIngestaProgramada.Estado estado = TelemetriaIngestaProgramada.estado();
        Assert.isFalse(estado.activa, 'No marker means inactive');
        Assert.isNull(estado.escenario);
        Assert.areEqual(TelemetriaIngestaProgramada.INTERVALO_MINUTOS, estado.intervaloMinutos);
    }

    @isTest
    static void programarDejaElMarcadorYDesprogramarLoQuita() {
        conCacheEnMemoria();
        System.schedule('Otro job nocturno', '0 0 1 * * ?', new TelemetriaIngestaProgramada());
        Datetime antes = Datetime.now();

        TelemetriaIngestaProgramada.programar('BOUNDARIES', 3);

        TelemetriaIngestaProgramada.Estado estado = TelemetriaIngestaProgramada.estado();
        Datetime despues = Datetime.now();
        Assert.isTrue(estado.activa, 'With the jobs scheduled the automatic ingestion is on');
        Assert.areEqual('BOUNDARIES', estado.escenario, 'The scenario comes from the marker');
        Assert.areEqual(TelemetriaIngestaProgramada.INTERVALO_MINUTOS, estado.intervaloMinutos);
        Assert.isNotNull(estado.proximaEjecucion);
        Assert.isTrue(estado.proximaEjecucion > antes, 'The next run is in the future');
        Assert.isTrue(estado.proximaEjecucion <= despues.addMinutes(TelemetriaIngestaProgramada.INTERVALO_MINUTOS),
            'With a slot every 5 minutes the next one is at most 5 minutes away');

        TelemetriaIngestaProgramada.desprogramar();

        Assert.isFalse(TelemetriaIngestaProgramada.estado().activa, 'Clearing the jobs clears the marker');
        Assert.isNull(TelemetriaIngestaProgramada.proximaEjecucion());
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'Otro job nocturno'],
            'A job outside the prefix is left alone');
    }

    @isTest
    static void laProximaEjecucionCaeEnUnaFranjaDeLosCronsYNuncaEsLaActual() {
        // The jobs fire at second 0 of minutes 0, 5, ..., 55, so the shown next run must be one of those marks.
        Datetime desdeUnaFranja = Datetime.newInstance(2026, 10, 16, 12, 5, 0);
        Datetime desdeAntesDeUna = Datetime.newInstance(2026, 10, 16, 12, 4, 59);
        Datetime desdeMedioDeFranja = Datetime.newInstance(2026, 10, 16, 12, 7, 30);
        Datetime desdeFinDeHora = Datetime.newInstance(2026, 10, 16, 12, 59, 0);

        Assert.areEqual(Datetime.newInstance(2026, 10, 16, 12, 10, 0), TelemetriaIngestaProgramada.proximaFranja(desdeUnaFranja),
            'On a slot the next run is the following one, never the current one');
        Assert.areEqual(Datetime.newInstance(2026, 10, 16, 12, 5, 0), TelemetriaIngestaProgramada.proximaFranja(desdeAntesDeUna));
        Assert.areEqual(Datetime.newInstance(2026, 10, 16, 12, 10, 0), TelemetriaIngestaProgramada.proximaFranja(desdeMedioDeFranja));
        Assert.areEqual(Datetime.newInstance(2026, 10, 16, 13, 0, 0), TelemetriaIngestaProgramada.proximaFranja(desdeFinDeHora),
            'The slot after 12:55 is the top of the next hour');
    }

    @isTest
    static void cadaCorridaProgramadaRefrescaElMarcadorYCuraUnaCacheVacia() {
        conCacheEnMemoria(); // as if the cache had evicted the marker while the jobs are still scheduled
        TelemetriaIngestaProgramada.soloCapturar = true;
        Assert.isFalse(TelemetriaIngestaProgramada.estado().activa, 'Precondition: marker gone');

        new TelemetriaIngestaProgramada('QA_200', 2).execute(null);

        TelemetriaIngestaProgramada.Estado estado = TelemetriaIngestaProgramada.estado();
        Assert.isTrue(estado.activa, 'A scheduled run brings the marker back');
        Assert.areEqual('QA_200', estado.escenario);
    }

    @isTest
    static void laCorridaQueSeOmitePorHaberOtraEnCursoTambienRefrescaElMarcador() {
        conCacheEnMemoria();
        Test.setMock(HttpCalloutMock.class, new EmptySimulatorMock());
        TelemetriaIngesta.iniciar('MIXED', null, null, 1, false); // one run already queued

        new TelemetriaIngestaProgramada('MIXED', 5).execute(null);

        Assert.isTrue(TelemetriaIngestaProgramada.estado().activa, 'A skipped run still proves the schedule is alive');
    }

    @isTest
    static void sinCacheProgramarSigueAgendandoYElEstadoEsInactivo() {
        SesionSimulador.simularNoDisponible = true;

        Integer total = TelemetriaIngestaProgramada.programar('MIXED', 5);

        Assert.areEqual(12, total, 'Scheduling does not depend on the cache');
        Assert.areEqual(12, jobsProgramados());
        Assert.isFalse(TelemetriaIngestaProgramada.estado().activa, 'Without cache the panel cannot know, so it shows off');
        Assert.areEqual(12, TelemetriaIngestaProgramada.desprogramar(), 'Unscheduling works without the cache too');
    }
}
