# OCN Fixed IP (IPoE) Plugin for OPNsense

This is an OPNsense plugin dedicated to **OCN Fixed IP (IPoE)** (IPv4 over IPv6 / IPIP).
It is focused on OCN fixed IP operation only.

> [!IMPORTANT]
> This is a community plugin and is not an official NTT Docomo Business or OPNsense product.
> Keep console or another management path available while changing the default IPv4 route.

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Scope](#scope)
- [Requirements](#requirements)
- [Before You Install](#before-you-install)
- [Installation](#installation)
- [Initial Configuration](#initial-configuration)
- [Post-install Required Setup](#post-install-required-setup-important)
- [GUI Settings](#gui-settings-interfaces--ocn-fixed-ip-ipoe)
- [Runtime Behavior](#runtime-behavior)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)
- [Known Limitations](#known-limitations)
- [Development Notes](#development-notes)

---

## Overview

This plugin configures a `gif0` (IPv4-in-IPv6) tunnel on OPNsense and automates OCN fixed-IP routing and prefix update handling.

Main behavior:

- Builds an OCN fixed-IP IPIP tunnel on `gif0`
- Uses a fixed `Tunnel Peer IPv4` value: `192.0.0.1`
- Auto-calculates `Local Tunnel IPv6`
  - Uses WAN global IPv6 `/56`
  - Builds interface ID from the fixed IPv4 range start
- Runs Prefix Update (OCN API)
  - On startup / apply / WAN IPv6 renewal
- Reconfigures through `rc.newwanipv6` flow (runs only on `inet6` trigger)
- Retries WAN global IPv6 detection briefly to avoid DHCPv6 renewal timing races
- Cleans up previously managed WAN `/128` tunnel alias when prefix changes
- Uses temporary `netrc` file for prefix update authentication (avoids exposing credentials in process args)

## How It Works

```text
LAN / VLAN clients
       |
       | IPv4 + outbound NAT
       v
OPNsense gif0 (local fixed IPv4 -> 192.0.0.1)
       |
       | IPv4-in-IPv6 (IPIP)
       v
OCN BR IPv6 endpoint
       |
       v
IPv4 Internet
```

The WAN continues to provide native IPv6. The plugin derives the local IPv6 tunnel
endpoint from the current WAN `/56` base and the OCN fixed IPv4 range start. IPv4
traffic is sent through `gif0`; IPv6 traffic is not translated by this plugin.

The plugin is responsible for the tunnel and its immediate default route. OPNsense
gateway monitoring, firewall policy, outbound NAT, and MSS normalization remain
administrator-managed settings.

---

## Scope

- Supported: **OCN Fixed IP (IPoE)**

Official service page (NTT Docomo Business):

- https://www.ntt.com/business/services/network/internet-connect/ocn-business/ftth.html

---

## Requirements

1. OPNsense 26.1+
2. WAN running on IPoE IPv6
3. OCN fixed-IP contract values available (update URL, auth credentials, hostname token)
4. `python3`, `curl`, `xmllint`, and standard FreeBSD networking tools on OPNsense
5. Administrative shell and Web UI access to OPNsense

Typical WAN settings:

- IPv4: DHCP (environment-dependent) or None
- IPv6: DHCPv6

### NTT Prefix Delegation (Hikari Cross)

| Plan | Typical PD Size | Notes |
|---|---|---|
| Hikari Cross (10G) | `/56` | Contract/base delegation |
| Hikari Cross (10G) with HGW | `/60` | Downstream router may receive/use `/60` behind HGW |

- This plugin's tunnel local IPv6 calculation is normalized to `/56` base.

## Before You Install

Collect the following values from the OCN service activation documents or customer
portal before starting:

| Value | Example | Notes |
|---|---|---|
| BR / AFTR IPv6 endpoint | `2001:380:a120::a` | Use the value assigned for the service |
| Fixed IPv4 range start | `203.0.113.96` | First address of the assigned block, not a host address chosen from it |
| Prefix update URL | `http://ipoe-static.ocn.ad.jp/nic/update` | Use the OCN-provided URL |
| Prefix update hostname | `ieabc123def456` | Token passed as the `hostname` query parameter |
| Authentication user ID | Contract-specific | Used only for the prefix update request |
| Authentication password | Contract-specific | Stored in the OPNsense configuration |

Also record the current OPNsense IPv4 default route and export an OPNsense
configuration backup. Applying this plugin changes the system IPv4 default route to
the tunnel peer.

---

## Installation

```sh
# on your development machine
git clone https://github.com/unchained-llc/os-ocnfixedip
cd os-ocnfixedip
scp -r ./os-ocnfixedip root@<opnsense-host>:./

# on OPNsense
sh /root/os-ocnfixedip/install.sh
```

The installer copies the MVC, configd, runtime script, plugin hook, and dashboard
widget files into the local OPNsense installation. It then refreshes OPNsense plugin
metadata, restarts `configd`, clears UI caches, and pre-creates `gif0` when possible.

After installation, log out of the Web UI and log back in so the new menu and ACL
entries are loaded.

## Initial Configuration

1. Open **Interfaces > OCN Fixed IP (IPoE) > Settings**.
2. Select the WAN interface that receives native IPv6 or DHCPv6-PD.
3. Enter the OCN BR IPv6 endpoint and fixed IPv4 range start.
4. Enter the prefix update URL, hostname token, user ID, and password.
5. Leave MTU at `1460` unless OCN or your line conditions require another value.
6. Enable the plugin and click **Apply**.
7. Wait several seconds, then confirm that the status panel reports **Connected**.

Applying the settings creates the tunnel, but LAN IPv4 forwarding is not complete
until the gateway, outbound NAT, and MSS normalization steps below are configured.

---

## Post-install required setup (important)

After enabling/applying the plugin settings, complete the following OPNsense steps or LAN clients will not have IPv4 Internet access:

1. Confirm tunnel interface assignment for `gif0` in **Interfaces > Assignments** (plugin tries to auto-assign as `TUNNEL`)
2. Create/select IPv4 gateway on that assigned tunnel interface and mark it as **Upstream** in **System > Gateways > Configuration**
3. Configure outbound NAT for LAN/internal networks to the tunnel interface in **Firewall > NAT > Outbound**
4. Add a scrub normalization rule for tunnel egress MSS in **Firewall > Settings > Normalization**:
   - Interface: `TUNNEL` (your assigned `gif0` interface)
   - Direction: `Out`
   - Protocol: `TCP`
   - Source/Destination: `any`
   - Max MSS: `1420`
   - Example description: `OCN IPoE out`

Recommended order:

1. Configure and apply this plugin (creates/configures `gif0`)
2. Confirm `gif0` assignment (`TUNNEL`) was created (best-effort auto-assign)
3. Configure tunnel gateway as Upstream
4. Add outbound NAT rules
5. Add normalization rule (Max MSS `1420`) on tunnel `Out`

If auto-assignment did not happen, assign `gif0` manually in **Interfaces > Assignments** and apply once more.

### Suggested gateway configuration

- Interface: assigned `TUNNEL` interface
- Address family: IPv4
- Gateway address: `192.0.0.1`
- Upstream gateway: enabled
- Monitoring: configure according to your operational policy

Avoid defining two competing default IPv4 gateways unless you intentionally use an
OPNsense gateway group or policy routing.

### Suggested outbound NAT rule

Create rules for each internal IPv4 network that should use OCN Fixed IP:

- Interface: `TUNNEL`
- TCP/IP version: IPv4
- Source: LAN/VLAN network
- Translation / target: Interface address

Use Hybrid or Manual outbound NAT mode when you need explicit control. Confirm that
the resulting translation address is the assigned fixed IPv4 range start.

## GUI Settings (Interfaces > OCN Fixed IP (IPoE))

Current fields:

- **Enable**
  - Enables the plugin

- **WAN Interface**
  - WAN interface used as IPv6 prefix source

- **BR / AFTR IPv6 Endpoint**
  - Remote OCN BR IPv6 endpoint

- **Fixed IPv4 Range Start**
  - First address of your assigned fixed IPv4 block
  - Example: for `203.0.113.96/255.255.255.240`, use `203.0.113.96`

- **MTU** (Advanced)
  - Default: `1460`
  - MTU reference (NTT Docomo Business FAQ): https://support.ntt.com/ocn-business/faq/detail/pid2300001n9t/

- **Prefix Update URL**
  - Example: `http://ipoe-static.ocn.ad.jp/nic/update`

- **Prefix Update Hostname**
  - OCN hostname token (example: `ieabc123def456`)
  - If `hostname=` is missing in URL, the plugin appends it automatically

- **Auth User ID**
  - Prefix update authentication user

- **Auth Password**
  - Prefix update authentication password
  - Stored in `/conf/config.xml`; protect OPNsense backups accordingly

Removed fields/features:

- Local Tunnel IPv6 (now auto-calculated)
- Tunnel Peer IPv4 input (now fixed)
- NAT-related settings
- Prefix Update Interval

---

## Runtime Behavior

### Local Tunnel IPv6 auto-calculation

`local_tunnel_v6 = WAN_global_v6_/56 + (fixed_ipv4 << 24)`

Notes:

- This plugin intentionally normalizes to `/56` before embedding the IPv4-derived interface ID.
- In environments where WAN host address and delegated prefix differ (for example, HGW in front and delegated `/60` from an original `/56`), this keeps tunnel local IPv6 anchored to the `/56` base.

Example:

- WAN host IPv6: `2001:db8:1234:56f1::254`
- `/56` base used by plugin: `2001:db8:1234:5600::/56`
- Fixed IPv4 Range Start: `203.0.113.96`
- Calculated local tunnel IPv6: `2001:db8:1234:5600:cb:71:6000:0`

### Prefix Update trigger timing

- Service start / restart / apply
- WAN IPv6 renewal event (`newwanip(..., inet6)` path via `rc.newwanipv6`)

Repeated configure events within three seconds are ignored to reduce duplicate work
during configuration-save and WAN-renewal races.

### Routing

- Sets IPv4 default gateway to `192.0.0.1`
- If `route change` fails, falls back to `delete/add`

### Disable and stop behavior

Disabling the service destroys `gif0`. The IPv4 default route is removed only when it
currently uses `gif0`. OPNsense may then restore another configured gateway according
to its own gateway management state.

### Connectivity checks (status/diagnostics)

- BR reachability is checked with IPv6 ping to **BR / AFTR IPv6 Endpoint** (user-configured value)
- Internet reachability is checked with IPv4 ping to fixed destination `1.1.1.1` via tunnel source IPv4

---

## LAN IPv6 Prefix Tracking Recommendation (OPNsense 26.1+)

For LAN/VLAN IPv6 prefix tracking, prefer `Identity association` mode.

Recommended approach:

1. Set WAN to `DHCPv6` (PD enabled as required by your ISP)
2. For each LAN/VLAN interface, select `Identity association`
3. Set per-interface Prefix ID (for example `1`, `3`, `4`)
4. Set `Optional interface ID` to fix the host part

Concrete example:

- If you want LAN address `2001:db8:1234:5671::254`, set:
  - Prefix ID: `1` (so LAN prefix becomes `...:5671::/64`)
  - Optional interface ID: `254`
- Result on prefix `2001:db8:1234:5670::/60` is `2001:db8:1234:5671::254/64`

This provides PD follow-up on prefix changes while keeping consistent host IDs per interface.

## Log Checks

Key expected logs:

- `Auto-calculated local tunnel IPv6: ...`
- `Sending prefix update to ...`
- `Prefix update response: nochg ...` or `good ...`
- `OCN Fixed IP (IPoE) tunnel configuration complete`

Response meanings:

- `nochg`: Already up to date (normal)
- `good`: Update accepted (normal)
- `nohost`: Hostname token mismatch likely

## Verification

### Web UI

1. Open **Interfaces > OCN Fixed IP (IPoE)**.
2. Confirm **Status: Connected**.
3. Confirm Local IPv6, BR IPv6, Tunnel IPv4, and MTU match the expected values.
4. Open **Diagnostics** and review the tunnel, route, BR ping, and Internet ping.

### Shell

Run these commands from the OPNsense shell:

```sh
ifconfig gif0
route -n get default
configctl ocnfixedip status
configctl ocnfixedip diagnostics
```

Expected results:

- `gif0` exists and includes `UP` and `RUNNING`
- `tunnel inet6` shows the calculated local IPv6 and configured BR IPv6
- the tunnel IPv4 is paired with `192.0.0.1`
- the IPv4 default gateway is `192.0.0.1`
- BR IPv6 and `1.1.1.1` connectivity checks succeed

### Confirm the public IPv4 address

From a LAN client routed through the tunnel, query a trusted public-IP service and
confirm that the result belongs to the assigned OCN fixed IPv4 block. A successful
router-side ping alone does not verify LAN outbound NAT and firewall policy.

## Troubleshooting

### Status is "Not started" or `gif0` is missing

- Confirm **Enable** is selected and all required fields are saved.
- Run `configctl ocnfixedip restart`.
- Check `/var/log/system/latest.log` for `ocnfixedip` errors.
- Confirm the selected WAN interface maps to a real interface device.

### Local tunnel IPv6 cannot be calculated

- Confirm WAN has a non-link-local IPv6 address with `ifconfig`.
- Verify DHCPv6-PD/native IPv6 has completed before applying.
- Confirm `python3` is available.
- If renewal is still converging, wait several seconds and restart the service.

### `gif0` is up but there is no IPv4 Internet access

- Verify the default route points to `192.0.0.1`.
- Verify the TUNNEL gateway is marked **Upstream**.
- Check outbound NAT for every required LAN/VLAN network.
- Check firewall rules permit LAN IPv4 traffic.
- Add the TUNNEL outbound normalization rule with Max MSS `1420`.
- Use the Diagnostics page to distinguish BR reachability from Internet reachability.

### BR ping fails

- Recheck the BR IPv6 endpoint against the OCN contract information.
- Confirm native IPv6 routing works on WAN.
- Confirm the calculated local tunnel IPv6 is present as a `/128` WAN alias.
- Check upstream IPv6 firewall and routing policy.

### Prefix update returns `nohost`

The hostname token probably does not match the authentication account. Copy the
hostname exactly as issued by OCN and ensure an old `hostname=` value is not already
embedded in the configured URL.

### Prefix update returns neither `good` nor `nochg`

- Verify the URL, username, password, and hostname token.
- Confirm OPNsense can reach the update endpoint over IPv6.
- Inspect the complete `Prefix update response` log entry.
- Note that the current implementation logs the response but does not fail the whole
  configure operation based on the OCN response body.

### WAN prefix changed but the tunnel did not recover

The plugin normally runs through the `rc.newwanipv6` hook and replaces its previously
tracked WAN `/128` alias. If convergence is delayed, run:

```sh
configctl ocnfixedip restart
```

Then confirm the new calculated address and prefix update response in the system log.

---

## Performance

### User report (high-speed environment)

Environment:

- Proxmox `9.2.4`
- VM: `16 vCPU / 8GB RAM`
- Host CPU: `Ryzen 7 3700X`
- NIC: `Mellanox ConnectX-4 Lx 25GbE` (uplink to switch at `10GbE`)
- Measurement: `speedtest.net`

Results:

| Test | Result |
|---|---|
| speedtest.net Download | 8002 Mbps |
| speedtest.net Upload | 6998 Mbps |
| iperf3 8-stream download | 8.80 Gbps |
| iperf3 8-stream upload | 8.13 Gbps |
| ping 1.1.1.1 (16 samples) | avg 4.00 ms (min 3.667 / max 4.470) |

These results are a user report from one virtualized environment and are not a
performance guarantee. Throughput depends on CPU, NIC offload behavior, virtualization,
firewall rules, traffic shape, and the access network.

## Upgrade

To upgrade a manually installed copy:

```sh
# development machine
git pull
scp -r ./os-ocnfixedip root@<opnsense-host>:./

# OPNsense
sh /root/os-ocnfixedip/install.sh
```

The installer overwrites plugin program files but does not remove the existing
`//OPNsense/ocnfixedip` configuration from `/conf/config.xml`. Export a configuration
backup before upgrading and review release changes before applying them to a remote
router.

## Uninstall

```sh
sh /root/os-ocnfixedip/uninstall.sh
```

Uninstallation stops and removes the plugin files and destroys `gif0`. It deliberately
leaves the plugin configuration in `/conf/config.xml`, and it does not remove gateway,
outbound NAT, normalization, firewall, or interface-assignment configuration created
outside the plugin. Review and remove those entries manually when they are no longer
needed.

## Known Limitations

- OCN Fixed IP (IPoE) only; this is not a generic DS-Lite or MAP-E implementation.
- One hard-coded tunnel interface, `gif0`, and one fixed peer IPv4, `192.0.0.1`.
- The local tunnel address calculation intentionally assumes an OCN `/56` base.
- Applying the service directly changes the system IPv4 default route.
- Gateway, outbound NAT, firewall, and MSS normalization are not created automatically.
- WAN IPv6 selection uses the first non-link-local IPv6 found on the selected device.
- Prefix update results are logged but are not currently validated as success/failure.
- The installer is a local file-copy installer, not an OPNsense package repository.
- Automated tests and an OPNsense VM integration-test workflow are not included yet.

## Security Notes

- Prefix update credentials are stored in the OPNsense configuration and therefore
  may be present in exported backups.
- Runtime authentication uses a mode-`0600` temporary netrc file so credentials are
  not placed directly in the `curl` process arguments.
- The current request uses `curl -k`, which disables TLS certificate verification for
  HTTPS update URLs. Use only the endpoint provided by OCN and restrict administrative
  access to the router.
- Diagnostic output contains interface addresses and routing information; sanitize it
  before posting publicly.

---

## Development Notes

Main files:

- `os-ocnfixedip/src/etc/inc/plugins.inc.d/ocnfixedip.inc`
- `os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/configure.sh`
- `os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/lib.sh`
- `os-ocnfixedip/src/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms/general.xml`

Repository structure:

```text
os-ocnfixedip/
  install.sh                         Local/offline installer
  uninstall.sh                       Uninstaller
  src/etc/inc/plugins.inc.d/         OPNsense lifecycle hooks
  src/opnsense/service/conf/         configd actions
  src/opnsense/scripts/              Tunnel runtime and diagnostics
  src/opnsense/mvc/                  Model, API, forms, views, ACL, and menu
  src/opnsense/www/js/widgets/       Dashboard widget
```

There is currently no test harness. At minimum, changes should be checked with shell
syntax validation and then exercised on a disposable OPNsense VM for configure,
restart, IPv6 prefix renewal, disable, and uninstall paths.

---

## License

BSD 2-Clause
