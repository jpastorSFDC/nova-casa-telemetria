/**
 * Test class for IntervencionService.
 * Covers one Case per unique identity, resend idempotency, no consolidation, batch duplicates,
 * bulk (200), partial success and SYSTEM_MODE (ingestion does not depend on operator permissions).
 */
@isTest
private class IntervencionServiceTest {

    private static final String ID_PREFIX = 'SIM|msg-';

    // ─── Test Setup ───────────────────────────────────────────────────────

    @testSetup
    static void setup() {
        Account building = new Account(Name = 'Edificio Intervencion Test', External_Id__c = 'BLD-INT-001');
        insert building;
        insert new List<Asset>{
            new Asset(Name = 'Bomba test', AccountId = building.Id, External_Id__c = 'AST-INT-001', Tipo_Activo__c = 'WATER_PUMP'),
            new Asset(Name = 'Ventilacion test', AccountId = building.Id, External_Id__c = 'AST-INT-002', Tipo_Activo__c = 'VENTILATION')
        };

        Profile minimumAccessProfile = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        // No permission sets assigned: this user has no CRUD on Case.
        insert new User(
            FirstName = 'Restricted',
            LastName = 'InterventionUser',
            Alias = 'rintv',
            Email = 'restricted.intervencion.test@novacasatelemetria.invalid',
            Username = 'restricted.intervencion.test' + DateTime.now().getTime() + '@novacasatelemetria.invalid',
            ProfileId = minimumAccessProfile.Id,
            TimeZoneSidKey = 'America/Bogota',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    private static Asset asset(String externalId) {
        return [SELECT Id, AccountId FROM Asset WHERE External_Id__c = :externalId LIMIT 1];
    }

    private static IntervencionService.Solicitud solicitud(String identidad, Asset a, String tipo, String causa) {
        IntervencionService.Solicitud s = new IntervencionService.Solicitud();
        s.identidad = identidad;
        s.assetId = a == null ? null : a.Id;
        s.accountId = a == null ? null : a.AccountId;
        s.tipoMedicion = tipo;
        s.causa = causa;
        return s;
    }

    private static Integer caseCount() {
        return [SELECT COUNT() FROM Case];
    }

    // ─── Tests ────────────────────────────────────────────────────────────

    @isTest
    static void shouldCreateOneCaseWithExpectedFields_WhenSingleRequest() {
        Asset a = asset('AST-INT-001');
        String identity = 'SIM|msg-1';

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(
            new List<IntervencionService.Solicitud>{ solicitud(identity, a, 'WATER_PRESSURE', 'above critical threshold') });
        Test.stopTest();

        Assert.areEqual(1, caseCount(), 'Exactly one Case should exist');
        Assert.isTrue(r.errorPorIdentidad.isEmpty(), 'No errors expected');
        Assert.areEqual(1, r.casoPorIdentidad.size(), 'One identity mapped');
        Case c = [
            SELECT Id, Origin, Status, Priority, AssetId, AccountId, Identidad_Senal__c, Subject, Description
            FROM Case
        ];
        Assert.areEqual(c.Id, r.casoPorIdentidad.get(identity), 'Identity should map to the created Case');
        Assert.areEqual('Telemetria', c.Origin);
        Assert.areEqual('En curso', c.Status);
        Assert.areEqual('Critica', c.Priority);
        Assert.areEqual(a.Id, c.AssetId);
        Assert.areEqual(a.AccountId, c.AccountId);
        Assert.areEqual(identity, c.Identidad_Senal__c);
        Assert.areEqual('Critical signal: WATER_PRESSURE on asset ' + a.Id, c.Subject);
        Assert.areEqual('Signal ' + identity + ': above critical threshold', c.Description);
    }

    @isTest
    static void shouldReturnSameCaseWithoutModifyingIt_WhenSameIdentityIsResent() {
        Asset a = asset('AST-INT-001');
        String identity = 'SIM|msg-resend';
        IntervencionService.Resultado first = IntervencionService.abrir(
            new List<IntervencionService.Solicitud>{ solicitud(identity, a, 'WATER_PRESSURE', 'original cause') });
        Case before = [SELECT Id, Subject, Description, Status, Priority, AssetId FROM Case];

        Test.startTest();
        IntervencionService.Resultado second = IntervencionService.abrir(
            new List<IntervencionService.Solicitud>{ solicitud(identity, asset('AST-INT-002'), 'TEMPERATURE', 'different cause') });
        Test.stopTest();

        Assert.areEqual(1, caseCount(), 'Resend must not create a second Case');
        Assert.areEqual(first.casoPorIdentidad.get(identity), second.casoPorIdentidad.get(identity), 'Same Case Id returned');
        Assert.isTrue(second.errorPorIdentidad.isEmpty(), 'Resend is not an error');
        Case after = [SELECT Id, Subject, Description, Status, Priority, AssetId FROM Case];
        Assert.areEqual(before.Id, after.Id);
        Assert.areEqual(before.Subject, after.Subject, 'Subject must not change on resend');
        Assert.areEqual(before.Description, after.Description, 'Description must not change on resend');
        Assert.areEqual(before.AssetId, after.AssetId, 'Asset must not change on resend');
        Assert.areEqual(before.Status, after.Status);
        Assert.areEqual(before.Priority, after.Priority);
    }

    @isTest
    static void shouldCreateTwoCases_WhenDifferentIdentitiesShareAssetAndMeasurement() {
        Asset a = asset('AST-INT-001');

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            solicitud('SIM|msg-A', a, 'WATER_PRESSURE', 'c1'),
            solicitud('SIM|msg-B', a, 'WATER_PRESSURE', 'c2')
        });
        Test.stopTest();

        Assert.areEqual(2, caseCount(), 'One Case per unique critical message, no consolidation');
        Assert.areEqual(2, r.casoPorIdentidad.size());
        Assert.areNotEqual(r.casoPorIdentidad.get('SIM|msg-A'), r.casoPorIdentidad.get('SIM|msg-B'), 'Distinct Cases');
    }

