# ADSBDawg ✈️

Stream live ADS-B aircraft data from an RTL-SDR dongle to [Datadog](https://www.datadoghq.com/) via DogStatsD. Includes a ready-to-import Datadog dashboard for real-time monitoring of aircraft in your area.

## How it works

```
RTL-SDR USB dongle
       │
   dump1090 (port 30003, SBS-1 format)
       │
   adsb.py  ──── DogStatsD (UDP 8125) ──── Datadog Agent ──── Datadog Cloud
```

`adsb.py` connects to the dump1090 SBS-1 TCP feed, parses each aircraft message, and emits the following metrics to Datadog:

| Metric | Type | Description | Tags |
|---|---|---|---|
| `adsb.message` | count | Every received ADS-B message | `icao24`, `callsign`, `on_ground` |
| `adsb.altitude` | gauge | Aircraft altitude in feet | `icao24`, `callsign`, `on_ground` |
| `adsb.airspeed` | gauge | Ground speed in knots | `icao24`, `callsign`, `on_ground` |
| `adsb.heading` | histogram | Track/heading in degrees | `icao24`, `callsign`, `on_ground` |
| `adsb.ascentrate` | gauge | Positive vertical rate (ft/min) | `icao24`, `callsign`, `on_ground` |
| `adsb.descentrate` | gauge | Absolute descent rate (ft/min) | `icao24`, `callsign`, `on_ground` |
| `adsb.latitude` | gauge | Aircraft latitude | `icao24`, `callsign`, `on_ground` |
| `adsb.longitude` | gauge | Aircraft longitude | `icao24`, `callsign`, `on_ground` |
| `adsb.squawk` | gauge | Squawk code | `icao24`, `callsign`, `on_ground` |
| `adsb.emergency` | count | Emergency squawk detected | `icao24`, `callsign`, `on_ground` |

## Requirements

- Raspberry Pi (any model with USB) running Raspberry Pi OS
- [RTL-SDR (RTL2832U) USB dongle](https://www.rtl-sdr.com/buy-rtl-sdr-dvb-t-dongles/)
- [dump1090](https://github.com/flightaware/dump1090) listening on TCP port 30003 (SBS-1 format)
- [Datadog Agent](https://docs.datadoghq.com/agent/) installed with a valid API key (DogStatsD enabled on `127.0.0.1:8125`)
- Python 3.7+

## Quick Start (Raspberry Pi)

### 1. Clone the repository

```bash
git clone https://github.com/ryanmaclean/adsbdawg.git /home/pi/adsbdawg
cd /home/pi/adsbdawg
```

### 2. Run the automated setup script

```bash
export DD_API_KEY="your_datadog_api_key_here"
sudo bash setup-raspberry-pi.sh
```

This script will:
- Install RTL-SDR drivers and blacklist the conflicting DVB-T module
- Install dump1090-fa (FlightAware fork)
- Install Python dependencies
- Install and configure the Datadog Agent
- Install and enable the `adsbdawg` systemd service

### 3. Import the sample dashboard

1. Open [Datadog Dashboards](https://app.datadoghq.com/dashboard/lists)
2. Click **New Dashboard → Import JSON**
3. Paste the contents of `dashboards/adsb_dashboard.json`

## Manual Setup

### Install RTL-SDR and dump1090

```bash
sudo apt-get update
sudo apt-get install -y rtl-sdr dump1090-fa
# Blacklist the kernel DVB-T module that conflicts with RTL-SDR
echo "blacklist dvb_usb_rtl28xxu" | sudo tee /etc/modprobe.d/blacklist-rtl.conf
```

### Install the Datadog Agent

```bash
DD_AGENT_MAJOR_VERSION=7 DD_API_KEY=<YOUR_API_KEY> \
  bash -c "$(curl -L https://s3.amazonaws.com/dd-agent-bootstrap/datadog-install-script.sh)"
```

### Install Python dependencies

```bash
pip3 install -r requirements.txt
```

### Run adsbdawg

```bash
python3 adsb.py [--host HOST] [--port PORT]
```

| Argument | Default | Description |
|---|---|---|
| `--host` | `localhost` | Hostname of the dump1090 server |
| `--port` | `30003` | TCP port of the dump1090 SBS-1 feed |

### Run as a systemd service

```bash
sudo cp adsb.service /etc/systemd/system/adsbdawg.service
# Edit WorkingDirectory / ExecStart paths if your install location differs
sudo systemctl daemon-reload
sudo systemctl enable adsbdawg
sudo systemctl start adsbdawg
```

Check logs with:
```bash
journalctl -u adsbdawg -f
```

## Dashboard

The included dashboard (`dashboards/adsb_dashboard.json`) provides:

- **Message rate** – bar chart of incoming ADS-B messages per second
- **Aircraft in range** – count of unique aircraft seen in the last 10 minutes
- **Altitude by aircraft** – per-callsign altitude timeseries
- **Ground speed by aircraft** – per-callsign speed timeseries
- **Vertical rate** – ascent and descent rates
- **Most active aircraft** – toplist by message count
- **Highest flying aircraft** – toplist by average altitude
- **Airborne vs on-ground** – split message counts
- **Emergency squawks** – alert timeseries for squawk 7500/7600/7700

Template variables (`$callsign`, `$icao24`) let you filter the entire dashboard to a single aircraft.

## Project Structure

```
adsbdawg/
├── adsb.py                   # Main collector – connects to dump1090, emits metrics
├── sbs1.py                   # SBS-1 message parser
├── requirements.txt          # Python dependencies
├── adsb.service              # systemd unit file for Raspberry Pi
├── setup-raspberry-pi.sh     # One-shot Raspberry Pi setup script
└── dashboards/
    └── adsb_dashboard.json   # Importable Datadog dashboard
```
