#!/usr/bin/env nu
# SPDX-License-Identifier: MIT
# ADSBDawg: stream ADS-B data from dump1090 (SBS-1, port 30003) to Datadog via DogStatsD.
#
#   nu adsb.nu run    read the SBS-1 feed, send DogStatsD datagrams (reconnects forever)
#   nu adsb.nu emit   read SBS-1 lines on stdin, print DogStatsD lines on stdout (debug/tests)
#
# TCP and UDP transport use `nc` (OpenBSD netcat, BSD licensed); parsing and metric
# construction are pure Nushell functions so they can be tested without a network.

use sbs1.nu [parse-sbs1 to-json-record]

const ICAO_COUNTRY_RANGES = [
    [lo hi cc];
    [0x008000 0x00FFFF 'ZA'] [0x010000 0x017FFF 'EG'] [0x020000 0x027FFF 'MA']
    [0x0A0000 0x0AFFFF 'NG'] [0x100000 0x1FFFFF 'RU'] [0x300000 0x33FFFF 'IT']
    [0x340000 0x37FFFF 'ES'] [0x380000 0x3BFFFF 'FR'] [0x3C0000 0x3FFFFF 'DE']
    [0x400000 0x43FFFF 'GB'] [0x440000 0x447FFF 'AT'] [0x448000 0x44FFFF 'BE']
    [0x450000 0x457FFF 'BG'] [0x458000 0x45FFFF 'DK'] [0x460000 0x467FFF 'FI']
    [0x468000 0x46FFFF 'GR'] [0x470000 0x477FFF 'HU'] [0x478000 0x47FFFF 'NO']
    [0x480000 0x487FFF 'NL'] [0x488000 0x48FFFF 'PL'] [0x490000 0x497FFF 'PT']
    [0x498000 0x49FFFF 'CZ'] [0x4A0000 0x4A7FFF 'RO'] [0x4B0000 0x4B7FFF 'SE']
    [0x4C0000 0x4C7FFF 'CH'] [0x4CA000 0x4CBFFF 'IE'] [0x4D0000 0x4D7FFF 'TR']
    [0x780000 0x7BFFFF 'CN'] [0x7C0000 0x7FFFFF 'AU'] [0x800000 0x83FFFF 'IN']
    [0x840000 0x87FFFF 'JP'] [0x900000 0x93FFFF 'KR'] [0xA00000 0xAFFFFF 'US']
    [0xC00000 0xC3FFFF 'CA'] [0xE00000 0xE3FFFF 'AR'] [0xE40000 0xE7FFFF 'BR']
]

const ACTIVE_WINDOW_S = 300.0

export def icao-country [icao24: any]: nothing -> string {
    if $icao24 == null or not ($icao24 =~ '^[0-9a-fA-F]{1,8}$') { return 'unknown' }
    let v = ($icao24 | into int --radix 16)
    let hit = ($ICAO_COUNTRY_RANGES | where {|r| $v >= $r.lo and $v <= $r.hi })
    if ($hit | is-empty) { 'unknown' } else { $hit | first | get cc }
}

export def altitude-band [altitude_ft: any]: nothing -> string {
    if $altitude_ft == null { return 'unknown' }
    if $altitude_ft < 1000 { return 'surface' }
    if $altitude_ft < 10000 { return 'approach' }
    if $altitude_ft < 18000 { return 'transition' }
    if $altitude_ft < 35000 { return 'cruise_low' }
    'cruise_high'
}

export def haversine-nm [lat1: float, lon1: float, lat2: float, lon2: float]: nothing -> float {
    let r = 3440.065
    let rad = (3.141592653589793 / 180.0)
    let dlat = (($lat2 - $lat1) * $rad)
    let dlon = (($lon2 - $lon1) * $rad)
    let a = ((($dlat / 2) | math sin) ** 2) + ((($lat1 * $rad) | math cos) * (($lat2 * $rad) | math cos) * ((($dlon / 2) | math sin) ** 2))
    let clamped = ([0.0 ([1.0 $a] | math min)] | math max)
    $r * 2 * (($clamped | math sqrt) | math arcsin)
}

# DogStatsD tags may not contain , | or newlines.
def clean-tag [text: string]: nothing -> string {
    $text | str replace -a -r '[,|\r\n]' '_'
}

