# rm551e-fix

Fixes for three Quectel RM551E-GL (SDX75, OpenWrt 23.05.4, R02A02) bugs that break the host's
connectivity after a modem restart, an eSIM switch or a USB re-enumeration:

1. **IPPT loses downlink** (`02-ippt-lan-resync`).
2. **odhcpd gets stuck, so the host has no IPv6** (`03-odhcpd-watchdog`).
3. **The modem's own DNS breaks behind a passthrough connection** (`04-ippt-dns-routes`).

## Bug 1: IPPT host route missing

`setup_lan_ippt` (`/etc/data/ippt.sh`) only installs the LAN-side host route
(`<PUBLIC_IP> dev br-lanN table custom_bind_<profile>`, plus the table-301 route) if the VLAN
bridge already exists. When the PDN comes up before the bridge, that step is skipped and never
re-run. The host still gets its public IP over DHCP and uplink works, but every downlink packet
is routed back out `rmnet_dataN` (`ip route get <ip> iif rmnet_dataN` → `cache <redirect>`).

### Fix

`modem/02-ippt-lan-resync` is a hotplug hook (`/etc/hotplug.d/iface/`) that restores any missing
host routes for every profile with active IPPT on each ifup/ifupdate. It is idempotent, and it
only touches QCMAP's own routing tables. It does not modify any Quectel files.

## Bug 2: odhcpd stuck after a USB re-enumeration

The modem re-enumerates its USB functions **whenever IP passthrough starts or stops**: when a
PDN with IPPT comes up (e.g. an eSIM switch to a profile whose passthrough PDN is IPv4), and when
one goes away (switching back). It happens with a REFRESH switch or an `AT+CFUN=0/1` alike.
Profiles whose PDNs don't use passthrough never trigger it. The kernel log shows why:

```
QCMAP:WAN connected v4 on sub id:0profile:<n>      ← the passthrough PDN comes up
   ~8 s
QCMAP: LINK_DOWN message posted                    ← QCMAP bounces the ECM link so the host
   ~3 s                                               re-DHCPs for the public address
android_work: sent uevent USB_STATE=DISCONNECTED   ← with ECM over IPA, the bounce becomes
ECM_IPA was destroyed                                 a full USB re-enumeration
```

Leaving passthrough disconnects the same way, a few seconds after the switch. The OS doesn't
reboot. QCMAP rebuilds `ecm0` (and the bridges, in order: `ecm0`, `br-lan`, `br-lan2`,
`ecm0.2`) and restarts `dnsmasq` for each LAN, but not `odhcpd`. Sometimes (once in 12
re-enumerations in one day of testing) `odhcpd` ends up in a busy loop:

- It uses a full CPU core (load average ~2.5–2.9).
- `ubus call dhcp …` times out.
- It stops sending router advertisements for `lan` and `lan2` (`dhcp.lan.ra` and
  `dhcp.lan2.ra` are `server`).

The host then has only link-local IPv6 on the internet interface and on the IMS VLAN
(`ndp -r` lists no router for them), although the PDNs, bridges and routes on the modem
are all fine. `/etc/init.d/odhcpd restart` fixes it at once.

### Fix

`modem/03-odhcpd-watchdog` goes into both `/etc/hotplug.d/iface/` and `/etc/hotplug.d/net/`:

- **`ecm0` added** (`hotplug.d/net`): that's a USB re-enumeration. The hook waits for both
  bridges (up to 30 s), waits 3 s more, then **always restarts `odhcpd`**, and checks it
  once more 30 s later. QCMAP's ordinary `ecm0` down/up toggles don't recreate the device,
  so they don't trigger it.
- **Any other LAN event** (a `lan*` ifup/ifupdate, `br-lan*` added): the hook checks after
  10 s and again 30 s later. If `odhcpd` doesn't answer `ubus call dhcp ipv6leases` twice in
  a row, it restarts it. If `odhcpd` isn't running although enabled, it starts it.

- A lock in `/tmp` makes one re-enumeration's burst of events check only once.
- Log lines (`odhcpd-watchdog: …`) go to the kernel log (`dmesg`).
- There's no cron on the modem, so a spin that starts without any of these events isn't
  caught. `status` shows it.

## Bug 3: DNS routes hijacked by a passthrough connection

For every connection that comes up, `/lib/netifd/rmnet.script` calls `util_add_dnsv4`
(`/etc/data/lanUtils.sh`). That asks netifd for a /32 host route to each of that
connection's DNS servers, via its `rmnet` device (`proto_add_ipv4_route "$dns" 32`).
netifd puts an interface's routes in its own table if it has an `ip4table`, otherwise in
**main**.

