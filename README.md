# OCN Fixed IP (IPoE) Plugin for OPNsense

This is an OPNsense plugin dedicated to **OCN Fixed IP (IPoE)** (IPv4 over IPv6 / IPIP).
It is focused on OCN fixed IP operation only.

---

## Overview

This plugin configures a `gif0` (IPv4-in-IPv6) tunnel on OPNsense and automates OCN fixed-IP routing and prefix update handling.

Main behavior:

- Builds an OCN fixed-IP IPIP tunnel on `gif0`
- Uses a fixed `Tunnel Peer IPv4` value: `192.0.0.1`
- Auto-calculates `Local Tunnel IPv6`
  - Uses WAN global IPv6 `/64`
  - Builds interface ID from the fixed IPv4 range start
- Runs Prefix Update (OCN API)
  - On startup / apply / WAN IPv6 renewal
- Reconfigures through `rc.newwanipv6` flow (runs only on `inet6` trigger)
- Retries WAN global IPv6 detection briefly to avoid DHCPv6 renewal timing races
- Cleans up previously managed WAN `/128` tunnel alias when prefix changes
- Uses temporary `netrc` file for prefix update authentication (avoids exposing credentials in process args)

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

Typical WAN settings:

- IPv4: DHCP (environment-dependent) or None
- IPv6: DHCPv6

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

Removed fields/features:

- Local Tunnel IPv6 (now auto-calculated)
- Tunnel Peer IPv4 input (now fixed)
- NAT-related settings
- Prefix Update Interval

---

## Runtime Behavior

### Local Tunnel IPv6 auto-calculation

`local_tunnel_v6 = WAN_global_v6_/64 + (fixed_ipv4 << 24)`

Example:

- WAN prefix: `2001:db8:1234:5678::/64`
- Fixed IPv4 Range Start: `203.0.113.96`
- Calculated local tunnel IPv6: `2001:db8:1234:5678:cb00:7160:0:0`

### Prefix Update trigger timing

- Service start / restart / apply
- WAN IPv6 renewal event (`newwanip(..., inet6)` path via `rc.newwanipv6`)

### Routing

- Sets IPv4 default gateway to `192.0.0.1`
- If `route change` fails, falls back to `delete/add`

### Connectivity checks (status/diagnostics)

- BR reachability is checked with IPv6 ping to **BR / AFTR IPv6 Endpoint** (user-configured value)
- Internet reachability is checked with IPv4 ping to fixed destination `1.1.1.1` via tunnel source IPv4

---

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

---

## Uninstall

```sh
sh /root/os-ocnfixedip/uninstall.sh
```

---

## Development Notes

Main files:

- `src/etc/inc/plugins.inc.d/ocnfixedip.inc`
- `src/opnsense/scripts/OPNsense/ocnfixedip/configure.sh`
- `src/opnsense/scripts/OPNsense/ocnfixedip/lib.sh`
- `src/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms/general.xml`

---

## License

BSD 2-Clause
