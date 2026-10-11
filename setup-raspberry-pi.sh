#!/usr/bin/env bash
# setup-raspberry-pi.sh
# One-shot setup for ADSBDawg on Raspberry Pi OS (Debian-based).
# Run with: sudo bash setup-raspberry-pi.sh

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ── Validation ──────────────────────────────────────────────────────────────
if [[ -z "${DD_API_KEY:-}" || "${DD_API_KEY}" == "YOUR_DATADOG_API_KEY" ]]; then
    echo "ERROR: Set DD_API_KEY before running: export DD_API_KEY=<your-key>"
    exit 1
fi

INSTALL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
INSTALL_DIR="/home/$INSTALL_USER/adsbdawg"
VENV_DIR="$INSTALL_DIR/.venv"
DD_SITE="${DD_SITE:-datadoghq.com}"
BOOT_CONFIG="$( [ -f /boot/firmware/config.txt ] && echo /boot/firmware/config.txt || echo /boot/config.txt )"
ARCH="$(dpkg --print-architecture)"

echo "==> User: $INSTALL_USER | Install dir: $INSTALL_DIR | Arch: $ARCH"

# ── Disk space check ─────────────────────────────────────────────────────────
AVAIL_KB=$(df --output=avail / | tail -1)
if [ "$AVAIL_KB" -lt 524288 ]; then
    echo "ERROR: Less than 512 MB free on /. Aborting."
    exit 1
fi

# ── System packages ──────────────────────────────────────────────────────────
echo "==> Updating package lists..."
apt-get update -y

echo "==> Installing RTL-SDR and system tools..."
apt-get install -y --no-install-recommends rtl-sdr librtlsdr-dev python3 python3-pip python3-venv

# ── RTL-SDR kernel module blacklist ──────────────────────────────────────────
echo "==> Blacklisting dvb_usb_rtl28xxu kernel module..."
BLACKLIST_FILE="/etc/modprobe.d/blacklist-rtl.conf"
if ! grep -q "blacklist dvb_usb_rtl28xxu" "$BLACKLIST_FILE" 2>/dev/null; then
    echo "blacklist dvb_usb_rtl28xxu" >> "$BLACKLIST_FILE"
fi
modprobe -r dvb_usb_rtl28xxu 2>/dev/null || true
update-initramfs -u -k "$(uname -r)" 2>/dev/null || true

# ── RTL-SDR USB autosuspend disable ──────────────────────────────────────────
echo "==> Disabling USB autosuspend for RTL-SDR dongle..."
UDEV_RULE="/etc/udev/rules.d/99-rtlsdr-power.rules"
cat > "$UDEV_RULE" << 'UDEV'
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", ATTR{power/autosuspend}="-1"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", ATTR{power/autosuspend}="-1"
UDEV
udevadm control --reload-rules && udevadm trigger --subsystem-match=usb

# ── plugdev group ─────────────────────────────────────────────────────────────
echo "==> Adding $INSTALL_USER to plugdev group..."
usermod -aG plugdev "$INSTALL_USER" || true

# ── Presence check ───────────────────────────────────────────────────────────
lsusb | grep -q "0bda:283" || echo "WARNING: RTL-SDR dongle not detected. Ensure it is connected."

# ── dump1090 ──────────────────────────────────────────────────────────────────
echo "==> Installing dump1090..."
if apt-get install -y --no-install-recommends dump1090-fa 2>/dev/null; then
    DUMP1090_SERVICE="dump1090-fa"
elif apt-get install -y --no-install-recommends dump1090-mutability 2>/dev/null; then
    DUMP1090_SERVICE="dump1090-mutability"
else
    echo "ERROR: Could not install any dump1090 variant. Add FlightAware apt repo first:"
    echo "  https://flightaware.com/adsb/piaware/install"
    exit 1
fi
systemctl enable "$DUMP1090_SERVICE" && systemctl start "$DUMP1090_SERVICE"