QCMAP gives a passthrough connection its own table (`custom_bind_<profile>`) and sets it as
`ip6table` for the IPv6 side (`ubus call network.interface.<wan>_v6 status` → `ip6table`),
but never as `ip4table`. So the passthrough connection's IPv4 DNS routes land in main.

That's harmless until two connections are given **the same IPv4 DNS servers**. Then the one
that comes up second, typically the passthrough one, replaces the internet connection's
routes (which one wins depends on the order they come up in, so it breaks only sometimes):

```
10.x.x.x dev rmnet_data2 proto static scope link      ← the passthrough connection
```

With passthrough the modem has only a placeholder address on that connection (`169.254.x`;
the real one belongs to the host). The modem's DNS queries leave with a source the network
doesn't know and get no answer:

- `dnsmasq` has no working upstream, and `dig @<modem>` from the LAN times out;
- internet by IP still works;
- deleting the two routes fixes it until the connection comes up again (a radio restart
  re-adds them).

### Fix

`modem/04-ippt-dns-routes` (`/etc/hotplug.d/iface/`) runs 3 s after a connection comes up.
For each profile with active IPPT (its `rmnet` found from QCMAP's rule
`iif rmnet_dataN lookup custom_bind_<p>`), each main-table route to one of that connection's
IPv4 DNS servers via its `rmnet` is:

- **kept** for the passthrough connection in `custom_bind_<profile>`;
- **re-pointed** in main at the non-passthrough connection that lists the same server. That
  restores its own netifd route, i.e. the layout QCMAP already uses for IPv6.
- If no other connection lists the server, it's just removed from main, and the default route
  carries the queries.

One run at a time: a connection coming up fires several events together. A run that finds
the lock taken leaves a note and exits, and the running one repeats, so a route QCMAP
re-adds after a check is still caught. A lock older than 60 s (a run that died) is taken
over.

IPv6 needs nothing: QCMAP sets `ip6table` there. Every change is logged to `dmesg`
(`ippt-dns-routes: …`), and `status` reports where each passthrough connection's DNS
servers route.

## Known limitation (not fixed): a passthrough address ending in .255 or .0

A mobile network assigns a PDN a /32, so an address like `x.x.x.255` is perfectly valid. But
QCMAP's passthrough treats the host LAN as a /24 (`NETMASK=255.255.255.0` in
`/tmp/ipv4config<profile>`), where `.255` is the broadcast address:

- the gateway it derives lands in the next /24 (e.g. `x.x.(y+1).0`);
- no DHCP reservation is created for the host;
- `dnsmasq` logs `no address range available for DHCP request via br-lanN`;
- the host falls back to a self-assigned `169.254.x` address.

The workaround is to re-establish the PDN (e.g. `AT+CFUN=0` then `AT+CFUN=1`) for a new address.
About 1 PDN setup in 128 gets such an address.

## Layout

| Path | Runs on | Purpose |
|---|---|---|
| `modem-ippt-fix.sh` | Mac | Pushes `modem/` over ADB and runs `install.sh` |
| `modem/install.sh` | modem | status / install / uninstall / dry-run |
| `modem/02-ippt-lan-resync` | modem | bug 1 hook (`hotplug.d/iface`) |
| `modem/03-odhcpd-watchdog` | modem | bug 2 hook (`hotplug.d/iface` and `hotplug.d/net`) |
| `modem/04-ippt-dns-routes` | modem | bug 3 hook (`hotplug.d/iface`) |

## Usage

```sh
./modem-ippt-fix.sh status     # default: hooks installed? host routes? odhcpd healthy? DNS routes?
./modem-ippt-fix.sh dry-run
./modem-ippt-fix.sh install    # install/update the hooks and apply each once now
./modem-ippt-fix.sh uninstall
```

- Requires `adb` (`brew install android-platform-tools`).
- The modem's ADB is on USB interface 5. macOS adb only sees it with `ADB_LIBUSB=0`, which the script sets.
- If adb can't find the device, quit any app that holds the modem's USB device exclusively
  (for example, one talking AT over USB).
- To pick a device, set `ADB_SERIAL=<serial>`.
- **Re-run `install` after every firmware upgrade**, because an upgrade can replace `/etc`.
  The hooks live in `/etc/hotplug.d/`, so they survive ordinary restarts.

Manual one-off workarounds (lost on restart):

```sh
adb shell ip route add <pdn-ip> dev br-lan2 table custom_bind_2   # bug 1
adb shell /etc/init.d/odhcpd restart                              # bug 2
adb shell ip route del <dns-ip> dev <passthrough rmnet>           # bug 3, per DNS server
```
