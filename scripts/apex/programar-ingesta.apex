// Turns on automatic ingestion (US-201, BR-201, D040): schedules 12 jobs (minute 0, 5, ..., 55) so
// TelemetriaIngesta runs every 5 minutes. Run as a user with Nova_Casa_Simulator_Integration and Create on
// Senial_Sensor__e (the jobs run as whoever schedules them). Re-running leaves exactly 12 jobs.
//
//   sf apex run --file scripts/apex/programar-ingesta.apex -o nova-cdo
//
// Change the scenario or pages per run here if needed (default MIXED, 5 pages).
Integer total = TelemetriaIngestaProgramada.programar('MIXED', 5);
System.debug('Scheduled jobs: ' + total);
// "Next run: null" with 12 jobs scheduled means Platform Cache is unavailable (the panel would show it off, D040).
System.debug('Next run: ' + TelemetriaIngestaProgramada.proximaEjecucion());
