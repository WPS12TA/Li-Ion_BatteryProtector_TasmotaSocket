# Li-Ion_BatteryProtector_TasmotaSocket
#  Rationale
Some people say that Li-Ion cells are relatively more stressed by maximum 100% charges and deep discharges. Circuits should be already designed with this in mind, however this makes stopping before maximum charging explicit. It should encourage more frequent charges that stop before 100% capacity.
This Berry script, running on a Tasmota ESP32 mains socket with power monitoring, is designed to terminate the final stages of Li-Ion battery charger phases as they 'Top Off' a battery on re-charging. In theory, this should improve the life of an eBike battery.
It assumes you prioritise overall battery life over maximum ride duration on next ride and can charge easily via an ESP32 Tasmota controlled mains socket. It possibly might improve safety? 
#  Method
The script monitors power draw and simply shuts off when the mains power intake draw starts to drop through a pre-defined threshold, having assessed the high plateau level.
#  Reporting
It uses MQTT to publish progress and gives progress output on the Tasmota console too.
#  How to use
The file requires 3 simple edits at the top. Autoexec.be file names a Berry Script which loads automatically on a Tasmota restart. One edit easily deactivates or reactivates the script on the next Tasmota restart. The next defines the base MQTT topic. The next is just used for version reporting. 
#  Limitations
The Berry scripting language must be activated and I believe this requires an ESP32 based socket. Cheaper sockets may only use an ESP8266 or similar without the memory or processor to run Berry.
