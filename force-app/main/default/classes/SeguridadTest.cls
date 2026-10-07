/**
 * Security matrix (BR-208, BR-210, T8.5). One user per real persona permission set (Nova_Casa_Operator,
 * Nova_Casa_Coordinator, Nova_Casa_Gerente, Nova_Casa_Admin) on the Minimum Access profile, exercised with System.runAs.
 * Widening or dropping a permission in any of those sets fails a test here. Expectations come from docs/acceso.md.
 * What other classes already cover (ingestion user, behavior of the controllers) is not repeated: this class asserts
 * object/field access, custom permissions, class access, and that nobody but Admin carries View All / Modify All.
 * No callouts: IngestaController is only called with a refused or invalid request, or to read status.
 */
@isTest
private class SeguridadTest {

    private static final String OPERADOR = 'Nova_Casa_Operator';
    private static final String COORDINADOR = 'Nova_Casa_Coordinator';
    private static final String GERENTE = 'Nova_Casa_Gerente';
    private static final String ADMIN = 'Nova_Casa_Admin';

    private static final String PERM_CREAR = 'Nova_Casa_Crear_Intervencion';
    private static final String PERM_SEGUIR = 'Nova_Casa_Seguir_Intervencion';
    private static final String PERM_TRAER = 'Nova_Casa_Traer_Senales';

    private static final List<String> OBJETOS_NOVA = new List<String>{
        'Account', 'Asset', 'Case', 'Contact', 'Lectura_Vigente__c', 'Log_Senial__c', 'Umbral__c'
    };
    private static final List<String> OBJETOS_DE_LECTURA = new List<String>{
        'Account', 'Asset', 'Case', 'Contact', 'Lectura_Vigente__c'
    };

    @TestSetup
    static void crearUsuarios() {
        crearUsuario('segoper', OPERADOR);
        crearUsuario('segcoor', COORDINADOR);
        crearUsuario('seggere', GERENTE);
        crearUsuario('segadmi', ADMIN);
    }

    // ─── (a) Log_Senial__c: only Admin ─────────────────────────────────────

    @IsTest
    static void soloAdminTieneAccesoALogSenial() {
        Map<String, String> acceso = new Map<String, String>();
        Map<String, String> reintento = new Map<String, String>();
        for (String conjunto : new List<String>{ OPERADOR, COORDINADOR, GERENTE, ADMIN }) {
            System.runAs(usuario(conjunto)) {
                acceso.put(conjunto, accesoAObjeto('Log_Senial__c'));
                reintento.put(conjunto, accesoACampo('Log_Senial__c', 'Reintento_Seguro__c'));
            }
        }

        for (String conjunto : new List<String>{ OPERADOR, COORDINADOR, GERENTE }) {
            Assert.areEqual('----', acceso.get(conjunto), conjunto + ' no debe tener ningun acceso a Log_Senial__c');
            Assert.areEqual('--', reintento.get(conjunto), conjunto + ' no debe leer ni editar Reintento_Seguro__c');
        }
        Assert.areEqual('ACUD', acceso.get(ADMIN), 'Admin conserva CRUD sobre Log_Senial__c');
        Assert.areEqual('AU', reintento.get(ADMIN), 'Solo Admin lee y edita Reintento_Seguro__c');
    }

    @IsTest
    static void ningunConjuntoDeUsuarioPermiteEditarElLogNiLoMuestraAlGerente() {
        // Misma regla a nivel de metadata (ObjectPermissions / FieldPermissions), sin depender del describe.
        for (String conjunto : new List<String>{ OPERADOR, COORDINADOR, GERENTE }) {
            Id conjuntoId = conjuntoPorNombre(conjunto).Id;
            Assert.areEqual(0, [SELECT COUNT() FROM ObjectPermissions WHERE ParentId = :conjuntoId AND SobjectType = 'Log_Senial__c'],
                conjunto + ' no debe declarar permisos de objeto sobre Log_Senial__c');
            Assert.areEqual(0, [SELECT COUNT() FROM FieldPermissions WHERE ParentId = :conjuntoId AND SobjectType = 'Log_Senial__c'],
                conjunto + ' no debe declarar FLS sobre Log_Senial__c');
        }
        Id adminId = conjuntoPorNombre(ADMIN).Id;
        List<FieldPermissions> reintento = [
            SELECT PermissionsRead, PermissionsEdit FROM FieldPermissions
            WHERE ParentId = :adminId AND Field = 'Log_Senial__c.Reintento_Seguro__c'
        ];
        Assert.areEqual(1, reintento.size(), 'Admin debe declarar FLS sobre Reintento_Seguro__c');
        Assert.isTrue(reintento[0].PermissionsRead && reintento[0].PermissionsEdit, 'Admin edita Reintento_Seguro__c');
    }

