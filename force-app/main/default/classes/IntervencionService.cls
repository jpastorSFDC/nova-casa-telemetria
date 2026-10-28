/**
 * Opens or links the operational intervention (Case, D001) for winning critical signals. D039: an asset has at most
 *              one open telemetry Case (Origin = Telemetria). The first critical opens it; while it stays open, later
 *              criticals of the same asset (any measurement type) link to it and refresh its Ultima_Critica_* fields
 *              only when they are more recent (D003 order extended to every critical of the asset). Manual Cases
 *              (Origin = Operador) are never linked or updated. An asset with several open telemetry Cases (opened
 *              before D039) uses the most recent one; the older ones are closed in bulk (D035).
 *
 *              Identity = source + messageId. Case.Identidad_Senal__c (unique) holds the identity of the signal that
 *              opened the Case, so that identity maps to its Case (open or closed) untouched: retrying it never opens,
 *              reopens or updates a Case. Any other identity (including a linked one retried after a Fallida) goes
 *              through link-or-open again.
 *
 *              The asset rows are locked before looking for open Cases, so two concurrent runs cannot both open the
 *              first Case of the same asset.
 *
 *              INGESTION-PATH-ONLY API: runs in system mode (`without sharing`, SYSTEM_MODE query and DML)
 *              because the subscriber that processes the events runs as the integration user (D017; BR-208
 *              covers the separate query-side authorization path). It must never be called from
 *              operator-facing code (LWC or
 *              @AuraEnabled controllers): doing so would bypass CRUD/FLS/sharing for operators.
 *              The strings in Resultado.errorPorIdentidad can come straight from DML
 *              (Database.Error.getMessage()); they must not be shown verbatim to operators or written to logs.
 */
