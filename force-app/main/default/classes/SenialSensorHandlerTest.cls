@IsTest
private class SenialSensorHandlerTest {
    @IsTest
    static void elTriggerEntregaElLoteCompletoAlHandler() {
        List<Senial_Sensor__e> seniales = new List<Senial_Sensor__e>{
            new Senial_Sensor__e(Message_Id__c = 'msg_000001', Source__c = 'nova-casa-simulator'),
            new Senial_Sensor__e(Message_Id__c = 'msg_000002', Source__c = 'nova-casa-simulator'),
            new Senial_Sensor__e(Message_Id__c = 'msg_000003', Source__c = 'nova-casa-simulator')
        };

        Test.startTest();
        List<Database.SaveResult> resultados = EventBus.publish(seniales);
        Test.stopTest();

        for (Database.SaveResult resultado : resultados) {
            Assert.isTrue(resultado.isSuccess(), 'La publicación debe aceptarse: ' + resultado.getErrors());
        }
        Assert.areEqual(3, SenialSensorHandler.senialesRecibidas, 'El handler debe recibir las 3 señales publicadas');
    }
}
