/**
 * Clasifica cada Senial_Sensor__e contra los Umbral__c activos y elige una ganadora
 * por activo + tipo de medición con el desempate de D003. Todavía no escribe registros.
 */
public with sharing class SenialSensorHandler {
    private static final String MENSAJE_CONECTIVIDAD = 'CONNECTIVITY';
    private static final String MEDICION_CONECTIVIDAD = 'CAMERA_CONNECTIVITY';
    private static final String UNIDAD_CONECTIVIDAD = 'SECONDS';
    private static final String FORMATO_ISO = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';
    private static final List<String> SEVERIDADES_EN_ORDEN = new List<String>{ 'Invalida', 'Critica', 'Advertencia' };
    private static final Map<String, String> LIMITE_POR_SEVERIDAD = new Map<String, String>{
        'Invalida' => 'de rango físico',
        'Critica' => 'crítico',
        'Advertencia' => 'de advertencia'
    };
    private static final Map<String, String> VERBO_POR_OPERADOR = new Map<String, String>{
        'LT' => 'queda bajo',
        'LE' => 'alcanza',
        'GT' => 'supera',
        'GE' => 'alcanza'
    };

    @TestVisible
    private static Integer senialesRecibidas = 0;
    @TestVisible
    private static Map<String, Clasificacion> clasificacionPorMessageId = new Map<String, Clasificacion>();
    @TestVisible
    private static Map<String, Clasificacion> ganadoraPorClave = new Map<String, Clasificacion>();

    /**
     * @param seniales Lote entregado por SenialSensorTrigger (hasta 200 eventos).
     */
    public void procesar(List<Senial_Sensor__e> seniales) {
        senialesRecibidas += seniales.size();
        System.debug(LoggingLevel.INFO, 'SenialSensorHandler recibió ' + seniales.size() + ' señales');
        if (seniales.isEmpty()) {
            return;
        }

        Map<String, List<Umbral__c>> umbralesPorTipo = consultarUmbrales();
        List<Clasificacion> clasificaciones = new List<Clasificacion>();
        clasificacionPorMessageId = new Map<String, Clasificacion>();
        for (Senial_Sensor__e senial : seniales) {
            Clasificacion clasificacion = clasificar(senial, umbralesPorTipo);
            clasificaciones.add(clasificacion);
            clasificacionPorMessageId.put(clasificacion.messageId, clasificacion);
            System.debug(LoggingLevel.INFO, 'Señal ' + clasificacion.messageId + ' ' + clasificacion.clave + ': '
                + clasificacion.estado + ' (nivel ' + clasificacion.nivel + ') ' + clasificacion.motivo);
        }

        ganadoraPorClave = elegirGanadoras(clasificaciones);
        for (String clave : ganadoraPorClave.keySet()) {
            Clasificacion ganadora = ganadoraPorClave.get(clave);
            System.debug(LoggingLevel.INFO, 'Ganadora ' + clave + ': ' + ganadora.messageId + ' '
                + ganadora.estado + ' (nivel ' + ganadora.nivel + ', occurredAt ' + ganadora.occurredAt.formatGmt(FORMATO_ISO) + ')');
        }
    }

    private static Map<String, List<Umbral__c>> consultarUmbrales() {
        Map<String, List<Umbral__c>> umbralesPorTipo = new Map<String, List<Umbral__c>>();
        // SYSTEM_MODE: la ingesta corre como Automated Process y no puede depender de los permisos del operador.
        for (Umbral__c umbral : [
            SELECT Tipo_Activo__c, Tipo_Medicion__c, Operador__c, Valor__c, Unidad_Esperada__c, Severidad__c, Severidad_Nivel__c
            FROM Umbral__c
            WHERE Activo__c = true
            WITH SYSTEM_MODE
            ORDER BY Name
        ]) {
            String tipo = umbral.Tipo_Activo__c + '|' + umbral.Tipo_Medicion__c;
            if (!umbralesPorTipo.containsKey(tipo)) {
                umbralesPorTipo.put(tipo, new List<Umbral__c>());
            }
            umbralesPorTipo.get(tipo).add(umbral);
        }
        return umbralesPorTipo;
    }

    private static Clasificacion clasificar(Senial_Sensor__e senial, Map<String, List<Umbral__c>> umbralesPorTipo) {
        Boolean esConectividad = senial.Message_Type__c == MENSAJE_CONECTIVIDAD;
        String medicion = esConectividad ? MEDICION_CONECTIVIDAD : senial.Measurement_Type__c;
        String valorTexto = esConectividad ? senial.Gap_Seconds__c : senial.Value__c;
        String unidad = esConectividad ? UNIDAD_CONECTIVIDAD : senial.Unit__c;

        Clasificacion resultado = new Clasificacion();
        resultado.messageId = senial.Message_Id__c;
        resultado.clave = senial.Asset_Id__c + '|' + medicion;
        resultado.valor = convertirDecimal(valorTexto);
        resultado.occurredAt = convertirFecha(senial.Occurred_At__c);

        if (resultado.valor == null) {
            return resultado.marcar('DatoInvalido', null, 'Valor ausente o no numérico: ' + valorTexto);
        }
        if (resultado.occurredAt == null) {
            return resultado.marcar('DatoInvalido', null, 'occurredAt ausente o no ISO 8601: ' + senial.Occurred_At__c);
        }
        String lectura = medicion + ' ' + resultado.valor + ' ' + unidad;

        List<Umbral__c> umbrales = umbralesPorTipo.get(senial.Asset_Type__c + '|' + medicion);
        if (umbrales == null) {
            return resultado.marcar('SinUmbral', null, 'No hay umbral activo para ' + senial.Asset_Type__c + ' ' + medicion);
        }
        List<Umbral__c> umbralesDeLaUnidad = new List<Umbral__c>();
        for (Umbral__c umbral : umbrales) {
            if (umbral.Unidad_Esperada__c == unidad) {
                umbralesDeLaUnidad.add(umbral);
            }
        }
        if (umbralesDeLaUnidad.isEmpty()) {
            return resultado.marcar('MedicionIncompatible', null,
                lectura + ' no está en la unidad esperada ' + umbrales[0].Unidad_Esperada__c);
        }

        for (String severidad : SEVERIDADES_EN_ORDEN) {
            for (Umbral__c umbral : umbralesDeLaUnidad) {
                if (umbral.Severidad__c == severidad && cumple(resultado.valor, umbral)) {
                    return resultado.marcar(severidad, umbral.Severidad_Nivel__c?.intValue(),
                        lectura + ' ' + VERBO_POR_OPERADOR.get(umbral.Operador__c) + ' el límite '
                        + LIMITE_POR_SEVERIDAD.get(severidad) + ' ' + umbral.Operador__c + ' ' + umbral.Valor__c.stripTrailingZeros().toPlainString());
                }
            }
        }
        return resultado.marcar('Normal', 0, lectura + ' dentro de los límites');
    }

    private static Boolean cumple(Decimal valor, Umbral__c umbral) {
        switch on umbral.Operador__c {
            when 'LT' {
                return valor < umbral.Valor__c;
            }
            when 'LE' {
                return valor <= umbral.Valor__c;
            }
            when 'GT' {
                return valor > umbral.Valor__c;
            }
            when 'GE' {
                return valor >= umbral.Valor__c;
            }
            when else {
                return false;
            }
        }
    }

    private static Map<String, Clasificacion> elegirGanadoras(List<Clasificacion> clasificaciones) {
        Map<String, Clasificacion> ganadoras = new Map<String, Clasificacion>();
        for (Clasificacion candidata : clasificaciones) {
            if (candidata.nivel == null) {
                continue;
            }
            Clasificacion actual = ganadoras.get(candidata.clave);
            if (actual == null || candidata.ganaA(actual)) {
                ganadoras.put(candidata.clave, candidata);
            }
        }
        return ganadoras;
    }

    private static Decimal convertirDecimal(String texto) {
        if (String.isBlank(texto)) {
            return null;
        }
        try {
            return Decimal.valueOf(texto.trim());
        } catch (TypeException e) {
            return null;
        }
    }

    private static Datetime convertirFecha(String texto) {
        if (String.isBlank(texto)) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize('"' + texto.trim() + '"', Datetime.class);
        } catch (JSONException e) {
            return null;
        }
    }

    @TestVisible
    private class Clasificacion {
        public String messageId;
        public String clave;
        public Decimal valor;
        public Datetime occurredAt;
        public String estado;
        public Integer nivel;
        public String motivo;

        public Clasificacion marcar(String estado, Integer nivel, String motivo) {
            this.estado = estado;
            this.nivel = nivel;
            this.motivo = motivo;
            return this;
        }

        // compareTo y no <: en String el < de Apex depende del locale del usuario y no distingue mayúsculas.
        public Boolean ganaA(Clasificacion otra) {
            if (occurredAt != otra.occurredAt) {
                return occurredAt > otra.occurredAt;
            }
            if (nivel != otra.nivel) {
                return nivel > otra.nivel;
            }
            return (messageId ?? '').compareTo(otra.messageId ?? '') < 0;
        }
    }
}
