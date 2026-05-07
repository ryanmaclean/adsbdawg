import math
import os
import socket
import time
import logging
import argparse
from datadog import statsd
import sbs1

_ICAO_COUNTRY_RANGES = [
    (0x008000, 0x00FFFF, 'ZA'),
    (0x010000, 0x017FFF, 'EG'),
    (0x020000, 0x027FFF, 'MA'),
    (0x0A0000, 0x0AFFFF, 'NG'),
    (0x100000, 0x1FFFFF, 'RU'),
    (0x300000, 0x33FFFF, 'IT'),
    (0x340000, 0x37FFFF, 'ES'),
    (0x380000, 0x3BFFFF, 'FR'),
    (0x3C0000, 0x3FFFFF, 'DE'),
    (0x400000, 0x43FFFF, 'GB'),
    (0x440000, 0x447FFF, 'AT'),
    (0x448000, 0x44FFFF, 'BE'),
    (0x450000, 0x457FFF, 'BG'),
    (0x458000, 0x45FFFF, 'DK'),
    (0x460000, 0x467FFF, 'FI'),
    (0x468000, 0x46FFFF, 'GR'),
    (0x470000, 0x477FFF, 'HU'),
    (0x478000, 0x47FFFF, 'NO'),
    (0x480000, 0x487FFF, 'NL'),
    (0x488000, 0x48FFFF, 'PL'),
    (0x490000, 0x497FFF, 'PT'),
    (0x498000, 0x49FFFF, 'CZ'),
    (0x4A0000, 0x4A7FFF, 'RO'),
    (0x4B0000, 0x4B7FFF, 'SE'),
    (0x4C0000, 0x4C7FFF, 'CH'),
    (0x4CA000, 0x4CBFFF, 'IE'),
    (0x4D0000, 0x4D7FFF, 'TR'),
    (0x780000, 0x7BFFFF, 'CN'),
    (0x7C0000, 0x7FFFFF, 'AU'),
    (0x800000, 0x83FFFF, 'IN'),
    (0x840000, 0x87FFFF, 'JP'),
    (0x900000, 0x93FFFF, 'KR'),
    (0xA00000, 0xAFFFFF, 'US'),
    (0xC00000, 0xC3FFFF, 'CA'),
    (0xE00000, 0xE3FFFF, 'AR'),
    (0xE40000, 0xE7FFFF, 'BR'),
]

_seen_aircraft = {}


def icao_country(icao24):
    try:
        v = int(icao24, 16)
        for lo, hi, cc in _ICAO_COUNTRY_RANGES:
            if lo <= v <= hi:
                return cc
    except (ValueError, TypeError):
        pass
    return 'unknown'


def altitude_band(altitude_ft):
    if altitude_ft is None:
        return 'unknown'
    if altitude_ft < 1000:
        return 'surface'
    if altitude_ft < 10000:
        return 'approach'
    if altitude_ft < 18000:
        return 'transition'
    if altitude_ft < 35000:
        return 'cruise_low'
    return 'cruise_high'


def haversine_nm(lat1, lon1, lat2, lon2):
    R = 3440.065
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2
         + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2))
         * math.sin(dlon / 2) ** 2)
    return R * 2 * math.asin(math.sqrt(max(0.0, min(1.0, a))))


def update_active_aircraft(icao24):
    now = time.monotonic()
    _seen_aircraft[icao24] = now
    cutoff = now - 300
    for k in [k for k, v in _seen_aircraft.items() if v < cutoff]:
        del _seen_aircraft[k]
    statsd.gauge('adsb.aircraft.active', len(_seen_aircraft))


def build_tags(msg):
    tags = []
    if msg.icao24:
        tags.append(f'icao24:{msg.icao24}')
        tags.append(f'icao_country:{icao_country(msg.icao24)}')
    if msg.callsign:
        tags.append(f'callsign:{msg.callsign}')
    if msg.onGround is not None:
        tags.append(f'on_ground:{str(msg.onGround).lower()}')
    if msg.altitude is not None:
        tags.append(f'altitude_band:{altitude_band(msg.altitude)}')
    return tags


