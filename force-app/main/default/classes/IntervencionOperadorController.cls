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
    @TestVisible private static final String STATUS_CLOSED = 'Closed';
    @TestVisible private static final Integer MOTIVO_MAX = 1000;
    @TestVisible private static final Integer COMMENT_MAX = 4000;
    @TestVisible private static final Integer DESCRIPTION_MAX = 32000;
    // Cases closed per call: keeps one request far from the DML and CPU limits; the caller asks again for the rest.
    @TestVisible private static final Integer BULK_CLOSE_MAX = 200;

    @TestVisible private static final String NO_PERMISSION_CREATE = 'No tienes permiso para crear intervenciones.';
    @TestVisible private static final String NO_PERMISSION_FOLLOW = 'No tienes permiso para actualizar intervenciones.';
    @TestVisible private static final String REASON_REQUIRED = 'Escribe el motivo de la intervención.';
    @TestVisible private static final String REASON_TOO_LONG = 'El motivo es demasiado largo (máximo 1000 caracteres).';
    @TestVisible private static final String COMMENT_TOO_LONG = 'El comentario es demasiado largo (máximo 4000 caracteres).';
    @TestVisible private static final String ASSET_NOT_FOUND = 'No se encontró el activo o no tienes acceso a él.';
    @TestVisible private static final String NO_READINGS = 'Este activo aún no tiene lecturas, no se puede abrir una intervención.';
    @TestVisible private static final String ALREADY_OPEN = 'Ya hay una intervención abierta para este activo.';
    @TestVisible private static final String CASE_NOT_FOUND = 'No se encontró la intervención o no tienes acceso a ella.';
    @TestVisible private static final String NOTHING_TO_CLOSE = 'Este activo no tiene intervenciones abiertas que puedas cerrar.';
    @TestVisible private static final String COUNT_CHANGED = 'Cambió el número de intervenciones abiertas de este activo. Revisa y vuelve a confirmar.';
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

    public class CierreResultado {
        @AuraEnabled public Integer cerradas { get; private set; }
        @AuraEnabled public Integer fallidas { get; private set; }
        // True when more open interventions were left because of BULK_CLOSE_MAX: the caller asks again.
        @AuraEnabled public Boolean hayMas { get; private set; }
        public CierreResultado(Integer closed, Integer failed, Boolean more) {
            this.cerradas = closed;
            this.fallidas = failed;
            this.hayMas = more;
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

    /**
     * Closes, in one call, the open interventions of one asset (up to BULK_CLOSE_MAX; `hayMas` says if some are left)
     * and leaves one line in each Description, with the optional comment. Ingestion opens one intervention per unique
     * critical message (D010), so an asset can pile up many; this only changes how they are closed, not how they open.
     * Same key as actualizarSeguimiento (Nova_Casa_Seguir_Intervencion) and the same USER_MODE: only the Cases the
     * user can see and edit are closed, each on its own (one failure does not undo the rest).
     * `esperadas` is the number the person saw and confirmed: if the open count changed since (ingestion keeps opening
     * interventions), nothing is closed and the screen asks again, so a new critical one is never closed unseen.
     */
    @AuraEnabled
    public static CierreResultado cerrarIntervencionesDelActivo(Id assetId, Integer esperadas, String comentario) {
        if (!FeatureManagement.checkPermission(PERM_SEGUIR)) {
            throw safeError(NO_PERMISSION_FOLLOW);
        }
        String note = comentario == null ? '' : comentario.trim();
        if (note.length() > COMMENT_MAX) {
            throw safeError(COMMENT_TOO_LONG);
        }
        // One line per Case: a typed line break could pass for another person's audit line.
        note = note.replaceAll('[\\r\\n]+', ' ');
        if (assetId == null) {
            throw safeError(ASSET_NOT_FOUND);
        }

        try {
            if ([SELECT COUNT() FROM Asset WHERE Id = :assetId WITH USER_MODE] == 0) {
                throw safeError(ASSET_NOT_FOUND);
            }
            Integer total = [SELECT COUNT() FROM Case WHERE AssetId = :assetId AND IsClosed = false WITH USER_MODE];
            if (total == 0) {
                throw safeError(NOTHING_TO_CLOSE);
            }
            if (esperadas != null && esperadas != total) {
                throw safeError(COUNT_CHANGED);
            }
            Integer fetch = BULK_CLOSE_MAX + 1;
            List<Case> open = [
                SELECT Id, Status, Description FROM Case
                WHERE AssetId = :assetId AND IsClosed = false
                WITH USER_MODE ORDER BY CreatedDate, Id LIMIT :fetch
            ];
            if (open.isEmpty()) {
                throw safeError(NOTHING_TO_CLOSE);
            }
            Boolean more = open.size() > BULK_CLOSE_MAX;
            if (more) {
                open.remove(open.size() - 1);
            }

            String line = '[' + Datetime.now().format('yyyy-MM-dd HH:mm') + ' ' + UserInfo.getName() + '] Cierre en bloque'
                + (note == '' ? '' : ': ' + note);
            for (Case c : open) {
                c.Status = STATUS_CLOSED;
                // On overflow the oldest text goes, not the line that says who closed it.
                String joined = String.isBlank(c.Description) ? line : c.Description + '\n' + line;
                c.Description = joined.length() > DESCRIPTION_MAX ? joined.right(DESCRIPTION_MAX) : joined;
            }
            Integer closed = 0;
            for (Database.SaveResult sr : Database.update(open, false, AccessLevel.USER_MODE)) {
                if (sr.isSuccess()) {
                    closed++;
                } else {
                    System.debug(LoggingLevel.ERROR, 'cerrarIntervencionesDelActivo: ' + sr.getErrors()[0].getStatusCode());
                }
            }
            return new CierreResultado(closed, open.size() - closed, more);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'cerrarIntervencionesDelActivo: ' + e.getTypeName());
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
