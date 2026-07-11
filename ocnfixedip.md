# OCN Fixed IP (IPoE) Notes (OPNsense)

This document describes the current design and behavior of the OPNsense plugin in this repository.

Official service page (NTT Docomo Business):

- https://www.ntt.com/business/services/network/internet-connect/ocn-business/ftth.html

- Product scope: **OCN Fixed IP (IPoE) only**
- Tunnel mode: **IPv4 over IPv6 (IPIP) on `gif0`**
- Peer IPv4: fixed to `192.0.0.1`

---

## 1. Functional Scope

Implemented:

- OCN fixed-IP tunnel creation/teardown
- WAN IPv6-based local tunnel IPv6 auto-calculation
- Prefix update API call on apply/start and WAN IPv6 renewal
- Best-effort auto-assignment of `gif0` to `TUNNEL` (optX) on first configure
- OPNsense MVC UI + API + dashboard widget

---

## 2. Tunnel Model

### 2.1 Interface and addresses

- Interface: `gif0`
- Tunnel transport: IPv6
- Inside IPv4 point-to-point:
  - local: `Fixed IPv4 Range Start`
  - peer: `192.0.0.1`

### 2.2 Local tunnel IPv6 auto-calculation

MTU reference (NTT Docomo Business FAQ):

- https://support.ntt.com/ocn-business/faq/detail/pid2300001n9t/


Formula:

`local_tunnel_v6 = WAN_global_v6_/64 + (fixed_ipv4 << 24)`

WAN global IPv6 detection uses a short retry window to absorb DHCPv6 renewal timing races.

Example:

- WAN prefix: `2001:db8:1234:5678::/64`
- Fixed IPv4 range start: `203.0.113.96`
- Result: `2001:db8:1234:5678:cb00:7160:0:0`

---

## 3. Prefix Update Behavior

Update endpoint is called when:

1. service starts/restarts
2. settings are applied
3. WAN IPv6 renewal path runs (`rc.newwanipv6` -> `newwanip(..., inet6)`)

Credentials are passed via a temporary `netrc` file when invoking `curl`.

The plugin appends `hostname=` if missing in the configured URL and uses configured auth credentials.

Typical responses:

- `good ...` : update accepted
- `nochg ...` : no change needed
- `nohost` : hostname token mismatch likely

---

## 4. Hooking Model on OPNsense

`plugins.inc.d/ocnfixedip.inc` registers:

- `newwanip => ocnfixedip_configure_do:3`

Runtime behavior:

- called for both `inet` and `inet6` paths by OPNsense
- plugin explicitly skips non-`inet6` triggers
- effective reconfiguration target is WAN IPv6 renewal events
- interface hook does not register a virtual interface (to avoid assignment visibility conflicts)

---

## 5. Routing Behavior

- Attempts to set IPv4 default route via `192.0.0.1`
- If `route change` fails, falls back to `route delete` + `route add`
- Logs warning when convergence is not immediate

---

## 6. UI Model

Main fields:

- Enable
- WAN Interface
- BR / AFTR IPv6 Endpoint
- Fixed IPv4 Range Start
- MTU
- Prefix Update URL
- Prefix Update Hostname
- Auth User ID
- Auth Password

Removed from UI:

- Local Tunnel IPv6 input
- Tunnel Peer IPv4 input
- NAT-related options
- Prefix Update Interval

---

## 7. Repository Layout

Plugin directory:

- `os-ocnfixedip/`

Important files:

- `os-ocnfixedip/src/etc/inc/plugins.inc.d/ocnfixedip.inc`
- `os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/configure.sh`
- `os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/lib.sh`
- `os-ocnfixedip/src/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms/general.xml`

---

## 8. Operational Verification Checklist

1. `rc.newwanipv6` log includes:
   - `execute task : ocnfixedip_configure_do(,[wan],inet6)`
2. Plugin log includes:
   - `Auto-calculated local tunnel IPv6: ...`
   - (when prefix changed) `Removed stale WAN /128 alias ...`
   - `Added WAN /128 alias ...`
   - `Prefix update response: good ...` or `nochg ...`
   - `OCN Fixed IP (IPoE) tunnel configuration complete`
3. Default IPv4 route points to `192.0.0.1`

Useful command:

```sh
tail -F /var/log/system/latest.log | grep -E 'rc.newwanipv6|ocnfixedip'
```

If convergence is delayed right after prefix renewal:

```sh
configctl ocnfixedip restart
```

---

## 9. Naming

For this fork, preferred naming is:

- repository: `os-ocnfixedip`
- plugin directory: `os-ocnfixedip`
- UI name: `OCN Fixed IP (IPoE)`
