@isTest
private class ActivosOperadorControllerTest {

    private static final String OPERATOR_ROLE = 'Operador_Edificios';
    private static final String COORDINATOR_ROLE = 'Coordinador_Mantenimiento';
    private static final String GERENTE_ROLE = 'Gerente_Regional_Operaciones';
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
                new FieldPermissions(ParentId = fullPs.Id, SobjectType = 'Asset',
                    Field = 'Asset.External_Id__c', PermissionsRead = true, PermissionsEdit = false),
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
            // The coordinator sees this operator's buildings through the role hierarchy.
            operator.UserRoleId = roleId(OPERATOR_ROLE);
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
            new List<Object>{ null, 7, ActivosOperadorController.SEVERITY_FILTER_MESSAGE },
            new List<Object>{ 'not-an-id', null, ActivosOperadorController.BUILDING_FILTER_MESSAGE }
        }) {
            Boolean rejected = false;
            System.runAs(operator) {
                try {
                    ActivosOperadorController.getAssets((String) args[0], (Integer) args[1], null);
                } catch (AuraHandledException e) {
                    rejected = true;
                    Assert.areEqual((String) args[2], e.getMessage(), 'Unexpected message');
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
        Account building = newAccount('Edificio Privado', UserInfo.getUserId());
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
        // Given data owned by a user who can read the objects but not Asset.Tipo_Activo__c
        Account building = newAccount('Edificio FLS', userLike('nc207nofls').Id);
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
    static void catalogExternalIdIsReturnedAndBlankWhenTheAssetHasNone() {
        // Given one asset with a catalog code and one without
        Account building = newAccount('Edificio ID');
        Asset withCode = newAsset('AST-WITH-CODE', building, 'WATER_PUMP');
        setExternalId(withCode, 'AST-TST-001');
        newAsset('AST-NO-CODE', building, 'WATER_PUMP');

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(userLike('nc207operator'), null, null, null);

        // Then the code reaches the view, and a missing code is null (never invented)
        Assert.areEqual(2, result.size());
        // (equal severity, so they sort by name)
        Assert.areEqual('AST-NO-CODE', result[0].name);
        Assert.isNull(result[0].externalId);
        Assert.areEqual('AST-WITH-CODE', result[1].name);
        Assert.areEqual('AST-TST-001', result[1].externalId);
    }

    @isTest
    static void realOperatorPermissionSetCanReadTheListButNotThresholds() {
        // Given a user holding only the shipped Nova_Casa_Operator permission set
        User realOperator = newUserWithPermissionSet('nc207realop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Operador Real', realOperator.Id);
        Asset asset = newAsset('AST-REAL-OP', building, 'WATER_PUMP');
        setExternalId(asset, 'AST-TST-OP');
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
        Assert.areEqual('AST-TST-OP', page.assets[0].externalId, 'Nova_Casa_Operator must grant Asset.External_Id__c');
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
        // Given a user holding only the shipped Nova_Casa_Coordinator permission set, above the building's operator
        User realCoordinator = newUserWithPermissionSet('nc207realcoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Account building = newAccount('Edificio Coordinador Real');
        Asset asset = newAsset('AST-REAL-CO', building, 'ENERGY_METER');
        setExternalId(asset, 'AST-TST-CO');
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
        Assert.areEqual('AST-TST-CO', page.assets[0].externalId, 'Nova_Casa_Coordinator must grant Asset.External_Id__c');
        Assert.areEqual(1, page.assets[0].severityLevel);
        Assert.areEqual('Advertencia', page.assets[0].severityLabel);
        Assert.areEqual(1, buildings.options.size());
        Assert.areEqual(building.Id, buildings.options[0].value);
        Assert.isTrue(umbralReadable, 'Nova_Casa_Coordinator grants Umbral__c read');
    }

    @isTest
    static void realGerentePermissionSetSeesOperatorBuildingThroughHierarchyOnly() {
        // Given a user holding only Nova_Casa_Gerente, who owns nothing and sits two roles above the building's operator
        User realGerente = newUserWithPermissionSet('nc207realgerente', 'Nova_Casa_Gerente', GERENTE_ROLE);
        Account building = newAccount('Edificio Gerente Real');
        Asset asset = newAsset('AST-REAL-GE', building, 'ENERGY_METER');
        setExternalId(asset, 'AST-TST-GE');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 60, baseTime(), 1);

        // When that user loads assets and buildings
        ActivosOperadorController.AssetPage page;
        ActivosOperadorController.BuildingListResult buildings;
        System.runAs(realGerente) {
            page = ActivosOperadorController.getAssets(null, null, null);
            buildings = ActivosOperadorController.getBuildings();
        }

        // Then the building, its asset and its reading are visible through the role hierarchy
        Assert.areEqual(1, page.assets.size());
        Assert.areEqual('AST-REAL-GE', page.assets[0].name);
        Assert.areEqual('AST-TST-GE', page.assets[0].externalId, 'Nova_Casa_Gerente must grant Asset.External_Id__c');
        Assert.areEqual(1, page.assets[0].readings.size());
        Assert.areEqual(1, buildings.options.size());
        Assert.areEqual(building.Id, buildings.options[0].value);
    }

    @isTest
    static void operatorDoesNotSeeAnotherOperatorsBuildingButGerenteSeesBoth() {
        // Given two operators (same role and permission set) and a Gerente above both
        User operatorB = newUserWithPermissionSet('nc207operator2', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User gerente = newUserWithPermissionSet('nc207gerenteiso', 'Nova_Casa_Gerente', GERENTE_ROLE);
        User operatorA = userLike('nc207operator');
        Assert.areNotEqual(operatorA.Id, operatorB.Id, 'userLike must not resolve operator A to operator B');
        Account buildingA = newAccount('Edificio Operador A', operatorA.Id);
        Account buildingB = newAccount('Edificio Operador B', operatorB.Id);
        newAsset('AST-ISO-A', buildingA, 'WATER_PUMP');
        newAsset('AST-ISO-B', buildingB, 'WATER_PUMP');

        // When each user loads assets and buildings
        ActivosOperadorController.AssetPage pageB;
        ActivosOperadorController.BuildingListResult buildingsB;
        System.runAs(operatorB) {
            pageB = ActivosOperadorController.getAssets(null, null, null);
            buildingsB = ActivosOperadorController.getBuildings();
        }
        ActivosOperadorController.AssetPage pageA;
        ActivosOperadorController.BuildingListResult buildingsA;
        System.runAs(operatorA) {
            pageA = ActivosOperadorController.getAssets(null, null, null);
            buildingsA = ActivosOperadorController.getBuildings();
        }
        ActivosOperadorController.AssetPage pageG;
        ActivosOperadorController.BuildingListResult buildingsG;
        System.runAs(gerente) {
            pageG = ActivosOperadorController.getAssets(null, null, null);
            buildingsG = ActivosOperadorController.getBuildings();
        }

        // Then each operator sees only their own building, and the Gerente sees both
        Assert.areEqual(new List<String>{ 'AST-ISO-B' }, names(pageB.assets), 'operator B must not see operator A building');
        Assert.areEqual(1, buildingsB.options.size());
        Assert.areEqual(buildingB.Id, buildingsB.options[0].value);
        Assert.areEqual(new List<String>{ 'AST-ISO-A' }, names(pageA.assets), 'operator A must not see operator B building');
        Assert.areEqual(1, buildingsA.options.size());
        Assert.areEqual(buildingA.Id, buildingsA.options[0].value);
        Assert.areEqual(new List<String>{ 'AST-ISO-A', 'AST-ISO-B' }, names(pageG.assets));
        Assert.areEqual(2, buildingsG.options.size());
    }

    @isTest
    static void historyIsNewestFirstAndRespectsTheLimitAndItsClamp() {
        // Given an asset with 3 signals inserted out of order
        Account building = newAccount('Edificio Historial');
        Asset asset = newAsset('AST-HIST', building, 'WATER_PUMP');
        Datetime now = baseTime();
        newLog(asset, 'MEASUREMENT', 'Procesada', now.addMinutes(-30), null, null);
        newLog(asset, 'CONNECTIVITY', 'Atrasada', now, null, null);
        newLog(asset, 'MEASUREMENT', 'Duplicada', now.addMinutes(-10), null, null);
        User operator = userLike('nc207operator');

        // When the operator asks for the history
        ActivosOperadorController.HistoryResult all = history(operator, asset.Id, null);
        ActivosOperadorController.HistoryResult two = history(operator, asset.Id, 2);
        ActivosOperadorController.HistoryResult floor = history(operator, asset.Id, 0);
        ActivosOperadorController.HistoryResult negative = history(operator, asset.Id, -5);

        // Then it is newest first, the default fits everything, and the limit cuts and flags truncation
        Assert.areEqual(3, all.signals.size());
        Assert.areEqual(ActivosOperadorController.HISTORY_DEFAULT_LIMIT, all.limite);
        Assert.isFalse(all.truncated);
        Assert.areEqual(now, all.signals[0].occurredAt);
        Assert.areEqual('CONNECTIVITY', all.signals[0].messageType);
        Assert.areEqual('Atrasada', all.signals[0].resultado);
        Assert.areEqual(now.addMinutes(-10), all.signals[1].occurredAt);
        Assert.areEqual(now.addMinutes(-30), all.signals[2].occurredAt);
        Assert.areEqual(2, two.signals.size());
        Assert.isTrue(two.truncated);
        Assert.areEqual(now, two.signals[0].occurredAt);
        Assert.areEqual(now.addMinutes(-10), two.signals[1].occurredAt);
        Assert.areEqual(1, floor.limite, 'limit below 1 is clamped to 1');
        Assert.areEqual(1, floor.signals.size());
        Assert.areEqual(1, negative.limite);
    }

    @isTest
    static void historyLimitIsCappedAtFifty() {
        // Given an asset with 55 signals
        Account building = newAccount('Edificio Historial Grande');
        Asset asset = newAsset('AST-HIST-BIG', building, 'WATER_PUMP');
        Datetime now = baseTime();
        List<Log_Senial__c> logs = new List<Log_Senial__c>();
        for (Integer i = 0; i < 55; i++) {
            logs.add(logRow(asset, 'MEASUREMENT', 'Procesada', now.addMinutes(-i), null, null));
        }
        insert logs;

        // When 500 rows are requested
        ActivosOperadorController.HistoryResult result = history(userLike('nc207operator'), asset.Id, 500);

        // Then only 50 come back, the newest ones, flagged as truncated
        Assert.areEqual(50, result.limite);
        Assert.areEqual(50, result.signals.size());
        Assert.isTrue(result.truncated);
        Assert.areEqual(now, result.signals[0].occurredAt);
        Assert.areEqual(now.addMinutes(-49), result.signals[49].occurredAt);
    }

    @isTest
    static void historyOnlyReturnsRowsOfTheRequestedAsset() {
        // Given two assets, each with its own signals
        Account building = newAccount('Edificio Dos Activos');
        Asset a = newAsset('AST-HIST-A', building, 'WATER_PUMP');
        Asset b = newAsset('AST-HIST-B', building, 'WATER_PUMP');
        Datetime now = baseTime();
        newLog(a, 'MEASUREMENT', 'Procesada', now, null, null);
        newLog(b, 'CONNECTIVITY', 'Rechazada', now.addMinutes(1), null, null);
        newLog(b, 'CONNECTIVITY', 'Rechazada', now.addMinutes(2), null, null);

        // When the history of A is requested
        ActivosOperadorController.HistoryResult result = history(userLike('nc207operator'), a.Id, null);

        // Then B's rows are not returned
        Assert.areEqual(1, result.signals.size());
        Assert.areEqual('MEASUREMENT', result.signals[0].messageType);
        Assert.areEqual('Procesada', result.signals[0].resultado);
    }

    @isTest
    static void historyIsDeniedForAnAssetTheUserCannotSeeButWorksForTheGerente() {
        // Given two operators, a Gerente above both, and a signal on operator A's asset
        User operatorB = newUserWithPermissionSet('nc207operator2', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User gerente = newUserWithPermissionSet('nc207gerenteiso', 'Nova_Casa_Gerente', GERENTE_ROLE);
        User operatorA = userLike('nc207operator');
        Account buildingA = newAccount('Edificio Hist A', operatorA.Id);
        Account buildingB = newAccount('Edificio Hist B', operatorB.Id);
        Asset assetA = newAsset('AST-HIST-ISO-A', buildingA, 'WATER_PUMP');
        Asset assetB = newAsset('AST-HIST-ISO-B', buildingB, 'WATER_PUMP');
        newLog(assetA, 'MEASUREMENT', 'Procesada', baseTime(), null, null);
        newLog(assetB, 'MEASUREMENT', 'Procesada', baseTime(), null, null);

        // When operator B asks for A's history
        String denied;
        System.runAs(operatorB) {
            try {
                ActivosOperadorController.getHistorial(assetA.Id, null);
                Assert.fail('operator B must not read the history of an asset it cannot see');
            } catch (AuraHandledException e) {
                denied = e.getMessage();
            }
        }

        // Then it fails with the safe message; each operator sees their own and the Gerente sees both
        Assert.areEqual(ActivosOperadorController.HISTORY_ASSET_MESSAGE, denied);
        Assert.areEqual(1, history(operatorA, assetA.Id, null).signals.size());
        Assert.areEqual(1, history(operatorB, assetB.Id, null).signals.size());
        Assert.areEqual(1, history(gerente, assetA.Id, null).signals.size());
        Assert.areEqual(1, history(gerente, assetB.Id, null).signals.size());
    }

    @isTest
    static void historyRejectsANullOrUnknownAssetWithASafeMessage() {
        // Given a user and an Id that is not an existing asset
        User operator = userLike('nc207operator');
        Account building = newAccount('Edificio Hist Borrado');
        Asset gone = newAsset('AST-HIST-GONE', building, 'WATER_PUMP');
        Id goneId = gone.Id;
        delete gone;

        // When asking with null and with a deleted asset
        List<Id> ids = new List<Id>{ null, goneId };
        for (Id candidate : ids) {
            System.runAs(operator) {
                try {
                    ActivosOperadorController.getHistorial(candidate, 10);
                    Assert.fail('expected a rejection for ' + candidate);
                } catch (AuraHandledException e) {
                    // Then the message is the static one
                    Assert.areEqual(ActivosOperadorController.HISTORY_ASSET_MESSAGE, e.getMessage());
                }
            }
        }
    }

    @isTest
    static void historyExposesNoTechnicalFieldsOrValues() {
        // Given a signal whose technical columns carry recognizable secrets
        Account building = newAccount('Edificio Hist Tecnico');
        Asset asset = newAsset('AST-HIST-TECH', building, 'WATER_PUMP');
        newLog(asset, 'MEASUREMENT', 'Rechazada', baseTime(), 'MOTIVO-SECRETO-XYZ', 'HUELLA-SECRETA-XYZ');

        // When the operator reads the history
        ActivosOperadorController.HistoryResult result = history(userLike('nc207operator'), asset.Id, null);

        // Then neither the values nor any extra key are in the serialized payload
        String payload = JSON.serialize(result);
        Assert.isFalse(payload.contains('SECRETO'), 'Motivo/Huella values must not leave the controller');
        Assert.isFalse(payload.contains('SECRETA'), 'Motivo/Huella values must not leave the controller');
        Assert.isFalse(payload.contains('TEST-MSG-'), 'Message_Id__c must not leave the controller');
        Assert.isFalse(payload.contains('test-src'), 'Source__c must not leave the controller');
        Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(payload);
        List<Object> signals = (List<Object>) top.get('signals');
        Map<String, Object> first = (Map<String, Object>) signals[0];
        Assert.areEqual(new Set<String>{ 'messageType', 'occurredAt', 'resultado' }, first.keySet());
    }

    @isTest
    static void historyRejectsAnIdOfAnotherObjectWithTheSameSafeMessage() {
        // Given a Case Id (a real record the operator can see)
        Account building = newAccount('Edificio Hist Caso');
        Asset asset = newAsset('AST-HIST-CASE', building, 'WATER_PUMP');
        Case c = newCase(asset, 'New', 'Caso de prueba');

        // When it is passed as the asset Id
        System.runAs(userLike('nc207operator')) {
            try {
                ActivosOperadorController.getHistorial(c.Id, 10);
                Assert.fail('a non-Asset Id must be rejected');
            } catch (AuraHandledException e) {
                // Then it is the same static message
                Assert.areEqual(ActivosOperadorController.HISTORY_ASSET_MESSAGE, e.getMessage());
            }
        }
    }

    @isTest
    static void historyReadsTheLogEvenThoughTheOperatorCannotQueryItDirectly() {
        // Given an operator with the shipped permission set, which grants no access to Log_Senial__c
        User operator = newUserWithPermissionSet('nc207operatorlog', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Hist Premisa', operator.Id);
        Asset asset = newAsset('AST-HIST-PREMISE', building, 'WATER_PUMP');
        newLog(asset, 'MEASUREMENT', 'Procesada', baseTime(), null, null);

        // When the operator queries the log directly in USER_MODE and through the controller
        Boolean directBlocked = false;
        ActivosOperadorController.HistoryResult result;
        System.runAs(operator) {
            try {
                Database.query('SELECT Id FROM Log_Senial__c LIMIT 1', AccessLevel.USER_MODE);
            } catch (QueryException e) {
                directBlocked = true;
            }
            result = ActivosOperadorController.getHistorial(asset.Id, null);
        }

        // Then the direct query is denied (premise of the system-mode read) but the history still comes back
        Assert.isTrue(directBlocked, 'operator must have no access to Log_Senial__c');
        Assert.areEqual(1, result.signals.size());
    }

    // ---------- building summary (HP-07) ----------

    @isTest
    static void buildingSummaryCountsAssetsPerSeverityOpenCasesAndLastSignal() {
        // Given a real operator who owns a building with one asset per class and cases in different states
        User op = newUserWithPermissionSet('nc207sumop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Resumen', op.Id);
        Datetime now = baseTime();
        Asset critical = newAsset('AST-SUM-CRIT', building, 'WATER_PUMP');
        newReading(critical, 'TEMPERATURE', 'CELSIUS', 95, now.addMinutes(-30), 2);
        newReading(critical, 'WATER_PRESSURE', 'BAR', 3, now.addMinutes(-40), 0);
        Asset warning = newAsset('AST-SUM-WARN', building, 'WATER_PUMP');
        newReading(warning, 'TEMPERATURE', 'CELSIUS', 60, now, 1);
        Asset normal = newAsset('AST-SUM-OK', building, 'WATER_PUMP');
        newReading(normal, 'TEMPERATURE', 'CELSIUS', 20, now.addMinutes(-5), 0);
        newAsset('AST-SUM-NONE', building, 'WATER_PUMP');
        newCase(critical, 'New', 'Open one');
        newCase(critical, 'Working', 'Open two');
        newCase(normal, 'Closed', 'Closed one');

        // When the operator loads the building summary
        ActivosOperadorController.EdificioResumen r = resumen(op, building.Id);

        // Then every asset falls in exactly one class, only open cases count, and the newest signal wins
        Assert.areEqual(4, r.totalActivos);
        Assert.areEqual(1, r.activosCriticos);
        Assert.areEqual(1, r.activosEnAlerta);
        Assert.areEqual(1, r.activosNormales);
        Assert.areEqual(1, r.activosSinLectura, 'an asset without readings is never counted as normal');
        Assert.areEqual(0, r.activosSinNivel);
        Assert.isFalse(r.truncated);
        Assert.areEqual(
            r.activosCriticos + r.activosEnAlerta + r.activosNormales + r.activosSinLectura + r.activosSinNivel,
            r.totalActivos,
            'every asset falls in exactly one class'
        );
        Assert.areEqual(2, r.casosAbiertos);
        Assert.areEqual(now, r.ultimaSenal);
    }

    @isTest
    static void buildingSummaryOperatorSeesOnlyOwnBuildingAndGerenteSeesBoth() {
        // Given two operators with a building each, and a Gerente above both
        User opA = newUserWithPermissionSet('nc207sumopa', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User opB = newUserWithPermissionSet('nc207sumopb', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User gerente = newUserWithPermissionSet('nc207sumger', 'Nova_Casa_Gerente', GERENTE_ROLE);
        Account buildingA = newAccount('Edificio Resumen A', opA.Id);
        Account buildingB = newAccount('Edificio Resumen B', opB.Id);
        Asset assetA = newAsset('AST-SUMA-1', buildingA, 'WATER_PUMP');
        newReading(assetA, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);
        newCase(assetA, 'New', 'A case');
        Asset assetB = newAsset('AST-SUMB-1', buildingB, 'WATER_PUMP');
        newReading(assetB, 'TEMPERATURE', 'CELSIUS', 60, baseTime(), 1);
        newAsset('AST-SUMB-2', buildingB, 'WATER_PUMP');

        // When each user asks for their own and for the other building
        ActivosOperadorController.EdificioResumen aOwn = resumen(opA, buildingA.Id);
        ActivosOperadorController.EdificioResumen gerenteA = resumen(gerente, buildingA.Id);
        ActivosOperadorController.EdificioResumen gerenteB = resumen(gerente, buildingB.Id);
        AuraHandledException denied;
        System.runAs(opA) {
            try {
                ActivosOperadorController.getResumenEdificio(buildingB.Id);
            } catch (AuraHandledException e) {
                denied = e;
            }
        }

        // Then the operator gets their own counts and is refused the other building; the Gerente sees both
        Assert.areEqual(1, aOwn.totalActivos);
        Assert.areEqual(1, aOwn.activosCriticos);
        Assert.areEqual(1, aOwn.casosAbiertos);
        Assert.isNotNull(denied, 'operator A must not read operator B building');
        Assert.areEqual(ActivosOperadorController.BUILDING_SUMMARY_MESSAGE, denied.getMessage());
        Assert.areEqual(1, gerenteA.totalActivos);
        Assert.areEqual(1, gerenteA.activosCriticos);
        Assert.areEqual(2, gerenteB.totalActivos);
        Assert.areEqual(1, gerenteB.activosEnAlerta);
        Assert.areEqual(1, gerenteB.activosSinLectura);
    }

    @isTest
    static void buildingSummaryOfABuildingWithoutAssetsIsAllZerosAndNoLastSignal() {
        // Given a building the operator owns with no assets
        User op = newUserWithPermissionSet('nc207sumempty', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Vacio', op.Id);

        // When the operator loads the summary
        ActivosOperadorController.EdificioResumen r = resumen(op, building.Id);

        // Then everything is zero and there is no last signal
        Assert.areEqual(0, r.totalActivos);
        Assert.areEqual(0, r.activosCriticos);
        Assert.areEqual(0, r.activosEnAlerta);
        Assert.areEqual(0, r.activosNormales);
        Assert.areEqual(0, r.activosSinLectura);
        Assert.areEqual(0, r.activosSinNivel);
        Assert.isFalse(r.truncated);
        Assert.areEqual(0, r.casosAbiertos);
        Assert.isNull(r.ultimaSenal);
    }

    @isTest
    static void buildingSummaryRejectsANullOrNonAccountIdWithASafeMessage() {
        // Given a null Id and an Id of another object
        Account building = newAccount('Edificio Para Id Ajeno');
        Asset asset = newAsset('AST-SUM-WRONG', building, 'WATER_PUMP');
        List<Id> bad = new List<Id>{ null, asset.Id };

        // When the summary is requested with each of them
        for (Id value : bad) {
            AuraHandledException thrown;
            System.runAs(userLike('nc207operator')) {
                try {
                    ActivosOperadorController.getResumenEdificio(value);
                } catch (AuraHandledException e) {
                    thrown = e;
                }
            }

            // Then the same safe message comes back, never a platform message
            Assert.isNotNull(thrown, 'expected a rejection for ' + value);
            Assert.areEqual(ActivosOperadorController.BUILDING_SUMMARY_MESSAGE, thrown.getMessage());
        }
    }

    @isTest
    static void buildingSummaryNewerNormalReadingOfAnotherTypeDoesNotHideAnOlderCritical() {
        // Given an asset whose critical temperature is older than a normal pressure reading
        User op = newUserWithPermissionSet('nc207sumhide', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Severidad Maxima', op.Id);
        Datetime now = baseTime();
        Asset asset = newAsset('AST-SUM-HIDE', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, now.addMinutes(-30), 2);
        newReading(asset, 'WATER_PRESSURE', 'BAR', 3, now, 0);

        // When the operator loads the summary
        ActivosOperadorController.EdificioResumen r = resumen(op, building.Id);

        // Then the asset is still critical and the last signal is the newer normal one
        Assert.areEqual(1, r.totalActivos);
        Assert.areEqual(1, r.activosCriticos, 'a newer normal reading must not hide an older critical one');
        Assert.areEqual(0, r.activosNormales);
        Assert.areEqual(now, r.ultimaSenal);
    }

    @isTest
    static void buildingSummarySeparatesNoSignalFromSignalWithoutLevelAndNeverCountsEitherAsNormal() {
        // Given an asset with no signal, one whose every reading has no level, and a plain normal asset
        User op = newUserWithPermissionSet('nc207sumnull', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Niveles Nulos', op.Id);
        newAsset('AST-SUM-NOSIGNAL', building, 'WATER_PUMP');
        Asset nullOnly = newAsset('AST-SUM-NULL', building, 'WATER_PUMP');
        newReading(nullOnly, 'TEMPERATURE', 'CELSIUS', 20, baseTime(), null);
        newReading(nullOnly, 'WATER_PRESSURE', 'BAR', 3, baseTime(), null);
        Asset normal = newAsset('AST-SUM-NORMAL', building, 'WATER_PUMP');
        newReading(normal, 'TEMPERATURE', 'CELSIUS', 20, baseTime(), 0);

        // When the operator loads the summary
        ActivosOperadorController.EdificioResumen r = resumen(op, building.Id);

        // Then each case has its own counter and only the real level-0 asset is normal
        Assert.areEqual(3, r.totalActivos);
        Assert.areEqual(1, r.activosSinLectura, 'no signal at all');
        Assert.areEqual(1, r.activosSinNivel, 'signal without level');
        Assert.areEqual(1, r.activosNormales);
        Assert.areEqual(0, r.activosCriticos + r.activosEnAlerta);
        Assert.areEqual(
            r.activosCriticos + r.activosEnAlerta + r.activosNormales + r.activosSinLectura + r.activosSinNivel,
            r.totalActivos
        );
    }

    @isTest
    static void buildingSummaryIsReportedAsTruncatedWhenThereAreMoreAssetsThanTheCeiling() {
        // Given more visible assets than the summary ceiling, all with a signal and a level
        User op = newUserWithPermissionSet('nc207sumtrunc', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Resumen Grande', op.Id);
        for (Integer i = 1; i <= 3; i++) {
            Asset a = newAsset('AST-SUM-BIG-' + i, building, 'WATER_PUMP');
            newReading(a, 'TEMPERATURE', 'CELSIUS', 20, baseTime(), 0);
        }
        ActivosOperadorController.maxSummaryAssets = 2;

        // When the operator loads the summary
        ActivosOperadorController.EdificioResumen r = resumen(op, building.Id);

        // Then only the ceiling is counted and the caller is told the summary is partial
        Assert.isTrue(r.truncated);
        Assert.areEqual(2, r.totalActivos);
        Assert.areEqual(2, r.activosNormales);

        // And at exactly the ceiling it is not partial
        ActivosOperadorController.maxSummaryAssets = 3;
        ActivosOperadorController.EdificioResumen exact = resumen(op, building.Id);
        Assert.isFalse(exact.truncated);
        Assert.areEqual(3, exact.totalActivos);
    }

    @isTest
    static void buildingSummaryDeniesUsersMissingObjectOrFieldAccessWithTheSafeAccessMessage() {
        // Given a building and asset that an admin can see, one owned by a user lacking Asset FLS
        Account building = newAccount('Edificio Resumen Privado', UserInfo.getUserId());
        newAsset('AST-SUM-PRIV', building, 'WATER_PUMP');
        Account flsBuilding = newAccount('Edificio Resumen FLS', userLike('nc207nofls').Id);
        Asset flsAsset = newAsset('AST-SUM-FLS', flsBuilding, 'WATER_PUMP');
        newReading(flsAsset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);

        // When a user with no object access, and one missing field access, ask the server directly
        AuraHandledException objectError;
        AuraHandledException fieldError;
        System.runAs(userLike('nc207restricted')) {
            try {
                ActivosOperadorController.getResumenEdificio(building.Id);
            } catch (AuraHandledException e) {
                objectError = e;
            }
        }
        System.runAs(userLike('nc207nofls')) {
            try {
                ActivosOperadorController.getResumenEdificio(flsBuilding.Id);
            } catch (AuraHandledException e) {
                fieldError = e;
            }
        }

        // Then both fail with the static access message, never platform text naming objects or fields
        Assert.isNotNull(objectError, 'no object access must be rejected');
        Assert.areEqual(ActivosOperadorController.ACCESS_MESSAGE, objectError.getMessage());
        Assert.isNotNull(fieldError, 'missing field access must be rejected, not answered with partial counts');
        Assert.areEqual(ActivosOperadorController.ACCESS_MESSAGE, fieldError.getMessage());
        Assert.isFalse(fieldError.getMessage().contains('Ultima_Senal__c'));
        Assert.isFalse(fieldError.getMessage().contains('Severidad_Nivel__c'));
    }

    @isTest
    static void buildingSummaryExposesOnlyTheAgreedFields() {
        // Given the DTO the component receives
        ActivosOperadorController.EdificioResumen r = new ActivosOperadorController.EdificioResumen();

        // When it is serialized
        Map<String, Object> json = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(r));

        // Then it carries exactly the nine agreed keys and nothing technical
        Assert.areEqual(
            new Set<String>{ 'totalActivos', 'activosCriticos', 'activosEnAlerta', 'activosNormales', 'activosSinLectura', 'activosSinNivel', 'truncated', 'casosAbiertos', 'ultimaSenal' },
            json.keySet().clone(),
            'the summary DTO must expose only the agreed keys'
        );
    }

    // ---------- asset state (HP-07, Asset record page) ----------

    @isTest
    static void assetStateReturnsTheLatestReadingPerTypeWithValueAndUnit() {
        // Given two readings of the same type at different times, and one of another type
        User op = newUserWithPermissionSet('nc207stateop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Estado', op.Id);
        Asset asset = newAsset('AST-STATE-LATEST', building, 'WATER_PUMP');
        Datetime now = baseTime();
        Lectura_Vigente__c older = newReading(asset, 'TEMPERATURE', 'CELSIUS', 40, now.addMinutes(-30), 0);
        Lectura_Vigente__c newer = newReading(asset, 'TEMPERATURE', 'CELSIUS', 62.5, now, 1);
        newReading(asset, 'WATER_PRESSURE', 'BAR', 3, now.addMinutes(-5), 0);
        Assert.areNotEqual(older.Id, newer.Id);

        // When the operator opens the asset
        ActivosOperadorController.EstadoActivo result = estado(op, asset.Id);

        // Then there is exactly one row per type, the newest of each, with value, unit, time and level
        Assert.areEqual(2, result.readings.size());
        ActivosOperadorController.EstadoLectura temperature = stateReading(result, 'TEMPERATURE');
        Assert.areEqual(62.5, temperature.value);
        Assert.areEqual('CELSIUS', temperature.unit);
        Assert.areEqual(now, temperature.occurredAt);
        Assert.areEqual(1, temperature.severityLevel);
        Assert.areEqual(3, stateReading(result, 'WATER_PRESSURE').value);
        Assert.areEqual('BAR', stateReading(result, 'WATER_PRESSURE').unit);
    }

    @isTest
    static void assetStateNewerNormalOfAnotherTypeDoesNotHideACritical() {
        // Given an older critical temperature and a newer normal pressure
        User op = newUserWithPermissionSet('nc207statecrit', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Estado Critico', op.Id);
        Asset asset = newAsset('AST-STATE-CRIT', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime().addMinutes(-30), 2);
        newReading(asset, 'WATER_PRESSURE', 'BAR', 3, baseTime(), 0);

        // When the operator opens the asset
        ActivosOperadorController.EstadoActivo result = estado(op, asset.Id);

        // Then both rows are listed and the critical one keeps its level
        Assert.areEqual(2, result.readings.size());
        Assert.areEqual(2, stateReading(result, 'TEMPERATURE').severityLevel, 'a newer normal reading of another type must not hide the critical');
        Assert.areEqual(0, stateReading(result, 'WATER_PRESSURE').severityLevel);
    }

    @isTest
    static void assetStateKeepsAReadingWithoutLevelAsNullNeverNormal() {
        // Given a reading with no severity level
        User op = newUserWithPermissionSet('nc207statenull', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Estado Nulo', op.Id);
        Asset asset = newAsset('AST-STATE-NULL', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 20, baseTime(), null);

        // When the operator opens the asset
        ActivosOperadorController.EstadoActivo result = estado(op, asset.Id);

        // Then the level stays null so the component shows "Sin dato"
        Assert.isNull(stateReading(result, 'TEMPERATURE').severityLevel);
    }

    @isTest
    static void assetStateListsOnlyOpenInterventionsNewestFirstAndEmptyWhenNone() {
        // Given an asset with closed and open cases, and another asset with only a closed case
        User op = newUserWithPermissionSet('nc207statecase', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Estado Casos', op.Id);
        Asset withCases = newAsset('AST-STATE-CASES', building, 'WATER_PUMP');
        Asset onlyClosed = newAsset('AST-STATE-CLOSED', building, 'WATER_PUMP');
        newCase(withCases, 'Closed', 'Cerrado');
        Case open = newCase(withCases, 'New', 'Abierto uno');
        newCase(onlyClosed, 'Closed', 'Cerrado otro');

        // When the operator opens each asset
        ActivosOperadorController.EstadoActivo a = estado(op, withCases.Id);
        ActivosOperadorController.EstadoActivo b = estado(op, onlyClosed.Id);

        // Then only the open case counts, with its number, subject and status; closed ones are ignored
        Assert.areEqual(1, a.openInterventionCount);
        Assert.areEqual(open.Id, a.openIntervention.caseId);
        Assert.areEqual('Abierto uno', a.openIntervention.subject);
        Assert.areEqual('New', a.openIntervention.status);
        Assert.isNotNull(a.openIntervention.caseNumber);
        Assert.areEqual(0, b.openInterventionCount);
        Assert.isNull(b.openIntervention);
        Assert.isTrue(b.readings.isEmpty());
    }

    @isTest
    static void assetStateIsDeniedForAnotherOperatorsAssetButWorksForTheGerente() {
        // Given two operators, a Gerente above both, and a reading on operator A's asset
        User operatorB = newUserWithPermissionSet('nc207stateop2', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User gerente = newUserWithPermissionSet('nc207stategerente', 'Nova_Casa_Gerente', GERENTE_ROLE);
        User operatorA = userLike('nc207operator');
        Account buildingA = newAccount('Edificio Estado A', operatorA.Id);
        Asset assetA = newAsset('AST-STATE-ISO-A', buildingA, 'WATER_PUMP');
        newReading(assetA, 'TEMPERATURE', 'CELSIUS', 50, baseTime(), 1);

        // When operator B asks for A's asset
        String denied;
        System.runAs(operatorB) {
            try {
                ActivosOperadorController.getEstadoActivo(assetA.Id);
                Assert.fail('operator B must not read the state of an asset it cannot see');
            } catch (AuraHandledException e) {
                denied = e.getMessage();
            }
        }

        // Then it fails with the safe message, while the owner and the Gerente get the reading
        Assert.areEqual(ActivosOperadorController.ASSET_STATE_MESSAGE, denied);
        Assert.areEqual(1, estado(operatorA, assetA.Id).readings.size());
        Assert.areEqual(1, estado(gerente, assetA.Id).readings.size());
    }

    @isTest
    static void assetStateRejectsNullAndOtherObjectIdsWithTheSafeMessage() {
        // Given a Case Id (a real record) and null
        Account building = newAccount('Edificio Estado Otro');
        Asset asset = newAsset('AST-STATE-OTHER', building, 'WATER_PUMP');
        Case c = newCase(asset, 'New', 'Caso de prueba');

        // When they are passed as the asset Id
        for (Id candidate : new List<Id>{ null, c.Id }) {
            System.runAs(userLike('nc207operator')) {
                try {
                    ActivosOperadorController.getEstadoActivo(candidate);
                    Assert.fail('expected a rejection for ' + candidate);
                } catch (AuraHandledException e) {
                    // Then the message is the static one
                    Assert.areEqual(ActivosOperadorController.ASSET_STATE_MESSAGE, e.getMessage());
                }
            }
        }
    }

    @isTest
    static void assetStateExposesOnlyTheAgreedKeys() {
        // Given an asset with one reading and one open case
        User op = newUserWithPermissionSet('nc207statekeys', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Estado Llaves', op.Id);
        Asset asset = newAsset('AST-STATE-KEYS', building, 'WATER_PUMP');
        insert new Lectura_Vigente__c(
            Asset__c = asset.Id,
            Clave__c = 'TEST-KEYS-1',
            Tipo_Medicion__c = 'TEMPERATURE',
            Unidad__c = 'CELSIUS',
            Valor__c = 50,
            Occurred_At__c = baseTime(),
            Severidad_Nivel__c = 1,
            Sensor_Id__c = 'SENSOR-SECRETO-XYZ'
        );
        newCase(asset, 'New', 'Caso');

        // When the DTO is serialized
        String payload = JSON.serialize(estado(op, asset.Id));
        Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(payload);
        Map<String, Object> reading = (Map<String, Object>) ((List<Object>) top.get('readings'))[0];
        Map<String, Object> intervention = (Map<String, Object>) top.get('openIntervention');

        // Then only the agreed keys are present and no technical value leaks
        Assert.areEqual(new Set<String>{ 'readings', 'openIntervention', 'openInterventionCount', 'truncated' }, top.keySet());
        Assert.areEqual(new Set<String>{ 'measurementType', 'value', 'unit', 'occurredAt', 'severityLevel' }, reading.keySet());
        Assert.areEqual(new Set<String>{ 'caseId', 'caseNumber', 'subject', 'status' }, intervention.keySet());
        Assert.isFalse(payload.contains('SECRETO'), 'Sensor_Id__c must not leave the controller');
    }

    @isTest
    static void assetStateFlagsTruncationOnlyWhenTheReadingCapIsExceeded() {
        // Given one asset with exactly the cap of readings (5 types x 1 asset)
        User op = newUserWithPermissionSet('nc207statetrunc', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Estado Tope', op.Id);
        Asset asset = newAsset('AST-STATE-CAP', building, 'WATER_PUMP');
        Datetime now = baseTime();
        for (Integer i = 0; i < 5; i++) {
            newReading(asset, 'TEMPERATURE', 'CELSIUS', 20 + i, now.addMinutes(-i), 0);
        }

        // When the operator opens the asset
        ActivosOperadorController.EstadoActivo exact = estado(op, asset.Id);

        // Then nothing was cut
        Assert.isFalse(exact.truncated, 'Exactly at the readings cap is not a cut');

        // When one more reading pushes it over the cap
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 99, now.addMinutes(-10), 0);
        ActivosOperadorController.EstadoActivo over = estado(op, asset.Id);

        // Then the panel is told the figures may be incomplete
        Assert.isTrue(over.truncated, 'Readings beyond the cap must set truncated');
    }

    @isTest
    static void assetStateSameInstantHighestSeverityWinsThenRecordIdNotArrivalOrder() {
        // Given three readings of one type at the same instant: a normal, a critical, then another critical
        User op = newUserWithPermissionSet('nc207statetie', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Estado Empate', op.Id);
        Asset asset = newAsset('AST-STATE-TIE', building, 'WATER_PUMP');
        Datetime now = baseTime();
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 20, now, 0);
        Lectura_Vigente__c critical = newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, now, 2);

        // When the operator opens the asset
        ActivosOperadorController.EstadoActivo bySeverity = estado(op, asset.Id);

        // Then the highest severity wins even though the normal one arrived first
        Assert.areEqual(1, bySeverity.readings.size());
        Assert.areEqual(2, bySeverity.readings[0].severityLevel);
        Assert.areEqual(95, bySeverity.readings[0].value);

        // When a second critical with the same instant arrives
        Lectura_Vigente__c second = newReading(asset, 'TEMPERATURE', 'CELSIUS', 96, now, 2);
        Lectura_Vigente__c expected = String.valueOf(critical.Id) > String.valueOf(second.Id) ? critical : second;
        ActivosOperadorController.EstadoActivo byId = estado(op, asset.Id);

        // Then the higher record Id wins, not the arrival order
        Assert.areEqual(1, byId.readings.size());
        Assert.areEqual(expected.Valor__c, byId.readings[0].value);
    }

    @isTest
    static void realCoordinatorAndAdminPermissionSetsCanOpenTheAssetState() {
        // Given a coordinator above the building, an admin-set user with no role, and an asset with a reading and an open case
        User coordinator = newUserWithPermissionSet('nc207statecoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        User admin = newUserWithPermissionSet('nc207stateadmin', 'Nova_Casa_Admin', null);
        Account building = newAccount('Edificio Estado Roles');
        Asset asset = newAsset('AST-STATE-ROLES', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 60, baseTime(), 1);
        Case open = newCase(asset, 'New', 'Caso abierto');

        // When each opens the asset state
        ActivosOperadorController.EstadoActivo forCoordinator = estado(coordinator, asset.Id);
        ActivosOperadorController.EstadoActivo forAdmin = estado(admin, asset.Id);

        // Then neither gets the access error and both see the reading and the case subject
        for (ActivosOperadorController.EstadoActivo r : new List<ActivosOperadorController.EstadoActivo>{ forCoordinator, forAdmin }) {
            Assert.areEqual(1, r.readings.size());
            Assert.areEqual(1, r.openInterventionCount);
            Assert.areEqual(open.Id, r.openIntervention.caseId);
            Assert.areEqual('Caso abierto', r.openIntervention.subject);
        }
    }

    @isTest
    static void assetStateWithoutFieldAccessGetsTheSafeAccessMessage() {
        // Given a user who can see the asset but has no FLS on Lectura_Vigente__c.Severidad_Nivel__c
        User limited;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet ps = newPermissionSet('NC207_State_NoSeverity');
            insert ps;
            List<ObjectPermissions> objectPerms = new List<ObjectPermissions>();
            for (String obj : new List<String>{ 'Asset', 'Account', 'Contact', 'Case', 'Lectura_Vigente__c' }) {
                objectPerms.add(new ObjectPermissions(ParentId = ps.Id, SobjectType = obj, PermissionsRead = true));
            }
            insert objectPerms;
            List<FieldPermissions> fieldPerms = new List<FieldPermissions>();
            for (String f : new List<String>{ 'Asset.AccountId', 'Case.AssetId', 'Case.Subject', 'Lectura_Vigente__c.Sensor_Id__c' }) {
                // Required and master-detail fields are always readable; Severidad_Nivel__c is the only one left out.
                fieldPerms.add(new FieldPermissions(ParentId = ps.Id, SobjectType = f.substringBefore('.'),
                    Field = f, PermissionsRead = true, PermissionsEdit = false));
            }
            insert fieldPerms;
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            limited = newUser(p.Id, 'nc207stateinsev', String.valueOf(Crypto.getRandomInteger()).replace('-', 'n'));
            insert limited;
            insert new PermissionSetAssignment(AssigneeId = limited.Id, PermissionSetId = ps.Id);
        }
        Account building = newAccount('Edificio Estado FLS', limited.Id);
        Asset asset = newAsset('AST-STATE-FLS', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);

        // When that user asks for the asset state
        AuraHandledException error;
        System.runAs(limited) {
            try {
                ActivosOperadorController.getEstadoActivo(asset.Id);
            } catch (AuraHandledException e) {
                error = e;
            }
        }

        // Then it is rejected with the static message, not partial data or platform text naming fields
        Assert.isNotNull(error, 'missing field access must be rejected');
        Assert.areEqual(ActivosOperadorController.ACCESS_MESSAGE, error.getMessage());
        Assert.isFalse(error.getMessage().contains('Severidad_Nivel__c'));
    }

    // ---------- helpers ----------

    // Assigns a SHIPPED permission set (by Name) to a fresh user. Call before inserting data rows in the test.
    private static User newUserWithPermissionSet(String prefix, String permissionSetName, String roleName) {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName];
            Assert.areEqual(1, sets.size(), permissionSetName + ' must be deployed to the org');
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            u = newUser(p.Id, prefix, String.valueOf(Crypto.getRandomInteger()).replace('-', 'n'));
            if (roleName != null) {
                u.UserRoleId = roleId(roleName);
            }
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = sets[0].Id);
        }
        return u;
    }

    private static ActivosOperadorController.EdificioResumen resumen(User runAs, Id accountId) {
        ActivosOperadorController.EdificioResumen result;
        System.runAs(runAs) {
            result = ActivosOperadorController.getResumenEdificio(accountId);
        }
        return result;
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

    private static ActivosOperadorController.EstadoActivo estado(User runAs, Id assetId) {
        ActivosOperadorController.EstadoActivo result;
        System.runAs(runAs) {
            result = ActivosOperadorController.getEstadoActivo(assetId);
        }
        return result;
    }

    private static ActivosOperadorController.EstadoLectura stateReading(ActivosOperadorController.EstadoActivo state, String type) {
        for (ActivosOperadorController.EstadoLectura r : state.readings) {
            if (r.measurementType == type) {
                return r;
            }
        }
        Assert.fail('no reading of type ' + type);
        return null;
    }

    private static ActivosOperadorController.HistoryResult history(User runAs, Id assetId, Integer limite) {
        ActivosOperadorController.HistoryResult result;
        System.runAs(runAs) {
            result = ActivosOperadorController.getHistorial(assetId, limite);
        }
        return result;
    }

    private static Log_Senial__c logRow(Asset asset, String messageType, String resultado, Datetime at, String motivo, String huella) {
        keyCounter++;
        return new Log_Senial__c(
            Asset__c = asset.Id,
            Message_Id__c = 'TEST-MSG-' + keyCounter,
            Source__c = 'test-src',
            Message_Type__c = messageType,
            Resultado__c = resultado,
            Occurred_At__c = at,
            Motivo__c = motivo,
            Huella__c = huella
        );
    }

    private static Log_Senial__c newLog(Asset asset, String messageType, String resultado, Datetime at, String motivo, String huella) {
        Log_Senial__c l = logRow(asset, messageType, resultado, at, motivo, huella);
        insert l;
        return l;
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
        // Usernames are prefix + '.' + suffix, so 'nc207operator.%' cannot match 'nc207operator2.…'.
        String pattern = prefix + '.%';
        return [SELECT Id FROM User WHERE Username LIKE :pattern LIMIT 1];
    }

    private static Id roleId(String developerName) {
        List<UserRole> roles = [SELECT Id FROM UserRole WHERE DeveloperName = :developerName];
        Assert.areEqual(1, roles.size(), developerName + ' must be deployed to the org');
        return roles[0].Id;
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

    // Owned by the operator: with private Account sharing (BR-208) only the owner and the roles above it see a building.
    private static Account newAccount(String name) {
        return newAccount(name, userLike('nc207operator').Id);
    }

    private static Account newAccount(String name, Id ownerId) {
        Account acc = new Account(Name = name, OwnerId = ownerId);
        insert acc;
        return acc;
    }

    private static Asset newAsset(String name, Account building, String type) {
        Asset asset = new Asset(Name = name, AccountId = building.Id, Tipo_Activo__c = type);
        insert asset;
        return asset;
    }

    private static void setExternalId(Asset asset, String code) {
        asset.External_Id__c = code;
        update asset;
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

    // Owned by the building's owner, so with private Case sharing whoever sees the asset also sees its cases.
    private static Case newCase(Asset asset, String status, String subject) {
        Id ownerId = [SELECT Account.OwnerId FROM Asset WHERE Id = :asset.Id].Account.OwnerId;
        Case c = new Case(AssetId = asset.Id, OwnerId = ownerId, Status = status, Subject = subject, Origin = 'Web');
        insert c;
        return c;
    }
}
