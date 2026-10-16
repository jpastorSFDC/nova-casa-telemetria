/**
 * BR-209 / D014: ata la fórmula Log_Senial__c.Accion_Reintento__c a lo que SenialSensorHandler hace de verdad.
 * La fórmula y la regla "solo Fallida/Publicada se reprocesan" del handler están escritas dos veces; si una cambia
 * sin la otra, estos tests fallan.
 */
@IsTest
private class LogAccionReintentoTest {
    private static final String FUENTE = 'nova-casa-simulator';
    private static final String OCURRIDO = '2026-09-30T16:45:21.262Z';

    private static final String SIN_ACCION = 'No hace falta';
    private static final String SIN_ACCION_CONTADO = 'No hace falta: el reenvío ya quedó contado';

    // Estado => texto exacto de la fórmula con Reenvios__c = 0.
    private static final Map<String, String> ACCION_ESPERADA = new Map<String, String>{
        'Procesada' => SIN_ACCION,
        'Duplicada' => SIN_ACCION,
        'Atrasada' => SIN_ACCION,
        'Superada' => SIN_ACCION,
        'Fallida' => 'Sí: reintentar; la identidad evita duplicar el caso',
        'Publicada' => 'Sí: volver a publicar el evento',
        'Rechazada' => 'No: corregir el dato en origen y enviarlo con otro messageId (ver Motivo)',
        'Conflicto' => 'No: investigar la huella distinta antes de reintentar'
    };

    // Lo que el handler reprocesa hoy (líneas "yaProcesada" de SenialSensorHandler.persistir).
    private static final Set<String> REINTENTABLES = new Set<String>{ 'Fallida', 'Publicada' };

    @TestSetup
    static void crearDatos() {
        Account edificio = new Account(Name = 'Edificio Accion Test', External_Id__c = 'BLD-ACC-001');
        insert edificio;
        List<Asset> activos = new List<Asset>();
        for (Integer i = 0; i < 10; i++) {
            activos.add(new Asset(Name = 'Bulk ' + i, AccountId = edificio.Id, External_Id__c = 'AST-BULK-0' + i,
                Tipo_Activo__c = 'TECHNICAL_ROOM'));
        }
        insert activos;
        insert new List<Umbral__c>{
            umbral('GT', 30, 'Advertencia'),
            umbral('GT', 35, 'Critica'),
            umbral('LT', 15, 'Critica'),
            umbral('GE', 81, 'Invalida'),
            umbral('LE', -11, 'Invalida')
        };
    }

    @IsTest
    static void laPicklistDeResultadoTieneExactamenteLosEstadosCubiertos() {
        Set<String> enOrg = new Set<String>();
        for (Schema.PicklistEntry entrada : Log_Senial__c.Resultado__c.getDescribe().getPicklistValues()) {
            enOrg.add(entrada.getValue());
        }
        Assert.areEqual(ACCION_ESPERADA.keySet(), enOrg,
            'Un estado nuevo en Resultado__c exige decidir su acción de reintento y cubrirlo aquí');
    }

    @IsTest
    static void laFormulaDaLaAccionExactaPorEstado() {
        List<Log_Senial__c> filas = new List<Log_Senial__c>();
        for (String estado : ACCION_ESPERADA.keySet()) {
            filas.add(new Log_Senial__c(Identidad__c = FUENTE + '|msg_f_' + estado, Source__c = FUENTE,
                Message_Id__c = 'msg_f_' + estado, Resultado__c = estado));
        }
        insert filas;

        Map<String, Log_Senial__c> porEstado = new Map<String, Log_Senial__c>();
        for (Log_Senial__c fila : [SELECT Resultado__c, Reenvios__c, Accion_Reintento__c FROM Log_Senial__c]) {
            porEstado.put(fila.Resultado__c, fila);
        }
        Assert.areEqual(ACCION_ESPERADA.size(), porEstado.size(), 'Una fila por estado');
        for (String estado : ACCION_ESPERADA.keySet()) {
            Assert.areEqual(0, porEstado.get(estado).Reenvios__c.intValue(), estado + ': sin reenvíos al inicio');
            Assert.areEqual(ACCION_ESPERADA.get(estado), porEstado.get(estado).Accion_Reintento__c,
                'Acción de reintento para ' + estado);
        }
    }

