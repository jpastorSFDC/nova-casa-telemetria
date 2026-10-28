/**
 * Test class for IntervencionService.
 * Covers D039 (one open telemetry Case per asset, refreshed with its most recent critical; manual and closed Cases
 * left alone), resend idempotency by identity, batch duplicates, bulk (200), partial success and SYSTEM_MODE
 * (ingestion does not depend on operator permissions).
 */
@isTest
private class IntervencionServiceTest {

    private static final String ID_PREFIX = 'SIM|msg-';
    // Whole seconds, so Case.Ultima_Critica_At__c compares exactly with what the request carried.
    private static final Datetime T0 = Datetime.newInstanceGmt(2026, 10, 1, 10, 0, 0);

    // ─── Test Setup ───────────────────────────────────────────────────────

    @testSetup
    static void setup() {
        Account building = new Account(Name = 'Edificio Intervencion Test', External_Id__c = 'BLD-INT-001');
        insert building;
        insert new List<Asset>{
            new Asset(Name = 'Bomba test', AccountId = building.Id, External_Id__c = 'AST-INT-001', Tipo_Activo__c = 'WATER_PUMP'),
            new Asset(Name = 'Medidor test', AccountId = building.Id, External_Id__c = 'AST-INT-002', Tipo_Activo__c = 'WATER_METER')
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
        return [SELECT Id, AccountId, External_Id__c FROM Asset WHERE External_Id__c = :externalId LIMIT 1];
    }

    private static IntervencionService.Solicitud solicitud(String identidad, Asset a, String tipo, String causa) {
        IntervencionService.Solicitud s = new IntervencionService.Solicitud();
        s.identidad = identidad;
        s.assetId = a == null ? null : a.Id;
        s.accountId = a == null ? null : a.AccountId;
        s.codigoActivo = a == null ? null : a.External_Id__c;
        s.tipoMedicion = tipo;
        s.causa = causa;
        return s;
    }

    // A request as the handler builds it for a winning critical (D039 fields set).
    private static IntervencionService.Solicitud critica(String identidad, Asset a, String tipo, Datetime occurredAt, Decimal valor, String unidad) {
        IntervencionService.Solicitud s = solicitud(identidad, a, tipo, 'above critical threshold');
        s.occurredAt = occurredAt;
        s.valor = valor;
        s.unidad = unidad;
        return s;
    }

    private static IntervencionService.Resultado openOne(IntervencionService.Solicitud s) {
        return IntervencionService.abrir(new List<IntervencionService.Solicitud>{ s });
    }

    private static Integer caseCount() {
        return [SELECT COUNT() FROM Case];
    }

    private static Case caseById(Id caseId) {
        List<Case> cases = [
            SELECT Id, Origin, Status, IsClosed, Priority, AssetId, AccountId, Subject, Description, Identidad_Senal__c,
                Ultima_Critica_Medicion__c, Ultima_Critica_Valor__c, Ultima_Critica_Unidad__c, Ultima_Critica_At__c,
                Ultima_Critica_Identidad__c
            FROM Case WHERE Id = :caseId
        ];
        Assert.areEqual(1, cases.size(), 'Expected exactly one Case with Id ' + caseId);
        return cases[0];
    }

    private static void assertLatestCritical(Case c, String identity, String tipo, Decimal valor, String unidad, Datetime occurredAt, String context) {
        Assert.areEqual(identity, c.Ultima_Critica_Identidad__c, context + ' - Ultima_Critica_Identidad__c');
        Assert.areEqual(tipo, c.Ultima_Critica_Medicion__c, context + ' - Ultima_Critica_Medicion__c');
        Assert.areEqual(valor, c.Ultima_Critica_Valor__c, context + ' - Ultima_Critica_Valor__c');
        Assert.areEqual(unidad, c.Ultima_Critica_Unidad__c, context + ' - Ultima_Critica_Unidad__c');
        Assert.areEqual(occurredAt, c.Ultima_Critica_At__c, context + ' - Ultima_Critica_At__c');
    }

    // An open telemetry Case created outside abrir() (accumulated before D039). latestAt = null: it records no critical.
    private static Case openTelemetryCase(Asset a, String identity, Datetime latestAt) {
        Case c = new Case(AssetId = a.Id, AccountId = a.AccountId, Status = 'En curso', Origin = 'Telemetria', Priority = 'Critica',
            Subject = 'Señal crítica: TEMPERATURE en ' + a.External_Id__c, Identidad_Senal__c = identity);
        if (latestAt != null) {
            c.Ultima_Critica_Identidad__c = identity;
            c.Ultima_Critica_Medicion__c = 'TEMPERATURE';
            c.Ultima_Critica_Valor__c = 36;
            c.Ultima_Critica_Unidad__c = 'CELSIUS';
            c.Ultima_Critica_At__c = latestAt;
        }
        return c;
    }

    // The two setup assets plus eight more on the same building, sorted by External_Id__c.
    private static List<Asset> tenAssets() {
        Account building = [SELECT Id FROM Account WHERE External_Id__c = 'BLD-INT-001'];
        List<Asset> extra = new List<Asset>();
        for (Integer i = 0; i < 8; i++) {
            extra.add(new Asset(Name = 'Bulk ' + i, AccountId = building.Id, External_Id__c = 'AST-INT-B0' + i, Tipo_Activo__c = 'WATER_PUMP'));
        }
        insert extra;
        List<Asset> assets = [SELECT Id, AccountId, External_Id__c FROM Asset WHERE AccountId = :building.Id ORDER BY External_Id__c];
        Assert.areEqual(10, assets.size(), 'Precondition: ten assets');
        return assets;
    }

    // 20 requests per asset, interleaved across assets. Each asset's most recent one (minute 20) sits mid-list (n = 17),
    // so neither first-wins nor last-wins would pick it. newestByAsset receives that identity per asset.
    private static List<IntervencionService.Solicitud> bulkRequests(List<Asset> assets, Map<Id, String> newestByAsset) {
        List<IntervencionService.Solicitud> requests = new List<IntervencionService.Solicitud>();
        for (Integer n = 0; n < 20; n++) {
            Integer minute = 1 + Math.mod(n * 7, 20);
            for (Integer i = 0; i < assets.size(); i++) {
                String identity = ID_PREFIX + 'bulk-' + i + '-' + n;
                requests.add(critica(identity, assets[i], 'WATER_PRESSURE', T0.addMinutes(minute), 7 + minute, 'BAR'));
                if (minute == 20) {
                    newestByAsset.put(assets[i].Id, identity);
                }
            }
        }
        return requests;
    }

    private static Map<Id, Case> casesByAsset() {
        Map<Id, Case> byAsset = new Map<Id, Case>();
        for (Case c : [SELECT Id, AssetId, IsClosed, Identidad_Senal__c, Ultima_Critica_Identidad__c FROM Case]) {
            Assert.isFalse(byAsset.containsKey(c.AssetId), 'More than one Case for asset ' + c.AssetId);
            Assert.isFalse(c.IsClosed, 'Every Case stays open');
            byAsset.put(c.AssetId, c);
        }
        return byAsset;
    }

    // ─── Tests ────────────────────────────────────────────────────────────

    @isTest
    static void shouldCreateOneCaseWithExpectedFields_WhenSingleRequest() {
        Asset a = asset('AST-INT-001');
        String identity = 'SIM|msg-1';

        Test.startTest();
        IntervencionService.Resultado r = openOne(critica(identity, a, 'WATER_PRESSURE', T0, 7.5, 'BAR'));
        Test.stopTest();

        Assert.areEqual(1, caseCount(), 'Exactly one Case should exist');
        Assert.isTrue(r.errorPorIdentidad.isEmpty(), 'No errors expected');
        Assert.areEqual(1, r.casoPorIdentidad.size(), 'One identity mapped');
        Assert.isNotNull(r.casoPorIdentidad.get(identity), 'Identity should map to the created Case');
        Case c = caseById(r.casoPorIdentidad.get(identity));
        Assert.areEqual('Telemetria', c.Origin);
        Assert.areEqual('En curso', c.Status);
        Assert.areEqual('Critica', c.Priority);
        Assert.areEqual(a.Id, c.AssetId);
        Assert.areEqual(a.AccountId, c.AccountId);
        Assert.areEqual(identity, c.Identidad_Senal__c);
        Assert.areEqual('Señal crítica: WATER_PRESSURE en AST-INT-001', c.Subject);
        Assert.areEqual('Signal ' + identity + ': above critical threshold', c.Description);
        assertLatestCritical(c, identity, 'WATER_PRESSURE', 7.5, 'BAR', T0, 'The opener is the latest critical');
    }

    @isTest
    static void shouldFallBackToAssetId_WhenCatalogCodeIsBlank() {
        Asset a = asset('AST-INT-001');
        IntervencionService.Solicitud s = solicitud('SIM|msg-nocode', a, 'TEMPERATURE', 'above critical threshold');
        s.codigoActivo = null;

        IntervencionService.abrir(new List<IntervencionService.Solicitud>{ s });

        Assert.areEqual('Señal crítica: TEMPERATURE en ' + a.Id, [SELECT Subject FROM Case].Subject);
    }

    @isTest
    static void shouldOpenItsOwnCase_WhenAManualInterventionIsAlreadyOpenOnTheAsset() {
        Asset a = asset('AST-INT-001');
        insert new Case(AssetId = a.Id, Status = 'En curso', Origin = 'Operador', Subject = 'Intervención manual en AST-INT-001');

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(
            new List<IntervencionService.Solicitud>{ solicitud('SIM|msg-critical', a, 'WATER_PRESSURE', 'above critical threshold') });
        Test.stopTest();

        Assert.areEqual(2, caseCount(), 'A manual Case does not stand in for the Case of a critical message');
        Assert.isTrue(r.casoPorIdentidad.containsKey('SIM|msg-critical'));
        Assert.areEqual(1, [SELECT COUNT() FROM Case WHERE Identidad_Senal__c = 'SIM|msg-critical' AND Origin = 'Telemetria']);
    }

    @isTest
    static void shouldNeverLinkOrRefreshTheManualCase_WhenTelemetryRequestsArrive() {
        Asset a = asset('AST-INT-001');
        Case manual = new Case(AssetId = a.Id, Status = 'En curso', Origin = 'Operador', Subject = 'Intervención manual en AST-INT-001');
        insert manual;
        IntervencionService.Resultado first = openOne(critica('SIM|msg-1', a, 'TEMPERATURE', T0, 40, 'CELSIUS'));
        Id telemetryId = first.casoPorIdentidad.get('SIM|msg-1');
        Assert.isNotNull(telemetryId, 'The first request opens a Case');
        // The manual Case becomes the most recently created open Case of the asset: only the Origin filter keeps it out.
        Test.setCreatedDate(telemetryId, Datetime.now().addDays(-1));

        Test.startTest();
        IntervencionService.Resultado second = openOne(critica('SIM|msg-2', a, 'WATER_PRESSURE', T0.addMinutes(5), 7.5, 'BAR'));
        Test.stopTest();

        Assert.areNotEqual(manual.Id, telemetryId, 'The telemetry request opens its own Case instead of linking the manual one');
        Assert.areEqual(telemetryId, second.casoPorIdentidad.get('SIM|msg-2'), 'The next request links to the telemetry Case, not the manual one');
        Assert.areEqual(2, caseCount(), 'One manual Case and one telemetry Case');
        Case manualAfter = caseById(manual.Id);
        Assert.areEqual('Operador', manualAfter.Origin, 'The manual Case keeps its origin');
        Assert.areEqual('Intervención manual en AST-INT-001', manualAfter.Subject, 'The manual Case keeps its subject');
        Assert.isNull(manualAfter.Identidad_Senal__c, 'The manual Case has no signal identity');
        assertLatestCritical(manualAfter, null, null, null, null, null, 'The manual Case is never refreshed');
        assertLatestCritical(caseById(telemetryId), 'SIM|msg-2', 'WATER_PRESSURE', 7.5, 'BAR', T0.addMinutes(5),
            'The telemetry Case is refreshed with the more recent request');
    }

    @isTest
    static void shouldReturnSameCaseWithoutModifyingIt_WhenSameIdentityIsResent() {
        Asset a = asset('AST-INT-001');
        String identity = 'SIM|msg-resend';
        IntervencionService.Solicitud original = critica(identity, a, 'WATER_PRESSURE', T0, 7.5, 'BAR');
        original.causa = 'original cause';
        IntervencionService.Resultado first = openOne(original);
        Case before = caseById(first.casoPorIdentidad.get(identity));

        Test.startTest();
        IntervencionService.Solicitud resend = critica(identity, asset('AST-INT-002'), 'TEMPERATURE', T0.addMinutes(30), 40, 'CELSIUS');
        resend.causa = 'different cause';
        IntervencionService.Resultado second = openOne(resend);
        Test.stopTest();

        Assert.areEqual(1, caseCount(), 'Resend must not create a second Case');
        Assert.areEqual(first.casoPorIdentidad.get(identity), second.casoPorIdentidad.get(identity), 'Same Case Id returned');
        Assert.isTrue(second.errorPorIdentidad.isEmpty(), 'Resend is not an error');
        Case after = caseById(before.Id);
        Assert.areEqual(before.Subject, after.Subject, 'Subject must not change on resend');
        Assert.areEqual(before.Description, after.Description, 'Description must not change on resend');
        Assert.areEqual(before.AssetId, after.AssetId, 'Asset must not change on resend');
        Assert.areEqual(before.Status, after.Status);
        Assert.areEqual(before.Priority, after.Priority);
        assertLatestCritical(after, identity, 'WATER_PRESSURE', 7.5, 'BAR', T0, 'A resend does not refresh the latest critical');
    }

    @isTest
    static void shouldLeaveTheCaseUntouched_WhenItsOpenerIsSentAgainWithNewerValues() {
        Asset a = asset('AST-INT-001');
        Id caseId = openOne(critica('SIM|msg-opener', a, 'TEMPERATURE', T0, 40, 'CELSIUS')).casoPorIdentidad.get('SIM|msg-opener');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        // Same asset: had the identity lookup not short-circuited it, the open Case would be refreshed.
        IntervencionService.Resultado r = openOne(critica('SIM|msg-opener', a, 'WATER_PRESSURE', T0.addMinutes(30), 9, 'BAR'));
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(caseId, r.casoPorIdentidad.get('SIM|msg-opener'), 'The identity maps to the Case it opened');
        Assert.areEqual(0, dmlUsed, 'An identity that already has a Case writes nothing');
        Assert.areEqual(1, caseCount());
        assertLatestCritical(caseById(caseId), 'SIM|msg-opener', 'TEMPERATURE', 40, 'CELSIUS', T0, 'The Case keeps what its opener recorded');
    }

    @isTest
    static void shouldNotRefreshAgain_WhenALinkedIdentityIsSentAgain() {
        Asset a = asset('AST-INT-001');
        Id caseId = openOne(critica('SIM|msg-1', a, 'TEMPERATURE', T0, 40, 'CELSIUS')).casoPorIdentidad.get('SIM|msg-1');
        IntervencionService.Solicitud linked = critica('SIM|msg-2', a, 'WATER_PRESSURE', T0.addMinutes(5), 7.5, 'BAR');
        Assert.areEqual(caseId, openOne(linked).casoPorIdentidad.get('SIM|msg-2'), 'Precondition: the second identity links to the Case');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        IntervencionService.Resultado r = openOne(linked);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(caseId, r.casoPorIdentidad.get('SIM|msg-2'), 'The linked identity maps to the same Case again');
        Assert.isTrue(r.errorPorIdentidad.isEmpty());
        Assert.areEqual(0, dmlUsed, 'The Case already records this identity: no update');
        Assert.areEqual(1, caseCount());
        assertLatestCritical(caseById(caseId), 'SIM|msg-2', 'WATER_PRESSURE', 7.5, 'BAR', T0.addMinutes(5), 'Still the linked identity');
    }

    @isTest
    static void shouldReturnSameCaseWithoutReopeningIt_WhenSameIdentityIsResentAfterTheCaseWasClosed() {
        Asset a = asset('AST-INT-001');
        String identity = 'SIM|msg-closed';
        IntervencionService.Resultado first = IntervencionService.abrir(
            new List<IntervencionService.Solicitud>{ solicitud(identity, a, 'WATER_PRESSURE', 'original cause') });
        Id caseId = first.casoPorIdentidad.get(identity);
        closeCaseWithComment(caseId);

        Test.startTest();
        IntervencionService.Resultado second = IntervencionService.abrir(
            new List<IntervencionService.Solicitud>{ solicitud(identity, a, 'WATER_PRESSURE', 'original cause') });
        Test.stopTest();

        Assert.areEqual(1, caseCount(), 'A resend after the close must not open a second Case');
        Assert.areEqual(caseId, second.casoPorIdentidad.get(identity), 'The closed Case is the existing result');
        Assert.isTrue(second.errorPorIdentidad.isEmpty());
        Assert.isTrue([SELECT IsClosed FROM Case WHERE Id = :caseId].IsClosed, 'The resend does not reopen the Case');
    }

    @isTest
    static void shouldOpenOneCase_WhenDifferentIdentitiesShareAssetAndMeasurement() {
        Asset a = asset('AST-INT-001');

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            critica('SIM|msg-A', a, 'WATER_PRESSURE', T0, 7, 'BAR'),
            critica('SIM|msg-B', a, 'WATER_PRESSURE', T0.addMinutes(5), 8, 'BAR')
        });
        Test.stopTest();

