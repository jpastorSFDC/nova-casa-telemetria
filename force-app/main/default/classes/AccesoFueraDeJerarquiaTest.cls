/**
 * BR-208, T8.5: what a user outside the role hierarchy of a building's owner can reach, checked on the concrete result.
 * The two gaps the other test classes leave open:
 *  1. A coordinator who HOLDS the follow-up permission and has Edit on Case still cannot change a Case that sharing hides
 *     from them, calling the Apex of the follow-up form directly. The same coordinator can change an equivalent Case that
 *     sits under them in the hierarchy, so the refusal comes from sharing, not from the call path.
 *  2. A building outside the hierarchy (the BLD-TEST-NOAUT case of docs/acceso.md) is invisible to the coordinator and to
 *     the manager through every method of the screen controller, not only through SOQL.
 * Users carry the shipped permission sets and roles, as in IntervencionOperadorControllerTest; all data is created here.
 */
@isTest
private class AccesoFueraDeJerarquiaTest {

    private static final String OPERATOR_ROLE = 'Operador_Edificios';
    private static final String COORDINATOR_ROLE = 'Coordinador_Mantenimiento';
    private static final String GERENTE_ROLE = 'Gerente_Regional_Operaciones';

    // Well-formed Ids of the right object that do not exist in any org: what "unknown" means for the safe messages.
    private static final Id UNKNOWN_BUILDING = Id.valueOf('001000000000000AAA');
    private static final Id UNKNOWN_ASSET = Id.valueOf('02i000000000000AAA');

    // ─── Helpers ──────────────────────────────────────────────────────────

    // roleName may be null: that user sits outside every hierarchy. With private sharing (BR-208, D022) a coordinator or
    // manager sees a building only through the role hierarchy, above the operator who owns it.
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

    // Building (owned by ownerId) with one asset and one latest reading of the given severity level.
    private static Asset newAssetWithReading(String code, Integer level, Id ownerId) {
        Account building = new Account(Name = 'Edificio ' + code, OwnerId = ownerId);
        insert building;
        Asset asset = new Asset(Name = 'Activo ' + code, AccountId = building.Id, Tipo_Activo__c = 'WATER_PUMP', External_Id__c = code);
        insert asset;
        insert new Lectura_Vigente__c(
            Asset__c = asset.Id, Clave__c = code + '|TEMPERATURE', Tipo_Medicion__c = 'TEMPERATURE',
            Unidad__c = 'CELSIUS', Valor__c = 50, Occurred_At__c = Datetime.now().addMinutes(-1), Severidad_Nivel__c = level
        );
        return asset;
    }

    private static Case newOpenTelemetryCase(Asset asset, Id ownerId, String description) {
        Case c = new Case(
            AssetId = asset.Id, AccountId = asset.AccountId, OwnerId = ownerId,
            Status = 'En curso', Origin = 'Telemetria', Subject = 'Abierta', Description = description
        );
        insert c;
        return c;
    }