    @IsTest
    static void conReenviosLosEstadosSinAccionLoDicenYLosDemasNoCambian() {
        List<Log_Senial__c> filas = new List<Log_Senial__c>();
        for (String estado : ACCION_ESPERADA.keySet()) {
            filas.add(new Log_Senial__c(Identidad__c = FUENTE + '|msg_r_' + estado, Source__c = FUENTE,
                Message_Id__c = 'msg_r_' + estado, Resultado__c = estado, Reenvios__c = 2));
        }
        insert filas;

        for (Log_Senial__c fila : [SELECT Resultado__c, Accion_Reintento__c FROM Log_Senial__c]) {
            String esperada = SIN_ACCION.equals(ACCION_ESPERADA.get(fila.Resultado__c))
                ? SIN_ACCION_CONTADO : ACCION_ESPERADA.get(fila.Resultado__c);
            Assert.areEqual(esperada, fila.Accion_Reintento__c, 'Acción con 2 reenvíos para ' + fila.Resultado__c);
        }
    }

    @IsTest
    static void laFormulaYElHandlerCoincidenEnQueEstadosSeReprocesan() {
        List<String> estados = new List<String>(ACCION_ESPERADA.keySet());
        estados.sort();
        Assert.isTrue(estados.size() <= 10, 'El setup solo trae 10 activos');

        // 1) Cada estado parte de una señal real procesada por el handler (huella verdadera, misma identidad).
        List<Senial_Sensor__e> originales = new List<Senial_Sensor__e>();
        for (Integer i = 0; i < estados.size(); i++) {
            originales.add(senial(mensaje(estados[i]), 'AST-BULK-0' + i));
        }
        new SenialSensorHandler().procesar(originales);
        delete [SELECT Id FROM Lectura_Vigente__c]; // una Fallida/Publicada real no dejó lectura

        // 2) Se fuerza el estado bajo prueba conservando la huella original.
        Map<String, Log_Senial__c> filas = new Map<String, Log_Senial__c>();
        for (Log_Senial__c fila : [SELECT Id, Identidad__c, Huella__c FROM Log_Senial__c]) {
            filas.put(fila.Identidad__c, fila);
        }
        Assert.areEqual(estados.size(), filas.size(), 'Una fila de log por señal original');
        for (String estado : estados) {
            Log_Senial__c fila = filas.get(identidad(estado));
            Assert.isNotNull(fila, 'Falta la fila de ' + estado);
            Assert.isNotNull(fila.Huella__c, 'El handler debe haber guardado la huella de ' + estado);
            fila.Resultado__c = estado;
        }
        update filas.values();

        // Lo que dice la fórmula, leída de la base tras fijar el estado.
        Map<String, Boolean> formulaDiceSi = new Map<String, Boolean>();
        for (Log_Senial__c fila : [SELECT Resultado__c, Accion_Reintento__c FROM Log_Senial__c]) {
            formulaDiceSi.put(fila.Resultado__c, fila.Accion_Reintento__c.startsWith('Sí'));
        }

        // 3) Reenvío idéntico (misma identidad, misma huella) de todos a la vez.
        List<Senial_Sensor__e> reenvios = new List<Senial_Sensor__e>();
        for (Integer i = 0; i < estados.size(); i++) {
            reenvios.add(senial(mensaje(estados[i]), 'AST-BULK-0' + i));
        }
        Test.startTest();
        new SenialSensorHandler().procesar(reenvios);
        Test.stopTest();

        Map<String, Log_Senial__c> despues = new Map<String, Log_Senial__c>();
        for (Log_Senial__c fila : [
            SELECT Identidad__c, Resultado__c, Reenvios__c, Huella__c, Accion_Reintento__c FROM Log_Senial__c
        ]) {
            despues.put(fila.Identidad__c, fila);
        }

        Set<String> reprocesados = new Set<String>();
        for (String estado : estados) {
            Log_Senial__c fila = despues.get(identidad(estado));
            Assert.areEqual(filas.get(identidad(estado)).Huella__c, fila.Huella__c, estado + ': la huella original se conserva');
            Boolean formulaDiceReintentar = formulaDiceSi.get(estado);
            if (formulaDiceReintentar) {
                reprocesados.add(estado);
                Assert.areEqual('Procesada', fila.Resultado__c,
                    estado + ': la fórmula dice "Sí" y el handler debe reprocesarla');
                Assert.areEqual(0, fila.Reenvios__c.intValue(), estado + ': un reproceso no cuenta como reenvío');
                Assert.areEqual(SIN_ACCION, fila.Accion_Reintento__c, estado + ': tras reprocesar ya no hay acción pendiente');
            } else {
                Assert.areEqual(estado, fila.Resultado__c,
                    estado + ': la fórmula dice "No" / "No hace falta": el handler no debe reprocesarla ni cambiar su resultado');
                Assert.areEqual(1, fila.Reenvios__c.intValue(), estado + ': se trata como reenvío y suma 1');
            }
        }
        Assert.areEqual(REINTENTABLES, reprocesados, 'Los estados reintentables según la fórmula son Fallida y Publicada');
        // Solo los reprocesados dejan lectura: el resto no escribe estado nuevo.
        Assert.areEqual(REINTENTABLES.size(), [SELECT COUNT() FROM Lectura_Vigente__c],
            'Solo Fallida y Publicada vuelven a escribir lectura');
    }

