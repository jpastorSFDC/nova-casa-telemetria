/**
 * Keeps the simulator session between ingestion runs (HP-05, D025): the cursor of the next page to read, and the
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
    // Suffix of the "the stream ended on the saved cursor" marker, kept next to the cursor so the next run knows its
    // first page is a re-poll of an already-exhausted stream (D040). Alphanumeric like the cursor key it extends.
    @TestVisible
    private static final String SUFIJO_FIN = 'fin';
    // "Automatic ingestion is scheduled" marker (D040). Every scheduled run refreshes it, so the TTL only has to
    // outlive a few missed runs (3 x 5 min, above the 300 s minimum); a lost marker comes back on the next run.
    @TestVisible
    private static final String CLAVE_PROGRAMACION = 'ingestaprogramada';
    @TestVisible
    private static final Integer TTL_PROGRAMACION_SEGUNDOS = 900;

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
        limpiarFinDeFlujo(clave); // a cleared session carries no end-of-stream marker (D040)
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

    /**
     * Marks that the stream ended on the cursor saved under `clave`, so the next run treats its first page as a
     * re-poll of an exhausted stream (D040). The marker shares the cursor's TTL; nothing sensitive is stored.
     */
    public static Boolean guardarFinDeFlujo(String clave) {
        return escribir(claveFin(clave), '1', TTL_CURSOR_SEGUNDOS);
    }

    /** True when the saved cursor of `clave` is a re-poll of a stream that already ended (D040). */
    public static Boolean flujoTerminadoGuardado(String clave) {
        return String.isNotBlank(leer(claveFin(clave)));
    }

    /** Clears the end-of-stream marker: the stream continued, so the next page is genuinely new (D040). */
    public static void limpiarFinDeFlujo(String clave) {
        if (simularNoDisponible || String.isBlank(clave)) {
            return;
        }
        String claveMarca = claveFin(clave);
        if (memoriaDePrueba != null) {
            memoriaDePrueba.remove(claveMarca);
            return;
        }
        Cache.OrgPartition p = particion();
        if (p == null) {
            return;
        }
        try {
            p.remove(claveMarca);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'SesionSimulador: no se pudo limpiar la marca de fin (' + e.getTypeName() + ')');
        }
    }

    private static String claveFin(String clave) {
        return String.isBlank(clave) ? clave : clave + SUFIJO_FIN;
    }

    /** Counters of the last run, as the JSON of TelemetriaIngesta.Resumen (no cursor). */
    public static Boolean guardarResumen(String resumenJson) {
        return escribir(CLAVE_RESUMEN, resumenJson, TTL_RESUMEN_SEGUNDOS);
    }

    public static String leerResumen() {
        return leer(CLAVE_RESUMEN);
    }

    /**
     * Marks that the automatic ingestion is scheduled, with its scenario (D040). The panel reads this instead of
     * the scheduled-job tables, which the Nova_Casa_Admin persona cannot read (no View Setup). The scenario is not a
     * secret. @return false when it could not be saved (cache unavailable)
     */
    public static Boolean guardarProgramacion(String escenario) {
        return escribir(CLAVE_PROGRAMACION, escenario, TTL_PROGRAMACION_SEGUNDOS);
    }

    /** The scenario of the scheduled automatic ingestion, or null when there is no marker or no cache. */
    public static String leerProgramacion() {
        return leer(CLAVE_PROGRAMACION);
    }

    public static void borrarProgramacion() {
        quitar(CLAVE_PROGRAMACION);
    }

    // ─── Private helpers ─────────────────────────────────────────────────

    private static void quitar(String clave) {
        if (simularNoDisponible || String.isBlank(clave)) {
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
            System.debug(LoggingLevel.WARN, 'SesionSimulador: no se pudo quitar una marca (' + e.getTypeName() + ')');
        }
    }

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
