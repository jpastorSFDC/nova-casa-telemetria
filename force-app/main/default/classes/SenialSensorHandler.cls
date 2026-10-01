public with sharing class SenialSensorHandler {
    @TestVisible
    private static Integer senialesRecibidas = 0;

    public void procesar(List<Senial_Sensor__e> seniales) {
        senialesRecibidas += seniales.size();
        System.debug(LoggingLevel.INFO, 'SenialSensorHandler recibió ' + seniales.size() + ' señales');
    }
}
