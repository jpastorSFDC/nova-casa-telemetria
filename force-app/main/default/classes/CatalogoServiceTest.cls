/**
 * Test class for CatalogoService.
 * Mocks GET /catalog with HttpCalloutMock -- never calls the simulator.
 */
@isTest
private class CatalogoServiceTest {

    private static final String ONE_BUILDING_CATALOG_JSON =
        '{"catalog":{"buildings":[' +
            '{"id":"BLD-TEST-001","name":"Edificio Test","city":"Bogotá","assets":[' +
                '{"id":"AST-TEST-001","name":"Sala tecnica test","type":"TECHNICAL_ROOM","sensorId":"SNS-TEST-001","measurement":"TEMPERATURE","unit":"CELSIUS"}' +
            ']}' +
        ']}}';

    private static final String RENAMED_BUILDING_CATALOG_JSON =
        '{"catalog":{"buildings":[' +
            '{"id":"BLD-TEST-001","name":"Edificio Test Renombrado","city":"Bogotá","assets":[' +
                '{"id":"AST-TEST-001","name":"Sala tecnica test","type":"TECHNICAL_ROOM","sensorId":"SNS-TEST-001","measurement":"TEMPERATURE","unit":"CELSIUS"}' +
            ']}' +
        ']}}';

    private static final String NO_CITY_CATALOG_JSON =
        '{"catalog":{"buildings":[' +
            '{"id":"BLD-TEST-001","name":"Edificio Test","assets":[]}' +
        ']}}';

    private static final String ALL_TYPES_CATALOG_JSON =
        '{"catalog":{"buildings":[' +
            '{"id":"BLD-TEST-001","name":"Edificio Test","city":"Bogotá","assets":[' +
                '{"id":"AST-TEST-001","name":"Sala tecnica test","type":"TECHNICAL_ROOM","sensorId":"S1","measurement":"TEMPERATURE","unit":"CELSIUS"},' +
                '{"id":"AST-TEST-002","name":"Bomba test","type":"WATER_PUMP","sensorId":"S2","measurement":"WATER_PRESSURE","unit":"BAR"},' +
                '{"id":"AST-TEST-003","name":"Medidor agua test","type":"WATER_METER","sensorId":"S3","measurement":"WATER_CONSUMPTION","unit":"LITER_PER_15_MIN"},' +
                '{"id":"AST-TEST-004","name":"Medidor energia test","type":"ENERGY_METER","sensorId":"S4","measurement":"ENERGY_CONSUMPTION","unit":"KWH_PER_15_MIN"},' +
                '{"id":"AST-TEST-005","name":"Camara test","type":"SECURITY_CAMERA","sensorId":"S5","measurement":"CAMERA_CONNECTIVITY","unit":"SECONDS"},' +
                '{"id":"AST-TEST-006","name":"Sala tecnica test 2","type":"TECHNICAL_ROOM","sensorId":"S6","measurement":"TEMPERATURE","unit":"CELSIUS"}' +
            ']}' +
        ']}}';

    private static final String NO_BUILDINGS_CATALOG_JSON = '{"catalog":{"buildings":[]}}';

    // ─── Test Setup ───────────────────────────────────────────────────────

