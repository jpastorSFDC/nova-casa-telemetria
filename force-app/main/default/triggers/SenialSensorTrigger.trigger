trigger SenialSensorTrigger on Senial_Sensor__e (after insert) {
    new SenialSensorHandler().procesar(Trigger.new);
}
