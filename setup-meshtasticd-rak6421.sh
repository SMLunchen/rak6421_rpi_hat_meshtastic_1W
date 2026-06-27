#!/bin/bash
# Setup-Script fuer meshtasticd auf Raspberry Pi mit RAK6421 HAT
#
# Getestet mit: Raspberry Pi 4 Model B, Debian 13 (trixie) aarch64
# Hardware: RAK6421 + RAK13302 (SX1262 + SKY66122 PA) + RAK12501 GPS + RAK1906 BME680
#
# Verwendung:
#   sudo ./setup-meshtasticd-rak6421.sh
#
# Das Script ist idempotent -- kann mehrfach ausgefuehrt werden.
# Nach dem ersten Lauf ist ein Reboot noetig (boot config Aenderungen).

set -euo pipefail

# --- Farben ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!!]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC} $1"; }

# --- Root-Check ---
if [ "$EUID" -ne 0 ]; then
  error "Bitte als root ausfuehren: sudo $0"
  exit 1
fi

echo ""
echo "=========================================="
echo " meshtasticd Setup fuer RAK6421 Pi HAT"
echo "=========================================="
echo ""

# =========================================================================
# 1. Boot-Config
# =========================================================================
echo "--- Schritt 1: Boot-Config pruefen ---"
BOOT_CONFIG="/boot/firmware/config.txt"

if [ ! -f "$BOOT_CONFIG" ]; then
  error "$BOOT_CONFIG nicht gefunden!"
  exit 1
fi

BOOT_CHANGED=false

# SPI aktivieren
if ! grep -q '^dtparam=spi=on' "$BOOT_CONFIG"; then
  echo 'dtparam=spi=on' >> "$BOOT_CONFIG"
  info "dtparam=spi=on hinzugefuegt"
  BOOT_CHANGED=true
else
  info "SPI bereits aktiviert"
fi

# SPI ohne Hardware-CS
if ! grep -q '^dtoverlay=spi0-0cs' "$BOOT_CONFIG"; then
  echo 'dtoverlay=spi0-0cs' >> "$BOOT_CONFIG"
  info "dtoverlay=spi0-0cs hinzugefuegt"
  BOOT_CHANGED=true
else
  info "spi0-0cs bereits konfiguriert"
fi

# I2C
if ! grep -q '^dtparam=i2c_arm=on' "$BOOT_CONFIG"; then
  echo 'dtparam=i2c_arm=on' >> "$BOOT_CONFIG"
  info "dtparam=i2c_arm=on hinzugefuegt"
  BOOT_CHANGED=true
else
  info "I2C bereits aktiviert"
fi

# I2C HAT EEPROM
if ! grep -q '^dtparam=i2c_vc=on' "$BOOT_CONFIG"; then
  echo 'dtparam=i2c_vc=on' >> "$BOOT_CONFIG"
  info "dtparam=i2c_vc=on hinzugefuegt"
  BOOT_CHANGED=true
else
  info "I2C VC bereits aktiviert"
fi

if ! grep -q '^dtoverlay=i2c0' "$BOOT_CONFIG"; then
  echo 'dtoverlay=i2c0' >> "$BOOT_CONFIG"
  info "dtoverlay=i2c0 hinzugefuegt"
  BOOT_CHANGED=true
else
  info "I2C0-Overlay bereits vorhanden"
fi

# UART
if ! grep -q '^enable_uart=1' "$BOOT_CONFIG"; then
  echo 'enable_uart=1' >> "$BOOT_CONFIG"
  info "enable_uart=1 hinzugefuegt"
  BOOT_CHANGED=true
else
  info "UART bereits aktiviert"
fi

# Bluetooth deaktivieren (PL011 fuer GPS freigeben)
if ! grep -q '^dtoverlay=disable-bt' "$BOOT_CONFIG"; then
  # Unter [all] Sektion einfuegen, oder anlegen
  if grep -q '^\[all\]' "$BOOT_CONFIG"; then
    sed -i '/^\[all\]/a dtoverlay=disable-bt' "$BOOT_CONFIG"
  else
    echo -e '\n[all]\ndtoverlay=disable-bt' >> "$BOOT_CONFIG"
  fi
  info "dtoverlay=disable-bt hinzugefuegt (PL011-UART fuer GPS)"
  BOOT_CHANGED=true
else
  info "Bluetooth bereits deaktiviert"
fi

# Serial-Console deaktivieren
if command -v raspi-config &>/dev/null; then
  raspi-config nonint do_serial_hw 0 2>/dev/null || true
  raspi-config nonint do_serial_cons 1 2>/dev/null || true
  info "Serial-Console deaktiviert via raspi-config"
fi

echo ""

# =========================================================================
# 2. Pakete installieren
# =========================================================================
echo "--- Schritt 2: Pakete installieren ---"