    /**
     * Creates the restricted-permission user once for shouldThrowException_WhenRunningAsUserWithoutCatalogAccess.
     * The test re-queries it by Username pattern because static state set in @testSetup does not
     * carry over into a test method's execution context.
     */
    @testSetup
    static void setup() {
        Profile minimumAccessProfile = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User restrictedUser = new User(
            FirstName = 'Restricted',
            LastName = 'CatalogUser',
            Alias = 'rcatlg',
            Email = 'restricted.catalog.test@novacasatelemetria.invalid',
            Username = 'restricted.catalog.test' + DateTime.now().getTime() + '@novacasatelemetria.invalid',
            ProfileId = minimumAccessProfile.Id,
            TimeZoneSidKey = 'America/Bogota',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert restrictedUser;
        // Deliberately not assigning the Nova_Casa_Admin permission set: this user has
        // no CRUD/FLS on Account/Asset, so USER_MODE should block the upsert.

        // Second user: can write Account/Asset but has no access to Umbral__c, so only the seed fails.
        PermissionSet catalogNoUmbral = new PermissionSet(Name = 'Catalog_Test_No_Umbral', Label = 'Catalog Test No Umbral');
        insert catalogNoUmbral;
        List<ObjectPermissions> objectPerms = new List<ObjectPermissions>();
        for (String objectName : new List<String>{'Account', 'Asset'}) {
            objectPerms.add(new ObjectPermissions(
                ParentId = catalogNoUmbral.Id, SobjectType = objectName,
                PermissionsCreate = true, PermissionsRead = true, PermissionsEdit = true
            ));
        }
        // Read Account/Asset depend on Read Contact (FIELD_INTEGRITY_EXCEPTION otherwise).
        objectPerms.add(new ObjectPermissions(
            ParentId = catalogNoUmbral.Id, SobjectType = 'Contact', PermissionsRead = true
        ));
        insert objectPerms;
        List<FieldPermissions> fieldPerms = new List<FieldPermissions>();
        for (String fieldName : new List<String>{'Account.External_Id__c', 'Asset.External_Id__c', 'Asset.Tipo_Activo__c', 'Asset.AccountId'}) {
            fieldPerms.add(new FieldPermissions(
                ParentId = catalogNoUmbral.Id, SobjectType = fieldName.substringBefore('.'),
                Field = fieldName, PermissionsRead = true, PermissionsEdit = true
            ));
        }
        insert fieldPerms;
        User noUmbralUser = new User(
            FirstName = 'NoUmbral',
            LastName = 'CatalogUser',
            Alias = 'nounbr',
            Email = 'nothresholds.catalog.test@novacasatelemetria.invalid',
            Username = 'nothresholds.catalog.test' + DateTime.now().getTime() + '@novacasatelemetria.invalid',
            ProfileId = minimumAccessProfile.Id,
            TimeZoneSidKey = 'America/Bogota',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert noUmbralUser;
        insert new PermissionSetAssignment(AssigneeId = noUmbralUser.Id, PermissionSetId = catalogNoUmbral.Id);
    }

    // ─── Positive Tests ───────────────────────────────────────────────────

    @isTest
    static void shouldUpsertBuildingAndAsset_WhenCatalogIsValid() {
        // Given
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON));

        // When
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then
        Account building = [SELECT Id, Name, External_Id__c, BillingCity FROM Account WHERE External_Id__c = 'BLD-TEST-001'];
        Asset asset = [SELECT Id, Name, External_Id__c, Tipo_Activo__c, AccountId FROM Asset WHERE External_Id__c = 'AST-TEST-001'];

        Assert.areEqual('Edificio Test', building.Name, 'Building Name should come from the catalog');
        Assert.areEqual('Bogotá', building.BillingCity, 'Building BillingCity should come from the catalog city');
        Assert.areEqual('Sala tecnica test', asset.Name, 'Asset Name should come from the catalog');
        Assert.areEqual('TECHNICAL_ROOM', asset.Tipo_Activo__c, 'Asset type should come from the catalog');
        Assert.areEqual(building.Id, asset.AccountId, 'Asset should be linked to its building');
    }

