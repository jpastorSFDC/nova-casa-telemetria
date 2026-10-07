/**
 * Tests for SesionSimulador (HP-05, D024). Platform Cache holds nothing in Apex tests, so the saved values go
 * through the memoriaDePrueba map; the real-cache path is only checked for "does not throw when unavailable".
 * Cursors are obviously fake placeholders.
 */
@isTest
private class SesionSimuladorTest {

    @isTest
    static void laClaveEsAlfanumericaEstableYCabeEnLaLlaveDeCache() {
        String clave = SesionSimulador.clave('QA_200', 42, 50);

        Assert.areEqual(clave, SesionSimulador.clave('QA_200', 42, 50));
        Assert.isTrue(clave.length() <= 50, 'Platform Cache keys are at most 50 characters');
        Assert.isTrue(Pattern.matches('[A-Za-z0-9]+', clave), 'Platform Cache keys must be alphanumeric');
        Assert.areNotEqual(clave, SesionSimulador.clave('QA_200', 43, 50));
        Assert.areNotEqual(clave, SesionSimulador.clave('MIXED', 42, 50));
        Assert.areNotEqual(clave, SesionSimulador.clave('QA_200', 42, 51));
        Assert.isFalse(clave.contains('QA_200'), 'The key does not spell out the parameters');
    }

    @isTest
    static void guardaLeeYBorraElCursor() {
        SesionSimulador.memoriaDePrueba = new Map<String, String>();
        String clave = SesionSimulador.clave('QA_200', null, 200);

        Assert.isNull(SesionSimulador.leerCursor(clave), 'Nothing saved yet');
        Assert.isTrue(SesionSimulador.guardar(clave, 'fake-cursor-1'));
        Assert.areEqual('fake-cursor-1', SesionSimulador.leerCursor(clave));
        Assert.isTrue(SesionSimulador.guardar(clave, 'fake-cursor-2'));
        Assert.areEqual('fake-cursor-2', SesionSimulador.leerCursor(clave), 'The latest cursor wins');
        SesionSimulador.borrar(clave);
        Assert.isNull(SesionSimulador.leerCursor(clave));
    }

    @isTest
    static void noGuardaUnCursorVacio() {
        SesionSimulador.memoriaDePrueba = new Map<String, String>();
        String clave = SesionSimulador.clave('QA_200', null, 200);

        Assert.isFalse(SesionSimulador.guardar(clave, null));
        Assert.isFalse(SesionSimulador.guardar(clave, ' '));
        Assert.isFalse(SesionSimulador.memoriaDePrueba.containsKey(clave));
    }

    @isTest
    static void sinCacheNadaLanzaYNadaSeGuarda() {
        SesionSimulador.simularNoDisponible = true;
        String clave = SesionSimulador.clave('QA_200', null, 200);

        Assert.isFalse(SesionSimulador.disponible());
        Assert.isFalse(SesionSimulador.guardar(clave, 'fake-cursor-1'));
        Assert.isNull(SesionSimulador.leerCursor(clave));
        SesionSimulador.borrar(clave);
        Assert.isFalse(SesionSimulador.guardarResumen('{}'));
        Assert.isNull(SesionSimulador.leerResumen());
    }

    @isTest
    static void laParticionRealAusenteNoLanzaYSeTrataComoNoDisponible() {
        // In a test the real partition holds nothing: either unavailable or empty, and never an exception.
        String clave = SesionSimulador.clave('QA_200', null, 200);

        SesionSimulador.disponible();
        Assert.isNull(SesionSimulador.leerCursor(clave));
        SesionSimulador.guardar(clave, 'fake-cursor-1');
        SesionSimulador.borrar(clave);
        Assert.isNull(SesionSimulador.leerCursor(clave), 'Nothing survives in a test');
    }

    @isTest
    static void elResumenSeGuardaAparteDelCursor() {
        SesionSimulador.memoriaDePrueba = new Map<String, String>();
        String clave = SesionSimulador.clave('QA_200', null, 200);
        SesionSimulador.guardar(clave, 'fake-cursor-1');

        Assert.isTrue(SesionSimulador.guardarResumen('{"paginas":2}'));

        Assert.areEqual('{"paginas":2}', SesionSimulador.leerResumen());
        Assert.areEqual('fake-cursor-1', SesionSimulador.leerCursor(clave), 'Saving the summary leaves the cursor alone');
    }

    @isTest
    static void soloLaIngestaPuedeLeerElCursorGuardado() {
        // Any Apex in the org's namespace can read Platform Cache, so the only guard is that no other class asks.
        // Fails if a new class calls SesionSimulador.leerCursor. The probe string is built so this file never
        // contains it literally.
        String sonda = 'SesionSimulador' + '.leerCursor';
        Set<String> permitidas = new Set<String>{
            'SesionSimulador', 'SesionSimuladorTest', 'TelemetriaIngesta', 'TelemetriaIngestaTest'
        };
        List<String> infractoras = new List<String>();
        for (ApexClass clase : [SELECT Name, Body FROM ApexClass WHERE NamespacePrefix = null]) {
            if (!permitidas.contains(clase.Name) && clase.Body != null && clase.Body.containsIgnoreCase(sonda)) {
                infractoras.add(clase.Name);
            }
        }
        Assert.isTrue(infractoras.isEmpty(), 'Only TelemetriaIngesta may read the saved cursor. Offenders: ' + infractoras);
    }
}
