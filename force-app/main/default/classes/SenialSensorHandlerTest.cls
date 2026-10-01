@IsTest
private class SenialSensorHandlerTest {
    private static final String OCURRIDO = '2026-09-30T16:45:21.262Z';
    private static final String ANTERIOR = '2026-09-30T16:40:00.000Z';
    private static final String SALA = 'AST-BOG-TEMP-001';

    @TestSetup
    static void crearUmbrales() {
        insert new List<Umbral__c>{
            umbralDeTemperatura('GT', 30, 'Advertencia'),
            umbralDeTemperatura('GT', 35, 'Critica'),
            umbralDeTemperatura('LT', 15, 'Critica'),
            umbralDeTemperatura('GE', 81, 'Invalida'),
            umbralDeTemperatura('LE', -11, 'Invalida'),
            new Umbral__c(Tipo_Activo__c = 'SECURITY_CAMERA', Tipo_Medicion__c = 'CAMERA_CONNECTIVITY', Operador__c = 'GT',
                Valor__c = 180, Unidad_Esperada__c = 'SECONDS', Severidad__c = 'Critica', Activo__c = true)
        };
    }

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

    @IsTest
    static void clasificaNormalYCriticaSegunUmbral() {
        Senial_Sensor__e camara = new Senial_Sensor__e(Message_Id__c = 'msg_camara', Message_Type__c = 'CONNECTIVITY',
            Asset_Type__c = 'SECURITY_CAMERA', Asset_Id__c = 'AST-BOG-CAM-001', Gap_Seconds__c = '200', Occurred_At__c = OCURRIDO);

        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{
            temperatura('msg_normal', SALA, '25', 'CELSIUS', OCURRIDO),
            temperatura('msg_critica', 'AST-BOG-TEMP-002', '36', 'CELSIUS', OCURRIDO),
            camara
        });
        Test.stopTest();

        assertClasificacion('msg_normal', 'Normal', 0);
        assertClasificacion('msg_critica', 'Critica', 2);
        assertClasificacion('msg_camara', 'Critica', 2);
        Assert.areEqual('TEMPERATURE 36 CELSIUS supera el límite crítico GT 35',
            SenialSensorHandler.clasificacionPorMessageId.get('msg_critica').motivo, 'El motivo debe explicar el límite cruzado');
    }

    @IsTest
    static void lasSenialesSinNivelValidoNoQuedanComoNormal() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{
            new Senial_Sensor__e(Message_Id__c = 'msg_sin_umbral', Message_Type__c = 'MEASUREMENT', Asset_Type__c = 'WATER_PUMP',
                Asset_Id__c = 'AST-BOG-PUMP-001', Measurement_Type__c = 'WATER_PRESSURE', Value__c = '1.2', Unit__c = 'BAR',
                Occurred_At__c = OCURRIDO),
            temperatura('msg_sin_valor', SALA, null, 'CELSIUS', OCURRIDO),
            temperatura('msg_fecha_invalida', SALA, '25', 'CELSIUS', 'ayer'),
            temperatura('msg_otra_unidad', SALA, '77', 'FAHRENHEIT', OCURRIDO),
            temperatura('msg_fuera_de_rango', SALA, '90', 'CELSIUS', OCURRIDO)
        });
        Test.stopTest();

        assertClasificacion('msg_sin_umbral', 'SinUmbral', null);
        assertClasificacion('msg_sin_valor', 'DatoInvalido', null);
        assertClasificacion('msg_fecha_invalida', 'DatoInvalido', null);
        assertClasificacion('msg_otra_unidad', 'MedicionIncompatible', null);
        assertClasificacion('msg_fuera_de_rango', 'Invalida', null);
        Assert.isTrue(SenialSensorHandler.ganadoraPorClave.isEmpty(), 'Sin nivel válido no debe haber lectura ganadora');
    }

    @IsTest
    static void eligeUnaGanadoraPorActivoYMedicionSinDependerDelOrdenDeLlegada() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{
            temperatura('msg_000002', 'AST-MISMO-NIVEL', '25', 'CELSIUS', OCURRIDO),
            temperatura('msg_000001', 'AST-MISMO-NIVEL', '26', 'CELSIUS', OCURRIDO),
            temperatura('msg_000004', 'AST-OTRO-NIVEL', '36', 'CELSIUS', OCURRIDO),
            temperatura('msg_000003', 'AST-OTRO-NIVEL', '25', 'CELSIUS', OCURRIDO),
            temperatura('msg_000006', 'AST-OTRA-FECHA', '25', 'CELSIUS', OCURRIDO),
            temperatura('msg_000005', 'AST-OTRA-FECHA', '36', 'CELSIUS', ANTERIOR)
        });
        Test.stopTest();

        Assert.areEqual(3, SenialSensorHandler.ganadoraPorClave.size(), 'Debe haber una ganadora por activo + medición');
        Assert.areEqual('msg_000001', ganadora('AST-MISMO-NIVEL'), 'Mismo occurredAt y nivel: gana el messageId menor');
        Assert.areEqual('msg_000004', ganadora('AST-OTRO-NIVEL'), 'Mismo occurredAt: gana el nivel mayor');
        Assert.areEqual('msg_000006', ganadora('AST-OTRA-FECHA'), 'Gana el occurredAt más reciente aunque tenga menor nivel');
    }

    private static Umbral__c umbralDeTemperatura(String operador, Decimal valor, String severidad) {
        return new Umbral__c(Tipo_Activo__c = 'TECHNICAL_ROOM', Tipo_Medicion__c = 'TEMPERATURE', Operador__c = operador,
            Valor__c = valor, Unidad_Esperada__c = 'CELSIUS', Severidad__c = severidad, Activo__c = true);
    }

    private static Senial_Sensor__e temperatura(String messageId, String assetId, String valor, String unidad, String occurredAt) {
        return new Senial_Sensor__e(Message_Id__c = messageId, Message_Type__c = 'MEASUREMENT', Asset_Type__c = 'TECHNICAL_ROOM',
            Asset_Id__c = assetId, Measurement_Type__c = 'TEMPERATURE', Value__c = valor, Unit__c = unidad, Occurred_At__c = occurredAt);
    }

    private static void assertClasificacion(String messageId, String estadoEsperado, Integer nivelEsperado) {
        SenialSensorHandler.Clasificacion clasificacion = SenialSensorHandler.clasificacionPorMessageId.get(messageId);
        Assert.areEqual(estadoEsperado, clasificacion.estado, messageId + ': ' + clasificacion.motivo);
        Assert.areEqual(nivelEsperado, clasificacion.nivel, messageId + ' debe tener nivel ' + nivelEsperado);
    }

    private static String ganadora(String assetId) {
        return SenialSensorHandler.ganadoraPorClave.get(assetId + '|TEMPERATURE').messageId;
    }
}
