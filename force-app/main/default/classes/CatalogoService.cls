/**
 * Loads the building/asset catalog from the Nova Casa Simulator (GET /catalog)
 *              and upserts it into Account (building) and Asset (asset) records,
 *              keyed by External_Id__c so a repeated run never duplicates data.
 */
public with sharing class CatalogoService {

    // ─── Constants ───────────────────────────────────────────────────────
    private static final String CATALOG_ENDPOINT = 'callout:Nova_Casa_Simulator/catalog';
    private static final String HTTP_GET = 'GET';

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

        try {
            Database.upsert(buildingAccounts, Account.External_Id__c, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            throw new CatalogoServiceException('Failed to upsert building Accounts: ' + e.getMessage(), e);
        } catch (System.NoAccessException e) {
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

        try {
            Database.upsert(assets, Asset.External_Id__c, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            throw new CatalogoServiceException('Failed to upsert Assets: ' + e.getMessage(), e);
        } catch (System.NoAccessException e) {
            throw new CatalogoServiceException('Failed to upsert Assets: ' + e.getMessage(), e);
        }
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
    }

    // ─── Exception ───────────────────────────────────────────────────────

    /**
     * Custom exception for CatalogoService errors
     */
    public class CatalogoServiceException extends Exception {}
}
