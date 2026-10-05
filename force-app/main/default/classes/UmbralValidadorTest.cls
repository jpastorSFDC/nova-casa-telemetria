/**
 * Pruebas de UmbralValidador / UmbralTrigger (US-204, D018): un umbral Advertencia no puede quedar
 * inalcanzable porque la Crítica de la misma combinación se cumple siempre antes.
 */
@IsTest
private class UmbralValidadorTest {

    // ─── Helpers ─────────────────────────────────────────────────────────

    private static Umbral__c umbral(String severidad, String operador, Decimal valor) {
        return umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS', severidad, operador, valor, true);
    }

    private static Umbral__c umbral(String tipoActivo, String tipoMedicion, String unidad, String severidad,
        String operador, Decimal valor, Boolean activo) {
        return new Umbral__c(Tipo_Activo__c = tipoActivo, Tipo_Medicion__c = tipoMedicion, Unidad_Esperada__c = unidad,
            Severidad__c = severidad, Operador__c = operador, Valor__c = valor, Activo__c = activo);
    }

    private static void assertRechazado(Database.SaveResult resultado, String contexto) {
        Assert.isFalse(resultado.isSuccess(), contexto + ': debía rechazarse');
    }

    private static String mensaje(Database.SaveResult resultado) {
        Assert.isFalse(resultado.getErrors().isEmpty(), 'Se esperaba al menos un error');
        return resultado.getErrors()[0].getMessage();
    }

    /** Inserta la lista y exige que falle completa (all-or-none); devuelve el mensaje del error. */
    private static String insertarYEsperarError(List<Umbral__c> umbrales) {
        try {
            insert umbrales;
        } catch (DmlException e) {
            return e.getMessage();
        }
        Assert.fail('Se esperaba un DmlException por umbral contradictorio');
        return null;
    }

    // ─── (1) Dirección superior rechazada ────────────────────────────────

    @IsTest
    static void rechazaAdvertenciaGt40ConCriticaGt35AlInsertarEnAmbosOrdenes() {
        for (Boolean advertenciaPrimero : new List<Boolean>{ true, false }) {
            Umbral__c advertencia = umbral('Advertencia', 'GT', 40);
            Umbral__c critica = umbral('Critica', 'GT', 35);
            List<Umbral__c> lote = advertenciaPrimero
                ? new List<Umbral__c>{ advertencia, critica }
                : new List<Umbral__c>{ critica, advertencia };

            String error = insertarYEsperarError(lote);

            String contexto = advertenciaPrimero ? 'Advertencia primero' : 'Crítica primero';
            Assert.isTrue(error.contains('Advertencia GT 40'), contexto + ': el mensaje debe nombrar la Advertencia GT 40: ' + error);
            Assert.isTrue(error.contains('Critica GT 35'), contexto + ': el mensaje debe nombrar la Crítica GT 35: ' + error);
            Assert.isTrue(error.contains('TECHNICAL_ROOM'), contexto + ': el mensaje debe nombrar el activo: ' + error);
            Assert.isTrue(error.contains('TEMPERATURE'), contexto + ': el mensaje debe nombrar la medición: ' + error);
            Assert.isTrue(error.contains('Regla GT/GE'), contexto + ': el mensaje debe citar la regla: ' + error);
            Assert.areEqual(0, [SELECT COUNT() FROM Umbral__c], contexto + ': no debe guardarse ninguna fila');
        }
    }

    // ─── (2) Casos válidos y conjunto de referencia ──────────────────────

    @IsTest
    static void guardaAdvertenciaGt30ConCriticaGt35() {
        insert new List<Umbral__c>{ umbral('Advertencia', 'GT', 30), umbral('Critica', 'GT', 35) };

        Assert.areEqual(2, [SELECT COUNT() FROM Umbral__c], 'El par válido GT 30 / GT 35 debe guardarse');
    }

