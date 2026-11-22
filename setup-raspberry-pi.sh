#!/bin/sh
# SPDX-License-Identifier: MIT
# Bootstrap for ADSBDawg on Raspberry Pi OS (Debian based). Run as root:
#   sudo DD_API_KEY=<key> sh setup-raspberry-pi.sh
#
# This file only installs Nushell and hands over to setup.nu. Nushell (MIT) is taken
# from the official nushell/nushell release at a pinned version, and the tarball is
# verified against a pinned SHA-256 before anything is extracted or executed.
# To upgrade: change NU_VERSION and the three digests together (the release publishes
# them in its SHA256SUMS asset), run `nu setup.nu --dry-run`, commit.
set -eu

NU_VERSION=0.117.0
case "$(uname -m)" in
  aarch64 | arm64)
    NU_TARGET=aarch64-unknown-linux-musl
    NU_SHA256=19966b94ae19f52e2cf0402cb99844ddfa06e2361cf6c77b1b2e29abd17e9188 ;;
  armv7l | armv8l)
    NU_TARGET=armv7-unknown-linux-musleabihf
    NU_SHA256=a0a3706dbf31e2f42c0b6ca7d5e73f671f42cdaf6ef56eaf30779ee3d6770c47 ;;
  x86_64)
    NU_TARGET=x86_64-unknown-linux-musl
    NU_SHA256=2b808786d44af41170a29f8b9a15b5113bb6ea5dda9221098eca932f8a149924 ;;
  *)
    echo "ERROR: unsupported architecture $(uname -m)" >&2
    exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root (sudo)." >&2
  exit 1
fi

HERE=$(cd "$(dirname "$0")" && pwd)
NU_DIR="/opt/adsbdawg/nu/$NU_VERSION"
NU_BIN="$NU_DIR/nu"
NU_NAME="nu-$NU_VERSION-$NU_TARGET"

if [ ! -x "$NU_BIN" ] || [ "$("$NU_BIN" --version 2>/dev/null || true)" != "$NU_VERSION" ]; then
  command -v curl >/dev/null 2>&1 || {
    apt-get update
    apt-get install -y --no-install-recommends curl ca-certificates
  }
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  echo "==> Downloading Nushell $NU_VERSION ($NU_TARGET)"
  curl --proto '=https' --tlsv1.2 -fsSL -o "$TMP/$NU_NAME.tar.gz" \
    "https://github.com/nushell/nushell/releases/download/$NU_VERSION/$NU_NAME.tar.gz"
  echo "$NU_SHA256  $TMP/$NU_NAME.tar.gz" | sha256sum -c - || {
    echo "ERROR: Nushell checksum mismatch; refusing to run it." >&2
    exit 1
  }
  tar -xzf "$TMP/$NU_NAME.tar.gz" -C "$TMP"
  mkdir -p "$NU_DIR"
  install -m 0755 "$TMP/$NU_NAME/nu" "$NU_BIN"
fi

exec "$NU_BIN" --no-config-file "$HERE/setup.nu" --nu-bin "$NU_BIN" "$@"
