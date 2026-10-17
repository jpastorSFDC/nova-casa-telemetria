trigger UmbralTrigger on Umbral__c (before insert, before update) {
    UmbralValidador.validar(Trigger.new);
}
