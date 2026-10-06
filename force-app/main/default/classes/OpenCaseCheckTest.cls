/**
 * Tests for OpenCaseCheck. Its answer must not depend on who runs it: with Case private, a user who cannot see the open
 * Case (owned by someone else, outside their hierarchy) must still get true.
 */
@isTest
private class OpenCaseCheckTest {

    private static Asset newAsset(String code, Id ownerId) {
        Account building = new Account(Name = 'Edificio ' + code, OwnerId = ownerId);
        insert building;
        Asset asset = new Asset(Name = 'Activo ' + code, AccountId = building.Id, Tipo_Activo__c = 'WATER_PUMP', External_Id__c = code);
        insert asset;
        return asset;
    }

    private static User newOperator(String prefix) {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
            List<UserRole> roles = [SELECT Id FROM UserRole WHERE DeveloperName = 'Operador_Edificios'];
            Assert.areEqual(1, roles.size(), 'Operador_Edificios must be deployed to the org');
            String suffix = String.valueOf(Crypto.getRandomInteger()).replace('-', 'n');
            u = new User(
                Username = prefix + '.' + suffix + '@novacasa-test.example.com',
                Alias = prefix.right(8),
                Email = prefix + '@novacasa-test.example.com',
                LastName = prefix,
                ProfileId = p.Id,
                TimeZoneSidKey = 'America/Bogota',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                UserRoleId = roles[0].Id
            );
            insert u;
            List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name = 'Nova_Casa_Operator'];
            Assert.areEqual(1, sets.size(), 'Nova_Casa_Operator must be deployed to the org');
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = sets[0].Id);
        }
        return u;
    }

    @isTest
    static void shouldReturnTrue_WhenTheAssetHasAnOpenCase() {
        Asset asset = newAsset('AST-OCC-1', UserInfo.getUserId());
        insert new Case(AssetId = asset.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Abierta');

        Assert.isTrue(OpenCaseCheck.existsFor(asset.Id));
    }

    @isTest
    static void shouldReturnFalse_WhenTheOnlyCaseIsClosed() {
        Asset asset = newAsset('AST-OCC-2', UserInfo.getUserId());
        insert new Case(AssetId = asset.Id, Status = 'Closed', Origin = 'Telemetria', Subject = 'Cerrada');

        Assert.isFalse(OpenCaseCheck.existsFor(asset.Id));
    }

    @isTest
    static void shouldReturnFalse_WhenTheAssetHasNoCaseOrIsNull() {
        Asset asset = newAsset('AST-OCC-3', UserInfo.getUserId());

        Assert.isFalse(OpenCaseCheck.existsFor(asset.Id));
        Assert.isFalse(OpenCaseCheck.existsFor(null), 'A null asset must not match Cases without an asset');
    }

    @isTest
    static void shouldReturnTrue_WhenTheOpenCaseIsInvisibleToTheRunningUser() {
        User operator = newOperator('ncocc');
        Asset asset = newAsset('AST-OCC-4', UserInfo.getUserId());
        Case existing = new Case(AssetId = asset.Id, Status = 'En curso', Origin = 'Telemetria', Subject = 'Abierta');
        insert existing;

        Boolean found;
        Integer visible;
        System.runAs(operator) {
            visible = [SELECT COUNT() FROM Case WHERE Id = :existing.Id WITH USER_MODE];
            found = OpenCaseCheck.existsFor(asset.Id);
        }

        Assert.areEqual(0, visible, 'Precondition: the running user cannot see the Case');
        Assert.isTrue(found, 'The check must see the Case regardless of sharing');
    }
}
