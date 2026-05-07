"""
SBS-1 parser in Python.
Converted from the JavaScript node-sbs1 project by John Wiseman (github.com/wiseman/node-sbs1).
"""
import json
from datetime import datetime
from enum import IntEnum
import logging

log = logging.getLogger(__name__)


class TransmissionType(IntEnum):
    ES_IDENT_AND_CATEGORY = 1
    ES_SURFACE_POS = 2
    ES_AIRBORNE_POS = 3
    ES_AIRBORNE_VEL = 4
    SURVEILLANCE_ALT = 5
    SURVEILLANCE_ID = 6
    AIR_TO_AIR = 7
    ALL_CALL_REPLY = 8


class SBS1Message:
    """
    A message parsed from the SBS-1 TCP feed produced by dump1090 on port 30003.

    Attributes map directly to SBS-1 fields. Fields absent in a given message are None.
    See github.com/wiseman/node-sbs1 for the full field reference.
    """

    __slots__ = (
        'isValid', 'messageType', 'transmissionType', 'sessionID', 'aircraftID',
        'icao24', 'flightID', 'generatedDate', 'loggedDate', 'callsign',
        'altitude', 'groundSpeed', 'track', 'lat', 'lon', 'verticalRate',
        'squawk', 'alert', 'emergency', 'spi', 'onGround',
    )

    def __init__(self, sbs1Message):
        parts = sbs1Message.split(',')
        self.isValid = True
        self.messageType = self._parse(parts, 0)
        if self.messageType != 'MSG':
            self.messageType = None
            self.isValid = False
        self.transmissionType = self._parse(parts, 1, int)
        self.sessionID = self._parse(parts, 2)
        self.aircraftID = self._parse(parts, 3)
        self.icao24 = self._parse(parts, 4)
        self.flightID = self._parse(parts, 5)
        self.generatedDate = self._parseDateTime(parts, 6, 7)
        self.loggedDate = self._parseDateTime(parts, 8, 9)
        self.callsign = self._parse(parts, 10)
        self.altitude = self._parse(parts, 11, int)
        self.groundSpeed = self._parse(parts, 12, int)
        self.track = self._parse(parts, 13, int)
        self.lat = self._parse(parts, 14, float)
        self.lon = self._parse(parts, 15, float)
        self.verticalRate = self._parse(parts, 16, int)
        self.squawk = self._parse(parts, 17, int)
        self.alert = self._parse(parts, 18, lambda x: bool(int(x)))
        self.emergency = self._parse(parts, 19, lambda x: bool(int(x)))
        self.spi = self._parse(parts, 20, lambda x: bool(int(x)))
        self.onGround = self._parse(parts, 21, lambda x: bool(int(x)))

    def _parse(self, array, index, converter=None):
        try:
            raw = array[index].strip()
            if not raw:
                return None
            return converter(raw) if converter else raw
        except (ValueError, TypeError, IndexError, AttributeError):
            return None

    def _parseDateTime(self, array, dateIndex, timeIndex):
        date_str = self._parse(array, dateIndex)
        time_str = self._parse(array, timeIndex)
        if date_str is None or time_str is None:
            return None
        combined = f"{date_str} {time_str}"
        for fmt in ("%Y/%m/%d %H:%M:%S.%f", "%Y/%m/%d %H:%M:%S"):
            try:
                return datetime.strptime(combined, fmt)
            except ValueError:
                continue
        return None

    def __repr__(self):
        return (f"SBS1Message(icao24={self.icao24!r}, callsign={self.callsign!r}, "
                f"alt={self.altitude}, valid={self.isValid})")

    def dump(self):
        if self.messageType is None:
            log.debug("Illegal message")
            return
        log.debug(f"messageType      : {self.messageType}")
        if self.transmissionType is not None:
            log.debug(f"transmissionType : {self.transmissionType}")
        if self.sessionID is not None:
            log.debug(f"sessionID        : {self.sessionID}")
        if self.aircraftID is not None:
            log.debug(f"aircraftID       : {self.aircraftID}")
        if self.icao24 is not None:
            log.debug(f"icao24           : {self.icao24}")
        if self.flightID is not None:
            log.debug(f"flightID         : {self.flightID}")
        if self.generatedDate is not None:
            log.debug(f"generatedDate    : {self.generatedDate}")
        if self.loggedDate is not None:
            log.debug(f"loggedDate       : {self.loggedDate}")
        if self.callsign is not None:
            log.debug(f"callsign         : {self.callsign}")
        if self.altitude is not None:
            log.debug(f"altitude         : {self.altitude}")
        if self.groundSpeed is not None:
            log.debug(f"groundSpeed      : {self.groundSpeed}")
        if self.track is not None:
            log.debug(f"track            : {self.track}")
        if self.lat is not None and self.lon is not None:
            log.debug(f"lat, lon         : {self.lat}, {self.lon}")
        if self.verticalRate is not None:
            log.debug(f"verticalRate     : {self.verticalRate}")
        if self.squawk is not None:
            log.debug(f"squawk           : {self.squawk}")
        if self.alert is not None:
            log.debug(f"alert            : {self.alert}")
        if self.emergency is not None:
            log.debug(f"emergency        : {self.emergency}")
        if self.spi is not None:
            log.debug(f"spi              : {self.spi}")
        if self.onGround is not None:
            log.debug(f"onGround         : {self.onGround}")

    def toJSON(self):
        return json.dumps({
            'timestamp': self.loggedDate.isoformat() if self.loggedDate else None,
            'aircraftID': self.aircraftID,
            'squawk': self.squawk,
            'callsign': self.callsign,
            'verticalRate': self.verticalRate,
            'track': self.track,
            'transmissionType': self.transmissionType,
            'onGround': self.onGround,
            'alert': self.alert,
            'emergency': self.emergency,
            'spi': self.spi,
            'icao24': self.icao24,
            'latitude': self.lat,
            'longitude': self.lon,
            'groundSpeed': self.groundSpeed,
            'altitude': self.altitude,
        })
