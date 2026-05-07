import socket
import time
import logging
import argparse
from datadog import statsd
import sbs1

logging.basicConfig(level=logging.INFO)


def fetch_data(skt):
    msg = skt.recv(1024)
    if len(msg) < 20:
        raise Exception("Socket contained malformed data")
    return msg


def parse_data(msg):
    return sbs1.SBS1Message(msg.decode('utf-8'))


def build_tags(sbs):
    tags = []
    if sbs.icao24:
        tags.append('icao24:{}'.format(sbs.icao24))
    if sbs.callsign:
        tags.append('callsign:{}'.format(sbs.callsign.strip()))
    if sbs.onGround is not None:
        tags.append('on_ground:{}'.format(str(sbs.onGround).lower()))
    return tags


def log_dawg(sbs):
    tags = build_tags(sbs)
    statsd.increment('adsb.message', tags=tags)
    if sbs.groundSpeed is not None:
        statsd.gauge('adsb.airspeed', sbs.groundSpeed, tags=tags)
    if sbs.altitude is not None:
        statsd.gauge('adsb.altitude', sbs.altitude, tags=tags)
    if sbs.track is not None:
        statsd.histogram('adsb.heading', sbs.track, tags=tags)
    if sbs.verticalRate is not None:
        if sbs.verticalRate > 0:
            statsd.gauge('adsb.ascentrate', sbs.verticalRate, tags=tags)
        else:
            statsd.gauge('adsb.descentrate', abs(sbs.verticalRate), tags=tags)
    if sbs.lat is not None:
        statsd.gauge('adsb.latitude', sbs.lat, tags=tags)
    if sbs.lon is not None:
        statsd.gauge('adsb.longitude', sbs.lon, tags=tags)
    if sbs.squawk is not None:
        statsd.gauge('adsb.squawk', sbs.squawk, tags=tags)
    if sbs.emergency:
        statsd.increment('adsb.emergency', tags=tags)


def fetch_loop(skt):
    while True:
        msg = fetch_data(skt)
        sbs_message = parse_data(msg)
        if sbs_message.isValid:
            logging.info(sbs_message.toJSON())
            log_dawg(sbs_message)


def start_socket(args):
    logging.info("Connecting to {}:{}...".format(args.host, args.port))
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((args.host, args.port))
    logging.info("Connected to {}:{}".format(args.host, args.port))
    return s


def main_loop(args):
    while True:
        skt = None
        try:
            skt = start_socket(args)
            fetch_loop(skt)
        except Exception as error:
            logging.error("Connection error: %s", error)
        finally:
            if skt is not None:
                try:
                    skt.close()
                except Exception as close_error:
                    logging.error("Could not close socket: %s", close_error)
        logging.info("Connection lost. Retrying in 5 seconds...")
        time.sleep(5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Stream ADS-B data from dump1090 to Datadog via DogStatsD')
    parser.add_argument('--host', help='Hostname of the dump1090 server. Default: localhost', default='localhost')
    parser.add_argument('--port', help='Port of the dump1090 server. Default: 30003', type=int, default=30003)

    main_loop(parser.parse_args())