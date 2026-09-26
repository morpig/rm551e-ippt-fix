#!/bin/sh
# install.sh — runs ON THE MODEM (Quectel RM551E-GL, OpenWrt/QCMAP). Installs the IPPT
# LAN-resync hotplug hook (02-ippt-lan-resync); see that file for the bug and the fix.
#
#   sh install.sh status      is the hook installed and current? are the IPPT host routes there?
#   sh install.sh install     install / update the hook, then run it once now
#   sh install.sh uninstall   remove the hook (routes it added stay until the next restart)
#   sh install.sh dry-run     show what install would do
#
# Driven from the Mac by ../modem-ippt-fix.sh, which pushes this folder to /tmp and
# re-applies it after a firmware upgrade (a firmware image can replace /etc).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK_NAME=02-ippt-lan-resync
SRC="$HERE/$HOOK_NAME"
DST="/etc/hotplug.d/iface/$HOOK_NAME"
MODE=${1:-status}

say() { printf '%s\n' "$*"; }
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Platform check: QCMAP with IPPT support, not a specific firmware string (the hook only reads
# QCMAP state and adds missing routes, so it's safe on any build with these pieces).
platform() {
	[ -f /etc/data/ippt.sh ] && [ -f /etc/data/lanUtils.sh ] && [ -d /etc/hotplug.d/iface ] &&
		uci -q get qcmap_lan.@no_of_configs[0].no_of_profiles >/dev/null
}

routes_report() {
	local n i p active ctx sec dev PUBLIC_IP ok301 okcb
	n=$(uci -q get qcmap_lan.@no_of_configs[0].no_of_profiles)
	i=0
	while [ "$i" -le "${n:-3}" ]; do
		p=$(uci -q get qcmap_lan.@profile[$i].profile_id)
		active=$(uci -q get qcmap_lan.@profile[$i].active_ippt)
		ctx=$(uci -q get qcmap_lan.@profile[$i].ippt_bridge_context)
		i=$((i + 1))
		[ -n "$p" ] && [ "$active" = 1 ] || continue
		[ "$ctx" = 0 ] && sec=lan || sec=lan$ctx
		dev=$(uci -q -P /var/state get network.$sec.ifname)
		PUBLIC_IP=
		[ -f "/tmp/ipv4config$p" ] && . "/tmp/ipv4config$p"
		okcb=missing; ok301=missing
		ip route show table "custom_bind_$p" 2>/dev/null | grep -q "^$PUBLIC_IP dev $dev " && okcb=ok
		ip route show table 301 2>/dev/null | grep -q "^$PUBLIC_IP dev $dev " && ok301=ok
		say "  profile $p: IPPT on $sec (${dev:-no bridge}), public ${PUBLIC_IP:-none}: custom_bind_$p $okcb, table 301 $ok301"
	done
}

say "== RM551E IPPT LAN-resync fix: $MODE"
platform || { say "  not a QCMAP/IPPT modem (missing /etc/data/ippt.sh, lanUtils.sh or qcmap_lan) — nothing done"; exit 1; }
[ -f "$SRC" ] || { say "  $SRC missing from this bundle"; exit 1; }

case "$MODE" in
status)
	if [ -f "$DST" ]; then
		[ "$(md5 "$DST")" = "$(md5 "$SRC")" ] && say "  hook: installed, current" || say "  hook: installed, DIFFERENT from this bundle (run install)"
	else
		say "  hook: NOT installed (a firmware upgrade removes it: run install)"
	fi
	routes_report
	;;
dry-run)
	if [ -f "$DST" ] && [ "$(md5 "$DST")" = "$(md5 "$SRC")" ]; then say "  would do nothing (already current)"
	else say "  would copy $HOOK_NAME to $DST (mode 755) and run it once"; fi
	routes_report
	;;
install)
	cp "$SRC" "$DST.tmp" && chmod 755 "$DST.tmp" && mv "$DST.tmp" "$DST" || { say "  copy failed"; exit 1; }
	[ "$(md5 "$DST")" = "$(md5 "$SRC")" ] || { say "  verify failed"; exit 1; }
	say "  hook: installed at $DST"
	# Apply now, for the state the modem is in already.
	ACTION=ifupdate IPPT_LAN_RESYNC_NOW=1 sh "$DST"
	routes_report
	;;
uninstall)
	rm -f "$DST" && say "  hook: removed"
	routes_report
	;;
*)
	say "  usage: sh install.sh [status|install|uninstall|dry-run]"; exit 2
	;;
esac