    @isTest
    static void shouldNotDuplicateRecords_WhenLoadedTwice() {
        // Given: seed the state as if a first loadCatalog() already ran (same External_Id__c
        // values and fields as ONE_BUILDING_CATALOG_JSON would upsert). A real second call to
        // loadCatalog() can't be made in this same test method -- Apex forbids a callout after
        // uncommitted DML in one transaction, and test methods never commit mid-method -- so this
        // seeds the "already loaded" state directly instead.
        Account existingBuilding = new Account(
            External_Id__c = 'BLD-TEST-001',
            Name = 'Edificio Test',
            BillingCity = 'Bogotá'
        );
        insert existingBuilding;
        Asset existingAsset = new Asset(
            External_Id__c = 'AST-TEST-001',
            Name = 'Sala tecnica test',
            Tipo_Activo__c = 'TECHNICAL_ROOM',
            AccountId = existingBuilding.Id
        );
        insert existingAsset;

        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON));

        // When: reload the same catalog once more
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE External_Id__c = 'BLD-TEST-001'],
            'A reload should not create a second building');
        Assert.areEqual(1, [SELECT COUNT() FROM Asset WHERE External_Id__c = 'AST-TEST-001'],
            'A reload should not create a second asset');

        Account reloadedBuilding = [SELECT Id, BillingCity FROM Account WHERE External_Id__c = 'BLD-TEST-001'];
        Asset reloadedAsset = [SELECT Id FROM Asset WHERE External_Id__c = 'AST-TEST-001'];
        Assert.areEqual(existingBuilding.Id, reloadedBuilding.Id,
            'A reload should update the existing building in place, not delete and recreate it');
        Assert.areEqual(existingAsset.Id, reloadedAsset.Id,
            'A reload should update the existing asset in place, not delete and recreate it');
        Assert.areEqual('Bogotá', reloadedBuilding.BillingCity, 'A reload should leave BillingCity unchanged');
    }

    @isTest
    static void shouldKeepExistingCity_WhenCatalogHasNoCity() {
        // Given: a building that already has a city, and a catalog entry without one
        insert new Account(External_Id__c = 'BLD-TEST-001', Name = 'Edificio Test', BillingCity = 'Bogotá');
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, NO_CITY_CATALOG_JSON));

        // When
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then
        Account building = [SELECT BillingCity FROM Account WHERE External_Id__c = 'BLD-TEST-001'];
        Assert.areEqual('Bogotá', building.BillingCity, 'A missing city must not blank the existing BillingCity');
    }

    @isTest
    static void shouldUpdateBuilding_WhenNameChangesOnReload() {
        // Given: seed the state as if a first loadCatalog() already ran (a second real call
        // would hit "uncommitted work pending" -- callout after DML in one transaction).
        insert new Account(External_Id__c = 'BLD-TEST-001', Name = 'Edificio Test');
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, RENAMED_BUILDING_CATALOG_JSON));

        // When
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then
        Account building = [SELECT Id, Name FROM Account WHERE External_Id__c = 'BLD-TEST-001'];
        Assert.areEqual('Edificio Test Renombrado', building.Name, 'A reload should update the existing building, not create a new one');
    }

    @isTest
    static void shouldSeedOneThresholdSetPerCombination_WhenCatalogIsValid() {
        // Given: 5 asset types / measurements, with TEMPERATURE on two assets of the same type
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ALL_TYPES_CATALOG_JSON));

        // When
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then: 6 + 5 + 4 + 4 + 2 rules, and the duplicated TECHNICAL_ROOM asset adds none
        Assert.areEqual(21, [SELECT COUNT() FROM Umbral__c], 'One threshold per reference rule, once per combination');
        Assert.areEqual(6, [SELECT COUNT() FROM Umbral__c WHERE Tipo_Activo__c = 'TECHNICAL_ROOM' AND Tipo_Medicion__c = 'TEMPERATURE'],
            'Temperature should get its 6 rules once');
        Assert.areEqual(2, [SELECT COUNT() FROM Umbral__c WHERE Tipo_Activo__c = 'SECURITY_CAMERA' AND Tipo_Medicion__c = 'CAMERA_CONNECTIVITY'],
            'Camera connectivity should get its 2 rules');

        Umbral__c criticalHigh = [
            SELECT Operador__c, Valor__c, Unidad_Esperada__c, Activo__c
            FROM Umbral__c
            WHERE Tipo_Activo__c = 'TECHNICAL_ROOM' AND Severidad__c = 'Critica' AND Operador__c = 'GT'
        ];
        Assert.areEqual(35, criticalHigh.Valor__c, 'Critical high temperature limit should be 35');
        Assert.areEqual('CELSIUS', criticalHigh.Unidad_Esperada__c, 'Unit should come from the catalog');
        Assert.isTrue(criticalHigh.Activo__c, 'Seeded thresholds should be active');
    }

    @isTest
    static void shouldNotDuplicateThresholds_WhenLoadedTwice() {
        // Given: state after a first load (a second loadCatalog() can't follow DML in one test)
        List<Umbral__c> firstLoad = new List<Umbral__c>();
        for (String[] rule : new List<String[]>{
            new String[]{'Advertencia', 'LT', '18'}, new String[]{'Advertencia', 'GT', '30'},
            new String[]{'Critica', 'LT', '15'}, new String[]{'Critica', 'GT', '35'},
            new String[]{'Invalida', 'LE', '-11'}, new String[]{'Invalida', 'GE', '81'}
        }) {
            firstLoad.add(new Umbral__c(
                Tipo_Activo__c = 'TECHNICAL_ROOM', Tipo_Medicion__c = 'TEMPERATURE', Unidad_Esperada__c = 'CELSIUS',
                Severidad__c = rule[0], Operador__c = rule[1], Valor__c = Decimal.valueOf(rule[2])
            ));
        }
        insert firstLoad;
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON));

        // When
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then
        Assert.areEqual(6, [SELECT COUNT() FROM Umbral__c], 'A reload should not create any threshold again');
    }

    @isTest
    static void shouldKeepEditedThreshold_WhenCatalogIsReloaded() {
        // Given: a user raised a limit to 99 and deactivated it
        Umbral__c edited = new Umbral__c(
            Tipo_Activo__c = 'TECHNICAL_ROOM', Tipo_Medicion__c = 'TEMPERATURE', Unidad_Esperada__c = 'CELSIUS',
            Severidad__c = 'Advertencia', Operador__c = 'GT', Valor__c = 99, Activo__c = false
        );
        insert edited;
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON));

        // When
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then
        Assert.areEqual(1, [SELECT COUNT() FROM Umbral__c], 'A combination with user data should not be reseeded');
        Umbral__c kept = [SELECT Valor__c, Activo__c FROM Umbral__c WHERE Id = :edited.Id];
        Assert.areEqual(99, kept.Valor__c, 'The user-edited value should be preserved');
        Assert.isFalse(kept.Activo__c, 'The deactivated flag should be preserved');
    }

    @isTest
    static void shouldNotCompletePartialSet_WhenCatalogIsReloaded() {
        // Given: the combination already has a partial set (only one Advertencia row)
        Umbral__c partial = new Umbral__c(
            Tipo_Activo__c = 'TECHNICAL_ROOM', Tipo_Medicion__c = 'TEMPERATURE', Unidad_Esperada__c = 'CELSIUS',
            Severidad__c = 'Advertencia', Operador__c = 'GT', Valor__c = 30, Activo__c = true
        );
        insert partial;
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON));

        // When
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then: known limit, the partial set is left alone and not completed
        Assert.areEqual(1, [SELECT COUNT() FROM Umbral__c], 'A partial set should not be completed on reload');
        Assert.areEqual(partial.Id, [SELECT Id FROM Umbral__c LIMIT 1].Id, 'The existing row should be the only one');
    }

    // ─── Edge Case Tests ──────────────────────────────────────────────────

    @isTest
    static void shouldDoNothing_WhenCatalogHasNoBuildings() {
        // Given
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, NO_BUILDINGS_CATALOG_JSON));

        // When
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE External_Id__c != null],
            'An empty catalog should not create any building');
    }

    // ─── Negative Tests ───────────────────────────────────────────────────

    @isTest
    static void shouldThrowException_WhenCalloutReturnsErrorStatus() {
        // Given
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(500, '{"error":"simulator unavailable"}'));

        // When/Then
        Test.startTest();
        try {
            CatalogoService.loadCatalog();
            Assert.fail('Expected CatalogoServiceException for a non-200 response');
        } catch (CatalogoService.CatalogoServiceException e) {
            Assert.isTrue(e.getMessage().contains('500'), 'Exception message should mention the status code');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowException_WhenBodyIsNotValidJson() {
        // Given
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, 'not-json'));

        // When/Then
        Test.startTest();
        try {
            CatalogoService.loadCatalog();
            Assert.fail('Expected CatalogoServiceException for an unparsable body');
        } catch (CatalogoService.CatalogoServiceException e) {
            Assert.isTrue(e.getMessage().contains('unparsable'), 'Exception message should mention the unparsable body');
        }
        Test.stopTest();
    }

    // ─── Security Tests ───────────────────────────────────────────────────

    /**
     * Proves that upsertBuildings' USER_MODE Database.upsert actually enforces CRUD/FLS
     * for the running user. A user with no Nova_Casa_Admin permission set (and the
     * standard "Minimum Access - Salesforce" profile, which grants no object/field
     * access at all) must not be able to create the building Account. If USER_MODE
     * were ever reverted to SYSTEM_MODE (or "with sharing" dropped in a way that
     * stops enforcing CRUD/FLS), this DML would silently succeed and this test would fail.
     */
    @isTest
    static void shouldThrowException_WhenRunningAsUserWithoutCatalogAccess() {
        // Given: the restricted user comes from setup(); look it up by Username pattern.
        User restrictedUser = [
            SELECT Id
            FROM User
            WHERE Username LIKE 'restricted.catalog.test%@novacasatelemetria.invalid'
            LIMIT 1
        ];

        // No city: BillingCity is not grantable in a permission set, so this user would fail on Account first.
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON.remove('"city":"Bogotá",')));

        // When/Then
        System.runAs(restrictedUser) {
            Test.startTest();
            try {
                CatalogoService.loadCatalog();
                Assert.fail('Expected CatalogoServiceException: a user without Nova_Casa_Admin ' +
                    'should not be able to upsert building Accounts under USER_MODE');
            } catch (CatalogoService.CatalogoServiceException e) {
                Assert.isTrue(
                    e.getMessage().contains('Failed to upsert building Accounts'),
                    'Exception should surface the USER_MODE CRUD/FLS failure on Account, got: ' + e.getMessage()
                );
            }
            Test.stopTest();
        }

        // Then
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE External_Id__c = 'BLD-TEST-001'],
            'A restricted user must not be able to create the building Account under USER_MODE');
    }

    @isTest
    static void shouldThrowException_WhenRunningAsUserWithoutUmbralAccess() {
        // Given: a user who can write Account/Asset but has no Umbral__c access
        User noUmbralUser = [
            SELECT Id
            FROM User
            WHERE Username LIKE 'nothresholds.catalog.test%@novacasatelemetria.invalid'
            LIMIT 1
        ];
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON));

        // When/Then
        System.runAs(noUmbralUser) {
            Test.startTest();
            try {
                CatalogoService.loadCatalog();
                Assert.fail('Expected CatalogoServiceException: no access to Umbral__c');
            } catch (CatalogoService.CatalogoServiceException e) {
                Assert.isTrue(
                    e.getMessage().contains('Failed to seed Umbral__c'),
                    'Exception should surface the missing Umbral__c access, got: ' + e.getMessage()
                );
            }
            Test.stopTest();
        }

        // Then
        Assert.areEqual(0, [SELECT COUNT() FROM Umbral__c], 'No threshold should be created without access');
    }

    // ─── Mock ──────────────────────────────────────────────────────────────

    private class CatalogSimulatorMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;

        CatalogSimulatorMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            response.setBody(body);
            response.setHeader('Content-Type', 'application/json');
            return response;
        }
    }
}
