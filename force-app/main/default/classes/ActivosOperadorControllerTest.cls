@isTest
private class ActivosOperadorControllerTest {

    private static Integer keyCounter = 0;

    @testSetup
    static void setup() {
        // Setup objects (users, permission sets) in their own runAs block to avoid mixed DML.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            String suffix = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');

            PermissionSet fullPs = newPermissionSet('NC207_Operator_Full');
            PermissionSet noFlsPs = newPermissionSet('NC207_Operator_NoFls');
            insert new List<PermissionSet>{ fullPs, noFlsPs };

            List<ObjectPermissions> objectPerms = new List<ObjectPermissions>();
            for (PermissionSet ps : new List<PermissionSet>{ fullPs, noFlsPs }) {
                for (String obj : new List<String>{ 'Asset', 'Account', 'Contact', 'Case', 'Lectura_Vigente__c' }) {
                    objectPerms.add(new ObjectPermissions(
                        ParentId = ps.Id, SobjectType = obj, PermissionsRead = true));
                }
            }
            // Platform-enforced dependencies: Read Account/Case/Asset require Read Contact (FIELD_INTEGRITY_EXCEPTION).
            insert objectPerms;

            // Only these need FLS: Valor__c, Occurred_At__c, Tipo_Medicion__c, Unidad__c are required and Asset__c is
            // master-detail (always visible); standard Asset/Account/Case fields are visible with object Read.
            List<FieldPermissions> fieldPerms = new List<FieldPermissions>{
                new FieldPermissions(ParentId = fullPs.Id, SobjectType = 'Asset',
                    Field = 'Asset.Tipo_Activo__c', PermissionsRead = true, PermissionsEdit = false),
                new FieldPermissions(ParentId = fullPs.Id, SobjectType = 'Lectura_Vigente__c',
                    Field = 'Lectura_Vigente__c.Severidad_Nivel__c', PermissionsRead = true, PermissionsEdit = false),
                new FieldPermissions(ParentId = fullPs.Id, SobjectType = 'Lectura_Vigente__c',
                    Field = 'Lectura_Vigente__c.Sensor_Id__c', PermissionsRead = true, PermissionsEdit = false),
                // noFlsPs deliberately lacks Asset.Tipo_Activo__c
                new FieldPermissions(ParentId = noFlsPs.Id, SobjectType = 'Lectura_Vigente__c',
                    Field = 'Lectura_Vigente__c.Severidad_Nivel__c', PermissionsRead = true, PermissionsEdit = false),
                new FieldPermissions(ParentId = noFlsPs.Id, SobjectType = 'Lectura_Vigente__c',
                    Field = 'Lectura_Vigente__c.Sensor_Id__c', PermissionsRead = true, PermissionsEdit = false)
            };
            // Standard fields flagged permissionable in the describe need explicit FLS too (object Read is not enough):
            // Asset.AccountId, Case.AssetId, Case.Subject. CaseNumber, Status, IsClosed, Name, CreatedDate do not.
            for (PermissionSet ps : new List<PermissionSet>{ fullPs, noFlsPs }) {
                for (String f : new List<String>{ 'Asset.AccountId', 'Case.AssetId', 'Case.Subject' }) {
                    fieldPerms.add(new FieldPermissions(ParentId = ps.Id, SobjectType = f.substringBefore('.'),
                        Field = f, PermissionsRead = true, PermissionsEdit = false));
                }
            }
            insert fieldPerms;

            User restricted = newUser(p.Id, 'nc207restricted', suffix);
            User operator = newUser(p.Id, 'nc207operator', suffix);
            User noFls = newUser(p.Id, 'nc207nofls', suffix);
            insert new List<User>{ restricted, operator, noFls };

            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = fullPs.Id),
                new PermissionSetAssignment(AssigneeId = noFls.Id, PermissionSetId = noFlsPs.Id)
            };
        }
    }

    @isTest
    static void assetWithoutReadingsHasNoSeverityAndNoIntervention() {
        // Given an asset that never received a signal
        Account building = newAccount('Edificio Sin Datos');
        Asset asset = newAsset('AST-SIN-DATO', building, 'WATER_PUMP');

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(userLike('nc207operator'), null, null, null);

        // Then it shows as 'Sin lecturas' instead of 'Normal'
        Assert.areEqual(1, result.size());
        ActivosOperadorController.AssetView view = result[0];
        Assert.areEqual(asset.Id, view.assetId);
        Assert.areEqual('Edificio Sin Datos', view.accountName);
        Assert.areEqual('WATER_PUMP', view.assetType);
        Assert.isNull(view.severityLevel);
        Assert.areEqual('Sin lecturas', view.severityLabel);
        Assert.isTrue(view.readings.isEmpty());
        Assert.isNull(view.lastSignalAt);
        Assert.isNull(view.openIntervention);
        Assert.areEqual(0, view.openInterventionCount);
    }

    @isTest
    static void assetSeverityIsHighestLatestReadingAndTypesDoNotOverwriteEachOther() {
        // Given one asset whose critical temperature is OLDER than a normal pressure reading
        Account building = newAccount('Edificio A');
        Datetime now = baseTime();
        Asset critical = newAsset('AST-CRIT', building, 'TECHNICAL_ROOM');
        newReading(critical, 'TEMPERATURE', 'CELSIUS', 95, now.addMinutes(-30), 2);
        newReading(critical, 'WATER_PRESSURE', 'BAR', 3, now, 0);
        // and another asset with warning + normal
        Asset warning = newAsset('AST-WARN', building, 'WATER_PUMP');
        newReading(warning, 'TEMPERATURE', 'CELSIUS', 60, now, 1);
        newReading(warning, 'WATER_PRESSURE', 'BAR', 3, now, 0);

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(userLike('nc207operator'), null, null, null);

        // Then each asset shows the highest severity, both readings survive, and the critical one sorts first
        Assert.areEqual(2, result.size());
        Assert.areEqual('AST-CRIT', result[0].name);
        Assert.areEqual(2, result[0].severityLevel);
        Assert.areEqual('Crítica', result[0].severityLabel);
        Assert.areEqual(2, result[0].readings.size());
        Assert.areEqual(now, result[0].lastSignalAt);
        Assert.areEqual('AST-WARN', result[1].name);
        Assert.areEqual(1, result[1].severityLevel);
        Assert.areEqual('Advertencia', result[1].severityLabel);
        ActivosOperadorController.ReadingView temperature = readingOf(result[0], 'TEMPERATURE');
        ActivosOperadorController.ReadingView pressure = readingOf(result[0], 'WATER_PRESSURE');
        Assert.areEqual(95, temperature.value);
        Assert.areEqual(2, temperature.severityLevel);
        Assert.areEqual(0, pressure.severityLevel);
    }

    @isTest
    static void newestReadingOfTheSameTypeReplacesAnOlderCriticalOne() {
        // Given a critical temperature followed by a normal temperature, and a tie at the same instant
        Account building = newAccount('Edificio B');
        Datetime now = baseTime();
        Asset recovered = newAsset('AST-RECOVERED', building, 'WATER_PUMP');
        newReading(recovered, 'TEMPERATURE', 'CELSIUS', 95, now.addMinutes(-10), 2);
        newReading(recovered, 'TEMPERATURE', 'CELSIUS', 20, now, 0);
        Asset tie = newAsset('AST-TIE', building, 'WATER_PUMP');
        newReading(tie, 'TEMPERATURE', 'CELSIUS', 20, now, 0);
        newReading(tie, 'TEMPERATURE', 'CELSIUS', 95, now, 2);

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(userLike('nc207operator'), null, null, null);

        // Then the newest wins, and on a tie the higher severity wins regardless of arrival order
        Map<String, ActivosOperadorController.AssetView> byName = byName(result);
        Assert.areEqual(1, byName.get('AST-RECOVERED').readings.size());
        Assert.areEqual(0, byName.get('AST-RECOVERED').severityLevel);
        Assert.areEqual(1, byName.get('AST-TIE').readings.size());
        Assert.areEqual(2, byName.get('AST-TIE').severityLevel);
    }

    @isTest
    static void onlyOpenCasesCountAsOpenIntervention() {
        // Given an asset with an open case, one with a closed case, and one with both
        Account building = newAccount('Edificio C');
        Asset open = newAsset('AST-OPEN', building, 'WATER_PUMP');
        Asset closed = newAsset('AST-CLOSED', building, 'WATER_PUMP');
        Asset both = newAsset('AST-BOTH', building, 'WATER_PUMP');
        newCase(open, 'New', 'Open one');
        newCase(closed, 'Closed', 'Closed one');
        newCase(both, 'Closed', 'Old closed');
        Case current = newCase(both, 'Working', 'Current open');

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(userLike('nc207operator'), null, null, null);

        // Then only non-closed cases are reported, and the open one is the one returned
        Map<String, ActivosOperadorController.AssetView> byName = byName(result);
        Assert.isNotNull(byName.get('AST-OPEN').openIntervention);
        Assert.areEqual('New', byName.get('AST-OPEN').openIntervention.status);
        Assert.areEqual(1, byName.get('AST-OPEN').openInterventionCount);
        Assert.isNull(byName.get('AST-CLOSED').openIntervention);
        Assert.areEqual(0, byName.get('AST-CLOSED').openInterventionCount);
        Assert.areEqual(current.Id, byName.get('AST-BOTH').openIntervention.caseId);
        Assert.areEqual(1, byName.get('AST-BOTH').openInterventionCount);
    }

    @isTest
    static void filtersNarrowByBuildingSeverityAndType() {
        // Given assets across two buildings, two severities and two types
        Account north = newAccount('Edificio Norte');
        Account south = newAccount('Edificio Sur');
        Datetime now = baseTime();
        Asset a1 = newAsset('AST-N-CRIT', north, 'WATER_PUMP');
        newReading(a1, 'TEMPERATURE', 'CELSIUS', 95, now, 2);
        Asset a2 = newAsset('AST-N-OK', north, 'ENERGY_METER');
        newReading(a2, 'TEMPERATURE', 'CELSIUS', 20, now, 0);
        Asset a3 = newAsset('AST-S-CRIT', south, 'ENERGY_METER');
        newReading(a3, 'TEMPERATURE', 'CELSIUS', 95, now, 2);
        User operator = userLike('nc207operator');

        // When filtering by building
        List<ActivosOperadorController.AssetView> byBuilding = load(operator, north.Id, null, null);
        // Then only that building's assets come back
        Assert.areEqual(new List<String>{ 'AST-N-CRIT', 'AST-N-OK' }, names(byBuilding));

        // When filtering by severity
        List<ActivosOperadorController.AssetView> bySeverity = load(operator, null, 2, null);
        // Then only critical assets come back
        Assert.areEqual(new List<String>{ 'AST-N-CRIT', 'AST-S-CRIT' }, names(bySeverity));
        Assert.areEqual(1, names(load(operator, null, 0, null)).size());

        // When filtering by type
        List<ActivosOperadorController.AssetView> byType = load(operator, null, null, 'ENERGY_METER');
        // Then only that type comes back
        Assert.areEqual(new List<String>{ 'AST-N-OK', 'AST-S-CRIT' }, names(byType));

        // When combining all three, and when passing blank strings
        List<ActivosOperadorController.AssetView> combined = load(operator, south.Id, 2, 'ENERGY_METER');
        List<ActivosOperadorController.AssetView> blanks = load(operator, '', null, '');
        // Then filters intersect, and blanks mean "no filter"
        Assert.areEqual(new List<String>{ 'AST-S-CRIT' }, names(combined));
        Assert.areEqual(3, blanks.size());
        Assert.areEqual(0, load(operator, north.Id, 2, 'ENERGY_METER').size());
    }

    @isTest
    static void invalidFiltersAreRejectedWithASafeMessage() {
        // Given a valid operator
        User operator = userLike('nc207operator');

        // When the severity is out of range or the building is not an Id
        // Then the user gets a safe AuraHandledException, not a raw error
        for (List<Object> args : new List<List<Object>>{
            new List<Object>{ null, 7 },
            new List<Object>{ 'not-an-id', null }
        }) {
            Boolean rejected = false;
            System.runAs(operator) {
                try {
                    ActivosOperadorController.getAssets((String) args[0], (Integer) args[1], null);
                } catch (AuraHandledException e) {
                    rejected = true;
                    Assert.isTrue(e.getMessage().contains('not valid'), 'Unexpected message: ' + e.getMessage());
                }
            }
            Assert.isTrue(rejected, 'Invalid filter should be rejected');
        }
    }

    @isTest
    static void buildingsListsOnlyBuildingsWithAssets() {
        // Given one building with an asset and one without
        Account withAsset = newAccount('Edificio Con Activo');
        newAccount('Edificio Vacio');
        newAsset('AST-B', withAsset, 'WATER_PUMP');

        // When the operator loads the building options
        ActivosOperadorController.BuildingListResult result;
        System.runAs(userLike('nc207operator')) {
            result = ActivosOperadorController.getBuildings();
        }

        // Then only the building that has an asset is offered
        Assert.areEqual(1, result.options.size());
        Assert.areEqual(withAsset.Id, result.options[0].value);
        Assert.areEqual('Edificio Con Activo', result.options[0].label);
        Assert.isFalse(result.truncated);
    }

    @isTest
    static void buildingsAreFlaggedWhenOverTheBound() {
        // Given two buildings with assets and a bound of one
        newAsset('AST-B1', newAccount('Edificio 1'), 'WATER_PUMP');
        newAsset('AST-B2', newAccount('Edificio 2'), 'WATER_PUMP');
        ActivosOperadorController.maxBuildings = 1;

        // When the operator loads the building options
        ActivosOperadorController.BuildingListResult result;
        System.runAs(userLike('nc207operator')) {
            result = ActivosOperadorController.getBuildings();
        }

        // Then one is returned and the caller is told the list is cut
        Assert.areEqual(1, result.options.size());
        Assert.isTrue(result.truncated);
    }

    @isTest
    static void mostSevereAssetsSurviveThePageCutEvenWhenTheirNameSortsLast() {
        // Given three assets where the critical one sorts last by name, and a page of two
        Account building = newAccount('Edificio Paginado');
        Datetime now = baseTime();
        newReading(newAsset('AST-A', building, 'WATER_PUMP'), 'TEMPERATURE', 'CELSIUS', 20, now, 0);
        newReading(newAsset('AST-B', building, 'WATER_PUMP'), 'TEMPERATURE', 'CELSIUS', 60, now, 1);
        newReading(newAsset('AST-Z', building, 'WATER_PUMP'), 'TEMPERATURE', 'CELSIUS', 95, now, 2);
        ActivosOperadorController.pageSize = 2;
        User operator = userLike('nc207operator');

        // When the operator loads the list, unfiltered and filtered by critical
        ActivosOperadorController.AssetPage all = loadResult(operator, null, null, null);
        ActivosOperadorController.AssetPage critical = loadResult(operator, null, 2, null);

        // Then the critical asset leads, the cut is reported, and the severity filter still finds it
        Assert.areEqual(new List<String>{ 'AST-Z', 'AST-B' }, new List<String>{ all.assets[0].name, all.assets[1].name });
        Assert.areEqual(3, all.totalCount);
        Assert.areEqual(2, all.assetLimit);
        Assert.isTrue(all.truncated);
        Assert.areEqual(1, critical.assets.size());
        Assert.areEqual('AST-Z', critical.assets[0].name);
        Assert.areEqual(1, critical.totalCount);
        Assert.isFalse(critical.truncated);
    }

    @isTest
    static void scanCeilingIsReportedAsTruncated() {
        // Given more assets than the scan ceiling
        Account building = newAccount('Edificio Grande');
        newAsset('AST-1', building, 'WATER_PUMP');
        newAsset('AST-2', building, 'WATER_PUMP');
        newAsset('AST-3', building, 'WATER_PUMP');
        ActivosOperadorController.maxScan = 2;

        // When the operator loads the list
        ActivosOperadorController.AssetPage result = loadResult(userLike('nc207operator'), null, null, null);

        // Then only the scanned assets are ranked and the caller is told it is truncated
        Assert.areEqual(2, result.totalCount);
        Assert.isTrue(result.truncated);
        Assert.areEqual(100, result.assetLimit);
    }

    @isTest
    static void equalSeverityAndOccurredAtResolvesByRecordIdNotArrivalOrder() {
        // Given two readings of the same type with the same severity and instant but different values
        Account building = newAccount('Edificio Empate');
        Asset asset = newAsset('AST-TIE-ID', building, 'WATER_PUMP');
        Datetime now = baseTime();
        Lectura_Vigente__c first = newReading(asset, 'TEMPERATURE', 'CELSIUS', 91, now, 2);
        Lectura_Vigente__c second = newReading(asset, 'TEMPERATURE', 'CELSIUS', 92, now, 2);
        Lectura_Vigente__c expected = String.valueOf(first.Id) > String.valueOf(second.Id) ? first : second;

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(userLike('nc207operator'), null, null, null);

        // Then the higher record Id wins every time
        Assert.areEqual(1, result[0].readings.size());
        Assert.areEqual(expected.Valor__c, result[0].readings[0].value);
    }

    @isTest
    static void userWithoutObjectAccessIsDeniedWithASafeError() {
        // Given data that exists and that an admin can see
        Account building = newAccount('Edificio Privado');
        Asset asset = newAsset('AST-PRIV', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);
        newCase(asset, 'New', 'Secret case');
        Assert.areEqual(1, ActivosOperadorController.getAssets(null, null, null).assets.size());

        // When a user with no object access asks the server directly
        AuraHandledException assetsError;
        AuraHandledException buildingsError;
        System.runAs(userLike('nc207restricted')) {
            try {
                ActivosOperadorController.getAssets(null, null, null);
            } catch (AuraHandledException e) {
                assetsError = e;
            }
            try {
                ActivosOperadorController.getBuildings();
            } catch (AuraHandledException e) {
                buildingsError = e;
            }
        }

        // Then USER_MODE denies the query and both calls fail with the static access message
        Assert.isNotNull(assetsError, 'getAssets must throw for a user without object access');
        Assert.areEqual(ActivosOperadorController.ACCESS_MESSAGE, assetsError.getMessage());
        Assert.isNotNull(buildingsError, 'getBuildings must throw for a user without object access');
        Assert.areEqual(ActivosOperadorController.ACCESS_MESSAGE, buildingsError.getMessage());
    }

    @isTest
    static void userMissingFieldAccessGetsAnErrorInsteadOfPartialData() {
        // Given data and a user who can read the objects but not Asset.Tipo_Activo__c
        Account building = newAccount('Edificio FLS');
        Asset asset = newAsset('AST-FLS', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);

        // When that user asks for the list
        AuraHandledException error;
        System.runAs(userLike('nc207nofls')) {
            try {
                ActivosOperadorController.getAssets(null, null, null);
            } catch (AuraHandledException e) {
                error = e;
            }
        }

        // Then the call fails with the static message, which names no field or object
        Assert.isNotNull(error, 'Missing FLS must raise an AuraHandledException');
        Assert.areEqual(ActivosOperadorController.ACCESS_MESSAGE, error.getMessage());
        Assert.isFalse(error.getMessage().contains('Tipo_Activo__c'));
        Assert.isFalse(error.getMessage().containsIgnoreCase('Asset'));
    }

    @isTest
    static void readingsWithoutASeverityLevelAreNeverCountedAsNormal() {
        // Given an asset whose only reading has no level, one that mixes a null level with a level-0 reading,
        // and a plain normal asset
        Account building = newAccount('Edificio Nulos');
        Datetime now = baseTime();
        Asset nullOnly = newAsset('AST-NULL', building, 'WATER_PUMP');
        newReading(nullOnly, 'TEMPERATURE', 'CELSIUS', 20, now, null);
        Asset mixed = newAsset('AST-MIXED', building, 'WATER_PUMP');
        newReading(mixed, 'TEMPERATURE', 'CELSIUS', 20, now, null);
        newReading(mixed, 'WATER_PRESSURE', 'BAR', 3, now, 0);
        Asset normal = newAsset('AST-NORMAL', building, 'WATER_PUMP');
        newReading(normal, 'TEMPERATURE', 'CELSIUS', 20, now, 0);
        User operator = userLike('nc207operator');

        // When the operator loads the list unfiltered and filtered by Normal
        Map<String, ActivosOperadorController.AssetView> all = byName(load(operator, null, null, null));
        ActivosOperadorController.AssetPage normalOnly = loadResult(operator, null, 0, null);

        // Then the null-only asset has no level and reads 'Sin dato', not 'Normal'
        Assert.areEqual(3, all.size());
        Assert.isNull(all.get('AST-NULL').severityLevel);
        Assert.areEqual('Sin dato', all.get('AST-NULL').severityLabel);
        Assert.areEqual(1, all.get('AST-NULL').readings.size());
        Assert.isNull(all.get('AST-NULL').readings[0].severityLevel);
        Assert.areEqual('Sin dato', all.get('AST-NULL').readings[0].severityLabel);
        // and the mixed asset ignores the null and takes the level-0 reading
        Assert.areEqual(0, all.get('AST-MIXED').severityLevel);
        Assert.areEqual('Normal', all.get('AST-MIXED').severityLabel);
        Assert.isNull(readingOf(all.get('AST-MIXED'), 'TEMPERATURE').severityLevel);
        // and the Normal filter keeps the mixed and normal assets but not the null-only one
        Assert.areEqual(new List<String>{ 'AST-MIXED', 'AST-NORMAL' }, names(normalOnly.assets));
        Assert.areEqual(2, normalOnly.totalCount);
    }

    @isTest
    static void readingRowCapIsReportedAsTruncated() {
        // Given one asset with exactly the cap of readings (5 types x 1 asset)
        Account building = newAccount('Edificio Lecturas');
        Datetime now = baseTime();
        Asset atCap = newAsset('AST-AT-CAP', building, 'WATER_PUMP');
        for (Integer i = 0; i < 5; i++) {
            newReading(atCap, 'TEMPERATURE', 'CELSIUS', 20 + i, now.addMinutes(-i), 0);
        }
        User operator = userLike('nc207operator');

        // When the operator loads the list
        ActivosOperadorController.AssetPage exact = loadResult(operator, null, null, null);

        // Then nothing is cut, so the list is not flagged
        Assert.isFalse(exact.truncated, 'Exactly at the readings cap is not a cut');

        // When one more reading pushes the asset over the cap
        newReading(atCap, 'TEMPERATURE', 'CELSIUS', 99, now.addMinutes(-10), 0);
        ActivosOperadorController.AssetPage over = loadResult(operator, null, null, null);

        // Then the readings cap is reported through truncated
        Assert.isTrue(over.truncated, 'Readings beyond assets x 5 must set truncated');
        Assert.areEqual(1, over.totalCount);
    }

    @isTest
    static void realOperatorPermissionSetCanReadTheListButNotThresholds() {
        // Given a user holding only the shipped Nova_Casa_Operator permission set
        User realOperator = newUserWithPermissionSet('nc207realop', 'Nova_Casa_Operator');
        Account building = newAccount('Edificio Operador Real');
        Asset asset = newAsset('AST-REAL-OP', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);
        newCase(asset, 'New', 'Real operator case');

        // When that user loads assets and buildings, and checks the thresholds object
        ActivosOperadorController.AssetPage page;
        ActivosOperadorController.BuildingListResult buildings;
        Boolean umbralReadable;
        Boolean caseEditable;
        System.runAs(realOperator) {
            page = ActivosOperadorController.getAssets(null, null, null);
            buildings = ActivosOperadorController.getBuildings();
            umbralReadable = Schema.sObjectType.Umbral__c.isAccessible();
            caseEditable = Schema.sObjectType.Case.isUpdateable();
        }

        // Then the shipped set is enough for the screen, with the expected data
        Assert.areEqual(1, page.assets.size());
        Assert.areEqual('AST-REAL-OP', page.assets[0].name);
        Assert.areEqual('Edificio Operador Real', page.assets[0].accountName);
        Assert.areEqual('WATER_PUMP', page.assets[0].assetType);
        Assert.areEqual(2, page.assets[0].severityLevel);
        Assert.areEqual(1, page.assets[0].openInterventionCount);
        Assert.areEqual(1, buildings.options.size());
        Assert.areEqual(building.Id, buildings.options[0].value);
        // and the operator cannot read thresholds or edit cases
        Assert.isFalse(umbralReadable, 'Nova_Casa_Operator must not grant Umbral__c');
        Assert.isFalse(caseEditable, 'Nova_Casa_Operator is read-only on Case');
    }

    @isTest
    static void realCoordinatorPermissionSetCanReadTheListAndThresholds() {
        // Given a user holding only the shipped Nova_Casa_Coordinator permission set
        User realCoordinator = newUserWithPermissionSet('nc207realcoord', 'Nova_Casa_Coordinator');
        Account building = newAccount('Edificio Coordinador Real');
        Asset asset = newAsset('AST-REAL-CO', building, 'ENERGY_METER');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 60, baseTime(), 1);

        // When that user loads assets and buildings
        ActivosOperadorController.AssetPage page;
        ActivosOperadorController.BuildingListResult buildings;
        Boolean umbralReadable;
        System.runAs(realCoordinator) {
            page = ActivosOperadorController.getAssets(null, null, null);
            buildings = ActivosOperadorController.getBuildings();
            umbralReadable = Schema.sObjectType.Umbral__c.isAccessible();
        }

        // Then the screen works with the expected data, and thresholds are readable for the coordinator
        Assert.areEqual(1, page.assets.size());
        Assert.areEqual('AST-REAL-CO', page.assets[0].name);
        Assert.areEqual(1, page.assets[0].severityLevel);
        Assert.areEqual('Advertencia', page.assets[0].severityLabel);
        Assert.areEqual(1, buildings.options.size());
        Assert.areEqual(building.Id, buildings.options[0].value);
        Assert.isTrue(umbralReadable, 'Nova_Casa_Coordinator grants Umbral__c read');
    }

    // ---------- helpers ----------

    // Assigns a SHIPPED permission set (by Name) to a fresh user. Call before inserting data rows in the test.
    private static User newUserWithPermissionSet(String prefix, String permissionSetName) {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName];
            Assert.areEqual(1, sets.size(), permissionSetName + ' must be deployed to the org');
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            u = newUser(p.Id, prefix, String.valueOf(Crypto.getRandomInteger()).replace('-', 'n'));
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = sets[0].Id);
        }
        return u;
    }

    private static List<ActivosOperadorController.AssetView> load(User runAs, String accountId, Integer severity, String type) {
        return loadResult(runAs, accountId, severity, type).assets;
    }

    private static ActivosOperadorController.AssetPage loadResult(User runAs, String accountId, Integer severity, String type) {
        ActivosOperadorController.AssetPage result;
        System.runAs(runAs) {
            result = ActivosOperadorController.getAssets(accountId, severity, type);
        }
        return result;
    }

    private static List<String> names(List<ActivosOperadorController.AssetView> views) {
        List<String> names = new List<String>();
        for (ActivosOperadorController.AssetView v : views) {
            names.add(v.name);
        }
        names.sort();
        return names;
    }

    private static Map<String, ActivosOperadorController.AssetView> byName(List<ActivosOperadorController.AssetView> views) {
        Map<String, ActivosOperadorController.AssetView> result = new Map<String, ActivosOperadorController.AssetView>();
        for (ActivosOperadorController.AssetView v : views) {
            result.put(v.name, v);
        }
        return result;
    }

    private static ActivosOperadorController.ReadingView readingOf(ActivosOperadorController.AssetView view, String type) {
        for (ActivosOperadorController.ReadingView r : view.readings) {
            if (r.measurementType == type) {
                return r;
            }
        }
        Assert.fail('No reading of type ' + type);
        return null;
    }

    // Whole seconds: DateTime fields do not keep milliseconds.
    private static Datetime baseTime() {
        return Datetime.newInstanceGmt(2026, 10, 1, 12, 0, 0);
    }

    private static User userLike(String prefix) {
        String pattern = prefix + '%';
        return [SELECT Id FROM User WHERE Username LIKE :pattern LIMIT 1];
    }

    private static PermissionSet newPermissionSet(String name) {
        return new PermissionSet(Name = name, Label = name);
    }

    private static User newUser(Id profileId, String prefix, String suffix) {
        return new User(
            Username = prefix + '.' + suffix + '@novacasa-test.example.com',
            Alias = prefix.right(8),
            Email = prefix + '@novacasa-test.example.com',
            LastName = prefix,
            ProfileId = profileId,
            TimeZoneSidKey = 'America/Bogota',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    private static Account newAccount(String name) {
        Account acc = new Account(Name = name);
        insert acc;
        return acc;
    }

    private static Asset newAsset(String name, Account building, String type) {
        Asset asset = new Asset(Name = name, AccountId = building.Id, Tipo_Activo__c = type);
        insert asset;
        return asset;
    }

    private static Lectura_Vigente__c newReading(Asset asset, String type, String unit, Decimal value, Datetime at, Integer level) {
        keyCounter++;
        Lectura_Vigente__c r = new Lectura_Vigente__c(
            Asset__c = asset.Id,
            Clave__c = 'TEST-' + keyCounter,
            Tipo_Medicion__c = type,
            Unidad__c = unit,
            Valor__c = value,
            Occurred_At__c = at,
            Severidad_Nivel__c = level
        );
        insert r;
        return r;
    }

    private static Case newCase(Asset asset, String status, String subject) {
        Case c = new Case(AssetId = asset.Id, Status = status, Subject = subject, Origin = 'Web');
        insert c;
        return c;
    }
}
