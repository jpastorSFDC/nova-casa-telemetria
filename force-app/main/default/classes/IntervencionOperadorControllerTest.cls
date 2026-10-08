/**
 * Tests for IntervencionOperadorController (D020, D036) and the capabilities of ActivosOperadorController.
 * Users carry the shipped permission sets, so these also fail if a custom permission is dropped from one.
 */
@isTest
private class IntervencionOperadorControllerTest {

    private static final String OPERATOR_ROLE = 'Operador_Edificios';
    private static final String COORDINATOR_ROLE = 'Coordinador_Mantenimiento';
    private static final String GERENTE_ROLE = 'Gerente_Regional_Operaciones';
    private static final String INTEGRATION_ROLE = 'Integracion_Telemetria';

    // ─── Helpers ──────────────────────────────────────────────────────────

    // roleName may be null. With private sharing (BR-208) a coordinator or gerente sees a building only through the
    // role hierarchy, above the operator who owns it.
    private static User newUserWithPermissionSet(String prefix, String permissionSetName, String roleName) {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName];
            Assert.areEqual(1, sets.size(), permissionSetName + ' must be deployed to the org');
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            String suffix = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');
            u = new User(
                Username = prefix + '.' + suffix + '@novacasa-test.example.com',
                Alias = prefix.right(8),
                Email = prefix + '@novacasa-test.example.com',
                LastName = prefix,
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/Bogota',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                UserRoleId = roleName == null ? null : roleId(roleName)
            );
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = sets[0].Id);
        }
        return u;
    }

    private static Id roleId(String developerName) {
        List<UserRole> roles = [SELECT Id FROM UserRole WHERE DeveloperName = :developerName];
        Assert.areEqual(1, roles.size(), developerName + ' must be deployed to the org');
        return roles[0].Id;
    }

    private static Asset newAssetWithReading(String code, Integer level, Id ownerId) {
        Account building = new Account(Name = 'Edificio ' + code, OwnerId = ownerId);
        insert building;
        Asset asset = new Asset(Name = 'Activo ' + code, AccountId = building.Id, Tipo_Activo__c = 'WATER_PUMP', External_Id__c = code);
        insert asset;
        if (level != null) {
            insert new Lectura_Vigente__c(
                Asset__c = asset.Id, Clave__c = code + '|TEMPERATURE', Tipo_Medicion__c = 'TEMPERATURE',
                Unidad__c = 'CELSIUS', Valor__c = 50, Occurred_At__c = Datetime.now().addMinutes(-1), Severidad_Nivel__c = level
            );
        }
        return asset;
    }

    private static String errorOf(Id assetId, String motivo) {
        try {
            IntervencionOperadorController.crearIntervencion(assetId, motivo);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static Integer caseCount(Id assetId) {
        return [SELECT COUNT() FROM Case WHERE AssetId = :assetId];
    }

    // ─── crearIntervencion ────────────────────────────────────────────────

    @isTest
    static void shouldOpenManualCaseWithReasonAndPriorityFromSeverity_WhenOperatorHasPermission() {
        User operator = newUserWithPermissionSet('ncmanop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Asset asset = newAssetWithReading('AST-MAN-1', 1, operator.Id);

        IntervencionOperadorController.Resultado result;
        System.runAs(operator) {
            result = IntervencionOperadorController.crearIntervencion(asset.Id, '  Ruido raro en la bomba  ');
        }

        Case c = [SELECT Origin, Status, Priority, AssetId, AccountId, Subject, Description, Identidad_Senal__c, CaseNumber FROM Case WHERE Id = :result.caseId];
        Assert.areEqual('Operador', c.Origin);
        Assert.areEqual('En curso', c.Status);
        Assert.areEqual('High', c.Priority, 'Warning severity maps to High');
        Assert.areEqual(asset.Id, c.AssetId);
        Assert.areEqual(asset.AccountId, c.AccountId);
        Assert.areEqual('Intervención manual en AST-MAN-1', c.Subject);
        Assert.isTrue(c.Description.startsWith('Ruido raro en la bomba'), 'The reason is trimmed and kept');
        Assert.isNull(c.Identidad_Senal__c, 'A manual case is not tied to a signal message');
        Assert.areEqual(c.CaseNumber, result.caseNumber);
    }

    @isTest
    static void shouldMapCriticalAndNormalSeverityToPriority() {
        User operator = newUserWithPermissionSet('ncmanprio', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Asset critical = newAssetWithReading('AST-MAN-C', 2, operator.Id);
        Asset normal = newAssetWithReading('AST-MAN-N', 0, operator.Id);

        System.runAs(operator) {
            IntervencionOperadorController.crearIntervencion(critical.Id, 'motivo');
            IntervencionOperadorController.crearIntervencion(normal.Id, 'motivo');
        }

        Assert.areEqual('Critica', [SELECT Priority FROM Case WHERE AssetId = :critical.Id].Priority);
        Assert.areEqual('Medium', [SELECT Priority FROM Case WHERE AssetId = :normal.Id].Priority);
    }

    @isTest
    static void shouldRefuseSecondIntervention_WhenOneIsAlreadyOpen() {
        User operator = newUserWithPermissionSet('ncmandup', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Asset asset = newAssetWithReading('AST-MAN-2', 2, operator.Id);
        // As in production: the open Case belongs to the integration user (role Integracion_Telemetria), not to the operator.
        User integration = newUserWithPermissionSet('ncmandupint', 'Nova_Casa_Procesamiento', INTEGRATION_ROLE);
        Case existing = new Case(AssetId = asset.Id, AccountId = asset.AccountId, OwnerId = integration.Id,
            Status = 'En curso', Origin = 'Telemetria', Subject = 'Ya abierta');
        insert existing;
        String caseNumber = [SELECT CaseNumber FROM Case WHERE Id = :existing.Id].CaseNumber;

        String error;
        System.runAs(operator) {
            error = errorOf(asset.Id, 'otra vez');
        }

        Assert.areEqual(IntervencionOperadorController.ALREADY_OPEN, error);
        Assert.isFalse(error.contains(caseNumber), 'The message must not reveal the number of the existing Case');
        Assert.areEqual(1, caseCount(asset.Id), 'No second Case');
    }

    @isTest
    static void shouldRefuseAsAssetNotFound_WhenTheAssetIsInvisibleEvenIfAnOpenCaseExists() {
        User operator = newUserWithPermissionSet('ncmaninv', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User otherOwner = newUserWithPermissionSet('ncmanown', 'Nova_Casa_Operator', null);
        Asset hidden = newAssetWithReading('AST-MAN-H', 2, otherOwner.Id);
        insert new Case(AssetId = hidden.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Ya abierta');

        String error;
        System.runAs(operator) {
            error = errorOf(hidden.Id, 'intento');
        }

        Assert.areEqual(IntervencionOperadorController.ASSET_NOT_FOUND, error, 'No oracle about Cases on assets the user cannot see');
        Assert.areEqual(1, caseCount(hidden.Id), 'No second Case');
    }

    @isTest
    static void shouldOpenAgain_WhenThePreviousInterventionIsClosed() {
        User operator = newUserWithPermissionSet('ncmanclosed', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Asset asset = newAssetWithReading('AST-MAN-3', 1, operator.Id);
        insert new Case(AssetId = asset.Id, Status = 'Closed', Origin = 'Telemetria', Subject = 'Vieja');

        System.runAs(operator) {
            IntervencionOperadorController.crearIntervencion(asset.Id, 'nueva');
        }

        Assert.areEqual(2, caseCount(asset.Id));
    }

    @isTest
    static void shouldBlockTheSecondClick_WhenTheSameUserCreatesTwice() {
        User operator = newUserWithPermissionSet('ncmandbl', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Asset asset = newAssetWithReading('AST-MAN-4', 1, operator.Id);

        String second;
        System.runAs(operator) {
            IntervencionOperadorController.crearIntervencion(asset.Id, 'primero');
            second = errorOf(asset.Id, 'segundo');
        }

        Assert.isNotNull(second);
        Assert.areEqual(IntervencionOperadorController.ALREADY_OPEN, second);
        Assert.areEqual(1, caseCount(asset.Id));
    }

    @isTest
    static void shouldRefuse_WhenReasonIsBlankOrTooLong() {
        User operator = newUserWithPermissionSet('ncmanreason', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Asset asset = newAssetWithReading('AST-MAN-5', 1, operator.Id);

        String blank;
        String nullReason;
        String tooLong;
        System.runAs(operator) {
            blank = errorOf(asset.Id, '   ');
            nullReason = errorOf(asset.Id, null);
            tooLong = errorOf(asset.Id, 'x'.repeat(IntervencionOperadorController.MOTIVO_MAX + 1));
        }

        Assert.areEqual(IntervencionOperadorController.REASON_REQUIRED, blank);
        Assert.areEqual(IntervencionOperadorController.REASON_REQUIRED, nullReason);
        Assert.areEqual(IntervencionOperadorController.REASON_TOO_LONG, tooLong);
        Assert.areEqual(0, caseCount(asset.Id));
    }

    @isTest
    static void shouldRefuse_WhenAssetHasNoReadingsOrDoesNotExist() {
        User operator = newUserWithPermissionSet('ncmannoread', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Asset noReadings = newAssetWithReading('AST-MAN-6', null, operator.Id);

        String noReadingsError;
        String missingError;
        String nullError;
        System.runAs(operator) {
            noReadingsError = errorOf(noReadings.Id, 'motivo');
            missingError = errorOf(Id.valueOf('02i000000000000AAA'), 'motivo');
            nullError = errorOf(null, 'motivo');
        }

        Assert.areEqual(IntervencionOperadorController.NO_READINGS, noReadingsError);
        Assert.areEqual(IntervencionOperadorController.ASSET_NOT_FOUND, missingError);
        Assert.areEqual(IntervencionOperadorController.ASSET_NOT_FOUND, nullError);
        Assert.areEqual(0, caseCount(noReadings.Id));
    }

    @isTest
    static void shouldRefuseWithoutCreating_WhenUserLacksTheCustomPermission() {
        User operator = newUserWithPermissionSet('ncmangteop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User gerente = newUserWithPermissionSet('ncmangte', 'Nova_Casa_Gerente', GERENTE_ROLE);
        Asset asset = newAssetWithReading('AST-MAN-7', 2, operator.Id);

        String error;
        System.runAs(gerente) {
            error = errorOf(asset.Id, 'motivo');
        }

        Assert.areEqual(IntervencionOperadorController.NO_PERMISSION_CREATE, error);
        Assert.areEqual(0, caseCount(asset.Id));
    }

    // ─── getEstadosSeguimiento ────────────────────────────────────────────

    // Active entries of the Case.Status picklist, in picklist order: what the follow-up form must offer (D036).
    private static List<Schema.PicklistEntry> activeStatusEntries() {
        List<Schema.PicklistEntry> active = new List<Schema.PicklistEntry>();
        for (Schema.PicklistEntry entry : Schema.Case.Status.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                active.add(entry);
            }
        }
        return active;
    }

    private static List<String> activeStatusValues() {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry entry : activeStatusEntries()) {
            values.add(entry.getValue());
        }
        return values;
    }

    private static List<String> valuesOf(List<IntervencionOperadorController.EstadoOpcion> options) {
        List<String> values = new List<String>();
        for (IntervencionOperadorController.EstadoOpcion option : options) {
            values.add(option.value);
        }
        return values;
    }

    @isTest
    static void shouldOfferExactlyTheActiveCaseStatusValues_WhenTheListIsRequested() {
        List<Schema.PicklistEntry> expected = activeStatusEntries();

        List<IntervencionOperadorController.EstadoOpcion> options = IntervencionOperadorController.getEstadosSeguimiento();

        Assert.areEqual(expected.size(), options.size(), 'One option per active Case.Status value');
        for (Integer i = 0; i < expected.size(); i++) {
            Assert.areEqual(expected[i].getValue(), options[i].value, 'Same API value, same position as the picklist');
            Assert.areEqual(expected[i].getLabel(), options[i].label, 'The label the user reads is the picklist label');
            Assert.isFalse(String.isBlank(options[i].label), 'Every option has a label: ' + options[i].value);
        }
        List<String> values = valuesOf(options);
        Assert.areEqual(values.size(), new Set<String>(values).size(), 'No value is offered twice');
        Assert.isTrue(values.contains(IntervencionOperadorController.STATUS_IN_PROGRESS), 'The form default (En curso) is offered');
        Assert.isTrue(values.contains(IntervencionOperadorController.STATUS_CLOSED), 'Closed is offered');
    }

    @isTest
    static void shouldOfferTheStatuses_WhenTheUserLacksTheFollowUpPermission() {
        User operator = newUserWithPermissionSet('ncestop', 'Nova_Casa_Operator', OPERATOR_ROLE);

        Boolean holdsTheKey;
        String error;
        List<IntervencionOperadorController.EstadoOpcion> options;
        System.runAs(operator) {
            holdsTheKey = FeatureManagement.checkPermission(IntervencionOperadorController.PERM_SEGUIR);
            try {
                options = IntervencionOperadorController.getEstadosSeguimiento();
            } catch (AuraHandledException e) {
                error = e.getMessage();
            }
        }

        Assert.isFalse(holdsTheKey, 'The operator must not hold Nova_Casa_Seguir_Intervencion, or this proves nothing');
        Assert.isNull(error, 'The list is picklist metadata: it is not gated by the follow-up permission');
        Assert.areEqual(activeStatusValues(), valuesOf(options), 'The operator gets the same list as anyone else');
    }

    // ─── actualizarSeguimiento ────────────────────────────────────────────

    private static String followUpError(Id caseId, String status) {
        try {
            IntervencionOperadorController.actualizarSeguimiento(caseId, status, null);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @isTest
    static void shouldChangeStatusAndAppendComment_WhenCoordinatorFollowsUp() {
        User operator = newUserWithPermissionSet('ncfupown', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncfupcoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-1', 2, operator.Id);
        Case c = new Case(AssetId = asset.Id, OwnerId = operator.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Abierta', Description = 'Original');
        insert c;

        System.runAs(coordinator) {
            IntervencionOperadorController.actualizarSeguimiento(c.Id, 'On Hold', 'Esperando repuesto');
        }

        Case after = [SELECT Status, Description FROM Case WHERE Id = :c.Id];
        Assert.areEqual('On Hold', after.Status);
        Assert.isTrue(after.Description.startsWith('Original\n['), 'Comment is appended, original kept');
        Assert.isTrue(after.Description.endsWith('Esperando repuesto'));
    }

    @isTest
    static void shouldChangeStatusWithoutComment_WhenCommentIsBlank() {
        User operator = newUserWithPermissionSet('ncfupcloseop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncfupclose', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-2', 2, operator.Id);
        Case c = new Case(AssetId = asset.Id, OwnerId = operator.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Abierta', Description = 'Original');
        insert c;

        System.runAs(coordinator) {
            IntervencionOperadorController.actualizarSeguimiento(c.Id, 'Closed', '  ');
        }

        Case after = [SELECT Status, Description, IsClosed FROM Case WHERE Id = :c.Id];
        Assert.isTrue(after.IsClosed);
        Assert.areEqual('Original', after.Description);
    }

    @isTest
    static void shouldRefuseFollowUp_WhenOperatorLacksThePermission() {
        User operator = newUserWithPermissionSet('ncfupop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-3', 2, operator.Id);
        Case c = new Case(AssetId = asset.Id, OwnerId = operator.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Abierta');
        insert c;

        String error;
        System.runAs(operator) {
            try {
                IntervencionOperadorController.actualizarSeguimiento(c.Id, 'Closed', null);
            } catch (AuraHandledException e) {
                error = e.getMessage();
            }
        }

        Assert.areEqual(IntervencionOperadorController.NO_PERMISSION_FOLLOW, error);
        Assert.areEqual('En curso', [SELECT Status FROM Case WHERE Id = :c.Id].Status);
    }

    @isTest
    static void shouldRefuseFollowUp_WhenStatusIsOutsideThePicklistOrInputIsBad() {
        User operator = newUserWithPermissionSet('ncfupbadop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncfupbad', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-4', 2, operator.Id);
        Case c = new Case(AssetId = asset.Id, OwnerId = operator.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Abierta');
        insert c;
        Assert.isFalse(activeStatusValues().contains('Inexistente'), 'The "invalid" status must not be a Case.Status value');

        List<String> errors = new List<String>();
        System.runAs(coordinator) {
            for (List<Object> args : new List<List<Object>>{
                new List<Object>{ c.Id, 'Inexistente', null },
                new List<Object>{ c.Id, null, null },
                new List<Object>{ c.Id, '   ', null },
                new List<Object>{ c.Id, 'Closed', 'x'.repeat(IntervencionOperadorController.COMMENT_MAX + 1) },
                new List<Object>{ null, 'Closed', null },
                new List<Object>{ Id.valueOf('500000000000000AAA'), 'Closed', null }
            }) {
                try {
                    IntervencionOperadorController.actualizarSeguimiento((Id) args[0], (String) args[1], (String) args[2]);
                    errors.add('no error');
                } catch (AuraHandledException e) {
                    errors.add(e.getMessage());
                }
            }
        }

        Assert.areEqual(new List<String>{
            IntervencionOperadorController.INVALID_STATUS,
            IntervencionOperadorController.INVALID_STATUS,
            IntervencionOperadorController.INVALID_STATUS,
            IntervencionOperadorController.COMMENT_TOO_LONG,
            IntervencionOperadorController.CASE_NOT_FOUND,
            IntervencionOperadorController.CASE_NOT_FOUND
        }, errors);
        Assert.areEqual('En curso', [SELECT Status FROM Case WHERE Id = :c.Id].Status);
    }

    @isTest
    static void shouldRefuseFollowUp_WhenCaseIsClosedOrHasNoAsset() {
        User operator = newUserWithPermissionSet('ncfupscopeop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncfupscope', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-5', 2, operator.Id);
        Case closed = new Case(AssetId = asset.Id, OwnerId = operator.Id, Status = 'Closed', Origin = 'Telemetria', Subject = 'Cerrada');
        Case noAsset = new Case(OwnerId = operator.Id, Status = 'En curso', Origin = 'Email', Subject = 'Sin activo');
        insert new List<Case>{ closed, noAsset };

        Integer visible;
        List<String> errors = new List<String>();
        System.runAs(coordinator) {
            visible = [SELECT COUNT() FROM Case WHERE Id IN :new Set<Id>{ closed.Id, noAsset.Id } WITH USER_MODE];
            for (Case c : new List<Case>{ closed, noAsset }) {
                try {
                    IntervencionOperadorController.actualizarSeguimiento(c.Id, 'En curso', null);
                    errors.add('no error');
                } catch (AuraHandledException e) {
                    errors.add(e.getMessage());
                }
            }
        }

        Assert.areEqual(2, visible, 'The coordinator can see both Cases, so not-found comes from the filter, not from sharing');
        Assert.areEqual(new List<String>{
            IntervencionOperadorController.CASE_NOT_FOUND, IntervencionOperadorController.CASE_NOT_FOUND
        }, errors);
        Assert.areEqual('Closed', [SELECT Status FROM Case WHERE Id = :closed.Id].Status, 'A closed Case is not reopened');
        Assert.areEqual('En curso', [SELECT Status FROM Case WHERE Id = :noAsset.Id].Status);
    }

    @isTest
    static void shouldRefuseFollowUpForLackOfPermissionNotVisibility_WhenGerenteSeesTheCaseThroughHierarchy() {
        User operator = newUserWithPermissionSet('ncfupgeop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User gerente = newUserWithPermissionSet('ncfupge', 'Nova_Casa_Gerente', GERENTE_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-6', 2, operator.Id);
        Case c = new Case(AssetId = asset.Id, AccountId = asset.AccountId, OwnerId = operator.Id,
            Status = 'En curso', Origin = 'Telemetria', Subject = 'Abierta');
        insert c;

        Integer visible;
        String error;
        System.runAs(gerente) {
            visible = [SELECT COUNT() FROM Case WHERE Id = :c.Id WITH USER_MODE];
            try {
                IntervencionOperadorController.actualizarSeguimiento(c.Id, 'Closed', null);
            } catch (AuraHandledException e) {
                error = e.getMessage();
            }
        }

        Assert.areEqual(1, visible, 'The gerente sees the operator Case through the role hierarchy');
        Assert.areEqual(IntervencionOperadorController.NO_PERMISSION_FOLLOW, error, 'Refused for permission, not CASE_NOT_FOUND');
        Assert.areEqual('En curso', [SELECT Status FROM Case WHERE Id = :c.Id].Status);
    }

    @isTest
    static void shouldAcceptEscalated_WhenCoordinatorFollowsUp() {
        User operator = newUserWithPermissionSet('ncfupescop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncfupesc', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-7', 2, operator.Id);
        Case c = openCase(asset, operator.Id, 'En curso', 'Original');
        insert c;
        // The old fixed list (En curso, On Hold, Closed) refused it; now it is accepted because it is in the picklist.
        Assert.isTrue(activeStatusValues().contains('Escalated'), 'Escalated must be an active Case.Status value in the org');

        String error;
        System.runAs(coordinator) {
            error = followUpError(c.Id, 'Escalated');
        }

        Assert.isNull(error, 'Escalated is in the Case.Status picklist, so the server accepts it');
        Case after = [SELECT Status, IsClosed, Description FROM Case WHERE Id = :c.Id];
        Assert.areEqual('Escalated', after.Status);
        Assert.isFalse(after.IsClosed, 'Escalated keeps the intervention open');
        Assert.areEqual('Original', after.Description, 'No comment, nothing appended');
    }

    @isTest
    static void shouldAcceptEveryStatusTheFormOffers_WhenCoordinatorFollowsUp() {
        User operator = newUserWithPermissionSet('ncfupallop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncfupall', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-8', 2, operator.Id);
        List<String> offered = valuesOf(IntervencionOperadorController.getEstadosSeguimiento());
        Assert.isFalse(offered.isEmpty(), 'The form must offer at least one status');
        // One fresh open Case per status, started from a different status so the change is a real one.
        List<Case> cases = new List<Case>();
        for (String status : offered) {
            String startStatus = status == IntervencionOperadorController.STATUS_IN_PROGRESS ? 'New' : IntervencionOperadorController.STATUS_IN_PROGRESS;
            cases.add(openCase(asset, operator.Id, startStatus, null));
        }
        insert cases;

        List<String> refused = new List<String>();
        System.runAs(coordinator) {
            for (Integer i = 0; i < offered.size(); i++) {
                String error = followUpError(cases[i].Id, offered[i]);
                if (error != null) {
                    refused.add(offered[i] + ': ' + error);
                }
            }
        }

        Assert.areEqual(new List<String>(), refused, 'Every status the form offers is accepted by the server');
        Map<Id, Case> after = new Map<Id, Case>([SELECT Status, IsClosed FROM Case WHERE AssetId = :asset.Id]);
        for (Integer i = 0; i < offered.size(); i++) {
            Case saved = after.get(cases[i].Id);
            Assert.areEqual(offered[i], saved.Status, 'The Case takes the status it was sent');
            // Closed needs no comment and closes the Case; any other offered status leaves it open.
            Assert.areEqual(offered[i] == IntervencionOperadorController.STATUS_CLOSED, saved.IsClosed, 'IsClosed after ' + offered[i]);
        }
    }

    @isTest
    static void shouldRefuseEveryStatusTheFormOffers_WhenTheCaseIsAlreadyClosed() {
        User operator = newUserWithPermissionSet('ncfupreopop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncfupreop', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-9', 2, operator.Id);
        Case closed = openCase(asset, operator.Id, IntervencionOperadorController.STATUS_CLOSED, 'Cerrada antes');
        insert closed;
        List<String> offered = valuesOf(IntervencionOperadorController.getEstadosSeguimiento());
        Assert.isFalse(offered.isEmpty(), 'The form must offer at least one status');

        Integer visible;
        List<String> outcomes = new List<String>();
        List<String> expected = new List<String>();
        System.runAs(coordinator) {
            visible = [SELECT COUNT() FROM Case WHERE Id = :closed.Id WITH USER_MODE];
            for (String status : offered) {
                // A call that succeeds returns no error text, so its entry differs from the expected one below.
                outcomes.add(status + ': ' + followUpError(closed.Id, status));
                expected.add(status + ': ' + IntervencionOperadorController.CASE_NOT_FOUND);
            }
        }

        Assert.areEqual(1, visible, 'The coordinator sees the Case, so not-found comes from the IsClosed filter, not from sharing');
        Assert.areEqual(expected, outcomes, 'No status reopens a closed Case from the panel');
        Case after = [SELECT Status, IsClosed, Description FROM Case WHERE Id = :closed.Id];
        Assert.areEqual(IntervencionOperadorController.STATUS_CLOSED, after.Status);
        Assert.isTrue(after.IsClosed);
        Assert.areEqual('Cerrada antes', after.Description);
    }

    // ─── cerrarIntervencionesDelActivo ────────────────────────────────────

    private static String closeAllError(Id assetId, String comment) {
        return closeAllError(assetId, null, comment);
    }

    private static String closeAllError(Id assetId, Integer expected, String comment) {
        try {
            IntervencionOperadorController.cerrarIntervencionesDelActivo(assetId, expected, comment);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static Case openCase(Asset asset, Id ownerId, String status, String description) {
        return new Case(AssetId = asset.Id, AccountId = asset.AccountId, OwnerId = ownerId,
            Status = status, Origin = 'Telemetria', Subject = 'Abierta', Description = description);
    }

    @isTest
    static void shouldCloseEveryOpenCaseOfTheAssetAndOnlyOfThatAsset_WhenCoordinatorClosesAll() {
        User operator = newUserWithPermissionSet('nccloseallop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('nccloseall', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-ALL-1', 2, operator.Id);
        Asset other = newAssetWithReading('AST-ALL-2', 2, operator.Id);
        Case inProgress = openCase(asset, operator.Id, 'En curso', 'Original');
        Case onHold = openCase(asset, operator.Id, 'On Hold', null);
        Case alreadyClosed = openCase(asset, operator.Id, 'Closed', 'Cerrada antes');
        Case otherAssetCase = openCase(other, operator.Id, 'En curso', null);
        insert new List<Case>{ inProgress, onHold, alreadyClosed, otherAssetCase };

        IntervencionOperadorController.CierreResultado result;
        System.runAs(coordinator) {
            result = IntervencionOperadorController.cerrarIntervencionesDelActivo(asset.Id, 2, '  Prueba terminada  ');
        }

        Assert.areEqual(2, result.cerradas);
        Assert.areEqual(0, result.fallidas);
        Assert.isFalse(result.hayMas);
        Map<Id, Case> after = new Map<Id, Case>([SELECT Status, IsClosed, Description FROM Case WHERE AssetId IN :new Set<Id>{ asset.Id, other.Id }]);
        Assert.isTrue(after.get(inProgress.Id).IsClosed);
        Assert.isTrue(after.get(onHold.Id).IsClosed);
        Assert.isTrue(after.get(inProgress.Id).Description.startsWith('Original\n['), 'The line is appended, the original kept');
        Assert.isTrue(after.get(inProgress.Id).Description.endsWith('Cierre en bloque: Prueba terminada'));
        Assert.isTrue(after.get(onHold.Id).Description.startsWith('['), 'A Case with no description gets just the line');
        Assert.areEqual('Cerrada antes', after.get(alreadyClosed.Id).Description, 'A Case that was already closed is not touched');
        Assert.isFalse(after.get(otherAssetCase.Id).IsClosed, 'Another asset keeps its open intervention');
    }

    @isTest
    static void shouldStillLeaveALine_WhenTheCommentIsBlank() {
        User operator = newUserWithPermissionSet('nccloseblkop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('nccloseblk', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-ALL-3', 2, operator.Id);
        Case c = openCase(asset, operator.Id, 'En curso', 'Original');
        insert c;

        System.runAs(coordinator) {
            IntervencionOperadorController.cerrarIntervencionesDelActivo(asset.Id, null, '   ');
        }

        Case after = [SELECT IsClosed, Description FROM Case WHERE Id = :c.Id];
        Assert.isTrue(after.IsClosed);
        Assert.isTrue(after.Description.endsWith('] Cierre en bloque'), 'The bulk close is traceable even without a comment');
    }

    @isTest
    static void shouldRefuseCloseAll_WhenOperatorLacksThePermission() {
        User operator = newUserWithPermissionSet('nccloseallnoperm', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Asset asset = newAssetWithReading('AST-ALL-4', 2, operator.Id);
        insert new List<Case>{ openCase(asset, operator.Id, 'En curso', null), openCase(asset, operator.Id, 'En curso', null) };

        String error;
        System.runAs(operator) {
            error = closeAllError(asset.Id, null);
        }

        Assert.areEqual(IntervencionOperadorController.NO_PERMISSION_FOLLOW, error);
        Assert.areEqual(2, [SELECT COUNT() FROM Case WHERE AssetId = :asset.Id AND IsClosed = false]);
    }

    @isTest
    static void shouldRefuseCloseAllForLackOfPermissionNotVisibility_WhenGerenteSeesTheAsset() {
        User operator = newUserWithPermissionSet('ncclosegeop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User gerente = newUserWithPermissionSet('ncclosege', 'Nova_Casa_Gerente', GERENTE_ROLE);
        Asset asset = newAssetWithReading('AST-ALL-5', 2, operator.Id);
        insert openCase(asset, operator.Id, 'En curso', null);

        Integer visible;
        String error;
        System.runAs(gerente) {
            visible = [SELECT COUNT() FROM Case WHERE AssetId = :asset.Id WITH USER_MODE];
            error = closeAllError(asset.Id, null);
        }

        Assert.areEqual(1, visible, 'The gerente sees the Case through the role hierarchy');
        Assert.areEqual(IntervencionOperadorController.NO_PERMISSION_FOLLOW, error);
        Assert.areEqual(1, [SELECT COUNT() FROM Case WHERE AssetId = :asset.Id AND IsClosed = false]);
    }

    @isTest
    static void shouldRefuseCloseAll_WhenInputIsBadTheAssetIsInvisibleOrNothingIsOpen() {
        User operator = newUserWithPermissionSet('ncclosebadop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncclosebad', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        User stranger = newUserWithPermissionSet('ncclosestr', 'Nova_Casa_Operator', null);
        Asset hidden = newAssetWithReading('AST-ALL-6', 2, stranger.Id);
        Case hiddenCase = openCase(hidden, stranger.Id, 'En curso', null);
        Asset quiet = newAssetWithReading('AST-ALL-7', 2, operator.Id);
        insert new List<Case>{ hiddenCase, openCase(quiet, operator.Id, 'Closed', null) };

        List<String> errors = new List<String>();
        System.runAs(coordinator) {
            errors.add(closeAllError(null, null));
            errors.add(closeAllError(Id.valueOf('02i000000000000AAA'), null));
            errors.add(closeAllError(hidden.Id, null));
            errors.add(closeAllError(quiet.Id, 'x'.repeat(IntervencionOperadorController.COMMENT_MAX + 1)));
            errors.add(closeAllError(quiet.Id, null));
        }

        Assert.areEqual(new List<String>{
            IntervencionOperadorController.ASSET_NOT_FOUND,
            IntervencionOperadorController.ASSET_NOT_FOUND,
            IntervencionOperadorController.ASSET_NOT_FOUND,
            IntervencionOperadorController.COMMENT_TOO_LONG,
            IntervencionOperadorController.NOTHING_TO_CLOSE
        }, errors);
        Assert.isFalse([SELECT IsClosed FROM Case WHERE Id = :hiddenCase.Id].IsClosed, 'An asset the user cannot see is not touched');
    }

    @isTest
    static void shouldKeepOpenTheCasesTheUserCanOnlyRead_AndCountThemAsFailed() {
        User operator = newUserWithPermissionSet('nccloserowop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('nccloserow', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        User stranger = newUserWithPermissionSet('nccloserowstr', 'Nova_Casa_Operator', null);
        Asset asset = newAssetWithReading('AST-ALL-9', 2, operator.Id);
        Case editable = openCase(asset, operator.Id, 'En curso', null);
        // No AccountId and a foreign owner: the coordinator reaches this Case only through the manual Read share.
        Case readOnly = new Case(AssetId = asset.Id, OwnerId = stranger.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Solo lectura');
        insert new List<Case>{ editable, readOnly };
        insert new CaseShare(CaseId = readOnly.Id, UserOrGroupId = coordinator.Id, CaseAccessLevel = 'Read', RowCause = 'Manual');

        IntervencionOperadorController.CierreResultado result;
        System.runAs(coordinator) {
            result = IntervencionOperadorController.cerrarIntervencionesDelActivo(asset.Id, null, null);
        }

        Assert.areEqual(1, result.cerradas);
        Assert.areEqual(1, result.fallidas, 'The Case the user cannot edit is counted, not closed');
        Assert.isFalse(result.hayMas);
        Assert.isTrue([SELECT IsClosed FROM Case WHERE Id = :editable.Id].IsClosed, 'One failure does not undo the rest');
        Assert.isFalse([SELECT IsClosed FROM Case WHERE Id = :readOnly.Id].IsClosed, 'A read-only Case stays open');
    }

    @isTest
    static void shouldCloseNothingAndAskAgain_WhenTheOpenCountChangedSinceTheUserConfirmed() {
        User operator = newUserWithPermissionSet('ncclosecntop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncclosecnt', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-ALL-10', 2, operator.Id);
        insert new List<Case>{ openCase(asset, operator.Id, 'En curso', null), openCase(asset, operator.Id, 'En curso', null),
            openCase(asset, operator.Id, 'En curso', null) };

        String stale;
        System.runAs(coordinator) {
            stale = closeAllError(asset.Id, 2, null);
        }

        Assert.areEqual(IntervencionOperadorController.COUNT_CHANGED, stale, 'The user confirmed 2 but 3 are open');
        Assert.areEqual(3, [SELECT COUNT() FROM Case WHERE AssetId = :asset.Id AND IsClosed = false], 'A new critical one is not closed unseen');

        System.runAs(coordinator) {
            Assert.areEqual(3, IntervencionOperadorController.cerrarIntervencionesDelActivo(asset.Id, 3, null).cerradas);
        }
    }

    @isTest
    static void shouldWriteASingleAuditLineThatSurvivesAFullDescription_WhenTheCommentHasLineBreaks() {
        User operator = newUserWithPermissionSet('ncclosefmtop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncclosefmt', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-ALL-11', 2, operator.Id);
        Case full = openCase(asset, operator.Id, 'En curso', 'x'.repeat(IntervencionOperadorController.DESCRIPTION_MAX));
        insert full;

        System.runAs(coordinator) {
            IntervencionOperadorController.cerrarIntervencionesDelActivo(asset.Id, null, 'uno\r\n[2026-01-01 00:00 Otra Persona] falso');
        }

        String description = [SELECT Description FROM Case WHERE Id = :full.Id].Description;
        Assert.areEqual(IntervencionOperadorController.DESCRIPTION_MAX, description.length());
        Assert.isTrue(description.endsWith('Cierre en bloque: uno [2026-01-01 00:00 Otra Persona] falso'), 'The new line is kept and flat');
        Assert.isFalse(description.contains('\n[2026-01-01 00:00 Otra Persona]'), 'A typed line break cannot forge an audit line');
    }

    @isTest
    static void shouldCloseNothing_WhenTheUserHoldsTheCustomPermissionButCannotEditCases() {
        User operator = newUserWithPermissionSet('ncclosenoed', 'Nova_Casa_Operator', OPERATOR_ROLE);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet onlyKey = new PermissionSet(Name = 'NcTestSeguirSinEdit', Label = 'NcTestSeguirSinEdit');
            insert onlyKey;
            insert new SetupEntityAccess(
                ParentId = onlyKey.Id,
                SetupEntityId = [SELECT Id FROM CustomPermission WHERE DeveloperName = 'Nova_Casa_Seguir_Intervencion'].Id
            );
            insert new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = onlyKey.Id);
        }
        Asset asset = newAssetWithReading('AST-ALL-12', 2, operator.Id);
        insert new List<Case>{ openCase(asset, operator.Id, 'En curso', null), openCase(asset, operator.Id, 'En curso', null) };

        IntervencionOperadorController.CierreResultado result;
        String error;
        System.runAs(operator) {
            try {
                result = IntervencionOperadorController.cerrarIntervencionesDelActivo(asset.Id, null, null);
            } catch (AuraHandledException e) {
                error = e.getMessage();
            }
        }

        // The key alone is not enough: either the call is refused or every Case is reported as failed.
        Assert.isTrue(error != null || (result.cerradas == 0 && result.fallidas == 2), 'Nothing may be closed without Edit on Case');
        Assert.areEqual(2, [SELECT COUNT() FROM Case WHERE AssetId = :asset.Id AND IsClosed = false]);
    }

    @isTest
    static void shouldCloseTheCapPerCallAndReportThereAreMore_WhenManyAreOpen() {
        User operator = newUserWithPermissionSet('ncclosecapop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncclosecap', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-ALL-8', 2, operator.Id);
        List<Case> many = new List<Case>();
        for (Integer i = 0; i < IntervencionOperadorController.BULK_CLOSE_MAX + 1; i++) {
            many.add(openCase(asset, operator.Id, 'En curso', null));
        }
        insert many;

        IntervencionOperadorController.CierreResultado first;
        IntervencionOperadorController.CierreResultado second;
        System.runAs(coordinator) {
            first = IntervencionOperadorController.cerrarIntervencionesDelActivo(asset.Id, null, null);
            second = IntervencionOperadorController.cerrarIntervencionesDelActivo(asset.Id, null, null);
        }

        Assert.areEqual(IntervencionOperadorController.BULK_CLOSE_MAX, first.cerradas);
        Assert.isTrue(first.hayMas, 'One is left, so the caller must ask again');
        Assert.areEqual(1, second.cerradas);
        Assert.isFalse(second.hayMas);
        Assert.areEqual(0, [SELECT COUNT() FROM Case WHERE AssetId = :asset.Id AND IsClosed = false]);
    }

    // ─── Capabilities per role ────────────────────────────────────────────

    private static ActivosOperadorController.Capacidades capsOf(String prefix, String permissionSet) {
        User u = newUserWithPermissionSet(prefix, permissionSet, null);
        ActivosOperadorController.Capacidades caps;
        System.runAs(u) {
            caps = ActivosOperadorController.getCapacidades();
        }
        return caps;
    }

    @isTest
    static void shouldGiveEachRoleItsOwnActions() {
        ActivosOperadorController.Capacidades op = capsOf('nccapop', 'Nova_Casa_Operator');
        ActivosOperadorController.Capacidades co = capsOf('nccapco', 'Nova_Casa_Coordinator');
        ActivosOperadorController.Capacidades ge = capsOf('nccapge', 'Nova_Casa_Gerente');
        ActivosOperadorController.Capacidades ad = capsOf('nccapad', 'Nova_Casa_Admin');

        Assert.isTrue(op.puedeCrearIntervencion, 'Operator creates');
        Assert.isFalse(op.puedeSeguirIntervencion, 'Operator does not follow up');
        Assert.isFalse(op.puedeTraerSenales);
        Assert.isFalse(op.puedeVerLimites);

        Assert.isTrue(co.puedeCrearIntervencion);
        Assert.isTrue(co.puedeSeguirIntervencion, 'Coordinator follows up');
        Assert.isFalse(co.puedeTraerSenales);
        Assert.isTrue(co.puedeVerLimites, 'Coordinator reaches thresholds');

        Assert.isFalse(ge.puedeCrearIntervencion, 'Gerente only views');
        Assert.isFalse(ge.puedeSeguirIntervencion);
        Assert.isFalse(ge.puedeTraerSenales);

        Assert.isTrue(ad.puedeCrearIntervencion);
        Assert.isTrue(ad.puedeSeguirIntervencion);
        Assert.isTrue(ad.puedeTraerSenales, 'Only admin pulls signals');
        Assert.isTrue(ad.puedeVerLimites);
    }
}