    // ─── (b) CRUD matrix of the persona sets ───────────────────────────────

    @IsTest
    static void gerenteEsSoloLecturaEnLosObjetosDeNovaCasa() {
        System.runAs(usuario(GERENTE)) {
            for (String objeto : OBJETOS_DE_LECTURA) {
                Assert.areEqual('A---', accesoAObjeto(objeto), 'Gerente: solo lectura (sin create/update/delete) en ' + objeto);
            }
            Assert.areEqual('----', accesoAObjeto('Umbral__c'), 'Gerente no tiene acceso a Umbral__c');
        }
    }

    @IsTest
    static void operadorEsSoloLecturaYSinUmbrales() {
        System.runAs(usuario(OPERADOR)) {
            for (String objeto : OBJETOS_DE_LECTURA) {
                Assert.areEqual('A---', accesoAObjeto(objeto), 'Operador: solo lectura en ' + objeto);
            }
            Assert.areEqual('----', accesoAObjeto('Umbral__c'), 'Operador no tiene acceso a Umbral__c');
        }
    }

    @IsTest
    static void coordinadorSoloEditaCasosYGestionaUmbrales() {
        System.runAs(usuario(COORDINADOR)) {
            for (String objeto : new List<String>{ 'Account', 'Asset', 'Contact', 'Lectura_Vigente__c' }) {
                Assert.areEqual('A---', accesoAObjeto(objeto), 'Coordinador: solo lectura en ' + objeto);
            }
            Assert.areEqual('A-U-', accesoAObjeto('Case'), 'Coordinador edita Case, no lo crea ni lo borra');
            Assert.areEqual('ACU-', accesoAObjeto('Umbral__c'), 'Coordinador crea y edita Umbral__c, no lo borra');
        }
    }

    @IsTest
    static void adminTieneCrudCompletoEnLosObjetosDeNovaCasa() {
        System.runAs(usuario(ADMIN)) {
            for (String objeto : OBJETOS_NOVA) {
                Assert.areEqual('ACUD', accesoAObjeto(objeto), 'Admin: CRUD completo en ' + objeto);
            }
        }
    }

    @IsTest
    static void gerenteSoloLeeLosCamposQueDeclara() {
        // FLS: ningun campo editable en el set del gerente (docs/acceso.md: "Nada editable").
        Id gerenteId = conjuntoPorNombre(GERENTE).Id;
        Assert.areEqual(0, [SELECT COUNT() FROM FieldPermissions WHERE ParentId = :gerenteId AND PermissionsEdit = true],
            'Nova_Casa_Gerente no debe tener ningun campo editable');
        Assert.isTrue([SELECT COUNT() FROM FieldPermissions WHERE ParentId = :gerenteId AND PermissionsRead = true] > 0,
            'Nova_Casa_Gerente debe seguir leyendo los campos de la pantalla');
    }

    // ─── (c) IngestaController only with the real Admin set ────────────────

