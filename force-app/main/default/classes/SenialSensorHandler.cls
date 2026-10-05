/**
 * Clasifica cada Senial_Sensor__e contra los Umbral__c activos, elige una ganadora por activo + tipo
 * de medición con el desempate de D003 y persiste el resultado: Log_Senial__c (una fila por identidad
 * source + messageId), Lectura_Vigente__c (una fila por activo + medición) y, para las críticas
 * ganadoras, una intervención vía IntervencionService (D010, D011).
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
    private static final Set<String> ESTADOS_VALIDOS = new Set<String>{ 'Normal', 'Advertencia', 'Critica' };
    private static final String CRITICA = 'Critica';
    private static final String PUBLICADA = 'Publicada';
    private static final String FALLIDA = 'Fallida';
    private static final Integer MOTIVO_MAX = 255;
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
    // Señales críticas que ganaron, no son reenvío/conflicto/atrasadas y ya tienen Case.
    @TestVisible
    private static List<Clasificacion> criticasProcesadas = new List<Clasificacion>();
    // Resultado__c final que se envía al log por identidad (source|messageId).
    @TestVisible
    private static Map<String, String> resultadoPorIdentidad = new Map<String, String>();
    // Eventos sin source o messageId: no hay identidad, no se puede registrar en el log.
    @TestVisible
    private static Integer senialesSinIdentidad = 0;

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
            clasificacion.enriquecer(senial, huellaDe(senial));
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

        persistir(clasificaciones);
    }

    // ─── Persistencia (D011) ─────────────────────────────────────────────

    /**
     * Orden: 1) consultas (logs, activos, lecturas vigentes); 2) decisión en memoria por identidad y por clave;
     * 3) IntervencionService.abrir, una llamada; 4) upsert de Lectura_Vigente__c; 5) upsert de Log_Senial__c.
     * La lectura se escribe solo si su intervención existe (T5.16); el log se escribe al final para reflejar el resultado real.
     */
    private static void persistir(List<Clasificacion> clasificaciones) {
        criticasProcesadas = new List<Clasificacion>();
        resultadoPorIdentidad = new Map<String, String>();
        Set<String> identidades = new Set<String>();
        Set<String> activosExternos = new Set<String>();
        Set<String> claves = new Set<String>();
        List<Clasificacion> conIdentidad = new List<Clasificacion>();
        for (Clasificacion c : clasificaciones) {
            if (c.identidad == null) {
                senialesSinIdentidad++;
                continue;
            }
            conIdentidad.add(c);
            identidades.add(c.identidad);
            if (String.isNotBlank(c.assetExterno)) {
                activosExternos.add(c.assetExterno);
            }
            claves.add(c.clave);
        }
        if (conIdentidad.isEmpty()) {
            return;
        }

        Map<String, Log_Senial__c> logsPrevios = consultarLogs(identidades);
        Map<String, Asset> activos = consultarActivos(activosExternos);
        Map<String, Lectura_Vigente__c> vigentes = consultarVigentes(claves);

        Datetime ahora = Datetime.now();
        Map<String, Log_Senial__c> filaPorIdentidad = new Map<String, Log_Senial__c>();
        List<Log_Senial__c> filas = new List<Log_Senial__c>();
        Map<String, String> huellaConocida = new Map<String, String>();
        Map<String, Decimal> reenvios = new Map<String, Decimal>();
        Map<String, List<Clasificacion>> candidatasPorClave = new Map<String, List<Clasificacion>>();

        for (Clasificacion c : conIdentidad) {
            Log_Senial__c previo = logsPrevios.get(c.identidad);
            if (!huellaConocida.containsKey(c.identidad) && previo != null && previo.Resultado__c != PUBLICADA && previo.Resultado__c != FALLIDA) {
                huellaConocida.put(c.identidad, previo.Huella__c);
                reenvios.put(c.identidad, reenviosDe(previo));
            }

            if (huellaConocida.containsKey(c.identidad)) {
                // Misma identidad ya procesada (antes o antes en este lote): reenvío o conflicto, nunca estado nuevo.
                Log_Senial__c fila = filaPara(c.identidad, filaPorIdentidad, filas);
                String original = huellaConocida.get(c.identidad);
                if (String.isBlank(original) || original == c.huella) {
                    Decimal total = reenvios.get(c.identidad) + 1;
                    reenvios.put(c.identidad, total);
                    fila.Reenvios__c = total;
                    fila.Ultimo_Reenvio__c = ahora;
                    c.resultado = 'Reenvio';
                } else {
                    fila.Resultado__c = 'Conflicto';
                    fila.Motivo__c = 'Misma identidad con contenido distinto (huella) al ya procesado';
                    fila.Procesado_At__c = ahora;
                    c.resultado = 'Conflicto';
                }
                continue;
            }

            // Primer procesamiento (fila ausente, Publicada o Fallida): aquí sí se decide estado.
            huellaConocida.put(c.identidad, c.huella);
            reenvios.put(c.identidad, reenviosDe(previo));
            Asset activo = activos.get(c.assetExterno);
            Log_Senial__c fila = filaPara(c.identidad, filaPorIdentidad, filas);
            fila.Source__c = c.source;
            fila.Message_Id__c = c.messageId;
            fila.Message_Type__c = c.tipoMensaje;
            fila.Occurred_At__c = c.occurredAt;
            fila.Delivery_Id__c = c.deliveryId;
            fila.Huella__c = c.huella;
            fila.Procesado_At__c = ahora;
            fila.Asset__c = activo?.Id;
            if (!c.esValida()) {
                rechazar(c, fila, c.motivo);
            } else if (activo == null) {
                rechazar(c, fila, 'El activo ' + c.assetExterno + ' no existe en el catálogo');
            } else {
                fila.Resultado__c = 'Procesada';
                fila.Motivo__c = null;
                c.resultado = 'Procesada';
                if (!candidatasPorClave.containsKey(c.clave)) {
                    candidatasPorClave.put(c.clave, new List<Clasificacion>());
                }
                candidatasPorClave.get(c.clave).add(c);
            }
        }

        // Una ganadora por clave dentro del lote y luego contra la lectura vigente guardada; el resto queda como evidencia.
        List<Clasificacion> ganadoras = new List<Clasificacion>();
        for (String clave : candidatasPorClave.keySet()) {
            Clasificacion mejor = null;
            for (Clasificacion candidata : candidatasPorClave.get(clave)) {
                if (mejor == null || candidata.ganaA(mejor)) {
                    mejor = candidata;
                }
            }
            for (Clasificacion candidata : candidatasPorClave.get(clave)) {
                if (candidata !== mejor) {
                    marcarAtrasada(candidata, filaPorIdentidad.get(candidata.identidad),
                        'Superada en el lote por ' + mejor.identidad + ' (más reciente o gana el desempate D003)');
                }
            }
            Lectura_Vigente__c vigente = vigentes.get(clave);
            if (vigente != null && !mejor.ganaA(desdeVigente(vigente))) {
                marcarAtrasada(mejor, filaPorIdentidad.get(mejor.identidad),
                    'Más antigua que la lectura vigente ' + vigente.Identidad_Senal__c + ' o pierde el desempate D003');
                continue;
            }
            ganadoras.add(mejor);
        }

        // Una sola llamada por lote. Sin Case no hay lectura crítica (T5.16).
        List<IntervencionService.Solicitud> solicitudes = new List<IntervencionService.Solicitud>();
        for (Clasificacion ganadora : ganadoras) {
            if (ganadora.estado == CRITICA) {
                IntervencionService.Solicitud solicitud = new IntervencionService.Solicitud();
                solicitud.identidad = ganadora.identidad;
                solicitud.assetId = activos.get(ganadora.assetExterno).Id;
                solicitud.accountId = activos.get(ganadora.assetExterno).AccountId;
                solicitud.tipoMedicion = ganadora.medicion;
                solicitud.causa = ganadora.motivo;
                solicitudes.add(solicitud);
            }
        }
        IntervencionService.Resultado casos = solicitudes.isEmpty()
            ? new IntervencionService.Resultado() : IntervencionService.abrir(solicitudes);

        List<Clasificacion> aEscribir = new List<Clasificacion>();
        List<Lectura_Vigente__c> lecturas = new List<Lectura_Vigente__c>();
        for (Clasificacion ganadora : ganadoras) {
            if (ganadora.estado == CRITICA) {
                Id casoId = casos.casoPorIdentidad.get(ganadora.identidad);
                if (casoId == null || casos.errorPorIdentidad.containsKey(ganadora.identidad)) {
                    // Detalle del error solo a depuración: puede venir del DML (ver IntervencionService).
                    System.debug(LoggingLevel.WARN, 'Sin intervención para ' + ganadora.identidad);
                    marcarFallida(ganadora, filaPorIdentidad.get(ganadora.identidad), 'No se pudo abrir la intervención; la lectura no se aplicó');
                    continue;
                }
                filaPorIdentidad.get(ganadora.identidad).Caso__c = casoId;
            }
            aEscribir.add(ganadora);
            lecturas.add(new Lectura_Vigente__c(
                Clave__c = ganadora.clave,
                Asset__c = activos.get(ganadora.assetExterno).Id,
                Tipo_Medicion__c = ganadora.medicion,
                Unidad__c = ganadora.unidad,
                Valor__c = ganadora.valor,
                Occurred_At__c = ganadora.occurredAt,
                Severidad_Nivel__c = ganadora.nivel,
                Identidad_Senal__c = ganadora.identidad,
                Sensor_Id__c = ganadora.sensorId
            ));
        }

        if (!lecturas.isEmpty()) {
            List<Database.UpsertResult> resultados = Database.upsert(lecturas, Lectura_Vigente__c.Clave__c, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < resultados.size(); i++) {
                Clasificacion c = aEscribir[i];
                if (!resultados[i].isSuccess()) {
                    System.debug(LoggingLevel.WARN, 'Lectura no guardada ' + c.clave + ': ' + resultados[i].getErrors()[0].getMessage());
                    marcarFallida(c, filaPorIdentidad.get(c.identidad), 'No se pudo guardar la lectura vigente');
                } else if (c.estado == CRITICA) {
                    criticasProcesadas.add(c);
                }
            }
        }

        for (Log_Senial__c fila : filas) {
            if (fila.Resultado__c != null) {
                resultadoPorIdentidad.put(fila.Identidad__c, fila.Resultado__c);
            }
        }
        List<Database.UpsertResult> resultadosLog = Database.upsert(filas, Log_Senial__c.Identidad__c, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < resultadosLog.size(); i++) {
            if (!resultadosLog[i].isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'Log no guardado ' + filas[i].Identidad__c + ': ' + resultadosLog[i].getErrors()[0].getMessage());
            }
        }
    }

    // Representa la lectura ya guardada para compararla con D003.
    private static Clasificacion desdeVigente(Lectura_Vigente__c vigente) {
        Clasificacion c = new Clasificacion();
        c.identidad = vigente.Identidad_Senal__c;
        c.messageId = vigente.Identidad_Senal__c?.substringAfter('|');
        c.occurredAt = vigente.Occurred_At__c;
        c.nivel = vigente.Severidad_Nivel__c == null ? 0 : vigente.Severidad_Nivel__c.intValue();
        return c;
    }

    private static Decimal reenviosDe(Log_Senial__c log) {
        Decimal total = 0;
        if (log != null && log.Reenvios__c != null) {
            total = log.Reenvios__c;
        }
        return total;
    }

    private static Log_Senial__c filaPara(String identidad, Map<String, Log_Senial__c> filaPorIdentidad, List<Log_Senial__c> filas) {
        Log_Senial__c fila = filaPorIdentidad.get(identidad);
        if (fila == null) {
            fila = new Log_Senial__c(Identidad__c = identidad);
            filaPorIdentidad.put(identidad, fila);
            filas.add(fila);
        }
        return fila;
    }

    private static void rechazar(Clasificacion c, Log_Senial__c fila, String motivo) {
        fila.Resultado__c = 'Rechazada';
        fila.Motivo__c = recortar(motivo);
        c.resultado = 'Rechazada';
    }

    private static void marcarAtrasada(Clasificacion c, Log_Senial__c fila, String motivo) {
        if (fila.Resultado__c == 'Conflicto') {
            return; // un conflicto de contenido en el mismo lote prevalece sobre Atrasada
        }
        fila.Resultado__c = 'Atrasada';
        fila.Motivo__c = recortar(motivo);
        c.resultado = 'Atrasada';
    }

    private static void marcarFallida(Clasificacion c, Log_Senial__c fila, String motivo) {
        fila.Resultado__c = FALLIDA;
        fila.Motivo__c = recortar(motivo);
        c.resultado = FALLIDA;
    }

    private static String recortar(String texto) {
        return texto == null ? null : texto.abbreviate(MOTIVO_MAX);
    }

    private static Map<String, Log_Senial__c> consultarLogs(Set<String> identidades) {
        Map<String, Log_Senial__c> logs = new Map<String, Log_Senial__c>();
        // SYSTEM_MODE: misma razón que el resto de la ruta de ingesta (Automated Process, sin permisos de operador).
        for (Log_Senial__c log : [
            SELECT Id, Identidad__c, Resultado__c, Huella__c, Reenvios__c
            FROM Log_Senial__c
            WHERE Identidad__c IN :identidades
            WITH SYSTEM_MODE
        ]) {
            logs.put(log.Identidad__c, log);
        }
        return logs;
    }

    private static Map<String, Asset> consultarActivos(Set<String> externos) {
        Map<String, Asset> activos = new Map<String, Asset>();
        for (Asset activo : [
            SELECT Id, External_Id__c, AccountId
            FROM Asset
            WHERE External_Id__c IN :externos
            WITH SYSTEM_MODE
        ]) {
            activos.put(activo.External_Id__c, activo);
        }
        return activos;
    }

    private static Map<String, Lectura_Vigente__c> consultarVigentes(Set<String> claves) {
        Map<String, Lectura_Vigente__c> vigentes = new Map<String, Lectura_Vigente__c>();
        for (Lectura_Vigente__c vigente : [
            SELECT Id, Clave__c, Occurred_At__c, Severidad_Nivel__c, Identidad_Senal__c
            FROM Lectura_Vigente__c
            WHERE Clave__c IN :claves
            WITH SYSTEM_MODE
        ]) {
            vigentes.put(vigente.Clave__c, vigente);
        }
        return vigentes;
    }

    /**
     * Hash del contenido del mensaje (BR-205). Excluye deliveryId y publishedAt: cambian en cada reenvío.
     */
    private static String huellaDe(Senial_Sensor__e s) {
        List<String> partes = new List<String>{
            s.Source__c, s.Message_Id__c, s.Message_Type__c, s.Asset_Id__c, s.Asset_Type__c, s.Building_Id__c,
            s.Sensor_Id__c, s.Measurement_Type__c, s.Value__c, s.Unit__c, s.Occurred_At__c, s.Gap_Seconds__c,
            s.Comm_Status__c, s.Episode_Id__c, s.Last_Seen_At__c
        };
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(JSON.serialize(partes))));
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
        resultado.medicion = medicion;
        resultado.unidad = unidad;

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
        // Campos de persistencia (D011)
        public String source;
        public String identidad; // source + '|' + messageId; null si falta alguno
        public String huella;
        public String assetExterno;
        public String medicion;
        public String unidad;
        public String sensorId;
        public String deliveryId;
        public String tipoMensaje;
        // Procesada, Rechazada, Atrasada, Fallida, Reenvio o Conflicto
        public String resultado;

        public void enriquecer(Senial_Sensor__e senial, String huella) {
            this.source = senial.Source__c;
            this.identidad = String.isBlank(senial.Source__c) || String.isBlank(senial.Message_Id__c)
                ? null : senial.Source__c + '|' + senial.Message_Id__c;
            this.huella = huella;
            this.assetExterno = senial.Asset_Id__c;
            this.sensorId = senial.Sensor_Id__c;
            this.deliveryId = senial.Delivery_Id__c;
            this.tipoMensaje = senial.Message_Type__c;
        }

        public Boolean esValida() {
            return nivel != null && ESTADOS_VALIDOS.contains(estado);
        }

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
