@IsTest
private class SenialSensorHandlerTest {
    private static final String OCURRIDO = '2026-09-30T16:45:21.262Z';
    private static final String ANTERIOR = '2026-09-30T16:40:00.000Z';
    private static final String SALA = 'AST-BOG-TEMP-001';

    private static final String FUENTE = 'nova-casa-simulator';
    private static final String SALA_2 = 'AST-BOG-TEMP-002';
    private static final String SALA_3 = 'AST-BOG-TEMP-003';
    private static final String FORMATO_ISO = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';

    @TestSetup
    static void crearUmbrales() {
        Account edificio = new Account(Name = 'Edificio Handler Test', External_Id__c = 'BLD-HDL-001');
        insert edificio;
        List<Asset> activos = new List<Asset>();
        for (String externo : new List<String>{ SALA, SALA_2, SALA_3 }) {
            activos.add(new Asset(Name = externo, AccountId = edificio.Id, External_Id__c = externo, Tipo_Activo__c = 'TECHNICAL_ROOM'));
        }
        for (Integer i = 0; i < 10; i++) {
            activos.add(new Asset(Name = 'Bulk ' + i, AccountId = edificio.Id, External_Id__c = 'AST-BULK-0' + i, Tipo_Activo__c = 'TECHNICAL_ROOM'));
        }
        insert activos;
        insert new List<Umbral__c>{
            new Umbral__c(Tipo_Activo__c = 'TECHNICAL_ROOM', Tipo_Medicion__c = 'WATER_PRESSURE', Operador__c = 'GT',
                Valor__c = 6, Unidad_Esperada__c = 'BAR', Severidad__c = 'Critica', Activo__c = true)
        };
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

    // ─── Persistencia (US-202, D011) ─────────────────────────────────────

    @IsTest
    static void primeraSenialNormalCreaLogYLecturaSinCase() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_n1', SALA, 'TEMPERATURE', '25', 'CELSIUS', OCURRIDO) });
        Test.stopTest();

        Log_Senial__c log = filaLog(identidad('msg_n1'));
        Assert.areEqual('Procesada', log.Resultado__c, 'Una señal válida queda Procesada: ' + log.Motivo__c);
        Assert.isNotNull(log.Procesado_At__c, 'Procesado_At__c debe fijarse');
        Assert.areEqual(activo(SALA).Id, log.Asset__c, 'El log apunta al activo del catálogo');
        Assert.areEqual(fecha(OCURRIDO), log.Occurred_At__c, 'El log guarda el occurredAt del mensaje');
        Assert.areEqual('dlv_1', log.Delivery_Id__c, 'El log guarda el deliveryId');
        Assert.areEqual('MEASUREMENT', log.Message_Type__c, 'El log guarda el tipo de mensaje');
        Assert.areEqual(64, log.Huella__c.length(), 'La huella SHA-256 en hex ocupa 64 caracteres');
        Assert.isNull(log.Caso__c, 'Una señal normal no abre intervención');

        Lectura_Vigente__c lectura = lectura(SALA + '|TEMPERATURE');
        Assert.areEqual(activo(SALA).Id, lectura.Asset__c, 'La lectura cuelga del activo');
        Assert.areEqual(25, lectura.Valor__c, 'Valor de la lectura');
        Assert.areEqual('CELSIUS', lectura.Unidad__c, 'Unidad de la lectura');
        Assert.areEqual('TEMPERATURE', lectura.Tipo_Medicion__c, 'Tipo de medición de la lectura');
        Assert.areEqual(0, lectura.Severidad_Nivel__c.intValue(), 'Normal es nivel 0');
        Assert.areEqual(identidad('msg_n1'), lectura.Identidad_Senal__c, 'La lectura recuerda la señal que la fijó');
        Assert.areEqual('SNS-1', lectura.Sensor_Id__c, 'Sensor de la lectura');
        Assert.areEqual(fecha(OCURRIDO), lectura.Occurred_At__c, 'occurredAt de la lectura');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'Ninguna intervención para una señal normal');
    }

    @IsTest
    static void senialCriticaAbreUnCaseYLoEnlazaAlLog() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_c1', SALA_2, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO) });
        Test.stopTest();

        List<Case> casos = [SELECT Id, Origin, Priority, AssetId, Identidad_Senal__c FROM Case];
        Assert.areEqual(1, casos.size(), 'Exactamente una intervención');
        Assert.areEqual('Telemetria', casos[0].Origin, 'Origen del Case');
        Assert.areEqual(identidad('msg_c1'), casos[0].Identidad_Senal__c, 'El Case lleva la identidad de la señal');
        Assert.areEqual(activo(SALA_2).Id, casos[0].AssetId, 'El Case apunta al activo');
        Log_Senial__c log = filaLog(identidad('msg_c1'));
        Assert.areEqual('Procesada', log.Resultado__c, 'Resultado del log');
        Assert.areEqual(casos[0].Id, log.Caso__c, 'El log enlaza el Case abierto');
        Lectura_Vigente__c lectura = lectura(SALA_2 + '|TEMPERATURE');
        Assert.areEqual(36, lectura.Valor__c, 'La lectura crítica se escribe');
        Assert.areEqual(2, lectura.Severidad_Nivel__c.intValue(), 'Crítica es nivel 2');
        Assert.areEqual(1, SenialSensorHandler.criticasProcesadas.size(), 'Una crítica procesada');
    }

    @IsTest
    static void unReenvioIgualSoloSumaReenviosSinTocarLecturaNiCase() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_r1', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO) });
        Log_Senial__c original = filaLog(identidad('msg_r1'));
        Lectura_Vigente__c lecturaOriginal = lectura(SALA + '|TEMPERATURE');

        Senial_Sensor__e reenvio = medicion('msg_r1', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO);
        reenvio.Delivery_Id__c = 'dlv_2'; // deliveryId cambia en cada reenvío y no cuenta para la huella
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ reenvio });
        Log_Senial__c trasUno = filaLog(identidad('msg_r1'));
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_r1', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO) });
        Test.stopTest();

        Log_Senial__c trasDos = filaLog(identidad('msg_r1'));
        Assert.areEqual(1, trasUno.Reenvios__c.intValue(), 'El primer reenvío suma 1');
        Assert.areEqual(2, trasDos.Reenvios__c.intValue(), 'El segundo reenvío suma otro');
        Assert.isNotNull(trasUno.Ultimo_Reenvio__c, 'Ultimo_Reenvio__c se fija');
        Assert.areEqual('Procesada', trasDos.Resultado__c, 'El reenvío no cambia el resultado');
        Assert.areEqual(original.Procesado_At__c, trasDos.Procesado_At__c, 'El reenvío no refresca Procesado_At__c');
        Assert.areEqual(original.Caso__c, trasDos.Caso__c, 'El Case del log no cambia');
        Assert.areEqual(original.Huella__c, trasDos.Huella__c, 'La huella original se conserva');
        Assert.areEqual('dlv_1', trasDos.Delivery_Id__c, 'El deliveryId original se conserva');
        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Vigente__c], 'Sigue habiendo una sola lectura');
        Assert.areEqual(lecturaOriginal.Id, lectura(SALA + '|TEMPERATURE').Id, 'Es la misma fila de lectura');
        Assert.areEqual(1, [SELECT COUNT() FROM Case], 'El reenvío no abre un segundo Case');
        Assert.areEqual(1, [SELECT COUNT() FROM Log_Senial__c], 'Una fila de log por identidad');
    }

    @IsTest
    static void mismaIdentidadConOtroContenidoEsConflictoSinCambiarEstado() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_x1', SALA, 'TEMPERATURE', '25', 'CELSIUS', OCURRIDO) });
        Log_Senial__c original = filaLog(identidad('msg_x1'));
        // Mismo source + messageId, valor distinto y crítico: no debe abrir Case ni mover la lectura.
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_x1', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO) });
        Test.stopTest();

        Log_Senial__c log = filaLog(identidad('msg_x1'));
        Assert.areEqual('Conflicto', log.Resultado__c, 'Contenido distinto con la misma identidad es Conflicto');
        Assert.isNotNull(log.Motivo__c, 'El conflicto explica el motivo');
        Assert.areEqual(original.Huella__c, log.Huella__c, 'La huella original no se reemplaza');
        Lectura_Vigente__c lectura = lectura(SALA + '|TEMPERATURE');
        Assert.areEqual(25, lectura.Valor__c, 'La lectura no cambia');
        Assert.areEqual(0, lectura.Severidad_Nivel__c.intValue(), 'La severidad no cambia');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'Un conflicto no abre intervención');
        Assert.areEqual('Conflicto', SenialSensorHandler.resultadoPorIdentidad.get(identidad('msg_x1')), 'Resultado reportado por el handler');
    }

    @IsTest
    static void unConflictoSobreUnaCriticaConservaSuCase() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_x2', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO) });
        Id casoId = filaLog(identidad('msg_x2')).Caso__c;
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_x2', SALA, 'TEMPERATURE', '40', 'CELSIUS', OCURRIDO) });
        Test.stopTest();

        Log_Senial__c log = filaLog(identidad('msg_x2'));
        Assert.areEqual('Conflicto', log.Resultado__c, 'Resultado del log');
        Assert.areEqual(casoId, log.Caso__c, 'El conflicto conserva el Case original (D011)');
        Assert.areEqual(36, lectura(SALA + '|TEMPERATURE').Valor__c, 'La lectura sigue siendo la original');
        Assert.areEqual(1, [SELECT COUNT() FROM Case], 'Sin Case nuevo');
    }

    @IsTest
    static void unaSenialMasAntiguaQueLaVigenteQuedaAtrasadaAunqueSeaCritica() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_l1', SALA, 'TEMPERATURE', '25', 'CELSIUS', OCURRIDO) });
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_l2', SALA, 'TEMPERATURE', '36', 'CELSIUS', ANTERIOR) });
        Test.stopTest();

        Log_Senial__c tardia = filaLog(identidad('msg_l2'));
        Assert.areEqual('Atrasada', tardia.Resultado__c, 'Se conserva como evidencia: ' + tardia.Motivo__c);
        Assert.isNull(tardia.Caso__c, 'Sin Case enlazado');
        Lectura_Vigente__c lectura = lectura(SALA + '|TEMPERATURE');
        Assert.areEqual(identidad('msg_l1'), lectura.Identidad_Senal__c, 'La lectura vigente no se sobrescribe');
        Assert.areEqual(25, lectura.Valor__c, 'Valor vigente intacto');
        Assert.areEqual(fecha(OCURRIDO), lectura.Occurred_At__c, 'occurredAt vigente intacto');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'Una crítica tardía no abre intervención');
        Assert.areEqual(0, SenialSensorHandler.criticasProcesadas.size(), 'No cuenta como crítica procesada');
    }

    @IsTest
    static void tiposDeMedicionDistintosDelMismoActivoNoSeSobrescriben() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_t1', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO) });
        // Presión más reciente que la temperatura: no debe tocar la lectura de temperatura.
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{
            medicion('msg_p1', SALA, 'WATER_PRESSURE', '2', 'BAR', '2026-09-30T16:50:00.000Z')
        });
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Lectura_Vigente__c], 'Una lectura por activo + tipo de medición');
        Lectura_Vigente__c temperatura = lectura(SALA + '|TEMPERATURE');
        Lectura_Vigente__c presion = lectura(SALA + '|WATER_PRESSURE');
        Assert.areEqual(36, temperatura.Valor__c, 'La temperatura sigue intacta');
        Assert.areEqual(2, temperatura.Severidad_Nivel__c.intValue(), 'La severidad de temperatura sigue intacta');
        Assert.areEqual(2, presion.Valor__c, 'Valor de presión');
        Assert.areEqual('BAR', presion.Unidad__c, 'Unidad de presión');
        Assert.areEqual(0, presion.Severidad_Nivel__c.intValue(), 'Presión normal');
        Assert.areEqual('Procesada', filaLog(identidad('msg_p1')).Resultado__c, 'La presión no es tardía respecto a la temperatura');
    }

    @IsTest
    static void elDesempateD003NoDependeDelOrdenDeLlegada() {
        desempatarEnUnLote(false);
    }

    @IsTest
    static void elDesempateD003NoDependeDelOrdenDeLlegadaEnOrdenInverso() {
        desempatarEnUnLote(true);
    }

    @IsTest
    static void unActivoInexistenteOUnaClasificacionInvalidaSeRechazanSinLecturaNiCase() {
        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{
            medicion('msg_z1', 'AST-NO-EXISTE', 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO), // crítica pero sin activo
            medicion('msg_z2', SALA, 'TEMPERATURE', '90', 'CELSIUS', OCURRIDO), // fuera de rango físico
            medicion('msg_z3', SALA_2, 'TEMPERATURE', null, 'CELSIUS', OCURRIDO), // sin valor
            new Senial_Sensor__e(Source__c = FUENTE, Message_Id__c = 'msg_z4', Message_Type__c = 'MEASUREMENT', Asset_Type__c = 'WATER_PUMP',
                Asset_Id__c = SALA_3, Measurement_Type__c = 'WATER_PRESSURE', Value__c = '1.2', Unit__c = 'BAR', Occurred_At__c = OCURRIDO) // sin umbral
        });
        Test.stopTest();

        Assert.isTrue(filaLog(identidad('msg_z1')).Motivo__c.contains('AST-NO-EXISTE'), 'El motivo nombra el activo inexistente');
        Assert.isNull(filaLog(identidad('msg_z1')).Asset__c, 'Sin activo en el log');
        Assert.isTrue(filaLog(identidad('msg_z2')).Motivo__c.contains('rango físico'), 'El motivo explica el rango físico');
        Assert.isTrue(filaLog(identidad('msg_z3')).Motivo__c.contains('Valor ausente'), 'El motivo explica el valor ausente');
        Assert.isTrue(filaLog(identidad('msg_z4')).Motivo__c.contains('No hay umbral activo'), 'El motivo explica la falta de umbral');
        for (String mid : new List<String>{ 'msg_z1', 'msg_z2', 'msg_z3', 'msg_z4' }) {
            Log_Senial__c log = filaLog(identidad(mid));
            Assert.areEqual('Rechazada', log.Resultado__c, mid + ' debe quedar Rechazada');
            Assert.isNotNull(log.Procesado_At__c, mid + ' se marca como procesada');
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Lectura_Vigente__c], 'Ninguna lectura');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'Ningún Case');
    }

    @IsTest
    static void losEventosSinSourceOMessageIdNoDejanLogYSeCuentan() {
        Integer antes = SenialSensorHandler.senialesSinIdentidad;
        Senial_Sensor__e sinSource = medicion('msg_s1', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO);
        sinSource.Source__c = null;
        Senial_Sensor__e sinMessageId = medicion(null, SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO);

        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ sinSource, sinMessageId });
        Test.stopTest();

        Assert.areEqual(antes + 2, SenialSensorHandler.senialesSinIdentidad, 'Ambos eventos cuentan como sin identidad');
        Assert.areEqual(0, [SELECT COUNT() FROM Log_Senial__c], 'Sin identidad no hay fila de log');
        Assert.areEqual(0, [SELECT COUNT() FROM Lectura_Vigente__c], 'Sin identidad no hay lectura');
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'Sin identidad no hay Case');
    }

    @IsTest
    static void siFallaElCaseLaIdentidadQuedaFallidaSinLecturaYLasDemasSeProcesan() {
        // Una identidad de más de 60 caracteres no cabe en Case.Identidad_Senal__c (60): el insert del Case falla
        // por fila, de forma determinista, mientras las demás identidades del lote sí se insertan (éxito parcial).
        String idLargo = 'msg_' + 'x'.repeat(38);
        String identidadLarga = FUENTE + '|' + idLargo;
        Assert.isTrue(identidadLarga.length() > 60, 'La identidad del caso de prueba debe exceder 60 caracteres');

        Test.startTest();
        // La lectura previa de SALA debe sobrevivir al fallo.
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_previa', SALA, 'TEMPERATURE', '25', 'CELSIUS', ANTERIOR) });
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{
            medicion('msg_ok', SALA_2, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO),
            medicion(idLargo, SALA, 'TEMPERATURE', '37', 'CELSIUS', OCURRIDO),
            medicion('msg_normal', SALA_3, 'TEMPERATURE', '25', 'CELSIUS', OCURRIDO)
        });
        Test.stopTest();

        Assert.areEqual('Fallida', SenialSensorHandler.resultadoPorIdentidad.get(identidadLarga), 'El handler marca la identidad como Fallida');
        // El log de esa identidad no cabe en Identidad__c (60), así que se verifica por lo que NO se escribió.
        Lectura_Vigente__c sala = lectura(SALA + '|TEMPERATURE');
        Assert.areEqual(identidad('msg_previa'), sala.Identidad_Senal__c, 'La lectura vigente anterior sigue intacta');
        Assert.areEqual(25, sala.Valor__c, 'Valor anterior intacto');
        Assert.areEqual(0, [SELECT COUNT() FROM Case WHERE Identidad_Senal__c = :identidadLarga], 'No existe Case para la identidad fallida');
        Assert.areEqual(1, [SELECT COUNT() FROM Case], 'Solo el Case de la otra crítica');
        Assert.areEqual('Procesada', filaLog(identidad('msg_ok')).Resultado__c, 'La otra crítica se procesa');
        Assert.isNotNull(filaLog(identidad('msg_ok')).Caso__c, 'La otra crítica tiene su Case');
        Assert.areEqual(36, lectura(SALA_2 + '|TEMPERATURE').Valor__c, 'La otra crítica escribe su lectura');
        Assert.areEqual('Procesada', filaLog(identidad('msg_normal')).Resultado__c, 'La señal normal del lote se procesa');
        Assert.areEqual(25, lectura(SALA_3 + '|TEMPERATURE').Valor__c, 'La señal normal escribe su lectura');
    }

    @IsTest
    static void doscientosEventosEnUnLoteUsanUnNumeroFijoDeConsultasYDml() {
        List<Senial_Sensor__e> lote = new List<Senial_Sensor__e>();
        Datetime base = Datetime.newInstanceGmt(2026, 9, 30, 10, 0, 0);
        for (Integer activo = 0; activo < 10; activo++) {
            for (Integer n = 0; n < 20; n++) {
                // El último evento de cada activo (n = 19) es el más reciente; en los activos pares es crítico.
                String valor = (n == 19 && Math.mod(activo, 2) == 0) ? '36' : '25';
                lote.add(medicion('msg_' + activo + '_' + n, 'AST-BULK-0' + activo, 'TEMPERATURE', valor, 'CELSIUS',
                    base.addMinutes(n).formatGmt(FORMATO_ISO)));
            }
        }
        Assert.areEqual(200, lote.size(), 'El lote de prueba son 200 eventos');

        Test.startTest();
        new SenialSensorHandler().procesar(lote);
        // Consultas: umbrales + logs + activos + lecturas (handler) + Cases existentes (IntervencionService) = 5.
        // DML: insert de Cases + upsert de lecturas + upsert de logs = 3. Ninguno escala con el tamaño del lote.
        Integer consultas = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        Test.stopTest();

        Assert.areEqual(5, consultas, 'Consultas fijas por lote');
        Assert.areEqual(3, dml, 'Sentencias DML fijas por lote');
        Assert.areEqual(200, [SELECT COUNT() FROM Log_Senial__c], 'Una fila de log por identidad');
        Assert.areEqual(10, [SELECT COUNT() FROM Lectura_Vigente__c], 'Una lectura por activo');
        Assert.areEqual(10, [SELECT COUNT() FROM Log_Senial__c WHERE Resultado__c = 'Procesada'], 'Una ganadora por activo');
        Assert.areEqual(190, [SELECT COUNT() FROM Log_Senial__c WHERE Resultado__c = 'Atrasada'], 'El resto queda como evidencia');
        Assert.areEqual(5, [SELECT COUNT() FROM Case], 'Un Case por cada activo cuya ganadora es crítica');
        Assert.areEqual(36, lectura('AST-BULK-00|TEMPERATURE').Valor__c, 'Gana la lectura más reciente del activo');
        Assert.areEqual(25, lectura('AST-BULK-01|TEMPERATURE').Valor__c, 'Gana la lectura más reciente del activo impar');
    }

    @IsTest
    static void laIngestaPersisteConUnUsuarioSinPermisosDeOperador() {
        User minimo;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile perfil = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            minimo = new User(FirstName = 'Sin', LastName = 'Permisos', Alias = 'sinperm', ProfileId = perfil.Id,
                Email = 'sin.permisos.handler@novacasatelemetria.invalid',
                Username = 'sin.permisos.handler' + DateTime.now().getTime() + '@novacasatelemetria.invalid',
                TimeZoneSidKey = 'America/Bogota', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US');
            insert minimo;
        }

        Test.startTest();
        System.runAs(minimo) {
            new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{
                medicion('msg_u1', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO),
                medicion('msg_u2', SALA_2, 'TEMPERATURE', '25', 'CELSIUS', OCURRIDO)
            });
        }
        Test.stopTest();

        Assert.areEqual('Procesada', filaLog(identidad('msg_u1')).Resultado__c, 'El log se escribe sin permisos de operador');
        Assert.areEqual('Procesada', filaLog(identidad('msg_u2')).Resultado__c, 'El log se escribe sin permisos de operador');
        Assert.areEqual(36, lectura(SALA + '|TEMPERATURE').Valor__c, 'La lectura se escribe sin permisos de operador');
        Assert.areEqual(25, lectura(SALA_2 + '|TEMPERATURE').Valor__c, 'La lectura se escribe sin permisos de operador');
        Assert.areEqual(1, [SELECT COUNT() FROM Case], 'El Case se abre sin permisos de operador');
        Assert.isNotNull(filaLog(identidad('msg_u1')).Caso__c, 'El log enlaza el Case');
    }

    @IsTest
    static void publicarElEventoPersisteATravesDelTrigger() {
        Test.startTest();
        EventBus.publish(medicion('msg_e1', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO));
        Test.stopTest();

        Log_Senial__c log = filaLog(identidad('msg_e1'));
        Assert.areEqual('Procesada', log.Resultado__c, 'El trigger entrega el evento al handler que persiste: ' + log.Motivo__c);
        Assert.isNotNull(log.Caso__c, 'La crítica publicada abre su Case');
        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Vigente__c], 'Una lectura');
    }

    // ─── Helpers de persistencia ─────────────────────────────────────────

    // D003: mismo occurredAt en el mismo lote. Gana el nivel mayor; a igual nivel, el messageId menor.
    private static void desempatarEnUnLote(Boolean invertido) {
        List<Senial_Sensor__e> lote = new List<Senial_Sensor__e>{
            medicion('msg_z', SALA, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO), // crítica con messageId mayor: gana por nivel
            medicion('msg_a', SALA, 'TEMPERATURE', '25', 'CELSIUS', OCURRIDO),
            medicion('msg_2', SALA_2, 'TEMPERATURE', '25', 'CELSIUS', OCURRIDO), // mismo nivel: gana el messageId menor
            medicion('msg_1', SALA_2, 'TEMPERATURE', '26', 'CELSIUS', OCURRIDO),
            medicion('msg_y', SALA_3, 'TEMPERATURE', '37', 'CELSIUS', OCURRIDO), // dos críticas: gana msg_x
            medicion('msg_x', SALA_3, 'TEMPERATURE', '36', 'CELSIUS', OCURRIDO)
        };
        if (invertido) {
            List<Senial_Sensor__e> alReves = new List<Senial_Sensor__e>();
            for (Integer i = lote.size() - 1; i >= 0; i--) {
                alReves.add(lote[i]);
            }
            lote = alReves;
        }

        Test.startTest();
        new SenialSensorHandler().procesar(lote);
        Test.stopTest();

        Assert.areEqual(identidad('msg_z'), lectura(SALA + '|TEMPERATURE').Identidad_Senal__c, 'Gana el nivel mayor');
        Assert.areEqual(identidad('msg_1'), lectura(SALA_2 + '|TEMPERATURE').Identidad_Senal__c, 'A igual nivel gana el messageId menor');
        Assert.areEqual(identidad('msg_x'), lectura(SALA_3 + '|TEMPERATURE').Identidad_Senal__c, 'A igual nivel crítico gana el messageId menor');
        for (String ganadora : new List<String>{ 'msg_z', 'msg_1', 'msg_x' }) {
            Assert.areEqual('Procesada', filaLog(identidad(ganadora)).Resultado__c, ganadora + ' debe quedar Procesada');
        }
        for (String perdedora : new List<String>{ 'msg_a', 'msg_2', 'msg_y' }) {
            Log_Senial__c log = filaLog(identidad(perdedora));
            Assert.areEqual('Atrasada', log.Resultado__c, perdedora + ' pierde el desempate: ' + log.Motivo__c);
            Assert.isNull(log.Caso__c, perdedora + ' no abre Case');
        }
        Assert.areEqual(3, [SELECT COUNT() FROM Lectura_Vigente__c], 'Una lectura por clave');
        Set<String> identidadesConCase = new Set<String>();
        for (Case c : [SELECT Identidad_Senal__c FROM Case]) {
            identidadesConCase.add(c.Identidad_Senal__c);
        }
        Assert.areEqual(new Set<String>{ identidad('msg_z'), identidad('msg_x') }, identidadesConCase, 'Solo las críticas ganadoras abren Case');
    }

    private static Senial_Sensor__e medicion(String messageId, String assetId, String tipo, String valor, String unidad, String occurredAt) {
        return new Senial_Sensor__e(Source__c = FUENTE, Message_Id__c = messageId, Message_Type__c = 'MEASUREMENT', Asset_Type__c = 'TECHNICAL_ROOM',
            Asset_Id__c = assetId, Sensor_Id__c = 'SNS-1', Measurement_Type__c = tipo, Value__c = valor, Unit__c = unidad,
            Occurred_At__c = occurredAt, Delivery_Id__c = 'dlv_1');
    }

    private static String identidad(String messageId) {
        return FUENTE + '|' + messageId;
    }

    private static Datetime fecha(String iso) {
        return (Datetime) JSON.deserialize('"' + iso + '"', Datetime.class);
    }

    private static Asset activo(String externo) {
        return [SELECT Id, AccountId FROM Asset WHERE External_Id__c = :externo LIMIT 1];
    }

    private static Log_Senial__c filaLog(String identidad) {
        List<Log_Senial__c> filas = [
            SELECT Id, Identidad__c, Resultado__c, Motivo__c, Procesado_At__c, Asset__c, Caso__c, Occurred_At__c, Delivery_Id__c,
                Message_Type__c, Huella__c, Reenvios__c, Ultimo_Reenvio__c
            FROM Log_Senial__c WHERE Identidad__c = :identidad
        ];
        Assert.areEqual(1, filas.size(), 'Debe existir exactamente una fila de log para ' + identidad);
        return filas[0];
    }

    private static Lectura_Vigente__c lectura(String clave) {
        List<Lectura_Vigente__c> filas = [
            SELECT Id, Clave__c, Asset__c, Valor__c, Unidad__c, Tipo_Medicion__c, Severidad_Nivel__c, Identidad_Senal__c, Sensor_Id__c, Occurred_At__c
            FROM Lectura_Vigente__c WHERE Clave__c = :clave
        ];
        Assert.areEqual(1, filas.size(), 'Debe existir exactamente una lectura vigente para ' + clave);
        return filas[0];
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
