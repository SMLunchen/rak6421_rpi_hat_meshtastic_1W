# meshtasticd Installation auf Raspberry Pi mit RAK6421 HAT

Getestet mit: Raspberry Pi 4 Model B, Debian 13 (trixie) aarch64, meshtasticd 2.7.15

## Hardware

| Modul | Funktion | Interface |
|-------|----------|-----------|
| RAK6421 | WisBlock Pi HAT | Baseboard |
| RAK 13302 | LoRa SX1262 + SKY66122 PA | SPI (Slot 1) |
| RAK 12501 | GPS (Quectel L76K) | UART |
| RAK 1906 | BME680 Umweltsensor | I2C |

---

## 1. Kernel-Interfaces vorbereiten

In `/boot/firmware/config.txt` muessen folgende Eintraege vorhanden sein:

```ini
dtparam=spi=on
dtoverlay=spi0-0cs
dtparam=i2c_arm=on
dtparam=i2c_vc=on
dtoverlay=i2c0
enable_uart=1

[all]
dtoverlay=disable-bt
```

Erlaeuterungen:

- `spi0-0cs` -- kein Hardware-CS-Pin, meshtasticd steuert CS selbst via GPIO
- `i2c_vc=on` + `i2c0` -- ermoeglicht HAT-EEPROM-Erkennung
- `disable-bt` -- gibt den PL011-UART (`ttyAMA0`) frei, der stabiler ist als der mini-UART (`ttyS0`)

Nach Aenderungen: `sudo reboot`

### Pruefen ob Interfaces aktiv sind

```bash
ls /dev/spidev0.0    # SPI
ls /dev/i2c-1        # I2C
ls /dev/ttyAMA0      # UART (PL011, nach disable-bt)
```

---

## 2. I2C-Tools installieren und Sensoren pruefen

```bash
sudo apt install -y i2c-tools
i2cdetect -y 1
```

Erwartete Ausgabe:

- `0x76` oder `0x77` -- BME680 (RAK 1906)
- `0x48` -- ggf. weiterer Sensor auf dem HAT

---

## 3. meshtasticd installieren

### Repository hinzufuegen (Debian 13 / trixie)

```bash
echo 'deb http://download.opensuse.org/repositories/network:/Meshtastic:/beta/Debian_13/ /' \
  | sudo tee /etc/apt/sources.list.d/network:Meshtastic:beta.list

curl -fsSL https://download.opensuse.org/repositories/network:Meshtastic:beta/Debian_13/Release.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/trusted.gpg.d/network_Meshtastic_beta.gpg > /dev/null
```

> Fuer Debian 12 (bookworm): `Debian_13` durch `Debian_12` ersetzen.
> Fuer Raspberry Pi OS 32-bit: die Raspbian-Repos von Meshtastic verwenden.

### Installieren

```bash
sudo apt update
sudo apt install -y meshtasticd
```

Der Dienst wird automatisch aktiviert (`systemctl enable`).

---

## 4. Konfiguration

meshtasticd verwendet zwei Konfigurations-Ebenen:

- **`config.yaml`** -- Hauptkonfiguration (GPS, I2C, Webserver, General)
- **`available.d/`** -- Hardware-spezifische autoconf-Dateien (LoRa-Modul)

### 4a. autoconf-Datei fuer RAK6421 erstellen

meshtasticd erkennt den RAK6421 HAT automatisch ueber den Device-Tree (`/proc/device-tree/hat`) und sucht nach der Datei `/etc/meshtasticd/available.d/lora-hat-rak-6421-pi-hat.yaml`. Diese existiert standardmaessig **nicht** und muss manuell erstellt werden:

```bash
sudo tee /etc/meshtasticd/available.d/lora-hat-rak-6421-pi-hat.yaml << 'EOF'
Lora:
  ### RAK6421 Pi HAT mit RAK13300/RAK13302 (SX1262) in Slot 1
  Module: sx1262
  CS: 8
  IRQ: 22
  Reset: 16
  Busy: 24
  DIO3_TCXO_VOLTAGE: true
  DIO2_AS_RF_SWITCH: true
  spidev: spidev0.0
EOF
```

> **Wichtig:** `CS: 8` muss explizit gesetzt werden. Ohne diesen Eintrag schlaegt die SPI-Kommunikation mit `SX126x init result -2` fehl (weil `spi0-0cs` keinen Hardware-CS bereitstellt).

> **WARNUNG -- kein `SX126X_ANT_SW` und kein `SX126X_MAX_POWER` setzen!**
> `SX126X_ANT_SW: 13` steuert GPIO 13 (Antenna Switch) aktiv an und blockiert den TX-Pfad des SKY66122 PA -- es wird dann kein RF-Signal gesendet, obwohl meshtasticd TX-Pakete zaehlt.
> `SX126X_MAX_POWER: 30` verursacht `SX126x init result -13` (SPI command timeout) und verhindert ebenfalls TX.
> Der SKY66122 PA wird ueber `DIO2_AS_RF_SWITCH` korrekt geschaltet. Die gemeldeten 22 dBm sind die SX1262-Chip-Leistung; der PA verstaerkt das Signal zusaetzlich um ca. 13 dB.

