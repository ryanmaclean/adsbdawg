#!/usr/bin/env nu
# SPDX-License-Identifier: MIT
# Executes the SBS-1 parser, the metric producer and the DogStatsD wire path.
#   nu --no-config-file tests/run.nu            # everything
#   nu --no-config-file tests/run.nu --no-wire  # pure tests only (no nc, no sockets)
# Exits non-zero on the first failed assertion.

use std/assert
use ../sbs1.nu [parse-sbs1 to-json-record]
use ../setup.nu [sha256-matches render-unit env-file]
use ../adsb.nu [icao-country altitude-band haversine-nm build-tags message-metrics format-metric track-active process-line]

const HERE = (path self | path dirname)
const NO_RECEIVER = {receiver_lat: null, receiver_lon: null}

def metric-of [ms: list<record>, name: string]: nothing -> record { $ms | where name == $name | first }

def has-tags [actual: list<string>, required: list<string>]: nothing -> bool {
    $required | all {|t| $t in $actual }
}

def run-case [case: record]: nothing -> nothing {
    let id = $case.id
    let msg = (parse-sbs1 $case.input)
    let want = $case.expected
    assert equal $msg.isValid $want.isValid $"($id): isValid"
    assert equal $msg.squawk $want.squawk $"($id): parsed squawk"
    assert equal (to-json-record $msg | from json | get squawk) $want.json_squawk $"($id): json squawk"
    let metrics = (message-metrics $msg $NO_RECEIVER)
    let tags = ($metrics | first | get tags)
    let squawk_tag = ($tags | where {|t| $t | str starts-with 'squawk:' })
    if $want.squawk_tag == null {
        assert ($squawk_tag | is-empty) $"($id): no squawk tag expected"
    } else {
        assert equal $squawk_tag [$want.squawk_tag] $"($id): squawk tag"
    }
    let gauges = ($metrics | where name == 'adsb.squawk')
    if $want.forbid_squawk_gauge { assert ($gauges | is-empty) $"($id): no squawk gauge expected" }
    for exp in $want.expected_metrics {
        let kind = if $exp.method == 'increment' { 'c' } else { 'g' }
        let found = ($metrics | where name == $exp.metric and kind == $kind)
        if $exp.method == 'increment' { assert equal ($found | length) $exp.times $"($id): ($exp.metric) count" }
        assert (not ($found | is-empty)) $"($id): ($exp.metric) emitted"
        let hit = ($found | first)
        assert (has-tags $hit.tags $exp.required_tags) $"($id): required tags on ($exp.metric): ($hit.tags)"
        if ($exp | get -o value) != null and $exp.method == 'gauge' {
            assert equal $hit.value $exp.value $"($id): ($exp.metric) value"
        }
        if ($exp | get -o forbid_squawk_tag) == true {
            assert ($hit.tags | all {|t| not ($t | str starts-with 'squawk:') }) $"($id): squawk tag forbidden"
        }
    }
}

def run-sequence [seq: record]: nothing -> nothing {
    mut seen = {}
    mut all = []
    for line in $seq.inputs {
        let r = (process-line $line $seen $NO_RECEIVER 1000.0)
        $seen = $r.seen
        $all = ($all | append $r.lines)
    }
    let want = $seq.expected
    let msg_lines = ($all | where {|l| $l | str starts-with 'adsb.message:' })
    let tagged = ($msg_lines | where {|l| $l | str contains 'squawk:' })
    let gauge_vals = ($all | where {|l| $l | str starts-with 'adsb.squawk:' } | each {|l| $l | split row ':' | get 1 | split row '|' | first | into int })
    if ($want | get -o squawk_tagged_message_increments) != null {
        assert equal ($tagged | length) $want.squawk_tagged_message_increments $"($seq.id): tagged increments"
    }
    if ($want | get -o total_message_increments) != null {
        assert equal ($msg_lines | length) $want.total_message_increments $"($seq.id): total increments"
    }
    if ($want | get -o numeric_squawk_gauge_values) != null {
        assert equal $gauge_vals $want.numeric_squawk_gauge_values $"($seq.id): gauge values"
    }
    if ($want | get -o squawk_gauge_calls) != null {
        assert equal ($gauge_vals | length) $want.squawk_gauge_calls $"($seq.id): gauge calls"
    }
    if ($want | get -o parser_squawk) == null and ('parser_squawk' in ($want | columns)) {
        assert equal (parse-sbs1 ($seq.inputs | first) | get squawk) null $"($seq.id): parser squawk"
    }
}

