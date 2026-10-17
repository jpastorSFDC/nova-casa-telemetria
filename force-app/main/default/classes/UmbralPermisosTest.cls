/**
 * BR-204 / BR-210: los permission sets REALES deciden quién edita los umbrales.
 * Cada prueba corre como un usuario de prueba con solo el conjunto del rol y usa DML / SOQL en
 * modo usuario, de modo que CRUD y FLS cuentan. Si se quita el permiso al rol, la prueba falla.
 * Los usuarios se crean con el perfil Minimum Access para que el único acceso venga del conjunto.
 * La edición de un límite que cambia la clasificación sin tocar código ya la cubre
 * SenialSensorHandlerTest.editarElLimiteDeUnUmbralCambiaLaClasificacionSinTocarElHistorico.
 */
@IsTest
private class UmbralPermisosTest {
    @IsTest
    static void coordinadorInsertaUnUmbralValido() {
        User coordinador = crearUsuario('umbcoord1', 'Nova_Casa_Coordinator');
        Umbral__c umbral = umbral('GT', 30, 'Advertencia');

        System.runAs(coordinador) {
            Database.SaveResult resultado = Database.insert(umbral, AccessLevel.USER_MODE);
            Assert.isTrue(resultado.isSuccess(), 'El Coordinador debe poder crear un umbral válido');
        }

        List<Umbral__c> guardados = [SELECT Valor__c, Severidad__c, Operador__c, Activo__c FROM Umbral__c];
        Assert.areEqual(1, guardados.size(), 'Debe quedar un umbral guardado');
        Assert.areEqual(30, guardados[0].Valor__c, 'Valor guardado');
        Assert.areEqual('Advertencia', guardados[0].Severidad__c, 'Severidad guardada');
        Assert.isTrue(guardados[0].Activo__c, 'El umbral queda activo');
    }

    @IsTest
    static void coordinadorActualizaUnUmbralExistente() {
        User coordinador = crearUsuario('umbcoord2', 'Nova_Casa_Coordinator');
        Umbral__c existente = umbral('GT', 30, 'Advertencia');
        insert existente;

        System.runAs(coordinador) {
            Umbral__c editado = [SELECT Id, Valor__c FROM Umbral__c WHERE Id = :existente.Id WITH USER_MODE];
            editado.Valor__c = 32;
            editado.Activo__c = false;
            Database.SaveResult resultado = Database.update(editado, AccessLevel.USER_MODE);
            Assert.isTrue(resultado.isSuccess(), 'El Coordinador debe poder editar el límite y el estado de un umbral');
        }

        Umbral__c guardado = [SELECT Valor__c, Activo__c FROM Umbral__c WHERE Id = :existente.Id];
        Assert.areEqual(32, guardado.Valor__c, 'El nuevo límite se guarda');
        Assert.isFalse(guardado.Activo__c, 'El nuevo estado se guarda');
    }

    @IsTest
    static void coordinadorSigueSujetoAlValidadorDeContradicciones() {
        User coordinador = crearUsuario('umbcoord3', 'Nova_Casa_Coordinator');
        insert umbral('GT', 30, 'Advertencia');
        // Crítica GT 20 haría inalcanzable la Advertencia GT 30 (D018).
        Umbral__c contradictorio = umbral('GT', 20, 'Critica');

        Boolean rechazado = false;
        System.runAs(coordinador) {
            try {
                Database.insert(contradictorio, AccessLevel.USER_MODE);
            } catch (DmlException e) {
                rechazado = true;
                Assert.isTrue(e.getMessage().contains('contradictorio'), 'Debe rechazarlo el validador: ' + e.getMessage());
            }
        }
        Assert.isTrue(rechazado, 'El permiso de crear no exime de la validación');
        Assert.areEqual(1, [SELECT COUNT() FROM Umbral__c], 'No se guarda el umbral contradictorio');
    }

    @IsTest
    static void coordinadorNoPuedeEliminarUnUmbral() {
        User coordinador = crearUsuario('umbcoord4', 'Nova_Casa_Coordinator');
        Umbral__c existente = umbral('GT', 30, 'Advertencia');
        insert existente;

        Boolean rechazado = false;
        System.runAs(coordinador) {
            try {
                Database.delete(existente, AccessLevel.USER_MODE);
            } catch (Exception e) {
                rechazado = denegadoPorPermiso(e);
            }
        }
        Assert.isTrue(rechazado, 'El Coordinador no tiene Delete sobre Umbral__c');
        Assert.areEqual(1, [SELECT COUNT() FROM Umbral__c WHERE Id = :existente.Id], 'El umbral sigue existiendo');
    }

