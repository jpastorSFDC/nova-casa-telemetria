@IsTest
private class PermisosProcesamientoTest {
    private static final String CONJUNTO = 'Nova_Casa_Procesamiento';
    private static final String FUENTE = 'nova-casa-simulator';
    private static final String OCURRIDO = '2026-09-30T16:45:21.262Z';
    private static final String SALA = 'AST-BOG-TEMP-001';
    private static final String SALA_2 = 'AST-BOG-TEMP-002';
    private static final String ROL_INTEGRACION = 'Integracion_Telemetria';
    private static final String ROL_OPERADOR = 'Operador_Edificios';
    private static final String ROL_COORDINADOR = 'Coordinador_Mantenimiento';
    private static final String ROL_GERENTE = 'Gerente_Regional_Operaciones';

    @TestSetup
    static void crearCatalogoYUmbrales() {
        Account edificio = new Account(Name = 'Edificio Permisos Test', External_Id__c = 'BLD-PRM-001');
        insert edificio;
        insert new List<Asset>{
            new Asset(Name = SALA, AccountId = edificio.Id, External_Id__c = SALA, Tipo_Activo__c = 'TECHNICAL_ROOM'),
            new Asset(Name = SALA_2, AccountId = edificio.Id, External_Id__c = SALA_2, Tipo_Activo__c = 'TECHNICAL_ROOM')
        };
        insert new List<Umbral__c>{
            umbralDeTemperatura('GT', 30, 'Advertencia'),
            umbralDeTemperatura('GT', 35, 'Critica'),
            umbralDeTemperatura('LT', 15, 'Critica'),
            umbralDeTemperatura('GE', 81, 'Invalida'),
            umbralDeTemperatura('LE', -11, 'Invalida')
        };
    }

    @IsTest
    static void elConjuntoDeProcesamientoNoAmpliaPermisosMasAllaDeLoAcordado() {
        List<PermissionSet> conjuntos = [
            SELECT Id, PermissionsModifyAllData, PermissionsViewAllData FROM PermissionSet WHERE Name = :CONJUNTO
        ];
        Assert.areEqual(1, conjuntos.size(), 'Debe existir el permission set ' + CONJUNTO);
        Assert.isFalse(conjuntos[0].PermissionsModifyAllData, 'Se añadió ModifyAllData al conjunto de procesamiento');
        Assert.isFalse(conjuntos[0].PermissionsViewAllData, 'Se añadió ViewAllData al conjunto de procesamiento');

        Map<String, ObjectPermissions> porObjeto = new Map<String, ObjectPermissions>();
        for (ObjectPermissions permiso : [
            SELECT SobjectType, PermissionsCreate, PermissionsEdit, PermissionsDelete, PermissionsModifyAllRecords
            FROM ObjectPermissions WHERE ParentId = :conjuntos[0].Id
        ]) {
            porObjeto.put(permiso.SobjectType, permiso);
            Assert.isFalse(permiso.PermissionsDelete, 'Se añadió Delete sobre ' + permiso.SobjectType);
            Assert.isFalse(permiso.PermissionsModifyAllRecords, 'Se añadió ModifyAllRecords sobre ' + permiso.SobjectType);
        }

        for (String objeto : new List<String>{ 'Lectura_Vigente__c', 'Log_Senial__c', 'Case', 'Senial_Sensor__e' }) {
            Assert.isTrue(porObjeto.containsKey(objeto), 'Falta el permiso de objeto sobre ' + objeto);
            Assert.isTrue(porObjeto.get(objeto).PermissionsCreate, 'Falta el permiso Create sobre ' + objeto);
        }

        for (String objeto : new List<String>{ 'Lectura_Vigente__c', 'Log_Senial__c', 'Case' }) {
            Assert.isTrue(porObjeto.get(objeto).PermissionsEdit, 'Falta el permiso Edit sobre ' + objeto);
        }
        for (String objeto : new List<String>{ 'Account', 'Asset', 'Contact' }) {
            Assert.isTrue(porObjeto.containsKey(objeto), 'Falta el permiso de lectura sobre ' + objeto);
            Assert.isFalse(porObjeto.get(objeto).PermissionsCreate, 'Se añadió Create sobre ' + objeto);
            Assert.isFalse(porObjeto.get(objeto).PermissionsEdit, 'Se añadió Edit sobre ' + objeto);
        }

        Assert.isTrue(porObjeto.containsKey('Umbral__c'), 'Falta el permiso de lectura sobre Umbral__c');
        Assert.isFalse(porObjeto.get('Umbral__c').PermissionsCreate, 'Se añadió Create sobre Umbral__c');
        Assert.isFalse(porObjeto.get('Umbral__c').PermissionsEdit, 'Se añadió Edit sobre Umbral__c');
        Assert.isFalse(porObjeto.get('Umbral__c').PermissionsDelete, 'Se añadió Delete sobre Umbral__c');
    }