def unit-tests []: nothing -> int {
    mut n = 0
    # country and altitude bands
    for row in [['A1B2C3' 'US'] ['400000' 'GB'] ['3C0000' 'DE'] ['4CA001' 'IE'] ['000001' 'unknown'] ['zzzz' 'unknown'] ['' 'unknown']] {
        assert equal (icao-country ($row.0)) ($row.1) $"country ($row.0)"; $n += 1
    }
    assert equal (icao-country null) 'unknown'; $n += 1
    for row in [[null 'unknown'] [0 'surface'] [999 'surface'] [1000 'approach'] [9999 'approach'] [10000 'transition'] [17999 'transition'] [18000 'cruise_low'] [34999 'cruise_low'] [35000 'cruise_high']] {
        assert equal (altitude-band ($row.0)) ($row.1) $"band ($row.0)"; $n += 1
    }
    # great-circle distance: one degree of latitude is 60.04 nm on this radius
    let one_deg = (haversine-nm 0.0 0.0 1.0 0.0)
    assert ((($one_deg - 60.0425) | math abs) < 0.01) $"one degree: ($one_deg)"; $n += 1
    assert equal (haversine-nm 10.0 20.0 10.0 20.0) 0.0; $n += 1
    # parser fields
    let full = (parse-sbs1 'MSG,3,1,1,400A1B,1,2026/11/22,12:00:00.250,2026/11/22,12:00:00.750,BAW123,35000,450,270,51.5,-0.12,-640,7700,1,1,1,0')
    assert equal $full.callsign 'BAW123'; $n += 1
    assert equal $full.altitude 35000; $n += 1
    assert equal $full.lat 51.5; $n += 1
    assert equal $full.lon (-0.12); $n += 1
    assert equal $full.verticalRate (-640); $n += 1
    assert equal [$full.alert $full.emergency $full.spi $full.onGround] [true true true false]; $n += 1
    let ms = (message-metrics $full {receiver_lat: 51.0, receiver_lon: 0.0})
    let by_name = ($ms | group-by name)
    assert equal (metric-of $ms 'adsb.message.lag_ms' | get value) 500.0; $n += 1
    assert equal (metric-of $ms 'adsb.descentrate' | get value) 640; $n += 1
    assert ('adsb.ascentrate' not-in ($by_name | columns)); $n += 1
    assert equal (metric-of $ms 'adsb.heading' | get kind) 'h'; $n += 1
    assert ('adsb.range_nm' in ($by_name | columns)); $n += 1
    assert equal (metric-of $ms 'adsb.emergency' | get kind) 'c'; $n += 1
    assert equal (metric-of $ms 'adsb.onground' | get value) 0; $n += 1
    assert equal ($ms | first | get tags) ['icao24:400A1B' 'icao_country:GB' 'callsign:BAW123' 'on_ground:false' 'altitude_band:cruise_high' 'squawk:7700']; $n += 1
    # non-MSG frames, empty lines, bad fields
    assert equal (parse-sbs1 'STA,6,1').isValid false; $n += 1
    assert equal (process-line 'garbage' {} $NO_RECEIVER 0.0 | get lines) ['adsb.message.invalid:1|c']; $n += 1
    assert equal (process-line '   ' {} $NO_RECEIVER 0.0 | get lines) []; $n += 1
    let bad = (parse-sbs1 'MSG,3,1,1,400A1B,1,2026/13/40,99:00:00,,,,abc,1.5,,,,,,,,,')
    assert equal [$bad.generatedDate $bad.altitude $bad.groundSpeed] [null null null]; $n += 1
    # DogStatsD formatting and tag hygiene
    assert equal (format-metric {kind: 'g', name: 'a.b', value: 3, tags: []}) 'a.b:3|g'; $n += 1
    assert equal (format-metric {kind: 'c', name: 'a.b', value: 1, tags: ['x:1' 'y:2']}) 'a.b:1|c|#x:1,y:2'; $n += 1
    let hostile = (parse-sbs1 'MSG,1,1,1,400A1B,1,,,,,CALL|#x,,,,,,,,,,,')
    assert equal (build-tags $hostile | where {|t| $t | str starts-with 'callsign:' }) ['callsign:CALL_#x']; $n += 1
    # active-aircraft window: 300 s, numeric-looking ICAO keys must not index
    let s1 = (track-active {} '400000' 1000.0)
    let s2 = (track-active $s1 '123456' 1100.0)
    assert equal ($s2 | columns | sort) ['123456' '400000']; $n += 1
    let s3 = (track-active $s2 'ABCDEF' 1301.0)
    assert equal ($s3 | columns | sort) ['123456' 'ABCDEF']; $n += 1
    let s4 = (track-active $s3 'ABCDEF' 1500.0)
    assert equal ($s4 | columns) ['ABCDEF']; $n += 1
    let two = (process-line 'MSG,1,1,1,400A1B,1,,,,,X,,,,,,,,,,,' {} $NO_RECEIVER 5.0)
    assert ($two.lines | any {|l| $l | str starts-with 'adsb.aircraft.active:1|g' }); $n += 1
    $n
}