    @isTest
    static void shouldCreateOneCaseAndKeepFirst_WhenIdentityDuplicatedInBatch() {
        Asset a = asset('AST-INT-001');

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            solicitud('SIM|msg-dup', a, 'WATER_PRESSURE', 'first wins'),
            solicitud('SIM|msg-dup', a, 'WATER_PRESSURE', 'second loses')
        });
        Test.stopTest();

        Assert.areEqual(1, caseCount());
        Assert.areEqual(1, r.casoPorIdentidad.size());
        Assert.isTrue(r.errorPorIdentidad.isEmpty());
        Case c = [SELECT Description FROM Case];
        Assert.areEqual('Signal SIM|msg-dup: first wins', c.Description, 'First request must win');
    }

    @isTest
    static void shouldCreate200Cases_WithinGovernorLimits_WhenBulk() {
        Asset a = asset('AST-INT-001');
        List<IntervencionService.Solicitud> requests = new List<IntervencionService.Solicitud>();
        for (Integer i = 0; i < 200; i++) {
            requests.add(solicitud(ID_PREFIX + 'bulk-' + i, a, 'WATER_PRESSURE', 'bulk ' + i));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        IntervencionService.Resultado r = IntervencionService.abrir(requests);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(200, r.casoPorIdentidad.size());
        Assert.isTrue(r.errorPorIdentidad.isEmpty());
        Assert.areEqual(200, caseCount());
        Assert.isTrue(queriesUsed <= 2, 'SOQL queries used: ' + queriesUsed);
        Assert.isTrue(dmlUsed <= 2, 'DML statements used: ' + dmlUsed);
    }

    @isTest
    static void shouldReportErrorsAndKeepValidRows_WhenIdentityOrAssetMissing() {
        Asset a = asset('AST-INT-001');

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            solicitud('SIM|msg-ok', a, 'WATER_PRESSURE', 'ok'),
            solicitud('   ', a, 'WATER_PRESSURE', 'blank identity'),
            solicitud(null, a, 'WATER_PRESSURE', 'null identity'),
            solicitud('SIM|msg-noasset', null, 'WATER_PRESSURE', 'no asset')
        });
        Test.stopTest();

        Assert.areEqual(1, caseCount(), 'Only the valid row creates a Case');
        Assert.areEqual(1, r.casoPorIdentidad.size());
        Assert.isTrue(r.casoPorIdentidad.containsKey('SIM|msg-ok'));
        Assert.areEqual('identidad is required', r.errorPorIdentidad.get('(blank identity #1)'), 'Blank identity keyed by position');
        Assert.areEqual('identidad is required', r.errorPorIdentidad.get('(blank identity #2)'), 'Null identity keyed by position');
        Assert.areEqual('assetId is required', r.errorPorIdentidad.get('SIM|msg-noasset'));
        Assert.areEqual(3, r.errorPorIdentidad.size());
        Assert.isFalse(r.casoPorIdentidad.containsKey('SIM|msg-noasset'));
    }

    @isTest
    static void shouldReportWhitespaceIdentityUnderOwnLabel_WhenOtherRowsAreValid() {
        Asset a = asset('AST-INT-001');

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            solicitud('  SIM|msg-trim  ', a, 'WATER_PRESSURE', 'padded identity'),
            solicitud(' \t ', a, 'WATER_PRESSURE', 'whitespace only')
        });
        Test.stopTest();

        Assert.areEqual(1, caseCount(), 'Only the valid row creates a Case');
        Assert.isTrue(r.casoPorIdentidad.containsKey('SIM|msg-trim'), 'Identity is trimmed before use');
        Assert.areEqual('identidad is required', r.errorPorIdentidad.get('(blank identity #1)'));
        Assert.areEqual(1, r.errorPorIdentidad.size());
        Assert.areEqual('SIM|msg-trim', [SELECT Identidad_Senal__c FROM Case].Identidad_Senal__c);
    }

    @isTest
    static void shouldCreateCaseWithCappedDescription_WhenCausaIsOversized() {
        Asset a = asset('AST-INT-001');

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            solicitud('SIM|msg-huge', a, 'WATER_PRESSURE', 'x'.repeat(40000))
        });
        Test.stopTest();

        Assert.isTrue(r.errorPorIdentidad.isEmpty(), 'Oversized causa must not make the insert fail');
        Assert.areEqual(1, caseCount());
        Case c = [SELECT Description FROM Case];
        Assert.isTrue(c.Description.length() <= 32000, 'Description length: ' + c.Description.length());
    }

    @isTest
    static void shouldReportError_WhenIdentityLongerThan60Chars() {
        Asset a = asset('AST-INT-001');
        String tooLong = 'SIM|' + 'x'.repeat(57); // 61 chars
        Assert.areEqual(61, tooLong.length());

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            solicitud('SIM|msg-fine', a, 'WATER_PRESSURE', 'ok'),
            solicitud(tooLong, a, 'WATER_PRESSURE', 'too long')
        });
        Test.stopTest();

        Assert.areEqual(1, caseCount(), 'Only the valid row creates a Case');
        Assert.isTrue(r.casoPorIdentidad.containsKey('SIM|msg-fine'));
        Assert.isTrue(r.errorPorIdentidad.containsKey(tooLong), 'Over-length identity should be reported');
        Assert.isFalse(String.isBlank(r.errorPorIdentidad.get(tooLong)));
        Assert.isFalse(r.casoPorIdentidad.containsKey(tooLong));
    }

    @isTest
    static void shouldReturnEmptyMapsWithoutDmlOrSoql_WhenInputNullOrEmpty() {
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        IntervencionService.Resultado fromNull = IntervencionService.abrir(null);
        IntervencionService.Resultado fromEmpty = IntervencionService.abrir(new List<IntervencionService.Solicitud>());

        Assert.isNotNull(fromNull.casoPorIdentidad);
        Assert.isNotNull(fromNull.errorPorIdentidad);
        Assert.isTrue(fromNull.casoPorIdentidad.isEmpty());
        Assert.isTrue(fromNull.errorPorIdentidad.isEmpty());
        Assert.isTrue(fromEmpty.casoPorIdentidad.isEmpty());
        Assert.isTrue(fromEmpty.errorPorIdentidad.isEmpty());
        Assert.areEqual(queriesBefore, Limits.getQueries(), 'No SOQL expected');
        Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'No DML expected');
    }

    @isTest
    static void shouldCreateCase_WhenRunningAsUserWithoutCaseAccess() {
        Asset a = asset('AST-INT-001');
        User restricted = [SELECT Id FROM User WHERE Email = 'restricted.intervencion.test@novacasatelemetria.invalid' LIMIT 1];

        IntervencionService.Resultado r;
        System.runAs(restricted) {
            Assert.isFalse(Schema.SObjectType.Case.isCreateable(), 'Precondition: user cannot create Case');
            Test.startTest();
            r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
                solicitud('SIM|msg-restricted', a, 'WATER_PRESSURE', 'ingestion path')
            });
            Test.stopTest();
        }

        Assert.isTrue(r.errorPorIdentidad.isEmpty(), 'SYSTEM_MODE must not depend on operator permissions');
        Assert.areEqual(1, r.casoPorIdentidad.size());
        Assert.areEqual(1, caseCount());
        Assert.areEqual('SIM|msg-restricted', [SELECT Identidad_Senal__c FROM Case WHERE Id = :r.casoPorIdentidad.get('SIM|msg-restricted')].Identidad_Senal__c);
    }
}
