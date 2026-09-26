# rm551e-fix

Fix for Quectel RM551E-GL (SDX75, OpenWrt 23.05.4, R02A02) IP passthrough (IPPT) losing
downlink traffic after a modem restart or eSIM switch.

## The bug

`setup_lan_ippt` (`/etc/data/ippt.sh`) only installs the LAN-side host route
(`<PUBLIC_IP> dev br-lanN table custom_bind_<profile>`, plus the table-301 route) if the VLAN
bridge already exists. When the PDN comes up before the bridge, that step is skipped and never
re-run. The host still gets its public IP over DHCP and uplink works, but every downlink packet
is routed back out `rmnet_dataN` (`ip route get <ip> iif rmnet_dataN` → `cache <redirect>`).

## The fix

`modem/02-ippt-lan-resync` is a hotplug hook (`/etc/hotplug.d/iface/`) that restores any missing
host routes for every profile with active IPPT on each ifup/ifupdate. It is idempotent, and it
only touches QCMAP's own routing tables. It does not modify any Quectel files.

## Layout

| Path | Runs on | Purpose |
|---|---|---|
| `modem-ippt-fix.sh` | Mac | Pushes `modem/` over ADB and runs `install.sh` |
| `modem/install.sh` | modem | status / install / uninstall / dry-run |
| `modem/02-ippt-lan-resync` | modem | the hotplug hook itself |

## Usage

```sh
./modem-ippt-fix.sh status     # default: hook installed? host routes present?
./modem-ippt-fix.sh dry-run
./modem-ippt-fix.sh install    # install/update the hook and apply it once now
./modem-ippt-fix.sh uninstall
```

- Requires `adb` (`brew install android-platform-tools`).
- The modem's ADB is on USB interface 5. macOS adb only sees it with `ADB_LIBUSB=0`, which the script sets.
- Quit any app that holds the modem's USB device exclusively (for example, one talking AT over USB). While it runs, adb cannot reach the ADB interface.
- To pick a device, set `ADB_SERIAL=<serial>`.
- **Re-run `install` after every firmware upgrade**, because an upgrade can replace `/etc`.

Manual one-off workaround (lost on restart):

```sh
adb shell ip route add <pdn-ip> dev br-lan2 table custom_bind_2
```
