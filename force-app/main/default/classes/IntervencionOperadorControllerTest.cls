/**
 * Tests for IntervencionOperadorController (D020) and the capabilities of ActivosOperadorController.
 * Users carry the shipped permission sets, so these also fail if a custom permission is dropped from one.
 */
@isTest
private class IntervencionOperadorControllerTest {

    private static final String OPERATOR_ROLE = 'Operador_Edificios';
    private static final String COORDINATOR_ROLE = 'Coordinador_Mantenimiento';
    private static final String GERENTE_ROLE = 'Gerente_Regional_Operaciones';

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
        Case existing = new Case(AssetId = asset.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Ya abierta');
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

    // ─── actualizarSeguimiento ────────────────────────────────────────────

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
    static void shouldRefuseFollowUp_WhenStatusIsNotAllowedOrInputIsBad() {
        User operator = newUserWithPermissionSet('ncfupbadop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('ncfupbad', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset asset = newAssetWithReading('AST-FUP-4', 2, operator.Id);
        Case c = new Case(AssetId = asset.Id, OwnerId = operator.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Abierta');
        insert c;

        List<String> errors = new List<String>();
        System.runAs(coordinator) {
            for (List<Object> args : new List<List<Object>>{
                new List<Object>{ c.Id, 'Escalated', null },
                new List<Object>{ c.Id, null, null },
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