        Assert.areEqual(1, caseCount(), 'D039: one open telemetry Case per asset, not one per identity');
        Assert.areEqual(2, r.casoPorIdentidad.size(), 'Both identities are mapped');
        Assert.isTrue(r.errorPorIdentidad.isEmpty());
        Assert.areEqual(r.casoPorIdentidad.get('SIM|msg-A'), r.casoPorIdentidad.get('SIM|msg-B'), 'Both identities share the Case');
        Assert.areEqual('SIM|msg-B', caseById(r.casoPorIdentidad.get('SIM|msg-A')).Identidad_Senal__c, 'The most recent request opens it');
    }

    @isTest
    static void shouldOpenOneCaseFromTheMostRecent_WhenTwoMeasurementsOfAnAssetArriveTogether() {
        assertOneCaseFromTheMostRecent(false);
    }

    @isTest
    static void shouldOpenOneCaseFromTheMostRecent_WhenTwoMeasurementsOfAnAssetArriveTogetherInReverseOrder() {
        assertOneCaseFromTheMostRecent(true);
    }

    private static void assertOneCaseFromTheMostRecent(Boolean newerFirst) {
        Asset a = asset('AST-INT-001');
        IntervencionService.Solicitud older = critica('SIM|msg-temp', a, 'TEMPERATURE', T0, 40, 'CELSIUS');
        IntervencionService.Solicitud newer = critica('SIM|msg-pres', a, 'WATER_PRESSURE', T0.addMinutes(5), 7.5, 'BAR');

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(newerFirst
            ? new List<IntervencionService.Solicitud>{ newer, older }
            : new List<IntervencionService.Solicitud>{ older, newer });
        Test.stopTest();

        Assert.isTrue(r.errorPorIdentidad.isEmpty(), 'No errors expected: ' + r.errorPorIdentidad);
        Assert.areEqual(1, caseCount(), 'Two measurements of one asset open a single Case');
        Id caseId = r.casoPorIdentidad.get('SIM|msg-pres');
        Assert.isNotNull(caseId, 'The newer identity is mapped');
        Assert.areEqual(caseId, r.casoPorIdentidad.get('SIM|msg-temp'), 'The older identity maps to the same Case');
        Case c = caseById(caseId);
        Assert.areEqual('SIM|msg-pres', c.Identidad_Senal__c, 'The most recent request opens the Case, whatever the input order');
        Assert.areEqual('Señal crítica: WATER_PRESSURE en AST-INT-001', c.Subject, 'The subject names the opener measurement');
        assertLatestCritical(c, 'SIM|msg-pres', 'WATER_PRESSURE', 7.5, 'BAR', T0.addMinutes(5), 'The Case records the most recent critical');
    }

    @isTest
    static void shouldLinkAndRefreshTheLatestCritical_WhenAMoreRecentRequestArrivesInALaterCall() {
        Asset a = asset('AST-INT-001');
        Id caseId = openOne(critica('SIM|msg-1', a, 'TEMPERATURE', T0, 40, 'CELSIUS')).casoPorIdentidad.get('SIM|msg-1');
        Case before = caseById(caseId);

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        IntervencionService.Resultado r = openOne(critica('SIM|msg-2', a, 'WATER_PRESSURE', T0.addMinutes(5), 7.5, 'BAR'));
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(caseId, r.casoPorIdentidad.get('SIM|msg-2'), 'The later request links to the open Case');
        Assert.isTrue(r.errorPorIdentidad.isEmpty());
        Assert.areEqual(1, caseCount(), 'No new Case while one is open');
        Assert.areEqual(1, dmlUsed, 'One update and no insert');
        Case after = caseById(caseId);
        assertLatestCritical(after, 'SIM|msg-2', 'WATER_PRESSURE', 7.5, 'BAR', T0.addMinutes(5), 'Refreshed with the more recent request');
        Assert.areEqual(before.Subject, after.Subject, 'Subject unchanged');
        Assert.areEqual(before.Description, after.Description, 'Description unchanged');
        Assert.areEqual(before.Status, after.Status, 'Status unchanged');
        Assert.areEqual(before.Priority, after.Priority, 'Priority unchanged');
        Assert.areEqual(before.Origin, after.Origin, 'Origin unchanged');
        Assert.areEqual('SIM|msg-1', after.Identidad_Senal__c, 'Identidad_Senal__c keeps the identity that opened the Case');
    }

    @isTest
    static void shouldLinkWithoutRefreshing_WhenALaterCallBringsAnOlderRequest() {
        Asset a = asset('AST-INT-001');
        Id caseId = openOne(critica('SIM|msg-new', a, 'WATER_PRESSURE', T0.addMinutes(5), 7.5, 'BAR')).casoPorIdentidad.get('SIM|msg-new');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        IntervencionService.Resultado r = openOne(critica('SIM|msg-old', a, 'TEMPERATURE', T0, 40, 'CELSIUS'));
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(caseId, r.casoPorIdentidad.get('SIM|msg-old'), 'An older request still links to the open Case');
        Assert.isTrue(r.errorPorIdentidad.isEmpty());
        Assert.areEqual(1, caseCount(), 'No new Case');
        Assert.areEqual(0, dmlUsed, 'An older request does not update the Case');
        assertLatestCritical(caseById(caseId), 'SIM|msg-new', 'WATER_PRESSURE', 7.5, 'BAR', T0.addMinutes(5), 'The Case keeps the more recent critical');
    }

    @isTest
    static void shouldKeepTheSmallerMessageId_WhenTiedRequestsArriveInSeparateCalls() {
        assertTieKeepsTheSmallerMessageId(true);
    }

    @isTest
    static void shouldKeepTheSmallerMessageId_WhenTiedRequestsArriveInSeparateCallsInReverseOrder() {
        assertTieKeepsTheSmallerMessageId(false);
    }

    private static void assertTieKeepsTheSmallerMessageId(Boolean smallerFirst) {
        Asset a = asset('AST-INT-001');
        IntervencionService.Solicitud smaller = critica('SIM|msg-a', a, 'TEMPERATURE', T0, 40, 'CELSIUS');
        IntervencionService.Solicitud larger = critica('SIM|msg-b', a, 'WATER_PRESSURE', T0, 7.5, 'BAR');
        IntervencionService.Solicitud firstRequest = smallerFirst ? smaller : larger;
        IntervencionService.Solicitud secondRequest = smallerFirst ? larger : smaller;
        Id caseId = openOne(firstRequest).casoPorIdentidad.get(firstRequest.identidad);

        Test.startTest();
        IntervencionService.Resultado second = openOne(secondRequest);
        Test.stopTest();

        Assert.isNotNull(caseId, 'The first request opens the Case');
        Assert.areEqual(caseId, second.casoPorIdentidad.get(secondRequest.identidad), 'The second request links to the same Case');
        Assert.areEqual(1, caseCount());
        Case c = caseById(caseId);
        Assert.areEqual(firstRequest.identidad, c.Identidad_Senal__c, 'Identidad_Senal__c keeps the opener');
        assertLatestCritical(c, 'SIM|msg-a', 'TEMPERATURE', 40, 'CELSIUS', T0, 'Same occurredAt: the smaller messageId wins in either order');
    }

    @isTest
    static void shouldOpenFromTheSmallerSource_WhenOccurredAtAndMessageIdTie() {
        Asset a = asset('AST-INT-001');
        Asset b = asset('AST-INT-002');

        Test.startTest();
        // Asset A gets the larger source first, asset B gets it last: arrival order must not decide either.
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            critica('SIM-B|msg-1', a, 'TEMPERATURE', T0, 40, 'CELSIUS'),
            critica('SIM-A|msg-1', a, 'WATER_PRESSURE', T0, 7.5, 'BAR'),
            critica('SIM-A|msg-2', b, 'WATER_PRESSURE', T0, 7.5, 'BAR'),
            critica('SIM-B|msg-2', b, 'TEMPERATURE', T0, 40, 'CELSIUS')
        });
        Test.stopTest();

        Assert.areEqual(2, caseCount(), 'One Case per asset');
        Assert.areEqual('SIM-A|msg-1', caseById(r.casoPorIdentidad.get('SIM-B|msg-1')).Identidad_Senal__c, 'Asset A: the smaller source opens the Case');
        Assert.areEqual('SIM-A|msg-2', caseById(r.casoPorIdentidad.get('SIM-B|msg-2')).Identidad_Senal__c, 'Asset B: the smaller source opens the Case');
    }

    @isTest
    static void shouldOpenANewCaseAndLeaveTheClosedOneUntouched_WhenTheOpenCaseWasClosed() {
        Asset a = asset('AST-INT-001');
        Id closedId = openOne(critica('SIM|msg-1', a, 'TEMPERATURE', T0, 40, 'CELSIUS')).casoPorIdentidad.get('SIM|msg-1');
        closeCaseWithComment(closedId);

        Test.startTest();
        IntervencionService.Resultado r = openOne(critica('SIM|msg-2', a, 'WATER_PRESSURE', T0.addMinutes(5), 7.5, 'BAR'));
        Test.stopTest();

        Id newId = r.casoPorIdentidad.get('SIM|msg-2');
        Assert.isNotNull(newId, 'The next request is mapped');
        Assert.areNotEqual(closedId, newId, 'A closed Case is not linked: the next critical opens a new one');
        Assert.areEqual(2, caseCount());
        Case closed = caseById(closedId);
        Assert.isTrue(closed.IsClosed, 'The closed Case stays closed');
        assertLatestCritical(closed, 'SIM|msg-1', 'TEMPERATURE', 40, 'CELSIUS', T0, 'The closed Case is not refreshed');
        Case opened = caseById(newId);
        Assert.isFalse(opened.IsClosed, 'The new Case is open');
        Assert.areEqual('Telemetria', opened.Origin);
        Assert.areEqual('SIM|msg-2', opened.Identidad_Senal__c, 'The new Case is opened by the next request');
        assertLatestCritical(opened, 'SIM|msg-2', 'WATER_PRESSURE', 7.5, 'BAR', T0.addMinutes(5), 'The new Case records its opener');
    }

    @isTest
    static void shouldLinkToTheMostRecentlyCreatedOpenCase_WhenTheAssetHasTwoOpenTelemetryCases() {
        Asset a = asset('AST-INT-001');
        // Inserted first, so it has the smaller Id: only CreatedDate makes it the most recent.
        Case recent = openTelemetryCase(a, 'SIM|legacy-recent', T0);
        insert recent;
        Case older = openTelemetryCase(a, 'SIM|legacy-older', T0);
        insert older;
        Test.setCreatedDate(recent.Id, Datetime.now().addDays(-1));
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-2));

        Test.startTest();
        IntervencionService.Resultado r = openOne(critica('SIM|msg-new', a, 'WATER_PRESSURE', T0.addMinutes(5), 7.5, 'BAR'));
        Test.stopTest();

        Assert.areEqual(recent.Id, r.casoPorIdentidad.get('SIM|msg-new'), 'The request links to the most recently created open Case');
        Assert.areEqual(2, caseCount(), 'No new Case');
        assertLatestCritical(caseById(recent.Id), 'SIM|msg-new', 'WATER_PRESSURE', 7.5, 'BAR', T0.addMinutes(5), 'Only the linked Case is refreshed');
        assertLatestCritical(caseById(older.Id), 'SIM|legacy-older', 'TEMPERATURE', 36, 'CELSIUS', T0, 'The older open Case is untouched');
    }

    @isTest
    static void shouldFillTheLatestCritical_WhenTheOpenCaseRecordsNone() {
        Asset a = asset('AST-INT-001');
        Case legacy = openTelemetryCase(a, 'SIM|legacy', null);
        insert legacy;

        Test.startTest();
        // Years older than T0: a Case with no Ultima_Critica_At__c is older than any request.
        IntervencionService.Resultado r = openOne(critica('SIM|msg-1', a, 'TEMPERATURE', T0.addYears(-5), 40, 'CELSIUS'));
        Test.stopTest();

        Assert.areEqual(legacy.Id, r.casoPorIdentidad.get('SIM|msg-1'), 'The request links to the legacy open Case');
        Assert.areEqual(1, caseCount(), 'No new Case');
        Case c = caseById(legacy.Id);
        assertLatestCritical(c, 'SIM|msg-1', 'TEMPERATURE', 40, 'CELSIUS', T0.addYears(-5), 'The first linked request fills the empty fields');
        Assert.areEqual('SIM|legacy', c.Identidad_Senal__c, 'Identidad_Senal__c keeps the legacy opener');
    }

    @isTest
    static void shouldReportOnlyTheFailingIdentity_WhenTheCaseUpdateFails() {
        Asset a = asset('AST-INT-001');
        Asset b = asset('AST-INT-002');
        IntervencionService.Resultado opened = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            critica('SIM|msg-a-open', a, 'TEMPERATURE', T0.addMinutes(5), 40, 'CELSIUS'),
            critica('SIM|msg-b-open', b, 'TEMPERATURE', T0, 40, 'CELSIUS')
        });
        Id caseA = opened.casoPorIdentidad.get('SIM|msg-a-open');
        Id caseB = opened.casoPorIdentidad.get('SIM|msg-b-open');
        IntervencionService.identidadesConFalloDeActualizacion = new Set<String>{ 'SIM|msg-a-fails' };

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            // The most recent of asset A: its values are the ones written, and that update fails.
            critica('SIM|msg-a-fails', a, 'WATER_PRESSURE', T0.addMinutes(10), 7.5, 'BAR'),
            critica('SIM|msg-a-older', a, 'TEMPERATURE', T0, 41, 'CELSIUS'),
            critica('SIM|msg-b-new', b, 'WATER_PRESSURE', T0.addMinutes(10), 8, 'BAR')
        });
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(r.errorPorIdentidad.get('SIM|msg-a-fails')), 'The failing identity is reported');
        Assert.isFalse(r.casoPorIdentidad.containsKey('SIM|msg-a-fails'), 'The failing identity is not mapped');
        Assert.areEqual(1, r.errorPorIdentidad.size(), 'Only the identity whose values were being written fails: ' + r.errorPorIdentidad);
        Assert.areEqual(caseA, r.casoPorIdentidad.get('SIM|msg-a-older'), 'The asset\'s other identity stays linked');
        assertLatestCritical(caseById(caseA), 'SIM|msg-a-open', 'TEMPERATURE', 40, 'CELSIUS', T0.addMinutes(5), 'The failed update leaves the Case as it was');
        Assert.areEqual(caseB, r.casoPorIdentidad.get('SIM|msg-b-new'), 'Another asset in the same call links to its Case');
        assertLatestCritical(caseById(caseB), 'SIM|msg-b-new', 'WATER_PRESSURE', 8, 'BAR', T0.addMinutes(10), 'Another asset in the same call is refreshed');
        Assert.areEqual(2, caseCount(), 'No Case opened');
    }

    @isTest
    static void shouldLinkToTheCaseAConcurrentRunOpened_WhenTheInsertHitsADuplicateIdentity() {
        // Given another run inserts the asset's Case, with the same opener identity, between our lookup and our insert
        Asset a = asset('AST-INT-001');
        IntervencionService.insertarRivalAntesDeAbrir = true;

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            critica('SIM|msg-race-new', a, 'TEMPERATURE', T0.addMinutes(5), 40, 'CELSIUS'),
            critica('SIM|msg-race-old', a, 'TEMPERATURE', T0, 41, 'CELSIUS')
        });
        Test.stopTest();

        // Then the collision is recovered, not reported, and no second Case opens
        Assert.isTrue(r.errorPorIdentidad.isEmpty(), 'A duplicate opener on insert is recovered: ' + r.errorPorIdentidad);
        List<Case> cases = [SELECT Id, Identidad_Senal__c FROM Case WHERE AssetId = :a.Id];
        Assert.areEqual(1, cases.size(), 'Only the Case the other run opened exists');
        Assert.areEqual('SIM|msg-race-new', cases[0].Identidad_Senal__c, 'The other run opened it from the same most recent critical');
        Assert.areEqual(cases[0].Id, r.casoPorIdentidad.get('SIM|msg-race-new'), 'The opener maps to the existing Case');
        Assert.areEqual(cases[0].Id, r.casoPorIdentidad.get('SIM|msg-race-old'), 'The asset\'s other identity links to it too');
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
    static void shouldOpenOneCasePerAsset_WithinGovernorLimits_WhenBulk() {
        List<Asset> assets = tenAssets();
        Map<Id, String> newestByAsset = new Map<Id, String>();
        List<IntervencionService.Solicitud> requests = bulkRequests(assets, newestByAsset);
        Assert.areEqual(200, requests.size(), 'Precondition: 200 requests');

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        IntervencionService.Resultado r = IntervencionService.abrir(requests);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.isTrue(r.errorPorIdentidad.isEmpty(), 'No errors expected: ' + r.errorPorIdentidad);
        Assert.areEqual(200, r.casoPorIdentidad.size(), 'Every identity is mapped');
        Assert.areEqual(assets.size(), caseCount(), 'One Case per asset, not one per identity');
        Assert.isTrue(queriesUsed <= 4, 'SOQL queries used: ' + queriesUsed);
        Assert.isTrue(dmlUsed <= 2, 'DML statements used: ' + dmlUsed);
        Map<Id, Case> byAsset = casesByAsset();
        for (Asset a : assets) {
            Case c = byAsset.get(a.Id);
            Assert.isNotNull(c, 'Asset ' + a.External_Id__c + ' has its Case');
            Assert.areEqual(newestByAsset.get(a.Id), c.Identidad_Senal__c, 'The most recent request of ' + a.External_Id__c + ' opens its Case');
            Assert.areEqual(newestByAsset.get(a.Id), c.Ultima_Critica_Identidad__c, 'The Case of ' + a.External_Id__c + ' records its most recent request');
        }
        for (IntervencionService.Solicitud s : requests) {
            Assert.areEqual(byAsset.get(s.assetId).Id, r.casoPorIdentidad.get(s.identidad), s.identidad + ' maps to its asset Case');
        }
    }

    @isTest
    static void shouldRefreshOrOpenPerAsset_WithinGovernorLimits_WhenBulkAndSomeAssetsHaveOpenCases() {
        List<Asset> assets = tenAssets();
        // Assets 0-3 already have an open telemetry Case. Asset 3's records a critical newer than every request.
        List<Case> preOpened = new List<Case>();
        for (Integer i = 0; i < 4; i++) {
            preOpened.add(openTelemetryCase(assets[i], 'SIM|pre-' + i, i == 3 ? T0.addDays(1) : T0.addDays(-1)));
        }
        insert preOpened;
        Map<Id, String> newestByAsset = new Map<Id, String>();
        List<IntervencionService.Solicitud> requests = bulkRequests(assets, newestByAsset);
        Assert.areEqual(200, requests.size(), 'Precondition: 200 requests');

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        IntervencionService.Resultado r = IntervencionService.abrir(requests);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.isTrue(r.errorPorIdentidad.isEmpty(), 'No errors expected: ' + r.errorPorIdentidad);
        Assert.areEqual(200, r.casoPorIdentidad.size(), 'Every identity is mapped');
        Assert.areEqual(assets.size(), caseCount(), '4 existing Cases + 6 new ones: one per asset');
        Assert.isTrue(queriesUsed <= 4, 'SOQL queries used: ' + queriesUsed);
        Assert.isTrue(dmlUsed <= 2, 'DML statements used (one insert, one update): ' + dmlUsed);
        Map<Id, Case> byAsset = casesByAsset();
        for (Integer i = 0; i < assets.size(); i++) {
            Asset a = assets[i];
            Case c = byAsset.get(a.Id);
            Assert.isNotNull(c, 'Asset ' + a.External_Id__c + ' has its Case');
            if (i < 4) {
                Assert.areEqual(preOpened[i].Id, c.Id, a.External_Id__c + ' keeps its open Case');
                Assert.areEqual('SIM|pre-' + i, c.Identidad_Senal__c, a.External_Id__c + ' keeps its opener');
                String expectedLatest = i == 3 ? 'SIM|pre-3' : newestByAsset.get(a.Id);
                Assert.areEqual(expectedLatest, c.Ultima_Critica_Identidad__c,
                    a.External_Id__c + ' is refreshed only when the request is more recent than what it records');
            } else {
                Assert.areEqual(newestByAsset.get(a.Id), c.Identidad_Senal__c, 'The most recent request of ' + a.External_Id__c + ' opens its Case');
                Assert.areEqual(newestByAsset.get(a.Id), c.Ultima_Critica_Identidad__c, a.External_Id__c + ' records its opener');
            }
        }
        for (IntervencionService.Solicitud s : requests) {
            Assert.areEqual(byAsset.get(s.assetId).Id, r.casoPorIdentidad.get(s.identidad), s.identidad + ' maps to its asset Case');
        }
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
    static void shouldStoreNullValueAndTruncateTexts_WhenTheyExceedTheCaseFields() {
        Account building = [SELECT Id FROM Account WHERE External_Id__c = 'BLD-INT-001'];
        insert new Asset(Name = 'Tercer activo', AccountId = building.Id, External_Id__c = 'AST-INT-003', Tipo_Activo__c = 'WATER_PUMP');
        Decimal tooLarge = 100000000000000L; // 1e14
        Decimal largestThatFits = 99999999999999.9999; // Number(18,4)

        Test.startTest();
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            critica('SIM|msg-over', asset('AST-INT-001'), 'M'.repeat(70), T0, tooLarge, 'U'.repeat(50)),
            critica('SIM|msg-under', asset('AST-INT-002'), 'WATER_PRESSURE', T0, -tooLarge, 'BAR'),
            critica('SIM|msg-edge', asset('AST-INT-003'), 'WATER_PRESSURE', T0, largestThatFits, 'BAR')
        });
        Test.stopTest();

        Assert.isTrue(r.errorPorIdentidad.isEmpty(), 'Oversized values must not make the insert fail: ' + r.errorPorIdentidad);
        Assert.areEqual(3, caseCount());
        Case over = caseById(r.casoPorIdentidad.get('SIM|msg-over'));
        Assert.isNull(over.Ultima_Critica_Valor__c, 'A value of 1e14 does not fit Number(18,4) and is stored as null');
        Assert.areEqual('M'.repeat(60), over.Ultima_Critica_Medicion__c, 'The measurement is truncated to 60');
        Assert.areEqual('U'.repeat(40), over.Ultima_Critica_Unidad__c, 'The unit is truncated to 40');
        Assert.isNull(caseById(r.casoPorIdentidad.get('SIM|msg-under')).Ultima_Critica_Valor__c, 'A value of -1e14 is stored as null too');
        Assert.areEqual(largestThatFits, caseById(r.casoPorIdentidad.get('SIM|msg-edge')).Ultima_Critica_Valor__c,
            'The largest value that fits is kept');
    }

    @isTest
    static void shouldRejectBeforeAnyDml_WhenIdentityLongerThan60Chars() {
        Asset a = asset('AST-INT-001');
        String tooLong = 'SIM|' + 'x'.repeat(57);
        String longest = 'SIM|' + 'y'.repeat(56);
        Assert.areEqual(61, tooLong.length());
        Assert.areEqual(60, longest.length());

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        IntervencionService.Resultado alone = openOne(critica(tooLong, a, 'WATER_PRESSURE', T0, 7.5, 'BAR'));
        Integer queriesAlone = Limits.getQueries() - queriesBefore;
        Integer dmlAlone = Limits.getDmlStatements() - dmlBefore;
        // The over-length identity is the most recent: had it joined the asset group it would open the Case and fail the insert.
        IntervencionService.Resultado r = IntervencionService.abrir(new List<IntervencionService.Solicitud>{
            critica('SIM|msg-fine', a, 'WATER_PRESSURE', T0, 7.5, 'BAR'),
            critica(longest, a, 'TEMPERATURE', T0.addMinutes(1), 40, 'CELSIUS'),
            critica(tooLong, a, 'TEMPERATURE', T0.addMinutes(5), 41, 'CELSIUS')
        });
        Test.stopTest();

        Assert.areEqual('identidad exceeds 60 characters', alone.errorPorIdentidad.get(tooLong), 'Over-length identity is reported');
        Assert.isTrue(alone.casoPorIdentidad.isEmpty());
        Assert.areEqual(0, queriesAlone, 'Rejected before any SOQL');
        Assert.areEqual(0, dmlAlone, 'Rejected before any DML');

        Assert.areEqual('identidad exceeds 60 characters', r.errorPorIdentidad.get(tooLong));
        Assert.areEqual(1, r.errorPorIdentidad.size(), 'A 60-character identity is valid: ' + r.errorPorIdentidad);
        Assert.isFalse(r.casoPorIdentidad.containsKey(tooLong));
        Assert.areEqual(1, caseCount(), 'The valid rows open one Case');
        Id caseId = r.casoPorIdentidad.get(longest);
        Assert.isNotNull(caseId, 'The 60-character identity is mapped');
        Assert.areEqual(caseId, r.casoPorIdentidad.get('SIM|msg-fine'), 'Both valid identities share the Case');
        Case c = caseById(caseId);
        Assert.areEqual(longest, c.Identidad_Senal__c, 'The most recent valid request opens the Case');
        Assert.areEqual(longest, c.Ultima_Critica_Identidad__c);
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
    static void shouldOpenAndRefreshTheCase_WhenRunningAsUserWithoutCaseAccess() {
        Asset a = asset('AST-INT-001');
        User restricted = [SELECT Id FROM User WHERE Email = 'restricted.intervencion.test@novacasatelemetria.invalid' LIMIT 1];

        IntervencionService.Resultado opened;
        IntervencionService.Resultado refreshed;
        System.runAs(restricted) {
            Assert.isFalse(Schema.SObjectType.Case.isCreateable(), 'Precondition: user cannot create Case');
            Assert.isFalse(Schema.SObjectType.Case.isUpdateable(), 'Precondition: user cannot edit Case');
            Test.startTest();
            opened = openOne(critica('SIM|msg-restricted', a, 'WATER_PRESSURE', T0, 7.5, 'BAR'));
            refreshed = openOne(critica('SIM|msg-restricted-2', a, 'TEMPERATURE', T0.addMinutes(5), 40, 'CELSIUS'));
            Test.stopTest();
        }

        Assert.isTrue(opened.errorPorIdentidad.isEmpty(), 'SYSTEM_MODE insert must not depend on operator permissions');
        Assert.isTrue(refreshed.errorPorIdentidad.isEmpty(), 'SYSTEM_MODE update must not depend on operator permissions');
        Assert.areEqual(1, caseCount());
        Id caseId = opened.casoPorIdentidad.get('SIM|msg-restricted');
        Assert.areEqual(caseId, refreshed.casoPorIdentidad.get('SIM|msg-restricted-2'), 'The second request links to the same Case');
        Case c = caseById(caseId);
        Assert.areEqual('SIM|msg-restricted', c.Identidad_Senal__c);
        assertLatestCritical(c, 'SIM|msg-restricted-2', 'TEMPERATURE', 40, 'CELSIUS', T0.addMinutes(5), 'Refreshed as the restricted user');
    }

    // Changing a Case's status needs a comment on the Case (D046): append one and keep what is already there.
    private static void closeCaseWithComment(Id caseId) {
        Case current = [SELECT Description FROM Case WHERE Id = :caseId];
        current.Status = 'Closed';
        current.Description = (String.isBlank(current.Description) ? '' : current.Description + '\n') + 'Cierre de prueba';
        update current;
    }
}
