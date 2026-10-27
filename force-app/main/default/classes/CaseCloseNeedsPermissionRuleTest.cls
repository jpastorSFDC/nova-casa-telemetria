/**
 * Tests the Case validation rule Cierre_Exige_Permiso_Seguimiento (D052): moving a Case to Closed needs the custom
 * permission Nova_Casa_Seguir_Intervencion, the same key the operator console checks (D035, D036). The rule is what
 * keeps that permission the real gate once the Details tab can offer Closed. Users carry the shipped permission sets, so
 * these also fail if the permission is dropped from the coordinator or Admin, or handed to the integration user.
 */
@isTest
private class CaseCloseNeedsPermissionRuleTest {

    private static final String COORDINATOR_ROLE = 'Coordinador_Mantenimiento';
    private static final String INTEGRATION_ROLE = 'Integracion_Telemetria';
    private static final String FOLLOW_UP_PERMISSION = 'Nova_Casa_Seguir_Intervencion';
    private static final String REFUSAL = 'Para cerrar una intervención necesitas el permiso de seguimiento. Pídele a coordinación que la cierre.';
    // Changing a Case's status needs a comment on the Case (D046), so every edit below carries one and only D052 can refuse.
    private static final String COMMENTED = 'Original\n[2026-10-27 10:00 Prueba] Comentario del cambio';

    // ─── Helpers ──────────────────────────────────────────────────────────