apt-get install -y i2c-tools avahi-daemon avahi-utils > /dev/null 2>&1
info "i2c-tools, avahi installiert"

# Debian-Version ermitteln
DEBIAN_VERSION=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "$VERSION_CODENAME" in
    bookworm) DEBIAN_VERSION="Debian_12" ;;
    trixie)   DEBIAN_VERSION="Debian_13" ;;
    *)        DEBIAN_VERSION="Debian_13" ; warn "Unbekanntes Release '$VERSION_CODENAME', verwende Debian_13" ;;
  esac
else
  DEBIAN_VERSION="Debian_13"
  warn "os-release nicht gefunden, verwende Debian_13"
fi

# Meshtastic-Repo hinzufuegen
REPO_URL="http://download.opensuse.org/repositories/network:/Meshtastic:/beta/${DEBIAN_VERSION}/"
REPO_FILE="/etc/apt/sources.list.d/network:Meshtastic:beta.list"

if [ ! -f "$REPO_FILE" ]; then
  echo "deb $REPO_URL /" > "$REPO_FILE"
  curl -fsSL "https://download.opensuse.org/repositories/network:Meshtastic:beta/${DEBIAN_VERSION}/Release.key" \
    | gpg --dearmor \
    | tee /etc/apt/trusted.gpg.d/network_Meshtastic_beta.gpg > /dev/null
  info "Meshtastic-Repository hinzugefuegt ($DEBIAN_VERSION)"
else
  info "Meshtastic-Repository bereits vorhanden"
fi

apt-get update -qq > /dev/null 2>&1
apt-get install -y meshtasticd > /dev/null 2>&1
MESHTASTIC_VERSION=$(dpkg -s meshtasticd 2>/dev/null | grep '^Version:' | awk '{print $2}')
info "meshtasticd installiert (Version: $MESHTASTIC_VERSION)"

echo ""

# =========================================================================
# 3. LoRa autoconf-Datei erstellen
# =========================================================================
echo "--- Schritt 3: LoRa-Konfiguration (available.d) ---"

AUTOCONF_FILE="/etc/meshtasticd/available.d/lora-hat-rak-6421-pi-hat.yaml"

cat > "$AUTOCONF_FILE" << 'EOF'
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
  ### WARNUNG: SX126X_ANT_SW und SX126X_MAX_POWER NICHT setzen!
  ### SX126X_ANT_SW: 13 blockiert den TX-Pfad (kein RF-Output).
  ### SX126X_MAX_POWER: 30 verursacht SPI timeout (init result -13).
  ### Der SKY66122 PA verstaerkt automatisch via DIO2_AS_RF_SWITCH.
EOF

chown meshtasticd:meshtasticd "$AUTOCONF_FILE" 2>/dev/null || true
info "autoconf-Datei erstellt: $AUTOCONF_FILE"

echo ""

# =========================================================================
# 4. config.yaml anpassen
# =========================================================================
echo "--- Schritt 4: config.yaml anpassen ---"

CONFIG_YAML="/etc/meshtasticd/config.yaml"

if [ ! -f "$CONFIG_YAML" ]; then
  error "$CONFIG_YAML nicht gefunden!"
  exit 1
fi

changed_items=()

# Pi-Modell erkennen fuer UART-Device
SERIAL_DEVICE="/dev/ttyAMA0"  # PL011 (Standard nach disable-bt)
if [ -f /sys/firmware/devicetree/base/model ]; then
  PI_MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
  info "Erkanntes Modell: $PI_MODEL"
fi

# GPS SerialPath aktivieren/setzen
if grep -q '^#.*SerialPath:' "$CONFIG_YAML"; then
  sed -i "s|^#.*SerialPath:.*|  SerialPath: ${SERIAL_DEVICE}|" "$CONFIG_YAML"
  changed_items+=("SerialPath (${SERIAL_DEVICE})")
elif grep -q "^  SerialPath:" "$CONFIG_YAML"; then
  sed -i "s|^  SerialPath:.*|  SerialPath: ${SERIAL_DEVICE}|" "$CONFIG_YAML"
  changed_items+=("SerialPath (${SERIAL_DEVICE})")
fi

# I2C Device aktivieren
if grep -q '^#.*I2CDevice: /dev/i2c-1' "$CONFIG_YAML"; then
  sed -i 's|^#.*I2CDevice: /dev/i2c-1|  I2CDevice: /dev/i2c-1|' "$CONFIG_YAML"
  changed_items+=("I2CDevice")
fi

# Webserver Port aktivieren
if grep -q '^#.*Port: 9443' "$CONFIG_YAML"; then
  sed -i 's|^#.*Port: 9443|  Port: 9443|' "$CONFIG_YAML"
  changed_items+=("Webserver Port")