def setup-tests []: nothing -> int {
    let work = (mktemp -d)
    let f = ($work | path join 'payload')
    "hello\n" | save --raw $f
    assert (sha256-matches $f '5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03') 'sha256 of known payload'
    assert (sha256-matches $f '5891B5B522D5DF086D0FF0B110FBD9D21BB4FC7163AF34D08286A2E846F6BE03') 'sha256 compare is case-insensitive'
    assert (not (sha256-matches $f '0000000000000000000000000000000000000000000000000000000000000000')) 'sha256 mismatch refused'
    rm -r $work
    let unit = (render-unit (open --raw ($HERE | path join '..' 'adsb.service')) '/home/ann/adsbdawg' 'ann' '/opt/adsbdawg/nu/9.9.9/nu')
    assert ($unit | str contains 'User=ann') 'unit user'
    assert ($unit | str contains 'ExecStart=/opt/adsbdawg/nu/9.9.9/nu --no-config-file /home/ann/adsbdawg/adsb.nu run') 'unit ExecStart'
    assert (not ($unit | str contains '/home/pi')) 'no pi paths left'
    assert ((env-file) | str contains 'ADSB_STATSD_PORT=8125') 'env file defaults'
    7
}

def fixture-tests []: nothing -> int {
    let fx = (open --raw ($HERE | path join 'squawk-contract-fixtures.json') | from json)
    for case in $fx.cases { run-case $case }
    for seq in $fx.sequences { run-sequence $seq }
    ($fx.cases | length) + ($fx.sequences | length)
}

