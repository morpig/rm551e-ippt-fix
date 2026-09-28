#!/bin/sh
# modem-ippt-fix.sh — install / check the RM551E fix hooks on the modem, from the Mac:
# 02-ippt-lan-resync (IPPT host routes) and 03-odhcpd-watchdog (odhcpd stuck after USB
# re-enumeration). The fixes themselves are in modem/ (each file explains its bug). Re-run
# `install` after every modem firmware upgrade: a firmware image can replace /etc.
#
#   ./modem-ippt-fix.sh status      (default) hooks installed? IPPT host routes? odhcpd healthy?
#   ./modem-ippt-fix.sh install     install / update, apply once now
#   ./modem-ippt-fix.sh uninstall
#   ./modem-ippt-fix.sh dry-run
#
# Needs: adb (brew install android-platform-tools); no other app holding the modem's USB device
# (an exclusive claim keeps adb off the ADB interface). macOS adb only sees this modem with
# its native USB backend, hence ADB_LIBUSB=0. Pick a device with ADB_SERIAL=<serial>.
set -eu
MODE=${1:-status}
ROOT=$(cd "$(dirname "$0")" && pwd)
BUNDLE="$ROOT/modem"
REMOTE=/tmp/rm551e-ippt-fix

command -v adb >/dev/null || { echo "adb not found (brew install android-platform-tools)" >&2; exit 1; }

export ADB_LIBUSB=0
adb kill-server >/dev/null 2>&1 || true
adb start-server >/dev/null 2>&1
SERIAL=${ADB_SERIAL:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}
[ -n "$SERIAL" ] || { echo "no ADB device (modem ADB enabled? another app holding the USB device?)" >&2; exit 1; }

adb -s "$SERIAL" shell "rm -rf $REMOTE && mkdir -p $REMOTE" >/dev/null
adb -s "$SERIAL" push "$BUNDLE"/install.sh "$BUNDLE"/0[0-9]-* "$REMOTE/" >/dev/null 2>&1
adb -s "$SERIAL" shell "sh $REMOTE/install.sh $MODE"
