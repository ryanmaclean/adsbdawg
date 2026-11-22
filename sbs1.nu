# SPDX-License-Identifier: MIT
# SBS-1 (BaseStation) message parser for the dump1090 feed on port 30003.
# Field layout follows github.com/wiseman/node-sbs1 (MIT).
# Absent or malformed fields parse to null; a frame is valid when it starts with MSG.

def field [parts: list<string>, idx: int]: nothing -> any {
    let raw = ($parts | get -o $idx)
    if $raw == null { return null }
    let trimmed = ($raw | str trim)
    if ($trimmed | is-empty) { null } else { $trimmed }
}

def as-int [raw: any]: nothing -> any {
    if $raw == null { return null }
    if ($raw =~ '^[+-]?[0-9]+$') { $raw | str replace -r '^\+' '' | into int } else { null }
}

def as-float [raw: any]: nothing -> any {
    if $raw == null { return null }
    if ($raw =~ '^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$') {
        $raw | str replace -r '^\+' '' | into float
    } else { null }
}

def as-bool [raw: any]: nothing -> any {
    let n = (as-int $raw)
    if $n == null { null } else { $n != 0 }
}

# SBS carries four octal digits as text, not a base-8 integer value.
# The result keeps the historical decimal-digit integer (0750 -> 750).
def as-squawk [raw: any]: nothing -> any {
    if $raw == null { return null }
    if ($raw =~ '^[0-7]{4}$') { $raw | into int } else { null }
}

def as-datetime [date: any, time: any]: nothing -> any {
    if $date == null or $time == null { return null }
    let text = $"($date) ($time)"
    if not ($text =~ '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?$') { return null }
    let fmt = if ($text | str contains '.') { '%Y/%m/%d %H:%M:%S%.f' } else { '%Y/%m/%d %H:%M:%S' }
    try { $text | into datetime --timezone UTC --format $fmt } catch { null }
}

# Parse one SBS-1 line into a record. Never throws.
export def parse-sbs1 [line: string]: nothing -> record {
    let parts = ($line | split row ',')
    let kind = (field $parts 0)
    let valid = ($kind == 'MSG')
    {
        isValid: $valid
        messageType: (if $valid { 'MSG' } else { null })
        transmissionType: (as-int (field $parts 1))
        sessionID: (field $parts 2)
        aircraftID: (field $parts 3)
        icao24: (field $parts 4)
        flightID: (field $parts 5)
        generatedDate: (as-datetime (field $parts 6) (field $parts 7))
        loggedDate: (as-datetime (field $parts 8) (field $parts 9))
        callsign: (field $parts 10)
        altitude: (as-int (field $parts 11))
        groundSpeed: (as-int (field $parts 12))
        track: (as-int (field $parts 13))
        lat: (as-float (field $parts 14))
        lon: (as-float (field $parts 15))
        verticalRate: (as-int (field $parts 16))
        squawk: (as-squawk (field $parts 17))
        alert: (as-bool (field $parts 18))
        emergency: (as-bool (field $parts 19))
        spi: (as-bool (field $parts 20))
        onGround: (as-bool (field $parts 21))
    }
}

# JSON projection of a parsed message (same keys as the former Python toJSON).
export def to-json-record [msg: record]: nothing -> string {
    {
        timestamp: (if $msg.loggedDate == null { null } else { $msg.loggedDate | format date '%Y-%m-%dT%H:%M:%S%.f' })
        aircraftID: $msg.aircraftID
        squawk: $msg.squawk
        callsign: $msg.callsign
        verticalRate: $msg.verticalRate
        track: $msg.track
        transmissionType: $msg.transmissionType
        onGround: $msg.onGround
        alert: $msg.alert
        emergency: $msg.emergency
        spi: $msg.spi
        icao24: $msg.icao24
        latitude: $msg.lat
        longitude: $msg.lon
        groundSpeed: $msg.groundSpeed
        altitude: $msg.altitude
    } | to json --raw
}
