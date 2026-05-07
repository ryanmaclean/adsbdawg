#!/usr/bin/env bash
# setup-raspberry-pi.sh
# One-shot setup for ADSBDawg on a Raspberry Pi running Raspberry Pi OS (Debian-based).
# Run as root or with sudo: sudo bash setup-raspberry-pi.sh

set -euo pipefail

INSTALL_DIR="/home/pi/adsbdawg"
SERVICE_FILE="adsb.service"
DD_AGENT_CONFIG="/etc/datadog-agent/datadog.yaml"

echo "==> Updating package lists..."
apt-get update -y

echo "==> Installing RTL-SDR kernel and userspace tools..."
apt-get install -y rtl-sdr librtlsdr-dev

echo "==> Blacklisting the default DVB-T kernel module (conflicts with RTL-SDR)..."
if ! grep -q "blacklist dvb_usb_rtl28xxu" /etc/modprobe.d/blacklist-rtl.conf 2>/dev/null; then
    echo "blacklist dvb_usb_rtl28xxu" >> /etc/modprobe.d/blacklist-rtl.conf
fi

echo "==> Installing dump1090-fa (FlightAware fork)..."
apt-get install -y dump1090-fa || {
    echo "dump1090-fa not available via apt. Installing dump1090-mutability..."
    apt-get install -y dump1090-mutability
}

echo "==> Installing Python 3 and pip..."
apt-get install -y python3 python3-pip

echo "==> Installing ADSBDawg Python dependencies..."
if [ -d "$INSTALL_DIR" ]; then
    pip3 install -r "$INSTALL_DIR/requirements.txt"
else
    echo "WARNING: $INSTALL_DIR not found. Clone the repo there and re-run."
fi

echo "==> Installing Datadog Agent..."
if ! command -v datadog-agent &>/dev/null; then
    DD_AGENT_MAJOR_VERSION=7 \
    DD_API_KEY="${DD_API_KEY:-YOUR_DATADOG_API_KEY}" \
    bash -c "$(curl -L https://s3.amazonaws.com/dd-agent-bootstrap/datadog-install-script.sh)"
else
    echo "Datadog Agent already installed, skipping."
fi

echo "==> Enabling DogStatsD in Datadog Agent config..."
if [ -f "$DD_AGENT_CONFIG" ]; then
    if grep -q "# dogstatsd_non_local_traffic:" "$DD_AGENT_CONFIG"; then
        sed -i 's/# dogstatsd_non_local_traffic: false/dogstatsd_non_local_traffic: false/' "$DD_AGENT_CONFIG"
    fi
    echo "DogStatsD is enabled on 127.0.0.1:8125 by default."
fi

echo "==> Installing and enabling the adsbdawg systemd service..."
if [ -f "$INSTALL_DIR/$SERVICE_FILE" ]; then
    cp "$INSTALL_DIR/$SERVICE_FILE" /etc/systemd/system/adsbdawg.service
    systemctl daemon-reload
    systemctl enable adsbdawg.service
    systemctl start adsbdawg.service
    echo "adsbdawg service started."
else
    echo "WARNING: $INSTALL_DIR/$SERVICE_FILE not found. Start manually with:"
    echo "  python3 $INSTALL_DIR/adsb.py"
fi

echo ""
echo "==> Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Verify dump1090 is running:  systemctl status dump1090-fa"
echo "  2. Check adsbdawg service:      systemctl status adsbdawg"
echo "  3. Check Datadog Agent:         systemctl status datadog-agent"
echo "  4. Import dashboards/adsb_dashboard.json into Datadog:"
echo "     Dashboards > New Dashboard > Import JSON"
echo ""
