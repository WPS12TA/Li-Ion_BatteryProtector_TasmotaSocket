# Li-Ion_BatteryProtector_TasmotaSocket
This Berry script running on a Tasmota ESP32 mains socket, is designed to terminate the final stages of Li-Ion battery charger phases as they 'Top Off' a battery on re-charging. In theory, this should improve the life of an eBike battery.
It assumes you prioritise overall battery life over maximum ride duration on next ride and can charge easily via an ESP32 Tasmota controlled mains socket. It possibly might improve safety? 
# Method
The script monitors power draw and simply shuts off when the mains power intake draw starts to drop through a pre-defined threshold, having assessed the high plateau level.
# Reporting
It uses MQTT to publish progress and gives progress output on the Tasmota console too.
# How to use
The file requires 3 simple edits at the top. Autoexec.be file names a Berry Script which loads automatically on a Tasmota restart. One edit easily deactivates or reactivates the script on the next Tasmota restart. The next defines the base MQTT topic. The next is just used for version reporting.