    @IsTest
    static void traerSenalesYEstadoSoloFuncionanConElPermissionSetDeAdmin() {
        Map<String, String> errorAlTraer = new Map<String, String>();
        Map<String, String> errorDeEstado = new Map<String, String>();
        for (String conjunto : new List<String>{ OPERADOR, COORDINADOR, GERENTE }) {
            System.runAs(usuario(conjunto)) {
                // Escenario valido: el rechazo debe ser por permiso, no por el escenario.
                errorAlTraer.put(conjunto, errorDeTraer('MIXED'));
                errorDeEstado.put(conjunto, errorDeEstado());
            }
        }
        for (String conjunto : new List<String>{ OPERADOR, COORDINADOR, GERENTE }) {
            Assert.areEqual(IngestaController.NO_PERMISSION, errorAlTraer.get(conjunto), conjunto + ' no puede traer senales');
            Assert.areEqual(IngestaController.NO_PERMISSION, errorDeEstado.get(conjunto), conjunto + ' no puede leer el estado de la ingesta');
        }
        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'TelemetriaIngesta'],
            'Un rechazo por permiso no debe encolar la ingesta');

        // Admin pasa la compuerta de permiso: con un escenario invalido el error cambia a INVALID_SCENARIO.
        String adminTraer;
        IngestaController.Estado estado;
        System.runAs(usuario(ADMIN)) {
            adminTraer = errorDeTraer('NO_EXISTE');
            estado = IngestaController.estadoIngesta(null);
        }
        Assert.areEqual(IngestaController.INVALID_SCENARIO, adminTraer, 'Admin pasa el permiso y solo falla por el escenario');
        Assert.isNotNull(estado, 'Admin lee el estado de la ingesta');
        Assert.isFalse(estado.enCurso, 'Sin ingesta encolada no hay una en curso');
    }

    @IsTest
    static void soloAdminTieneElPermisoPersonalizadoDeTraerSenalesYLaClase() {
        Map<String, Boolean> permisos = new Map<String, Boolean>();
        for (String conjunto : new List<String>{ OPERADOR, COORDINADOR, GERENTE, ADMIN }) {
            System.runAs(usuario(conjunto)) {
                permisos.put(conjunto, FeatureManagement.checkPermission(PERM_TRAER));
            }
        }
        Assert.isFalse(permisos.get(OPERADOR), 'Operador no trae senales');
        Assert.isFalse(permisos.get(COORDINADOR), 'Coordinador no trae senales');
        Assert.isFalse(permisos.get(GERENTE), 'Gerente no trae senales');
        Assert.isTrue(permisos.get(ADMIN), 'Admin trae senales');

        assertMismoConjunto(new List<String>{ ADMIN }, conjuntosConAccesoALaClase('IngestaController'),
            'Solo Nova_Casa_Admin da acceso a IngestaController');
    }

    // ─── (d) custom permissions of the screen ──────────────────────────────

    @IsTest
    static void lasCustomPermissionsDeIntervencionSonLasAcordadasPorPersona() {
        Map<String, List<Boolean>> obtenido = new Map<String, List<Boolean>>();
        for (String conjunto : new List<String>{ OPERADOR, COORDINADOR, GERENTE, ADMIN }) {
            System.runAs(usuario(conjunto)) {
                obtenido.put(conjunto, new List<Boolean>{
                    FeatureManagement.checkPermission(PERM_CREAR),
                    FeatureManagement.checkPermission(PERM_SEGUIR),
                    FeatureManagement.checkPermission(PERM_TRAER)
                });
            }
        }
        // [crear, seguir, traer]
        assertPermisos(OPERADOR, obtenido.get(OPERADOR), true, false, false);
        assertPermisos(COORDINADOR, obtenido.get(COORDINADOR), true, true, false);
        assertPermisos(GERENTE, obtenido.get(GERENTE), false, false, false);
        assertPermisos(ADMIN, obtenido.get(ADMIN), true, true, true);
    }

    @IsTest
    static void elAccesoALasClasesDeLaPantallaSigueLaMatriz() {
        assertMismoConjunto(new List<String>{ OPERADOR, COORDINADOR, GERENTE, ADMIN }, conjuntosConAccesoALaClase('ActivosOperadorController'),
            'Los cuatro ven la pantalla de activos');
        assertMismoConjunto(new List<String>{ OPERADOR, COORDINADOR, ADMIN }, conjuntosConAccesoALaClase('IntervencionOperadorController'),
            'El gerente no tiene acceso a IntervencionOperadorController');
    }

    // ─── (e) nobody but Admin with View All / Modify All ───────────────────

    @IsTest
    static void ningunConjuntoDeUsuarioTieneViewAllNiModifyAllSalvoAdmin() {
        for (String conjunto : new List<String>{ OPERADOR, COORDINADOR, GERENTE }) {
            User persona = usuario(conjunto);
            // Todo lo que le llega al usuario: el set de la persona y el del perfil (IsOwnedByProfile).
            List<PermissionSetAssignment> asignaciones = [
                SELECT PermissionSetId, PermissionSet.Name, PermissionSet.IsOwnedByProfile,
                    PermissionSet.PermissionsViewAllData, PermissionSet.PermissionsModifyAllData
                FROM PermissionSetAssignment WHERE AssigneeId = :persona.Id
            ];
            Assert.isFalse(asignaciones.isEmpty(), 'El usuario ' + conjunto + ' debe tener asignaciones');
            Set<Id> ids = new Set<Id>();
            for (PermissionSetAssignment asignacion : asignaciones) {
                ids.add(asignacion.PermissionSetId);
                Assert.isFalse(asignacion.PermissionSet.PermissionsViewAllData, conjunto + ': ViewAllData en ' + asignacion.PermissionSet.Name);
                Assert.isFalse(asignacion.PermissionSet.PermissionsModifyAllData, conjunto + ': ModifyAllData en ' + asignacion.PermissionSet.Name);
            }
            Assert.isTrue(ids.contains(conjuntoPorNombre(conjunto).Id), conjunto + ' debe estar asignado a su usuario');

            List<ObjectPermissions> permisos = [
                SELECT SobjectType, PermissionsViewAllRecords, PermissionsModifyAllRecords, PermissionsDelete
                FROM ObjectPermissions WHERE ParentId IN :ids AND SobjectType IN :OBJETOS_NOVA
            ];
            Assert.isFalse(permisos.isEmpty(), conjunto + ' debe declarar permisos de objeto');
            for (ObjectPermissions permiso : permisos) {
                Assert.isFalse(permiso.PermissionsViewAllRecords, conjunto + ': ViewAllRecords sobre ' + permiso.SobjectType);
                Assert.isFalse(permiso.PermissionsModifyAllRecords, conjunto + ': ModifyAllRecords sobre ' + permiso.SobjectType);
                Assert.isFalse(permiso.PermissionsDelete, conjunto + ': Delete sobre ' + permiso.SobjectType);
            }
        }
    }

    @IsTest
    static void adminConservaViewAllYModifyAllSobreLosObjetosDeNovaCasa() {
        Id adminId = conjuntoPorNombre(ADMIN).Id;
        Map<String, ObjectPermissions> porObjeto = new Map<String, ObjectPermissions>();
        for (ObjectPermissions permiso : [
            SELECT SobjectType, PermissionsViewAllRecords, PermissionsModifyAllRecords
            FROM ObjectPermissions WHERE ParentId = :adminId AND SobjectType IN :OBJETOS_NOVA
        ]) {
            porObjeto.put(permiso.SobjectType, permiso);
        }
        for (String objeto : OBJETOS_NOVA) {
            Assert.isTrue(porObjeto.containsKey(objeto), 'Admin debe declarar permisos sobre ' + objeto);
            Assert.isTrue(porObjeto.get(objeto).PermissionsViewAllRecords, 'Admin: ViewAllRecords sobre ' + objeto);
            Assert.isTrue(porObjeto.get(objeto).PermissionsModifyAllRecords, 'Admin: ModifyAllRecords sobre ' + objeto);
        }
    }

    @IsTest
    static void elGerenteNoLeeLosRegistrosDeOtroSinJerarquia() {
        // Sin View All, el gerente fuera de la jerarquia no ve un edificio ajeno (OWD Private, D022); el admin si.
        Account ajeno;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ajeno = new Account(Name = 'Edificio ajeno seguridad', External_Id__c = 'BLD-SEG-AJENO');
            insert ajeno;
        }
        Integer vistosPorGerente;
        Integer vistosPorAdmin;
        System.runAs(usuarioSinRol(GERENTE)) {
            vistosPorGerente = [SELECT COUNT() FROM Account WHERE Id = :ajeno.Id WITH USER_MODE];
        }
        System.runAs(usuarioSinRol(ADMIN)) {
            vistosPorAdmin = [SELECT COUNT() FROM Account WHERE Id = :ajeno.Id WITH USER_MODE];
        }
        Assert.areEqual(0, vistosPorGerente, 'Gerente sin jerarquia y sin View All no ve un edificio ajeno');
        Assert.areEqual(1, vistosPorAdmin, 'Admin (View All) si lo ve');
    }

    // ─── Helpers ───────────────────────────────────────────────────────────

    private static void assertMismoConjunto(List<String> esperado, Set<String> obtenido, String mensaje) {
        Assert.areEqual(esperado.size(), obtenido.size(), mensaje + ' (obtenido: ' + obtenido + ')');
        for (String nombre : esperado) {
            Assert.isTrue(obtenido.contains(nombre), mensaje + ': falta ' + nombre);
        }
    }

    private static void assertPermisos(String conjunto, List<Boolean> obtenido, Boolean crear, Boolean seguir, Boolean traer) {
        Assert.areEqual(crear, obtenido[0], conjunto + ': ' + PERM_CREAR);
        Assert.areEqual(seguir, obtenido[1], conjunto + ': ' + PERM_SEGUIR);
        Assert.areEqual(traer, obtenido[2], conjunto + ': ' + PERM_TRAER);
    }

    // "ACUD": Accessible, Createable, Updateable, Deletable of the running user; '-' where false.
    private static String accesoAObjeto(String objeto) {
        Schema.SObjectType tipo = Schema.getGlobalDescribe().get(objeto);
        Assert.isNotNull(tipo, 'El objeto ' + objeto + ' debe existir');
        Schema.DescribeSObjectResult d = tipo.getDescribe();
        return (d.isAccessible() ? 'A' : '-') + (d.isCreateable() ? 'C' : '-') + (d.isUpdateable() ? 'U' : '-') + (d.isDeletable() ? 'D' : '-');
    }

    // "AU": field Accessible and Updateable for the running user.
    private static String accesoACampo(String objeto, String campo) {
        Schema.DescribeFieldResult d = Schema.getGlobalDescribe().get(objeto).getDescribe().fields.getMap().get(campo).getDescribe();
        return (d.isAccessible() ? 'A' : '-') + (d.isUpdateable() ? 'U' : '-');
    }

    private static String errorDeTraer(String escenario) {
        try {
            IngestaController.traerSenales(escenario, 1, false);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static String errorDeEstado() {
        try {
            IngestaController.estadoIngesta(null);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    private static PermissionSet conjuntoPorNombre(String nombre) {
        List<PermissionSet> conjuntos = [SELECT Id, Name FROM PermissionSet WHERE Name = :nombre];
        Assert.areEqual(1, conjuntos.size(), nombre + ' debe estar desplegado en el org');
        return conjuntos[0];
    }

    // Persona sets (among the four) that grant the Apex class.
    private static Set<String> conjuntosConAccesoALaClase(String clase) {
        List<ApexClass> clases = [SELECT Id FROM ApexClass WHERE Name = :clase];
        Assert.areEqual(1, clases.size(), clase + ' debe existir');
        Map<Id, PermissionSet> conjuntos = new Map<Id, PermissionSet>([
            SELECT Id, Name FROM PermissionSet WHERE Name IN :new List<String>{ OPERADOR, COORDINADOR, GERENTE, ADMIN }
        ]);
        Set<String> resultado = new Set<String>();
        for (SetupEntityAccess acceso : [
            SELECT ParentId FROM SetupEntityAccess WHERE SetupEntityId = :clases[0].Id AND ParentId IN :conjuntos.keySet()
        ]) {
            resultado.add(conjuntos.get(acceso.ParentId).Name);
        }
        return resultado;
    }

    private static String apellido(String conjunto) {
        return conjunto == OPERADOR ? 'segoper' : conjunto == COORDINADOR ? 'segcoor' : conjunto == GERENTE ? 'seggere' : 'segadmi';
    }

    private static User usuario(String conjunto) {
        List<User> usuarios = [SELECT Id, LastName FROM User WHERE LastName = :apellido(conjunto) AND IsActive = true];
        Assert.areEqual(1, usuarios.size(), 'Debe existir el usuario de prueba de ' + conjunto);
        return usuarios[0];
    }

    // The same persona user without a role: outside the hierarchy of the building owner.
    private static User usuarioSinRol(String conjunto) {
        User u = usuario(conjunto);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = u.Id, UserRoleId = null);
        }
        return u;
    }

    private static void crearUsuario(String prefijo, String conjunto) {
        String sufijo = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');
        User u = new User(
            LastName = prefijo, Alias = prefijo.right(8), Email = prefijo + '@novacasa-test.example.com',
            Username = prefijo + '.' + sufijo + '@novacasa-test.example.com',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1].Id,
            TimeZoneSidKey = 'America/Bogota', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        Id conjuntoId = conjuntoPorNombre(conjunto).Id;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = conjuntoId);
        }
    }
}
