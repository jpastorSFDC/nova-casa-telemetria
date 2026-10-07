/**
 * Valida al guardar que los rangos de Umbral__c no se contradigan (US-204, D018).
 *
 * Regla (solo filas activas, misma combinación Tipo_Activo + Tipo_Medicion + Unidad_Esperada):
 * la banda Advertencia debe poder alcanzarse. Como el clasificador aplica la mayor severidad que se
 * cumple, una Advertencia queda inalcanzable si todo valor que la cumple también cumple la Crítica.
 *   - Dirección superior (GT/GE): la Crítica no puede ser menos exigente que la Advertencia.
 *     Es contradictoria si crítica.valor < advertencia.valor, o si son iguales y la Crítica cubre
 *     todo lo que cubre la Advertencia (mismo operador, o Crítica GE frente a Advertencia GT).
 *   - Dirección inferior (LT/LE): simétrico (crítica.valor > advertencia.valor, o igual y cubre).
 *   - Pares de distinta dirección (p. ej. Advertencia GT con Crítica LT) y la severidad Invalida
 *     no se comparan: son rechazos o bandas opuestas, no se tapan entre sí.
 *
 * Sharing: with sharing. Los umbrales son visibles para quien los edita (OWD de Umbral__c Read o
 * Read/Write, docs/acceso.md), así que la consulta ve las mismas filas que el usuario. La consulta
 * usa el modo por defecto de Apex (sin filtro de FLS) a propósito: para detectar una contradicción
 * hacen falta Severidad__c, Operador__c y Valor__c aunque el usuario no tenga FLS sobre ellos.
 */
public with sharing class UmbralValidador {
    private static final String ADVERTENCIA = 'Advertencia';
    private static final String CRITICA = 'Critica';
    private static final Set<String> SUPERIORES = new Set<String>{ 'GT', 'GE' };
    private static final Set<String> INFERIORES = new Set<String>{ 'LT', 'LE' };

    /** Punto de entrada del trigger: una consulta por lote, sin DML, acepta hasta 200 filas. */
    public static void validar(List<Umbral__c> nuevos) {
        List<Umbral__c> aValidar = new List<Umbral__c>();
        Set<Id> idsEnLote = new Set<Id>();
        Set<String> tiposActivo = new Set<String>();
        Set<String> tiposMedicion = new Set<String>();
        for (Umbral__c umbral : nuevos) {
            if (umbral.Id != null) {
                idsEnLote.add(umbral.Id);
            }
            if (participa(umbral)) {
                aValidar.add(umbral);
                tiposActivo.add(umbral.Tipo_Activo__c);
                tiposMedicion.add(umbral.Tipo_Medicion__c);
            }
        }
        if (aValidar.isEmpty()) {
            return;
        }

        // Grupos por combinación: las filas del lote primero, luego las ya guardadas.
        Map<String, List<Umbral__c>> grupos = new Map<String, List<Umbral__c>>();
        for (Umbral__c umbral : aValidar) {
            agregar(grupos, umbral);
        }
        // Las filas que se están editando se excluyen: su valor nuevo es el del lote, no el guardado.
        for (Umbral__c existente : [
            SELECT Name, Tipo_Activo__c, Tipo_Medicion__c, Unidad_Esperada__c, Severidad__c, Operador__c, Valor__c, Activo__c
            FROM Umbral__c
            WHERE Activo__c = true
            AND Tipo_Activo__c IN :tiposActivo
            AND Tipo_Medicion__c IN :tiposMedicion
            AND Id NOT IN :idsEnLote
        ]) {
            if (participa(existente)) {
                agregar(grupos, existente);
            }
        }

        for (Umbral__c umbral : aValidar) {
            for (Umbral__c otro : grupos.get(clave(umbral))) {
                if (otro === umbral) {
                    continue;
                }
                Umbral__c adv = umbral.Severidad__c == ADVERTENCIA ? umbral : otro;
                Umbral__c cri = umbral.Severidad__c == ADVERTENCIA ? otro : umbral;
                if (adv.Severidad__c == ADVERTENCIA && cri.Severidad__c == CRITICA
                    && advertenciaInalcanzable(adv, cri)) {
                    // Un error por fila (el del primer contrario): construir el mensaje por cada par
                    // agotaba el CPU con lotes grandes y contradictorios entre sí.
                    umbral.addError(mensaje(adv, cri));
                    break;
                }
            }
        }
    }

    /** True si la Crítica cubre todo valor que cumple la Advertencia (misma dirección). */
    @TestVisible
    private static Boolean advertenciaInalcanzable(Umbral__c adv, Umbral__c cri) {
        Boolean superior = SUPERIORES.contains(adv.Operador__c) && SUPERIORES.contains(cri.Operador__c);
        Boolean inferior = INFERIORES.contains(adv.Operador__c) && INFERIORES.contains(cri.Operador__c);
        if (!superior && !inferior) {
            return false;
        }
        if (cri.Valor__c == adv.Valor__c) {
            // Mismo límite: la Crítica cubre la Advertencia si es igual de inclusiva o más.
            return cri.Operador__c == adv.Operador__c
                || cri.Operador__c == 'GE'
                || cri.Operador__c == 'LE';
        }
        return superior ? cri.Valor__c < adv.Valor__c : cri.Valor__c > adv.Valor__c;
    }

    private static Boolean participa(Umbral__c umbral) {
        return umbral.Activo__c == true
            && umbral.Tipo_Activo__c != null
            && umbral.Tipo_Medicion__c != null
            && umbral.Operador__c != null
            && umbral.Valor__c != null
            && (umbral.Severidad__c == ADVERTENCIA || umbral.Severidad__c == CRITICA);
    }

    private static String clave(Umbral__c umbral) {
        return umbral.Tipo_Activo__c + '|' + umbral.Tipo_Medicion__c + '|' + umbral.Unidad_Esperada__c;
    }

    private static void agregar(Map<String, List<Umbral__c>> grupos, Umbral__c umbral) {
        String clave = clave(umbral);
        if (!grupos.containsKey(clave)) {
            grupos.put(clave, new List<Umbral__c>());
        }
        grupos.get(clave).add(umbral);
    }

    private static String describir(Umbral__c umbral) {
        String nombre = String.isBlank(umbral.Name) ? 'fila nueva o en edición' : umbral.Name;
        return nombre + ' (' + umbral.Severidad__c + ' ' + umbral.Operador__c + ' '
            + umbral.Valor__c.stripTrailingZeros().toPlainString() + ')';
    }

    private static String mensaje(Umbral__c adv, Umbral__c cri) {
        String direccion = SUPERIORES.contains(adv.Operador__c) ? 'GT/GE' : 'LT/LE';
        String exigencia = direccion == 'GT/GE'
            ? 'el límite crítico debe ser mayor o igual que el de advertencia'
            : 'el límite crítico debe ser menor o igual que el de advertencia';
        return 'Umbral contradictorio para ' + adv.Tipo_Activo__c + ' ' + adv.Tipo_Medicion__c
            + ': la Advertencia ' + describir(adv) + ' nunca se alcanzaría porque la Crítica '
            + describir(cri) + ' se cumple antes. Regla ' + direccion + ': ' + exigencia
            + ' (si son iguales, la Crítica no puede ser igual o más inclusiva que la Advertencia).';
    }
}
