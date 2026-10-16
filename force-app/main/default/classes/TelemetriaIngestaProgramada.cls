/**
 * Scheduled ingestion (US-201, BR-201, D040): runs TelemetriaIngesta automatically every 5 minutes so signals
 * arrive on their own, not from a manual button during the demo. The Schedulable makes no callout itself; it only
 * enqueues TelemetriaIngesta (a Queueable, Database.AllowsCallouts), which does the callouts after this
 * transaction commits, exactly as the manual start does.
 *
 * Salesforce cron takes a single minute value per job (a job fires at most once an hour), so "every 5 minutes"
 * needs 12 jobs, one per slot (minute 0, 5, ..., 55). programar() creates them, desprogramar() removes them, and
 * all 12 show in Setup > Scheduled Jobs while each run shows in Setup > Apex Jobs.
 *
 * "One ingestion at a time" is shared with the manual button through TelemetriaIngesta.hayIngestaEnCurso(), so a
 * scheduled run and a manual run never fight over the same simulator cursor (D025, D040).
 *
 * without sharing: cron and async jobs are not record data, there is nothing for sharing to filter. The job runs
 * as whoever schedules it; that user needs Nova_Casa_Simulator_Integration and Create on Senial_Sensor__e (D040).
 */
public without sharing class TelemetriaIngestaProgramada implements Schedulable {

    @TestVisible
    private static final String PREFIJO = 'Nova Casa - ingesta automatica';
    public static final Integer INTERVALO_MINUTOS = 5;
    @TestVisible
    private static final String ESCENARIO_POR_DEFECTO = 'MIXED';
    @TestVisible
    private static final Integer PAGINAS_POR_DEFECTO = 5;

    private final String escenario;
    private final Integer paginas;

    // Test seams. In production soloCapturar is false and the other two are null. A test cannot let the enqueued
    // Queueable run (it would call out), so with soloCapturar execute() records the arguments instead of enqueuing.
    @TestVisible
    private static Boolean soloCapturar = false;
    @TestVisible
    private static String ultimoEscenario;
    @TestVisible
    private static Integer ultimasPaginas;

    /** No-arg constructor for Setup > Apex Classes > Schedule Apex: defaults to MIXED, 5 pages. */
    public TelemetriaIngestaProgramada() {
        this(ESCENARIO_POR_DEFECTO, PAGINAS_POR_DEFECTO);
    }

    public TelemetriaIngestaProgramada(String escenario, Integer paginas) {
        this.escenario = String.isBlank(escenario) ? ESCENARIO_POR_DEFECTO : escenario;
        this.paginas = (paginas == null || paginas < 1) ? PAGINAS_POR_DEFECTO : paginas;
    }

    /**
     * Runs one ingestion, unless one is already queued or running (shared guard, D040). No callout here: the
     * enqueued Queueable makes the callouts after commit.
     */
    public void execute(SchedulableContext contexto) {
        if (TelemetriaIngesta.hayIngestaEnCurso()) {
            System.debug(LoggingLevel.WARN, 'Ingesta programada: ya hay una corrida en curso, no se encola otra');
            return;
        }
        if (soloCapturar) {
            ultimoEscenario = escenario;
            ultimasPaginas = paginas;
            return;
        }
        TelemetriaIngesta.iniciar(escenario, null, null, paginas, false);
    }

    /**
     * Schedules 12 cron jobs (minute 0, 5, ..., 55) so ingestion runs every 5 minutes. Re-running first aborts the
     * existing jobs of this prefix, so calling it twice still leaves exactly 12.
     * @param escenario simulator scenario for every run; blank means MIXED
     * @param paginas pages per run; null or less than 1 means 5
     * @return the number of jobs scheduled
     */
    public static Integer programar(String escenario, Integer paginas) {
        desprogramar();
        String esc = String.isBlank(escenario) ? ESCENARIO_POR_DEFECTO : escenario;
        Integer p = (paginas == null || paginas < 1) ? PAGINAS_POR_DEFECTO : paginas;
        Integer total = 0;
        for (Integer minuto = 0; minuto < 60; minuto += INTERVALO_MINUTOS) {
            String cron = '0 ' + minuto + ' * * * ?';
            System.schedule(nombre(esc, minuto), cron, new TelemetriaIngestaProgramada(esc, p));
            total++;
        }
        return total;
    }

    /** Aborts every scheduled job of this prefix and leaves others alone. @return how many were aborted. */
    public static Integer desprogramar() {
        Integer total = 0;
        for (CronTrigger ct : triggersDe(nombresDeTrabajos().keySet())) {
            System.abortJob(ct.Id);
            total++;
        }
        return total;
    }

    /** The soonest next fire time of the scheduled ingestion, or null when nothing is scheduled. */
    public static Datetime proximaEjecucion() {
        // Sorted by NextFireTime with nulls last, so the first row is the soonest one (null only if all are null).
        List<CronTrigger> triggers = triggersDe(nombresDeTrabajos().keySet());
        return triggers.isEmpty() ? null : triggers[0].NextFireTime;
    }

    /** Snapshot of the automatic ingestion for the operator panel (D040). No cursor, no job ids. */
    public static Estado estado() {
        Map<Id, String> nombres = nombresDeTrabajos();
        List<CronTrigger> triggers = triggersDe(nombres.keySet());
        Estado e = new Estado();
        e.intervaloMinutos = INTERVALO_MINUTOS;
        e.activa = !triggers.isEmpty();
        for (CronTrigger ct : triggers) {
            if (e.proximaEjecucion == null && ct.NextFireTime != null) {
                e.proximaEjecucion = ct.NextFireTime;
            }
            if (e.escenario == null) {
                e.escenario = escenarioDeNombre(nombres.get(ct.CronJobDetailId));
            }
        }
        return e;
    }

    /** Plain snapshot (no @AuraEnabled): IngestaController wraps it for the LWC. */
    public class Estado {
        public Boolean activa = false;
        public Datetime proximaEjecucion;
        public String escenario;
        public Integer intervaloMinutos;
    }

    // Job detail id -> job name, for every job of this prefix. The query intentionally uses NO bind variable and
    // filters by prefix in Apex instead: an inline bind here (WHERE Name LIKE :patron) also threw "Variable does not
    // exist: tmpVar1" under System.runAs with a limited user (IngestaControllerTest). CronJobDetail is a tiny setup
    // table (org-wide scheduled jobs), so reading all rows and filtering by prefix stays cheap.
    private static Map<Id, String> nombresDeTrabajos() {
        Map<Id, String> nombres = new Map<Id, String>();
        for (CronJobDetail detalle : [SELECT Id, Name FROM CronJobDetail]) {
            if (detalle.Name != null && detalle.Name.startsWith(PREFIJO)) {
                nombres.put(detalle.Id, detalle.Name);
            }
        }
        return nombres;
    }

    // Live triggers of those jobs, soonest first (no next fire time goes last).
    private static List<CronTrigger> triggersDe(Set<Id> detalles) {
        return [
            SELECT Id, NextFireTime, CronJobDetailId
            FROM CronTrigger
            WHERE CronJobDetailId IN :detalles AND State != 'DELETED'
            ORDER BY NextFireTime ASC NULLS LAST
        ];
    }

    @TestVisible
    private static String nombre(String escenario, Integer minuto) {
        return PREFIJO + ' ' + escenario + ' :' + (minuto < 10 ? '0' + minuto : String.valueOf(minuto));
    }

    // The scenario is encoded in the job name ("<prefix> <scenario> :MM") so the panel can show it without
    // reading the job's state; returns null when the name does not follow the pattern.
    @TestVisible
    private static String escenarioDeNombre(String nombre) {
        String inicio = PREFIJO + ' ';
        if (String.isBlank(nombre) || !nombre.startsWith(inicio)) {
            return null;
        }
        String resto = nombre.substring(inicio.length());
        Integer corte = resto.indexOf(' :');
        return corte > 0 ? resto.substring(0, corte) : resto;
    }
}
