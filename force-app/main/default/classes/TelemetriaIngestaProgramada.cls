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
 * The operator panel does NOT read the scheduled-job tables: the Nova_Casa_Admin persona has no View Setup, so
 * CronJobDetail is not even a queryable object for it. Instead programar() leaves a small marker in Platform Cache
 * (SesionSimulador, the scenario only), every scheduled run refreshes it, and desprogramar() clears it. estado()
 * reads that marker; the next run is the next 5-minute clock slot. The marker can be a few minutes off the real jobs
 * (D040): an abort done by hand in Setup leaves it "on" until it expires (15 min), and an evicted entry shows "off"
 * until the next run rewrites it (at most 5 min).
 *
 * without sharing: cron and async jobs are not record data, there is nothing for sharing to filter. The job runs
 * as whoever schedules it; that user needs Nova_Casa_Simulator_Integration and Create on Senial_Sensor__e (D040).
 * programar() and desprogramar() read the job tables, so they are run by an admin who can (not by the panel).
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
        // Refresh the panel marker first: a run skipped below is still proof that the schedule is alive, and this
        // also brings the marker back if the cache evicted it or the jobs were scheduled from Setup.
        SesionSimulador.guardarProgramacion(escenario);
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
     * existing jobs of this prefix, so calling it twice still leaves exactly 12. Leaves the panel marker "on".
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
        SesionSimulador.guardarProgramacion(esc);
        return total;
    }

    /**
     * Aborts every scheduled job of this prefix (leaves others alone) and clears the panel marker.
     * @return how many jobs were aborted
     */
    public static Integer desprogramar() {
        Integer total = 0;
        for (CronTrigger ct : triggersDelPrefijo()) {
            System.abortJob(ct.Id);
            total++;
        }
        SesionSimulador.borrarProgramacion();
        return total;
    }

    /** The next 5-minute slot while the automatic ingestion is on, or null when it is off. */
    public static Datetime proximaEjecucion() {
        return estado().proximaEjecucion;
    }

    /**
     * Snapshot of the automatic ingestion for the operator panel (D040). No cursor, no job ids. It comes from the
     * marker, not from the job tables (see the class comment), so any user who can call Apex can get it.
     */
    public static Estado estado() {
        Estado e = new Estado();
        e.intervaloMinutos = INTERVALO_MINUTOS;
        String escenarioMarcado = SesionSimulador.leerProgramacion();
        e.activa = String.isNotBlank(escenarioMarcado);
        if (e.activa) {
            e.escenario = escenarioMarcado;
            e.proximaEjecucion = proximaFranja(Datetime.now());
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

    // First 5-minute mark strictly after `desde`. The jobs fire at second 0 of minutes 0, 5, ..., 55, so counting
    // from the epoch lands on the same marks (every current time zone offset is a multiple of 5 minutes) and has no
    // DST gap.
    @TestVisible
    private static Datetime proximaFranja(Datetime desde) {
        Long paso = INTERVALO_MINUTOS * 60000L;
        return Datetime.newInstance((desde.getTime() / paso + 1) * paso);
    }

    // Live triggers of the jobs of this prefix. Only programar() and desprogramar() read them.
    private static List<CronTrigger> triggersDelPrefijo() {
        String patron = PREFIJO + '%';
        return [
            SELECT Id
            FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :patron AND State != 'DELETED'
        ];
    }

    @TestVisible
    private static String nombre(String escenario, Integer minuto) {
        return PREFIJO + ' ' + escenario + ' :' + (minuto < 10 ? '0' + minuto : String.valueOf(minuto));
    }
}
