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
            // Asset.AccountId, Case.AssetId, Case.Subject, Case.ClosedDate (read-only, like the shipped sets). CaseNumber, Status,
            // IsClosed, Name, CreatedDate do not.
            for (PermissionSet ps : new List<PermissionSet>{ fullPs, noFlsPs }) {
                for (String f : new List<String>{ 'Asset.AccountId', 'Case.AssetId', 'Case.Subject', 'Case.ClosedDate' }) {
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
    static void historyExposesOnlyTheAgreedKeysAndNoTechnicalFields() {
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
        Assert.areEqual(new Set<String>{ 'messageType', 'occurredAt', 'resultado', 'measurementType', 'unit', 'value' }, first.keySet());
    }

    @isTest
    static void historyReturnsMeasurementTypeUnitAndValueAndNullForOldRows() {
        // Given a new measurement row with type, unit and value, and an old row without them
        Account building = newAccount('Edificio Hist Valores');
        Asset asset = newAsset('AST-HIST-VALUES', building, 'WATER_PUMP');
        Datetime now = baseTime();
        newLogWithValue(asset, now, 'TEMPERATURE', 'CELSIUS', 21.5);
        newLog(asset, 'MEASUREMENT', 'Procesada', now.addMinutes(-5), null, null);

        // When the operator reads the history (newest first)
        ActivosOperadorController.HistoryResult result = history(userLike('nc207operator'), asset.Id, null);

        // Then the new row round-trips and the old row has nulls
        Assert.areEqual(2, result.signals.size());
        Assert.areEqual('TEMPERATURE', result.signals[0].measurementType);
        Assert.areEqual('CELSIUS', result.signals[0].unit);
        Assert.areEqual(21.5, result.signals[0].value);
        Assert.isNull(result.signals[1].measurementType);
        Assert.isNull(result.signals[1].unit);
        Assert.isNull(result.signals[1].value);
    }

    @isTest
    static void historyValuesReachAnOperatorWhoCannotReadTheLogAndAreNotExposedForAHiddenAsset() {
        // Given the shipped operator permission set (no access to Log_Senial__c) and a valued row on each of two buildings
        User operatorB = newUserWithPermissionSet('nc207operator2', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User operatorA = newUserWithPermissionSet('nc207operatorlog', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account buildingA = newAccount('Edificio Valores A', operatorA.Id);
        Account buildingB = newAccount('Edificio Valores B', operatorB.Id);
        Asset assetA = newAsset('AST-HIST-VAL-A', buildingA, 'WATER_PUMP');
        Asset assetB = newAsset('AST-HIST-VAL-B', buildingB, 'WATER_PUMP');
        newLogWithValue(assetA, baseTime(), 'WATER_PRESSURE', 'BAR', 3.2);
        newLogWithValue(assetB, baseTime(), 'WATER_PRESSURE', 'BAR', 4.4);

        // When operator A reads own history, and operator B asks for A's
        ActivosOperadorController.HistoryResult own = history(operatorA, assetA.Id, null);
        String denied;
        String leaked;
        System.runAs(operatorB) {
            try {
                leaked = JSON.serialize(ActivosOperadorController.getHistorial(assetA.Id, null));
            } catch (AuraHandledException e) {
                denied = e.getMessage();
            }
        }

        // Then A gets the value without log access, and B gets only the safe error with no value
        Assert.areEqual(3.2, own.signals[0].value);
        Assert.areEqual('BAR', own.signals[0].unit);
        Assert.areEqual(ActivosOperadorController.HISTORY_ASSET_MESSAGE, denied);
        Assert.isNull(leaked);
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
            for (String f : new List<String>{ 'Asset.AccountId', 'Case.AssetId', 'Case.Subject', 'Case.ClosedDate', 'Lectura_Vigente__c.Sensor_Id__c' }) {
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

    // ---------- warning (level 1) visibility for monitoring (BR-206 / US-206) ----------

    @isTest
    static void warningAssetIsShownToTheRealOperatorWithItsLevelLabelAndNoIntervention() {
        // Given a real operator who owns a building with an asset whose only reading is a warning (level 1)
        User op = newUserWithPermissionSet('nc206warnshow', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Advertencia', op.Id);
        Datetime now = baseTime();
        Asset warning = newAsset('AST-WARN-SHOW', building, 'WATER_PUMP');
        newReading(warning, 'TEMPERATURE', 'CELSIUS', 60, now, 1);

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(op, null, null, null);

        // Then the asset is listed as a warning (not critical, not normal), with its reading, and no case is opened
        Assert.areEqual(1, result.size());
        ActivosOperadorController.AssetView view = result[0];
        Assert.areEqual(warning.Id, view.assetId);
        Assert.areEqual(1, view.severityLevel);
        // Current controller label for level 1 (labelFor); the LWC shows 'Precaución' -- see report
        Assert.areEqual('Advertencia', view.severityLabel);
        Assert.areEqual(1, view.readings.size());
        Assert.areEqual(1, view.readings[0].severityLevel);
        Assert.areEqual('Advertencia', view.readings[0].severityLabel);
        Assert.areEqual(60, view.readings[0].value);
        Assert.areEqual(now, view.lastSignalAt);
        Assert.isNull(view.openIntervention, 'a warning must not carry an open case');
        Assert.areEqual(0, view.openInterventionCount);
        Assert.isTrue([SELECT COUNT() FROM Case WHERE AssetId = :warning.Id] == 0, 'the query side must not create cases');
    }

    @isTest
    static void severityFilterOneReturnsWarningAssetsAndCriticalFilterDoesNot() {
        // Given a warning, a critical and a normal asset owned by the real operator
        User op = newUserWithPermissionSet('nc206warnfilt', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Filtro Advertencia', op.Id);
        Datetime now = baseTime();
        newReading(newAsset('AST-F-WARN', building, 'WATER_PUMP'), 'TEMPERATURE', 'CELSIUS', 60, now, 1);
        newReading(newAsset('AST-F-CRIT', building, 'WATER_PUMP'), 'TEMPERATURE', 'CELSIUS', 95, now, 2);
        newReading(newAsset('AST-F-OK', building, 'WATER_PUMP'), 'TEMPERATURE', 'CELSIUS', 20, now, 0);

        // When filtering by level 1, by level 2 and by level 0
        ActivosOperadorController.AssetPage warnings = loadResult(op, null, 1, null);
        ActivosOperadorController.AssetPage criticals = loadResult(op, null, 2, null);
        ActivosOperadorController.AssetPage normals = loadResult(op, null, 0, null);

        // Then each filter returns only its own level: the warning is in level 1 and absent from level 2
        Assert.areEqual(new List<String>{ 'AST-F-WARN' }, names(warnings.assets));
        Assert.areEqual(1, warnings.totalCount);
        Assert.areEqual(1, warnings.assets[0].severityLevel);
        Assert.areEqual(new List<String>{ 'AST-F-CRIT' }, names(criticals.assets));
        Assert.areEqual(new List<String>{ 'AST-F-OK' }, names(normals.assets));
    }

    @isTest
    static void assetWithWarningAndCriticalReadingsIsCriticalNotWarning() {
        // Given one asset with a warning temperature and a critical pressure, and a warning-only control asset
        User op = newUserWithPermissionSet('nc206warnmax', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Maximo', op.Id);
        Datetime now = baseTime();
        Asset mixed = newAsset('AST-MAX-MIXED', building, 'WATER_PUMP');
        // the warning is the NEWER reading, so "latest wins" would wrongly make the asset a warning
        newReading(mixed, 'WATER_PRESSURE', 'BAR', 9, now.addMinutes(-20), 2);
        newReading(mixed, 'TEMPERATURE', 'CELSIUS', 60, now, 1);
        Asset onlyWarning = newAsset('AST-MAX-WARN', building, 'WATER_PUMP');
        newReading(onlyWarning, 'TEMPERATURE', 'CELSIUS', 60, now, 1);

        // When the operator loads the list, unfiltered and by each level
        Map<String, ActivosOperadorController.AssetView> all = byName(load(op, null, null, null));
        List<ActivosOperadorController.AssetView> warnings = load(op, null, 1, null);
        List<ActivosOperadorController.AssetView> criticals = load(op, null, 2, null);

        // Then the mixed asset is critical (the maximum), keeps both readings, and is not in the warning filter
        Assert.areEqual(2, all.get('AST-MAX-MIXED').severityLevel);
        Assert.areEqual('Crítica', all.get('AST-MAX-MIXED').severityLabel);
        Assert.areEqual(2, all.get('AST-MAX-MIXED').readings.size());
        Assert.areEqual(1, readingOf(all.get('AST-MAX-MIXED'), 'TEMPERATURE').severityLevel);
        Assert.areEqual(1, all.get('AST-MAX-WARN').severityLevel);
        Assert.areEqual(new List<String>{ 'AST-MAX-WARN' }, names(warnings));
        Assert.areEqual(new List<String>{ 'AST-MAX-MIXED' }, names(criticals));
    }

    @isTest
    static void criticalAssetIsListedBeforeTheWarningAssetEvenWhenItsNameSortsLater() {
        // Given a warning asset whose name sorts first, and a critical one whose name sorts last
        User op = newUserWithPermissionSet('nc206warnorder', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Orden', op.Id);
        Datetime now = baseTime();
        newReading(newAsset('AST-ORD-A-WARN', building, 'WATER_PUMP'), 'TEMPERATURE', 'CELSIUS', 60, now, 1);
        newReading(newAsset('AST-ORD-Z-CRIT', building, 'WATER_PUMP'), 'TEMPERATURE', 'CELSIUS', 95, now, 2);
        newReading(newAsset('AST-ORD-B-OK', building, 'WATER_PUMP'), 'TEMPERATURE', 'CELSIUS', 20, now, 0);

        // When the operator loads the list (names() would sort alphabetically, so read the raw order)
        List<ActivosOperadorController.AssetView> result = load(op, null, null, null);

        // Then the order is severity first: critical, warning, normal -- not alphabetical
        Assert.areEqual(3, result.size());
        Assert.areEqual('AST-ORD-Z-CRIT', result[0].name);
        Assert.areEqual('AST-ORD-A-WARN', result[1].name);
        Assert.areEqual('AST-ORD-B-OK', result[2].name);
        Assert.areEqual(2, result[0].severityLevel);
        Assert.areEqual(1, result[1].severityLevel);
        Assert.areEqual(0, result[2].severityLevel);
    }

    // ---------- last closed intervention (HP-07, D038) ----------
    // Case.ClosedDate is stamped by the platform when a Case closes and cannot be written from Apex. The one test that needs
    // two different close times lets real time pass between the closings (letOneSecondPass). The others only rely on a case
    // that is created, and so closed, later never having an older ClosedDate nor a lower Id than an earlier one.

    @isTest
    static void lastClosedInterventionCarriesTheIdNumberAndClosedDateOfTheOnlyClosedCase() {
        // Given an asset whose only case is closed
        Account building = newAccount('Edificio Ultima Cerrada');
        Asset asset = newAsset('AST-LAST-ONE', building, 'WATER_PUMP');
        Case closed = reloaded(newCase(asset, 'Closed', 'Cerrado unico'));
        Assert.isNotNull(closed.ClosedDate, 'precondition: closing a case stamps ClosedDate');

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(userLike('nc207operator'), null, null, null);

        // Then the asset carries that case as its last closed intervention, and has no open one
        Assert.areEqual(1, result.size());
        ActivosOperadorController.AssetView view = result[0];
        Assert.isNotNull(view.lastClosedIntervention, 'an asset with only closed cases must show the last one');
        Assert.areEqual(closed.Id, view.lastClosedIntervention.caseId);
        Assert.areEqual(closed.CaseNumber, view.lastClosedIntervention.caseNumber);
        Assert.areEqual(closed.ClosedDate, view.lastClosedIntervention.closedDate);
        Assert.isNull(view.openIntervention);
        Assert.areEqual(0, view.openInterventionCount);
    }

    @isTest
    static void lastClosedInterventionIsTheCaseClosedMostRecentlyEvenWhenAnotherHasAHigherId() {
        // Given an asset with two open cases: the one created second (higher Id) is closed first, and the one created
        // first (lower Id) is closed a second later
        Account building = newAccount('Edificio Cierre Reciente');
        Asset asset = newAsset('AST-LAST-NEWEST', building, 'WATER_PUMP');
        Case createdFirst = newCase(asset, 'New', 'Creado primero');
        Case createdSecond = newCase(asset, 'New', 'Creado segundo');
        closeCase(createdSecond);
        letOneSecondPass();
        closeCase(createdFirst);
        Case closedLast = reloaded(createdFirst);
        Case closedEarlier = reloaded(createdSecond);
        Assert.isTrue(
            closedLast.ClosedDate > closedEarlier.ClosedDate,
            'precondition: the two closings must get different ClosedDate values (the test waits between them because ClosedDate cannot be written)'
        );

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(userLike('nc207operator'), null, null, null);

        // Then the newest ClosedDate wins, not the highest Id and not the oldest close
        Assert.areEqual(1, result.size());
        Assert.isNotNull(result[0].lastClosedIntervention);
        Assert.areEqual(createdFirst.Id, result[0].lastClosedIntervention.caseId, 'the most recently closed case must win over a higher Id');
        Assert.areNotEqual(createdSecond.Id, result[0].lastClosedIntervention.caseId);
        Assert.areEqual(closedLast.CaseNumber, result[0].lastClosedIntervention.caseNumber);
        Assert.areEqual(closedLast.ClosedDate, result[0].lastClosedIntervention.closedDate);
    }

    @isTest
    static void whenTwoCasesShareTheSameClosedDateTheHigherCaseIdIsTheLastClosed() {
        // Given two cases inserted already closed in ONE statement, so the platform stamps both with the same ClosedDate
        Account building = newAccount('Edificio Empate Cierre');
        Asset asset = newAsset('AST-LAST-TIE', building, 'WATER_PUMP');
        Id ownerId = userLike('nc207operator').Id;
        insert new List<Case>{
            caseDraft(asset, ownerId, 'Closed', 'Cerrado uno'),
            caseDraft(asset, ownerId, 'Closed', 'Cerrado dos')
        };
        List<Case> byIdDesc = [SELECT Id, CaseNumber, ClosedDate FROM Case WHERE AssetId = :asset.Id ORDER BY Id DESC];
        Assert.areEqual(2, byIdDesc.size());
        Assert.areEqual(
            byIdDesc[0].ClosedDate,
            byIdDesc[1].ClosedDate,
            'precondition: cases closed by the same DML statement must share ClosedDate'
        );

        // When the operator loads the list
        List<ActivosOperadorController.AssetView> result = load(userLike('nc207operator'), null, null, null);

        // Then the tie resolves to the higher Id every time
        Assert.areEqual(1, result.size());
        Assert.isNotNull(result[0].lastClosedIntervention);
        Assert.areEqual(byIdDesc[0].Id, result[0].lastClosedIntervention.caseId, 'a tie on ClosedDate must resolve to the higher Id');
        Assert.areEqual(byIdDesc[0].CaseNumber, result[0].lastClosedIntervention.caseNumber);
        Assert.areNotEqual(byIdDesc[1].Id, result[0].lastClosedIntervention.caseId);
    }

    @isTest
    static void eachAssetGetsItsOwnNewestClosedCaseWhenSeveralAssetsShareTheQuery() {
        // Given three assets whose closed cases are interleaved, one asset having two
        Account building = newAccount('Edificio Varios Cerrados');
        Asset x = newAsset('AST-LAST-X', building, 'WATER_PUMP');
        Asset y = newAsset('AST-LAST-Y', building, 'WATER_PUMP');
        Asset z = newAsset('AST-LAST-Z', building, 'WATER_PUMP');
        newCase(x, 'Closed', 'X viejo');
        Case yOnly = newCase(y, 'Closed', 'Y unico');
        Case xNewest = newCase(x, 'Closed', 'X nuevo');
        Case zOnly = newCase(z, 'Closed', 'Z unico');

        // When the operator loads the list
        Map<String, ActivosOperadorController.AssetView> views = byName(load(userLike('nc207operator'), null, null, null));

        // Then every asset shows its own newest case: not the oldest one of its own, and not a neighbour's
        Assert.areEqual(3, views.size());
        Assert.areEqual(xNewest.Id, views.get('AST-LAST-X').lastClosedIntervention.caseId, 'X has two closed cases: its newest wins');
        Assert.areEqual(yOnly.Id, views.get('AST-LAST-Y').lastClosedIntervention.caseId);
        Assert.areEqual(zOnly.Id, views.get('AST-LAST-Z').lastClosedIntervention.caseId);
    }

    @isTest
    static void assetWithAnOpenCaseHasNoLastClosedInterventionEvenWhenItHasClosedOnes() {
        // Given an asset with closed cases and an open one, an asset with only an open one, and an asset with only a closed one
        Account building = newAccount('Edificio Abierto Y Cerrado');
        Asset both = newAsset('AST-LAST-BOTH', building, 'WATER_PUMP');
        Asset onlyOpen = newAsset('AST-LAST-OPEN', building, 'WATER_PUMP');
        Asset onlyClosed = newAsset('AST-LAST-CLOSED', building, 'WATER_PUMP');
        newCase(both, 'Closed', 'Cerrado viejo uno');
        newCase(both, 'Closed', 'Cerrado viejo dos');
        Case current = newCase(both, 'New', 'Abierto actual');
        newCase(onlyOpen, 'New', 'Solo abierto');
        Case closed = newCase(onlyClosed, 'Closed', 'Solo cerrado');

        // When the operator loads the list
        Map<String, ActivosOperadorController.AssetView> views = byName(load(userLike('nc207operator'), null, null, null));

        // Then the asset with an open case keeps it and shows no closed one, while the control asset does show its closed case
        ActivosOperadorController.AssetView withBoth = views.get('AST-LAST-BOTH');
        Assert.isNotNull(withBoth.openIntervention);
        Assert.areEqual(current.Id, withBoth.openIntervention.caseId);
        Assert.areEqual(1, withBoth.openInterventionCount);
        Assert.isNull(withBoth.lastClosedIntervention, 'a closed case must not be offered while another is open');
        Assert.isNull(views.get('AST-LAST-OPEN').lastClosedIntervention);
        Assert.isNotNull(views.get('AST-LAST-CLOSED').lastClosedIntervention, 'control: the lookup did run for the asset without an open case');
        Assert.areEqual(closed.Id, views.get('AST-LAST-CLOSED').lastClosedIntervention.caseId);
        Assert.isNull(views.get('AST-LAST-CLOSED').openIntervention);
    }

    @isTest
    static void assetWithoutAnyCaseHasNoLastClosedInterventionAndNeverBorrowsANeighboursCase() {
        // Given an asset with no case at all next to an asset with a closed case
        Account building = newAccount('Edificio Sin Casos');
        Asset noCases = newAsset('AST-LAST-NONE', building, 'WATER_PUMP');
        Asset neighbour = newAsset('AST-LAST-NEIGHBOUR', building, 'WATER_PUMP');
        newReading(noCases, 'TEMPERATURE', 'CELSIUS', 20, baseTime(), 0);
        Case neighbourCase = newCase(neighbour, 'Closed', 'Cerrado del vecino');

        // When the operator loads the list
        Map<String, ActivosOperadorController.AssetView> views = byName(load(userLike('nc207operator'), null, null, null));

        // Then only the neighbour shows a closed intervention
        Assert.isNull(views.get('AST-LAST-NONE').lastClosedIntervention, 'no case at all means no line');
        Assert.isNull(views.get('AST-LAST-NONE').openIntervention);
        Assert.areEqual(0, views.get('AST-LAST-NONE').openInterventionCount);
        Assert.areEqual(neighbourCase.Id, views.get('AST-LAST-NEIGHBOUR').lastClosedIntervention.caseId);
    }

    @isTest
    static void operatorWhoCannotSeeTheBuildingGetsNeitherTheAssetNorItsClosedCase() {
        // Given two operators (A with the test permission set, B with the shipped one) with a building each, and an asset
        // with a closed case in each building
        User operatorA = userLike('nc207operator');
        User operatorB = newUserWithPermissionSet('nc207closediso', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account buildingA = newAccount('Edificio Cerrado A', operatorA.Id);
        Account buildingB = newAccount('Edificio Cerrado B', operatorB.Id);
        Asset assetA = newAsset('AST-CLOSED-ISO-A', buildingA, 'WATER_PUMP');
        Asset assetB = newAsset('AST-CLOSED-ISO-B', buildingB, 'WATER_PUMP');
        Case closedA = newCase(assetA, 'Closed', 'Cerrado de A');
        Case closedB = newCase(assetB, 'Closed', 'Cerrado de B');

        // When each operator loads the list
        ActivosOperadorController.AssetPage pageA = loadResult(operatorA, null, null, null);
        ActivosOperadorController.AssetPage pageB = loadResult(operatorB, null, null, null);

        // Then each one gets only their own asset and their own closed case, and nothing of the other building leaks
        Assert.areEqual(new List<String>{ 'AST-CLOSED-ISO-B' }, names(pageB.assets), 'operator B must not see operator A building');
        Assert.areEqual(closedB.Id, pageB.assets[0].lastClosedIntervention.caseId, 'the shipped Nova_Casa_Operator set must read its own closed case');
        String payloadB = JSON.serialize(pageB);
        Assert.isFalse(payloadB.contains(String.valueOf(closedA.Id)), 'operator B must never receive the closed case of building A');
        Assert.isFalse(payloadB.contains(String.valueOf(assetA.Id)), 'operator B must never receive the asset of building A');
        Assert.areEqual(new List<String>{ 'AST-CLOSED-ISO-A' }, names(pageA.assets), 'operator A must not see operator B building');
        Assert.areEqual(closedA.Id, pageA.assets[0].lastClosedIntervention.caseId);
        String payloadA = JSON.serialize(pageA);
        Assert.isFalse(payloadA.contains(String.valueOf(closedB.Id)), 'operator A must never receive the closed case of building B');
    }

    @isTest
    static void closedCaseTheUserCannotSeeIsNeverReturnedEvenWhenTheAssetIsVisible() {
        // Given an asset the operator can see, with a closed case the operator owns and a closed case (higher Id, never older)
        // owned by a stranger outside the role hierarchy, and a second visible asset whose only closed case is the stranger's
        User operator = userLike('nc207operator');
        User stranger = newUserWithPermissionSet('nc207closedstr', 'Nova_Casa_Operator', null);
        Account building = newAccount('Edificio Caso Oculto', operator.Id);
        Asset withBoth = newAsset('AST-HIDDEN-BOTH', building, 'WATER_PUMP');
        Asset withHiddenOnly = newAsset('AST-HIDDEN-ONLY', building, 'WATER_PUMP');
        Case visible = caseDraft(withBoth, operator.Id, 'Closed', 'Cerrado visible');
        Case hiddenNewer = caseDraft(withBoth, stranger.Id, 'Closed', 'Cerrado oculto');
        Case hiddenOnly = caseDraft(withHiddenOnly, stranger.Id, 'Closed', 'Solo oculto');
        insert new List<Case>{ visible, hiddenNewer, hiddenOnly };
        Boolean strangerCaseVisible;
        System.runAs(operator) {
            strangerCaseVisible = !Database.queryWithBinds(
                'SELECT Id FROM Case WHERE Id = :hiddenId',
                new Map<String, Object>{ 'hiddenId' => hiddenNewer.Id },
                AccessLevel.USER_MODE
            ).isEmpty();
        }
        Assert.isFalse(strangerCaseVisible, 'precondition: a Case owned by a user outside the hierarchy must be private to the operator');

        // When the operator loads the list
        ActivosOperadorController.AssetPage page = loadResult(operator, null, null, null);
        Map<String, ActivosOperadorController.AssetView> views = byName(page.assets);

        // Then both assets are listed, but only the case the operator can see is ever returned
        Assert.areEqual(2, views.size());
        Assert.isNotNull(views.get('AST-HIDDEN-BOTH').lastClosedIntervention);
        Assert.areEqual(visible.Id, views.get('AST-HIDDEN-BOTH').lastClosedIntervention.caseId, 'the hidden case must not win even though it is newer');
        Assert.isNull(views.get('AST-HIDDEN-ONLY').lastClosedIntervention, 'an asset whose only closed case is hidden shows no line');
        String payload = JSON.serialize(page);
        Assert.isFalse(payload.contains(String.valueOf(hiddenNewer.Id)), 'a case the user cannot see must not be serialized');
        Assert.isFalse(payload.contains(String.valueOf(hiddenOnly.Id)), 'a case the user cannot see must not be serialized');
    }

    @isTest
    static void getAssetsRunsTheSameNumberOfQueriesForOneAssetAndForManyAndNeverMoreThanFour() {
        // Given one asset with a closed case
        Account building = newAccount('Edificio Consultas');
        newCase(newAsset('AST-SOQL-1', building, 'WATER_PUMP'), 'Closed', 'Cerrado 1');
        User operator = userLike('nc207operator');
        List<Integer> used = new List<Integer>();

        // When the operator loads the list with one asset, and again after adding five more assets with a closed case, one
        // with an open case and one with no case at all
        ActivosOperadorController.AssetPage one = loadCountingQueries(operator, used);
        for (Integer i = 2; i <= 6; i++) {
            newCase(newAsset('AST-SOQL-' + i, building, 'WATER_PUMP'), 'Closed', 'Cerrado ' + i);
        }
        newCase(newAsset('AST-SOQL-OPEN', building, 'WATER_PUMP'), 'New', 'Abierto');
        newAsset('AST-SOQL-EMPTY', building, 'WATER_PUMP');
        ActivosOperadorController.AssetPage many = loadCountingQueries(operator, used);

        // Then the number of queries does not grow with the number of assets, and stays within four
        Assert.areEqual(1, one.assets.size());
        Assert.areEqual(8, many.assets.size());
        Assert.areEqual(used[0], used[1], 'the closed-case lookup must be one query for the whole page, not one per asset');
        Assert.isTrue(used[1] <= 4, 'getAssets must run at most 4 queries but ran ' + used[1]);
        Integer withLine = 0;
        for (ActivosOperadorController.AssetView view : many.assets) {
            if (view.lastClosedIntervention != null) {
                withLine++;
            }
        }
        Assert.areEqual(6, withLine, 'the single lookup must still serve every asset that has a closed case and no open one');
    }

    @isTest
    static void closedLookupIsSkippedWhenEveryAssetOnThePageHasAnOpenCase() {
        // Given two assets that both have an open case (one also has an older closed case)
        Account building = newAccount('Edificio Todos Abiertos');
        Asset a = newAsset('AST-SKIP-A', building, 'WATER_PUMP');
        Asset b = newAsset('AST-SKIP-B', building, 'WATER_PUMP');
        newCase(a, 'Closed', 'Cerrado viejo');
        newCase(a, 'New', 'Abierto A');
        newCase(b, 'New', 'Abierto B');
        User operator = userLike('nc207operator');
        List<Integer> used = new List<Integer>();

        // When the operator loads the list, then again after adding an asset with no open case
        ActivosOperadorController.AssetPage allOpen = loadCountingQueries(operator, used);
        newCase(newAsset('AST-SKIP-C', building, 'WATER_PUMP'), 'Closed', 'Cerrado quieto');
        ActivosOperadorController.AssetPage withQuiet = loadCountingQueries(operator, used);

        // Then no closed lookup ran for the first page (one query fewer), and no asset with an open case shows a closed one
        Assert.areEqual(2, allOpen.assets.size());
        for (ActivosOperadorController.AssetView view : allOpen.assets) {
            Assert.areEqual(1, view.openInterventionCount);
            Assert.isNull(view.lastClosedIntervention);
        }
        Assert.areEqual(used[0] + 1, used[1], 'the closed lookup must run exactly once, and only when some asset has no open case');
        Map<String, ActivosOperadorController.AssetView> views = byName(withQuiet.assets);
        Assert.isNotNull(views.get('AST-SKIP-C').lastClosedIntervention);
        Assert.isNull(views.get('AST-SKIP-A').lastClosedIntervention);
        Assert.isNull(views.get('AST-SKIP-B').lastClosedIntervention);
    }

    @isTest
    static void closedLookupRowCapDropsTheLineOfTheAssetOutsideTheCutWithoutFlaggingTruncation() {
        // Given two assets that each have a closed case, the case of AST-CAP-NEWER being created, and so closed, after the other
        Account building = newAccount('Edificio Tope Cerrados');
        Asset older = newAsset('AST-CAP-OLDER', building, 'WATER_PUMP');
        Asset newer = newAsset('AST-CAP-NEWER', building, 'WATER_PUMP');
        newCase(older, 'Closed', 'Cerrado antes');
        Case newerCase = newCase(newer, 'Closed', 'Cerrado despues');
        User operator = userLike('nc207operator');

        // When the operator loads the list without a cap, with the closed lookup capped at one row, and capped at two
        ActivosOperadorController.AssetPage uncapped = loadResult(operator, null, null, null);
        Integer originalCap = ActivosOperadorController.maxClosedCaseRows;
        ActivosOperadorController.AssetPage cappedAtOne;
        ActivosOperadorController.AssetPage cappedAtTwo;
        try {
            ActivosOperadorController.maxClosedCaseRows = 1;
            cappedAtOne = loadResult(operator, null, null, null);
            ActivosOperadorController.maxClosedCaseRows = 2;
            cappedAtTwo = loadResult(operator, null, null, null);
        } finally {
            ActivosOperadorController.maxClosedCaseRows = originalCap;
        }

        // Then without the cap both assets have a line (control), so the cap alone removes the one outside the cut
        Map<String, ActivosOperadorController.AssetView> free = byName(uncapped.assets);
        Assert.isNotNull(free.get('AST-CAP-OLDER').lastClosedIntervention);
        Assert.isNotNull(free.get('AST-CAP-NEWER').lastClosedIntervention);
        Assert.isFalse(uncapped.truncated);
        // and with one row only the asset holding the newest closed case keeps its line, and both assets are still listed
        Map<String, ActivosOperadorController.AssetView> cut = byName(cappedAtOne.assets);
        Assert.areEqual(2, cut.size());
        Assert.isNotNull(cut.get('AST-CAP-NEWER').lastClosedIntervention);
        Assert.areEqual(newerCase.Id, cut.get('AST-CAP-NEWER').lastClosedIntervention.caseId);
        Assert.isNull(cut.get('AST-CAP-OLDER').lastClosedIntervention, 'the asset outside the cut must show no line');
        // and the cap is not reported as a truncated list: this line is only context
        Assert.areEqual(uncapped.truncated, cappedAtOne.truncated, 'the closed-case cap must not change the truncated flag');
        Assert.isFalse(cappedAtOne.truncated);
        Assert.areEqual(uncapped.totalCount, cappedAtOne.totalCount);
        // and a cap equal to the number of closed cases cuts nothing
        Map<String, ActivosOperadorController.AssetView> exact = byName(cappedAtTwo.assets);
        Assert.isNotNull(exact.get('AST-CAP-OLDER').lastClosedIntervention);
        Assert.isNotNull(exact.get('AST-CAP-NEWER').lastClosedIntervention);
        Assert.isFalse(cappedAtTwo.truncated);
    }

    @isTest
    static void lastClosedInterventionExposesOnlyTheAgreedKeysAndNothingAboutWhoClosedIt() {
        // Given an asset whose only case is closed (with a recognizable subject) and an asset with an open case
        Account building = newAccount('Edificio Llaves Cerrado');
        Asset closedAsset = newAsset('AST-KEYS-1-CLOSED', building, 'WATER_PUMP');
        Asset openAsset = newAsset('AST-KEYS-2-OPEN', building, 'WATER_PUMP');
        Case closed = newCase(closedAsset, 'Closed', 'ASUNTO-SECRETO-XYZ');
        newCase(openAsset, 'New', 'Abierto');

        // When the page is serialized, as the component receives it
        String payload = JSON.serialize(loadResult(userLike('nc207operator'), null, null, null));
        Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(payload);
        List<Object> assets = (List<Object>) top.get('assets');
        Map<String, Object> closedJson = (Map<String, Object>) assets[0];
        Map<String, Object> openJson = (Map<String, Object>) assets[1];
        Map<String, Object> line = (Map<String, Object>) closedJson.get('lastClosedIntervention');

        // Then the closed intervention has exactly caseId, caseNumber and closedDate, and no other case data or "closed by"
        Assert.areEqual('AST-KEYS-1-CLOSED', (String) closedJson.get('name'));
        Assert.isNotNull(line, 'the closed asset must carry lastClosedIntervention');
        Assert.areEqual(new Set<String>{ 'caseId', 'caseNumber', 'closedDate' }, line.keySet());
        Assert.areEqual(String.valueOf(closed.Id), (String) line.get('caseId'));
        Assert.isNotNull(line.get('caseNumber'));
        Assert.isNotNull(line.get('closedDate'));
        Assert.isFalse(payload.contains('SECRETO'), 'the subject of a closed case must not leave the controller');
        Assert.isFalse(payload.containsIgnoreCase('closedBy'), 'there is no "closed by": Case has no history tracking here');
        // and an asset with an open case still carries the key, empty, so the component has one contract
        Assert.areEqual('AST-KEYS-2-OPEN', (String) openJson.get('name'));
        Assert.isTrue(openJson.containsKey('lastClosedIntervention'));
        Assert.isNull(openJson.get('lastClosedIntervention'));
    }

    // Case.ClosedDate is permissionable (it needs read FLS like Case.Subject), so the closed lookup of getAssets is only allowed
    // for a user whose permission set grants it. The tests below pin that from every side: the lookup really enforces it, it
    // only runs when it has to, the four shipped sets grant it, and the roles above the operator receive the line.

    @isTest
    static void listFailsWithTheSafeAccessMessageWhenTheUserCannotReadCaseClosedDateAndAnAssetHasNoOpenCase() {
        // Given a user whose permission set grants everything the list needs EXCEPT Case.ClosedDate, who owns a building with
        // an asset that has a reading and only a closed case, so the closed lookup has to run
        User noClosedDate = newUserWithEverythingButClosedDate();
        Account building = newAccount('Edificio Sin Fecha Cierre', noClosedDate.Id);
        Asset asset = newAsset('AST-NOCD-CLOSED', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);
        newCase(asset, 'Closed', 'Cerrado sin permiso');

        // When that user loads the list
        ActivosOperadorController.AssetPage page;
        AuraHandledException error;
        System.runAs(noClosedDate) {
            try {
                page = ActivosOperadorController.getAssets(null, null, null);
            } catch (AuraHandledException e) {
                error = e;
            }
        }

        // Then the call fails with the static access message and returns no data. This is what proves the closed lookup runs
        // WITH USER_MODE: the user can see the asset, its reading and its case, and lacks only FLS on ClosedDate, so if the
        // query ran in system mode (or without enforcement) nothing would throw and this test would fail.
        Assert.isNotNull(error, 'Missing FLS on Case.ClosedDate must raise an AuraHandledException when the closed lookup runs');
        Assert.areEqual(ActivosOperadorController.ACCESS_MESSAGE, error.getMessage());
        Assert.isFalse(error.getMessage().contains('ClosedDate'), 'the message must not name the field');
        Assert.isNull(page, 'no partial data may be returned');
    }

    @isTest
    static void listLoadsForAUserWithoutCaseClosedDateAccessWhenEveryAssetOnThePageHasAnOpenCase() {
        // Given the same kind of user (everything except Case.ClosedDate) and a building whose only asset has an open case
        // and an older closed one, so no asset needs the closed lookup
        User noClosedDate = newUserWithEverythingButClosedDate();
        Account building = newAccount('Edificio Todo Abierto Sin Permiso', noClosedDate.Id);
        Asset asset = newAsset('AST-NOCD-OPEN', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);
        newCase(asset, 'Closed', 'Cerrado viejo');
        Case open = newCase(asset, 'New', 'Abierto actual');

        // When that user loads the list
        ActivosOperadorController.AssetPage page;
        AuraHandledException error;
        System.runAs(noClosedDate) {
            try {
                page = ActivosOperadorController.getAssets(null, null, null);
            } catch (AuraHandledException e) {
                error = e;
            }
        }

        // Then nothing throws: the closed lookup is skipped, so the missing ClosedDate access does not matter. This is also the
        // control of the test above: it shows ClosedDate is the only thing that user lacks for the list.
        Assert.isNull(error, 'the closed lookup must not run (and so not need ClosedDate) when every asset has an open case');
        Assert.areEqual(1, page.assets.size());
        Assert.areEqual(asset.Id, page.assets[0].assetId);
        Assert.areEqual(2, page.assets[0].severityLevel);
        Assert.areEqual(1, page.assets[0].openInterventionCount);
        Assert.areEqual(open.Id, page.assets[0].openIntervention.caseId);
        Assert.isNull(page.assets[0].lastClosedIntervention, 'an asset with an open case never offers a closed one');
    }

    @isTest
    static void everyShippedPermissionSetGrantsReadOnlyAccessToCaseClosedDate() {
        // Given the four shipped permission sets of the screen
        List<String> shipped = new List<String>{ 'Nova_Casa_Operator', 'Nova_Casa_Coordinator', 'Nova_Casa_Gerente', 'Nova_Casa_Admin' };
        Map<Id, PermissionSet> sets = new Map<Id, PermissionSet>([SELECT Id, Name FROM PermissionSet WHERE Name IN :shipped]);
        Assert.areEqual(4, sets.size(), 'all four shipped permission sets must be deployed to the org');

        // When their field permissions on Case.ClosedDate are read
        List<FieldPermissions> fieldPerms = [
            SELECT ParentId, PermissionsRead, PermissionsEdit
            FROM FieldPermissions
            WHERE SobjectType = 'Case' AND Field = 'Case.ClosedDate' AND ParentId IN :sets.keySet()
        ];
        Map<String, FieldPermissions> bySet = new Map<String, FieldPermissions>();
        for (FieldPermissions fieldPerm : fieldPerms) {
            bySet.put(sets.get(fieldPerm.ParentId).Name, fieldPerm);
        }

        // Then every set grants read and not edit, and there is exactly one row per set
        for (String setName : shipped) {
            FieldPermissions fieldPerm = bySet.get(setName);
            Assert.isNotNull(fieldPerm, setName + ' must have a field permission on Case.ClosedDate');
            Assert.isTrue(fieldPerm.PermissionsRead, setName + ' must grant read on Case.ClosedDate (getAssets reads it in USER_MODE)');
            Assert.isFalse(fieldPerm.PermissionsEdit, setName + ' must not grant edit on Case.ClosedDate');
        }
        Assert.areEqual(4, fieldPerms.size(), 'expected exactly one Case.ClosedDate field permission per shipped permission set');
    }

    @isTest
    static void realCoordinatorAndGerentePermissionSetsReceiveTheLastClosedInterventionOfAVisibleCase() {
        // Given a coordinator and a Gerente, each holding only their shipped permission set, above the building's operator,
        // and an asset whose only case is closed
        User coordinator = newUserWithPermissionSet('nc207closedcoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        User gerente = newUserWithPermissionSet('nc207closedger', 'Nova_Casa_Gerente', GERENTE_ROLE);
        Account building = newAccount('Edificio Cerrado Roles');
        Asset asset = newAsset('AST-CLOSED-ROLES', building, 'WATER_PUMP');
        Case closed = reloaded(newCase(asset, 'Closed', 'Cerrado roles'));
        Assert.isNotNull(closed.ClosedDate, 'precondition: closing a case stamps ClosedDate');

        // When each loads the list
        Map<String, ActivosOperadorController.AssetPage> pages = new Map<String, ActivosOperadorController.AssetPage>();
        pages.put('Nova_Casa_Coordinator', loadResult(coordinator, null, null, null));
        pages.put('Nova_Casa_Gerente', loadResult(gerente, null, null, null));

        // Then both see the asset through the role hierarchy and receive its closed case, which needs read FLS on ClosedDate
        for (String setName : pages.keySet()) {
            ActivosOperadorController.AssetPage page = pages.get(setName);
            Assert.areEqual(1, page.assets.size(), setName + ' must see the operator asset');
            ActivosOperadorController.AssetView view = page.assets[0];
            Assert.areEqual(asset.Id, view.assetId, setName);
            Assert.isNotNull(view.lastClosedIntervention, setName + ' must receive the last closed intervention of a case it can see');
            Assert.areEqual(closed.Id, view.lastClosedIntervention.caseId, setName);
            Assert.areEqual(closed.CaseNumber, view.lastClosedIntervention.caseNumber, setName);
            Assert.areEqual(closed.ClosedDate, view.lastClosedIntervention.closedDate, setName);
            Assert.isNull(view.openIntervention, setName);
        }
    }

    @isTest
    static void realAdminPermissionSetReceivesTheLastClosedInterventionWithoutAnyRole() {
        // Given a user holding only the shipped Nova_Casa_Admin set and no role (it sees the building through View All, as in
        // realCoordinatorAndAdminPermissionSetsCanOpenTheAssetState), and an asset whose only case is closed
        User admin = newUserWithPermissionSet('nc207closedadmin', 'Nova_Casa_Admin', null);
        Account building = newAccount('Edificio Cerrado Admin');
        Asset asset = newAsset('AST-CLOSED-ADMIN', building, 'WATER_PUMP');
        Case closed = reloaded(newCase(asset, 'Closed', 'Cerrado admin'));
        Assert.isNotNull(closed.ClosedDate, 'precondition: closing a case stamps ClosedDate');

        // When that user loads the list
        ActivosOperadorController.AssetPage page = loadResult(admin, null, null, null);

        // Then the asset and its closed case come back, with the closing date
        Assert.areEqual(1, page.assets.size(), 'Nova_Casa_Admin must see the operator asset');
        Assert.isNotNull(page.assets[0].lastClosedIntervention, 'Nova_Casa_Admin must receive the last closed intervention');
        Assert.areEqual(closed.Id, page.assets[0].lastClosedIntervention.caseId);
        Assert.areEqual(closed.CaseNumber, page.assets[0].lastClosedIntervention.caseNumber);
        Assert.areEqual(closed.ClosedDate, page.assets[0].lastClosedIntervention.closedDate);
    }

    // ---------- intervention record page (HP-07) ----------

    @isTest
    static void interventionMethodsRejectNullAnAssetIdAndAHiddenCaseWithTheSameSafeMessage() {
        // Given two operators with the shipped set, and a Case with a linked signal on operator A's building
        User operatorA = newUserWithPermissionSet('nc207caseopa', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User operatorB = newUserWithPermissionSet('nc207caseopb', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Caso Oculto', operatorA.Id);
        Asset asset = newAsset('AST-CASE-DENY', building, 'WATER_PUMP');
        Case hidden = newCase(asset, 'En curso', 'Caso de A');
        insert linkedLog(asset, hidden.Id, baseTime());

        // When the owner passes null and an Asset Id, and operator B passes A's Case Id, to both methods
        List<String> forNull = bothOutcomes(operatorA, null);
        List<String> forAsset = bothOutcomes(operatorA, asset.Id);
        List<String> forHidden = bothOutcomes(operatorB, hidden.Id);

        // Then every call fails with the same static message and returns nothing, while the owner does get the signal
        List<String> denied = new List<String>{ ActivosOperadorController.CASE_MESSAGE, ActivosOperadorController.CASE_MESSAGE };
        Assert.areEqual(denied, forNull, 'a null id must be rejected by both methods');
        Assert.areEqual(denied, forAsset, 'an Asset id must be rejected by both methods');
        Assert.areEqual(denied, forHidden, 'a Case the user cannot see must be rejected like a missing one, without its log');
        Assert.areEqual(1, interventionSignals(operatorA, hidden.Id, null).signals.size(), 'the owner sees the linked signal');
    }

    @isTest
    static void realOperatorCoordinatorGerenteAndAdminPermissionSetsReadAVisibleIntervention() {
        // Given the four shipped screen sets (the Gerente's grants no access to IntervencionOperadorController), and a
        // telemetry Case with priority and origin on the operator's building, with one linked signal
        User operator = newUserWithPermissionSet('nc207caseroleop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Map<String, User> bySet = new Map<String, User>{
            'Nova_Casa_Operator' => operator,
            'Nova_Casa_Coordinator' => newUserWithPermissionSet('nc207caserolecoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE),
            'Nova_Casa_Gerente' => newUserWithPermissionSet('nc207caseroleger', 'Nova_Casa_Gerente', GERENTE_ROLE),
            'Nova_Casa_Admin' => newUserWithPermissionSet('nc207caseroleadm', 'Nova_Casa_Admin', null)
        };
        Set<String> gerenteClasses = apexClassesOf('Nova_Casa_Gerente');
        Assert.isTrue(gerenteClasses.contains('ActivosOperadorController'), 'Nova_Casa_Gerente must be able to call the record-page methods');
        Assert.isFalse(gerenteClasses.contains('IntervencionOperadorController'),
            'precondition: the Gerente cannot call IntervencionOperadorController, so the page must not need it');
        Account building = newAccount('Edificio Caso Roles', operator.Id);
        Asset asset = newAsset('AST-CASE-ROLES', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);
        Case c = caseDraft(asset, operator.Id, 'En curso', 'Señal crítica roles');
        c.Origin = 'Telemetria';
        c.Priority = 'Critica';
        insert c;
        insert linkedLog(asset, c.Id, baseTime());

        // When each opens the intervention and its signals
        Map<String, ActivosOperadorController.IntervencionDetalle> details = new Map<String, ActivosOperadorController.IntervencionDetalle>();
        Map<String, ActivosOperadorController.SenalesIntervencion> signalLists = new Map<String, ActivosOperadorController.SenalesIntervencion>();
        Map<String, String> errors = new Map<String, String>();
        for (String setName : bySet.keySet()) {
            System.runAs(bySet.get(setName)) {
                try {
                    details.put(setName, ActivosOperadorController.getIntervencion(c.Id));
                    signalLists.put(setName, ActivosOperadorController.getSenalesDeIntervencion(c.Id, null));
                } catch (AuraHandledException e) {
                    errors.put(setName, e.getMessage());
                }
            }
        }

        // Then nobody gets an error (the detail reads Case.Origin and Case.Priority WITH USER_MODE) and the detail carries them
        for (String setName : bySet.keySet()) {
            Assert.isNull(errors.get(setName), setName + ' must read the intervention');
            ActivosOperadorController.IntervencionDetalle detalle = details.get(setName);
            Assert.areEqual(c.Id, detalle.caseId, setName);
            Assert.areEqual('Critica', detalle.priority, setName + ' must receive Case.Priority');
            Assert.areEqual('Telemetria', detalle.origin, setName + ' must receive Case.Origin');
            Assert.isTrue(detalle.esTelemetria, setName);
            Assert.isTrue(detalle.recibeCriticas, setName + ': the only open telemetry Case of the asset receives its criticals');
            Assert.areEqual(asset.Id, detalle.assetId, setName);
            Assert.areEqual('AST-CASE-ROLES', detalle.assetName, setName);
            Assert.areEqual(building.Id, detalle.accountId, setName);
            Assert.areEqual('Edificio Caso Roles', detalle.accountName, setName);
            Assert.areEqual(2, detalle.assetLevel, setName);
            Assert.areEqual(1, detalle.senalesEnlazadas, setName);
            Assert.isFalse(detalle.estados.isEmpty(), setName + ' must receive the follow-up statuses');
            Assert.areEqual(1, signalLists.get(setName).signals.size(), setName);
        }
    }

    @isTest
    static void interventionDetailWithoutReadOnCaseOriginOrPriorityGetsTheSafeAccessMessage() {
        // Given three users who each own a building with an open Case: one reads every field the detail selects, the other
        // two miss only Case.Origin or only Case.Priority
        Map<String, User> byMissingField = new Map<String, User>{
            'nothing' => newUserWithCaseReadExcept('nc207caseallfls', null),
            'Case.Origin' => newUserWithCaseReadExcept('nc207casenoorigin', 'Case.Origin'),
            'Case.Priority' => newUserWithCaseReadExcept('nc207casenoprio', 'Case.Priority')
        };
        Map<String, Case> caseByMissingField = new Map<String, Case>();
        for (String missing : byMissingField.keySet()) {
            User owner = byMissingField.get(missing);
            Account building = newAccount('Edificio FLS ' + missing, owner.Id);
            Asset asset = newAsset('AST-CASE-FLS-' + caseByMissingField.size(), building, 'WATER_PUMP');
            newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);
            Case c = caseDraft(asset, owner.Id, 'En curso', 'FLS ' + missing);
            c.Priority = 'Critica';
            insert c;
            insert linkedLog(asset, c.Id, baseTime());
            caseByMissingField.put(missing, c);
        }

        // When each opens the detail and the signal list of their own Case
        Map<String, String> detailErrors = new Map<String, String>();
        Map<String, Integer> signalCounts = new Map<String, Integer>();
        for (String missing : byMissingField.keySet()) {
            Id caseId = caseByMissingField.get(missing).Id;
            System.runAs(byMissingField.get(missing)) {
                try {
                    ActivosOperadorController.getIntervencion(caseId);
                    detailErrors.put(missing, null);
                } catch (AuraHandledException e) {
                    detailErrors.put(missing, e.getMessage());
                }
                signalCounts.put(missing, ActivosOperadorController.getSenalesDeIntervencion(caseId, null).signals.size());
            }
        }

        // Then the full set loads; missing either field fails with the static access message, not data or platform text,
        // while the signal list (which reads neither field) loads for everyone
        Assert.isNull(detailErrors.get('nothing'), 'with every field readable the detail must load, or the failures below prove nothing');
        for (String missing : new List<String>{ 'Case.Origin', 'Case.Priority' }) {
            Assert.areEqual(ActivosOperadorController.ACCESS_MESSAGE, detailErrors.get(missing), 'without read on ' + missing);
            Assert.isFalse(detailErrors.get(missing).contains(missing.substringAfter('.')), 'the message must not name the field');
        }
        for (String missing : byMissingField.keySet()) {
            Assert.areEqual(1, signalCounts.get(missing), missing);
        }
    }

    @isTest
    static void lastFollowUpIsTheLastMatchingLineSplitIntoDateAuthorAndTextAndOtherLinesAreIgnored() {
        // Given a coordinator above the building, and a telemetry Case whose Description has two follow-up lines (CRLF-
        // separated), then lines that do not match the pattern; it also carries the manual-reason separator
        User operator = newUserWithPermissionSet('nc207fupop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('nc207fupcoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Account building = newAccount('Edificio Seguimiento', operator.Id);
        Asset asset = newAsset('AST-CASE-FUP', building, 'WATER_PUMP');
        Case c = caseDraft(asset, operator.Id, 'En curso', 'Seguimiento');
        c.Origin = 'Telemetria';
        c.Description = 'Texto inicial'
            + '\n\nAbierta por: Alguien'
            + '\n[2026-10-01 09:15 Ana Pérez] Revisando la bomba'
            + '\r\n[2026-10-02 18:40 Luis Gómez] Cambio de válvula'
            + '\r\nnota suelta sin formato'
            + '\n[2026-10-03 Sin Hora] fecha incompleta'
            + '\n[2026-10-04 07:00 Sin Texto]';
        insert c;

        // When the coordinator opens it
        Boolean readsDescription;
        ActivosOperadorController.IntervencionDetalle detalle;
        System.runAs(coordinator) {
            readsDescription = Schema.SObjectType.Case.fields.Description.isAccessible();
            detalle = ActivosOperadorController.getIntervencion(c.Id);
        }

        // Then the last line that matches is returned split into its parts, and a telemetry Case has no manual reason
        Assert.isTrue(readsDescription, 'precondition: Nova_Casa_Coordinator reads Case.Description');
        Assert.isNotNull(detalle.ultimoSeguimiento, 'the last matching follow-up line must be found');
        Assert.areEqual('2026-10-02 18:40', detalle.ultimoSeguimiento.fecha);
        Assert.areEqual('Luis Gómez', detalle.ultimoSeguimiento.autor);
        Assert.areEqual('Cambio de válvula', detalle.ultimoSeguimiento.texto);
        Assert.isNull(detalle.motivo, 'only an Origin Operador intervention has a reason, even when the separator is present');
    }

    @isTest
    static void manualReasonIsTheTextBeforeAbiertaPorForTheCoordinatorAndTheOperatorGetsNoPartOfTheDescription() {
        // Given a manual intervention whose Description is what crearIntervencion writes plus one follow-up line
        User operator = newUserWithPermissionSet('nc207motop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('nc207motcoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Account building = newAccount('Edificio Motivo', operator.Id);
        Asset asset = newAsset('AST-CASE-MOTIVO', building, 'WATER_PUMP');
        Case manual = caseDraft(asset, operator.Id, 'En curso', 'Intervención manual en AST-CASE-MOTIVO');
        manual.Origin = 'Operador';
        manual.Description = 'La bomba vibra al arrancar\ny hace ruido'
            + '\n\nAbierta por: Operador Uno'
            + '\n[2026-10-05 08:30 Coordinador Uno] Visita programada';
        insert manual;

        // When the coordinator and the operator open it
        Boolean coordinatorReadsDescription;
        Boolean operatorReadsDescription;
        ActivosOperadorController.IntervencionDetalle forCoordinator;
        ActivosOperadorController.IntervencionDetalle forOperator;
        System.runAs(coordinator) {
            coordinatorReadsDescription = Schema.SObjectType.Case.fields.Description.isAccessible();
            forCoordinator = ActivosOperadorController.getIntervencion(manual.Id);
        }
        System.runAs(operator) {
            operatorReadsDescription = Schema.SObjectType.Case.fields.Description.isAccessible();
            forOperator = ActivosOperadorController.getIntervencion(manual.Id);
        }

        // Then the coordinator gets the reason and the follow-up; the operator gets the intervention without either
        Assert.isTrue(coordinatorReadsDescription, 'precondition: Nova_Casa_Coordinator reads Case.Description');
        Assert.isFalse(operatorReadsDescription, 'precondition: Nova_Casa_Operator must not read Case.Description, or this proves nothing');
        Assert.areEqual('La bomba vibra al arrancar\ny hace ruido', forCoordinator.motivo);
        Assert.isFalse(forCoordinator.esTelemetria);
        Assert.areEqual('2026-10-05 08:30', forCoordinator.ultimoSeguimiento.fecha);
        Assert.areEqual('Coordinador Uno', forCoordinator.ultimoSeguimiento.autor);
        Assert.areEqual('Visita programada', forCoordinator.ultimoSeguimiento.texto);
        Assert.areEqual(manual.Id, forOperator.caseId, 'the operator still gets the intervention');
        Assert.areEqual('Operador', forOperator.origin);
        Assert.isNull(forOperator.motivo, 'no reason without FLS on Description');
        Assert.isNull(forOperator.ultimoSeguimiento, 'no follow-up without FLS on Description');
        String operatorPayload = JSON.serialize(forOperator);
        Assert.isFalse(operatorPayload.contains('vibra'), 'no part of the Description reaches a user without FLS on it');
        Assert.isFalse(operatorPayload.contains('Visita programada'), 'no part of the Description reaches a user without FLS on it');
    }

    @isTest
    static void interventionPayloadsCarryNoIdentityDescriptionMotivoOrHuella() {
        // Given a telemetry Case whose identity, Description and linked log row carry recognizable values, opened by an
        // operator, a coordinator and an admin (both read Description; only the admin reads the log)
        User operator = newUserWithPermissionSet('nc207leakop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Map<String, User> viewers = new Map<String, User>{
            'Nova_Casa_Operator' => operator,
            'Nova_Casa_Coordinator' => newUserWithPermissionSet('nc207leakcoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE),
            'Nova_Casa_Admin' => newUserWithPermissionSet('nc207leakadm', 'Nova_Casa_Admin', null)
        };
        Account building = newAccount('Edificio Fuga', operator.Id);
        Asset asset = newAsset('AST-CASE-LEAK', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);
        Log_Senial__c opener = linkedLog(asset, null, baseTime());
        opener.Motivo__c = 'MOTIVO-SECRETO-XYZ';
        opener.Huella__c = 'HUELLA-SECRETA-XYZ';
        String identity = opener.Identidad__c;
        Case c = caseDraft(asset, operator.Id, 'En curso', 'Señal crítica fuga');
        c.Origin = 'Telemetria';
        c.Priority = 'Critica';
        c.Identidad_Senal__c = identity;
        c.Ultima_Critica_Identidad__c = identity;
        c.Ultima_Critica_Medicion__c = 'TEMPERATURE';
        c.Ultima_Critica_Valor__c = 95.5;
        c.Ultima_Critica_Unidad__c = 'CELSIUS';
        c.Ultima_Critica_At__c = baseTime();
        c.Description = 'DESCRIPCION-PRIVADA-XYZ\n[2026-10-01 10:00 Ana Pérez] Revisado en sitio';
        insert c;
        opener.Caso__c = c.Id;
        insert opener;

        // When each serializes both DTOs
        Map<String, String> detailPayloads = new Map<String, String>();
        Map<String, String> signalPayloads = new Map<String, String>();
        for (String setName : viewers.keySet()) {
            System.runAs(viewers.get(setName)) {
                detailPayloads.put(setName, JSON.serialize(ActivosOperadorController.getIntervencion(c.Id)));
                signalPayloads.put(setName, JSON.serialize(ActivosOperadorController.getSenalesDeIntervencion(c.Id, null)));
            }
        }

        // Then no payload names or carries the identity, the Description, Motivo__c or Huella__c
        List<String> forbidden = new List<String>{
            'Identidad', 'Description', 'Motivo__c', 'Huella', identity, opener.Message_Id__c,
            'SECRETO', 'SECRETA', 'DESCRIPCION-PRIVADA'
        };
        for (String setName : viewers.keySet()) {
            for (String payload : new List<String>{ detailPayloads.get(setName), signalPayloads.get(setName) }) {
                for (String token : forbidden) {
                    Assert.isFalse(payload.contains(token), setName + ' payload must not contain ' + token);
                }
            }
        }
        // and only the agreed keys are present (checked where every nested part is filled)
        String coordinatorDetail = detailPayloads.get('Nova_Casa_Coordinator');
        Assert.isTrue(coordinatorDetail.contains('Revisado en sitio'), 'precondition: the derived follow-up does reach the coordinator');
        Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(coordinatorDetail);
        Assert.areEqual(new Set<String>{
            'caseId', 'caseNumber', 'subject', 'status', 'isClosed', 'createdDate', 'closedDate', 'priority', 'origin',
            'esTelemetria', 'recibeCriticas', 'horasAbierta', 'assetId', 'assetName', 'assetExternalId', 'assetType',
            'accountId', 'accountName', 'assetLevel', 'lecturaActual', 'lecturasIncompletas', 'ultimaCritica',
            'senalesEnlazadas', 'ultimoSeguimiento', 'motivo', 'estados', 'puedeSeguir'
        }, top.keySet());
        Assert.areEqual(new Set<String>{ 'measurementType', 'value', 'unit', 'occurredAt', 'severityLevel' },
            ((Map<String, Object>) top.get('lecturaActual')).keySet());
        Assert.areEqual(new Set<String>{ 'measurementType', 'value', 'unit', 'occurredAt' },
            ((Map<String, Object>) top.get('ultimaCritica')).keySet());
        Assert.areEqual(new Set<String>{ 'fecha', 'autor', 'texto' }, ((Map<String, Object>) top.get('ultimoSeguimiento')).keySet());
        Map<String, Object> signalsTop = (Map<String, Object>) JSON.deserializeUntyped(signalPayloads.get('Nova_Casa_Admin'));
        Assert.areEqual(new Set<String>{ 'signals', 'truncated' }, signalsTop.keySet());
        Map<String, Object> first = (Map<String, Object>) ((List<Object>) signalsTop.get('signals'))[0];
        Assert.areEqual(new Set<String>{ 'occurredAt', 'measurementType', 'value', 'unit', 'result', 'resends', 'abrio' }, first.keySet());
        Assert.areEqual(true, first.get('abrio'), 'the opening signal is flagged without returning its identity');
    }

    @isTest
    static void interventionSignalsAreOnlyThoseOfTheCaseNewestFirstWithTheOpenerFlaggedAndNullResendsAsZero() {
        // Given an open telemetry Case with four linked rows inserted out of order (the opener, a resent one, one whose resend
        // count is null and one without identity), plus a newer row of an older Case of the same asset and a newer unlinked row
        User operator = newUserWithPermissionSet('nc207sigop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Senales', operator.Id);
        Asset asset = newAsset('AST-CASE-SIG', building, 'WATER_PUMP');
        Datetime now = baseTime();
        Log_Senial__c opener = linkedLog(asset, null, now.addMinutes(-20));
        Case c = caseDraft(asset, operator.Id, 'En curso', 'Señal crítica señales');
        c.Origin = 'Telemetria';
        // Upper-cased on the Case: the opener must be matched ignoring letter case.
        c.Identidad_Senal__c = opener.Identidad__c.toUpperCase();
        Case older = caseDraft(asset, operator.Id, 'Closed', 'Anterior');
        insert new List<Case>{ c, older };
        Assert.isFalse(c.Identidad_Senal__c.equals(opener.Identidad__c), 'precondition: the two identities differ in letter case');
        opener.Caso__c = c.Id;
        opener.Reenvios__c = 0;
        Log_Senial__c resent = linkedLog(asset, c.Id, now);
        resent.Value__c = 97.5;
        resent.Reenvios__c = 3;
        Log_Senial__c nullResends = linkedLog(asset, c.Id, now.addMinutes(-10));
        nullResends.Resultado__c = 'Superada';
        Log_Senial__c noIdentity = linkedLog(asset, c.Id, now.addMinutes(-30));
        noIdentity.Identidad__c = null;
        Log_Senial__c ofOlderCase = linkedLog(asset, older.Id, now.addMinutes(5));
        Log_Senial__c unlinked = linkedLog(asset, null, now.addMinutes(10));
        insert new List<Log_Senial__c>{ nullResends, opener, unlinked, resent, ofOlderCase, noIdentity };
        // Reenvios__c has a default value, so it is cleared after the insert.
        update new Log_Senial__c(Id = nullResends.Id, Reenvios__c = null);
        Assert.isNull([SELECT Reenvios__c FROM Log_Senial__c WHERE Id = :nullResends.Id].Reenvios__c, 'precondition: a null resend count');

        // When the operator reads the signals of each Case, and the count on the detail
        ActivosOperadorController.SenalesIntervencion all = interventionSignals(operator, c.Id, null);
        ActivosOperadorController.SenalesIntervencion exact = interventionSignals(operator, c.Id, 4);
        ActivosOperadorController.SenalesIntervencion cut = interventionSignals(operator, c.Id, 3);
        ActivosOperadorController.SenalesIntervencion ofOlder = interventionSignals(operator, older.Id, null);
        Integer linked = intervention(operator, c.Id).senalesEnlazadas;
        Integer linkedToOlder = intervention(operator, older.Id).senalesEnlazadas;

        // Then only this Case's rows come back, newest first, with its values and only the opener flagged
        Assert.areEqual(4, all.signals.size(), 'only the rows linked to this Case, not to another Case or to none');
        Assert.isFalse(all.truncated);
        List<Datetime> times = new List<Datetime>();
        for (ActivosOperadorController.SenalIntervencion s : all.signals) {
            times.add(s.occurredAt);
        }
        Assert.areEqual(new List<Datetime>{ now, now.addMinutes(-10), now.addMinutes(-20), now.addMinutes(-30) }, times, 'newest first');
        ActivosOperadorController.SenalIntervencion newest = all.signals[0];
        Assert.areEqual('TEMPERATURE', newest.measurementType);
        Assert.areEqual(97.5, newest.value);
        Assert.areEqual('CELSIUS', newest.unit);
        Assert.areEqual('Procesada', newest.result);
        Assert.areEqual(3, newest.resends);
        Assert.isFalse(newest.abrio);
        Assert.areEqual('Superada', all.signals[1].result);
        Assert.areEqual(0, all.signals[1].resends, 'a null resend count is returned as 0');
        Assert.isFalse(all.signals[1].abrio);
        Assert.isTrue(all.signals[2].abrio, 'the row whose identity opened the Case is flagged, ignoring letter case');
        Assert.areEqual(0, all.signals[2].resends);
        Assert.isFalse(all.signals[3].abrio, 'a row without identity never opened the Case');
        // the limit cuts and flags only beyond the linked rows
        Assert.areEqual(4, exact.signals.size());
        Assert.isFalse(exact.truncated, 'exactly the number of linked rows is not a cut');
        Assert.areEqual(3, cut.signals.size());
        Assert.isTrue(cut.truncated);
        Assert.areEqual(now, cut.signals[0].occurredAt);
        // the other Case has its own row and no opener
        Assert.areEqual(1, ofOlder.signals.size());
        Assert.areEqual(now.addMinutes(5), ofOlder.signals[0].occurredAt);
        Assert.isFalse(ofOlder.signals[0].abrio, 'a Case without an opening identity flags nothing');
        // and the detail counts the linked rows
        Assert.areEqual(4, linked);
        Assert.areEqual(1, linkedToOlder);
    }

    @isTest
    static void interventionSignalsLimitDefaultsToTwentyIsClampedBetweenOneAndFiftyAndFlagsTruncation() {
        // Given a Case with 55 linked signals, one minute apart
        User operator = newUserWithPermissionSet('nc207siglimop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Senales Tope', operator.Id);
        Asset asset = newAsset('AST-CASE-SIG-CAP', building, 'WATER_PUMP');
        Case c = caseDraft(asset, operator.Id, 'En curso', 'Muchas señales');
        insert c;
        Datetime now = baseTime();
        List<Log_Senial__c> rows = new List<Log_Senial__c>();
        for (Integer i = 0; i < 55; i++) {
            rows.add(linkedLog(asset, c.Id, now.addMinutes(-i)));
        }
        insert rows;

        // When the operator asks with no limit, below 1, and above 50
        ActivosOperadorController.SenalesIntervencion byDefault = interventionSignals(operator, c.Id, null);
        ActivosOperadorController.SenalesIntervencion zero = interventionSignals(operator, c.Id, 0);
        ActivosOperadorController.SenalesIntervencion negative = interventionSignals(operator, c.Id, -5);
        ActivosOperadorController.SenalesIntervencion huge = interventionSignals(operator, c.Id, 500);
        Integer linked = intervention(operator, c.Id).senalesEnlazadas;

        // Then null means 20, the limit is clamped to 1..50, the newest rows win and the cut is flagged
        Assert.areEqual(20, byDefault.signals.size(), 'no limit means 20');
        Assert.isTrue(byDefault.truncated);
        Assert.areEqual(now, byDefault.signals[0].occurredAt);
        Assert.areEqual(now.addMinutes(-19), byDefault.signals[19].occurredAt);
        Assert.areEqual(1, zero.signals.size(), 'a limit below 1 is clamped to 1');
        Assert.isTrue(zero.truncated);
        Assert.areEqual(now, zero.signals[0].occurredAt);
        Assert.areEqual(1, negative.signals.size());
        Assert.areEqual(50, huge.signals.size(), 'a limit above 50 is clamped to 50');
        Assert.isTrue(huge.truncated);
        Assert.areEqual(now.addMinutes(-49), huge.signals[49].occurredAt);
        Assert.areEqual(55, linked, 'the linked count is not capped by the list limit');
    }

    @isTest
    static void puedeSeguirIsTrueOnlyForTheCoordinatorOnAnOpenCaseWithAnAsset() {
        // Given an operator, a coordinator and a Gerente on one building, an open and a closed Case with assets, and an open
        // Case without asset
        User operator = newUserWithPermissionSet('nc207segop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('nc207segcoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        User gerente = newUserWithPermissionSet('nc207segger', 'Nova_Casa_Gerente', GERENTE_ROLE);
        Account building = newAccount('Edificio Seguir', operator.Id);
        Asset asset = newAsset('AST-CASE-SEGUIR', building, 'WATER_PUMP');
        Asset closedAsset = newAsset('AST-CASE-SEGUIR-CERRADO', building, 'WATER_PUMP');
        Case open = caseDraft(asset, operator.Id, 'En curso', 'Abierta');
        Case closed = caseDraft(closedAsset, operator.Id, 'Closed', 'Cerrada');
        Case withoutAsset = new Case(OwnerId = operator.Id, Status = 'En curso', Subject = 'Sin activo', Origin = 'Web');
        insert new List<Case>{ open, closed, withoutAsset };

        // When each opens the Cases
        Map<String, Boolean> holdsTheKey = new Map<String, Boolean>();
        Map<String, Boolean> canFollow = new Map<String, Boolean>();
        System.runAs(coordinator) {
            holdsTheKey.put('coordinator', FeatureManagement.checkPermission(IntervencionOperadorController.PERM_SEGUIR));
            canFollow.put('coordinator open', ActivosOperadorController.getIntervencion(open.Id).puedeSeguir);
            canFollow.put('coordinator closed', ActivosOperadorController.getIntervencion(closed.Id).puedeSeguir);
            canFollow.put('coordinator without asset', ActivosOperadorController.getIntervencion(withoutAsset.Id).puedeSeguir);
        }
        System.runAs(operator) {
            holdsTheKey.put('operator', FeatureManagement.checkPermission(IntervencionOperadorController.PERM_SEGUIR));
            canFollow.put('operator open', ActivosOperadorController.getIntervencion(open.Id).puedeSeguir);
        }
        System.runAs(gerente) {
            holdsTheKey.put('gerente', FeatureManagement.checkPermission(IntervencionOperadorController.PERM_SEGUIR));
            canFollow.put('gerente open', ActivosOperadorController.getIntervencion(open.Id).puedeSeguir);
        }

        // Then only the coordinator, who holds Nova_Casa_Seguir_Intervencion, may follow up, and only an open Case with asset
        Assert.isTrue(holdsTheKey.get('coordinator'), 'precondition: Nova_Casa_Coordinator holds the follow-up permission');
        Assert.isFalse(holdsTheKey.get('operator'), 'precondition: Nova_Casa_Operator does not hold the follow-up permission');
        Assert.isFalse(holdsTheKey.get('gerente'), 'precondition: Nova_Casa_Gerente does not hold the follow-up permission');
        Assert.isTrue(canFollow.get('coordinator open'));
        Assert.isFalse(canFollow.get('coordinator closed'), 'a closed Case cannot be followed up');
        Assert.isFalse(canFollow.get('coordinator without asset'), 'a Case without asset cannot be followed up');
        Assert.isFalse(canFollow.get('operator open'));
        Assert.isFalse(canFollow.get('gerente open'));
    }

    @isTest
    static void assetLevelIsTheHighestCurrentReadingAndUltimaCriticaIsOnlyFilledWhenTheCaseRecordsOne() {
        // Given four assets: an older critical next to a newer normal of another type, a critical replaced by a newer warning
        // of the same type, a reading without level, and no readings; a telemetry Case with its last critical on the first,
        // and Cases without it on the rest
        User operator = newUserWithPermissionSet('nc207lvlop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Nivel', operator.Id);
        Datetime now = baseTime();
        Asset critical = newAsset('AST-CASE-LVL-CRIT', building, 'WATER_PUMP');
        newReading(critical, 'TEMPERATURE', 'CELSIUS', 95, now.addMinutes(-30), 2);
        newReading(critical, 'WATER_PRESSURE', 'BAR', 3, now, 0);
        Asset replaced = newAsset('AST-CASE-LVL-REPL', building, 'WATER_PUMP');
        newReading(replaced, 'TEMPERATURE', 'CELSIUS', 95, now.addMinutes(-30), 2);
        newReading(replaced, 'TEMPERATURE', 'CELSIUS', 60, now, 1);
        Asset noLevel = newAsset('AST-CASE-LVL-NULL', building, 'WATER_PUMP');
        newReading(noLevel, 'TEMPERATURE', 'CELSIUS', 20, now, null);
        Asset silent = newAsset('AST-CASE-LVL-NONE', building, 'WATER_PUMP');
        Case telemetry = caseDraft(critical, operator.Id, 'En curso', 'Señal crítica nivel');
        telemetry.Origin = 'Telemetria';
        telemetry.Ultima_Critica_Medicion__c = 'TEMPERATURE';
        telemetry.Ultima_Critica_Valor__c = 95.5;
        telemetry.Ultima_Critica_Unidad__c = 'CELSIUS';
        telemetry.Ultima_Critica_At__c = now.addMinutes(-30);
        Case manual = caseDraft(replaced, operator.Id, 'En curso', 'Manual');
        manual.Origin = 'Operador';
        Case onNoLevel = caseDraft(noLevel, operator.Id, 'En curso', 'Sin nivel');
        Case onSilent = caseDraft(silent, operator.Id, 'En curso', 'Sin lecturas');
        insert new List<Case>{ telemetry, manual, onNoLevel, onSilent };

        // When the operator opens each Case
        ActivosOperadorController.IntervencionDetalle forCritical = intervention(operator, telemetry.Id);
        ActivosOperadorController.IntervencionDetalle forReplaced = intervention(operator, manual.Id);
        ActivosOperadorController.IntervencionDetalle forNoLevel = intervention(operator, onNoLevel.Id);
        ActivosOperadorController.IntervencionDetalle forSilent = intervention(operator, onSilent.Id);

        // Then the level is the highest of the latest reading per type, null without a level, and the last critical is
        // returned only when the Case records one
        Assert.areEqual(2, forCritical.assetLevel, 'a newer normal of another type does not hide the critical');
        Assert.areEqual(1, forReplaced.assetLevel, 'a critical replaced by a newer warning of the same type is no longer current');
        Assert.isNull(forNoLevel.assetLevel, 'a reading without level is never counted as normal');
        Assert.isNull(forSilent.assetLevel, 'no readings means no level');
        Assert.isNotNull(forCritical.ultimaCritica);
        Assert.areEqual('TEMPERATURE', forCritical.ultimaCritica.measurementType);
        Assert.areEqual(95.5, forCritical.ultimaCritica.value);
        Assert.areEqual('CELSIUS', forCritical.ultimaCritica.unit);
        Assert.areEqual(now.addMinutes(-30), forCritical.ultimaCritica.occurredAt);
        Assert.isTrue(forCritical.esTelemetria);
        Assert.isNull(forReplaced.ultimaCritica, 'a Case without Ultima_Critica_* has no last critical');
        Assert.isFalse(forReplaced.esTelemetria);
        Assert.isNull(forSilent.ultimaCritica);
    }

    @isTest
    static void estadosMatchTheFollowUpStatusesInOrderEvenForTheGerente() {
        // Given a Gerente above the building and an open Case
        User operator = newUserWithPermissionSet('nc207estop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User gerente = newUserWithPermissionSet('nc207estger', 'Nova_Casa_Gerente', GERENTE_ROLE);
        Account building = newAccount('Edificio Estados', operator.Id);
        Asset asset = newAsset('AST-CASE-ESTADOS', building, 'WATER_PUMP');
        Case c = caseDraft(asset, operator.Id, 'En curso', 'Estados');
        insert c;

        // When the Gerente opens it, and the follow-up form's list is read
        List<IntervencionOperadorController.EstadoOpcion> expected;
        ActivosOperadorController.IntervencionDetalle detalle;
        System.runAs(gerente) {
            expected = IntervencionOperadorController.getEstadosSeguimiento();
            detalle = ActivosOperadorController.getIntervencion(c.Id);
        }

        // Then the detail offers the same statuses, value and label, in the same order
        Assert.isFalse(expected.isEmpty(), 'precondition: Case.Status has active values');
        Assert.areEqual(expected.size(), detalle.estados.size(), 'one option per follow-up status');
        for (Integer i = 0; i < expected.size(); i++) {
            Assert.areEqual(expected[i].value, detalle.estados[i].value, 'same value at position ' + i);
            Assert.areEqual(expected[i].label, detalle.estados[i].label, 'same label at position ' + i);
        }
        Assert.areEqual('En curso', detalle.status);
    }

    @isTest
    static void everyShippedScreenPermissionSetGrantsReadOnlyAccessToCaseOriginAndPriority() {
        // Given the four shipped permission sets of the screen
        List<String> shipped = new List<String>{ 'Nova_Casa_Operator', 'Nova_Casa_Coordinator', 'Nova_Casa_Gerente', 'Nova_Casa_Admin' };
        List<String> fields = new List<String>{ 'Case.Origin', 'Case.Priority' };
        Map<Id, PermissionSet> sets = new Map<Id, PermissionSet>([SELECT Id, Name FROM PermissionSet WHERE Name IN :shipped]);
        Assert.areEqual(4, sets.size(), 'all four shipped permission sets must be deployed to the org');

        // When their field permissions on Case.Origin and Case.Priority are read
        List<FieldPermissions> fieldPerms = [
            SELECT ParentId, Field, PermissionsRead, PermissionsEdit
            FROM FieldPermissions
            WHERE SobjectType = 'Case' AND Field IN :fields AND ParentId IN :sets.keySet()
        ];
        Map<String, FieldPermissions> bySetAndField = new Map<String, FieldPermissions>();
        for (FieldPermissions fieldPerm : fieldPerms) {
            bySetAndField.put(sets.get(fieldPerm.ParentId).Name + ' ' + fieldPerm.Field, fieldPerm);
        }

        // Then every set reads both fields and edits neither (getIntervencion reads them WITH USER_MODE)
        for (String setName : shipped) {
            for (String field : fields) {
                FieldPermissions fieldPerm = bySetAndField.get(setName + ' ' + field);
                Assert.isNotNull(fieldPerm, setName + ' must have a field permission on ' + field);
                Assert.isTrue(fieldPerm.PermissionsRead, setName + ' must grant read on ' + field);
                Assert.isFalse(fieldPerm.PermissionsEdit, setName + ' must not grant edit on ' + field);
            }
        }
        Assert.areEqual(8, fieldPerms.size(), 'expected exactly one field permission per shipped set and field');
    }

    @isTest
    static void lecturaActualIsTheMostSevereLatestReadingThenTheMostRecentAndNullWithoutReadings() {
        // Given four assets: an older critical next to a newer normal of another type, two criticals of different types at
        // different times, no readings, and more readings than the cap of one asset
        User operator = newUserWithPermissionSet('nc207curop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Lectura Actual', operator.Id);
        Datetime now = baseTime();
        Asset critical = newAsset('AST-CASE-CUR-CRIT', building, 'WATER_PUMP');
        newReading(critical, 'TEMPERATURE', 'CELSIUS', 95.5, now.addMinutes(-30), 2);
        newReading(critical, 'WATER_PRESSURE', 'BAR', 3.5, now, 0);
        Asset twoCriticals = newAsset('AST-CASE-CUR-TIE', building, 'WATER_PUMP');
        newReading(twoCriticals, 'TEMPERATURE', 'CELSIUS', 96.5, now.addMinutes(-20), 2);
        newReading(twoCriticals, 'WATER_PRESSURE', 'BAR', 9.5, now.addMinutes(-5), 2);
        Asset silent = newAsset('AST-CASE-CUR-NONE', building, 'WATER_PUMP');
        Asset overCap = newAsset('AST-CASE-CUR-CAP', building, 'WATER_PUMP');
        for (Integer i = 0; i < 6; i++) {
            newReading(overCap, 'TEMPERATURE', 'CELSIUS', 20 + i, now.addMinutes(-i), 0);
        }
        Case onCritical = caseDraft(critical, operator.Id, 'En curso', 'Actual crítica');
        Case onTwoCriticals = caseDraft(twoCriticals, operator.Id, 'En curso', 'Actual empate');
        Case onSilent = caseDraft(silent, operator.Id, 'En curso', 'Actual sin lecturas');
        Case onOverCap = caseDraft(overCap, operator.Id, 'En curso', 'Actual tope');
        insert new List<Case>{ onCritical, onTwoCriticals, onSilent, onOverCap };

        // When the operator opens each Case
        ActivosOperadorController.IntervencionDetalle forCritical = intervention(operator, onCritical.Id);
        ActivosOperadorController.IntervencionDetalle forTwoCriticals = intervention(operator, onTwoCriticals.Id);
        ActivosOperadorController.IntervencionDetalle forSilent = intervention(operator, onSilent.Id);
        ActivosOperadorController.IntervencionDetalle forOverCap = intervention(operator, onOverCap.Id);

        // Then the current reading is the critical one even though a normal of another type is newer
        ActivosOperadorController.EstadoLectura current = forCritical.lecturaActual;
        Assert.isNotNull(current, 'an asset with readings has a current reading');
        Assert.areEqual('TEMPERATURE', current.measurementType, 'a newer normal of another type does not replace the critical');
        Assert.areEqual(95.5, current.value);
        Assert.areEqual('CELSIUS', current.unit);
        Assert.areEqual(now.addMinutes(-30), current.occurredAt);
        Assert.areEqual(2, current.severityLevel);
        Assert.isFalse(forCritical.lecturasIncompletas);
        // among equally severe readings the most recent wins
        Assert.areEqual('WATER_PRESSURE', forTwoCriticals.lecturaActual.measurementType, 'same level: the most recent wins');
        Assert.areEqual(9.5, forTwoCriticals.lecturaActual.value);
        Assert.areEqual(now.addMinutes(-5), forTwoCriticals.lecturaActual.occurredAt);
        // no readings means no current reading, and the cap is flagged only when it cuts
        Assert.isNull(forSilent.lecturaActual, 'no readings means no current reading');
        Assert.isFalse(forSilent.lecturasIncompletas);
        Assert.isTrue(forOverCap.lecturasIncompletas, 'more readings than the cap must be flagged as incomplete');
    }

    @isTest
    static void recibeCriticasIsTrueOnlyForTheNewestOpenTelemetryCaseOfTheAsset() {
        // Given one asset with two open telemetry Cases (the one that wins the Id tie-break is made the older), plus a closed
        // telemetry Case, an open manual Case and an open Web Case that still carries a signal identity, all created later
        User operator = newUserWithPermissionSet('nc207recop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Recibe', operator.Id);
        Asset asset = newAsset('AST-CASE-RECIBE', building, 'WATER_PUMP');
        Case first = caseDraft(asset, operator.Id, 'En curso', 'Telemetría uno');
        first.Origin = 'Telemetria';
        Case second = caseDraft(asset, operator.Id, 'En curso', 'Telemetría dos');
        second.Origin = 'Telemetria';
        Case closed = caseDraft(asset, operator.Id, 'Closed', 'Telemetría cerrada');
        closed.Origin = 'Telemetria';
        Case manual = caseDraft(asset, operator.Id, 'En curso', 'Manual');
        manual.Origin = 'Operador';
        Case web = caseDraft(asset, operator.Id, 'En curso', 'Web con identidad');
        web.Identidad_Senal__c = 'test-src|legacy-web';
        insert new List<Case>{ first, second, closed, manual, web };
        Id winsOnId = [SELECT Id FROM Case WHERE Id IN :new Set<Id>{ first.Id, second.Id } ORDER BY Id DESC LIMIT 1].Id;
        Case newest = winsOnId == first.Id ? second : first;
        Case older = winsOnId == first.Id ? first : second;
        // Test.setCreatedDate is only allowed before Test.startTest().
        Test.setCreatedDate(newest.Id, Datetime.now().addDays(-1));
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-2));

        // When the operator opens each Case
        Map<Id, ActivosOperadorController.IntervencionDetalle> details = new Map<Id, ActivosOperadorController.IntervencionDetalle>();
        Test.startTest();
        System.runAs(operator) {
            for (Case c : new List<Case>{ newest, older, closed, manual, web }) {
                details.put(c.Id, ActivosOperadorController.getIntervencion(c.Id));
            }
        }
        Test.stopTest();

        // Then only the newest open telemetry Case receives criticals, decided by CreatedDate and not by Id, and the later
        // closed, manual and Web Cases neither receive them nor take the role away
        Map<Id, Case> stamped = new Map<Id, Case>([SELECT CreatedDate FROM Case WHERE Id IN :new Set<Id>{ newest.Id, older.Id }]);
        Assert.isTrue(stamped.get(newest.Id).CreatedDate > stamped.get(older.Id).CreatedDate, 'precondition: CreatedDate was set');
        Assert.isTrue(details.get(newest.Id).recibeCriticas, 'the newest open telemetry Case receives the criticals');
        Assert.isFalse(details.get(older.Id).recibeCriticas, 'an older open telemetry Case of the same asset does not');
        Assert.isFalse(details.get(closed.Id).recibeCriticas, 'a closed Case does not');
        Assert.isFalse(details.get(manual.Id).recibeCriticas, 'a manual Case does not');
        Assert.isFalse(details.get(web.Id).recibeCriticas, 'only Origin Telemetria counts');
        // and esTelemetria comes from Origin alone, not from a signal identity
        Assert.isTrue(details.get(newest.Id).esTelemetria);
        Assert.isTrue(details.get(older.Id).esTelemetria);
        Assert.isFalse(details.get(manual.Id).esTelemetria);
        Assert.isFalse(details.get(web.Id).esTelemetria, 'a signal identity without Origin Telemetria is not a telemetry Case');
    }

    @isTest
    static void signalsStayHiddenWhenTheUserSeesTheCaseButNotItsAsset() {
        // Given a building owned by the operator, and a Case on its asset owned by a stranger outside the role hierarchy
        // (no Case.AccountId, so no implicit access to the building), with two linked signals and a critical reading
        User operator = newUserWithPermissionSet('nc207gateop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User stranger = newUserWithPermissionSet('nc207gatestr', 'Nova_Casa_Operator', null);
        User admin = newUserWithPermissionSet('nc207gateadm', 'Nova_Casa_Admin', null);
        Account building = newAccount('Edificio Ajeno', operator.Id);
        Asset asset = newAsset('AST-CASE-GATE', building, 'WATER_PUMP');
        newReading(asset, 'TEMPERATURE', 'CELSIUS', 95, baseTime(), 2);
        Case c = caseDraft(asset, stranger.Id, 'En curso', 'Caso del extraño');
        c.Origin = 'Telemetria';
        insert c;
        insert new List<Log_Senial__c>{ linkedLog(asset, c.Id, baseTime()), linkedLog(asset, c.Id, baseTime().addMinutes(-1)) };

        // When the stranger and the admin open it
        Integer caseVisible;
        Integer assetVisible;
        ActivosOperadorController.IntervencionDetalle forStranger;
        ActivosOperadorController.SenalesIntervencion strangerSignals;
        System.runAs(stranger) {
            caseVisible = [SELECT COUNT() FROM Case WHERE Id = :c.Id WITH USER_MODE];
            assetVisible = [SELECT COUNT() FROM Asset WHERE Id = :asset.Id WITH USER_MODE];
            forStranger = ActivosOperadorController.getIntervencion(c.Id);
            strangerSignals = ActivosOperadorController.getSenalesDeIntervencion(c.Id, null);
        }
        ActivosOperadorController.IntervencionDetalle forAdmin = intervention(admin, c.Id);
        ActivosOperadorController.SenalesIntervencion adminSignals = interventionSignals(admin, c.Id, null);

        // Then the stranger gets the Case but neither its signals nor their count, while a user who sees the asset gets both
        Assert.areEqual(1, caseVisible, 'precondition: the stranger owns the Case, so it sees it');
        Assert.areEqual(0, assetVisible, 'precondition: the stranger must not see the asset, or this proves nothing');
        Assert.isTrue(strangerSignals.signals.isEmpty(), 'no signal of an asset the user cannot see');
        Assert.isFalse(strangerSignals.truncated);
        Assert.areEqual(0, forStranger.senalesEnlazadas, 'not even the number of linked signals');
        Assert.isNull(forStranger.assetLevel, 'the readings of a hidden asset stay hidden');
        Assert.isNull(forStranger.lecturaActual);
        Assert.isNull(forStranger.assetName, 'no name of an asset the user cannot see');
        Assert.isNull(forStranger.assetExternalId, 'no code of an asset the user cannot see');
        Assert.isNull(forStranger.accountName, 'no building of an asset the user cannot see');
        Assert.areEqual(2, adminSignals.signals.size(), 'a user who sees the asset gets the signals');
        Assert.areEqual(2, forAdmin.senalesEnlazadas);
        Assert.areEqual(2, forAdmin.assetLevel);
        Assert.areEqual('AST-CASE-GATE', forAdmin.assetExternalId, 'a user who sees the asset gets its code');
    }

    @isTest
    static void manualReasonShapedLikeAFollowUpIsNotReturnedAsOneButARealLineAfterTheMarkerIs() {
        // Given two manual Cases whose reason looks like a follow-up line; only the second has a real line after the marker
        User operator = newUserWithPermissionSet('nc207fakeop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        User coordinator = newUserWithPermissionSet('nc207fakecoord', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Account building = newAccount('Edificio Motivo Falso', operator.Id);
        Asset onlyReason = newAsset('AST-CASE-FAKE-1', building, 'WATER_PUMP');
        Asset withFollowUp = newAsset('AST-CASE-FAKE-2', building, 'WATER_PUMP');
        String reasonAndMarker = '[2026-10-19 10:02 Juan Diego] Revisado\n\nAbierta por: Operador X';
        Case bare = caseDraft(onlyReason, operator.Id, 'En curso', 'Manual sin seguimiento');
        bare.Origin = 'Operador';
        bare.Description = reasonAndMarker;
        Case followed = caseDraft(withFollowUp, operator.Id, 'En curso', 'Manual con seguimiento');
        followed.Origin = 'Operador';
        followed.Description = reasonAndMarker + '\n[2026-10-19 11:15 Coordinador Real] Visita hecha';
        insert new List<Case>{ bare, followed };

        // When the coordinator opens both
        ActivosOperadorController.IntervencionDetalle forBare = intervention(coordinator, bare.Id);
        ActivosOperadorController.IntervencionDetalle forFollowed = intervention(coordinator, followed.Id);

        // Then the reason never passes for a follow-up, and a real line after the marker does count
        Assert.isNull(forBare.ultimoSeguimiento, 'a reason shaped like a follow-up line is not a follow-up');
        Assert.areEqual('[2026-10-19 10:02 Juan Diego] Revisado', forBare.motivo, 'it is still the reason');
        Assert.isNotNull(forFollowed.ultimoSeguimiento, 'a real line after the marker is a follow-up');
        Assert.areEqual('2026-10-19 11:15', forFollowed.ultimoSeguimiento.fecha);
        Assert.areEqual('Coordinador Real', forFollowed.ultimoSeguimiento.autor);
        Assert.areEqual('Visita hecha', forFollowed.ultimoSeguimiento.texto);
        Assert.areEqual('[2026-10-19 10:02 Juan Diego] Revisado', forFollowed.motivo);
    }

    @isTest
    static void signalsWithTheSameOccurredAtComeSmallerMessageIdFirstNotByArrivalOrId() {
        // Given a Case with a newer row and two rows at the same instant; the one that wins on Id gets messageId msg_b
        User operator = newUserWithPermissionSet('nc207sigtieop', 'Nova_Casa_Operator', OPERATOR_ROLE);
        Account building = newAccount('Edificio Empate Senales', operator.Id);
        Asset asset = newAsset('AST-CASE-SIG-TIE', building, 'WATER_PUMP');
        Case c = caseDraft(asset, operator.Id, 'En curso', 'Empate de señales');
        insert c;
        Datetime at = baseTime();
        Log_Senial__c newer = linkedLog(asset, c.Id, at.addMinutes(1));
        newer.Message_Id__c = 'msg_z';
        newer.Identidad__c = 'test-src|msg_z';
        newer.Value__c = 30.5;
        Log_Senial__c one = linkedLog(asset, c.Id, at);
        Log_Senial__c two = linkedLog(asset, c.Id, at);
        insert new List<Log_Senial__c>{ newer, one, two };
        Id winsOnId = [SELECT Id FROM Log_Senial__c WHERE Id IN :new Set<Id>{ one.Id, two.Id } ORDER BY Id DESC LIMIT 1].Id;
        Id msgB = winsOnId;
        Id msgA = winsOnId == one.Id ? two.Id : one.Id;
        update new List<Log_Senial__c>{
            new Log_Senial__c(Id = msgA, Message_Id__c = 'msg_a', Identidad__c = 'test-src|msg_a',
                Measurement_Type__c = 'TEMPERATURE', Value__c = 10.5),
            new Log_Senial__c(Id = msgB, Message_Id__c = 'msg_b', Identidad__c = 'test-src|msg_b',
                Measurement_Type__c = 'WATER_PRESSURE', Value__c = 20.5)
        };

        // When the operator reads the signals
        ActivosOperadorController.SenalesIntervencion result = interventionSignals(operator, c.Id, null);

        // Then the newer row is first, and at the same instant msg_a comes before msg_b although msg_b wins on Id
        Assert.areEqual(3, result.signals.size());
        Assert.areEqual(30.5, result.signals[0].value, 'a later occurredAt always comes first');
        Assert.areEqual(at, result.signals[1].occurredAt);
        Assert.areEqual(at, result.signals[2].occurredAt);
        Assert.areEqual('TEMPERATURE', result.signals[1].measurementType, 'same instant: messageId msg_a comes first');
        Assert.areEqual(10.5, result.signals[1].value);
        Assert.areEqual('WATER_PRESSURE', result.signals[2].measurementType);
        Assert.areEqual(20.5, result.signals[2].value);
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

    // A fresh user (no role) with a throwaway permission set that mirrors NC207_Operator_Full (Read on the five objects the list
    // queries, read-only FLS on its fields) minus Case.ClosedDate. Call before inserting data rows in the test.
    private static User newUserWithEverythingButClosedDate() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet ps = newPermissionSet('NC207_Operator_NoClosedDate');
            insert ps;
            List<ObjectPermissions> objectPerms = new List<ObjectPermissions>();
            for (String obj : new List<String>{ 'Asset', 'Account', 'Contact', 'Case', 'Lectura_Vigente__c' }) {
                objectPerms.add(new ObjectPermissions(ParentId = ps.Id, SobjectType = obj, PermissionsRead = true));
            }
            insert objectPerms;
            List<FieldPermissions> fieldPerms = new List<FieldPermissions>();
            for (String f : new List<String>{
                'Asset.AccountId', 'Asset.Tipo_Activo__c', 'Asset.External_Id__c',
                'Case.AssetId', 'Case.Subject',
                'Lectura_Vigente__c.Severidad_Nivel__c', 'Lectura_Vigente__c.Sensor_Id__c'
            }) {
                fieldPerms.add(new FieldPermissions(ParentId = ps.Id, SobjectType = f.substringBefore('.'),
                    Field = f, PermissionsRead = true, PermissionsEdit = false));
            }
            insert fieldPerms;
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            u = newUser(p.Id, 'nc207noclosed', String.valueOf(Crypto.getRandomInteger()).replace('-', 'n'));
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    // A fresh user (no role) with Read on the objects the intervention page queries and read-only FLS on every field
    // getIntervencion and getSenalesDeIntervencion select, except `missingField` (null keeps them all). Call before
    // inserting data rows in the test.
    private static User newUserWithCaseReadExcept(String prefix, String missingField) {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            PermissionSet ps = newPermissionSet('NC207_Case_' + prefix);
            insert ps;
            List<ObjectPermissions> objectPerms = new List<ObjectPermissions>();
            for (String obj : new List<String>{ 'Asset', 'Account', 'Contact', 'Case', 'Lectura_Vigente__c' }) {
                objectPerms.add(new ObjectPermissions(ParentId = ps.Id, SobjectType = obj, PermissionsRead = true));
            }
            insert objectPerms;
            Set<String> fields = new Set<String>{
                'Asset.AccountId', 'Asset.Tipo_Activo__c', 'Asset.External_Id__c',
                'Case.AssetId', 'Case.Subject', 'Case.ClosedDate', 'Case.Origin', 'Case.Priority', 'Case.Tiempo_Abierto_Horas__c',
                'Case.Identidad_Senal__c', 'Case.Ultima_Critica_Medicion__c', 'Case.Ultima_Critica_Valor__c',
                'Case.Ultima_Critica_Unidad__c', 'Case.Ultima_Critica_At__c',
                'Lectura_Vigente__c.Severidad_Nivel__c', 'Lectura_Vigente__c.Sensor_Id__c'
            };
            fields.remove(missingField);
            List<FieldPermissions> fieldPerms = new List<FieldPermissions>();
            for (String f : fields) {
                fieldPerms.add(new FieldPermissions(ParentId = ps.Id, SobjectType = f.substringBefore('.'),
                    Field = f, PermissionsRead = true, PermissionsEdit = false));
            }
            insert fieldPerms;
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            u = newUser(p.Id, prefix, String.valueOf(Crypto.getRandomInteger()).replace('-', 'n'));
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        }
        return u;
    }

    // Names of the Apex classes a shipped permission set (by Name) grants access to.
    private static Set<String> apexClassesOf(String permissionSetName) {
        List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName];
        Assert.areEqual(1, sets.size(), permissionSetName + ' must be deployed to the org');
        Set<Id> classIds = new Set<Id>();
        for (SetupEntityAccess entityAccess : [
            SELECT SetupEntityId FROM SetupEntityAccess WHERE ParentId = :sets[0].Id AND SetupEntityType = 'ApexClass'
        ]) {
            classIds.add(entityAccess.SetupEntityId);
        }
        Set<String> names = new Set<String>();
        for (ApexClass cls : [SELECT Name FROM ApexClass WHERE Id IN :classIds]) {
            names.add(cls.Name);
        }
        return names;
    }

    private static ActivosOperadorController.IntervencionDetalle intervention(User runAs, Id caseId) {
        ActivosOperadorController.IntervencionDetalle result;
        System.runAs(runAs) {
            result = ActivosOperadorController.getIntervencion(caseId);
        }
        return result;
    }

    private static ActivosOperadorController.SenalesIntervencion interventionSignals(User runAs, Id caseId, Integer limite) {
        ActivosOperadorController.SenalesIntervencion result;
        System.runAs(runAs) {
            result = ActivosOperadorController.getSenalesDeIntervencion(caseId, limite);
        }
        return result;
    }

    // Both record-page methods for one Id: each entry is the error message, or 'returned: ' + the payload when it succeeded.
    private static List<String> bothOutcomes(User runAs, Id caseId) {
        List<String> outcomes = new List<String>();
        System.runAs(runAs) {
            try {
                outcomes.add('returned: ' + JSON.serialize(ActivosOperadorController.getIntervencion(caseId)));
            } catch (AuraHandledException e) {
                outcomes.add(e.getMessage());
            }
            try {
                outcomes.add('returned: ' + JSON.serialize(ActivosOperadorController.getSenalesDeIntervencion(caseId, null)));
            } catch (AuraHandledException e) {
                outcomes.add(e.getMessage());
            }
        }
        return outcomes;
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

    private static Log_Senial__c newLogWithValue(Asset asset, Datetime at, String measurementType, String unit, Decimal value) {
        Log_Senial__c l = logRow(asset, 'MEASUREMENT', 'Procesada', at, null, null);
        l.Measurement_Type__c = measurementType;
        l.Unit__c = unit;
        l.Value__c = value;
        insert l;
        return l;
    }

    // A processed measurement linked to a Case (caseId may be null), with its unique source|messageId identity. Not inserted.
    private static Log_Senial__c linkedLog(Asset asset, Id caseId, Datetime at) {
        Log_Senial__c l = logRow(asset, 'MEASUREMENT', 'Procesada', at, null, null);
        l.Caso__c = caseId;
        l.Identidad__c = l.Source__c + '|' + l.Message_Id__c;
        l.Measurement_Type__c = 'TEMPERATURE';
        l.Unit__c = 'CELSIUS';
        l.Value__c = 95.5;
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

    // A Case that is not inserted yet, for tests that need several in one DML statement or a chosen owner.
    private static Case caseDraft(Asset asset, Id ownerId, String status, String subject) {
        return new Case(AssetId = asset.Id, OwnerId = ownerId, Status = status, Subject = subject, Origin = 'Web');
    }

    // Closing is what makes the platform stamp Case.ClosedDate (with the time of that DML statement).
    private static void closeCase(Case c) {
        update new Case(Id = c.Id, Status = 'Closed');
    }

    // Apex has no sleep: spin until the clock has moved on, so two closings get different ClosedDate values.
    private static void letOneSecondPass() {
        Long deadline = System.currentTimeMillis() + 1100;
        while (System.currentTimeMillis() < deadline) {
            // busy wait on purpose
        }
    }

    // Re-reads the system-stamped fields that the insert result does not carry (CaseNumber is auto-number).
    private static Case reloaded(Case c) {
        return [SELECT Id, CaseNumber, ClosedDate FROM Case WHERE Id = :c.Id];
    }

    // Same as loadResult, also recording how many SOQL queries getAssets itself consumed (setup queries are not counted).
    private static ActivosOperadorController.AssetPage loadCountingQueries(User runAs, List<Integer> queriesUsed) {
        ActivosOperadorController.AssetPage result;
        System.runAs(runAs) {
            Integer before = Limits.getQueries();
            result = ActivosOperadorController.getAssets(null, null, null);
            queriesUsed.add(Limits.getQueries() - before);
        }
        return result;
    }
}
