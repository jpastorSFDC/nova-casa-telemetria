/**
 * Loads the building/asset catalog from the Nova Casa Simulator (GET /catalog)
 *              and upserts it into Account (building) and Asset (asset) records,
 *              keyed by External_Id__c so a repeated run never duplicates data. Also seeds
 *              Umbral__c with the reference thresholds for each asset type + measurement.
 */
public with sharing class CatalogoService {

    // ─── Constants ───────────────────────────────────────────────────────
    private static final String CATALOG_ENDPOINT = 'callout:Nova_Casa_Simulator/catalog';
    private static final String HTTP_GET = 'GET';

    // /catalog's thresholdsReference gives ranges, not operators, so this seed table holds the team's
    // proposed reference values from T2.7; operators/values await facilitator confirmation (AGENTS.md pendiente 1).
    private static final Map<String, List<ThresholdRule>> RULES_BY_MEASUREMENT = buildReferenceRules();

    // ─── Public API ──────────────────────────────────────────────────────

    /**
     * Fetches the catalog from the simulator and upserts buildings and assets.
     *              Currently an operator/admin-triggered bootstrap action, invoked manually via
     *              Execute Anonymous per README's "Loading the building/asset catalog" section —
     *              not part of the automated signal-ingestion pipeline. If this is ever wired into
     *              an automated/scheduled path, revisit the AccessLevel/permission-set scoping
     *              against BR-208 and the ingestion-permissions agreement in AGENTS.md.
     * @throws CatalogoServiceException if the callout fails or the response can't be parsed
     * @example
     * CatalogoService.loadCatalog();
     */
    public static void loadCatalog() {
        CatalogResponse catalogResponse = fetchCatalog();
        upsertBuildingsAndAssets(catalogResponse);
        seedThresholds(catalogResponse);
    }

    // ─── Private Helpers ─────────────────────────────────────────────────

    /**
     * Calls GET /catalog via the Nova_Casa_Simulator Named Credential.
     * @return The deserialized catalog response
     * @throws CatalogoServiceException if the callout fails or the body can't be parsed
     */
    private static CatalogResponse fetchCatalog() {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(CATALOG_ENDPOINT);
        request.setMethod(HTTP_GET);

        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (CalloutException e) {
            throw new CatalogoServiceException('GET /catalog callout failed: ' + e.getMessage(), e);
        }

        if (response.getStatusCode() != 200) {
            throw new CatalogoServiceException(
                'GET /catalog returned status ' + response.getStatusCode() + ': ' + response.getBody()
            );
        }

        try {
            return (CatalogResponse) JSON.deserialize(response.getBody(), CatalogResponse.class);
        } catch (JSONException e) {
            throw new CatalogoServiceException('GET /catalog returned an unparsable body: ' + e.getMessage(), e);
        }
    }

    /**
     * Upserts the buildings and assets from a catalog response.
     * @param catalogResponse The deserialized catalog response
     * @throws CatalogoServiceException if the upsert DML fails
     */
    private static void upsertBuildingsAndAssets(CatalogResponse catalogResponse) {
        List<BuildingWrapper> buildings = catalogResponse?.catalog?.buildings;
        if (buildings == null || buildings.isEmpty()) {
            return;
        }

        Map<String, Id> buildingIdByExternalId = upsertBuildings(buildings);
        upsertAssets(buildings, buildingIdByExternalId);
    }

    /**
     * Upserts one Account per building, keyed by External_Id__c.
     * @param buildings The buildings from the catalog response
     * @return Map of building External_Id__c to its Account Id
     * @throws CatalogoServiceException if the upsert DML fails
     */
    private static Map<String, Id> upsertBuildings(List<BuildingWrapper> buildings) {
        List<Account> buildingAccounts = new List<Account>();
        for (BuildingWrapper building : buildings) {
            buildingAccounts.add(new Account(
                External_Id__c = building.id,
                Name = building.name
            ));
        }

        // Explicit CRUD pre-check: with no object access, the USER_MODE upsert below failed with a raw
        // "Access to entity denied" that the catch block did not wrap into CatalogoServiceException.
        if (!Schema.sObjectType.Account.isCreateable() || !Schema.sObjectType.Account.isUpdateable()) {
            throw new CatalogoServiceException('Failed to upsert building Accounts: running user lacks create/edit access on Account');
        }

        try {
            Database.upsert(buildingAccounts, Account.External_Id__c, AccessLevel.USER_MODE);
        } catch (Exception e) {
            throw new CatalogoServiceException('Failed to upsert building Accounts: ' + e.getMessage(), e);
        }

        Map<String, Id> buildingIdByExternalId = new Map<String, Id>();
        for (Account buildingAccount : buildingAccounts) {
            buildingIdByExternalId.put(buildingAccount.External_Id__c, buildingAccount.Id);
        }
        return buildingIdByExternalId;
    }

    /**
     * Upserts one Asset per catalog asset, keyed by External_Id__c and linked to its building.
     * @param buildings The buildings from the catalog response
     * @param buildingIdByExternalId Map of building External_Id__c to its Account Id
     * @throws CatalogoServiceException if the upsert DML fails
     */
    private static void upsertAssets(List<BuildingWrapper> buildings, Map<String, Id> buildingIdByExternalId) {
        List<Asset> assets = new List<Asset>();
        for (BuildingWrapper building : buildings) {
            if (building.assets == null) {
                continue;
            }
            for (AssetWrapper asset : building.assets) {
                assets.add(new Asset(
                    External_Id__c = asset.id,
                    Name = asset.name,
                    Tipo_Activo__c = asset.type,
                    AccountId = buildingIdByExternalId.get(building.id)
                ));
            }
        }

        if (assets.isEmpty()) {
            return;
        }

        if (!Schema.sObjectType.Asset.isCreateable() || !Schema.sObjectType.Asset.isUpdateable()) {
            throw new CatalogoServiceException('Failed to upsert Assets: running user lacks create/edit access on Asset');
        }

        try {
            Database.upsert(assets, Asset.External_Id__c, AccessLevel.USER_MODE);
        } catch (Exception e) {
            throw new CatalogoServiceException('Failed to upsert Assets: ' + e.getMessage(), e);
        }
    }

    /**
     * Seeds Umbral__c for each distinct asset type + measurement in the catalog. A combination
     *              that already has any Umbral__c is skipped, so edited, deactivated or deleted
     *              thresholds are never overwritten or resurrected and a reload adds nothing.
     * @param catalogResponse The deserialized catalog response
     * @throws CatalogoServiceException if access is missing or the query/insert fails
     */
    private static void seedThresholds(CatalogResponse catalogResponse) {
        Map<String, AssetWrapper> assetByCombination = new Map<String, AssetWrapper>();
        for (BuildingWrapper building : catalogResponse?.catalog?.buildings ?? new List<BuildingWrapper>()) {
            for (AssetWrapper asset : building.assets ?? new List<AssetWrapper>()) {
                if (asset.type == null || asset.measurement == null || asset.unit == null
                    || !RULES_BY_MEASUREMENT.containsKey(asset.measurement)) {
                    continue;
                }
                String combination = asset.type + '|' + asset.measurement;
                if (!assetByCombination.containsKey(combination)) {
                    assetByCombination.put(combination, asset);
                }
            }
        }
        if (assetByCombination.isEmpty()) {
            return;
        }

        if (!Schema.sObjectType.Umbral__c.isAccessible() || !Schema.sObjectType.Umbral__c.isCreateable()) {
            throw new CatalogoServiceException('Failed to seed Umbral__c: running user lacks read/create access on Umbral__c');
        }

        Set<String> assetTypes = new Set<String>();
        for (AssetWrapper asset : assetByCombination.values()) {
            assetTypes.add(asset.type);
        }

        Set<String> seededCombinations = new Set<String>();
        try {
            for (Umbral__c existing : [
                SELECT Tipo_Activo__c, Tipo_Medicion__c
                FROM Umbral__c
                WHERE Tipo_Activo__c IN :assetTypes
                WITH USER_MODE
            ]) {
                seededCombinations.add(existing.Tipo_Activo__c + '|' + existing.Tipo_Medicion__c);
            }
        } catch (Exception e) {
            throw new CatalogoServiceException('Failed to seed Umbral__c: ' + e.getMessage(), e);
        }

        List<Umbral__c> thresholds = new List<Umbral__c>();
        for (String combination : assetByCombination.keySet()) {
            if (seededCombinations.contains(combination)) {
                continue;
            }
            AssetWrapper asset = assetByCombination.get(combination);
            for (ThresholdRule rule : RULES_BY_MEASUREMENT.get(asset.measurement)) {
                thresholds.add(new Umbral__c(
                    Tipo_Activo__c = asset.type,
                    Tipo_Medicion__c = asset.measurement,
                    Unidad_Esperada__c = asset.unit,
                    Severidad__c = rule.severity,
                    Operador__c = rule.comparison,
                    Valor__c = rule.limitValue
                ));
            }
        }
        if (thresholds.isEmpty()) {
            return;
        }

        try {
            Database.insert(thresholds, AccessLevel.USER_MODE);
        } catch (Exception e) {
            throw new CatalogoServiceException('Failed to seed Umbral__c: ' + e.getMessage(), e);
        }
    }

    /**
     * Builds the reference threshold rules keyed by measurement type.
     * @return Map of measurement type to its threshold rules
     */
    private static Map<String, List<ThresholdRule>> buildReferenceRules() {
        List<ThresholdRule> rules = new List<ThresholdRule>{
            new ThresholdRule('TEMPERATURE', 'Advertencia', 'LT', 18),
            new ThresholdRule('TEMPERATURE', 'Advertencia', 'GT', 30),
            new ThresholdRule('TEMPERATURE', 'Critica', 'LT', 15),
            new ThresholdRule('TEMPERATURE', 'Critica', 'GT', 35),
            new ThresholdRule('TEMPERATURE', 'Invalida', 'LE', -11),
            new ThresholdRule('TEMPERATURE', 'Invalida', 'GE', 81),
            new ThresholdRule('WATER_PRESSURE', 'Advertencia', 'LT', 2.5),
            new ThresholdRule('WATER_PRESSURE', 'Advertencia', 'GT', 4),
            new ThresholdRule('WATER_PRESSURE', 'Critica', 'LT', 1.5),
            new ThresholdRule('WATER_PRESSURE', 'Critica', 'GT', 5),
            new ThresholdRule('WATER_PRESSURE', 'Invalida', 'GT', 20),
            new ThresholdRule('WATER_CONSUMPTION', 'Advertencia', 'GT', 400),
            new ThresholdRule('WATER_CONSUMPTION', 'Critica', 'GT', 650),
            new ThresholdRule('WATER_CONSUMPTION', 'Invalida', 'LT', 0),
            new ThresholdRule('WATER_CONSUMPTION', 'Invalida', 'GT', 5000),
            new ThresholdRule('ENERGY_CONSUMPTION', 'Advertencia', 'GT', 40),
            new ThresholdRule('ENERGY_CONSUMPTION', 'Critica', 'GT', 65),
            new ThresholdRule('ENERGY_CONSUMPTION', 'Invalida', 'LT', 0),
            new ThresholdRule('ENERGY_CONSUMPTION', 'Invalida', 'GT', 1000),
            new ThresholdRule('CAMERA_CONNECTIVITY', 'Advertencia', 'GT', 90),
            new ThresholdRule('CAMERA_CONNECTIVITY', 'Critica', 'GT', 180)
        };
        Map<String, List<ThresholdRule>> rulesByMeasurement = new Map<String, List<ThresholdRule>>();
        for (ThresholdRule rule : rules) {
            if (!rulesByMeasurement.containsKey(rule.measurement)) {
                rulesByMeasurement.put(rule.measurement, new List<ThresholdRule>());
            }
            rulesByMeasurement.get(rule.measurement).add(rule);
        }
        return rulesByMeasurement;
    }

    // ─── Response Wrappers (GET /catalog shape) ──────────────────────────

    /**
     * Top-level GET /catalog response. Only the fields CatalogoService uses are declared;
     *              JSON.deserialize ignores the rest (contractVersion, scenarios, defaults).
     */
    private class CatalogResponse {
        private CatalogWrapper catalog;
    }

    private class CatalogWrapper {
        private List<BuildingWrapper> buildings;
    }

    private class BuildingWrapper {
        private String id;
        private String name;
        private List<AssetWrapper> assets;
    }

    private class AssetWrapper {
        private String id;
        private String name;
        private String type;
        private String measurement;
        private String unit;
    }

    private class ThresholdRule {
        private String measurement;
        private String severity;
        private String comparison;
        private Decimal limitValue;

        private ThresholdRule(String measurement, String severity, String comparison, Decimal limitValue) {
            this.measurement = measurement;
            this.severity = severity;
            this.comparison = comparison;
            this.limitValue = limitValue;
        }
    }

    // ─── Exception ───────────────────────────────────────────────────────

    /**
     * Custom exception for CatalogoService errors
     */
    public class CatalogoServiceException extends Exception {}
}