# End to end: fake dump1090 (nc) -> `adsb.nu run` -> fake DogStatsD (nc -u -l -k).
def wire-test []: nothing -> int {
    let work = (mktemp -d)
    let tcp_port = (random int 20000..29999)
    let udp_port = ($tcp_port + 1)
    let frames = (0..<60 | each {|i|
        let icao = ($"4000(($i mod 40 | into string | fill --alignment right --character '0' --width 2))")
        $"MSG,3,1,1,($icao),1,2026/11/22,12:00:00.100,2026/11/22,12:00:00.300,TST($i),(30000 + $i),400,90,40.($i),-70.5,0,,0,0,0,0"
    })
    let input = ($frames | append ['STA,1' 'MSG,6,1,1,A1B2C3,1,,,,,,,,,,,,7700,,,,'])
    let sbs_file = ($work | path join 'feed.sbs')
    let out_file = ($work | path join 'datagrams.txt')
    ($input | str join (char nl)) + (char nl) | save --raw $sbs_file
    let opts = {receiver_lat: 40.0, receiver_lon: -70.0}
    let expected = ($input | reduce --fold {seen: {}, lines: []} {|l, acc|
        let r = (process-line $l $acc.seen $opts 1000.0)
        {seen: $r.seen, lines: ($acc.lines | append $r.lines)}
    } | get lines | where {|l| not ($l | str starts-with 'adsb.aircraft.active:') })
    let udp = (job spawn { ^nc -u -l -k 127.0.0.1 ($udp_port | into string) o> $out_file e> /dev/null })
    # paced like a real receiver: the whole capture (about 60 KB) must fit the fake UDP listener socket buffer even if it stalls
    let tcp = (job spawn { open --raw $sbs_file | lines | each {|l| sleep 10ms; $l } | to text | ^nc -N -l 127.0.0.1 ($tcp_port | into string) e> /dev/null })
    sleep 500ms
    let exe = $nu.current-exe
    let run = (^$exe --no-config-file ($HERE | path join '..' 'adsb.nu') run --host 127.0.0.1 --port $tcp_port --statsd-host 127.0.0.1 --statsd-port $udp_port --receiver-lat 40.0 --receiver-lon -70.0 --max-sessions 1 | complete)
    # wait until the capture file stops growing (2 s stable, at most 30 s)
    mut last = -1
    mut stable = 0
    for _ in 0..<60 {
        sleep 500ms
        let size = (ls $out_file | get size | first | into int)
        if $size == $last { $stable += 1 } else { $stable = 0; $last = $size }
        if $stable >= 4 { break }
    }
    try { job kill $udp }
    try { job kill $tcp }
    let got = (open --raw $out_file | lines | where {|l| $l != '' })
    assert equal $run.exit_code 0 $"run exit: ($run.stderr)"
    let wire_expected = ($expected | sort)
    let wire_got = ($got | where {|l| not ($l | str starts-with 'adsb.aircraft.active:') and not ($l | str starts-with 'adsb.connection.') } | sort)
    assert equal ($wire_got | length) ($wire_expected | length) $"datagram metric count: ($wire_got | length); missing: ($wire_expected | where {|l| $l not-in $wire_got } | first 3 | to json --raw); extra: ($wire_got | where {|l| $l not-in $wire_expected } | first 3 | to json --raw)"
    assert equal $wire_got $wire_expected 'wire metrics equal in-process metrics'
    assert ('adsb.connection.established:1|c' in $got) 'connection established metric'
    assert ('adsb.connection.error:1|c' in $got) 'connection error metric on feed close'
    assert ('adsb.message.invalid:1|c' in $got) 'invalid frame counted'
    assert ($got | any {|l| $l | str starts-with 'adsb.aircraft.active:' }) 'active gauge sent'
    assert ($got | any {|l| $l =~ '^adsb\.squawk:7700\|g\|#icao24:A1B2C3,icao_country:US,squawk:7700$' }) 'squawk gauge on wire'
    # a refused connection is survived, counted and reported, not fatal
    let refused = (^$exe --no-config-file ($HERE | path join '..' 'adsb.nu') run --host 127.0.0.1 --port ($tcp_port + 2) --statsd-port $udp_port --max-sessions 1 | complete)
    assert equal $refused.exit_code 0 $"refused-connection run exit: ($refused.stderr)"
    assert ($refused.stderr | str contains 'Connection lost') 'refused connection reported'
    let n = ($got | length)
    rm -r $work
    $n
}

def main [--no-wire] {
    let unit = (unit-tests)
    let fixtures = (fixture-tests)
    let setup = (setup-tests)
    let wire = if $no_wire { null } else { wire-test }
    {ok: true, unit_assertions: $unit, fixture_cases_and_sequences: $fixtures, setup_assertions: $setup, wire_datagram_lines: $wire} | to json --raw
}