/**
 * Keeps the simulator session between ingestion runs (HP-05, D024): the cursor of the next page to read, and the
 * counters of the last run. Both live in Platform Cache (org partition NovaCasaSimulador) with a TTL and never in a
 * record: the cursor is a secret (D013 point 2), so it is not written to an object, a Custom Setting or a log.
 *
 * Why: every POST /session restarts the simulator at its first message, so a run that opens a new session always
 * re-reads messages already stored. The simulator's own UI keeps ONE session and continues from the saved cursor;
 * this class lets TelemetriaIngesta do the same.
 *
 * Resilience: the cache can be missing (partition not deployed, no capacity allocated, platform error). Every
 * method then answers "nothing saved" instead of throwing, and TelemetriaIngesta opens a new session and reports it.
 *
 * Nothing here logs, returns in a message or serializes a cursor value. leerCursor is the only way to read one and
 * its only caller is TelemetriaIngesta. Platform Cache is readable by any Apex in the org (Visibility.NAMESPACE),
 * so the cursor is as protected as the code that can call this class.
 *
 * without sharing: the cache is not record data, there is nothing for sharing to filter.
 */
public without sharing class SesionSimulador {

    public static final String PARTICION = 'local.NovaCasaSimulador';

    // Platform Cache TTL is 300 s to 172800 s. A saved cursor lives a day: an expired simulator session answers
    // 409/410 and TelemetriaIngesta then clears it and opens a new one.
    @TestVisible
    private static final Integer TTL_CURSOR_SEGUNDOS = 86400;
    @TestVisible
    private static final Integer TTL_RESUMEN_SEGUNDOS = 3600;
    @TestVisible
    private static final String CLAVE_RESUMEN = 'ultimoresumen';

    // Test seams. Platform Cache does not hold data in Apex tests, so a test supplies a map instead.
    // In production both are left alone: memoriaDePrueba is null and simularNoDisponible is false.
    @TestVisible
    private static Map<String, String> memoriaDePrueba;
    @TestVisible
    private static Boolean simularNoDisponible = false;

    private static Cache.OrgPartition particionEnCache;
    private static Boolean particionResuelta = false;

    /**
     * Cache key of a session. Platform Cache keys must be alphanumeric, so the scenario, seed and batch size are
     * hashed: runs with different parameters do not share a stream.
     */
    public static String clave(String escenario, Integer semilla, Integer tamanoLote) {
        String base = (escenario == null ? '' : escenario) + '|' + semilla + '|' + tamanoLote;
        return 'ses' + EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(base))).left(32);
    }

    /** True when saved values can be read and written. */
    public static Boolean disponible() {
        if (simularNoDisponible) {
            return false;
        }
        return memoriaDePrueba != null || particion() != null;
    }

    /** The saved cursor, or null when there is none or the cache is unavailable. Sensitive: never log it. */
    public static String leerCursor(String clave) {
        return leer(clave);
    }

    /** @return false when the cursor could not be saved (cache unavailable) */
    public static Boolean guardar(String clave, String cursor) {
        return escribir(clave, cursor, TTL_CURSOR_SEGUNDOS);
    }

    public static void borrar(String clave) {
        if (simularNoDisponible) {
            return;
        }
        if (memoriaDePrueba != null) {
            memoriaDePrueba.remove(clave);
            return;
        }
        Cache.OrgPartition p = particion();
        if (p == null) {
            return;
        }
        try {
            p.remove(clave);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'SesionSimulador: no se pudo borrar la sesion (' + e.getTypeName() + ')');
        }
    }

    /** Counters of the last run, as the JSON of TelemetriaIngesta.Resumen (no cursor). */
    public static Boolean guardarResumen(String resumenJson) {
        return escribir(CLAVE_RESUMEN, resumenJson, TTL_RESUMEN_SEGUNDOS);
    }

    public static String leerResumen() {
        return leer(CLAVE_RESUMEN);
    }

    // ─── Private helpers ─────────────────────────────────────────────────

    private static String leer(String clave) {
        if (simularNoDisponible || String.isBlank(clave)) {
            return null;
        }
        if (memoriaDePrueba != null) {
            return memoriaDePrueba.get(clave);
        }
        Cache.OrgPartition p = particion();
        if (p == null) {
            return null;
        }
        try {
            Object valor = p.get(clave);
            return valor instanceof String ? (String) valor : null;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'SesionSimulador: no se pudo leer la sesion (' + e.getTypeName() + ')');
            return null;
        }
    }

    private static Boolean escribir(String clave, String valor, Integer ttlSegundos) {
        if (simularNoDisponible || String.isBlank(clave) || String.isBlank(valor)) {
            return false;
        }
        if (memoriaDePrueba != null) {
            memoriaDePrueba.put(clave, valor);
            return true;
        }
        Cache.OrgPartition p = particion();
        if (p == null) {
            return false;
        }
        try {
            p.put(clave, valor, ttlSegundos, Cache.Visibility.NAMESPACE, false);
            return true;
        } catch (Exception e) {
            // Only the type: the message could quote the value.
            System.debug(LoggingLevel.WARN, 'SesionSimulador: no se pudo guardar la sesion (' + e.getTypeName() + ')');
            return false;
        }
    }

    // The partition handle, or null when it does not exist or has no capacity. Resolved once per transaction.
    private static Cache.OrgPartition particion() {
        if (particionResuelta) {
            return particionEnCache;
        }
        particionResuelta = true;
        try {
            Cache.OrgPartition p = Cache.Org.getPartition(PARTICION);
            particionEnCache = p.isAvailable() ? p : null;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'SesionSimulador: la particion de cache no esta disponible (' + e.getTypeName() + ')');
            particionEnCache = null;
        }
        return particionEnCache;
    }
}