public without sharing class IntervencionService {
    // Why `without sharing` + SYSTEM_MODE: the subscriber runs as the integration user (D017) and must not depend on
    // operator/admin permissions (AGENTS.md). The query-side authorization path is separate (BR-208).

    // ─── Constants ───────────────────────────────────────────────────────
    private static final String ORIGIN_TELEMETRY = 'Telemetria';
    private static final String STATUS_IN_PROGRESS = 'En curso';
    private static final String PRIORITY_CRITICAL = 'Critica';
    private static final Integer SUBJECT_MAX_LENGTH = 255;
    private static final Integer DESCRIPTION_MAX_LENGTH = 32000; // Case.Description field limit
    private static final Integer IDENTITY_MAX_LENGTH = 60; // Case.Identidad_Senal__c and Ultima_Critica_Identidad__c
    private static final Integer MEASUREMENT_MAX_LENGTH = 60; // Case.Ultima_Critica_Medicion__c
    private static final Integer UNIT_MAX_LENGTH = 40; // Case.Ultima_Critica_Unidad__c
    private static final Decimal VALUE_LIMIT = 100000000000000L; // Ultima_Critica_Valor__c is Number(18,4): |value| < 1e14

    // Test-only seam: must NEVER be assigned outside a test class (it makes real Case updates fail).
    // When an asset's winning identity is in this set, its Case update row is built to fail (STRING_TOO_LONG).
    @TestVisible
    private static Set<String> identidadesConFalloDeActualizacion = new Set<String>();

    // Test-only seam: must NEVER be assigned outside a test class (it inserts real Cases).
    // When true, each Case about to be opened is inserted first by a "rival", as a concurrent run that got there first
    // would, so the DUPLICATE_VALUE recovery in insertCases can be exercised in a single-transaction test.
    @TestVisible
    private static Boolean insertarRivalAntesDeAbrir = false;

    // ─── Public API ──────────────────────────────────────────────────────

    /**
     * Maps every identity to a Case: the one it already has (by identity), its asset's open telemetry Case, or a new
     *              Case opened from the asset's most recent request. Partial success: a bad row lands in
     *              errorPorIdentidad without rolling back the others. Up to 200 requests use at most 4 SOQL and 2 DML.
     * @param solicitudes Requests for winning critical signals (up to 200 per invocation)
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
        Map<Id, List<String>> identitiesByAsset = new Map<Id, List<String>>();
        for (String identity : validByIdentity.keySet()) {
            if (existing.containsKey(identity)) {
                resultado.casoPorIdentidad.put(identity, existing.get(identity));
                continue;
            }
            Id assetId = validByIdentity.get(identity).assetId;
            if (!identitiesByAsset.containsKey(assetId)) {
                identitiesByAsset.put(assetId, new List<String>());
            }
            identitiesByAsset.get(assetId).add(identity);
        }

        if (!identitiesByAsset.isEmpty()) {
            linkOrOpen(identitiesByAsset, validByIdentity, resultado);
        }
        return resultado;
    }

    // ─── Private Helpers ─────────────────────────────────────────────────

    /**
     * Rejects requests without identity or asset, or whose identity exceeds 60 characters (it can't be stored, and as
     * the opener it would fail the Case the asset's other rows share), and collapses duplicate identities in the batch
     * (the first request wins). The identity is trimmed before use. A request whose identity is blank
     * after trimming (or a null request) is reported under '(blank identity #<index>)', where index is its
     * position in the input, so no failure collapses into another or loses its evidence.
     */
    private static Map<String, Solicitud> collectValid(List<Solicitud> solicitudes, Resultado resultado) {
        Map<String, Solicitud> validByIdentity = new Map<String, Solicitud>();
        for (Integer i = 0; i < solicitudes.size(); i++) {
            Solicitud solicitud = solicitudes[i];
            String identity = (solicitud == null || solicitud.identidad == null) ? '' : solicitud.identidad.trim();
            if (String.isBlank(identity)) {
                resultado.errorPorIdentidad.put('(blank identity #' + i + ')', 'identidad is required');
            } else if (solicitud.assetId == null) {
                resultado.errorPorIdentidad.put(identity, 'assetId is required');
            } else if (identity.length() > IDENTITY_MAX_LENGTH) {
                resultado.errorPorIdentidad.put(identity, 'identidad exceeds ' + IDENTITY_MAX_LENGTH + ' characters');
            } else if (!validByIdentity.containsKey(identity)) {
                validByIdentity.put(identity, solicitud);
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

    /**
     * Per asset: links every identity to the open telemetry Case (refreshing it if the asset's most recent request is
     * newer than what it records) or opens one Case from that request. One insert and one update for all assets.
     */
    private static void linkOrOpen(Map<Id, List<String>> identitiesByAsset, Map<String, Solicitud> validByIdentity, Resultado resultado) {
        lockAssets(identitiesByAsset.keySet());
        Map<Id, Case> openCaseByAsset = findOpenTelemetryCases(identitiesByAsset.keySet());

        List<Case> toInsert = new List<Case>();
        List<List<String>> insertGroups = new List<List<String>>();
        List<Case> toUpdate = new List<Case>();
        List<String> updateIdentities = new List<String>();
        for (Id assetId : identitiesByAsset.keySet()) {
            List<String> assetIdentities = identitiesByAsset.get(assetId);
            String best = mostRecent(assetIdentities, validByIdentity);
            Solicitud winner = validByIdentity.get(best);
            Case openCase = openCaseByAsset.get(assetId);
            if (openCase == null) {
                Case newCase = buildCase(best, winner);
                applyLatestCritical(newCase, best, winner);
                toInsert.add(newCase);
                insertGroups.add(assetIdentities);
                continue;
            }
            mapGroup(assetIdentities, openCase.Id, resultado);
            if (openCase.Ultima_Critica_At__c == null
                || isMoreRecent(winner.occurredAt, best, openCase.Ultima_Critica_At__c, openCase.Ultima_Critica_Identidad__c)) {
                Case refreshed = new Case(Id = openCase.Id);
                applyLatestCritical(refreshed, best, winner);
                if (identidadesConFalloDeActualizacion.contains(best)) {
                    refreshed.Ultima_Critica_Identidad__c = 'x'.repeat(IDENTITY_MAX_LENGTH + 1);
                }
                toUpdate.add(refreshed);
                updateIdentities.add(best);
            }
        }

        if (insertarRivalAntesDeAbrir && Test.isRunningTest() && !toInsert.isEmpty()) {
            insertRivals(toInsert);
        }
        insertCases(toInsert, insertGroups, resultado);
        updateCases(toUpdate, updateIdentities, resultado);
    }

    private static void insertRivals(List<Case> toInsert) {
        List<Case> rivals = new List<Case>();
        for (Case newCase : toInsert) {
            rivals.add(newCase.clone(false, true));
        }
        Database.insert(rivals, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Serializes two batches that would otherwise both open the first Case of the same asset; the unique identity no
     * longer covers that because each signal has its own identity. Same pattern as
     * IntervencionOperadorController.crearIntervencion.
     */
    private static void lockAssets(Set<Id> assetIds) {
        List<Asset> locked = [SELECT Id FROM Asset WHERE Id IN :assetIds WITH SYSTEM_MODE FOR UPDATE];
    }

    /**
     * One query, after the lock: the most recent open telemetry Case per asset (same order as the operator screen,
     * which also lists manual Cases).
     */
    private static Map<Id, Case> findOpenTelemetryCases(Set<Id> assetIds) {
        Map<Id, Case> openCaseByAsset = new Map<Id, Case>();
        for (Case openCase : [
            SELECT Id, AssetId, Ultima_Critica_At__c, Ultima_Critica_Identidad__c
            FROM Case
            WHERE Origin = :ORIGIN_TELEMETRY AND IsClosed = false AND AssetId IN :assetIds
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
        ]) {
            if (!openCaseByAsset.containsKey(openCase.AssetId)) {
                openCaseByAsset.put(openCase.AssetId, openCase);
            }
        }
        return openCaseByAsset;
    }

    private static String mostRecent(List<String> identities, Map<String, Solicitud> validByIdentity) {
        String best = null;
        for (String identity : identities) {
            if (best == null || isMoreRecent(validByIdentity.get(identity).occurredAt, identity, validByIdentity.get(best).occurredAt, best)) {
                best = identity;
            }
        }
        return best;
    }

    /**
     * D003 extended to every critical of the asset (all critical thresholds are level 2, so severity always ties):
     * the later occurredAt wins (null loses to non-null), then the smaller messageId, then the smaller source; the
     * full identity only settles identities without '|'. Arrival order never decides.
     * compareTo and not <: Apex's String < depends on the user's locale and ignores case.
     */
    private static Boolean isMoreRecent(Datetime occurredAt, String identity, Datetime otherOccurredAt, String otherIdentity) {
        if (occurredAt != otherOccurredAt) {
            if (occurredAt == null) {
                return false;
            }
            return otherOccurredAt == null || occurredAt > otherOccurredAt;
        }
        Integer byMessage = (identity?.substringAfter('|') ?? '').compareTo(otherIdentity?.substringAfter('|') ?? '');
        if (byMessage != 0) {
            return byMessage < 0;
        }
        Integer bySource = (identity?.substringBefore('|') ?? '').compareTo(otherIdentity?.substringBefore('|') ?? '');
        if (bySource != 0) {
            return bySource < 0;
        }
        return (identity ?? '').compareTo(otherIdentity ?? '') < 0;
    }

    private static Case buildCase(String identity, Solicitud solicitud) {
        String asset = String.isBlank(solicitud.codigoActivo) ? String.valueOf(solicitud.assetId) : solicitud.codigoActivo;
        String subject = 'Señal crítica: ' + nullToEmpty(solicitud.tipoMedicion) + ' en ' + asset;
        return new Case(
            Identidad_Senal__c = identity,
            Origin = ORIGIN_TELEMETRY,
            Status = STATUS_IN_PROGRESS,
            Priority = PRIORITY_CRITICAL,
            AssetId = solicitud.assetId,
            AccountId = solicitud.accountId,
            Subject = subject.abbreviate(SUBJECT_MAX_LENGTH),
            Description = ('Signal ' + identity + ': ' + nullToEmpty(solicitud.causa)).abbreviate(DESCRIPTION_MAX_LENGTH)
        );
    }

    private static void applyLatestCritical(Case target, String identity, Solicitud solicitud) {
        target.Ultima_Critica_Medicion__c = solicitud.tipoMedicion?.left(MEASUREMENT_MAX_LENGTH);
        target.Ultima_Critica_Unidad__c = solicitud.unidad?.left(UNIT_MAX_LENGTH);
        target.Ultima_Critica_Valor__c = (solicitud.valor == null || solicitud.valor.abs() >= VALUE_LIMIT) ? null : solicitud.valor;
        target.Ultima_Critica_At__c = solicitud.occurredAt;
        target.Ultima_Critica_Identidad__c = identity;
    }

    /**
     * Single partial-success insert; each new Case is shared by its asset's group, so its outcome (Id or error) maps
     * to every identity of the group. A DUPLICATE_VALUE error means a concurrent run already created a Case with the
     * opener's identity, so the group is resolved to that Case with one re-query.
     */
    private static void insertCases(List<Case> cases, List<List<String>> groups, Resultado resultado) {
        if (cases.isEmpty()) {
            return;
        }
        List<Database.SaveResult> saveResults = Database.insert(cases, false, AccessLevel.SYSTEM_MODE);
        Map<String, List<String>> racedGroupByOpener = new Map<String, List<String>>();
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult saveResult = saveResults[i];
            if (saveResult.isSuccess()) {
                mapGroup(groups[i], saveResult.getId(), resultado);
                continue;
            }
            Database.Error error = saveResult.getErrors()[0];
            if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                racedGroupByOpener.put(cases[i].Identidad_Senal__c, groups[i]);
            } else {
                failGroup(groups[i], error.getMessage(), resultado);
            }
        }

        if (!racedGroupByOpener.isEmpty()) {
            Map<String, Id> winners = findExistingCases(racedGroupByOpener.keySet());
            for (String opener : racedGroupByOpener.keySet()) {
                if (winners.containsKey(opener)) {
                    mapGroup(racedGroupByOpener.get(opener), winners.get(opener), resultado);
                } else {
                    failGroup(racedGroupByOpener.get(opener), 'Duplicate identity but existing Case not found', resultado);
                }
            }
        }
    }

    /**
     * Single partial-success update. A failure belongs only to the identity whose values were being written; the
     * asset's other identities stay linked because they didn't change the Case.
     */
    private static void updateCases(List<Case> cases, List<String> identities, Resultado resultado) {
        if (cases.isEmpty()) {
            return;
        }
        List<Database.SaveResult> saveResults = Database.update(cases, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < saveResults.size(); i++) {
            if (!saveResults[i].isSuccess()) {
                resultado.casoPorIdentidad.remove(identities[i]);
                resultado.errorPorIdentidad.put(identities[i], saveResults[i].getErrors()[0].getMessage());
            }
        }
    }

    private static void mapGroup(List<String> identities, Id caseId, Resultado resultado) {
        for (String identity : identities) {
            resultado.casoPorIdentidad.put(identity, caseId);
        }
    }

    private static void failGroup(List<String> identities, String message, Resultado resultado) {
        for (String identity : identities) {
            resultado.errorPorIdentidad.put(identity, message);
        }
    }

    private static String nullToEmpty(String value) {
        return value == null ? '' : value;
    }

    // ─── Inner Classes ───────────────────────────────────────────────────

    /** Request to link or open an intervention for one winning critical message. */
    public class Solicitud {
        public String identidad; // source + '|' + messageId
        public Id assetId;
        public Id accountId;
        public String codigoActivo; // Asset.External_Id__c, used in the subject; falls back to assetId
        public String tipoMedicion;
        public String causa;
        public Datetime occurredAt;
        public Decimal valor;
        public String unidad;
    }

    /** Outcome of abrir(): Case per identity (new or existing) and error per identity. */
    public class Resultado {
        public Map<String, Id> casoPorIdentidad = new Map<String, Id>();
        public Map<String, String> errorPorIdentidad = new Map<String, String>();
    }
}
