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
        // Given
        Test.setMock(HttpCalloutMock.class, new CatalogSimulatorMock(200, ONE_BUILDING_CATALOG_JSON));

        // When
        Test.startTest();
        CatalogoService.loadCatalog();
        CatalogoService.loadCatalog();
        Test.stopTest();

        // Then
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE External_Id__c = 'BLD-TEST-001'],
            'A second run should not create a second building');
        Assert.areEqual(1, [SELECT COUNT() FROM Asset WHERE External_Id__c = 'AST-TEST-001'],
            'A second run should not create a second asset');
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