### 4b. config.yaml anpassen

In `/etc/meshtasticd/config.yaml` muessen folgende Sektionen aktiv (nicht auskommentiert) sein:

```yaml
GPS:
  SerialPath: /dev/ttyAMA0    # PL011-UART (nach dtoverlay=disable-bt)

I2C:
  I2CDevice: /dev/i2c-1

Webserver:
  Port: 9443

General:
  MACAddressSource: end0      # noetig weil Bluetooth deaktiviert ist
  MaxNodes: 200
  MaxMessageQueue: 100
```

> **MACAddressSource:** Ohne Bluetooth fehlt die Standard-MAC-Quelle. `end0` (Ethernet) wird stattdessen verwendet. Ohne diese Einstellung bekommt der Node bei jedem Start eine andere ID.

### Pin-Belegung RAK6421

| Funktion | Slot 1 (GPIO) | Slot 2 (GPIO) |
|----------|---------------|---------------|
| CS | 8 | 7 |
| IRQ (IO6) | 22 | 18 |
| Reset (IO4) | 16 | 24 |
| Busy (IO5) | 24 | 19 |
| Ant_sw (IO3) | 13 (nicht verwenden!) | 23 |
| SPI Device | spidev0.0 | spidev0.1 |

> Falls das LoRa-Modul in **Slot 2** steckt, die Slot-2-Werte verwenden und `spidev: spidev0.1` setzen.

---

## 5. Dienst starten und pruefen

```bash
sudo systemctl restart meshtasticd
sudo systemctl status meshtasticd
```

### Logs pruefen

```bash
sudo journalctl -eu meshtasticd --no-pager -n 50
```

Erwartete Erfolgsmeldungen:

```
BME680 found at address 0x76
GPS power state move from OFF to ACTIVE
Environment Telemetry adding I2C devices...
SX126x init result 0
sx1262 init success
API server listen on TCP port 4403
```

> **Achtung:** Der GPS-Probing-Zyklus dauert ca. 60 Sekunden (testet mehrere Baudraten). Der L76K wird typischerweise bei 57600 Baud erkannt.

### Fehlerdiagnose

| Fehler | Ursache | Loesung |
|--------|---------|---------|
| `Unable to find config for 6421 Pi Hat` | autoconf-Datei fehlt | Schritt 4a ausfuehren |
| `SX126x init result -2` | SPI-Kommunikation fehlgeschlagen | `CS: 8` in config setzen, SPI-Overlay pruefen |
| `SX126x init result -13` | SPI command timeout | `SX126X_ANT_SW` und `SX126X_MAX_POWER` entfernen! |
| Kein TX auf SDR sichtbar | TX-Pfad blockiert | `SX126X_ANT_SW: 13` entfernen -- blockiert SKY66122 PA |
| Kein `/dev/spidev0.0` | SPI nicht aktiviert | `dtparam=spi=on` und `dtoverlay=spi0-0cs` in config.txt |
| Kein `/dev/i2c-1` | I2C nicht aktiviert | `dtparam=i2c_arm=on` in config.txt |
| Kein `/dev/ttyAMA0` | Bluetooth belegt PL011 | `dtoverlay=disable-bt` in config.txt |
| Node-ID aendert sich | MAC-Quelle fehlt | `MACAddressSource: end0` in config.yaml setzen |

---

## 6. Grundkonfiguration ueber CLI

### Region setzen (EU_868 fuer Europa)

```bash
meshtastic --host localhost --set lora.region EU_868
```

### GPS aktivieren

```bash
meshtastic --host localhost --set position.gps_mode ENABLED
```

### Umwelt-Telemetrie (BME680) aktivieren

```bash
meshtastic --host localhost \
  --set telemetry.environment_measurement_enabled true \
  --set telemetry.environment_update_interval 60 \
  --set telemetry.environment_screen_enabled true
```

### Node-Namen setzen

```bash
meshtastic --host localhost --set-owner "MeinNode" --set-owner-short "MN"
```

### Node-Info anzeigen

```bash
meshtastic --host localhost --info
```

---

## 7. Avahi/mDNS Auto-Discovery einrichten

Damit die Meshtastic-App (Android/iOS) das Device automatisch im Netzwerk findet.

### Avahi installieren (falls nicht vorhanden)

```bash
sudo apt install -y avahi-daemon avahi-utils
```

### Service-Datei erstellen

```bash
sudo tee /etc/avahi/services/meshtasticd.service << 'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Meshtastic on %h</name>
  <service protocol="any">
    <type>_meshtastic._tcp</type>
    <port>4403</port>
  </service>
  <service protocol="any">
    <type>_https._tcp</type>
    <port>9443</port>
    <txt-record>path=/</txt-record>
  </service>
</service-group>
EOF
```

### Avahi neu laden

```bash
sudo systemctl reload avahi-daemon
```

### Pruefen ob der Service advertised wird

```bash
avahi-browse -t _meshtastic._tcp
```

Erwartete Ausgabe:

```
+ wlan0 IPv4 Meshtastic on meshpi    _meshtastic._tcp     local
```