    // roleName may be null.
    private static User newUserWithPermissionSet(String prefix, String permissionSetName, String roleName) {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<PermissionSet> sets = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName];
            Assert.areEqual(1, sets.size(), permissionSetName + ' must be deployed to the org');
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
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
                UserRoleId = roleName == null ? null : roleId(roleName)
            );
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = sets[0].Id);
        }
        return u;
    }

    private static Id roleId(String developerName) {
        List<UserRole> roles = [SELECT Id FROM UserRole WHERE DeveloperName = :developerName];
        Assert.areEqual(1, roles.size(), developerName + ' must be deployed to the org');
        return roles[0].Id;
    }

    private static Case newCase(String status, Id ownerId) {
        Case c = new Case(Status = status, Origin = 'Telemetria', Subject = 'Abierta', Description = 'Original', OwnerId = ownerId);
        insert c;
        return c;
    }

    // ─── The rule refuses a closing without the key ───────────────────────

    @isTest
    static void shouldRefuseClosing_WhenTheUserLacksTheFollowUpPermission() {
        // The integration user is the one account that can edit Cases without holding the key.
        User integration = newUserWithPermissionSet('ncclsrul1', 'Nova_Casa_Procesamiento', INTEGRATION_ROLE);
        // Owned by the integration user: with private Case sharing it has View All, not Edit, on what others own, so
        // anything else could be refused for sharing instead of for the rule.
        Case c = newCase('En curso', integration.Id);

        String message;
        StatusCode code;
        List<String> fields;
        System.runAs(integration) {
            Assert.isFalse(FeatureManagement.checkPermission(FOLLOW_UP_PERMISSION), 'Premise: this user lacks the key');
            Assert.isTrue(Schema.sObjectType.Case.isUpdateable(), 'Premise: this user can edit Cases, or this proves nothing');
            try {
                update new Case(Id = c.Id, Status = 'Closed', Description = COMMENTED);
            } catch (DmlException e) {
                message = e.getDmlMessage(0);
                code = e.getDmlType(0);
                fields = e.getDmlFieldNames(0);
            }
        }

        Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, code, 'The validation rule refuses it');
        Assert.areEqual(REFUSAL, message);
        Assert.isTrue(fields.contains('Status'), 'The error sits on the Status field');
        Case after = [SELECT Status, IsClosed, Description FROM Case WHERE Id = :c.Id];
        Assert.areEqual('En curso', after.Status, 'The Case stays open');
        Assert.isFalse(after.IsClosed);
        Assert.areEqual('Original', after.Description, 'Nothing of the refused edit was saved');
    }

    @isTest
    static void shouldJudgeEveryCaseOfABulkEditOnItsOwn() {
        User integration = newUserWithPermissionSet('ncclsrul2', 'Nova_Casa_Procesamiento', INTEGRATION_ROLE);
        List<Case> cases = new List<Case>{ newCase('En curso', integration.Id), newCase('En curso', integration.Id) };

        // One Case is closed and the other only put on hold: only the closing is refused.
        List<Case> edits = new List<Case>{
            new Case(Id = cases[0].Id, Status = 'Closed', Description = COMMENTED),
            new Case(Id = cases[1].Id, Status = 'On Hold', Description = COMMENTED)
        };
        List<Database.SaveResult> results;
        System.runAs(integration) {
            results = Database.update(edits, false);
        }

        Assert.isFalse(results[0].isSuccess(), 'The closing is refused');
        Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, results[0].getErrors()[0].getStatusCode());
        Assert.isTrue(results[1].isSuccess(), 'The other status change is saved');
        Assert.areEqual('En curso', [SELECT Status FROM Case WHERE Id = :cases[0].Id].Status);
        Assert.areEqual('On Hold', [SELECT Status FROM Case WHERE Id = :cases[1].Id].Status);
    }

    // ─── The rule lets the holders of the key close ───────────────────────

    @isTest
    static void shouldAllowClosing_WhenTheUserIsTheCoordinator() {
        User coordinator = newUserWithPermissionSet('ncclsrul3', 'Nova_Casa_Coordinator', COORDINATOR_ROLE);
        Case c = newCase('En curso', coordinator.Id);

        System.runAs(coordinator) {
            Assert.isTrue(FeatureManagement.checkPermission(FOLLOW_UP_PERMISSION), 'Premise: the coordinator holds the key');
            update new Case(Id = c.Id, Status = 'Closed', Description = COMMENTED);
        }

        Case after = [SELECT Status, IsClosed FROM Case WHERE Id = :c.Id];
        Assert.areEqual('Closed', after.Status);
        Assert.isTrue(after.IsClosed, 'The coordinator closed it');
    }

    @isTest
    static void shouldAllowClosing_WhenTheUserIsTheAdminPersona() {
        User admin = newUserWithPermissionSet('ncclsrul4', 'Nova_Casa_Admin', null);
        Case c = newCase('En curso', admin.Id);

        System.runAs(admin) {
            Assert.isTrue(FeatureManagement.checkPermission(FOLLOW_UP_PERMISSION), 'Premise: Admin holds the key');
            update new Case(Id = c.Id, Status = 'Closed', Description = COMMENTED);
        }

        Assert.isTrue([SELECT IsClosed FROM Case WHERE Id = :c.Id].IsClosed, 'The Admin persona closed it');
    }

    // ─── The rule stays out of everything that is not a closing ───────────

    @isTest
    static void shouldNotGetInTheWayOfOtherEdits_ForAUserWithoutTheKey() {
        User integration = newUserWithPermissionSet('ncclsrul5', 'Nova_Casa_Procesamiento', INTEGRATION_ROLE);
        Case c = newCase('En curso', integration.Id);

        System.runAs(integration) {
            // Ingestion creates Cases in bulk, already in their first status, in SYSTEM_MODE (IntervencionService), so
            // the integration user's field permissions do not apply: there is nothing to guard at creation.
            List<Case> created = new List<Case>();
            for (Integer i = 0; i < 200; i++) {
                created.add(new Case(Status = 'En curso', Origin = 'Telemetria', Subject = 'Ingesta ' + i));
            }
            Database.insert(created, true, AccessLevel.SYSTEM_MODE);

            update new Case(Id = c.Id, Status = 'On Hold', Description = COMMENTED);
            update new Case(Id = c.Id, Subject = 'Otro asunto');
        }

        Assert.areEqual(200, [SELECT COUNT() FROM Case WHERE Subject LIKE 'Ingesta %']);
        Case after = [SELECT Status, Subject FROM Case WHERE Id = :c.Id];
        Assert.areEqual('On Hold', after.Status, 'A status change that is not a closing is saved');
        Assert.areEqual('Otro asunto', after.Subject, 'An edit that leaves the status alone is saved');
    }

    @isTest
    static void shouldNotRefuseAnEditThatLeavesTheCaseClosed_ForAUserWithoutTheKey() {
        User integration = newUserWithPermissionSet('ncclsrul6', 'Nova_Casa_Procesamiento', INTEGRATION_ROLE);
        // Already Closed (the rule is not evaluated on creation): the rule judges the change to Closed, not the state.
        Case c = newCase('Closed', integration.Id);

        System.runAs(integration) {
            update new Case(Id = c.Id, Subject = 'Otro asunto', Status = 'Closed');
        }

        Case after = [SELECT Status, IsClosed, Subject FROM Case WHERE Id = :c.Id];
        Assert.areEqual('Otro asunto', after.Subject, 'The edit is saved');
        Assert.isTrue(after.IsClosed, 'The Case is still closed');
    }

    // ─── The rule names Closed, so a second closed status would be a way around it ───

    @isTest
    static void shouldCoverEveryClosedStatus() {
        List<CaseStatus> closedStatuses = [SELECT ApiName FROM CaseStatus WHERE IsClosed = true];

        Assert.areEqual(1, closedStatuses.size(),
            'Extend the formula of Cierre_Exige_Permiso_Seguimiento to the new closed status, then update this test');
        Assert.areEqual('Closed', closedStatuses[0].ApiName, 'The rule names Closed');
    }
}
