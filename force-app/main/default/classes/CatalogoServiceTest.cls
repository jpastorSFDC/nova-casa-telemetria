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

    private static final String NO_BUILDINGS_CATALOG_JSON = '{"catalog":{"buildings":[]}}';

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
        Account building = [SELECT Id, Name, External_Id__c FROM Account WHERE External_Id__c = 'BLD-TEST-001'];
        Asset asset = [SELECT Id, Name, External_Id__c, Tipo_Activo__c, AccountId FROM Asset WHERE External_Id__c = 'AST-TEST-001'];

        Assert.areEqual('Edificio Test', building.Name, 'Building Name should come from the catalog');
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
            Name = 'Edificio Test'
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

        Account reloadedBuilding = [SELECT Id FROM Account WHERE External_Id__c = 'BLD-TEST-001'];
        Asset reloadedAsset = [SELECT Id FROM Asset WHERE External_Id__c = 'AST-TEST-001'];
        Assert.areEqual(existingBuilding.Id, reloadedBuilding.Id,
            'A reload should update the existing building in place, not delete and recreate it');
        Assert.areEqual(existingAsset.Id, reloadedAsset.Id,
            'A reload should update the existing asset in place, not delete and recreate it');
    }

    @isTest
    static void shouldUpdateBuilding_WhenNameChangesOnReload() {
        // Given
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON));
        CatalogoService.loadCatalog();

        // When
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, RENAMED_BUILDING_CATALOG_JSON));
        Test.startTest();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then
        Account building = [SELECT Id, Name FROM Account WHERE External_Id__c = 'BLD-TEST-001'];
        Assert.areEqual('Edificio Test Renombrado', building.Name, 'A reload should update the existing building, not create a new one');
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
        // Given
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

        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON));

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
