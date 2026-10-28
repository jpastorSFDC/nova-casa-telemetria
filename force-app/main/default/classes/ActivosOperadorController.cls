/**
 * Read side of the operator screen (US-207, BR-207/BR-208).
 * Runs with the operator's own CRUD/FLS/sharing: it never relies on the ingestion's SYSTEM_MODE path. The only
 * system-mode reads are three inner classes that read Log_Senial__c (HistoryReader, CaseSignalReader,
 * OpeningSignalReader), and each is reached only after the asset or the Case was proven visible in USER_MODE (D024, D045).
 */
public with sharing class ActivosOperadorController {

    // Ceiling: severity is computed over at most maxScan assets (5 measurement types => <= 5x readings),
    // ~30k rows of the 50k SOQL row limit; beyond that `truncated` is set. Only pageSize assets are returned.
    @TestVisible private static Integer maxScan = 5000;
    @TestVisible private static Integer pageSize = 100;
    @TestVisible private static Integer maxBuildings = 2000;
    private static final Integer READING_TYPES = 5;
    private static final Integer MAX_CASE_ROWS = 2000;
    // Row cap of the last-closed-intervention lookup (D038); a variable only so a test can lower it.
    @TestVisible private static Integer maxClosedCaseRows = MAX_CASE_ROWS;
    @TestVisible private static final String ACCESS_MESSAGE = 'No tienes acceso a toda la información necesaria para esta lista.';
    @TestVisible private static final String SEVERITY_FILTER_MESSAGE = 'El filtro de severidad no es válido.';
    @TestVisible private static final String BUILDING_FILTER_MESSAGE = 'El filtro de edificio no es válido.';
    @TestVisible private static final String HISTORY_ASSET_MESSAGE = 'El activo no es válido o no tienes acceso a él.';
    @TestVisible private static final Integer HISTORY_DEFAULT_LIMIT = 20;
    @TestVisible private static final Integer HISTORY_MAX_LIMIT = 50;
    @TestVisible private static final String BUILDING_SUMMARY_MESSAGE = 'El edificio no es válido o no tienes acceso a él.';
    @TestVisible private static final String ASSET_STATE_MESSAGE = 'El activo no es válido o no tienes acceso a él.';
    @TestVisible private static final String LOAD_MESSAGE = 'No se pudo cargar la información. Inténtalo de nuevo más tarde.';
    @TestVisible private static final String CASE_MESSAGE = 'No encontramos esta intervención o no tienes acceso a ella.';
    private static final String ORIGIN_TELEMETRY = 'Telemetria';
    private static final String ORIGIN_OPERATOR = 'Operador';
    // Follow-up line written by IntervencionOperadorController: "[yyyy-MM-dd HH:mm Name] comment".
    private static final Pattern FOLLOW_UP_LINE = Pattern.compile('^\\[(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}) ([^\\]]+)\\] (.+)$');
    // Separator crearIntervencion puts after the reason of a manual intervention, and the line it starts.
    private static final String OPENED_BY_MARKER = '\n\nAbierta por:';
    private static final String OPENED_BY_PREFIX = 'Abierta por:';

    public class Option {
        @AuraEnabled public String value { get; private set; }
        @AuraEnabled public String label { get; private set; }
        public Option(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    public class BuildingListResult {
        @AuraEnabled public List<Option> options { get; private set; }
        @AuraEnabled public Boolean truncated { get; private set; }
        public BuildingListResult(List<Option> options, Boolean truncated) {
            this.options = options;
            this.truncated = truncated;
        }
    }

    public class AssetPage {
        @AuraEnabled public List<AssetView> assets { get; private set; }
        // Assets matching the filters within the scan ceiling, before the page cut.
        @AuraEnabled public Integer totalCount { get; private set; }
        // Max assets returned per call.
        @AuraEnabled public Integer assetLimit { get; private set; }
        // True when anything was cut: page, asset scan ceiling, or readings/cases row caps.
        @AuraEnabled public Boolean truncated { get; private set; }
        public AssetPage(List<AssetView> assets, Integer totalCount, Integer assetLimit, Boolean truncated) {
            this.assets = assets;
            this.totalCount = totalCount;
            this.assetLimit = assetLimit;
            this.truncated = truncated;
        }
    }

    // Lightweight sort key so severity is ranked over every scanned asset before any view is built.
    private class Ranked implements Comparable {
        Asset asset;
        Integer level;
        Ranked(Asset asset, Integer level) {
            this.asset = asset;
            this.level = level;
        }
        public Integer compareTo(Object other) {
            Ranked o = (Ranked) other;
            if (level != o.level) {
                return level > o.level ? -1 : 1;
            }
            String n1 = asset.Name == null ? '' : asset.Name;
            String n2 = o.asset.Name == null ? '' : o.asset.Name;
            Integer byName = n1.compareTo(n2);
            if (byName != 0) {
                return byName;
            }
            return String.valueOf(asset.Id).compareTo(String.valueOf(o.asset.Id));
        }
    }

    public class ReadingView {
        @AuraEnabled public String measurementType { get; private set; }
        @AuraEnabled public Decimal value { get; private set; }
        @AuraEnabled public String unit { get; private set; }
        @AuraEnabled public Datetime occurredAt { get; private set; }
        @AuraEnabled public Integer severityLevel { get; private set; }
        @AuraEnabled public String severityLabel { get; private set; }
        @AuraEnabled public String sensorId { get; private set; }

        public ReadingView(Lectura_Vigente__c r) {
            this.measurementType = r.Tipo_Medicion__c;
            this.value = r.Valor__c;
            this.unit = r.Unidad__c;
            this.occurredAt = r.Occurred_At__c;
            this.severityLevel = levelOf(r);
            this.severityLabel = labelFor(this.severityLevel);
            this.sensorId = r.Sensor_Id__c;
        }
    }

    public class InterventionView {
        @AuraEnabled public Id caseId { get; private set; }
        @AuraEnabled public String caseNumber { get; private set; }
        @AuraEnabled public String subject { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Datetime createdDate { get; private set; }

        public InterventionView(Case c) {
            this.caseId = c.Id;
            this.caseNumber = c.CaseNumber;
            this.subject = c.Subject;
            this.status = c.Status;
            this.createdDate = c.CreatedDate;
        }
    }

    // The most recently closed Case of an asset with none open (D038). Deliberately no "closed by": Case has no history
    // tracking here and LastModifiedBy is not who closed it.
    public class ClosedInterventionView {
        @AuraEnabled public Id caseId { get; private set; }
        @AuraEnabled public String caseNumber { get; private set; }
        @AuraEnabled public Datetime closedDate { get; private set; }

        public ClosedInterventionView(Case c) {
            this.caseId = c.Id;
            this.caseNumber = c.CaseNumber;
            this.closedDate = c.ClosedDate;
        }
    }

    public class AssetView implements Comparable {
        @AuraEnabled public Id assetId { get; private set; }
        @AuraEnabled public String name { get; private set; }
        // Catalog code (Asset.External_Id__c), e.g. AST-BOG-002; shown as the ID chip.
        @AuraEnabled public String externalId { get; private set; }
        @AuraEnabled public String assetType { get; private set; }
        @AuraEnabled public Id accountId { get; private set; }
        @AuraEnabled public String accountName { get; private set; }
        // Highest severity among the latest readings; null when no reading carries a level.
        @AuraEnabled public Integer severityLevel { get; private set; }
        @AuraEnabled public String severityLabel { get; private set; }
        @AuraEnabled public Datetime lastSignalAt { get; private set; }
        @AuraEnabled public List<ReadingView> readings { get; private set; }
        @AuraEnabled public InterventionView openIntervention { get; private set; }
        @AuraEnabled public Integer openInterventionCount { get; private set; }
        // Set only when the asset has no open intervention and a closed one is visible to the user; null otherwise.
        @AuraEnabled public ClosedInterventionView lastClosedIntervention { get; private set; }

        public AssetView(Asset a, List<ReadingView> readings, List<Case> openCases, Case lastClosed) {
            this.assetId = a.Id;
            this.name = a.Name;
            this.externalId = a.External_Id__c;
            this.assetType = a.Tipo_Activo__c;
            this.accountId = a.AccountId;
            this.accountName = a.Account?.Name;
            this.readings = readings;
            this.openInterventionCount = openCases.size();
            this.openIntervention = openCases.isEmpty() ? null : new InterventionView(openCases[0]);
            this.lastClosedIntervention = openCases.isEmpty() && lastClosed != null ? new ClosedInterventionView(lastClosed) : null;
            for (ReadingView rv : readings) {
                if (rv.severityLevel != null && (this.severityLevel == null || rv.severityLevel > this.severityLevel)) {
                    this.severityLevel = rv.severityLevel;
                }
                if (rv.occurredAt != null && (this.lastSignalAt == null || rv.occurredAt > this.lastSignalAt)) {
                    this.lastSignalAt = rv.occurredAt;
                }
            }
            this.severityLabel = readings.isEmpty() ? 'Sin lecturas' : labelFor(this.severityLevel);
        }

        // Most severe first, then by name.
        public Integer compareTo(Object other) {
            AssetView o = (AssetView) other;
            Integer mine = severityLevel == null ? -1 : severityLevel;
            Integer theirs = o.severityLevel == null ? -1 : o.severityLevel;
            if (mine != theirs) {
                return mine > theirs ? -1 : 1;
            }
            String n1 = name == null ? '' : name;
            String n2 = o.name == null ? '' : o.name;
            return n1.compareTo(n2);
        }
    }

    /**
     * Assets the running user can see, most severe first, with latest readings and open intervention
     * (or, when none is open, the last closed one the user can see).
     * Severity is computed over all scanned assets before the page cut, so a critical asset is never dropped.
     * @param accountId building (Account Id); blank means all
     * @param severityLevel 0 normal, 1 warning, 2 critical; null means all
     * @param assetType Asset.Tipo_Activo__c API value; blank means all
     */
    @AuraEnabled(cacheable=true)
    public static AssetPage getAssets(String accountId, Integer severityLevel, String assetType) {
        try {
            Id buildingId = parseId(accountId);
            if (severityLevel != null && (severityLevel < 0 || severityLevel > 2)) {
                throw safeError(SEVERITY_FILTER_MESSAGE);
            }

            List<String> conditions = new List<String>();
            Map<String, Object> binds = new Map<String, Object>();
            if (buildingId != null) {
                conditions.add('AccountId = :buildingId');
                binds.put('buildingId', buildingId);
            }
            if (String.isNotBlank(assetType)) {
                conditions.add('Tipo_Activo__c = :assetType');
                binds.put('assetType', assetType);
            }
            String soql = 'SELECT Id, Name, AccountId, Account.Name, Tipo_Activo__c, External_Id__c FROM Asset'
                + (conditions.isEmpty() ? '' : ' WHERE ' + String.join(conditions, ' AND '))
                + ' ORDER BY Name, Id LIMIT ' + (maxScan + 1);
            List<Asset> assets = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
            Boolean truncated = assets.size() > maxScan;
            while (assets.size() > maxScan) {
                assets.remove(assets.size() - 1);
            }
            if (assets.isEmpty()) {
                return new AssetPage(new List<AssetView>(), 0, pageSize, false);
            }

            List<Boolean> capped = new List<Boolean>{ false };
            Map<Id, Map<String, Lectura_Vigente__c>> latest = latestReadings(new Map<Id, Asset>(assets).keySet(), capped);

            List<Ranked> ranked = new List<Ranked>();
            for (Asset a : assets) {
                Integer level = highestLevel(latest.get(a.Id));
                if (severityLevel == null || (level >= 0 && level == severityLevel)) {
                    ranked.add(new Ranked(a, level));
                }
            }
            ranked.sort();

            Integer total = ranked.size();
            Integer shown = Math.min(total, pageSize);
            List<Asset> pageAssets = new List<Asset>();
            for (Integer i = 0; i < shown; i++) {
                pageAssets.add(ranked[i].asset);
            }
            Map<Id, List<Case>> openCases = openInterventions(new Map<Id, Asset>(pageAssets).keySet(), capped);
            Set<Id> withoutOpenCase = new Set<Id>();
            for (Asset a : pageAssets) {
                if (!openCases.containsKey(a.Id)) {
                    withoutOpenCase.add(a.Id);
                }
            }
            Map<Id, Case> lastClosed = lastClosedInterventions(withoutOpenCase);

            List<AssetView> page = new List<AssetView>();
            for (Asset a : pageAssets) {
                List<ReadingView> readings = new List<ReadingView>();
                Map<String, Lectura_Vigente__c> byType = latest.get(a.Id);
                if (byType != null) {
                    List<String> types = new List<String>(byType.keySet());
                    types.sort();
                    for (String t : types) {
                        readings.add(new ReadingView(byType.get(t)));
                    }
                }
                List<Case> cases = openCases.containsKey(a.Id) ? openCases.get(a.Id) : new List<Case>();
                page.add(new AssetView(a, readings, cases, lastClosed.get(a.Id)));
            }
            return new AssetPage(page, total, pageSize, truncated || total > shown || capped[0]);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw failure(e);
        }
    }

    /**
     * One signal of the asset history. Deliberately minimal: no Motivo__c, Huella__c, Identidad__c, Message_Id__c,
     * Source__c or Delivery_Id__c. Technical and error detail stays Admin-only (docs/acceso.md).
     */
    public class SignalView {
        // Log_Senial__c.Message_Type__c: MEASUREMENT or CONNECTIVITY (not the physical measurement type).
        @AuraEnabled public String messageType { get; private set; }
        @AuraEnabled public Datetime occurredAt { get; private set; }
        // Log_Senial__c.Resultado__c, e.g. Procesada, Atrasada, Duplicada.
        @AuraEnabled public String resultado { get; private set; }
        // Physical measurement (e.g. TEMPERATURE, CELSIUS, 21.5), only for an accepted reading (D056): null on a rejected,
        // failed, late or conflicting row, and on rows received before these fields existed.
        @AuraEnabled public String measurementType { get; private set; }
        @AuraEnabled public String unit { get; private set; }
        @AuraEnabled public Decimal value { get; private set; }

        public SignalView(Log_Senial__c l, Boolean withValues) {
            this.messageType = l.Message_Type__c;
            this.occurredAt = l.Occurred_At__c;
            this.resultado = l.Resultado__c;
            if (withValues) {
                this.measurementType = l.Measurement_Type__c;
                this.unit = l.Unit__c;
                this.value = l.Value__c;
            }
        }
    }

    public class HistoryResult {
        @AuraEnabled public List<SignalView> signals { get; private set; }
        // Rows requested (after clamping).
        @AuraEnabled public Integer limite { get; private set; }
        // True when the asset has more signals than were returned.
        @AuraEnabled public Boolean truncated { get; private set; }
        public HistoryResult(List<SignalView> signals, Integer limite, Boolean truncated) {
            this.signals = signals;
            this.limite = limite;
            this.truncated = truncated;
        }
    }

    // Log_Senial__c is Private and operators have no access to it. The read is system-mode on purpose (the log is
    // read without the caller's CRUD/FLS/sharing), and `without sharing` because SYSTEM_MODE alone still honors the
    // class sharing keyword. It is only reachable after getHistorial proved the asset is visible in USER_MODE.
    private without sharing class HistoryReader {
        List<Log_Senial__c> read(Id assetId, Integer fetch) {
            return [
                SELECT Message_Type__c, Occurred_At__c, Resultado__c, Measurement_Type__c, Unit__c, Value__c, Identidad__c
                FROM Log_Senial__c
                WHERE Asset__c = :assetId
                WITH SYSTEM_MODE
                ORDER BY Occurred_At__c DESC, Id DESC
                LIMIT :fetch
            ];
        }

        // Identities (lower-case) of the asset's current readings; compared, never returned.
        Set<String> currentIdentities(Id assetId) {
            Set<String> identities = new Set<String>();
            for (Lectura_Vigente__c r : [
                SELECT Identidad_Senal__c FROM Lectura_Vigente__c WHERE Asset__c = :assetId WITH SYSTEM_MODE
            ]) {
                if (r.Identidad_Senal__c != null) {
                    identities.add(r.Identidad_Senal__c.toLowerCase());
                }
            }
            return identities;
        }
    }

    // D056: measurement, value and unit only for an accepted reading. A rejected, failed or conflicting signal's content
    // is technical detail for the admin (BR-209, US-208), and a late one is not the current condition. A Conflicto row
    // that is the current reading keeps its original's accepted value (D034).
    private static Boolean isAcceptedReading(Log_Senial__c l, Set<String> currentIdentities) {
        return l.Resultado__c == 'Procesada'
            || (l.Resultado__c == 'Conflicto' && l.Identidad__c != null && currentIdentities.contains(l.Identidad__c.toLowerCase()));
    }

    /**
     * Recent signals (newest first) of an asset the running user can see.
     * Authorization: the asset is first queried WITH USER_MODE; if the user cannot see it the call fails and the log is never read.
     * The log rows themselves are then read in system mode and only six non-technical fields are returned (type, time, result, measurement type, unit, value);
     * the last three only for an accepted reading (D056).
     * @param assetId Asset Id
     * @param limite max rows; clamped to 1..50, null means 20
     */
    @AuraEnabled(cacheable=true)
    public static HistoryResult getHistorial(Id assetId, Integer limite) {
        try {
            if (assetId == null || assetId.getSobjectType() != Asset.SObjectType) {
                throw safeError(HISTORY_ASSET_MESSAGE);
            }
            List<Asset> visible = [SELECT Id FROM Asset WHERE Id = :assetId WITH USER_MODE LIMIT 1];
            if (visible.isEmpty()) {
                throw safeError(HISTORY_ASSET_MESSAGE);
            }
            Integer cap = limite == null ? HISTORY_DEFAULT_LIMIT : Math.min(Math.max(limite, 1), HISTORY_MAX_LIMIT);
            HistoryReader reader = new HistoryReader();
            List<Log_Senial__c> rows = reader.read(assetId, cap + 1);
            Set<String> current = reader.currentIdentities(assetId);
            Boolean truncated = rows.size() > cap;
            List<SignalView> signals = new List<SignalView>();
            for (Integer i = 0; i < Math.min(rows.size(), cap); i++) {
                signals.add(new SignalView(rows[i], isAcceptedReading(rows[i], current)));
            }
            return new HistoryResult(signals, cap, truncated);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw failure(e);
        }
    }

    /** One latest reading (asset + measurement type) on the Asset record page. No sensor or other technical fields. */
    public class EstadoLectura {
        @AuraEnabled public String measurementType { get; private set; }
        @AuraEnabled public Decimal value { get; private set; }
        @AuraEnabled public String unit { get; private set; }
        @AuraEnabled public Datetime occurredAt { get; private set; }
        // 0 normal, 1 warning, 2 critical; null when the reading carries no level (shown as "Sin dato").
        @AuraEnabled public Integer severityLevel { get; private set; }

        public EstadoLectura(Lectura_Vigente__c r) {
            this.measurementType = r.Tipo_Medicion__c;
            this.value = r.Valor__c;
            this.unit = r.Unidad__c;
            this.occurredAt = r.Occurred_At__c;
            this.severityLevel = levelOf(r);
        }
    }

    public class EstadoIntervencion {
        @AuraEnabled public Id caseId { get; private set; }
        @AuraEnabled public String caseNumber { get; private set; }
        @AuraEnabled public String subject { get; private set; }
        @AuraEnabled public String status { get; private set; }

        public EstadoIntervencion(Case c) {
            this.caseId = c.Id;
            this.caseNumber = c.CaseNumber;
            this.subject = c.Subject;
            this.status = c.Status;
        }
    }

    /** What the Asset record page shows (HP-07): latest reading per type and the open intervention. */
    public class EstadoActivo {
        // One per measurement type, ordered by type.
        @AuraEnabled public List<EstadoLectura> readings { get; private set; }
        // Newest open intervention; null when none.
        @AuraEnabled public EstadoIntervencion openIntervention { get; private set; }
        @AuraEnabled public Integer openInterventionCount { get; private set; }
        // True when a row cap cut the readings or the cases, so the figures above may be incomplete.
        @AuraEnabled public Boolean truncated { get; private set; }

        public EstadoActivo(List<EstadoLectura> readings, List<Case> openCases, Boolean truncated) {
            this.truncated = truncated;
            this.readings = readings;
            this.openInterventionCount = openCases.size();
            this.openIntervention = openCases.isEmpty() ? null : new EstadoIntervencion(openCases[0]);
        }
    }

    /**
     * Latest reading per measurement type and open interventions of one asset, as the running user sees them.
     * The asset is first queried WITH USER_MODE (an operator only sees their own assets, BR-208); if not visible the call
     * fails with the same static message as a non-existent asset. Readings and cases are read WITH USER_MODE and use the
     * same latest-per-type rule as the list (latestReadings / isBetter). The signal history is not here: use getHistorial.
     * @param assetId Asset Id
     */
    @AuraEnabled(cacheable=true)
    public static EstadoActivo getEstadoActivo(Id assetId) {
        try {
            if (assetId == null || assetId.getSobjectType() != Asset.SObjectType) {
                throw safeError(ASSET_STATE_MESSAGE);
            }
            List<Asset> visible = [SELECT Id FROM Asset WHERE Id = :assetId WITH USER_MODE LIMIT 1];
            if (visible.isEmpty()) {
                throw safeError(ASSET_STATE_MESSAGE);
            }
            Set<Id> ids = new Set<Id>{ assetId };
            List<Boolean> capped = new List<Boolean>{ false };
            Map<String, Lectura_Vigente__c> byType = latestReadings(ids, capped).get(assetId);
            List<EstadoLectura> readings = new List<EstadoLectura>();
            if (byType != null) {
                List<String> types = new List<String>(byType.keySet());
                types.sort();
                for (String t : types) {
                    readings.add(new EstadoLectura(byType.get(t)));
                }
            }
            List<Case> cases = openInterventions(ids, capped).get(assetId);
            return new EstadoActivo(readings, cases == null ? new List<Case>() : cases, capped[0]);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw failure(e);
        }
    }

    /**
     * Counts for the Account record page of a building (HP-07). Deliberately minimal: no Log_Senial__c data and no
     * technical fields. Every number is what the running user can see.
     */
    @TestVisible private static Integer maxSummaryAssets = 2000;

    public class EdificioResumen {
        @AuraEnabled public Integer totalActivos { get; private set; }
        @AuraEnabled public Integer activosCriticos { get; private set; }
        @AuraEnabled public Integer activosEnAlerta { get; private set; }
        @AuraEnabled public Integer activosNormales { get; private set; }
        // No signal at all (Ultima_Senal__c empty): never counted as normal.
        @AuraEnabled public Integer activosSinLectura { get; private set; }
        // Has a signal but no severity level (Severidad_Nivel__c empty): never counted as normal either.
        @AuraEnabled public Integer activosSinNivel { get; private set; }
        // True when the building has more visible assets than maxSummaryAssets: every count covers only the first ones.
        @AuraEnabled public Boolean truncated { get; private set; }
        @AuraEnabled public Integer casosAbiertos { get; private set; }
        // Newest Asset.Ultima_Senal__c of the visible assets; null when none has a signal.
        @AuraEnabled public Datetime ultimaSenal { get; private set; }

        public EdificioResumen() {
            this.totalActivos = 0;
            this.activosCriticos = 0;
            this.activosEnAlerta = 0;
            this.activosNormales = 0;
            this.activosSinLectura = 0;
            this.activosSinNivel = 0;
            this.truncated = false;
            this.casosAbiertos = 0;
        }
    }

    /**
     * Severity counts, open interventions and last signal of one building, as the running user sees them.
     * Asset and Case are read WITH USER_MODE, so a building whose assets the user cannot see yields zeros for them;
     * a building the user cannot see at all is rejected. Severity uses the Asset roll-ups (same rule as the list):
     * 2 critical, 1 warning, 0 normal; no signal is "sin lectura" and a signal without level is "sin nivel".
     * At most maxSummaryAssets assets are counted; beyond that `truncated` is set.
     * Open cases are those linked through Case.AssetId to an asset of the building.
     * @param accountId building (Account Id)
     */
    @AuraEnabled(cacheable=true)
    public static EdificioResumen getResumenEdificio(Id accountId) {
        try {
            if (accountId == null || accountId.getSobjectType() != Account.SObjectType) {
                throw safeError(BUILDING_SUMMARY_MESSAGE);
            }
            List<Account> visible = [SELECT Id FROM Account WHERE Id = :accountId WITH USER_MODE LIMIT 1];
            if (visible.isEmpty()) {
                throw safeError(BUILDING_SUMMARY_MESSAGE);
            }
            EdificioResumen resumen = new EdificioResumen();
            Integer fetch = maxSummaryAssets + 1;
            for (Asset a : [
                SELECT Id, Severidad_Nivel__c, Ultima_Senal__c
                FROM Asset
                WHERE AccountId = :accountId
                WITH USER_MODE
                ORDER BY Id
                LIMIT :fetch
            ]) {
                if (resumen.totalActivos >= maxSummaryAssets) {
                    resumen.truncated = true;
                    break;
                }
                resumen.totalActivos++;
                if (a.Ultima_Senal__c == null) {
                    resumen.activosSinLectura++;
                } else if (a.Severidad_Nivel__c == null) {
                    resumen.activosSinNivel++;
                } else if (a.Severidad_Nivel__c >= 2) {
                    resumen.activosCriticos++;
                } else if (a.Severidad_Nivel__c >= 1) {
                    resumen.activosEnAlerta++;
                } else {
                    resumen.activosNormales++;
                }
                if (a.Ultima_Senal__c != null && (resumen.ultimaSenal == null || a.Ultima_Senal__c > resumen.ultimaSenal)) {
                    resumen.ultimaSenal = a.Ultima_Senal__c;
                }
            }
            if (resumen.totalActivos > 0) {
                resumen.casosAbiertos = [
                    SELECT COUNT() FROM Case
                    WHERE IsClosed = false AND AssetId IN (SELECT Id FROM Asset WHERE AccountId = :accountId)
                    WITH USER_MODE
                ];
            }
            return resumen;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw failure(e);
        }
    }

    /** What the running user may do on the screen. Only drives what is shown: every action re-checks on the server (BR-208). */
    public class Capacidades {
        @AuraEnabled public Boolean puedeCrearIntervencion { get; private set; }
        @AuraEnabled public Boolean puedeSeguirIntervencion { get; private set; }
        @AuraEnabled public Boolean puedeTraerSenales { get; private set; }
        @AuraEnabled public Boolean puedeVerLimites { get; private set; }
        public Capacidades() {
            this.puedeCrearIntervencion = FeatureManagement.checkPermission(IntervencionOperadorController.PERM_CREAR);
            this.puedeSeguirIntervencion = FeatureManagement.checkPermission(IntervencionOperadorController.PERM_SEGUIR);
            this.puedeTraerSenales = FeatureManagement.checkPermission(IngestaController.PERM_INGESTA);
            this.puedeVerLimites = Umbral__c.SObjectType.getDescribe().isAccessible();
        }
    }

    @AuraEnabled(cacheable=true)
    public static Capacidades getCapacidades() {
        return new Capacidades();
    }

    /** Buildings (Accounts) that have at least one asset visible to the user; truncated when over the bound. */
    @AuraEnabled(cacheable=true)
    public static BuildingListResult getBuildings() {
        try {
            Integer cap = maxBuildings;
            Integer fetch = cap + 1;
            List<Option> options = new List<Option>();
            for (Account acc : [
                SELECT Id, Name FROM Account
                WHERE Id IN (SELECT AccountId FROM Asset)
                WITH USER_MODE
                ORDER BY Name, Id
                LIMIT :fetch
            ]) {
                options.add(new Option(acc.Id, acc.Name));
            }
            Boolean truncated = options.size() > cap;
            if (truncated) {
                options.remove(options.size() - 1);
            }
            return new BuildingListResult(options, truncated);
        } catch (Exception e) {
            throw failure(e);
        }
    }

    /** Latest critical signal recorded on a telemetry intervention (D039). Never its identity. */
    public class UltimaCritica {
        @AuraEnabled public String measurementType { get; private set; }
        @AuraEnabled public Decimal value { get; private set; }
        @AuraEnabled public String unit { get; private set; }
        @AuraEnabled public Datetime occurredAt { get; private set; }

        public UltimaCritica(Case c) {
            this.measurementType = c.Ultima_Critica_Medicion__c;
            this.value = c.Ultima_Critica_Valor__c;
            this.unit = c.Ultima_Critica_Unidad__c;
            this.occurredAt = c.Ultima_Critica_At__c;
        }
    }

    /** Last follow-up line of the Case Description, split into its parts; the rest of the Description never leaves the server. */
    public class Seguimiento {
        // As written by the server, in the writer's time zone: yyyy-MM-dd HH:mm.
        @AuraEnabled public String fecha { get; private set; }
        @AuraEnabled public String autor { get; private set; }
        @AuraEnabled public String texto { get; private set; }

        public Seguimiento(String fecha, String autor, String texto) {
            this.fecha = fecha;
            this.autor = autor;
            this.texto = texto;
        }
    }

    /**
     * What the Case record page shows (HP-07). No identity, Description, Motivo__c or Huella__c: only flags and parts
     * derived on the server.
     */
    public class IntervencionDetalle {
        @AuraEnabled public Id caseId { get; private set; }
        @AuraEnabled public String caseNumber { get; private set; }
        @AuraEnabled public String subject { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Boolean isClosed { get; private set; }
        @AuraEnabled public Datetime createdDate { get; private set; }
        @AuraEnabled public Datetime closedDate { get; private set; }
        @AuraEnabled public String priority { get; private set; }
        @AuraEnabled public String origin { get; private set; }
        // Opened by the telemetry (Origin Telemetria), as opposed to a manual one.
        @AuraEnabled public Boolean esTelemetria { get; private set; }
        // The open telemetry Case that new criticals of its asset are linked to: the newest open one (D039).
        @AuraEnabled public Boolean recibeCriticas { get; private set; }
        // Case.Tiempo_Abierto_Horas__c: null once closed.
        @AuraEnabled public Decimal horasAbierta { get; private set; }
        @AuraEnabled public Id assetId { get; private set; }
        @AuraEnabled public String assetName { get; private set; }
        @AuraEnabled public String assetExternalId { get; private set; }
        @AuraEnabled public String assetType { get; private set; }
        // Building of the asset (Asset.AccountId): the screen permission sets read Asset.AccountId, not Case.AccountId.
        @AuraEnabled public Id accountId { get; private set; }
        @AuraEnabled public String accountName { get; private set; }
        // Current asset severity, same rule as the asset panel; null when no latest reading carries a level.
        @AuraEnabled public Integer assetLevel { get; private set; }
        // The latest reading behind assetLevel (highest level; on a tie the most recent); null when the asset has none.
        @AuraEnabled public EstadoLectura lecturaActual { get; private set; }
        // True when the readings row cap cut the asset's readings: one left out could be more severe.
        @AuraEnabled public Boolean lecturasIncompletas { get; private set; }
        // Last critical recorded on the Case (D039), not the current reading. Null on manual interventions.
        @AuraEnabled public UltimaCritica ultimaCritica { get; private set; }
        @AuraEnabled public Integer senalesEnlazadas { get; private set; }
        // Null when the user cannot read Description or it has no follow-up line.
        @AuraEnabled public Seguimiento ultimoSeguimiento { get; private set; }
        // Reason of a manual intervention; null when not manual, not readable or absent.
        @AuraEnabled public String motivo { get; private set; }
        // Active Case.Status values (getEstadosSeguimiento, D036).
        @AuraEnabled public List<Option> estados { get; private set; }
        // Only drives what is shown: actualizarSeguimiento re-checks on the server (BR-208).
        @AuraEnabled public Boolean puedeSeguir { get; private set; }

        public IntervencionDetalle(
            Case c,
            Integer assetLevel,
            EstadoLectura lecturaActual,
            Boolean lecturasIncompletas,
            Boolean recibeCriticas,
            Integer linkedSignals,
            String description,
            List<Option> estados
        ) {
            this.caseId = c.Id;
            this.caseNumber = c.CaseNumber;
            this.subject = c.Subject;
            this.status = c.Status;
            this.isClosed = c.IsClosed;
            this.createdDate = c.CreatedDate;
            this.closedDate = c.ClosedDate;
            this.priority = c.Priority;
            this.origin = c.Origin;
            this.esTelemetria = c.Origin == ORIGIN_TELEMETRY;
            this.recibeCriticas = recibeCriticas;
            this.horasAbierta = c.Tiempo_Abierto_Horas__c;
            this.assetId = c.AssetId;
            this.assetName = c.Asset?.Name;
            this.assetExternalId = c.Asset?.External_Id__c;
            this.assetType = c.Asset?.Tipo_Activo__c;
            this.accountId = c.Asset?.AccountId;
            this.accountName = c.Asset?.Account?.Name;
            this.assetLevel = assetLevel;
            this.lecturaActual = lecturaActual;
            this.lecturasIncompletas = lecturasIncompletas;
            Boolean hasCritical = c.Ultima_Critica_At__c != null || String.isNotBlank(c.Ultima_Critica_Medicion__c)
                || c.Ultima_Critica_Valor__c != null || String.isNotBlank(c.Ultima_Critica_Unidad__c);
            this.ultimaCritica = hasCritical ? new UltimaCritica(c) : null;
            this.senalesEnlazadas = linkedSignals;
            this.ultimoSeguimiento = lastFollowUp(description, c.Origin == ORIGIN_OPERATOR);
            this.motivo = c.Origin == ORIGIN_OPERATOR ? manualReason(description) : null;
            this.estados = estados;
            this.puedeSeguir = FeatureManagement.checkPermission(IntervencionOperadorController.PERM_SEGUIR)
                && !c.IsClosed && c.AssetId != null;
        }

        // A visible Case on an asset the user cannot see keeps neither the asset's Id nor its last critical reading,
        // the same rule as getSenalesDeIntervencion and getAperturasDeIntervencion (D024, D045, D053).
        public void ocultarActivo() {
            this.assetId = null;
            this.ultimaCritica = null;
        }
    }

    /** One signal linked to an intervention. Deliberately minimal: no identity, Motivo__c, Huella__c or delivery data. */
    public class SenalIntervencion {
        @AuraEnabled public Datetime occurredAt { get; private set; }
        @AuraEnabled public String measurementType { get; private set; }
        @AuraEnabled public Decimal value { get; private set; }
        @AuraEnabled public String unit { get; private set; }
        // Log_Senial__c.Resultado__c, e.g. Procesada.
        @AuraEnabled public String result { get; private set; }
        @AuraEnabled public Integer resends { get; private set; }
        // True for the signal whose identity opened the Case; the identity itself is not returned.
        @AuraEnabled public Boolean abrio { get; private set; }

        public SenalIntervencion(Log_Senial__c l, String openerIdentity) {
            this.occurredAt = l.Occurred_At__c;
            this.measurementType = l.Measurement_Type__c;
            this.value = l.Value__c;
            this.unit = l.Unit__c;
            this.result = l.Resultado__c;
            this.resends = l.Reenvios__c == null ? 0 : l.Reenvios__c.intValue();
            this.abrio = String.isNotBlank(openerIdentity) && openerIdentity.equalsIgnoreCase(l.Identidad__c);
        }
    }

    public class SenalesIntervencion {
        @AuraEnabled public List<SenalIntervencion> signals { get; private set; }
        // True when the Case has more linked signals than were returned.
        @AuraEnabled public Boolean truncated { get; private set; }
        public SenalesIntervencion(List<SenalIntervencion> signals, Boolean truncated) {
            this.signals = signals;
            this.truncated = truncated;
        }
    }

    // Same reasoning as HistoryReader: Log_Senial__c is Private and screen users have no access to it, so the read is
    // system-mode on purpose, and `without sharing` because SYSTEM_MODE alone still honors the class sharing keyword.
    // It is only reachable after getIntervencion / getSenalesDeIntervencion proved the Case is visible in USER_MODE.
    // Identidad__c is read only to flag the opening signal and never returned.
    private without sharing class CaseSignalReader {
        Integer countFor(Id caseId) {
            return [SELECT COUNT() FROM Log_Senial__c WHERE Caso__c = :caseId WITH SYSTEM_MODE];
        }
        // D003 order extended (as IntervencionService.isMoreRecent): later occurredAt, then smaller messageId, then smaller
        // source, so arrival order never decides which row is first ("Última").
        List<Log_Senial__c> read(Id caseId, Integer fetch) {
            return [
                SELECT Occurred_At__c, Measurement_Type__c, Value__c, Unit__c, Resultado__c, Reenvios__c, Identidad__c
                FROM Log_Senial__c
                WHERE Caso__c = :caseId
                WITH SYSTEM_MODE
                ORDER BY Occurred_At__c DESC, Message_Id__c ASC, Source__c ASC, Id DESC
                LIMIT :fetch
            ];
        }
    }

    /**
     * One intervention (Case) as the running user sees it, for the Case record page (HP-07).
     * The Case is queried WITH USER_MODE; if the user cannot see it the call fails with the same static message as a
     * non-existent one. The asset level and current reading use the same latest-reading rule as the asset panel
     * (latestReadings). Description is read (WITH USER_MODE) only when the user has FLS on it, and only its last follow-up
     * line and the manual reason are returned. The linked-signal count is read in system mode only after the visibility
     * checks (CaseSignalReader, signalsVisible).
     * @param caseId Case Id
     */
    @AuraEnabled(cacheable=true)
    public static IntervencionDetalle getIntervencion(Id caseId) {
        try {
            if (caseId == null || caseId.getSobjectType() != Case.SObjectType) {
                throw safeError(CASE_MESSAGE);
            }
            List<Case> visible = [
                SELECT Id, CaseNumber, Subject, Status, IsClosed, CreatedDate, ClosedDate, Priority, Origin,
                    Tiempo_Abierto_Horas__c, AssetId, Asset.Name, Asset.External_Id__c, Asset.Tipo_Activo__c,
                    Asset.AccountId, Asset.Account.Name, Ultima_Critica_Medicion__c,
                    Ultima_Critica_Valor__c, Ultima_Critica_Unidad__c, Ultima_Critica_At__c
                FROM Case
                WHERE Id = :caseId
                WITH USER_MODE
                LIMIT 1
            ];
            if (visible.isEmpty()) {
                throw safeError(CASE_MESSAGE);
            }
            Case c = visible[0];
            // Sharing is not enforced on parent fields: a visible Case can still carry the name and building of an asset
            // the user cannot see, so those are dropped (D024: only assets the user already sees).
            Boolean assetVisible = signalsVisible(c.AssetId);
            if (!assetVisible) {
                c.putSObject('Asset', null);
            }

            Integer level = null;
            EstadoLectura current = null;
            List<Boolean> capped = new List<Boolean>{ false };
            if (c.AssetId != null && assetVisible) {
                Map<String, Lectura_Vigente__c> byType = latestReadings(new Set<Id>{ c.AssetId }, capped).get(c.AssetId);
                Integer best = highestLevel(byType);
                level = best < 0 ? null : best;
                Lectura_Vigente__c headline = headlineReading(byType);
                current = headline == null ? null : new EstadoLectura(headline);
            }

            Boolean receivesCriticals = assetVisible && c.Origin == ORIGIN_TELEMETRY && !c.IsClosed && c.AssetId != null
                && isNewestOpenTelemetryCase(c.Id, c.AssetId);

            String description = null;
            if (Schema.SObjectType.Case.fields.Description.isAccessible()) {
                List<Case> withDescription = [SELECT Description FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];
                description = withDescription.isEmpty() ? null : withDescription[0].Description;
            }

            List<Option> estados = new List<Option>();
            for (IntervencionOperadorController.EstadoOpcion estado : IntervencionOperadorController.getEstadosSeguimiento()) {
                estados.add(new Option(estado.value, estado.label));
            }

            Integer linked = assetVisible ? new CaseSignalReader().countFor(caseId) : 0;
            IntervencionDetalle detalle = new IntervencionDetalle(c, level, current, capped[0], receivesCriticals, linked, description, estados);
            if (!assetVisible) {
                detalle.ocultarActivo();
            }
            return detalle;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw failure(e);
        }
    }

    /**
     * Signals linked to an intervention (Log_Senial__c.Caso__c), newest first.
     * Authorization: the Case is first queried WITH USER_MODE; if the user cannot see it the call fails and the log is
     * never read. If the Case has an asset the user cannot see, the list is empty and the log is not read either
     * (signalsVisible). The log rows are then read in system mode and only seven non-technical values are returned.
     * @param caseId Case Id
     * @param limite max rows; clamped to 1..50, null means 20
     */
    @AuraEnabled(cacheable=true)
    public static SenalesIntervencion getSenalesDeIntervencion(Id caseId, Integer limite) {
        try {
            if (caseId == null || caseId.getSobjectType() != Case.SObjectType) {
                throw safeError(CASE_MESSAGE);
            }
            List<Case> visible = [
                SELECT Id, AssetId, Identidad_Senal__c FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1
            ];
            if (visible.isEmpty()) {
                throw safeError(CASE_MESSAGE);
            }
            if (!signalsVisible(visible[0].AssetId)) {
                return new SenalesIntervencion(new List<SenalIntervencion>(), false);
            }
            String opener = visible[0].Identidad_Senal__c;
            Integer cap = limite == null ? HISTORY_DEFAULT_LIMIT : Math.min(Math.max(limite, 1), HISTORY_MAX_LIMIT);
            List<Log_Senial__c> rows = new CaseSignalReader().read(caseId, cap + 1);
            Boolean truncated = rows.size() > cap;
            List<SenalIntervencion> signals = new List<SenalIntervencion>();
            for (Integer i = 0; i < Math.min(rows.size(), cap); i++) {
                signals.add(new SenalIntervencion(rows[i], opener));
            }
            return new SenalesIntervencion(signals, truncated);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw failure(e);
        }
    }

    @TestVisible private static final Integer MAX_APERTURAS = 50;

    /** The signal that opened a telemetry intervention. Never its identity. */
    public class SenalApertura {
        @AuraEnabled public String measurementType { get; private set; }
        @AuraEnabled public Decimal value { get; private set; }
        @AuraEnabled public String unit { get; private set; }
        @AuraEnabled public Datetime occurredAt { get; private set; }

        SenalApertura(String measurementType, Decimal value, String unit, Datetime occurredAt) {
            this.measurementType = measurementType;
            this.value = value;
            this.unit = unit;
            this.occurredAt = occurredAt;
        }
    }

    /** How an intervention started: opened by the telemetry (with its opening signal when known) or by hand. */
    public class AperturaIntervencion {
        @AuraEnabled public Id caseId { get; private set; }
        @AuraEnabled public Boolean esTelemetria { get; private set; }
        // Null for a manual intervention, for an asset the user cannot see, or when the opening signal is no longer stored.
        @AuraEnabled public SenalApertura senal { get; private set; }

        AperturaIntervencion(Case c, SenalApertura senal) {
            this.caseId = c.Id;
            this.esTelemetria = c.Origin == ORIGIN_TELEMETRY;
            this.senal = senal;
        }
    }

    // Same reasoning as CaseSignalReader: only for Cases and assets already proved visible WITH USER_MODE. In system mode on
    // purpose: Ultima_Critica_Identidad__c (screen users have no FLS on it) and the log. Identities only match, never returned.
    private without sharing class OpeningSignalReader {
        Map<Id, SenalApertura> forCases(List<Case> cases) {
            Map<Id, SenalApertura> byCase = new Map<Id, SenalApertura>();
            Map<Id, String> latestIdentity = new Map<Id, String>();
            for (Case c : [SELECT Id, Ultima_Critica_Identidad__c FROM Case WHERE Id IN :cases WITH SYSTEM_MODE]) {
                latestIdentity.put(c.Id, c.Ultima_Critica_Identidad__c);
            }
            Map<String, Case> pending = new Map<String, Case>();
            Set<Id> pendingAssets = new Set<Id>();
            for (Case c : cases) {
                // The latest critical recorded on the Case is the opener until a later critical refreshes it (D039). It is
                // preferred because connectivity rows of the log carry no value.
                if (c.Identidad_Senal__c.equalsIgnoreCase(latestIdentity.get(c.Id))) {
                    byCase.put(c.Id, new SenalApertura(
                        c.Ultima_Critica_Medicion__c, c.Ultima_Critica_Valor__c, c.Ultima_Critica_Unidad__c, c.Ultima_Critica_At__c));
                } else {
                    pending.put(c.Identidad_Senal__c.toLowerCase(), c);
                    pendingAssets.add(c.AssetId);
                }
            }
            if (pending.isEmpty()) {
                return byCase;
            }
            // Scoped to the visible assets, and each row must belong to its own Case's asset (D024).
            for (Log_Senial__c l : [
                SELECT Identidad__c, Asset__c, Occurred_At__c, Measurement_Type__c, Value__c, Unit__c
                FROM Log_Senial__c
                WHERE Identidad__c IN :pending.keySet() AND Asset__c IN :pendingAssets
                WITH SYSTEM_MODE
            ]) {
                Case c = pending.get(l.Identidad__c.toLowerCase());
                if (c != null && c.AssetId == l.Asset__c) {
                    byCase.put(c.Id, new SenalApertura(l.Measurement_Type__c, l.Value__c, l.Unit__c, l.Occurred_At__c));
                }
            }
            return byCase;
        }
    }

    /**
     * How each given intervention started (HP-07), in the order received, for the Cases the running user can see.
     * Cases are read WITH USER_MODE, opener identity and last critical included (without FLS on them the call fails with
     * the access message): an unknown or hidden Id is skipped, never reported. Only telemetry Cases whose asset the user also
     * sees (D024) get their opening signal, completed in system mode after those checks (OpeningSignalReader); only four
     * non-technical values are returned.
     * @param caseIds Case Ids; null or empty gives an empty list, more than MAX_APERTURAS is rejected
     */
    @AuraEnabled(cacheable=true)
    public static List<AperturaIntervencion> getAperturasDeIntervencion(List<Id> caseIds) {
        try {
            List<AperturaIntervencion> result = new List<AperturaIntervencion>();
            if (caseIds == null || caseIds.isEmpty()) {
                return result;
            }
            if (caseIds.size() > MAX_APERTURAS) {
                throw safeError(CASE_MESSAGE);
            }
            Set<Id> requested = new Set<Id>();
            for (Id caseId : caseIds) {
                if (caseId != null && caseId.getSobjectType() == Case.SObjectType) {
                    requested.add(caseId);
                }
            }
            if (requested.isEmpty()) {
                return result;
            }
            Map<Id, Case> visible = new Map<Id, Case>([
                SELECT Id, Origin, AssetId, Identidad_Senal__c, Ultima_Critica_Medicion__c, Ultima_Critica_Valor__c,
                    Ultima_Critica_Unidad__c, Ultima_Critica_At__c
                FROM Case
                WHERE Id IN :requested
                WITH USER_MODE
            ]);
            Set<Id> assetIds = new Set<Id>();
            for (Case c : visible.values()) {
                if (c.Origin == ORIGIN_TELEMETRY && c.AssetId != null && String.isNotBlank(c.Identidad_Senal__c)) {
                    assetIds.add(c.AssetId);
                }
            }
            Map<Id, SenalApertura> openers = new Map<Id, SenalApertura>();
            if (!assetIds.isEmpty()) {
                Set<Id> visibleAssets = new Map<Id, Asset>([SELECT Id FROM Asset WHERE Id IN :assetIds WITH USER_MODE]).keySet();
                List<Case> readable = new List<Case>();
                for (Case c : visible.values()) {
                    if (c.Origin == ORIGIN_TELEMETRY && String.isNotBlank(c.Identidad_Senal__c) && visibleAssets.contains(c.AssetId)) {
                        readable.add(c);
                    }
                }
                if (!readable.isEmpty()) {
                    openers = new OpeningSignalReader().forCases(readable);
                }
            }
            Set<Id> added = new Set<Id>();
            for (Id caseId : caseIds) {
                Case c = caseId == null ? null : visible.get(caseId);
                if (c != null && added.add(c.Id)) {
                    result.add(new AperturaIntervencion(c, openers.get(c.Id)));
                }
            }
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw failure(e);
        }
    }

    // D024: the log is shown only for assets the user already sees. Case and Asset have their own sharing, so a visible
    // Case can point to an asset the user cannot see; its signals then stay hidden (empty list, count 0).
    private static Boolean signalsVisible(Id assetId) {
        return assetId == null || [SELECT COUNT() FROM Asset WHERE Id = :assetId WITH USER_MODE] > 0;
    }

    // Whether this Case is the newest open telemetry Case of its asset, the one ingestion links new criticals to (D039).
    // WITH USER_MODE: a newer open telemetry Case the user cannot see is not taken into account.
    private static Boolean isNewestOpenTelemetryCase(Id caseId, Id assetId) {
        List<Case> newest = [
            SELECT Id FROM Case
            WHERE AssetId = :assetId AND Origin = :ORIGIN_TELEMETRY AND IsClosed = false
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        return !newest.isEmpty() && newest[0].Id == caseId;
    }

    // The reading behind the asset level: highest level (no level ranks lowest), then the most recent occurredAt,
    // then the record Id so the choice never depends on map order. Null when there is none.
    private static Lectura_Vigente__c headlineReading(Map<String, Lectura_Vigente__c> byType) {
        Lectura_Vigente__c best = null;
        if (byType == null) {
            return best;
        }
        for (Lectura_Vigente__c r : byType.values()) {
            if (best == null || rank(r) > rank(best)) {
                best = r;
            } else if (rank(r) == rank(best)) {
                if (r.Occurred_At__c != best.Occurred_At__c) {
                    if (r.Occurred_At__c != null && (best.Occurred_At__c == null || r.Occurred_At__c > best.Occurred_At__c)) {
                        best = r;
                    }
                } else if (String.valueOf(r.Id).compareTo(String.valueOf(best.Id)) > 0) {
                    best = r;
                }
            }
        }
        return best;
    }

    // Last line of the Description that matches the follow-up format; null when none does. In a manual Case everything up
    // to and including the "Abierta por:" line is the reason, so only the lines after it count: a reason never passes
    // for a follow-up. Ingestion's first line ("Signal <identity>: ...") never matches the format.
    private static Seguimiento lastFollowUp(String description, Boolean manual) {
        if (String.isBlank(description)) {
            return null;
        }
        Seguimiento last = null;
        Boolean counting = !manual;
        for (String line : description.replace('\r\n', '\n').split('\n')) {
            if (!counting) {
                counting = line.startsWith(OPENED_BY_PREFIX);
                continue;
            }
            Matcher m = FOLLOW_UP_LINE.matcher(line);
            if (m.matches()) {
                last = new Seguimiento(m.group(1), m.group(2).trim(), m.group(3).trim());
            }
        }
        return last;
    }

    // The reason crearIntervencion wrote before "Abierta por:"; null when the separator is not there.
    private static String manualReason(String description) {
        if (String.isBlank(description)) {
            return null;
        }
        String normalized = description.replace('\r\n', '\n');
        if (!normalized.contains(OPENED_BY_MARKER)) {
            return null;
        }
        String reason = normalized.substringBefore(OPENED_BY_MARKER).trim();
        return String.isBlank(reason) ? null : reason;
    }

    // One reading per asset + measurement type; the newest occurredAt wins, ties go to the higher severity (D003).
    private static Map<Id, Map<String, Lectura_Vigente__c>> latestReadings(Set<Id> assetIds, List<Boolean> capped) {
        Map<Id, Map<String, Lectura_Vigente__c>> latest = new Map<Id, Map<String, Lectura_Vigente__c>>();
        // No recency window: a quiet asset's reading must not fall outside it. Lectura_Vigente__c is assumed to hold
        // only valid readings (invalid messages are rejected before write, T2.12), so no validity filter here.
        Integer readingCap = assetIds.size() * READING_TYPES;
        Integer readingFetch = readingCap + 1;
        Integer readingRows = 0;
        for (Lectura_Vigente__c r : [
            SELECT Asset__c, Tipo_Medicion__c, Valor__c, Unidad__c, Occurred_At__c, Severidad_Nivel__c, Sensor_Id__c
            FROM Lectura_Vigente__c
            WHERE Asset__c IN :assetIds
            WITH USER_MODE
            LIMIT :readingFetch
        ]) {
            if (++readingRows > readingCap) {
                capped[0] = true;
                break;
            }
            Map<String, Lectura_Vigente__c> byType = latest.get(r.Asset__c);
            if (byType == null) {
                byType = new Map<String, Lectura_Vigente__c>();
                latest.put(r.Asset__c, byType);
            }
            Lectura_Vigente__c current = byType.get(r.Tipo_Medicion__c);
            if (current == null || isBetter(r, current)) {
                byType.put(r.Tipo_Medicion__c, r);
            }
        }
        return latest;
    }

    // Open means Case.IsClosed = false; newest first.
    private static Map<Id, List<Case>> openInterventions(Set<Id> assetIds, List<Boolean> capped) {
        Map<Id, List<Case>> byAsset = new Map<Id, List<Case>>();
        Integer caseFetch = MAX_CASE_ROWS + 1;
        Integer caseRows = 0;
        for (Case c : [
            SELECT Id, CaseNumber, Subject, Status, CreatedDate, AssetId
            FROM Case
            WHERE AssetId IN :assetIds AND IsClosed = false
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT :caseFetch
        ]) {
            if (++caseRows > MAX_CASE_ROWS) {
                capped[0] = true;
                break;
            }
            if (!byAsset.containsKey(c.AssetId)) {
                byAsset.put(c.AssetId, new List<Case>());
            }
            byAsset.get(c.AssetId).add(c);
        }
        return byAsset;
    }

    // Last closed Case (newest ClosedDate) of each given asset, for the "Última intervención" line (D038). One query for
    // any number of assets; any closed Case counts (no time window). Newest first, so the first row seen for an asset is
    // its last one. Past maxClosedCaseRows an asset whose closed Cases all fall after the cut gets none and simply shows no
    // "Última intervención", as before this lookup existed. `capped` is not set: the list's truncated flag means assets or
    // severities may be missing, and this line is only context. WITH USER_MODE: a Case the user cannot see is never returned.
    private static Map<Id, Case> lastClosedInterventions(Set<Id> assetIds) {
        Map<Id, Case> byAsset = new Map<Id, Case>();
        if (assetIds.isEmpty()) {
            return byAsset;
        }
        Integer closedFetch = maxClosedCaseRows;
        for (Case c : [
            SELECT Id, CaseNumber, ClosedDate, AssetId
            FROM Case
            WHERE AssetId IN :assetIds AND IsClosed = true
            WITH USER_MODE
            ORDER BY ClosedDate DESC, Id DESC
            LIMIT :closedFetch
        ]) {
            if (!byAsset.containsKey(c.AssetId)) {
                byAsset.put(c.AssetId, c);
            }
        }
        return byAsset;
    }

    private static Boolean isBetter(Lectura_Vigente__c candidate, Lectura_Vigente__c current) {
        if (candidate.Occurred_At__c != current.Occurred_At__c) {
            return candidate.Occurred_At__c > current.Occurred_At__c;
        }
        if (rank(candidate) != rank(current)) {
            return rank(candidate) > rank(current);
        }
        // Final tie-break by record Id; D003's messageId step belongs to ingestion (no messageId on this object).
        return String.valueOf(candidate.Id) > String.valueOf(current.Id);
    }

    // Highest level among an asset's latest readings; -1 when it has none (no reading carries a level).
    private static Integer highestLevel(Map<String, Lectura_Vigente__c> byType) {
        Integer best = -1;
        if (byType != null) {
            for (Lectura_Vigente__c r : byType.values()) {
                best = Math.max(best, rank(r));
            }
        }
        return best;
    }

    private static Integer rank(Lectura_Vigente__c r) {
        Integer level = levelOf(r);
        return level == null ? -1 : level;
    }

    private static Integer levelOf(Lectura_Vigente__c r) {
        return r.Severidad_Nivel__c == null ? null : r.Severidad_Nivel__c.intValue();
    }

    // Same wording as the Severidad__c formula on Lectura_Vigente__c.
    private static String labelFor(Integer level) {
        if (level == null) {
            return 'Sin dato';
        }
        return level >= 2 ? 'Crítica' : (level == 1 ? 'Advertencia' : 'Normal');
    }

    private static Id parseId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (Exception e) {
            throw safeError(BUILDING_FILTER_MESSAGE);
        }
    }

    // Static messages only: access-type failures vs anything else; never echo the platform message.
    private static AuraHandledException failure(Exception e) {
        // Debug log only; the user-facing message stays static.
        System.debug(LoggingLevel.ERROR, 'ActivosOperador failure: ' + e.getTypeName() + ': ' + e.getMessage());
        if (e instanceof QueryException || e instanceof NoAccessException) {
            return safeError(ACCESS_MESSAGE);
        }
        return safeError(LOAD_MESSAGE);
    }

    private static AuraHandledException safeError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
