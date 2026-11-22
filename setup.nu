#!/usr/bin/env nu
# SPDX-License-Identifier: MIT
# One-shot setup for ADSBDawg on Raspberry Pi OS (Debian based). Normally started by
# setup-raspberry-pi.sh, which installs the pinned Nushell first:
#   sudo DD_API_KEY=<key> sh setup-raspberry-pi.sh
# `--dry-run` prints every action and changes nothing (used by CI).

# Datadog Agent installer, pinned. The script at this URL is mutable: when Datadog
# publishes a new version the checksum check fails closed. Review the new script, then
# update both values (install_script_version is printed at line 12 of the script).
const DD_INSTALL_URL = 'https://install.datadoghq.com/scripts/install_script_agent7.sh'
const DD_INSTALL_VERSION = '1.49.0'
const DD_INSTALL_SHA256 = '844d4192a87898bb42858b0f4b01de5b6fa6c6a15dc90d4557ad320c1434ca0d'

const HERE = (path self | path dirname)

def step [dry: bool, text: string] { print $"==> ($text)" }

# Run an external command, or only print it in dry-run mode.
def act [dry: bool, argv: list<string>] {
    if $dry { print $"    \(dry-run) ($argv | str join (char space))" } else { run-external ($argv | first) ...($argv | skip 1) }
}

def put-file [dry: bool, path: string, content: string, mode: string] {
    if $dry {
        print $"    \(dry-run) write ($path) mode ($mode)"
    } else {
        mkdir ($path | path dirname)
        $content | save --raw --force $path
        ^chmod $mode $path
    }
}

# Contents of /etc/adsbdawg/env
export def env-file []: nothing -> string {
    [
        'ADSB_HOST=localhost'
        'ADSB_PORT=30003'
        'ADSB_STATSD_HOST=127.0.0.1'
        'ADSB_STATSD_PORT=8125'
        '# Set these for range metrics (decimal degrees):'
        '# ADSB_RECEIVER_LAT=37.7749'
        '# ADSB_RECEIVER_LON=-122.4194'
        ''
    ] | str join (char nl)
}

# systemd unit rendered from adsb.service for this install.
export def render-unit [template: string, install_dir: string, user: string, nu_bin: string]: nothing -> string {
    $template
        | str replace --all '/home/pi/adsbdawg' $install_dir
        | str replace --all 'User=pi' $"User=($user)"
        | str replace --all '/opt/adsbdawg/nu/0.117.0/nu' $nu_bin
}

# True when the file at `path` has exactly the pinned SHA-256 (lowercase hex).
export def sha256-matches [path: path, expected: string]: nothing -> bool {
    (open --raw $path | hash sha256) == ($expected | str lowercase)
}

# Verify then run the pinned Datadog Agent installer.
def install-datadog-agent [dry: bool, api_key: string, site: string] {
    if (which datadog-agent | is-not-empty) {
        print 'Datadog Agent already installed, skipping.'
        return
    }
    if $dry {
        print $"    \(dry-run) fetch ($DD_INSTALL_URL), require sha256 ($DD_INSTALL_SHA256) \(script ($DD_INSTALL_VERSION)), then run it"
        return
    }
    let tmp = (mktemp -d)
    let script = ($tmp | path join 'install_script_agent7.sh')
    ^curl --proto '=https' --tlsv1.2 -fsSL -o $script $DD_INSTALL_URL
    if not (sha256-matches $script $DD_INSTALL_SHA256) {
        rm -r $tmp
        error make {msg: $"Datadog installer checksum mismatch \(sha256 differs\); refusing to run it"}
    }
    with-env {DD_API_KEY: $api_key, DD_SITE: $site, DD_AGENT_MAJOR_VERSION: '7'} {
        ^bash $script
    }
    rm -r $tmp
}