def log_dawg(msg, args):
    tags = build_tags(msg)
    statsd.increment('adsb.message', tags=tags)

    if msg.icao24:
        update_active_aircraft(msg.icao24)

    if msg.groundSpeed is not None:
        statsd.gauge('adsb.airspeed', msg.groundSpeed, tags=tags)
    if msg.altitude is not None:
        statsd.gauge('adsb.altitude', msg.altitude, tags=tags)
    if msg.track is not None:
        statsd.histogram('adsb.heading', msg.track, tags=tags)
    if msg.verticalRate is not None:
        if msg.verticalRate > 0:
            statsd.gauge('adsb.ascentrate', msg.verticalRate, tags=tags)
        else:
            statsd.gauge('adsb.descentrate', abs(msg.verticalRate), tags=tags)
    if msg.lat is not None:
        statsd.gauge('adsb.latitude', msg.lat, tags=tags)
    if msg.lon is not None:
        statsd.gauge('adsb.longitude', msg.lon, tags=tags)
    if msg.squawk is not None:
        statsd.gauge('adsb.squawk', msg.squawk, tags=tags)
    if msg.emergency:
        statsd.increment('adsb.emergency', tags=tags)
    if msg.alert:
        statsd.increment('adsb.alert', tags=tags)
    if msg.spi:
        statsd.increment('adsb.spi', tags=tags)
    if msg.onGround is not None:
        statsd.gauge('adsb.onground', int(msg.onGround), tags=tags)

    if args.receiver_lat is not None and args.receiver_lon is not None:
        if msg.lat is not None and msg.lon is not None:
            rng = haversine_nm(args.receiver_lat, args.receiver_lon, msg.lat, msg.lon)
            statsd.gauge('adsb.range_nm', rng, tags=tags)

    if msg.generatedDate and msg.loggedDate:
        lag_ms = (msg.loggedDate - msg.generatedDate).total_seconds() * 1000
        if lag_ms >= 0:
            statsd.gauge('adsb.message.lag_ms', lag_ms, tags=tags)


def fetch_loop(skt, args):
    log = logging.getLogger(__name__)
    with skt.makefile('r') as stream:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            if not line.startswith('MSG,'):
                statsd.increment('adsb.message.invalid')
                continue
            msg = sbs1.SBS1Message(line)
            if msg.isValid:
                log.debug(msg.toJSON())
                log_dawg(msg, args)
    raise ConnectionResetError("dump1090 closed the connection")


def start_socket(args):
    logging.info("Connecting to %s:%s...", args.host, args.port)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(30.0)
    s.connect((args.host, args.port))
    s.settimeout(None)
    logging.info("Connected to %s:%s", args.host, args.port)
    statsd.increment('adsb.connection.established')
    return s


def main_loop(args):
    attempt = 0
    while True:
        skt = None
        try:
            skt = start_socket(args)
            attempt = 0
            fetch_loop(skt, args)
        except Exception:
            attempt += 1
            statsd.increment('adsb.connection.error')
            logging.exception("Connection error (attempt %d)", attempt)
        finally:
            if skt is not None:
                try:
                    skt.close()
                except Exception as close_error:
                    logging.error("Could not close socket: %s", close_error)
        delay = min(5 * 2 ** (attempt - 1), 60)
        logging.info("Connection lost. Retrying in %d seconds...", delay)
        time.sleep(delay)


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(
        description='Stream ADS-B data from dump1090 to Datadog via DogStatsD'
    )
    parser.add_argument('--host', default=os.environ.get('ADSB_HOST', 'localhost'),
                        help='Hostname of the dump1090 server (env: ADSB_HOST). Default: localhost')
    parser.add_argument('--port', type=int, default=int(os.environ.get('ADSB_PORT', '30003')),
                        help='Port of the dump1090 SBS-1 feed (env: ADSB_PORT). Default: 30003')
    _rlat = os.environ.get('ADSB_RECEIVER_LAT')
    _rlon = os.environ.get('ADSB_RECEIVER_LON')
    parser.add_argument('--receiver-lat', type=float, default=float(_rlat) if _rlat else None,
                        help='Receiver latitude for range metrics (env: ADSB_RECEIVER_LAT)')
    parser.add_argument('--receiver-lon', type=float, default=float(_rlon) if _rlon else None,
                        help='Receiver longitude for range metrics (env: ADSB_RECEIVER_LON)')
    main_loop(parser.parse_args())
