/**
 * Admin-only entry point to pull signals from the simulator from the operator screen (D020), instead of
 * Execute Anonymous. It only checks the custom permission and starts TelemetriaIngesta; the ingestion itself keeps
 * running as the integration user and does not depend on who pressed the button (BR-208 covers this path separately).
 *
 * The caller also needs Nova_Casa_Simulator_Integration (Named Credential principal) and Create on Senial_Sensor__e,
 * exactly as with TelemetriaIngesta.iniciar from a console.
 */
public with sharing class IngestaController {

    public static final String PERM_INGESTA = 'Nova_Casa_Traer_Senales';

    // Scenarios of the simulator contract (docs/muestras/catalog.json).
    @TestVisible private static final List<String> SCENARIOS = new List<String>{
        'MIXED', 'QA_200', 'BOUNDARIES', 'CRITICAL_BURST', 'LATE_MESSAGES',
        'DUPLICATES', 'CONFLICT', 'INVALID_DATA', 'CAMERA_OUTAGE'
    };
    @TestVisible private static final Integer MAX_PAGES = 25;
    @TestVisible private static final Set<String> ACTIVE_JOB_STATUSES = new Set<String>{ 'Queued', 'Preparing', 'Processing', 'Holding' };

    @TestVisible private static final String NO_PERMISSION = 'No tienes permiso para traer señales.';
    @TestVisible private static final String INVALID_SCENARIO = 'El escenario no es válido.';
    @TestVisible private static final String ALREADY_RUNNING = 'Ya hay una ingesta en curso. Espera a que termine antes de lanzar otra.';
    @TestVisible private static final String START_FAILED = 'No se pudo iniciar la ingesta. Revisa que tengas acceso a la credencial del simulador.';
    @TestVisible private static final String STATUS_FAILED = 'No se pudo leer el estado de la ingesta.';

    public class Inicio {
        @AuraEnabled public Id jobId { get; private set; }
        @AuraEnabled public Datetime iniciadaEn { get; private set; }
        public Inicio(Id jobId, Datetime iniciadaEn) {
            this.jobId = jobId;
            this.iniciadaEn = iniciadaEn;
        }
    }

    /**
     * What the last run did, from the counters TelemetriaIngesta keeps in Platform Cache (D025). Counters and flags
     * only: no cursor. Explains a run that registered no new signals, because a duplicate has no new log row.
     */
    public class Detalle {
        @AuraEnabled public Integer paginas { get; private set; }
        @AuraEnabled public Integer recibidos { get; private set; }
        @AuraEnabled public Integer yaExistentes { get; private set; }
        @AuraEnabled public Boolean sesionContinuada { get; private set; }
        @AuraEnabled public Boolean sesionReiniciada { get; private set; }
        @AuraEnabled public Boolean cacheNoDisponible { get; private set; }
        @AuraEnabled public Boolean flujoTerminado { get; private set; }
        @AuraEnabled public Integer interrumpidaPorEstado { get; private set; }
        @AuraEnabled public Integer logsFallidos { get; private set; }
        @AuraEnabled public Integer noPublicadosPorLog { get; private set; }
        @AuraEnabled public Integer fallosPublicacion { get; private set; }
        @AuraEnabled public Boolean cursorSinAvanzar { get; private set; }
        public Detalle(TelemetriaIngesta.Resumen r) {
            this.paginas = r.paginas;
            this.recibidos = r.recibidos;
            this.yaExistentes = r.yaExistentes;
            this.sesionContinuada = r.sesionContinuada;
            this.sesionReiniciada = r.sesionReiniciada;
            this.cacheNoDisponible = r.cacheNoDisponible;
            this.flujoTerminado = r.flujoTerminado;
            this.interrumpidaPorEstado = r.interrumpidaPorEstado;
            this.logsFallidos = r.logsFallidos;
            this.noPublicadosPorLog = r.noPublicadosPorLog;
            this.fallosPublicacion = r.fallosPublicacion;
            this.cursorSinAvanzar = r.cursorSinAvanzar;
        }
    }

    public class Estado {
        @AuraEnabled public Boolean enCurso { get; private set; }
        @AuraEnabled public Integer total { get; private set; }
        @AuraEnabled public Map<String, Integer> porResultado { get; private set; }
        // Null when there is no summary of this run (cache unavailable, or the job has not written one yet).
        @AuraEnabled public Detalle detalle { get; private set; }
        public Estado(Boolean enCurso, Map<String, Integer> porResultado) {
            this.enCurso = enCurso;
            this.porResultado = porResultado;
            this.total = 0;
            for (Integer n : porResultado.values()) {
                this.total += n;
            }
        }
    }

    /**
     * Starts an ingestion run. Refuses when another one is still queued or running ("one person at a time").
     * @param escenario one of the contract scenarios
     * @param paginas pages to read, 1 to 25; null means the ingestion default
     * @param reiniciar true clears the saved simulator session first, so the run starts from the simulator's first
     *        message; false or null continues from where the last run stopped (D025)
     */
    @AuraEnabled
    public static Inicio traerSenales(String escenario, Integer paginas, Boolean reiniciar) {
        if (!FeatureManagement.checkPermission(PERM_INGESTA)) {
            throw safeError(NO_PERMISSION);
        }
        if (String.isBlank(escenario) || !SCENARIOS.contains(escenario)) {
            throw safeError(INVALID_SCENARIO);
        }
        Integer pages = (paginas == null || paginas < 1) ? null : Math.min(paginas, MAX_PAGES);
        if (hayIngestaEnCurso()) {
            throw safeError(ALREADY_RUNNING);
        }
        try {
            Datetime started = Datetime.now();
            Id jobId = TelemetriaIngesta.iniciar(escenario, null, null, pages, reiniciar == true);
            return new Inicio(jobId, started);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'traerSenales: ' + e.getTypeName());
            throw safeError(START_FAILED);
        }
    }

    /**
     * Progress of a run: whether a job is still active and how many log rows were written since `desde`, by result.
     * Not cacheable: it is polled.
     */
    @AuraEnabled
    public static Estado estadoIngesta(Datetime desde) {
        if (!FeatureManagement.checkPermission(PERM_INGESTA)) {
            throw safeError(NO_PERMISSION);
        }
        try {
            Datetime since = desde == null ? Datetime.now().addHours(-1) : desde;
            Map<String, Integer> byResult = new Map<String, Integer>();
            for (AggregateResult ar : [
                SELECT Resultado__c result, COUNT(Id) n FROM Log_Senial__c
                WHERE CreatedDate >= :since WITH USER_MODE GROUP BY Resultado__c
            ]) {
                String key = (String) ar.get('result');
                byResult.put(key == null ? 'Sin resultado' : key, (Integer) ar.get('n'));
            }
            Estado estado = new Estado(hayIngestaEnCurso(), byResult);
            estado.detalle = detalleDesde(since);
            return estado;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'estadoIngesta: ' + e.getTypeName());
            throw safeError(STATUS_FAILED);
        }
    }

    // The summary of the run that started at or after `since`; null when there is none or it cannot be read.
    @TestVisible
    private static Detalle detalleDesde(Datetime since) {
        try {
            String resumenJson = SesionSimulador.leerResumen();
            if (String.isBlank(resumenJson)) {
                return null;
            }
            TelemetriaIngesta.Resumen resumen = (TelemetriaIngesta.Resumen) JSON.deserialize(resumenJson, TelemetriaIngesta.Resumen.class);
            if (resumen.actualizadoEn == null || resumen.actualizadoEn < since) {
                return null; // left by an earlier run
            }
            return new Detalle(resumen);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'detalleDesde: ' + e.getTypeName());
            return null;
        }
    }

    // AsyncApexJob is not sharing-controlled for the admin; the name filter keeps other queueables out.
    @TestVisible
    private static Boolean hayIngestaEnCurso() {
        return [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'TelemetriaIngesta' AND Status IN :ACTIVE_JOB_STATUSES
            WITH SYSTEM_MODE
        ] > 0;
    }

    private static AuraHandledException safeError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
