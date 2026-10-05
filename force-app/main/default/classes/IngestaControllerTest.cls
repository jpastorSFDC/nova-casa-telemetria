/**
 * Tests for IngestaController (D020). The simulator is never called: the queued job is not run
 * (no Test.stopTest), only enqueued, which is what the "one run at a time" guard looks at.
 */
@isTest
private class IngestaControllerTest {

    private static User newUserWithPermissionSet(String prefix, String permissionSetName) {
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
                LanguageLocaleKey = 'en_US'
            );
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = sets[0].Id);
        }
        return u;
    }

    // Keeps the queued job harmless if the platform runs it: an empty session and an empty page, no real callout.
    private class EmptySimulatorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(request.getEndpoint().contains('/session') ? '{"cursor":"test-cursor"}' : '{"data":[]}');
            return response;
        }
    }

    private static String startError(String scenario, Integer pages) {
        try {
            IngestaController.traerSenales(scenario, pages);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @isTest
    static void shouldKeepTheNineContractScenarios() {
        Assert.areEqual(9, IngestaController.SCENARIOS.size());
        Assert.areEqual('MIXED', IngestaController.SCENARIOS[0]);
        Assert.areEqual('CAMERA_OUTAGE', IngestaController.SCENARIOS[8]);
    }

    @isTest
    static void shouldQueueOneRunAndRefuseASecond_WhenAdminStartsTwice() {
        User admin = newUserWithPermissionSet('ncingadm', 'Nova_Casa_Admin');
        Test.setMock(HttpCalloutMock.class, new EmptySimulatorMock());

        IngestaController.Inicio started;
        String second;
        IngestaController.Estado state;
        System.runAs(admin) {
            started = IngestaController.traerSenales('CRITICAL_BURST', 3);
            second = startError('QA_200', null);
            state = IngestaController.estadoIngesta(started.iniciadaEn);
        }

        Assert.isNotNull(started.jobId);
        Assert.isNotNull(started.iniciadaEn);
        Assert.areEqual(IngestaController.ALREADY_RUNNING, second);
        Assert.isTrue(state.enCurso, 'The queued job counts as running');
        Assert.areEqual(0, state.total);
    }

    @isTest
    static void shouldRefuse_WhenScenarioIsNotInTheContract() {
        User admin = newUserWithPermissionSet('ncingbad', 'Nova_Casa_Admin');

        String unknown;
        String blank;
        System.runAs(admin) {
            unknown = startError('DROP_TABLE', 1);
            blank = startError(' ', 1);
        }

        Assert.areEqual(IngestaController.INVALID_SCENARIO, unknown);
        Assert.areEqual(IngestaController.INVALID_SCENARIO, blank);
        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta']);
    }

    @isTest
    static void shouldRefuseStartAndStatus_WhenUserIsNotAdmin() {
        User coordinator = newUserWithPermissionSet('ncingcoo', 'Nova_Casa_Coordinator');

        String startErr;
        String statusErr;
        System.runAs(coordinator) {
            startErr = startError('MIXED', 1);
            try {
                IngestaController.estadoIngesta(null);
            } catch (AuraHandledException e) {
                statusErr = e.getMessage();
            }
        }

        Assert.areEqual(IngestaController.NO_PERMISSION, startErr);
        Assert.areEqual(IngestaController.NO_PERMISSION, statusErr);
        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta']);
    }

    @isTest
    static void shouldCountLogRowsByResultSinceTheStart() {
        User admin = newUserWithPermissionSet('ncingcnt', 'Nova_Casa_Admin');
        insert new List<Log_Senial__c>{
            new Log_Senial__c(Source__c = 'SIM', Message_Id__c = 'a', Identidad__c = 'SIM|a', Resultado__c = 'Procesada'),
            new Log_Senial__c(Source__c = 'SIM', Message_Id__c = 'b', Identidad__c = 'SIM|b', Resultado__c = 'Procesada'),
            new Log_Senial__c(Source__c = 'SIM', Message_Id__c = 'c', Identidad__c = 'SIM|c', Resultado__c = 'Rechazada')
        };

        IngestaController.Estado state;
        IngestaController.Estado future;
        System.runAs(admin) {
            state = IngestaController.estadoIngesta(Datetime.now().addMinutes(-5));
            future = IngestaController.estadoIngesta(Datetime.now().addMinutes(5));
        }

        Assert.areEqual(3, state.total);
        Assert.areEqual(2, state.porResultado.get('Procesada'));
        Assert.areEqual(1, state.porResultado.get('Rechazada'));
        Assert.isFalse(state.enCurso);
        Assert.areEqual(0, future.total, 'Rows older than the start are not counted');
    }
}