    @IsTest
    static void laIngestaCorreSinPermisosDeOperadorNiDeAdmin() {
        User usuario = crearUsuarioConSoloElConjunto();

        Test.startTest();
        System.runAs(usuario) {
            new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{
                medicion('msg_prm_normal', SALA, '25'),
                medicion('msg_prm_critica', SALA_2, '36')
            });
        }
        Test.stopTest();

        Log_Senial__c normal = filaLog(FUENTE + '|msg_prm_normal');
        Log_Senial__c critica = filaLog(FUENTE + '|msg_prm_critica');
        Assert.areEqual('Procesada', normal.Resultado__c, 'La señal normal debe quedar Procesada sin permisos de operador: ' + normal.Motivo__c);
        Assert.areEqual('Procesada', critica.Resultado__c, 'La señal crítica debe quedar Procesada sin permisos de operador: ' + critica.Motivo__c);
        Assert.isNull(normal.Caso__c, 'Una señal normal no abre intervención');
        Assert.isNotNull(critica.Caso__c, 'La señal crítica debe enlazar su Case');

        List<Case> casos = [SELECT Id, Origin, Priority FROM Case];
        Assert.areEqual(1, casos.size(), 'Exactamente un Case para el mensaje crítico');
        Assert.areEqual('Telemetria', casos[0].Origin, 'Origen del Case');
        Assert.areEqual('Critica', casos[0].Priority, 'Prioridad del Case');
        Assert.areEqual(casos[0].Id, critica.Caso__c, 'El log crítico enlaza el Case abierto');
        Assert.areEqual(2, [SELECT COUNT() FROM Lectura_Vigente__c], 'Se escribe una lectura vigente por activo');
    }

    @IsTest
    static void coordinadorYGerenteVenPorJerarquiaLoQueCreaLaIngesta() {
        // Dado un operador dueño del edificio y el usuario de ingesta en el rol Integración Telemetría (como en producción)
        User operador = crearUsuario('prmoperador', 'Nova_Casa_Operator', ROL_OPERADOR);
        User coordinador = crearUsuario('prmcoord', 'Nova_Casa_Coordinator', ROL_COORDINADOR);
        User gerente = crearUsuario('prmgerente', 'Nova_Casa_Gerente', ROL_GERENTE);
        User usuario = crearUsuarioConSoloElConjunto();
        update new Account(Id = [SELECT Id FROM Account WHERE External_Id__c = 'BLD-PRM-001'].Id, OwnerId = operador.Id);

        // Cuando la ingesta procesa una señal crítica
        Test.startTest();
        System.runAs(usuario) {
            new SenialSensorHandler().procesar(new List<Senial_Sensor__e>{ medicion('msg_prm_jerarquia', SALA, '36') });
        }
        Test.stopTest();

        // Entonces el Case y la lectura existen y pertenecen al usuario de ingesta, no a quien ve
        Assert.areEqual(1, [SELECT COUNT() FROM Case WHERE OwnerId = :usuario.Id], 'El Case lo crea el usuario de ingesta');
        Assert.areEqual(1, [SELECT COUNT() FROM Lectura_Vigente__c], 'La ingesta escribe la lectura vigente');
        // y coordinador y gerente los ven por la jerarquía de roles, sin ser dueños de nada
        for (User persona : new List<User>{ coordinador, gerente }) {
            Integer casos;
            Integer lecturas;
            System.runAs(persona) {
                casos = [SELECT COUNT() FROM Case WITH USER_MODE];
                lecturas = [SELECT COUNT() FROM Lectura_Vigente__c WITH USER_MODE];
            }
            Assert.areEqual(1, casos, 'El Case de ingesta debe verse por jerarquía: ' + persona.LastName);
            Assert.areEqual(1, lecturas, 'La lectura debe verse por jerarquía: ' + persona.LastName);
        }
    }

    private static User crearUsuario(String prefijo, String conjuntoNombre, String rol) {
        String sufijo = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');
        User usuario = new User(
            LastName = prefijo, Alias = prefijo.right(8), Email = prefijo + '@novacasa-test.example.com',
            Username = prefijo + '.' + sufijo + '@novacasa-test.example.com',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1].Id,
            UserRoleId = [SELECT Id FROM UserRole WHERE DeveloperName = :rol LIMIT 1].Id,
            TimeZoneSidKey = 'America/Bogota', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        Id conjuntoId = [SELECT Id FROM PermissionSet WHERE Name = :conjuntoNombre LIMIT 1].Id;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert usuario;
            insert new PermissionSetAssignment(AssigneeId = usuario.Id, PermissionSetId = conjuntoId);
        }
        return usuario;
    }

    private static User crearUsuarioConSoloElConjunto() {
        String sufijo = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User usuario = new User(
            FirstName = 'Procesamiento', LastName = 'Permisos', Alias = 'prm' + sufijo.left(5),
            Email = 'prm' + sufijo + '@example.com', Username = 'prm' + sufijo + '@novacasa.test.invalid',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id,
            TimeZoneSidKey = 'America/Bogota', LocaleSidKey = 'es_CO', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US',
            // Como en producción: bajo el Coordinador en la jerarquía, para que este vea lo que crea la ingesta.
            UserRoleId = [SELECT Id FROM UserRole WHERE DeveloperName = :ROL_INTEGRACION LIMIT 1].Id
        );
        Id conjuntoId = [SELECT Id FROM PermissionSet WHERE Name = :CONJUNTO LIMIT 1].Id;
        // Objetos de configuración: se insertan aparte, en un contexto propio, para evitar MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert usuario;
            insert new PermissionSetAssignment(AssigneeId = usuario.Id, PermissionSetId = conjuntoId);
        }
        return usuario;
    }

    private static Senial_Sensor__e medicion(String messageId, String assetId, String valor) {
        return new Senial_Sensor__e(Source__c = FUENTE, Message_Id__c = messageId, Message_Type__c = 'MEASUREMENT', Asset_Type__c = 'TECHNICAL_ROOM',
            Asset_Id__c = assetId, Sensor_Id__c = 'SNS-1', Measurement_Type__c = 'TEMPERATURE', Value__c = valor, Unit__c = 'CELSIUS',
            Occurred_At__c = OCURRIDO, Delivery_Id__c = 'dlv_1');
    }

    private static Umbral__c umbralDeTemperatura(String operador, Decimal valor, String severidad) {
        return new Umbral__c(Tipo_Activo__c = 'TECHNICAL_ROOM', Tipo_Medicion__c = 'TEMPERATURE', Operador__c = operador,
            Valor__c = valor, Unidad_Esperada__c = 'CELSIUS', Severidad__c = severidad, Activo__c = true);
    }

    private static Log_Senial__c filaLog(String identidad) {
        List<Log_Senial__c> filas = [
            SELECT Id, Resultado__c, Motivo__c, Caso__c FROM Log_Senial__c WHERE Identidad__c = :identidad
        ];
        Assert.areEqual(1, filas.size(), 'Debe existir exactamente una fila de log para ' + identidad);
        return filas[0];
    }
}