fi

# MACAddressSource setzen (noetig wegen disable-bt)
if ! grep -q 'MACAddressSource:' "$CONFIG_YAML"; then
  # Unter General: einfuegen
  if grep -q '^General:' "$CONFIG_YAML"; then
    sed -i '/^General:/a\  MACAddressSource: end0' "$CONFIG_YAML"
    changed_items+=("MACAddressSource")
  fi
elif grep -q '^#.*MACAddressSource:' "$CONFIG_YAML"; then
  sed -i 's|^#.*MACAddressSource:.*|  MACAddressSource: end0|' "$CONFIG_YAML"
  changed_items+=("MACAddressSource")
fi

if [ ${#changed_items[@]} -gt 0 ]; then
  changed_list=$(IFS=', '; echo "${changed_items[*]}")
  info "config.yaml aktualisiert: $changed_list"
else
  info "config.yaml bereits korrekt konfiguriert"
fi

echo ""

# =========================================================================
# 5. Avahi/mDNS Service einrichten
# =========================================================================
echo "--- Schritt 5: Avahi mDNS Service ---"

AVAHI_SERVICE="/etc/avahi/services/meshtasticd.service"

cat > "$AVAHI_SERVICE" << 'EOF'
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

systemctl reload avahi-daemon 2>/dev/null || systemctl restart avahi-daemon
info "Avahi mDNS Service erstellt und geladen"

echo ""

# =========================================================================
# 6. Dienst starten
# =========================================================================
echo "--- Schritt 6: meshtasticd starten ---"

systemctl enable meshtasticd > /dev/null 2>&1
systemctl restart meshtasticd

# Kurz warten und Init-Ergebnis pruefen
sleep 4
INIT_RESULT=$(journalctl -u meshtasticd --no-pager -n 30 | grep 'SX126x init result' | tail -1 || true)
INIT_SUCCESS=$(journalctl -u meshtasticd --no-pager -n 30 | grep 'sx1262 init success' | tail -1 || true)

if echo "$INIT_RESULT" | grep -q 'result 0'; then
  info "SX1262 LoRa-Modul initialisiert (init result 0)"
elif [ -n "$INIT_SUCCESS" ]; then
  warn "SX1262 initialisiert mit Warnung: $INIT_RESULT"
else
  error "SX1262 Initialisierung fehlgeschlagen: $INIT_RESULT"
  error "Logs pruefen: journalctl -eu meshtasticd --no-pager -n 50"
fi

# BME680 pruefen
if journalctl -u meshtasticd --no-pager -n 30 | grep -q 'BME680 found'; then
  info "BME680 Umweltsensor erkannt"
fi

# GPS pruefen
if journalctl -u meshtasticd --no-pager -n 30 | grep -q 'GPS power state'; then
  info "GPS aktiviert (Probing laeuft im Hintergrund)"
fi

# API Port
if journalctl -u meshtasticd --no-pager -n 30 | grep -q 'API server listen'; then
  info "API-Server laeuft auf Port 4403"
fi

echo ""

# =========================================================================
# Zusammenfassung
# =========================================================================
echo "=========================================="
echo " Setup abgeschlossen"
echo "=========================================="
echo ""
echo "  LoRa:     SX1262 + SKY66122 PA (22 dBm Chip + PA-Verstaerkung)"
echo "  GPS:      $SERIAL_DEVICE (L76K, Probing dauert ~60s)"
echo "  I2C:      /dev/i2c-1 (BME680)"
echo "  API:      TCP Port 4403"
echo "  Web UI:   https://<IP>:9443"
echo "  mDNS:     _meshtastic._tcp"
echo ""

if [ "$BOOT_CHANGED" = true ]; then
  warn "Boot-Config wurde geaendert -- Reboot erforderlich!"
  echo ""
  echo "  sudo reboot"
  echo ""
fi

echo "Naechste Schritte nach dem Reboot:"
echo ""
echo "  # Region setzen"
echo "  meshtastic --host localhost --set lora.region EU_868"
echo ""
echo "  # GPS aktivieren"
echo "  meshtastic --host localhost --set position.gps_mode ENABLED"
echo ""
echo "  # Umwelt-Telemetrie aktivieren"
echo "  meshtastic --host localhost \\"
echo "    --set telemetry.environment_measurement_enabled true \\"
echo "    --set telemetry.environment_update_interval 60 \\"
echo "    --set telemetry.environment_screen_enabled true"
echo ""
echo "  # Node-Namen setzen"
echo "  meshtastic --host localhost --set-owner \"MeinNode\" --set-owner-short \"MN\""
echo ""
echo "  # Status pruefen"
echo "  meshtastic --host localhost --info"
echo ""
