/**
 * Tests the Case validation rule Comentario_Obligatorio_Cambio_Estado (D046): changing Status needs Description to
 * change in the same edit. The rule is the one check that covers every way of editing a Case, such as the Details tab.
 */
@isTest
private class CaseStatusCommentRuleTest {

    private static Case newCase(String status) {
        Case c = new Case(Status = status, Origin = 'Telemetria', Subject = 'Abierta', Description = 'Original');
        insert c;
        return c;
    }

    @isTest
    static void shouldRefuseTheEdit_WhenStatusChangesWithoutAComment() {
        Case c = newCase('En curso');

        String message;
        StatusCode code;
        try {
            update new Case(Id = c.Id, Status = 'On Hold');
        } catch (DmlException e) {
            message = e.getDmlMessage(0);
            code = e.getDmlType(0);
        }

        Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, code, 'The validation rule refuses it');
        Assert.areEqual('Para cambiar el estado, agrega un comentario en la descripción.', message);
        Case after = [SELECT Status, Description FROM Case WHERE Id = :c.Id];
        Assert.areEqual('En curso', after.Status, 'The status did not change');
        Assert.areEqual('Original', after.Description);
    }

    @isTest
    static void shouldRefuseTheEdit_WhenTheDescriptionIsSavedUnchanged() {
        Case c = newCase('En curso');

        Boolean refused = false;
        try {
            update new Case(Id = c.Id, Status = 'Closed', Description = 'Original');
        } catch (DmlException e) {
            refused = e.getDmlType(0) == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION;
        }

        Assert.isTrue(refused, 'Saving the same text is not leaving a comment');
        Assert.areEqual('En curso', [SELECT Status FROM Case WHERE Id = :c.Id].Status);
    }

    @isTest
    static void shouldAllowTheEdit_WhenTheDescriptionChangesWithTheStatus() {
        Case c = newCase('En curso');

        update new Case(Id = c.Id, Status = 'Closed', Description = 'Original\n[2026-10-23 10:00 Coordinación] Resuelto');

        Case after = [SELECT Status, IsClosed, Description FROM Case WHERE Id = :c.Id];
        Assert.isTrue(after.IsClosed, 'The status changed');
        Assert.isTrue(after.Description.endsWith('Resuelto'), 'The comment was kept');
    }

    @isTest
    static void shouldNotAskForAComment_WhenTheStatusDoesNotChange() {
        Case c = newCase('En curso');

        update new Case(Id = c.Id, Subject = 'Otro asunto', Status = 'En curso');

        Assert.areEqual('Otro asunto', [SELECT Subject FROM Case WHERE Id = :c.Id].Subject);
    }

    @isTest
    static void shouldNotAskForAComment_WhenTheCaseIsCreated() {
        // Ingestion creates the Case already in its first status; there is nothing to comment on yet.
        List<Case> created = new List<Case>();
        for (Integer i = 0; i < 200; i++) {
            created.add(new Case(Status = 'En curso', Origin = 'Telemetria', Subject = 'Caso ' + i));
        }

        insert created;

        Assert.areEqual(200, [SELECT COUNT() FROM Case WHERE Subject LIKE 'Caso %']);
    }

    @isTest
    static void shouldJudgeEveryCaseOfABulkEditOnItsOwn() {
        List<Case> cases = new List<Case>{ newCase('En curso'), newCase('En curso') };

        // One Case carries a comment and the other does not: only the second one is refused.
        List<Case> edits = new List<Case>{
            new Case(Id = cases[0].Id, Status = 'On Hold', Description = 'Original\n[2026-10-23 10:00 Coordinación] En espera'),
            new Case(Id = cases[1].Id, Status = 'On Hold')
        };
        List<Database.SaveResult> results = Database.update(edits, false);

        Assert.isTrue(results[0].isSuccess(), 'The one with a comment is saved');
        Assert.isFalse(results[1].isSuccess(), 'The one without is refused');
        Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, results[1].getErrors()[0].getStatusCode());
        Assert.areEqual('On Hold', [SELECT Status FROM Case WHERE Id = :cases[0].Id].Status);
        Assert.areEqual('En curso', [SELECT Status FROM Case WHERE Id = :cases[1].Id].Status);
    }
}
