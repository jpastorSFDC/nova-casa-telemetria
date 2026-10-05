/**
 * Opens the operational intervention (Case, D001) for a critical signal. Baseline rule: one Case
 *              per unique critical message, where identity = source + messageId. The identity is
 *              stored in Case.Identidad_Senal__c (unique external id), so a resend of the same
 *              identity maps to the existing Case and never creates or updates a second one.
 *              Different identities are never consolidated into one Case.
 */
public without sharing class IntervencionService {
    // Why `without sharing` + SYSTEM_MODE: ingestion runs as an Automated Process and must not depend on
    // operator/admin permissions (AGENTS.md). The query-side authorization path is separate (BR-208).

    // ─── Constants ───────────────────────────────────────────────────────
    private static final String ORIGIN_TELEMETRY = 'Telemetria';
    private static final String STATUS_IN_PROGRESS = 'En curso';
    private static final String PRIORITY_CRITICAL = 'Critica';
    private static final Integer SUBJECT_MAX_LENGTH = 255;

    // ─── Public API ──────────────────────────────────────────────────────

    /**
     * Opens one Case per unique identity. Identities that already have a Case map to it untouched.
     *              Partial success: a bad row lands in errorPorIdentidad without rolling back the others.
     * @param solicitudes Requests to open interventions (up to 200 per invocation)
     * @return Case Id per identity (new or existing) and error message per identity
     * @example
     * IntervencionService.Resultado r = IntervencionService.abrir(solicitudes);
     */
    public static Resultado abrir(List<Solicitud> solicitudes) {
        Resultado resultado = new Resultado();
        if (solicitudes == null || solicitudes.isEmpty()) {
            return resultado;
        }

        Map<String, Solicitud> validByIdentity = collectValid(solicitudes, resultado);
        if (validByIdentity.isEmpty()) {
            return resultado;
        }

        Map<String, Id> existing = findExistingCases(validByIdentity.keySet());
        List<Case> toInsert = new List<Case>();
        List<String> insertIdentities = new List<String>();
        for (String identity : validByIdentity.keySet()) {
            if (existing.containsKey(identity)) {
                resultado.casoPorIdentidad.put(identity, existing.get(identity));
            } else {
                toInsert.add(buildCase(validByIdentity.get(identity)));
                insertIdentities.add(identity);
            }
        }

        if (!toInsert.isEmpty()) {
            insertCases(toInsert, insertIdentities, resultado);
        }
        return resultado;
    }

    // ─── Private Helpers ─────────────────────────────────────────────────

    /**
     * Rejects requests without identity or asset and collapses duplicate identities in the batch
     * (the first request wins).
     */
    private static Map<String, Solicitud> collectValid(List<Solicitud> solicitudes, Resultado resultado) {
        Map<String, Solicitud> validByIdentity = new Map<String, Solicitud>();
        for (Solicitud solicitud : solicitudes) {
            if (solicitud == null || String.isBlank(solicitud.identidad)) {
                // No usable identity: the error is keyed by the raw (blank) value, '' when null.
                resultado.errorPorIdentidad.put(solicitud == null ? '' : nullToEmpty(solicitud.identidad), 'identidad is required');
            } else if (solicitud.assetId == null) {
                resultado.errorPorIdentidad.put(solicitud.identidad, 'assetId is required');
            } else if (!validByIdentity.containsKey(solicitud.identidad)) {
                validByIdentity.put(solicitud.identidad, solicitud);
            }
        }
        return validByIdentity;
    }

    /**
     * One query for the Cases that already exist for the given identities.
     */
    private static Map<String, Id> findExistingCases(Set<String> identities) {
        Map<String, Id> caseIdByIdentity = new Map<String, Id>();
        for (Case existing : [
            SELECT Id, Identidad_Senal__c
            FROM Case
            WHERE Identidad_Senal__c IN :identities
            WITH SYSTEM_MODE
        ]) {
            caseIdByIdentity.put(existing.Identidad_Senal__c, existing.Id);
        }
        return caseIdByIdentity;
    }

    private static Case buildCase(Solicitud solicitud) {
        String subject = 'Critical signal: ' + nullToEmpty(solicitud.tipoMedicion) + ' on asset ' + solicitud.assetId;
        return new Case(
            Identidad_Senal__c = solicitud.identidad,
            Origin = ORIGIN_TELEMETRY,
            Status = STATUS_IN_PROGRESS,
            Priority = PRIORITY_CRITICAL,
            AssetId = solicitud.assetId,
            AccountId = solicitud.accountId,
            Subject = subject.abbreviate(SUBJECT_MAX_LENGTH),
            Description = 'Signal ' + solicitud.identidad + ': ' + nullToEmpty(solicitud.causa)
        );
    }

    /**
     * Single partial-success insert; errors are mapped back to their identity. A DUPLICATE_VALUE error
     * means a concurrent run created the Case first, so it is resolved to that Case with one re-query.
     */
    private static void insertCases(List<Case> cases, List<String> identities, Resultado resultado) {
        List<Database.SaveResult> saveResults = Database.insert(cases, false, AccessLevel.SYSTEM_MODE);
        Set<String> raced = new Set<String>();
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult saveResult = saveResults[i];
            String identity = identities[i];
            if (saveResult.isSuccess()) {
                resultado.casoPorIdentidad.put(identity, saveResult.getId());
                continue;
            }
            Database.Error error = saveResult.getErrors()[0];
            if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                raced.add(identity);
            } else {
                resultado.errorPorIdentidad.put(identity, error.getMessage());
            }
        }

        if (!raced.isEmpty()) {
            Map<String, Id> winners = findExistingCases(raced);
            for (String identity : raced) {
                if (winners.containsKey(identity)) {
                    resultado.casoPorIdentidad.put(identity, winners.get(identity));
                } else {
                    resultado.errorPorIdentidad.put(identity, 'Duplicate identity but existing Case not found');
                }
            }
        }
    }

    private static String nullToEmpty(String value) {
        return value == null ? '' : value;
    }

    // ─── Inner Classes ───────────────────────────────────────────────────

    /** Request to open an intervention for one critical message. */
    public class Solicitud {
        public String identidad; // source + '|' + messageId
        public Id assetId;
        public Id accountId;
        public String tipoMedicion;
        public String causa;
    }

    /** Outcome of abrir(): Case per identity (new or existing) and error per identity. */
    public class Resultado {
        public Map<String, Id> casoPorIdentidad = new Map<String, Id>();
        public Map<String, String> errorPorIdentidad = new Map<String, String>();
    }
}
