/**
 * Answers one question for IntervencionOperadorController: does this asset already have an open Case?
 * `without sharing` and an explicit SYSTEM_MODE query on purpose: with Case Private the caller may not see a Case owned
 * by someone else, and a duplicate intervention must still be refused. A plain inline SOQL did not bypass sharing for a
 * user running under System.runAs (it counted 0), the explicit access level did. It returns a Boolean only, never a
 * Case or any field of it, and the caller checks the custom permission and the asset visibility (USER_MODE) first.
 */
public without sharing class OpenCaseCheck {

    public static Boolean existsFor(Id assetId) {
        Integer open = Database.countQueryWithBinds(
            'SELECT COUNT() FROM Case WHERE AssetId = :assetId AND IsClosed = false',
            new Map<String, Object>{ 'assetId' => assetId },
            AccessLevel.SYSTEM_MODE
        );
        return open > 0;
    }
}