    private static String followUpError(Id caseId, String status, String comment) {
        try {
            IntervencionOperadorController.actualizarSeguimiento(caseId, status, comment);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String closeAllError(Id assetId) {
        try {
            IntervencionOperadorController.cerrarIntervencionesDelActivo(assetId, null, 'x');
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String buildingSummaryError(Id buildingId) {
        try {
            ActivosOperadorController.getResumenEdificio(buildingId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String assetStateError(Id assetId) {
        try {
            ActivosOperadorController.getEstadoActivo(assetId);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String historyError(Id assetId) {
        try {
            ActivosOperadorController.getHistorial(assetId, 10);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static List<String> names(List<ActivosOperadorController.AssetView> views) {
        List<String> names = new List<String>();
        for (ActivosOperadorController.AssetView v : views) {
            names.add(v.name);
        }
        names.sort();
        return names;
    }

    // ─── Test 1: follow-up on a Case that sharing hides ───────────────────

    @isTest
    static void shouldRefuseAsNotFoundAndChangeNothing_WhenACoordinatorWithTheFollowUpPermissionTargetsACaseSharingHides() {
        // Given a real coordinator, an operator under them, and an outsider (no role) who owns a building, asset and open Case
        User operator = newUserWithPermissionSet('nc85op', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User outsider = newUserWithPermissionSet('nc85out', 'Nova_Casa_Operator', null);
        User coordinator = newUserWithPermissionSet('nc85coord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Asset hiddenAsset = newAssetWithReading('AST-85-HID', 2, outsider.Id);
        Case hiddenCase = newOpenTelemetryCase(hiddenAsset, outsider.Id, 'Hidden original');
        // Positive controls: equivalent Cases owned by the operator under the coordinator, one per call under test
        Asset ownAsset = newAssetWithReading('AST-85-OWN', 2, operator.Id);
        Case ownCase = newOpenTelemetryCase(ownAsset, operator.Id, 'Own original');
        Asset ownCloseAsset = newAssetWithReading('AST-85-CLS', 2, operator.Id);
        Case ownCloseCase = newOpenTelemetryCase(ownCloseAsset, operator.Id, 'Close original');

        Boolean holdsTheKey;
        Boolean canEditCase;
        Integer hiddenCaseVisible;
        Integer hiddenAssetVisible;
        Integer ownCaseVisible;
        Integer ownAssetVisible;
        String followUpOnHidden;
        String closeAllOnHidden;
        IntervencionOperadorController.CierreResultado closeAllOnOwn;
        System.runAs(coordinator) {
            // When the coordinator, who holds the permission and has Edit on Case, targets the hidden Case directly
            holdsTheKey = FeatureManagement.checkPermission(IntervencionOperadorController.PERM_SEGUIR);
            canEditCase = Schema.SObjectType.Case.isUpdateable();
            hiddenCaseVisible = [SELECT COUNT() FROM Case WHERE Id = :hiddenCase.Id WITH USER_MODE];
            hiddenAssetVisible = [SELECT COUNT() FROM Asset WHERE Id = :hiddenAsset.Id WITH USER_MODE];
            ownCaseVisible = [SELECT COUNT() FROM Case WHERE Id = :ownCase.Id WITH USER_MODE];
            ownAssetVisible = [SELECT COUNT() FROM Asset WHERE Id = :ownCloseAsset.Id WITH USER_MODE];
            followUpOnHidden = followUpError(hiddenCase.Id, 'Closed', 'x');
            closeAllOnHidden = closeAllError(hiddenAsset.Id);
            // And does the same on the equivalent Case under them
            IntervencionOperadorController.actualizarSeguimiento(ownCase.Id, 'Closed', 'x');
            closeAllOnOwn = IntervencionOperadorController.cerrarIntervencionesDelActivo(ownCloseAsset.Id, 1, 'x');
        }

        // Then the refusal cannot be blamed on a missing permission: the key and Edit on Case are there, only sharing differs
        Assert.isTrue(holdsTheKey, 'The coordinator must hold Nova_Casa_Seguir_Intervencion, or this proves nothing');
        Assert.isTrue(canEditCase, 'Nova_Casa_Coordinator must grant Edit on Case, or this proves nothing');
        Assert.areEqual(0, hiddenCaseVisible, 'Sharing must hide the outsider Case from the coordinator');
        Assert.areEqual(0, hiddenAssetVisible, 'Sharing must hide the outsider asset from the coordinator');
        Assert.areEqual(1, ownCaseVisible, 'The coordinator sees the operator Case through the hierarchy');
        Assert.areEqual(1, ownAssetVisible, 'The coordinator sees the operator asset through the hierarchy');

        // And the hidden Case answers exactly like an unknown one, without being touched
        Assert.areEqual(IntervencionOperadorController.CASE_NOT_FOUND, followUpOnHidden);
        Assert.areEqual(IntervencionOperadorController.ASSET_NOT_FOUND, closeAllOnHidden);
        Case hiddenAfter = [SELECT Status, IsClosed, Description FROM Case WHERE Id = :hiddenCase.Id];
        Assert.areEqual('En curso', hiddenAfter.Status, 'The hidden Case keeps its status');
        Assert.isFalse(hiddenAfter.IsClosed, 'The hidden Case stays open');
        Assert.areEqual('Hidden original', hiddenAfter.Description, 'No comment line is appended to the hidden Case');

        // And the same coordinator did change the equivalent Case under them, so the refusal came from sharing
        Case ownAfter = [SELECT Status, IsClosed, Description FROM Case WHERE Id = :ownCase.Id];
        Assert.areEqual('Closed', ownAfter.Status);
        Assert.isTrue(ownAfter.IsClosed);
        Assert.isTrue(ownAfter.Description.startsWith('Own original\n['), 'The operator Case keeps its text and gets the line');
        Assert.isTrue(ownAfter.Description.endsWith('] x'), 'The comment is appended to the operator Case');
        Assert.areEqual(1, closeAllOnOwn.cerradas);
        Assert.areEqual(0, closeAllOnOwn.fallidas);
        Assert.isFalse(closeAllOnOwn.hayMas);
        Assert.isTrue([SELECT IsClosed FROM Case WHERE Id = :ownCloseCase.Id].IsClosed, 'The operator asset Case is closed in bulk');
    }

    // ─── Test 2: a building outside the hierarchy, through the controllers ─

    @isTest
    static void shouldHideTheBuildingOutsideTheHierarchyFromCoordinatorAndManager_ThroughEveryScreenMethod() {
        // Given building A owned by an operator under both users, and building B owned by an outsider (no role)
        User operator = newUserWithPermissionSet('nc85opa', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User outsider = newUserWithPermissionSet('nc85outb', 'Nova_Casa_Operator', null);
        User coordinator = newUserWithPermissionSet('nc85coor2', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        User manager = newUserWithPermissionSet('nc85mgr', 'Nova_Casa_Gerente', GERENTE_ROLE);
        Asset assetA = newAssetWithReading('AST-85-A', 1, operator.Id);
        Asset assetB = newAssetWithReading('AST-85-B', 2, outsider.Id);
        insert new List<Log_Senial__c>{
            new Log_Senial__c(Asset__c = assetA.Id, Message_Id__c = 'T85-MSG-A', Source__c = 'test-src',
                Message_Type__c = 'MEASUREMENT', Resultado__c = 'Procesada', Occurred_At__c = Datetime.now().addMinutes(-5)),
            new Log_Senial__c(Asset__c = assetB.Id, Message_Id__c = 'T85-MSG-B', Source__c = 'test-src',
                Message_Type__c = 'MEASUREMENT', Resultado__c = 'Procesada', Occurred_At__c = Datetime.now().addMinutes(-5))
        };

        // When each user loads the screen and asks the controllers for each building and asset by Id
        assertBuildingBIsInvisibleAndBuildingAIsServed(coordinator, 'coordinator', assetA, assetB);
        assertBuildingBIsInvisibleAndBuildingAIsServed(manager, 'manager', assetA, assetB);
    }

    private static void assertBuildingBIsInvisibleAndBuildingAIsServed(User who, String label, Asset assetA, Asset assetB) {
        ActivosOperadorController.AssetPage page;
        ActivosOperadorController.BuildingListResult buildings;
        String summaryOfB;
        String stateOfB;
        String historyOfB;
        String summaryOfUnknown;
        String stateOfUnknown;
        String historyOfUnknown;
        ActivosOperadorController.EdificioResumen summaryOfA;
        ActivosOperadorController.EstadoActivo stateOfA;
        ActivosOperadorController.HistoryResult historyOfA;
        System.runAs(who) {
            page = ActivosOperadorController.getAssets(null, null, null);
            buildings = ActivosOperadorController.getBuildings();
            summaryOfB = buildingSummaryError(assetB.AccountId);
            stateOfB = assetStateError(assetB.Id);
            historyOfB = historyError(assetB.Id);
            summaryOfUnknown = buildingSummaryError(UNKNOWN_BUILDING);
            stateOfUnknown = assetStateError(UNKNOWN_ASSET);
            historyOfUnknown = historyError(UNKNOWN_ASSET);
            summaryOfA = ActivosOperadorController.getResumenEdificio(assetA.AccountId);
            stateOfA = ActivosOperadorController.getEstadoActivo(assetA.Id);
            historyOfA = ActivosOperadorController.getHistorial(assetA.Id, 10);
        }

        // Then the list and the building filter hold exactly building A
        Assert.areEqual(new List<String>{ 'Activo AST-85-A' }, names(page.assets), label + ': getAssets returns only building A asset');
        Assert.areEqual(1, page.totalCount, label + ': getAssets counts only building A asset');
        Assert.areEqual(assetA.Id, page.assets[0].assetId, label);
        Assert.areEqual(1, buildings.options.size(), label + ': getBuildings returns only building A');
        Assert.areEqual(String.valueOf(assetA.AccountId), buildings.options[0].value, label);
        Assert.areEqual('Edificio AST-85-A', buildings.options[0].label, label);
        Assert.isFalse(buildings.truncated, label);

        // And every method that takes an Id answers for B exactly as it does for an Id that does not exist
        Assert.areEqual(ActivosOperadorController.BUILDING_SUMMARY_MESSAGE, summaryOfB, label + ': getResumenEdificio(B)');
        Assert.areEqual(ActivosOperadorController.ASSET_STATE_MESSAGE, stateOfB, label + ': getEstadoActivo(B asset)');
        Assert.areEqual(ActivosOperadorController.HISTORY_ASSET_MESSAGE, historyOfB, label + ': getHistorial(B asset)');
        Assert.areEqual(summaryOfUnknown, summaryOfB, label + ': B is indistinguishable from an unknown building');
        Assert.areEqual(stateOfUnknown, stateOfB, label + ': B is indistinguishable from an unknown asset');
        Assert.areEqual(historyOfUnknown, historyOfB, label + ': B history is indistinguishable from an unknown asset');

        // And the same calls do serve building A, so the refusals above come from visibility, not from the call path
        Assert.areEqual(1, summaryOfA.totalActivos, label + ': building A summary');
        Assert.areEqual(1, summaryOfA.activosEnAlerta, label + ': building A summary counts its warning asset');
        Assert.areEqual(0, summaryOfA.activosCriticos, label + ': building B critical asset is not counted');
        Assert.areEqual(1, stateOfA.readings.size(), label + ': asset A state');
        Assert.areEqual(1, stateOfA.readings[0].severityLevel, label + ': asset A state');
        Assert.areEqual(1, historyOfA.signals.size(), label + ': asset A history');
        Assert.areEqual('MEASUREMENT', historyOfA.signals[0].messageType, label + ': asset A history');
    }
}
