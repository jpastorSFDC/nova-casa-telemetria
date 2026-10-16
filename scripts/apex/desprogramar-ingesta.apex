// Turns off automatic ingestion (US-201, BR-201, D040): aborts the 12 scheduled jobs. Run this before cleaning the
// org, running other scenarios by hand, or deploying the ingestion classes (Salesforce blocks deploying a class
// that is scheduled for execution). Leaves scheduled jobs outside the ingestion prefix alone.
//
//   sf apex run --file scripts/apex/desprogramar-ingesta.apex -o nova-cdo
Integer abortados = TelemetriaIngestaProgramada.desprogramar();
System.debug('Aborted jobs: ' + abortados);
