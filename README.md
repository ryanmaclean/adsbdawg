# ADSBDawg ✈️

Stream live ADS-B aircraft data from an RTL-SDR dongle to [Datadog](https://www.datadoghq.com/) via DogStatsD, with dashboard and monitor templates that require receiver-specific configuration, and a Raspberry Pi setup script.

## Architecture

```
RTL-SDR USB dongle
       │  (1090 MHz RF)
   dump1090 — TCP :30003 (SBS-1 line protocol)
       │
   adsb.py  ─── DogStatsD UDP :8125 ─── Datadog Agent ─── Datadog Cloud
                   │
               Enriches each message with:
               icao24 · callsign · on_ground · altitude_band · icao_country · squawk
               (only when present in the current message)
```

## Metrics

| Metric | Type | Tags | Description |
|---|---|---|---|
| `adsb.message` | count | icao24, callsign, on_ground, altitude_band, icao_country, squawk | One increment per accepted MSG frame; tags reflect fields present in that frame |
| `adsb.altitude` | gauge | + | Altitude in feet MSL |
| `adsb.airspeed` | gauge | + | Ground speed in knots |
| `adsb.heading` | histogram | + | Track/heading 0–360° |
| `adsb.ascentrate` | gauge | + | Positive vertical rate (ft/min) |
| `adsb.descentrate` | gauge | + | Absolute descent rate (ft/min) |
| `adsb.latitude` | gauge | + | Aircraft latitude |
| `adsb.longitude` | gauge | + | Aircraft longitude |
| `adsb.squawk` | gauge | + | Legacy numeric digit representation of a validated squawk (e.g. 0750 → 750); never an event count |
| `adsb.emergency` | count | + | Emergency flag active |
| `adsb.alert` | count | + | Mode C squawk change alert |
| `adsb.spi` | count | + | Special Position Identification |
| `adsb.onground` | gauge | + | On-ground flag (0/1) |
| `adsb.range_nm` | gauge | + | Distance from receiver (requires `--receiver-lat/lon`) |
| `adsb.aircraft.active` | gauge | — | Receiver-wide unique ICAO24 count, expired and emitted when another aircraft frame arrives; can be stale during silence |
| `adsb.message.lag_ms` | gauge | + | loggedDate − generatedDate latency |
| `adsb.message.invalid` | count | — | Non-MSG lines skipped; not a complete malformed-frame counter |
| `adsb.connection.established` | count | — | Successful dump1090 connections |
| `adsb.connection.error` | count | — | Connection failures (for alerting) |

Tags marked + use the current frame's available tags; they are not joined across messages. The Agent supplies receiver host identity. The collector's ADSB_HOST selects the TCP feed and does not set the Datadog host tag.

### Squawk observation contract

The SBS squawk field must contain exactly four ASCII digits from 0 through 7 after trimming surrounding whitespace. Empty, truncated, signed, too-short/long, non-ASCII or non-octal values produce no squawk tag or gauge; other parsed fields in that frame are still usable. This is field validation, not a claim that the entire SBS frame is valid. Valid codes preserve the existing numeric parser/JSON/gauge representation, while the squawk tag restores four digits: 0000 → numeric 0 and tag squawk:0000, 0750 → numeric 750 and tag squawk:0750. Codes are digit strings, so 7500 remains numeric 7500, not a base-8 conversion to 3904.

Squawk queries count the existing adsb.message counter filtered by squawk tag. Each received frame counts once; duplicate/repeated transmissions count again. Frames without a valid squawk do not inherit a previously observed code. Counts describe received observations, not distinct aircraft, unique incidents, current transponder state or an all-clear. The legacy adsb.squawk gauge remains available for compatibility and must not use as_count(). Adding the squawk tag preserves its name, type and numeric value but changes timeseries dimensions, including other current-frame tagged metrics. Existing queries grouped by complete tagsets must account for the new dimension.

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
The file is an array of nine templates, not one monitor API payload. Remove the `_comment` metadata and create each object separately. Set every literal `host:pi-adsb` to the actual Agent receiver host and `device:/dev/root` to the actual disk device before import. Dashboard variables do not substitute monitor filters. No dashboard or monitor is deployed by these files.

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
| **Emergency observations** | Received 7500/7600/7700 frame counts and emergency-flag timeline; zero/no-data is not an all-clear |
| **Receiver health** | msg/sec timeseries with threshold marker, active aircraft count |
| **Flight tracking** | Altitude timeseries by ICAO24, altitude distribution histogram |
| **Altitude bands** | Stacked area: surface / approach / transition / cruise_low / cruise_high |
| **Speed & heading** | Speed timeseries + distribution, heading distribution (reveals active runway) |
| **Vertical rate** | Ascent vs descent rate timeseries |
| **Fleet analysis** | Callsign-bearing frame counts, highest altitude by ICAO24, fleet by country |
| **Coverage** | Range timeseries (max + avg), airborne vs on-ground split |
| **Squawk analysis** | Top squawk codes, processing lag timeseries |
| **Pi health** | CPU %, memory %, CPU temperature (with 80°C throttle marker), disk % |

Template variables: $callsign, $icao24, $country, $host. Select the actual Agent receiver host (default pi-adsb); host=* aggregates multiple receivers and is not a per-receiver health view.

| Panel scope | Applied filters |
|---|---|
| Emergency observations, message-rate/active-aircraft receiver health and Pi system health | host only; aircraft selections intentionally do not hide receiver-wide observations |
| Aircraft telemetry, altitude bands, range, squawk breakdown and lag | host, icao24, country |
| Callsign-bearing frame table | host, icao24, country, callsign |

SBS messages are sparse: identification frames can contain callsign while position or squawk frames lack it. There is no cross-frame aircraft cache. Altitude/speed/highest-aircraft grouping uses ICAO24, and the callsign variable only narrows the callsign-bearing frame table. It cannot filter the whole flight history. Missing fields have no corresponding tag, so field-based selections can omit sparse frames. Receiver-wide active-aircraft totals do not become aircraft-filtered totals.

The three squawk query-value cards use metric queries with sum aggregation over the selected dashboard time window. Other cards retain their metric-specific last/average/maximum aggregation. The emergency monitors separately use explicit last_2m monitor windows. These templates add no explicit zero-fill expression; platform no-data behavior still requires validation. Check receiver telemetry independently before interpreting the absence of observations.

## Monitors

Pre-built monitors in `monitors/adsb_monitors.json`:

| Monitor | Severity | Trigger |
|---|---|---|
| Receiver Offline | P1 | Average msg/sec < 0.5 over 5 min, for the configured receiver |
| Hijack Squawk 7500 | P1 | At least one received 7500-bearing frame in 2 min |
| Emergency Squawk 7700 | P1 | At least one received 7700-bearing frame in 2 min |
| Radio Failure Squawk 7600 | P2 | At least one received 7600-bearing frame in 2 min (critical threshold 0, priority P2) |
| Emergency Flag Active | P1 | Any emergency bit set |
| Message Rate Degraded | P2 | < 2 msg/sec for 15 min |
| Pi CPU Temperature | P2 | > 75°C warning / > 80°C critical |
| Pi Disk Space | P2 | > 85% warning / > 95% critical |
| Processing Lag | P3 | 5-minute mean lag > 5s warning / > 10s critical |

## Project Structure

```
adsbdawg/
├── adsb.py                    # Collector: connects to dump1090, enriches & emits metrics
├── sbs1.py                    # SBS-1 message parser (stdlib datetime, IntEnum, __slots__)
├── requirements.txt           # Python dependencies (datadog>=0.47.0)
├── adsb.service               # systemd unit (hardened: NoNewPrivileges, ProtectSystem)
├── setup-raspberry-pi.sh      # One-shot Raspberry Pi setup script
├── dashboards/
│   └── adsb_dashboard.json    # Datadog dashboard template (30 widgets)
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
- **Active aircraft gauge** — 5-minute unique ICAO24 count updated on incoming aircraft frames, not an independent heartbeat
- **ICAO country tag** — `icao_country:US`, `icao_country:GB`, etc. on per-frame metrics when ICAO24 is present
- **Altitude band tag** — `surface`, `approach`, `transition`, `cruise_low`, `cruise_high`
- **New metrics** — `adsb.alert`, `adsb.spi`, `adsb.onground`, `adsb.message.lag_ms`, `adsb.connection.*`
- **Connection telemetry** — `adsb.connection.established` / `adsb.connection.error` counters
- **Env var config** — `ADSB_HOST`, `ADSB_PORT`, `ADSB_RECEIVER_LAT/LON` work alongside CLI flags
- **`logging.exception()`** — full tracebacks on errors instead of just `str(error)`

### Infrastructure
- **`adsb.service`** — virtualenv Python path, `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, service dependencies on dump1090 and datadog-agent, `EnvironmentFile`
- **`setup-raspberry-pi.sh`** — user auto-detection (Bookworm-compatible), `DD_API_KEY` validation, virtualenv creation, udev rule reload, `plugdev` group, USB autosuspend disable, `gpu_mem=16`, journald size limits, NTP sync check, disk space guard, reboot reminder
