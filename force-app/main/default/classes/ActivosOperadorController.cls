/**
 * Read side of the operator screen (US-207, BR-207/BR-208).
 * Runs with the operator's own CRUD/FLS/sharing: it never relies on the ingestion's SYSTEM_MODE path.
 */
public with sharing class ActivosOperadorController {

    // Ceiling: severity is computed over at most maxScan assets (5 measurement types => <= 5x readings),
    // ~30k rows of the 50k SOQL row limit; beyond that `truncated` is set. Only pageSize assets are returned.
    @TestVisible private static Integer maxScan = 5000;
    @TestVisible private static Integer pageSize = 100;
    @TestVisible private static Integer maxBuildings = 2000;
    private static final Integer READING_TYPES = 5;
    private static final Integer MAX_CASE_ROWS = 2000;
    @TestVisible private static final String ACCESS_MESSAGE = 'You do not have access to all the information needed for this list.';
    @TestVisible private static final String LOAD_MESSAGE = 'The information could not be loaded. Try again later.';

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

        public AssetView(Asset a, List<ReadingView> readings, List<Case> openCases) {
            this.assetId = a.Id;
            this.name = a.Name;
            this.externalId = a.External_Id__c;
            this.assetType = a.Tipo_Activo__c;
            this.accountId = a.AccountId;
            this.accountName = a.Account?.Name;
            this.readings = readings;
            this.openInterventionCount = openCases.size();
            this.openIntervention = openCases.isEmpty() ? null : new InterventionView(openCases[0]);
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
     * Assets the running user can see, most severe first, with latest readings and open intervention.
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
                throw safeError('The severity filter is not valid.');
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
                page.add(new AssetView(a, readings, cases));
            }
            return new AssetPage(page, total, pageSize, truncated || total > shown || capped[0]);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw failure(e);
        }
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
            throw safeError('The building filter is not valid.');
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