    @IsTest
    static void operadorNoPuedeInsertarNiLeerUmbrales() {
        User operador = crearUsuario('umboper1', 'Nova_Casa_Operator');
        insert umbral('GT', 30, 'Advertencia');

        Boolean insertRechazado = false;
        Boolean lecturaRechazada = false;
        System.runAs(operador) {
            try {
                Database.insert(umbral('GT', 40, 'Critica'), AccessLevel.USER_MODE);
            } catch (Exception e) {
                insertRechazado = denegadoPorPermiso(e);
            }
            try {
                List<Umbral__c> visibles = [SELECT Id FROM Umbral__c WITH USER_MODE];
                Assert.areEqual(0, visibles.size(), 'No debe ver umbrales');
            } catch (Exception e) {
                lecturaRechazada = denegadoPorPermiso(e);
            }
        }
        Assert.isTrue(insertRechazado, 'El Operador no puede crear umbrales');
        Assert.isTrue(lecturaRechazada, 'El Operador no tiene Read sobre Umbral__c');
        Assert.areEqual(1, [SELECT COUNT() FROM Umbral__c], 'Solo existe el umbral sembrado');
    }

    @IsTest
    static void gerenteNoPuedeInsertarNiActualizarUmbrales() {
        User gerente = crearUsuario('umbgeren1', 'Nova_Casa_Gerente');
        Umbral__c existente = umbral('GT', 30, 'Advertencia');
        insert existente;

        Boolean insertRechazado = false;
        Boolean updateRechazado = false;
        System.runAs(gerente) {
            try {
                Database.insert(umbral('GT', 40, 'Critica'), AccessLevel.USER_MODE);
            } catch (Exception e) {
                insertRechazado = denegadoPorPermiso(e);
            }
            try {
                Database.update(new Umbral__c(Id = existente.Id, Valor__c = 99), AccessLevel.USER_MODE);
            } catch (Exception e) {
                updateRechazado = denegadoPorPermiso(e);
            }
        }
        Assert.isTrue(insertRechazado, 'El Gerente no puede crear umbrales');
        Assert.isTrue(updateRechazado, 'El Gerente no puede editar umbrales');
        Assert.areEqual(1, [SELECT COUNT() FROM Umbral__c], 'No se creó ningún umbral');
        Assert.areEqual(30, [SELECT Valor__c FROM Umbral__c WHERE Id = :existente.Id].Valor__c, 'El límite no cambió');
    }

    // USER_MODE reports a missing permission with a different exception depending on the operation: SecurityException
    // (entity access denied on insert/update/query) or TypeException (delete not allowed). Anything else, such as a
    // validation error, is not a permission denial and must not make these tests pass.
    private static Boolean denegadoPorPermiso(Exception e) {
        return e instanceof SecurityException || e instanceof TypeException || e instanceof QueryException;
    }

    private static Umbral__c umbral(String operador, Decimal valor, String severidad) {
        return new Umbral__c(Tipo_Activo__c = 'TECHNICAL_ROOM', Tipo_Medicion__c = 'TEMPERATURE', Operador__c = operador,
            Valor__c = valor, Unidad_Esperada__c = 'CELSIUS', Severidad__c = severidad, Activo__c = true);
    }

    private static User crearUsuario(String prefijo, String conjuntoNombre) {
        String sufijo = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');
        User usuario = new User(
            LastName = prefijo, Alias = prefijo.right(8), Email = prefijo + '@novacasa-test.example.com',
            Username = prefijo + '.' + sufijo + '@novacasa-test.example.com',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1].Id,
            TimeZoneSidKey = 'America/Bogota', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        Id conjuntoId = [SELECT Id FROM PermissionSet WHERE Name = :conjuntoNombre LIMIT 1].Id;
        // Objetos de configuración en su propio contexto para evitar MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert usuario;
            insert new PermissionSetAssignment(AssigneeId = usuario.Id, PermissionSetId = conjuntoId);
        }
        return usuario;
    }
}