    @IsTest
    static void guardaElConjuntoDeReferenciaQueSiembraCatalogoService() {
        List<Umbral__c> referencia = new List<Umbral__c>();
        referencia.addAll(reglas('TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS', new List<List<Object>>{
            new List<Object>{ 'Advertencia', 'LT', 18 }, new List<Object>{ 'Advertencia', 'GT', 30 },
            new List<Object>{ 'Critica', 'LT', 15 }, new List<Object>{ 'Critica', 'GT', 35 },
            new List<Object>{ 'Invalida', 'LE', -11 }, new List<Object>{ 'Invalida', 'GE', 81 }
        }));
        referencia.addAll(reglas('WATER_PUMP', 'WATER_PRESSURE', 'BAR', new List<List<Object>>{
            new List<Object>{ 'Advertencia', 'LT', 2.5 }, new List<Object>{ 'Advertencia', 'GT', 4 },
            new List<Object>{ 'Critica', 'LT', 1.5 }, new List<Object>{ 'Critica', 'GT', 5 },
            new List<Object>{ 'Invalida', 'GT', 20 }
        }));
        referencia.addAll(reglas('WATER_METER', 'WATER_CONSUMPTION', 'LITER_PER_15_MIN', new List<List<Object>>{
            new List<Object>{ 'Advertencia', 'GT', 400 }, new List<Object>{ 'Critica', 'GT', 650 },
            new List<Object>{ 'Invalida', 'LT', 0 }, new List<Object>{ 'Invalida', 'GT', 5000 }
        }));
        referencia.addAll(reglas('ENERGY_METER', 'ENERGY_CONSUMPTION', 'KWH_PER_15_MIN', new List<List<Object>>{
            new List<Object>{ 'Advertencia', 'GT', 40 }, new List<Object>{ 'Critica', 'GT', 65 },
            new List<Object>{ 'Invalida', 'LT', 0 }, new List<Object>{ 'Invalida', 'GT', 1000 }
        }));
        referencia.addAll(reglas('SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 'SECONDS', new List<List<Object>>{
            new List<Object>{ 'Advertencia', 'GT', 90 }, new List<Object>{ 'Critica', 'GT', 180 }
        }));
        Assert.areEqual(21, referencia.size(), 'El conjunto de referencia tiene 21 reglas (igual que CatalogoServiceTest)');

        insert referencia;

