# ADSBDawg ✈️

Stream live ADS-B aircraft data from an RTL-SDR dongle to [Datadog](https://www.datadoghq.com/) via DogStatsD, with a ready-to-import dashboard, pre-built monitors, and a one-shot Raspberry Pi setup script.

## Architecture

```
RTL-SDR USB dongle
       │  (1090 MHz RF)
   dump1090 — TCP :30003 (SBS-1 line protocol)
       │
   adsb.py  ─── DogStatsD UDP :8125 ─── Datadog Agent ─── Datadog Cloud
                   │
               Enriches each message with:
               icao24 · callsign · on_ground · altitude_band · icao_country
```

## Metrics

| Metric | Type | Tags | Description |
|---|---|---|---|
| `adsb.message` | count | icao24, callsign, on_ground, altitude_band, icao_country | Every received ADS-B message |
| `adsb.altitude` | gauge | + | Altitude in feet MSL |
| `adsb.airspeed` | gauge | + | Ground speed in knots |
| `adsb.heading` | histogram | + | Track/heading 0–360° |
| `adsb.ascentrate` | gauge | + | Positive vertical rate (ft/min) |
| `adsb.descentrate` | gauge | + | Absolute descent rate (ft/min) |
| `adsb.latitude` | gauge | + | Aircraft latitude |
| `adsb.longitude` | gauge | + | Aircraft longitude |
| `adsb.squawk` | gauge | squawk | Transponder squawk code |
| `adsb.emergency` | count | + | Emergency flag active |
| `adsb.alert` | count | + | Mode C squawk change alert |
| `adsb.spi` | count | + | Special Position Identification |
| `adsb.onground` | gauge | + | On-ground flag (0/1) |
| `adsb.range_nm` | gauge | + | Distance from receiver (requires `--receiver-lat/lon`) |
| `adsb.aircraft.active` | gauge | — | Unique aircraft seen in 5-min rolling window |
| `adsb.message.lag_ms` | gauge | + | loggedDate − generatedDate latency |
| `adsb.message.invalid` | count | — | Non-MSG or malformed frames skipped |
| `adsb.connection.established` | count | — | Successful dump1090 connections |
| `adsb.connection.error` | count | — | Connection failures (for alerting) |

## Requirements

- Raspberry Pi running Raspberry Pi OS (any Pi with USB; Pi 3B+ or later recommended)
- [RTL-SDR (RTL2832U) USB dongle](https://www.rtl-sdr.com/buy-rtl-sdr-dvb-t-dongles/)
- dump1090 listening on TCP port 30003 (SBS-1 format)
- [Datadog Agent](https://docs.datadoghq.com/agent/) with a valid API key (DogStatsD on `127.0.0.1:8125`)
- Python 3.7+

## Quick Start

### 1. Clone and run the setup script

```bash
git clone https://github.com/ryanmaclean/adsbdawg.git /home/$USER/adsbdawg
cd /home/$USER/adsbdawg

export DD_API_KEY="your_datadog_api_key_here"
sudo bash setup-raspberry-pi.sh
```

The script handles: RTL-SDR drivers, kernel module blacklist, USB autosuspend, dump1090, Python virtualenv, Datadog Agent, systemd service, SD card wear optimizations, and NTP check.

### 2. Configure receiver location (optional but recommended)

Enable range metrics by editing `/etc/adsbdawg/env`:

```bash
sudo nano /etc/adsbdawg/env
# Uncomment and set:
# ADSB_RECEIVER_LAT=37.7749
# ADSB_RECEIVER_LON=-122.4194
sudo systemctl restart adsbdawg
```

### 3. Import the dashboard

1. Open [Datadog → Dashboards → New Dashboard](https://app.datadoghq.com/dashboard/lists)
2. Click **Import JSON** → paste contents of `dashboards/adsb_dashboard.json`

### 4. Import the monitors

Use the Datadog API or Terraform to create monitors from `monitors/adsb_monitors.json`.
See the file header for the `curl` command template.

## Manual Usage

```bash
python3 adsb.py [OPTIONS]

Options:
  --host HOST            dump1090 server hostname (env: ADSB_HOST). Default: localhost
  --port PORT            dump1090 SBS-1 port (env: ADSB_PORT). Default: 30003
  --receiver-lat LAT     Receiver latitude for range metrics (env: ADSB_RECEIVER_LAT)
  --receiver-lon LON     Receiver longitude for range metrics (env: ADSB_RECEIVER_LON)
```

## Dashboard Highlights

The included dashboard (`dashboards/adsb_dashboard.json`) covers:

| Section | Widgets |
|---|---|
| **Emergency status** | 7500/7600/7700 squawk query_value (red/green), emergency timeline |
| **Receiver health** | msg/sec timeseries with threshold marker, active aircraft count |
| **Flight tracking** | Altitude timeseries by callsign, altitude distribution histogram |
| **Altitude bands** | Stacked area: surface / approach / transition / cruise_low / cruise_high |
| **Speed & heading** | Speed timeseries + distribution, heading distribution (reveals active runway) |
| **Vertical rate** | Ascent vs descent rate timeseries |
| **Fleet analysis** | Top flights (by messages), highest altitude, fleet by country |
| **Coverage** | Range timeseries (max + avg), airborne vs on-ground split |
| **Squawk analysis** | Top squawk codes, processing lag timeseries |
| **Pi health** | CPU %, memory %, CPU temperature (with 80°C throttle marker), disk % |

Template variables: `$callsign`, `$icao24`, `$country`, `$host`

## Monitors

Pre-built monitors in `monitors/adsb_monitors.json`:

| Monitor | Severity | Trigger |
|---|---|---|
| Receiver Offline | P1 | msg/sec < 0.5 for 5 min |
| Hijack Squawk 7500 | P1 | Any 7500 in 2 min |
| Emergency Squawk 7700 | P1 | Any 7700 in 2 min |
| Radio Failure Squawk 7600 | P2 | Any 7600 in 2 min |
| Emergency Flag Active | P1 | Any emergency bit set |
| Message Rate Degraded | P2 | < 2 msg/sec for 15 min |
| Pi CPU Temperature | P2 | > 75°C warning / > 80°C critical |
| Pi Disk Space | P2 | > 85% warning / > 95% critical |
| Processing Lag | P3 | lag_ms > 5s for 5 min |

## Project Structure

```
adsbdawg/
├── adsb.py                    # Collector: connects to dump1090, enriches & emits metrics
├── sbs1.py                    # SBS-1 message parser (stdlib datetime, IntEnum, __slots__)
├── requirements.txt           # Python dependencies (datadog>=0.47.0)
├── adsb.service               # systemd unit (hardened: NoNewPrivileges, ProtectSystem)
├── setup-raspberry-pi.sh      # One-shot Raspberry Pi setup script
├── dashboards/
│   └── adsb_dashboard.json    # Importable Datadog dashboard (34 widgets)
└── monitors/
    └── adsb_monitors.json     # Datadog monitor configurations (9 monitors)
```

## Improvements in This Version

### Ingestion (sbs1.py)
- **`__slots__`** on `SBS1Message` — reduces GC pressure on high-frequency feeds
- **DRY `_parse()` helper** — replaces 4 near-identical parse methods
- **`IntEnum` for `TransmissionType`** — proper enumeration with name/value lookup
- **stdlib `datetime.strptime`** — replaces `dateutil.parser.parse`; removes external dependency
- **`__repr__`** — useful for debugging: `SBS1Message(icao24='A1B2C3', callsign='UAL123', alt=35000)`
- **`toJSON`** — now includes `alert`, `spi`, `transmissionType` fields

### Collection (adsb.py)
- **TCP readline via `makefile('r')`** — correctly handles partial and concatenated SBS-1 messages
- **Socket timeout (30s)** — prevents silent hangs on dead connections
- **Exponential backoff** — retry delay grows from 5s to 60s max instead of hammering
- **Range metric** — haversine distance from receiver to aircraft (requires `--receiver-lat/lon`)
- **Active aircraft gauge** — rolling 5-minute unique ICAO24 count
- **ICAO country tag** — `icao_country:US`, `icao_country:GB`, etc. on every metric
- **Altitude band tag** — `surface`, `approach`, `transition`, `cruise_low`, `cruise_high`
- **New metrics** — `adsb.alert`, `adsb.spi`, `adsb.onground`, `adsb.message.lag_ms`, `adsb.connection.*`
- **Connection telemetry** — `adsb.connection.established` / `adsb.connection.error` counters
- **Env var config** — `ADSB_HOST`, `ADSB_PORT`, `ADSB_RECEIVER_LAT/LON` work alongside CLI flags
- **`logging.exception()`** — full tracebacks on errors instead of just `str(error)`

### Infrastructure
- **`adsb.service`** — virtualenv Python path, `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, service dependencies on dump1090 and datadog-agent, `EnvironmentFile`
- **`setup-raspberry-pi.sh`** — user auto-detection (Bookworm-compatible), `DD_API_KEY` validation, virtualenv creation, udev rule reload, `plugdev` group, USB autosuspend disable, `gpu_mem=16`, journald size limits, NTP sync check, disk space guard, reboot reminder