    @IsTest
    static void conHuellaDistintaUnEstadoReintentableEsConflictoYLaFormulaDiceInvestigar() {
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ senial('msg_dist', 'AST-BULK-00', '25') });
        Log_Senial__c fila = [SELECT Id, Identidad__c FROM Log_Senial__c WHERE Message_Id__c = 'msg_dist'];
        fila.Resultado__c = 'Fallida';
        update fila;

        Test.startTest();
        new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ senial('msg_dist', 'AST-BULK-00', '26') });
        Test.stopTest();

        Log_Senial__c despues = [SELECT Resultado__c, Accion_Reintento__c FROM Log_Senial__c WHERE Id = :fila.Id];
        Assert.areEqual('Conflicto', despues.Resultado__c, 'Una Fallida con otra huella no se reprocesa: es Conflicto');
        Assert.areEqual(ACCION_ESPERADA.get('Conflicto'), despues.Accion_Reintento__c, 'La fórmula pasa a "investigar"');
        // La primera pasada ya escribió la lectura (25). El conflicto (26) no la cambia.
        List<Lectura_Vigente__c> lecturas = [SELECT Valor__c FROM Lectura_Vigente__c WHERE Identidad_Senal__c = :fila.Identidad__c];
        Assert.areEqual(1, lecturas.size(), 'Sigue habiendo una sola lectura');
        Assert.areEqual(25, lecturas[0].Valor__c, 'El conflicto no cambia la lectura: el valor sigue siendo el original');
    }

    // ─── Helpers (copiados de SenialSensorHandlerTest, que los tiene privados) ──

    private static String mensaje(String estado) {
        return 'msg_' + estado.toLowerCase();
    }

    private static String identidad(String estado) {
        return FUENTE + '|' + mensaje(estado);
    }

    private static Senial_Sensor__e senial(String messageId, String assetId) {
        return senial(messageId, assetId, '25');
    }

    private static Senial_Sensor__e senial(String messageId, String assetId, String valor) {
        return new Senial_Sensor__e(Source__c = FUENTE, Message_Id__c = messageId, Message_Type__c = 'MEASUREMENT',
            Asset_Type__c = 'TECHNICAL_ROOM', Asset_Id__c = assetId, Sensor_Id__c = 'SNS-1',
            Measurement_Type__c = 'TEMPERATURE', Value__c = valor, Unit__c = 'CELSIUS',
            Occurred_At__c = OCURRIDO, Delivery_Id__c = 'dlv_1');
    }

    private static Umbral__c umbral(String operador, Decimal valor, String severidad) {
        return new Umbral__c(Tipo_Activo__c = 'TECHNICAL_ROOM', Tipo_Medicion__c = 'TEMPERATURE', Operador__c = operador,
            Valor__c = valor, Unidad_Esperada__c = 'CELSIUS', Severidad__c = severidad, Activo__c = true);
    }
}