export def build-tags [msg: record]: nothing -> list<string> {
    mut tags = []
    if $msg.icao24 != null {
        $tags = ($tags | append [$"icao24:(clean-tag $msg.icao24)" $"icao_country:(icao-country $msg.icao24)"])
    }
    if $msg.callsign != null { $tags = ($tags | append $"callsign:(clean-tag $msg.callsign)") }
    if $msg.onGround != null { $tags = ($tags | append $"on_ground:($msg.onGround)") }
    if $msg.altitude != null { $tags = ($tags | append $"altitude_band:(altitude-band $msg.altitude)") }
    if $msg.squawk != null {
        $tags = ($tags | append $"squawk:($msg.squawk | into string | fill --alignment right --character '0' --width 4)")
    }
    $tags
}

def metric [kind: string, name: string, value: any, tags: list<string>]: nothing -> record {
    {kind: $kind, name: $name, value: $value, tags: $tags}
}

# Metrics for one parsed message. Pure; active-aircraft tracking is added by process-line.
export def message-metrics [msg: record, opts: record]: nothing -> list<record> {
    let tags = (build-tags $msg)
    mut out = [(metric c adsb.message 1 $tags)]
    if $msg.groundSpeed != null { $out = ($out | append (metric g adsb.airspeed $msg.groundSpeed $tags)) }
    if $msg.altitude != null { $out = ($out | append (metric g adsb.altitude $msg.altitude $tags)) }
    if $msg.track != null { $out = ($out | append (metric h adsb.heading $msg.track $tags)) }
    if $msg.verticalRate != null {
        if $msg.verticalRate > 0 {
            $out = ($out | append (metric g adsb.ascentrate $msg.verticalRate $tags))
        } else {
            $out = ($out | append (metric g adsb.descentrate ($msg.verticalRate | math abs) $tags))
        }
    }
    if $msg.lat != null { $out = ($out | append (metric g adsb.latitude $msg.lat $tags)) }
    if $msg.lon != null { $out = ($out | append (metric g adsb.longitude $msg.lon $tags)) }
    if $msg.squawk != null { $out = ($out | append (metric g adsb.squawk $msg.squawk $tags)) }
    if $msg.emergency == true { $out = ($out | append (metric c adsb.emergency 1 $tags)) }
    if $msg.alert == true { $out = ($out | append (metric c adsb.alert 1 $tags)) }
    if $msg.spi == true { $out = ($out | append (metric c adsb.spi 1 $tags)) }
    if $msg.onGround != null { $out = ($out | append (metric g adsb.onground (if $msg.onGround { 1 } else { 0 }) $tags)) }
    if $opts.receiver_lat != null and $opts.receiver_lon != null and $msg.lat != null and $msg.lon != null {
        let rng = (haversine-nm $opts.receiver_lat $opts.receiver_lon $msg.lat $msg.lon)
        $out = ($out | append (metric g adsb.range_nm $rng $tags))
    }
    if $msg.generatedDate != null and $msg.loggedDate != null {
        let lag_ms = (($msg.loggedDate - $msg.generatedDate) / 1ms)
        if $lag_ms >= 0 { $out = ($out | append (metric g adsb.message.lag_ms $lag_ms $tags)) }
    }
    $out
}

export def format-metric [m: record]: nothing -> string {
    let tags = if ($m.tags | is-empty) { '' } else { $"|#($m.tags | str join ',')" }
    $"($m.name):($m.value)|($m.kind)($tags)"
}

# Record `icao24` as seen at `now` (seconds) and drop aircraft silent for > 300 s.
export def track-active [seen: record, icao24: string, now: float]: nothing -> record {
    let updated = ($seen | upsert $icao24 $now)
    let cutoff = ($now - $ACTIVE_WINDOW_S)
    let stale = ($updated | items {|k, v| if $v < $cutoff { $k } } | compact)
    if ($stale | is-empty) { $updated } else { $updated | reject ...$stale }
}

# One SBS-1 line -> {lines: DogStatsD lines, seen: updated active-aircraft record}.
export def process-line [line: string, seen: record, opts: record, now: float]: nothing -> record {
    let text = ($line | str trim)
    if ($text | is-empty) { return {lines: [], seen: $seen} }
    if not ($text | str starts-with 'MSG,') { return {lines: ['adsb.message.invalid:1|c'], seen: $seen} }
    let msg = (parse-sbs1 $text)
    if not $msg.isValid { return {lines: ['adsb.message.invalid:1|c'], seen: $seen} }
    mut metrics = (message-metrics $msg $opts)
    mut next_seen = $seen
    if $msg.icao24 != null {
        $next_seen = (track-active $seen $msg.icao24 $now)
        $metrics = ($metrics | insert 1 (metric g adsb.aircraft.active ($next_seen | columns | length) []))
    }
    {lines: ($metrics | each {|m| format-metric $m }), seen: $next_seen}
}

