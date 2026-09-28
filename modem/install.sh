#!/bin/sh
# install.sh — runs ON THE MODEM (Quectel RM551E-GL, OpenWrt/QCMAP). Installs the fix hooks:
#   02-ippt-lan-resync   /etc/hotplug.d/iface/          IPPT LAN host routes (see the file)
#   03-odhcpd-watchdog   /etc/hotplug.d/iface/ and net/ odhcpd stuck after USB re-enumeration
#   04-ippt-dns-routes   /etc/hotplug.d/iface/          DNS routes hijacked by a passthrough PDN
#
#   sh install.sh status      are the hooks installed and current? IPPT routes? odhcpd healthy?
#   sh install.sh install     install / update the hooks, then apply each once now
#   sh install.sh uninstall   remove the hooks (routes already added stay until the next restart)
#   sh install.sh dry-run     show what install would do
#
# Driven from the Mac by ../modem-ippt-fix.sh, which pushes this folder to /tmp and
# re-applies it after a firmware upgrade (a firmware image can replace /etc).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-status}
# hook:hotplug-subsystem pairs; a hook may go into several subsystems.
HOOKS="02-ippt-lan-resync:iface 03-odhcpd-watchdog:iface 03-odhcpd-watchdog:net 04-ippt-dns-routes:iface"

say() { printf '%s\n' "$*"; }
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Platform check: QCMAP with IPPT support, not a specific firmware string (the hooks only read
# QCMAP state, add missing routes and restart odhcpd, so they're safe on any build with these).
platform() {
	[ -f /etc/data/ippt.sh ] && [ -f /etc/data/lanUtils.sh ] && [ -d /etc/hotplug.d/iface ] &&
		[ -d /etc/hotplug.d/net ] && uci -q get qcmap_lan.@no_of_configs[0].no_of_profiles >/dev/null
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

odhcpd_report() {
	local pid out
	pid=$(pidof odhcpd)
	if [ -z "$pid" ]; then say "  odhcpd: NOT running (no IPv6 RAs on the LAN)"; return; fi
	out=$(ubus -t 3 call dhcp ipv6leases 2>&1 >/dev/null)
	case "$out" in
	*"timed out"*) say "  odhcpd: pid $pid, NOT answering ubus — stuck (no IPv6 RAs on the LAN)" ;;
	*) say "  odhcpd: pid $pid, answering" ;;
	esac
}

# For each passthrough connection: where main sends its IPv4 DNS servers. Into the
# passthrough connection itself is the broken state (the modem has no real address there).
dns_report() {
	local line rmnet p i dns via
	ip rule | sed -n 's/.*from all iif \(rmnet_data[0-9]*\) lookup custom_bind_\([0-9]*\)$/\1 \2/p' | sort -u |
	while read -r rmnet p; do
		for i in $(ubus list 'network.interface.*' 2>/dev/null | cut -d. -f3); do
			[ "$(ubus call "network.interface.$i" status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)" = "$rmnet" ] || continue
			for dns in $(ubus call "network.interface.$i" status | jsonfilter -e '@["dns-server"][*]' 2>/dev/null | grep -v ':'); do
				via=$(ip route get "$dns" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
				if [ "$via" = "$rmnet" ]; then
					say "  DNS $dns (profile $p): main routes it into the passthrough connection $rmnet — BROKEN (run install)"
				else
					say "  DNS $dns (profile $p): via ${via:-?}, ok"
				fi
			done
		done
	done
}

report() {
	routes_report
	odhcpd_report
	dns_report
}

say "== RM551E fix hooks: $MODE"
platform || { say "  not a QCMAP/IPPT modem (missing ippt.sh, lanUtils.sh, hotplug dirs or qcmap_lan) — nothing done"; exit 1; }

for pair in $HOOKS; do
	[ -f "$HERE/${pair%%:*}" ] || { say "  $HERE/${pair%%:*} missing from this bundle"; exit 1; }
done

case "$MODE" in
status|dry-run)
	for pair in $HOOKS; do
		name=${pair%%:*}; dst=/etc/hotplug.d/${pair##*:}/$name
		if [ -f "$dst" ] && [ "$(md5 "$dst")" = "$(md5 "$HERE/$name")" ]; then
			say "  $dst: installed, current"
		elif [ -f "$dst" ]; then
			say "  $dst: installed, DIFFERENT from this bundle$([ "$MODE" = dry-run ] && echo " — would update" || echo " (run install)")"
		else
			say "  $dst: NOT installed$([ "$MODE" = dry-run ] && echo " — would install" || echo " (a firmware upgrade removes it: run install)")"
		fi
	done
	report
	;;
install)
	for pair in $HOOKS; do
		name=${pair%%:*}; dst=/etc/hotplug.d/${pair##*:}/$name
		cp "$HERE/$name" "$dst.tmp" && chmod 755 "$dst.tmp" && mv "$dst.tmp" "$dst" || { say "  copy to $dst failed"; exit 1; }
		[ "$(md5 "$dst")" = "$(md5 "$HERE/$name")" ] || { say "  verify of $dst failed"; exit 1; }
		say "  installed $dst"
	done
	# Apply now, for the state the modem is in already.
	ACTION=ifupdate IPPT_LAN_RESYNC_NOW=1 sh /etc/hotplug.d/iface/02-ippt-lan-resync
	ACTION=ifupdate INTERFACE=lan ODHCPD_WATCHDOG_NOW=1 sh /etc/hotplug.d/iface/03-odhcpd-watchdog
	ACTION=ifupdate IPPT_DNS_ROUTES_NOW=1 sh /etc/hotplug.d/iface/04-ippt-dns-routes
	report
	;;
uninstall)
	for pair in $HOOKS; do
		dst=/etc/hotplug.d/${pair##*:}/${pair%%:*}
		rm -f "$dst" && say "  removed $dst"
	done
	report
	;;
*)
	say "  usage: sh install.sh [status|install|uninstall|dry-run]"; exit 2
	;;
esac
