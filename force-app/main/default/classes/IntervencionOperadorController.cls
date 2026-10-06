/**
 * Write side of the operator screen (D020): a person opens a manual intervention or follows up an open one.
 * Each action checks its custom permission on the server, so hiding a button in the LWC is never the only guard (BR-208).
 *
 * `with sharing`: the asset must be visible to the user (USER_MODE). The Case insert runs in SYSTEM_MODE on purpose:
 * operators have no Create on Case, the custom permission is their only key. The "no open intervention" check runs in
 * OpenCaseCheck (a separate `without sharing` class): SYSTEM_MODE inside a `with sharing` class still applies sharing,
 * and with Case Private a Case the user cannot see would not block a duplicate. The message never names that Case.
 * This is not the ingestion path: a manual intervention does not count as a critical message and leaves the
 * one-intervention-per-critical-message rule of IntervencionService untouched.
 */
public with sharing class IntervencionOperadorController {

    public static final String PERM_CREAR = 'Nova_Casa_Crear_Intervencion';
    public static final String PERM_SEGUIR = 'Nova_Casa_Seguir_Intervencion';

    @TestVisible private static final String ORIGIN_OPERATOR = 'Operador';
    @TestVisible private static final String STATUS_IN_PROGRESS = 'En curso';
    @TestVisible private static final Set<String> FOLLOW_UP_STATUSES = new Set<String>{ 'En curso', 'On Hold', 'Closed' };
    @TestVisible private static final Integer MOTIVO_MAX = 1000;
    @TestVisible private static final Integer COMMENT_MAX = 4000;

    @TestVisible private static final String NO_PERMISSION_CREATE = 'No tienes permiso para crear intervenciones.';
    @TestVisible private static final String NO_PERMISSION_FOLLOW = 'No tienes permiso para actualizar intervenciones.';
    @TestVisible private static final String REASON_REQUIRED = 'Escribe el motivo de la intervención.';
    @TestVisible private static final String REASON_TOO_LONG = 'El motivo es demasiado largo (máximo 1000 caracteres).';
    @TestVisible private static final String COMMENT_TOO_LONG = 'El comentario es demasiado largo (máximo 4000 caracteres).';
    @TestVisible private static final String ASSET_NOT_FOUND = 'No se encontró el activo o no tienes acceso a él.';
    @TestVisible private static final String NO_READINGS = 'Este activo aún no tiene lecturas, no se puede abrir una intervención.';
    @TestVisible private static final String ALREADY_OPEN = 'Ya hay una intervención abierta para este activo.';
    @TestVisible private static final String CASE_NOT_FOUND = 'No se encontró la intervención o no tienes acceso a ella.';
    @TestVisible private static final String INVALID_STATUS = 'El estado no es válido.';
    @TestVisible private static final String SAVE_FAILED = 'No se pudo guardar. Inténtalo de nuevo más tarde.';

    public class Resultado {
        @AuraEnabled public Id caseId { get; private set; }
        @AuraEnabled public String caseNumber { get; private set; }
        public Resultado(Case c) {
            this.caseId = c.Id;
            this.caseNumber = c.CaseNumber;
        }
    }

    /**
     * Opens a manual intervention for an asset that has readings and no open intervention.
     * @param assetId asset the user can see
     * @param motivo why the intervention is needed (required)
     */
    @AuraEnabled
    public static Resultado crearIntervencion(Id assetId, String motivo) {
        if (!FeatureManagement.checkPermission(PERM_CREAR)) {
            throw safeError(NO_PERMISSION_CREATE);
        }
        String reason = motivo == null ? '' : motivo.trim();
        if (reason == '') {
            throw safeError(REASON_REQUIRED);
        }
        if (reason.length() > MOTIVO_MAX) {
            throw safeError(REASON_TOO_LONG);
        }
        if (assetId == null) {
            throw safeError(ASSET_NOT_FOUND);
        }

        try {
            List<Asset> visible = [
                SELECT Id, Name, AccountId, External_Id__c, Severidad_Nivel__c
                FROM Asset WHERE Id = :assetId WITH USER_MODE LIMIT 1
            ];
            if (visible.isEmpty()) {
                throw safeError(ASSET_NOT_FOUND);
            }
            Asset asset = visible[0];

            // Lock the asset row: two clicks (or two people) on the same asset are serialized, so the second
            // one sees the Case the first one created.
            List<Asset> locked = [SELECT Id FROM Asset WHERE Id = :assetId WITH SYSTEM_MODE LIMIT 1 FOR UPDATE];
            if (locked.isEmpty()) {
                throw safeError(ASSET_NOT_FOUND);
            }

            if (OpenCaseCheck.existsFor(assetId)) {
                throw safeError(ALREADY_OPEN);
            }

            // Current severity = highest of the latest readings; computed from Lectura_Vigente__c in the user's access.
            Integer level = highestLevel(assetId);
            if (level == null) {
                throw safeError(NO_READINGS);
            }

            String code = String.isBlank(asset.External_Id__c) ? asset.Name : asset.External_Id__c;
            Case c = new Case(
                Origin = ORIGIN_OPERATOR,
                Status = STATUS_IN_PROGRESS,
                Priority = priorityFor(level),
                AssetId = asset.Id,
                AccountId = asset.AccountId,
                Subject = ('Intervención manual en ' + code).abbreviate(255),
                Description = (reason + '\n\nAbierta por: ' + UserInfo.getName()).abbreviate(32000)
            );
            Database.SaveResult sr = Database.insert(c, false, AccessLevel.SYSTEM_MODE);
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'crearIntervencion: ' + sr.getErrors()[0].getStatusCode());
                throw safeError(SAVE_FAILED);
            }
            Case saved = [SELECT Id, CaseNumber FROM Case WHERE Id = :c.Id WITH SYSTEM_MODE];
            return new Resultado(saved);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'crearIntervencion: ' + e.getTypeName());
            throw safeError(SAVE_FAILED);
        }
    }

    /**
     * Changes the status of an open intervention (a Case tied to an asset and not closed) and optionally leaves a
     * comment. A closed Case cannot be reopened here: that could leave two open interventions on one asset.
     * Runs as the user (USER_MODE): a user without Edit on Case cannot do it even with the custom permission.
     */
    @AuraEnabled
    public static void actualizarSeguimiento(Id caseId, String estado, String comentario) {
        if (!FeatureManagement.checkPermission(PERM_SEGUIR)) {
            throw safeError(NO_PERMISSION_FOLLOW);
        }
        if (String.isBlank(estado) || !FOLLOW_UP_STATUSES.contains(estado)) {
            throw safeError(INVALID_STATUS);
        }
        String note = comentario == null ? '' : comentario.trim();
        if (note.length() > COMMENT_MAX) {
            throw safeError(COMMENT_TOO_LONG);
        }
        if (caseId == null) {
            throw safeError(CASE_NOT_FOUND);
        }

        try {
            List<Case> found = [
                SELECT Id, Status, Description FROM Case
                WHERE Id = :caseId AND AssetId != null AND IsClosed = false WITH USER_MODE LIMIT 1
            ];
            if (found.isEmpty()) {
                throw safeError(CASE_NOT_FOUND);
            }
            Case c = found[0];
            c.Status = estado;
            if (note != '') {
                String line = '[' + Datetime.now().format('yyyy-MM-dd HH:mm') + ' ' + UserInfo.getName() + '] ' + note;
                c.Description = String.isBlank(c.Description) ? line : (c.Description + '\n' + line);
                c.Description = c.Description.abbreviate(32000);
            }
            update as user c;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'actualizarSeguimiento: ' + e.getTypeName());
            throw safeError(SAVE_FAILED);
        }
    }

    // Highest severity among the asset's latest readings; null when it has none.
    private static Integer highestLevel(Id assetId) {
        Integer best = null;
        for (Lectura_Vigente__c r : [
            SELECT Severidad_Nivel__c FROM Lectura_Vigente__c WHERE Asset__c = :assetId WITH USER_MODE LIMIT 50
        ]) {
            Integer level = r.Severidad_Nivel__c == null ? 0 : r.Severidad_Nivel__c.intValue();
            best = best == null ? level : Math.max(best, level);
        }
        return best;
    }

    @TestVisible
    private static String priorityFor(Integer level) {
        return level >= 2 ? 'Critica' : (level == 1 ? 'High' : 'Medium');
    }

    private static AuraHandledException safeError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