        Assert.areEqual(21, [SELECT COUNT() FROM Umbral__c], 'Todo el conjunto de referencia debe guardarse en un solo DML');
    }

    private static List<Umbral__c> reglas(String tipoActivo, String tipoMedicion, String unidad, List<List<Object>> datos) {
        List<Umbral__c> resultado = new List<Umbral__c>();
        for (List<Object> dato : datos) {
            resultado.add(umbral(tipoActivo, tipoMedicion, unidad, (String) dato[0], (String) dato[1],
                (Decimal) Decimal.valueOf(String.valueOf(dato[2])), true));
        }
        return resultado;
    }

    // ─── (3) Dirección inferior ──────────────────────────────────────────

    @IsTest
    static void rechazaAdvertenciaLt15ConCriticaLt18() {
        String error = insertarYEsperarError(new List<Umbral__c>{ umbral('Advertencia', 'LT', 15), umbral('Critica', 'LT', 18) });

        Assert.isTrue(error.contains('Advertencia LT 15'), 'Debe nombrar la Advertencia LT 15: ' + error);
        Assert.isTrue(error.contains('Critica LT 18'), 'Debe nombrar la Crítica LT 18: ' + error);
        Assert.isTrue(error.contains('Regla LT/LE'), 'Debe citar la regla inferior: ' + error);
    }

    @IsTest
    static void guardaAdvertenciaLt18ConCriticaLt15() {
        insert new List<Umbral__c>{ umbral('Advertencia', 'LT', 18), umbral('Critica', 'LT', 15) };

        Assert.areEqual(2, [SELECT COUNT() FROM Umbral__c], 'El par válido LT 18 / LT 15 debe guardarse');
    }

    // ─── (4) Límites iguales ─────────────────────────────────────────────

    @IsTest
    static void rechazaLimitesIgualesEnLosCasosEnQueLaCriticaCubreLaAdvertencia() {
        List<List<Object>> contradictorios = new List<List<Object>>{
            new List<Object>{ 'GT', 'GT' }, new List<Object>{ 'GT', 'GE' }, new List<Object>{ 'GE', 'GE' },
            new List<Object>{ 'LT', 'LT' }, new List<Object>{ 'LT', 'LE' }, new List<Object>{ 'LE', 'LE' }
        };
        for (List<Object> par : contradictorios) {
            Database.SaveResult[] resultados = Database.insert(new List<Umbral__c>{
                umbral('Advertencia', (String) par[0], 40), umbral('Critica', (String) par[1], 40)
            }, false);
            assertRechazado(resultados[0], 'Advertencia ' + par[0] + ' 40 con Crítica ' + par[1] + ' 40 (Advertencia)');
            assertRechazado(resultados[1], 'Advertencia ' + par[0] + ' 40 con Crítica ' + par[1] + ' 40 (Crítica)');
        }
    }

    @IsTest
    static void permiteLimitesIgualesCuandoLaAdvertenciaEsMasInclusiva() {
        // Advertencia GE 40 + Crítica GT 40: el valor exacto 40 sigue siendo Advertencia. Simétrico en LE/LT.
        insert new List<Umbral__c>{
            umbral('Advertencia', 'GE', 40), umbral('Critica', 'GT', 40),
            umbral('TECHNICAL_ROOM', 'WATER_PRESSURE', 'BAR', 'Advertencia', 'LE', 10, true),
            umbral('TECHNICAL_ROOM', 'WATER_PRESSURE', 'BAR', 'Critica', 'LT', 10, true)
        };

        Assert.areEqual(4, [SELECT COUNT() FROM Umbral__c], 'GE 40 / GT 40 y LE 10 / LT 10 deben guardarse');
    }

    // ─── (5) Direcciones mixtas e Invalida ───────────────────────────────

    @IsTest
    static void ignoraParesDeDireccionMixta() {
        insert new List<Umbral__c>{
            umbral('Advertencia', 'GT', 40), umbral('Critica', 'LT', 50),
            umbral('TECHNICAL_ROOM', 'WATER_PRESSURE', 'BAR', 'Advertencia', 'LT', 10, true),
            umbral('TECHNICAL_ROOM', 'WATER_PRESSURE', 'BAR', 'Critica', 'GE', 5, true)
        };

        Assert.areEqual(4, [SELECT COUNT() FROM Umbral__c], 'Los pares de distinta dirección no se comparan');
    }

    @IsTest
    static void lasFilasInvalidaNuncaProducenError() {
        insert new List<Umbral__c>{ umbral('Advertencia', 'GT', 30), umbral('Critica', 'GT', 35) };

        // Invalida con valores que, de contar, "taparían" o serían tapados por las otras bandas.
        insert new List<Umbral__c>{
            umbral('Invalida', 'GT', 10), umbral('Invalida', 'GE', 30), umbral('Invalida', 'LE', 100),
            umbral('Invalida', 'LT', 35)
        };

        Assert.areEqual(6, [SELECT COUNT() FROM Umbral__c], 'Ninguna fila Invalida debe rechazarse');
    }

    // ─── (6) Combinaciones independientes y filas inactivas ──────────────

    @IsTest
    static void combinacionesDistintasNoInteractuan() {
        insert umbral('Advertencia', 'GT', 40);

        List<Umbral__c> otrasCombinaciones = new List<Umbral__c>{
            umbral('WATER_PUMP', 'TEMPERATURE', 'CELSIUS', 'Critica', 'GT', 35, true),
            umbral('TECHNICAL_ROOM', 'WATER_PRESSURE', 'CELSIUS', 'Critica', 'GT', 35, true),
            umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'BAR', 'Critica', 'GT', 35, true)
        };
        Database.SaveResult[] resultados = Database.insert(otrasCombinaciones, false);

        for (Integer i = 0; i < resultados.size(); i++) {
            Assert.isTrue(resultados[i].isSuccess(), 'La combinación distinta #' + i + ' no debe interactuar: '
                + (resultados[i].isSuccess() ? '' : mensaje(resultados[i])));
        }
    }

    @IsTest
    static void ignoraLaFilaExistenteInactiva() {
        insert umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS', 'Critica', 'GT', 25, false);

        insert umbral('Advertencia', 'GT', 30);

        Assert.areEqual(2, [SELECT COUNT() FROM Umbral__c], 'Una Crítica inactiva no debe bloquear la Advertencia');
    }

    @IsTest
    static void permiteGuardarUnaFilaInactivaContradictoria() {
        insert umbral('Advertencia', 'GT', 30);

        insert umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS', 'Critica', 'GT', 25, false);

        Assert.areEqual(2, [SELECT COUNT() FROM Umbral__c], 'Una fila inactiva se guarda aunque contradiga a una activa');
    }

    // ─── (7) Actualizaciones ─────────────────────────────────────────────

    @IsTest
    static void rechazaUnaActualizacionQueCreaUnaContradiccion() {
        Umbral__c advertencia = umbral('Advertencia', 'GT', 30);
        Umbral__c critica = umbral('Critica', 'GT', 35);
        insert new List<Umbral__c>{ advertencia, critica };

        critica.Valor__c = 25;
        Database.SaveResult resultado = Database.update(critica, false);

        assertRechazado(resultado, 'Bajar la Crítica a GT 25 bajo la Advertencia GT 30');
        Assert.isTrue(mensaje(resultado).contains('Critica GT 25'), 'El mensaje debe mostrar el valor nuevo: ' + mensaje(resultado));
        Assert.areEqual(35, [SELECT Valor__c FROM Umbral__c WHERE Id = :critica.Id].Valor__c, 'El valor guardado no debe cambiar');
    }

    @IsTest
    static void permiteCambiarLosDosLimitesEnUnMismoLoteDeActualizacion() {
        Umbral__c advertencia = umbral('Advertencia', 'GT', 30);
        Umbral__c critica = umbral('Critica', 'GT', 35);
        insert new List<Umbral__c>{ advertencia, critica };

        // Validado contra lo guardado, la Advertencia 50 chocaría con la Crítica 35; el lote trae ambos valores nuevos.
        advertencia.Valor__c = 50;
        critica.Valor__c = 60;
        Database.SaveResult[] resultados = Database.update(new List<Umbral__c>{ advertencia, critica }, false);

        Assert.isTrue(resultados[0].isSuccess() && resultados[1].isSuccess(), 'El cambio conjunto de ambos límites debe guardarse');
        Assert.areEqual(50, [SELECT Valor__c FROM Umbral__c WHERE Id = :advertencia.Id].Valor__c, 'Advertencia actualizada');
        Assert.areEqual(60, [SELECT Valor__c FROM Umbral__c WHERE Id = :critica.Id].Valor__c, 'Crítica actualizada');
    }

    // ─── (8) Reactivación ────────────────────────────────────────────────

    @IsTest
    static void rechazaReactivarUnaFilaContradictoria() {
        insert umbral('Advertencia', 'GT', 30);
        Umbral__c critica = umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS', 'Critica', 'GT', 25, false);
        insert critica;

        critica.Activo__c = true;
        Database.SaveResult resultado = Database.update(critica, false);

        assertRechazado(resultado, 'Reactivar la Crítica GT 25 frente a la Advertencia GT 30');
        Assert.isFalse([SELECT Activo__c FROM Umbral__c WHERE Id = :critica.Id].Activo__c, 'La fila debe seguir inactiva');
    }

    @IsTest
    static void rechazaReactivarUnaAdvertenciaContradictoria() {
        insert umbral('Critica', 'GT', 35);
        Umbral__c advertencia = umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS', 'Advertencia', 'GT', 40, false);
        insert advertencia;

        advertencia.Activo__c = true;
        Database.SaveResult resultado = Database.update(advertencia, false);

        assertRechazado(resultado, 'Reactivar la Advertencia GT 40 frente a la Crítica GT 35');
    }

    // ─── (9) Lotes ───────────────────────────────────────────────────────

    @IsTest
    static void unaContradiccionDentroDelLoteMarcaAmbasFilas() {
        Database.SaveResult[] resultados = Database.insert(new List<Umbral__c>{
            umbral('Advertencia', 'GT', 40), umbral('Critica', 'GT', 35)
        }, false);

        assertRechazado(resultados[0], 'La Advertencia del par contradictorio');
        assertRechazado(resultados[1], 'La Crítica del par contradictorio');
        Assert.areEqual(0, [SELECT COUNT() FROM Umbral__c], 'Ninguna fila contradictoria debe guardarse');
    }

    @IsTest
    static void unLoteMixtoSoloMarcaLasFilasContradictorias() {
        Database.SaveResult[] resultados = Database.insert(new List<Umbral__c>{
            umbral('Advertencia', 'GT', 30), umbral('Critica', 'GT', 35),
            umbral('TECHNICAL_ROOM', 'WATER_PRESSURE', 'BAR', 'Advertencia', 'GT', 4, true),
            umbral('TECHNICAL_ROOM', 'WATER_PRESSURE', 'BAR', 'Critica', 'GT', 3, true),
            umbral('SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 'SECONDS', 'Critica', 'GT', 180, true)
        }, false);

        Assert.isTrue(resultados[0].isSuccess(), 'Advertencia válida');
        Assert.isTrue(resultados[1].isSuccess(), 'Crítica válida');
        assertRechazado(resultados[2], 'Advertencia contradictoria');
        assertRechazado(resultados[3], 'Crítica contradictoria');
        Assert.isTrue(resultados[4].isSuccess(), 'Fila ajena a la contradicción');
        Assert.areEqual(3, [SELECT COUNT() FROM Umbral__c], 'Solo se guardan las filas válidas');
    }

    @IsTest
    static void unaAdvertenciaNuevaContraUnaCriticaGuardadaMarcaSoloLaNueva() {
        Umbral__c guardada = umbral('Critica', 'GT', 35);
        insert guardada;

        Umbral__c nueva = umbral('Advertencia', 'GT', 40);
        Database.SaveResult resultado = Database.insert(nueva, false);

        assertRechazado(resultado, 'Advertencia GT 40 frente a la Crítica guardada GT 35');
        Assert.isTrue(mensaje(resultado).contains('Critica GT 35'), 'Debe nombrar la Crítica guardada: ' + mensaje(resultado));
        Assert.areEqual(1, [SELECT COUNT() FROM Umbral__c], 'La fila guardada no se toca');
    }

    // ─── (10) Bulk ───────────────────────────────────────────────────────

    @IsTest
    static void aceptaDoscientasFilasEnUnDmlConComoMaximoUnaConsulta() {
        List<List<String>> combinaciones = new List<List<String>>{
            new List<String>{ 'TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS' },
            new List<String>{ 'WATER_PUMP', 'WATER_PRESSURE', 'BAR' },
            new List<String>{ 'WATER_METER', 'WATER_CONSUMPTION', 'LITER_PER_15_MIN' },
            new List<String>{ 'ENERGY_METER', 'ENERGY_CONSUMPTION', 'KWH_PER_15_MIN' },
            new List<String>{ 'SECURITY_CAMERA', 'CAMERA_CONNECTIVITY', 'SECONDS' }
        };
        List<Umbral__c> lote = new List<Umbral__c>();
        for (Integer i = 0; i < 100; i++) {
            List<String> c = combinaciones[Math.mod(i, combinaciones.size())];
            lote.add(umbral(c[0], c[1], c[2], 'Advertencia', 'GT', 100 + i, true));
            lote.add(umbral(c[0], c[1], c[2], 'Critica', 'GT', 500 + i, true));
        }
        Assert.areEqual(200, lote.size(), 'El lote debe tener 200 filas');

        Integer consultasAntes = Limits.getQueries();
        Database.SaveResult[] resultados = Database.insert(lote, false);
        Integer consultas = Limits.getQueries() - consultasAntes;

        for (Integer i = 0; i < resultados.size(); i++) {
            Assert.isTrue(resultados[i].isSuccess(), 'La fila #' + i + ' debía guardarse');
        }
        Assert.isTrue(consultas <= 1, 'El validador debe hacer como máximo una consulta por lote, hizo ' + consultas);
        Assert.areEqual(200, [SELECT COUNT() FROM Umbral__c], 'Deben guardarse las 200 filas');
    }

    @IsTest
    static void doscientasFilasContradictoriasSeMarcanTodasSinExcederLimites() {
        List<Umbral__c> lote = new List<Umbral__c>();
        for (Integer i = 0; i < 100; i++) {
            lote.add(umbral('Advertencia', 'GT', 400 + i));
            lote.add(umbral('Critica', 'GT', 10 + i));
        }

        Integer consultasAntes = Limits.getQueries();
        Database.SaveResult[] resultados = Database.insert(lote, false);

        Assert.isTrue(Limits.getQueries() - consultasAntes <= 1, 'Como máximo una consulta');
        for (Integer i = 0; i < resultados.size(); i++) {
            Assert.isFalse(resultados[i].isSuccess(), 'La fila #' + i + ' es contradictoria y debía marcarse');
        }
    }

    // ─── (11) Null-safety ────────────────────────────────────────────────

    @IsTest
    static void filasSinValorOperadorOSeveridadNoLanzanExcepcionNiSeMarcan() {
        // Se invoca el validador sin DML: Valor, Operador y Severidad son obligatorios en el esquema.
        Umbral__c sinValor = umbral('Advertencia', 'GT', null);
        Umbral__c sinOperador = umbral('Critica', null, 35);
        Umbral__c sinSeveridad = umbral(null, 'GT', 35);
        Umbral__c sinTipoActivo = umbral(null, 'TEMPERATURE', 'CELSIUS', 'Critica', 'GT', 35, true);
        Umbral__c sinActivo = umbral('TECHNICAL_ROOM', 'TEMPERATURE', 'CELSIUS', 'Critica', 'GT', 35, null);
        Umbral__c sinUnidad = umbral('TECHNICAL_ROOM', 'TEMPERATURE', null, 'Advertencia', 'GT', 40, true);
        List<Umbral__c> lote = new List<Umbral__c>{ sinValor, sinOperador, sinSeveridad, sinTipoActivo, sinActivo, sinUnidad };

        UmbralValidador.validar(lote);

        for (Umbral__c fila : lote) {
            Assert.isFalse(fila.hasErrors(), 'Una fila incompleta no debe marcarse: ' + fila);
        }
    }

    @IsTest
    static void filasIncompletasNoAlteranLaValidacionDeLasFilasCompletas() {
        Umbral__c sinValor = umbral('Critica', 'GT', null);
        Umbral__c advertencia = umbral('Advertencia', 'GT', 40);
        Umbral__c critica = umbral('Critica', 'GT', 35);

        UmbralValidador.validar(new List<Umbral__c>{ sinValor, advertencia, critica });

        Assert.isFalse(sinValor.hasErrors(), 'La fila incompleta no se marca');
        Assert.isTrue(advertencia.hasErrors(), 'La Advertencia contradictoria sigue marcándose');
        Assert.isTrue(critica.hasErrors(), 'La Crítica contradictoria sigue marcándose');
    }

    @IsTest
    static void unLoteSinFilasParticipantesNoConsultaNada() {
        Integer consultasAntes = Limits.getQueries();

        UmbralValidador.validar(new List<Umbral__c>{ umbral('Invalida', 'GT', 10), umbral('Critica', 'GT', null) });

        Assert.areEqual(0, Limits.getQueries() - consultasAntes, 'Sin filas que validar no debe haber consulta');
    }

    // ─── (12) advertenciaInalcanzable (@TestVisible) ─────────────────────

    @IsTest
    static void advertenciaInalcanzableEnDireccionSuperior() {
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GT', 40), umbral('Critica', 'GT', 35)), 'GT 40 / GT 35');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GE', 40), umbral('Critica', 'GE', 35)), 'GE 40 / GE 35');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GT', 40), umbral('Critica', 'GE', 35)), 'GT 40 / GE 35');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GT', 40), umbral('Critica', 'GT', 40)), 'GT 40 / GT 40');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GE', 40), umbral('Critica', 'GE', 40)), 'GE 40 / GE 40');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GT', 40), umbral('Critica', 'GE', 40)), 'GT 40 / GE 40');
        Assert.isFalse(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GE', 40), umbral('Critica', 'GT', 40)), 'GE 40 / GT 40 es alcanzable (valor 40)');
        Assert.isFalse(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GT', 30), umbral('Critica', 'GT', 35)), 'GT 30 / GT 35');
        Assert.isFalse(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GE', 40), umbral('Critica', 'GT', 41)), 'GE 40 / GT 41');
    }

    @IsTest
    static void advertenciaInalcanzableEnDireccionInferior() {
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LT', 15), umbral('Critica', 'LT', 18)), 'LT 15 / LT 18');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LE', 15), umbral('Critica', 'LE', 18)), 'LE 15 / LE 18');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LT', 15), umbral('Critica', 'LE', 18)), 'LT 15 / LE 18');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LT', 15), umbral('Critica', 'LT', 15)), 'LT 15 / LT 15');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LE', 15), umbral('Critica', 'LE', 15)), 'LE 15 / LE 15');
        Assert.isTrue(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LT', 15), umbral('Critica', 'LE', 15)), 'LT 15 / LE 15');
        Assert.isFalse(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LE', 15), umbral('Critica', 'LT', 15)), 'LE 15 / LT 15 es alcanzable (valor 15)');
        Assert.isFalse(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LT', 18), umbral('Critica', 'LT', 15)), 'LT 18 / LT 15');
        Assert.isFalse(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LE', 15), umbral('Critica', 'LT', 14)), 'LE 15 / LT 14');
    }

    @IsTest
    static void advertenciaInalcanzableIgnoraDireccionesMixtas() {
        Assert.isFalse(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'GT', 40), umbral('Critica', 'LT', 50)), 'GT con LT');
        Assert.isFalse(UmbralValidador.advertenciaInalcanzable(umbral('Advertencia', 'LE', 10), umbral('Critica', 'GE', 5)), 'LE con GE');
    }
}
