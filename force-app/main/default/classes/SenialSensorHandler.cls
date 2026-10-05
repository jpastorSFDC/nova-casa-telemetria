/**
 * Clasifica cada Senial_Sensor__e contra los Umbral__c activos, elige una ganadora por activo + tipo
 * de medición con el desempate de D003 y persiste el resultado: Log_Senial__c (una fila por identidad
 * source + messageId), Lectura_Vigente__c (una fila por activo + medición) y, para las críticas
 * ganadoras, una intervención vía IntervencionService (D010, D011).
 *
 * Un fallo en un evento nunca debe tumbar el lote: una excepción no capturada en el trigger de un Platform
 * Event descarta los hasta 200 eventos entregados. Por eso el trabajo por evento y cada DML van protegidos.
 */
public without sharing class SenialSensorHandler {
    // Por qué `without sharing` + SYSTEM_MODE: la ingesta corre como Automated Process y no puede depender de los
    // permisos de operador/administrador (AGENTS.md). La ruta de consulta del operador tiene su propia autorización
    // (BR-208). Esta clase es solo de la ruta de ingesta: no debe llamarse desde LWC ni controladores @AuraEnabled.
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
    private static final String RECHAZADA = 'Rechazada';
    private static final String CONFLICTO = 'Conflicto';
    private static final String ATRASADA = 'Atrasada';
    // Perdió el desempate D003 (mismo occurredAt); distinta de Atrasada (más antigua que la lectura).
    private static final String SUPERADA = 'Superada';
    private static final Integer MOTIVO_MAX = 255;
    // Longitudes de los campos destino (Log_Senial__c, Lectura_Vigente__c, Case.Identidad_Senal__c).
    private static final Integer MAX_IDENTIDAD = 60;
    private static final Integer MAX_CLAVE = 60;
    private static final Integer MAX_MESSAGE_ID = 80;
    private static final Integer MAX_SOURCE = 80;
    private static final Integer MAX_DELIVERY_ID = 40;
    private static final Integer MAX_SENSOR_ID = 50;
    // Unidad__c (Lectura_Vigente__c) y Message_Type__c (Log_Senial__c) son picklists sin longitud propia: el tope es el
    // del valor de una picklist (255). Además son restringidas; ver la nota en D011.
    private static final Integer MAX_UNIDAD = 255;
    private static final Integer MAX_TIPO_MENSAJE = 255;
    // Valores vigentes de la picklist restringida Log_Senial__c.Message_Type__c (describe, sin SOQL/DML); se lee una vez por transacción.
    private static Set<String> tiposDeMensajeValidos {
        get {
            if (tiposDeMensajeValidos == null) {
                tiposDeMensajeValidos = new Set<String>();
                for (Schema.PicklistEntry entrada : Log_Senial__c.Message_Type__c.getDescribe().getPicklistValues()) {
                    tiposDeMensajeValidos.add(entrada.getValue());
                }
            }
            return tiposDeMensajeValidos;
        }
        private set;
    }
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
    // Eventos cuya identidad excede 60 caracteres: no caben en Identidad__c, así que no hay fila de log.
    // Quedan Rechazados en resultadoPorIdentidad y aquí (identidad => motivo) como única evidencia.
    @TestVisible
    private static Map<String, String> rechazadasSinLog = new Map<String, String>();
    // Excepciones inesperadas capturadas (por evento, por apertura de intervenciones o por DML).
    @TestVisible
    private static Integer erroresInesperados = 0;
    // Filas de log que no se pudieron guardar: contador y detalle (identidad + código, nunca el mensaje del DML).
    @TestVisible
    private static Integer fallosDeLog = 0;
    @TestVisible
    private static List<String> erroresDeLog = new List<String>();

    // Costuras solo para pruebas: permiten forzar fallos que no se pueden provocar con datos válidos.
    // En producción están vacías y no cambian el comportamiento.
    // NUNCA se deben asignar fuera de una clase de prueba: alterarían o descartarían datos reales de la ingesta.
    // Identidades cuya solicitud de Case se reemplaza por un error (sin llamar a IntervencionService).
    @TestVisible
    private static Set<String> identidadesConErrorDeCase = new Set<String>();
    // Si es true, IntervencionService.abrir se sustituye por una excepción.
    @TestVisible
    private static Boolean abrirLanzaExcepcion = false;
    // Entradas 'etapa:messageId' (etapa = clasificar | decidir) que lanzan una excepción.
    @TestVisible
    private static Set<String> excepcionesSimuladas = new Set<String>();
    // Identidades cuya fila de log se envía con un Resultado__c inválido para que el upsert falle.
    @TestVisible
    private static Set<String> identidadesConFalloDeLog = new Set<String>();

    /**
     * @param seniales Lote entregado por SenialSensorTrigger (hasta 200 eventos).
     */
    public void procesar(List<Senial_Sensor__e> seniales) {
        senialesRecibidas += seniales.size();
        System.debug(LoggingLevel.INFO, 'SenialSensorHandler recibió ' + seniales.size() + ' señales');
        if (seniales.isEmpty()) {
            return;
        }

        try {
            Map<String, List<Umbral__c>> umbralesPorTipo = consultarUmbrales();
            List<Clasificacion> clasificaciones = new List<Clasificacion>();
            clasificacionPorMessageId = new Map<String, Clasificacion>();
            for (Integer i = 0; i < seniales.size(); i++) {
                Senial_Sensor__e senial = seniales[i];
                Clasificacion clasificacion = clasificarSeguro(senial, umbralesPorTipo, i);
                clasificaciones.add(clasificacion);
                clasificacionPorMessageId.put(clasificacion.messageId, clasificacion);
                System.debug(LoggingLevel.INFO, 'Señal ' + clasificacion.messageId + ' ' + clasificacion.clave + ': '
                    + clasificacion.estado + ' (nivel ' + clasificacion.nivel + ')');
            }

            ganadoraPorClave = elegirGanadoras(clasificaciones);
            for (String clave : ganadoraPorClave.keySet()) {
                Clasificacion ganadora = ganadoraPorClave.get(clave);
                System.debug(LoggingLevel.INFO, 'Ganadora ' + clave + ': ' + ganadora.messageId + ' '
                    + ganadora.estado + ' (nivel ' + ganadora.nivel + ', occurredAt ' + ganadora.occurredAt.formatGmt(FORMATO_ISO) + ')');
            }

            persistir(clasificaciones);
        } catch (Exception e) {
            // Última red: un fallo imprevisto (p. ej. una consulta) no debe propagarse al trigger y descartar el lote.
            erroresInesperados++;
            System.debug(LoggingLevel.ERROR, 'SenialSensorHandler abortó el lote de ' + seniales.size() + ' señales: ' + e.getTypeName());
        }
    }

    // ─── Clasificación segura por evento ─────────────────────────────────

    private static Clasificacion clasificarSeguro(Senial_Sensor__e senial, Map<String, List<Umbral__c>> umbralesPorTipo, Integer posicion) {
        try {
            simularExcepcion('clasificar', senial.Message_Id__c);
            Clasificacion clasificacion = clasificar(senial, umbralesPorTipo);
            clasificacion.enriquecer(senial, huellaDe(senial));
            String excedido = validarLongitudes(senial, clasificacion);
            if (excedido != null) {
                clasificacion.marcar('DatoInvalido', null, excedido);
            }
            return clasificacion;
        } catch (Exception e) {
            erroresInesperados++;
            System.debug(LoggingLevel.ERROR, 'Error inesperado clasificando ' + senial.Message_Id__c + ': ' + e.getTypeName());
            Clasificacion fallida = new Clasificacion();
            fallida.messageId = senial.Message_Id__c;
            fallida.clave = '(error)|' + posicion;
            fallida.source = senial.Source__c;
            fallida.fijarIdentidad(senial.Source__c, senial.Message_Id__c);
            fallida.marcar('DatoInvalido', null, 'Error inesperado al clasificar la señal');
            if (fallida.identidad != null && fallida.identidad.length() > MAX_IDENTIDAD) {
                fallida.logeable = false;
            }
            return fallida;
        }
    }

    // Los PE pueden traer más texto del que caben los campos destino: se rechaza el evento en vez de dejar fallar el DML.
    private static String validarLongitudes(Senial_Sensor__e senial, Clasificacion c) {
        String motivo = null;
        if (senial.Source__c != null && senial.Source__c.length() > MAX_SOURCE) {
            motivo = 'Source excede ' + MAX_SOURCE + ' caracteres';
        } else if (senial.Message_Id__c != null && senial.Message_Id__c.length() > MAX_MESSAGE_ID) {
            motivo = 'Message_Id excede ' + MAX_MESSAGE_ID + ' caracteres';
        } else if (c.identidad != null && c.identidad.length() > MAX_IDENTIDAD) {
            motivo = 'La identidad (source|messageId) excede ' + MAX_IDENTIDAD + ' caracteres';
        } else if (senial.Delivery_Id__c != null && senial.Delivery_Id__c.length() > MAX_DELIVERY_ID) {
            motivo = 'Delivery_Id excede ' + MAX_DELIVERY_ID + ' caracteres';
        } else if (senial.Sensor_Id__c != null && senial.Sensor_Id__c.length() > MAX_SENSOR_ID) {
            motivo = 'Sensor_Id excede ' + MAX_SENSOR_ID + ' caracteres';
        } else if (senial.Unit__c != null && senial.Unit__c.length() > MAX_UNIDAD) {
            motivo = 'Unit excede ' + MAX_UNIDAD + ' caracteres';
        } else if (senial.Message_Type__c != null && senial.Message_Type__c.length() > MAX_TIPO_MENSAJE) {
            motivo = 'Message_Type excede ' + MAX_TIPO_MENSAJE + ' caracteres';
        } else if (String.isNotBlank(senial.Message_Type__c) && !tiposDeMensajeValidos.contains(senial.Message_Type__c)) {
            motivo = 'Message_Type no es un valor permitido';
        } else if (c.clave != null && c.clave.length() > MAX_CLAVE) {
            motivo = 'La clave activo|medición excede ' + MAX_CLAVE + ' caracteres';
        }
        if (c.identidad != null && c.identidad.length() > MAX_IDENTIDAD) {
            c.logeable = false; // no cabe en Identidad__c: no se puede escribir fila de log
        }
        // Lo que no cabe no se copia a la fila de log.
        if (senial.Delivery_Id__c != null && senial.Delivery_Id__c.length() > MAX_DELIVERY_ID) {
            c.deliveryId = null;
        }
        if (senial.Sensor_Id__c != null && senial.Sensor_Id__c.length() > MAX_SENSOR_ID) {
            c.sensorId = null;
        }
        if (senial.Message_Type__c != null && (senial.Message_Type__c.length() > MAX_TIPO_MENSAJE
                || (String.isNotBlank(senial.Message_Type__c) && !tiposDeMensajeValidos.contains(senial.Message_Type__c)))) {
            c.tipoMensaje = null;
        }
        if (senial.Unit__c != null && senial.Unit__c.length() > MAX_UNIDAD) {
            c.unidad = null;
        }
        return motivo;
    }

    private static void simularExcepcion(String etapa, String messageId) {
        if (!excepcionesSimuladas.isEmpty() && excepcionesSimuladas.contains(etapa + ':' + messageId)) {
            throw new DmlException('Excepción simulada en ' + etapa);
        }
    }

    // ─── Persistencia (D011) ─────────────────────────────────────────────

    /**
     * Orden: 1) consultas (logs, activos, lecturas vigentes); 2) decisión en memoria por identidad y por clave;
     * 3) IntervencionService.abrir, una llamada; 4) upsert de Lectura_Vigente__c; 5) upsert de Log_Senial__c.
     * La lectura se escribe solo si su intervención existe (T5.16); el log se escribe al final para reflejar el resultado real.
     * Las claves de identidad y de activo se comparan normalizadas (mayúsculas/minúsculas, espacios) para que el orden
     * o la grafía no cambien el resultado.
     */
    private static void persistir(List<Clasificacion> clasificaciones) {
        criticasProcesadas = new List<Clasificacion>();
        resultadoPorIdentidad = new Map<String, String>();
        rechazadasSinLog = new Map<String, String>();
        Set<String> identidades = new Set<String>();
        Set<String> activosExternos = new Set<String>();
        Set<String> claves = new Set<String>();
        List<Clasificacion> conIdentidad = new List<Clasificacion>();
        for (Clasificacion c : clasificaciones) {
            if (c.identidad == null) {
                senialesSinIdentidad++;
                continue;
            }
            if (!c.logeable) {
                c.resultado = RECHAZADA;
                resultadoPorIdentidad.put(c.identidad, RECHAZADA);
                rechazadasSinLog.put(c.identidad, c.motivo);
                continue;
            }
            conIdentidad.add(c);
            identidades.add(c.identidad);
            if (String.isNotBlank(c.assetKey)) {
                activosExternos.add(c.assetKey);
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
        Map<String, String> identidadCanonica = new Map<String, String>();
        Map<String, String> huellaConocida = new Map<String, String>();
        Map<String, Decimal> reenvios = new Map<String, Decimal>();
        Map<String, Clasificacion> originalPorIdentidad = new Map<String, Clasificacion>();
        Set<String> conflictivas = new Set<String>();
        List<Clasificacion> candidatas = new List<Clasificacion>();

        for (Clasificacion c : conIdentidad) {
            String llave = c.idKey;
            try {
                simularExcepcion('decidir', c.messageId);
                Log_Senial__c previo = logsPrevios.get(llave);
                if (!huellaConocida.containsKey(llave)) {
                    identidadCanonica.put(llave, previo != null ? previo.Identidad__c : c.identidad);
                    if (previo != null) {
                        Boolean yaProcesada = previo.Resultado__c != PUBLICADA && previo.Resultado__c != FALLIDA;
                        // Una fila Fallida/Publicada con otra huella no se reprocesa en silencio: es conflicto (BR-205).
                        Boolean otraHuella = String.isNotBlank(previo.Huella__c) && String.isNotBlank(c.huella)
                            && !previo.Huella__c.equals(c.huella);
                        if (yaProcesada || otraHuella) {
                            huellaConocida.put(llave, previo.Huella__c);
                            reenvios.put(llave, reenviosDe(previo));
                        }
                    }
                }

                if (huellaConocida.containsKey(llave)) {
                    // Misma identidad ya procesada (antes o antes en este lote): reenvío o conflicto, nunca estado nuevo.
                    Log_Senial__c fila = filaPara(identidadCanonica.get(llave), llave, filaPorIdentidad, filas);
                    String original = huellaConocida.get(llave);
                    if (String.isBlank(original) || String.isBlank(c.huella) || original.equals(c.huella)) {
                        Decimal total = reenvios.get(llave) + 1;
                        reenvios.put(llave, total);
                        fila.Reenvios__c = total;
                        fila.Ultimo_Reenvio__c = ahora;
                        c.resultado = 'Reenvio';
                    } else {
                        fila.Resultado__c = CONFLICTO;
                        fila.Motivo__c = 'Misma identidad con contenido distinto (huella) al ya procesado';
                        fila.Procesado_At__c = ahora;
                        c.resultado = CONFLICTO;
                        // El original del mismo lote tampoco puede ganar ni abrir Case: la identidad queda en conflicto.
                        conflictivas.add(llave);
                        Clasificacion primera = originalPorIdentidad.get(llave);
                        if (primera != null) {
                            primera.resultado = CONFLICTO;
                        }
                    }
                    continue;
                }

                // Primer procesamiento (fila ausente, Publicada o Fallida con la misma huella): aquí sí se decide estado.
                huellaConocida.put(llave, c.huella);
                reenvios.put(llave, reenviosDe(previo));
                originalPorIdentidad.put(llave, c);
                Asset activo = activos.get(c.assetKey);
                Log_Senial__c fila = filaPara(identidadCanonica.get(llave), llave, filaPorIdentidad, filas);
                fila.Source__c = c.source;
                fila.Message_Id__c = c.messageIdLog;
                fila.Message_Type__c = c.tipoMensaje;
                fila.Occurred_At__c = c.occurredAt;
                fila.Delivery_Id__c = c.deliveryId;
                fila.Huella__c = c.huella;
                fila.Procesado_At__c = ahora;
                fila.Asset__c = activo?.Id;
                if (!c.esValida()) {
                    registrar(c, fila, RECHAZADA, c.motivo);
                } else if (activo == null) {
                    registrar(c, fila, RECHAZADA, 'El activo ' + c.assetExterno + ' no existe en el catálogo');
                } else {
                    fila.Resultado__c = 'Procesada';
                    fila.Motivo__c = null;
                    c.resultado = 'Procesada';
                    candidatas.add(c);
                }
            } catch (Exception e) {
                erroresInesperados++;
                System.debug(LoggingLevel.ERROR, 'Error inesperado decidiendo ' + c.identidad + ': ' + e.getTypeName());
                // Una identidad ya procesada no se degrada a Fallida por un error al reexaminarla: su fila no se toca.
                Log_Senial__c previoFallo = logsPrevios.get(llave);
                if (previoFallo == null || previoFallo.Resultado__c == PUBLICADA || previoFallo.Resultado__c == FALLIDA) {
                    Log_Senial__c fila = filaPara(identidadCanonica.containsKey(llave) ? identidadCanonica.get(llave) : c.identidad,
                        llave, filaPorIdentidad, filas);
                    // Source__c y Message_Id__c son obligatorios en Log_Senial__c: sin ellos el upsert de la fila fallaría
                    // y la identidad quedaría sin evidencia. No se toca Huella__c para no reemplazar la original.
                    if (fila.Source__c == null) {
                        // Fila nueva en este lote: una ya poblada por el evento original conserva sus datos.
                        fila.Source__c = c.source;
                        fila.Message_Id__c = c.messageIdLog;
                        fila.Occurred_At__c = c.occurredAt;
                        fila.Procesado_At__c = ahora;
                    }
                    registrar(c, fila, FALLIDA, 'Error inesperado al procesar la señal');
                }
            }
        }

        // Una identidad en conflicto no compite: su original no puede ganar ni abrir Case (BR-205).
        Map<String, List<Clasificacion>> candidatasPorClave = new Map<String, List<Clasificacion>>();
        for (Clasificacion c : candidatas) {
            if (conflictivas.contains(c.idKey)) {
                continue;
            }
            if (!candidatasPorClave.containsKey(c.clave)) {
                candidatasPorClave.put(c.clave, new List<Clasificacion>());
            }
            candidatasPorClave.get(c.clave).add(c);
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
                    marcarPerdedora(candidata, filaPorIdentidad.get(candidata.idKey), mejor.identidad, mejor.occurredAt, 'el lote');
                }
            }
            Lectura_Vigente__c vigente = vigentes.get(clave);
            Boolean esLaVigente = vigente != null && vigente.Identidad_Senal__c != null
                && vigente.Identidad_Senal__c.equalsIgnoreCase(mejor.identidad);
            if (vigente != null && !esLaVigente && !mejor.ganaA(desdeVigente(vigente))) {
                marcarPerdedora(mejor, filaPorIdentidad.get(mejor.idKey), vigente.Identidad_Senal__c, vigente.Occurred_At__c, 'la lectura vigente');
                continue;
            }
            ganadoras.add(mejor);
        }

        // Una sola llamada por lote. Sin Case no hay lectura crítica (T5.16).
        List<IntervencionService.Solicitud> solicitudes = new List<IntervencionService.Solicitud>();
        IntervencionService.Resultado casos = new IntervencionService.Resultado();
        for (Clasificacion ganadora : ganadoras) {
            if (ganadora.estado != CRITICA) {
                continue;
            }
            if (identidadesConErrorDeCase.contains(ganadora.identidad)) {
                casos.errorPorIdentidad.put(ganadora.identidad, 'Error simulado');
                continue;
            }
            Asset activo = activos.get(ganadora.assetKey);
            IntervencionService.Solicitud solicitud = new IntervencionService.Solicitud();
            solicitud.identidad = ganadora.identidad;
            solicitud.assetId = activo.Id;
            solicitud.accountId = activo.AccountId;
            solicitud.codigoActivo = activo.External_Id__c;
            solicitud.tipoMedicion = ganadora.medicion;
            solicitud.causa = ganadora.motivo;
            solicitudes.add(solicitud);
        }
        abrirCasos(solicitudes, casos);

        List<Clasificacion> aEscribir = new List<Clasificacion>();
        List<Lectura_Vigente__c> lecturas = new List<Lectura_Vigente__c>();
        for (Clasificacion ganadora : ganadoras) {
            Log_Senial__c fila = filaPorIdentidad.get(ganadora.idKey);
            if (ganadora.estado == CRITICA) {
                Id casoId = casos.casoPorIdentidad.get(ganadora.identidad);
                if (casoId == null || casos.errorPorIdentidad.containsKey(ganadora.identidad)) {
                    // Detalle del error solo a depuración: puede venir del DML (ver IntervencionService).
                    System.debug(LoggingLevel.WARN, 'Sin intervención para ' + ganadora.identidad);
                    registrar(ganadora, fila, FALLIDA, 'No se pudo abrir la intervención; la lectura no se aplicó');
                    continue;
                }
                fila.Caso__c = casoId;
            }
            Asset activo = activos.get(ganadora.assetKey);
            aEscribir.add(ganadora);
            lecturas.add(new Lectura_Vigente__c(
                // Clave canónica: el External_Id__c del catálogo, no la grafía del evento.
                Clave__c = activo.External_Id__c + '|' + ganadora.medicion,
                Asset__c = activo.Id,
                Tipo_Medicion__c = ganadora.medicion,
                Unidad__c = ganadora.unidad,
                Valor__c = ganadora.valor,
                Occurred_At__c = ganadora.occurredAt,
                Severidad_Nivel__c = ganadora.nivel,
                Identidad_Senal__c = ganadora.identidad,
                Sensor_Id__c = ganadora.sensorId
            ));
        }

        escribirLecturas(lecturas, aEscribir, filaPorIdentidad);
        escribirLogs(filas);
    }

    private static void abrirCasos(List<IntervencionService.Solicitud> solicitudes, IntervencionService.Resultado destino) {
        if (solicitudes.isEmpty()) {
            return;
        }
        try {
            if (abrirLanzaExcepcion) {
                throw new DmlException('Fallo simulado al abrir intervenciones');
            }
            IntervencionService.Resultado abiertos = IntervencionService.abrir(solicitudes);
            destino.casoPorIdentidad.putAll(abiertos.casoPorIdentidad);
            destino.errorPorIdentidad.putAll(abiertos.errorPorIdentidad);
        } catch (Exception e) {
            // Puede haber Cases ya creados: el reintento los reutiliza por identidad (D011). Aquí todas quedan sin Case.
            erroresInesperados++;
            System.debug(LoggingLevel.ERROR, 'IntervencionService.abrir lanzó ' + e.getTypeName());
            for (IntervencionService.Solicitud solicitud : solicitudes) {
                destino.errorPorIdentidad.put(solicitud.identidad, e.getTypeName());
            }
        }
    }

    private static void escribirLecturas(List<Lectura_Vigente__c> lecturas, List<Clasificacion> aEscribir, Map<String, Log_Senial__c> filaPorIdentidad) {
        if (lecturas.isEmpty()) {
            return;
        }
        try {
            List<Database.UpsertResult> resultados = Database.upsert(lecturas, Lectura_Vigente__c.Clave__c, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < resultados.size(); i++) {
                Clasificacion c = aEscribir[i];
                if (!resultados[i].isSuccess()) {
                    System.debug(LoggingLevel.WARN, 'Lectura no guardada ' + c.clave + ': ' + resultados[i].getErrors()[0].getStatusCode());
                    registrar(c, filaPorIdentidad.get(c.idKey), FALLIDA, 'No se pudo guardar la lectura vigente');
                } else if (c.estado == CRITICA) {
                    criticasProcesadas.add(c);
                }
            }
        } catch (Exception e) {
            erroresInesperados++;
            System.debug(LoggingLevel.ERROR, 'Upsert de lecturas lanzó ' + e.getTypeName());
            for (Clasificacion c : aEscribir) {
                registrar(c, filaPorIdentidad.get(c.idKey), FALLIDA, 'No se pudo guardar la lectura vigente');
            }
        }
    }

    private static void escribirLogs(List<Log_Senial__c> filas) {
        for (Log_Senial__c fila : filas) {
            if (fila.Resultado__c != null) {
                resultadoPorIdentidad.put(fila.Identidad__c, fila.Resultado__c);
            }
            if (identidadesConFalloDeLog.contains(fila.Identidad__c)) {
                fila.Resultado__c = 'ValorInvalidoDePrueba'; // picklist restringida: el upsert de esta fila falla
            }
        }
        try {
            List<Database.UpsertResult> resultadosLog = Database.upsert(filas, Log_Senial__c.Identidad__c, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < resultadosLog.size(); i++) {
                if (!resultadosLog[i].isSuccess()) {
                    registrarFalloDeLog(filas[i].Identidad__c, String.valueOf(resultadosLog[i].getErrors()[0].getStatusCode()));
                }
            }
        } catch (Exception e) {
            for (Log_Senial__c fila : filas) {
                registrarFalloDeLog(fila.Identidad__c, e.getTypeName());
            }
        }
    }

    // El log es la evidencia de cada mensaje: si no se guarda, queda constancia en contador y lista (no solo en debug).
    // Se guarda el código del error, nunca el mensaje del DML, que puede traer datos del evento.
    private static void registrarFalloDeLog(String identidad, String codigo) {
        fallosDeLog++;
        erroresDeLog.add(identidad + ' -> ' + codigo);
        System.debug(LoggingLevel.ERROR, 'Log no guardado ' + identidad + ': ' + codigo);
    }

    // Representa la lectura ya guardada para compararla con D003.
    private static Clasificacion desdeVigente(Lectura_Vigente__c vigente) {
        Clasificacion c = new Clasificacion();
        c.identidad = vigente.Identidad_Senal__c;
        c.messageId = vigente.Identidad_Senal__c?.substringAfter('|');
        c.source = vigente.Identidad_Senal__c?.substringBefore('|');
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

    private static Log_Senial__c filaPara(String identidad, String llave, Map<String, Log_Senial__c> filaPorIdentidad, List<Log_Senial__c> filas) {
        Log_Senial__c fila = filaPorIdentidad.get(llave);
        if (fila == null) {
            fila = new Log_Senial__c(Identidad__c = identidad);
            filaPorIdentidad.put(llave, fila);
            filas.add(fila);
        }
        return fila;
    }

    // Único punto que fija un resultado de evidencia. Un Conflicto nunca se pisa: es la evidencia más fuerte de la identidad.
    private static void registrar(Clasificacion c, Log_Senial__c fila, String resultado, String motivo) {
        if (fila.Resultado__c == CONFLICTO) {
            return;
        }
        fila.Resultado__c = resultado;
        fila.Motivo__c = limpiar(motivo);
        c.resultado = resultado;
    }

    // Atrasada: más antigua que la referencia. Superada: mismo occurredAt y pierde el desempate D003.
    private static void marcarPerdedora(Clasificacion c, Log_Senial__c fila, String referencia, Datetime occurredAtReferencia, String contexto) {
        if (occurredAtReferencia == null || c.occurredAt < occurredAtReferencia) {
            registrar(c, fila, ATRASADA, 'Más antigua que ' + referencia + ' (' + contexto + ')');
        } else {
            registrar(c, fila, SUPERADA, 'Pierde el desempate D003 (severidad, luego messageId) contra ' + referencia + ' (' + contexto + ') con el mismo occurredAt');
        }
    }

    /**
     * Texto no confiable (valores, ids y fechas del evento) que termina en Motivo__c: sin caracteres de control
     * ni saltos de línea y con tope de longitud.
     */
    @TestVisible
    private static String limpiar(String texto) {
        if (texto == null) {
            return null;
        }
        return texto.replaceAll('[\\p{Cntrl}\\u2028\\u2029]+', ' ').trim().abbreviate(MOTIVO_MAX);
    }

    private static String normalizar(String texto) {
        return texto == null ? '' : texto.trim().toUpperCase();
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
            logs.put(log.Identidad__c.toLowerCase(), log);
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
            activos.put(normalizar(activo.External_Id__c), activo);
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
            vigentes.put(normalizar(vigente.Clave__c), vigente);
        }
        return vigentes;
    }

    /**
     * Hash del contenido del mensaje (BR-205). Excluye deliveryId y publishedAt: cambian en cada reenvío.
     * Source y messageId van en minúsculas porque la identidad se compara sin distinguir mayúsculas.
     */
    private static String huellaDe(Senial_Sensor__e s) {
        List<String> partes = new List<String>{
            s.Source__c?.toLowerCase(), s.Message_Id__c?.toLowerCase(), s.Message_Type__c, s.Asset_Id__c, s.Asset_Type__c, s.Building_Id__c,
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
            String tipo = normalizar(umbral.Tipo_Activo__c) + '|' + normalizar(umbral.Tipo_Medicion__c);
            if (!umbralesPorTipo.containsKey(tipo)) {
                umbralesPorTipo.put(tipo, new List<Umbral__c>());
            }
            umbralesPorTipo.get(tipo).add(umbral);
        }
        return umbralesPorTipo;
    }

    private static Clasificacion clasificar(Senial_Sensor__e senial, Map<String, List<Umbral__c>> umbralesPorTipo) {
        Boolean esConectividad = senial.Message_Type__c == MENSAJE_CONECTIVIDAD;
        String medicion = esConectividad ? MEDICION_CONECTIVIDAD : normalizar(senial.Measurement_Type__c);
        String valorTexto = esConectividad ? senial.Gap_Seconds__c : senial.Value__c;
        String unidad = esConectividad ? UNIDAD_CONECTIVIDAD : senial.Unit__c;

        Clasificacion resultado = new Clasificacion();
        resultado.messageId = senial.Message_Id__c;
        resultado.clave = normalizar(senial.Asset_Id__c) + '|' + medicion;
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

        List<Umbral__c> umbrales = umbralesPorTipo.get(normalizar(senial.Asset_Type__c) + '|' + medicion);
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
            Datetime fecha = (Datetime) JSON.deserialize('"' + texto.trim() + '"', Datetime.class);
            // Los campos DateTime de Salesforce no guardan milisegundos. Se trunca a segundos para comparar el evento
            // con la lectura vigente ya guardada con la misma precisión; si no, un empate real (D003) parecería
            // "más nuevo" solo por los milisegundos y el orden de llegada decidiría.
            return Datetime.newInstanceGmt(fecha.yearGmt(), fecha.monthGmt(), fecha.dayGmt(),
                fecha.hourGmt(), fecha.minuteGmt(), fecha.secondGmt());
        } catch (JSONException e) {
            return null;
        }
    }

    @TestVisible
    private class Clasificacion {
        public String messageId;
        public String clave; // activo|medición normalizados (mayúsculas, sin espacios): agrupa y busca lecturas
        public Decimal valor;
        public Datetime occurredAt;
        public String estado;
        public Integer nivel;
        public String motivo;
        // Campos de persistencia (D011)
        public String source;
        public String identidad; // source + '|' + messageId; null si falta alguno
        public String idKey; // identidad en minúsculas: llave de comparación de identidades
        public Boolean logeable = true; // false si la identidad no cabe en Identidad__c (60)
        public String messageIdLog;
        public String huella;
        public String assetExterno;
        public String assetKey; // assetExterno normalizado
        public String medicion;
        public String unidad;
        public String sensorId;
        public String deliveryId;
        public String tipoMensaje;
        // Procesada, Rechazada, Atrasada, Superada, Fallida, Reenvio o Conflicto
        public String resultado;

        public void enriquecer(Senial_Sensor__e senial, String huella) {
            this.source = senial.Source__c;
            fijarIdentidad(senial.Source__c, senial.Message_Id__c);
            this.huella = huella;
            this.assetExterno = senial.Asset_Id__c;
            this.assetKey = normalizar(senial.Asset_Id__c);
            this.sensorId = senial.Sensor_Id__c;
            this.deliveryId = senial.Delivery_Id__c;
            this.tipoMensaje = senial.Message_Type__c;
        }

        public void fijarIdentidad(String source, String messageId) {
            this.messageIdLog = messageId;
            this.identidad = String.isBlank(source) || String.isBlank(messageId) ? null : source + '|' + messageId;
            this.idKey = this.identidad?.toLowerCase();
        }

        public Boolean esValida() {
            return nivel != null && ESTADOS_VALIDOS.contains(estado);
        }

        public Clasificacion marcar(String estado, Integer nivel, String motivo) {
            this.estado = estado;
            this.nivel = nivel;
            this.motivo = limpiar(motivo);
            return this;
        }

        // D003: occurredAt, luego severidad, luego messageId; si aun así empatan (mismo messageId en otra fuente),
        // la identidad completa (que incluye source) cierra el desempate. El orden de llegada nunca decide.
        // compareTo y no <: en String el < de Apex depende del locale del usuario y no distingue mayúsculas.
        public Boolean ganaA(Clasificacion otra) {
            if (occurredAt != otra.occurredAt) {
                if (occurredAt == null) {
                    return false;
                }
                return otra.occurredAt == null || occurredAt > otra.occurredAt;
            }
            Integer miNivel = nivel == null ? 0 : nivel;
            Integer suNivel = otra.nivel == null ? 0 : otra.nivel;
            if (miNivel != suNivel) {
                return miNivel > suNivel;
            }
            Integer porMensaje = (messageId ?? '').compareTo(otra.messageId ?? '');
            if (porMensaje != 0) {
                return porMensaje < 0;
            }
            return (source ?? '').compareTo(otra.source ?? '') < 0;
        }
    }
}
