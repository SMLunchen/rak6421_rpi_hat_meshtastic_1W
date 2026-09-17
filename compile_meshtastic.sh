# installiere abhaengigkeiten
apt install platformio libyaml-cpp-dev git libgpiod-dev libbluetooth-dev libusb-1.0-0-dev libi2c-dev libssl-dev libuv1-dev libulfius-dev liborcania-dev libjsoncpp-dev 

# erzeuge ordner und clone repo
cd /opt/
git clone https://github.com/meshtastic/firmware.git
cd firmware

git tag -l
## aktuellen oder gewuenschten Tag auswaehlen
git checkout v2.8.0.7239fe8 


# submodules laden und initialisieren
git submodule update --init 
git submodule sync --recursive
git submodule update --recursive




pio run -e native
systemctl stop meshtasticd
cp /usr/bin/meshtasticd /usr/bin/meshtasticd.bak
cp .pio/build/native/meshtasticd /usr/bin/meshtasticd
systemctl start meshtasticd
systemctl status meshtasticd
