/**
 * Read side of the operator screen (US-207, BR-207/BR-208).
 * Runs with the operator's own CRUD/FLS/sharing: it never relies on the ingestion's SYSTEM_MODE path.
 */
public with sharing class ActivosOperadorController {

    @TestVisible private static final Integer MAX_ASSETS = 500;
    @TestVisible private static final Integer MAX_BUILDINGS = 200;
    private static final Integer MAX_CHILD_ROWS = 5000;

    public class Option {
        @AuraEnabled public String value { get; private set; }
        @AuraEnabled public String label { get; private set; }
        public Option(String value, String label) {
            this.value = value;
            this.label = label;
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
     * Assets the running user can see, with latest readings and open intervention.
     * @param accountId building (Account Id); blank means all
     * @param severityLevel 0 normal, 1 warning, 2 critical; null means all
     * @param assetType Asset.Tipo_Activo__c API value; blank means all
     */
    @AuraEnabled(cacheable=true)
    public static List<AssetView> getAssets(String accountId, Integer severityLevel, String assetType) {
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
            String soql = 'SELECT Id, Name, AccountId, Account.Name, Tipo_Activo__c FROM Asset'
                + (conditions.isEmpty() ? '' : ' WHERE ' + String.join(conditions, ' AND '))
                + ' ORDER BY Name LIMIT ' + MAX_ASSETS;
            List<Asset> assets = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);
            if (assets.isEmpty()) {
                return new List<AssetView>();
            }
            Set<Id> assetIds = new Map<Id, Asset>(assets).keySet();

            Map<Id, Map<String, Lectura_Vigente__c>> latest = latestReadings(assetIds);
            Map<Id, List<Case>> openCases = openInterventions(assetIds);

            List<AssetView> result = new List<AssetView>();
            for (Asset a : assets) {
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
                AssetView view = new AssetView(a, readings, cases);
                // Severity is derived from readings, so it is filtered after the query.
                if (severityLevel == null || view.severityLevel == severityLevel) {
                    result.add(view);
                }
            }
            result.sort();
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw safeError('You do not have access to this information or it could not be loaded.');
        }
    }

    /** Buildings (Accounts) that have at least one asset visible to the user. */
    @AuraEnabled(cacheable=true)
    public static List<Option> getBuildings() {
        try {
            List<Option> options = new List<Option>();
            for (Account acc : [
                SELECT Id, Name FROM Account
                WHERE Id IN (SELECT AccountId FROM Asset)
                WITH USER_MODE
                ORDER BY Name
                LIMIT :MAX_BUILDINGS
            ]) {
                options.add(new Option(acc.Id, acc.Name));
            }
            return options;
        } catch (Exception e) {
            throw safeError('You do not have access to this information or it could not be loaded.');
        }
    }

    // One reading per asset + measurement type; the newest occurredAt wins, ties go to the higher severity (D003).
    private static Map<Id, Map<String, Lectura_Vigente__c>> latestReadings(Set<Id> assetIds) {
        Map<Id, Map<String, Lectura_Vigente__c>> latest = new Map<Id, Map<String, Lectura_Vigente__c>>();
        for (Lectura_Vigente__c r : [
            SELECT Asset__c, Tipo_Medicion__c, Valor__c, Unidad__c, Occurred_At__c, Severidad_Nivel__c, Sensor_Id__c
            FROM Lectura_Vigente__c
            WHERE Asset__c IN :assetIds
            WITH USER_MODE
            ORDER BY Occurred_At__c DESC
            LIMIT :MAX_CHILD_ROWS
        ]) {
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
    private static Map<Id, List<Case>> openInterventions(Set<Id> assetIds) {
        Map<Id, List<Case>> byAsset = new Map<Id, List<Case>>();
        for (Case c : [
            SELECT Id, CaseNumber, Subject, Status, CreatedDate, AssetId
            FROM Case
            WHERE AssetId IN :assetIds AND IsClosed = false
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT :MAX_CHILD_ROWS
        ]) {
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
        return rank(candidate) > rank(current);
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

    private static AuraHandledException safeError(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