def main [
    --nu-bin: string = '/opt/adsbdawg/nu/0.117.0/nu'  # the Nushell that runs adsb.nu
    --dry-run                                         # print actions, change nothing
] {
    let dry = $dry_run
    let api_key = ($env.DD_API_KEY? | default '')
    if $api_key == '' or $api_key == 'YOUR_DATADOG_API_KEY' {
        if $dry { print 'note: DD_API_KEY not set (required for a real run)' } else {
            error make {msg: 'Set DD_API_KEY before running: sudo DD_API_KEY=<key> sh setup-raspberry-pi.sh'}
        }
    }
    let user = ($env.SUDO_USER? | default 'pi')
    let install_dir = $"/home/($user)/adsbdawg"
    let dd_site = ($env.DD_SITE? | default 'datadoghq.com')
    let boot_config = if ('/boot/firmware/config.txt' | path exists) { '/boot/firmware/config.txt' } else { '/boot/config.txt' }
    $env.DEBIAN_FRONTEND = 'noninteractive'
    $env.NEEDRESTART_MODE = 'a'

    step $dry $"User: ($user) | Install dir: ($install_dir) | Nushell: ($nu_bin)"
    if not $dry and (^df --output=avail / | lines | last | str trim | into int) < 524288 {
        error make {msg: 'Less than 512 MB free on /. Aborting.'}
    }

    step $dry 'Installing RTL-SDR and system tools'
    act $dry [apt-get update]
    act $dry [apt-get install -y --no-install-recommends rtl-sdr librtlsdr-dev netcat-openbsd curl ca-certificates usbutils]

    step $dry 'Blacklisting dvb_usb_rtl28xxu kernel module'
    let blacklist = '/etc/modprobe.d/blacklist-rtl.conf'
    let has_entry = ($blacklist | path exists) and (open --raw $blacklist | str contains 'blacklist dvb_usb_rtl28xxu')
    if not $has_entry {
        put-file $dry $blacklist "blacklist dvb_usb_rtl28xxu\n" '644'
    }
    if not $dry { try { ^modprobe -r dvb_usb_rtl28xxu } catch { null } }

    step $dry 'Disabling USB autosuspend for the RTL-SDR dongle'
    let udev = [
        'SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", ATTR{power/autosuspend}="-1"'
        'SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", ATTR{power/autosuspend}="-1"'
        ''
    ] | str join (char nl)
    put-file $dry '/etc/udev/rules.d/99-rtlsdr-power.rules' $udev '644'
    act $dry [udevadm control --reload-rules]
    act $dry [udevadm trigger --subsystem-match=usb]
    act $dry [usermod -aG plugdev $user]

    if not $dry and ((^lsusb | complete | get stdout) !~ '0bda:283') {
        print 'WARNING: RTL-SDR dongle not detected. Ensure it is connected.'
    }

    step $dry 'Installing dump1090'
    let dump = if $dry { 'dump1090-fa' } else {
        if (^apt-get install -y --no-install-recommends dump1090-fa | complete | get exit_code) == 0 { 'dump1090-fa' } else if (^apt-get install -y --no-install-recommends dump1090-mutability | complete | get exit_code) == 0 { 'dump1090-mutability' } else {
            error make {msg: 'Could not install any dump1090 variant. Add the FlightAware apt repo first: https://flightaware.com/adsb/piaware/install'}
        }
    }
    act $dry [systemctl enable --now $dump]

    step $dry 'Installing the Datadog Agent'
    install-datadog-agent $dry $api_key $dd_site
    act $dry [systemctl enable --now datadog-agent]

    step $dry 'Writing /etc/adsbdawg/env'
    # Readable by the service user (group), not by others.
    act $dry [install -d -m 750 -o root -g $user /etc/adsbdawg]
    put-file $dry '/etc/adsbdawg/env' (env-file) '640'
    act $dry [chgrp $user /etc/adsbdawg/env]

    step $dry 'Installing the adsbdawg systemd service'
    let template = (open --raw ($HERE | path join 'adsb.service'))
    put-file $dry '/etc/systemd/system/adsbdawg.service' (render-unit $template $install_dir $user $nu_bin) '644'
    act $dry [systemctl daemon-reload]
    act $dry [systemctl enable --now adsbdawg.service]

    step $dry 'Raspberry Pi tuning'
    for line in ['gpu_mem=16' 'dtoverlay=disable-bt'] {
        let key = ($line | split row '=' | first)
        let present = ($boot_config | path exists) and (open --raw $boot_config | lines | any {|l| $l | str starts-with $key })
        if not $present {
            if $dry { print $"    \(dry-run) append ($line) to ($boot_config)" } else { $"($line)\n" | save --raw --append $boot_config }
        }
    }

    step $dry 'Reducing journald SD card wear'
    let journald = [
        '[Journal]' 'SystemMaxUse=50M' 'RuntimeMaxUse=20M' 'RateLimitBurst=200' 'RateLimitIntervalSec=30s' ''
    ] | str join (char nl)
    put-file $dry '/etc/systemd/journald.conf.d/adsbdawg.conf' $journald '644'
    act $dry [systemctl restart systemd-journald]

    if not $dry and ((^timedatectl show | complete | get stdout) !~ 'NTPSynchronized=yes') {
        print 'WARNING: NTP not yet synchronized; ADS-B timestamps may be wrong until it is.'
    }

    print ''
    print '==> Setup complete. A reboot is recommended to apply the RTL-SDR module blacklist.'
    print $"Verify: systemctl status ($dump) adsbdawg datadog-agent; journalctl -u adsbdawg -f"
    print 'Import dashboards/adsb_dashboard.json in Datadog: Dashboards > New Dashboard > Import JSON'
}