# ── Python virtualenv ─────────────────────────────────────────────────────────
echo "==> Creating Python virtualenv at $VENV_DIR..."
if [ -d "$INSTALL_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip --quiet
    "$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt" --quiet
    chown -R "$INSTALL_USER:$INSTALL_USER" "$VENV_DIR"
else
    echo "WARNING: $INSTALL_DIR not found. Clone the repo there and re-run."
fi

# ── Datadog Agent ─────────────────────────────────────────────────────────────
echo "==> Installing Datadog Agent..."
if ! command -v datadog-agent &>/dev/null; then
    DD_AGENT_MAJOR_VERSION=7 DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" \
        bash -c "$(curl --tlsv1.2 --proto https -fsSL \
            https://s3.amazonaws.com/dd-agent-bootstrap/scripts/install_script_agent7.sh)"
else
    echo "Datadog Agent already installed, skipping."
fi
systemctl enable datadog-agent && systemctl start datadog-agent

# ── adsbdawg environment file ─────────────────────────────────────────────────
echo "==> Writing /etc/adsbdawg/env..."
mkdir -p /etc/adsbdawg
chmod 700 /etc/adsbdawg
cat > /etc/adsbdawg/env << ENV
ADSB_HOST=localhost
ADSB_PORT=30003
# Set these for range metrics (decimal degrees):
# ADSB_RECEIVER_LAT=37.7749
# ADSB_RECEIVER_LON=-122.4194
ENV
chmod 600 /etc/adsbdawg/env

# ── systemd service ───────────────────────────────────────────────────────────
echo "==> Installing adsbdawg systemd service..."
if [ -f "$INSTALL_DIR/adsb.service" ]; then
    UNIT_FILE="/etc/systemd/system/adsbdawg.service"
    sed "s|/home/pi/adsbdawg|$INSTALL_DIR|g; s|User=pi|User=$INSTALL_USER|g" \
        "$INSTALL_DIR/adsb.service" > "$UNIT_FILE"
    systemctl daemon-reload
    systemctl enable adsbdawg.service
    systemctl start adsbdawg.service
    echo "adsbdawg service started."
else
    echo "WARNING: $INSTALL_DIR/adsb.service not found."
fi

# ── Pi performance tweaks ─────────────────────────────────────────────────────
echo "==> Applying Raspberry Pi optimizations..."
if ! grep -q "^gpu_mem=" "$BOOT_CONFIG" 2>/dev/null; then
    echo "gpu_mem=16" >> "$BOOT_CONFIG"
fi
if ! grep -q "^dtoverlay=disable-bt" "$BOOT_CONFIG" 2>/dev/null; then
    echo "dtoverlay=disable-bt" >> "$BOOT_CONFIG"
fi

# ── journald SD card wear reduction ──────────────────────────────────────────
JOURNALD_CONF="/etc/systemd/journald.conf.d/adsbdawg.conf"
mkdir -p "$(dirname "$JOURNALD_CONF")"
cat > "$JOURNALD_CONF" << 'JCONF'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=20M
RateLimitBurst=200
RateLimitIntervalSec=30s
JCONF
systemctl restart systemd-journald

# ── NTP check ─────────────────────────────────────────────────────────────────
timedatectl show | grep -q "NTPSynchronized=yes" \
    || echo "WARNING: NTP not yet synchronized — ADS-B timestamps may be incorrect until sync."

echo ""
echo "==> Setup complete! A reboot is recommended to apply the RTL-SDR module blacklist."
echo ""
echo "Verify:"
echo "  systemctl status $DUMP1090_SERVICE"
echo "  systemctl status adsbdawg"
echo "  systemctl status datadog-agent"
echo "  journalctl -u adsbdawg -f"
echo ""
echo "Import dashboards/adsb_dashboard.json in Datadog:"
echo "  Dashboards > New Dashboard > Import JSON"