def now-s []: nothing -> float {
    (date now | into int) / 1_000_000_000.0
}

# Streaming filter: SBS-1 lines in, one datagram string (newline-joined metrics) per input line out.
export def stream-datagrams [opts: record]: list<string> -> list<string> {
    generate {|line, seen|
        let r = (process-line $line $seen $opts (now-s))
        if ($r.lines | is-empty) {
            {next: $r.seen}
        } else {
            {out: ($r.lines | str join (char nl)), next: $r.seen}
        }
    } {}
}

def opts-from [receiver_lat: any, receiver_lon: any]: nothing -> record {
    let lat = ($receiver_lat | default ($env.ADSB_RECEIVER_LAT? | default null))
    let lon = ($receiver_lon | default ($env.ADSB_RECEIVER_LON? | default null))
    {
        receiver_lat: (if $lat == null or $lat == '' { null } else { $lat | into float })
        receiver_lon: (if $lon == null or $lon == '' { null } else { $lon | into float })
    }
}

# Read SBS-1 lines on stdin, print DogStatsD lines on stdout.
def "main emit" [--receiver-lat: any, --receiver-lon: any]: string -> nothing {
    lines | stream-datagrams (opts-from $receiver_lat $receiver_lon) | each {|d| print $d } | ignore
}

# One connection: dump1090 -> parse -> DogStatsD. Returns when the feed closes or errors.
def session [host: string, port: int, statsd_host: string, statsd_port: int, opts: record] {
    ^nc -d -w 30 $host ($port | into string)
        | lines
        | stream-datagrams $opts
        | to text
        | ^nc -u -q 1 $statsd_host ($statsd_port | into string)
}

def send-statsd [statsd_host: string, statsd_port: int, line: string] {
    try { $"($line)\n" | ^nc -u -w 1 $statsd_host ($statsd_port | into string) } catch { null }
}

# Connect to dump1090 and stream metrics forever, reconnecting with capped backoff.
def "main run" [
    --host: string          # dump1090 host (env ADSB_HOST, default localhost)
    --port: int             # dump1090 SBS-1 port (env ADSB_PORT, default 30003)
    --receiver-lat: any     # receiver latitude for range metrics (env ADSB_RECEIVER_LAT)
    --receiver-lon: any     # receiver longitude for range metrics (env ADSB_RECEIVER_LON)
    --statsd-host: string   # DogStatsD host (env ADSB_STATSD_HOST, default 127.0.0.1)
    --statsd-port: int      # DogStatsD UDP port (env ADSB_STATSD_PORT, default 8125)
    --max-sessions: int     # stop after this many connection attempts (tests only)
] {
    let host = ($host | default ($env.ADSB_HOST? | default 'localhost'))
    let port = ($port | default ($env.ADSB_PORT? | default '30003' | into int))
    let sh = ($statsd_host | default ($env.ADSB_STATSD_HOST? | default '127.0.0.1'))
    let sp = ($statsd_port | default ($env.ADSB_STATSD_PORT? | default '8125' | into int))
    let opts = (opts-from $receiver_lat $receiver_lon)
    mut attempt = 0
    mut sessions = 0
    loop {
        print --stderr $"Connecting to ($host):($port)..."
        send-statsd $sh $sp 'adsb.connection.established:1|c'
        let r = (try { session $host $port $sh $sp $opts; {ok: true} } catch {|e| {ok: false, msg: $e.msg} })
        $sessions += 1
        # A session that ran to a clean close still counts as a lost connection.
        $attempt = if $r.ok { 1 } else { $attempt + 1 }
        send-statsd $sh $sp 'adsb.connection.error:1|c'
        print --stderr $"Connection lost \(attempt ($attempt)\)"
        if $max_sessions != null and $sessions >= $max_sessions { break }
        let delay = ([(5 * (2 ** ([($attempt - 1) 4] | math min))) 60] | math min)
        print --stderr $"Retrying in ($delay) seconds..."
        sleep ($delay * 1sec)
    }
}

def main [] {
    print "usage: nu adsb.nu run | nu adsb.nu emit   (see README.md)"
}
