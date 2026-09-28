# rm551e-fix

Fixes for two Quectel RM551E-GL (SDX75, OpenWrt 23.05.4, R02A02) bugs that break the host's
connectivity after a modem restart, an eSIM switch or a USB re-enumeration:

1. **IPPT loses downlink** (`02-ippt-lan-resync`).
2. **odhcpd gets stuck, so the host has no IPv6** (`03-odhcpd-watchdog`).

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

The modem sometimes re-enumerates its USB functions: after eSIM profile switches
(with a REFRESH *or* `AT+CFUN=0/1`) and after a plain `AT+CFUN=0/1`, but not every time. The
trigger is unknown. The OS doesn't reboot;
the kernel log shows `android_work: sent uevent USB_STATE=DISCONNECTED`, then
`ECM_IPA was destroyed`, then `j_gadget` reassigning functions. QCMAP then rebuilds
`ecm0` and restarts `dnsmasq` for each LAN, but not `odhcpd`. Sometimes (after one of 12
re-enumerations on 2026-09-28) `odhcpd` ends up in a busy loop:

- It uses a full CPU core (load average ~2.5–2.9).
- `ubus call dhcp …` times out.
- It stops sending router advertisements for `lan` and `lan2` (`dhcp.lan.ra` and
  `dhcp.lan2.ra` are `server`).

The host then has only link-local IPv6 on the internet interface and on the IMS VLAN
(`ndp -r` lists no router for them), although the PDNs, bridges and routes on the modem
are all fine. `/etc/init.d/odhcpd restart` fixes it at once.

### Fix

`modem/03-odhcpd-watchdog` goes into both `/etc/hotplug.d/iface/` and `/etc/hotplug.d/net/`:

- **`ecm0` added** (`hotplug.d/net`): that's a USB re-enumeration. The LAN side is
  recreated in order: `ecm0`, `br-lan`, `br-lan2`, `ecm0.2`. The hook waits for both
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

## Layout

| Path | Runs on | Purpose |
|---|---|---|
| `modem-ippt-fix.sh` | Mac | Pushes `modem/` over ADB and runs `install.sh` |
| `modem/install.sh` | modem | status / install / uninstall / dry-run |
| `modem/02-ippt-lan-resync` | modem | bug 1 hook (`hotplug.d/iface`) |
| `modem/03-odhcpd-watchdog` | modem | bug 2 hook (`hotplug.d/iface` and `hotplug.d/net`) |

## Usage

```sh
./modem-ippt-fix.sh status     # default: hooks installed? host routes present? odhcpd healthy?
./modem-ippt-fix.sh dry-run
./modem-ippt-fix.sh install    # install/update the hooks and apply each once now
./modem-ippt-fix.sh uninstall
```

- Requires `adb` (`brew install android-platform-tools`).
- The modem's ADB is on USB interface 5. macOS adb only sees it with `ADB_LIBUSB=0`, which the script sets.
- Quit any app that holds the modem's USB device exclusively (for example, one talking AT over USB). While it runs, adb cannot reach the ADB interface.
- To pick a device, set `ADB_SERIAL=<serial>`.
- **Re-run `install` after every firmware upgrade**, because an upgrade can replace `/etc`.

Manual one-off workarounds (lost on restart):

```sh
adb shell ip route add <pdn-ip> dev br-lan2 table custom_bind_2   # bug 1
adb shell /etc/init.d/odhcpd restart                              # bug 2
```