Die App sollte das Device jetzt automatisch unter dem Namen **"Meshtastic on <hostname>"** finden.

---

## 8. GPS als NTP-Server fuers Netzwerk (gpsd + chrony)

> **Hinweis:** gpsd und meshtasticd koennen den UART nicht gleichzeitig verwenden. Bei Nutzung von gpsd muss der GPS-SerialPath in config.yaml auskommentiert werden. meshtasticd arbeitet dann ohne GPS -- fuer stationaere Nodes kann eine feste Position gesetzt werden.

### Pakete installieren

```bash
sudo apt install -y gpsd gpsd-clients chrony
```

### gpsd konfigurieren

`/etc/default/gpsd`:

```
DEVICES="/dev/ttyAMA0"
GPSD_OPTIONS="-n -b"
USBAUTO="true"
```

- `-n`: sofort mit GPS-Polling beginnen (nicht auf Client warten)
- `-b`: read-only (keine Kommandos an den GPS senden)

```bash
sudo systemctl enable gpsd
sudo systemctl restart gpsd
```

### GPS in meshtasticd deaktivieren

In `/etc/meshtasticd/config.yaml` den SerialPath auskommentieren:

```yaml
GPS:
#  SerialPath: /dev/ttyAMA0  # GPS via gpsd/chrony statt meshtasticd
```

Fuer stationaere Nodes feste Position setzen:

```bash
meshtastic --host localhost --set position.fixed_position true
meshtastic --host localhost --setlat <BREITENGRAD> --setlon <LAENGENGRAD> --setalt <HOEHE>
```

### GPS-Empfang pruefen

```bash
gpspipe -w -n 10
```

Erwartetes Ergebnis bei Fix: `"mode":3` mit Koordinaten und Zeitstempel.
Ohne Fix: `"mode":1` (normal indoor, GPS braucht freie Sicht zum Himmel).

### chrony als NTP-Server konfigurieren

Datei `/etc/chrony/conf.d/gpsd.conf` erstellen:

```bash
sudo tee /etc/chrony/conf.d/gpsd.conf << 'EOF'
# GPS via gpsd SHM refclock (NMEA time)
refclock SHM 0 refid NMEA offset 0.2 precision 1e-1 poll 2 trust

# NTP-Clients aus dem lokalen Netz erlauben
allow 172.22.44.0/24

# Zeit auch ohne volle Synchronisation bereitstellen
local stratum 3 orphan
EOF
```

```bash
sudo systemctl restart chrony
```

### NTP-Quellen pruefen

```bash
chronyc sources
```

Erwartete Ausgabe (mit GPS-Fix):

```
#* NMEA                          0   2    77     3    -12ms[  -12ms] +/-  100ms
^- pool.ntp.org                  2   6   377    34   -234us[ -234us] +/-   15ms
```

`#*` = GPS ist primaere Zeitquelle. `#?` = noch kein Fix.

### NTP vom Netzwerk aus nutzen

```
# Linux/chrony
server 172.22.44.12 iburst

# Windows
w32tm /config /manualpeerlist:"172.22.44.12" /syncfromflags:manual /update
```

---

## 9. Fernzugriff

| Methode | Zugang |
|---------|--------|
| CLI remote | `meshtastic --host <IP-Adresse>` |
| API | TCP Port 4403 |
| Web UI | `https://<IP-Adresse>:9443` |
| App (Android/iOS) | Automatisch via mDNS oder manuell per IP |

---

## 10. Berechtigungen

Der meshtasticd-Systembenutzer muss in folgenden Gruppen sein (wird bei der Installation automatisch eingerichtet):

```
spi, i2c, gpio, dialout
```

Pruefen mit:

```bash
groups meshtasticd
```

---

## TX-Power und SKY66122 PA

Der RAK 13302 hat einen integrierten SKY66122 Power Amplifier mit ca. 13 dB Verstaerkung. meshtasticd meldet 22 dBm -- das ist die SX1262-Chip-Leistung. Am Antennenanschluss liegt die tatsaechliche Leistung bei ca. 30-35 dBm (1-3W) durch die PA-Verstaerkung.

**Nicht verwenden:**

| Parameter | Problem |
|-----------|---------|
| `SX126X_ANT_SW: 13` | Toggelt GPIO 13 und blockiert den TX-Pfad -- kein RF-Signal trotz TX-Zaehler |
| `SX126X_MAX_POWER: 30` | Verursacht SPI command timeout (`init result -13`) und verhindert TX |

Die PA-Verstaerkung geschieht automatisch ueber `DIO2_AS_RF_SWITCH: true`. Keine zusaetzliche GPIO-Steuerung noetig.

---

## Referenzen

- https://meshtastic.org/docs/meshtasticd/installation/debian/
- https://meshtastic.org/docs/meshtasticd/hardware/boards/raspberry-pi/
- https://docs.rakwireless.com/product-categories/meshtastic/wismesh-rak6421-pi-hat/quickstart/
- https://meshunderground.com/posts/1741209451013-install-meshtasticd-on-raspberrypi-for-off-grid-communication/
