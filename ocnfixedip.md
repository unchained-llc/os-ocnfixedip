# OCN Fixed IP (IPoE) Notes (OPNsense)

This document describes the current design and behavior of the OPNsense plugin in this repository.

This is the implementation and operations reference. For installation and end-user
configuration, see [`README.md`](README.md).

> This is a community implementation, not an official NTT Docomo Business or
> OPNsense component.

## Table of Contents

1. [Functional Scope](#1-functional-scope)
2. [Tunnel Model](#2-tunnel-model)
3. [Prefix Update Behavior](#3-prefix-update-behavior)
4. [Hooking Model on OPNsense](#4-hooking-model-on-opnsense)
5. [Routing Behavior](#5-routing-behavior)
6. [UI Model](#6-ui-model)
7. [Repository Layout](#7-repository-layout)
8. [Operational Verification Checklist](#8-operational-verification-checklist)
9. [Naming](#9-naming)
10. [Configuration Model](#10-configuration-model)
11. [Configure Lifecycle](#11-configure-lifecycle)
12. [Runtime State and Idempotency](#12-runtime-state-and-idempotency)
13. [Service and API Surface](#13-service-and-api-surface)
14. [Status and Diagnostics](#14-status-and-diagnostics)
15. [Installation and Removal](#15-installation-and-removal)
16. [Failure Behavior](#16-failure-behavior)
17. [Security Considerations](#17-security-considerations)
18. [Known Limitations](#18-known-limitations)
19. [Development and Test Guidance](#19-development-and-test-guidance)

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

Not implemented by the plugin:

- OPNsense gateway object creation
- Outbound NAT rules
- Firewall allow rules
- MSS normalization rules
- Multi-WAN or gateway-group policy
- Generic DS-Lite, MAP-E, or non-OCN IPIP profiles

These boundaries are intentional in the current version. The plugin owns `gif0` and
the immediate tunnel configuration; the administrator owns policy and LAN forwarding.

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

`local_tunnel_v6 = WAN_global_v6_/56 + (fixed_ipv4 << 24)`

WAN global IPv6 detection uses a short retry window to absorb DHCPv6 renewal timing races.

Example:

- WAN prefix: `2001:db8:1234:5600::/56`
- Fixed IPv4 range start: `203.0.113.96`
- Result: `2001:db8:1234:5600:cb:71:6000:0`

The calculation is implemented with Python's `ipaddress` module:

1. Parse the selected WAN global IPv6 address.
2. Normalize it to a strict-false `/56` network.
3. Convert the configured fixed IPv4 address to a 32-bit integer.
4. Shift that integer left by 24 bits.
5. OR the value into the `/56` network address.

The selected WAN address is the first address reported by `ifconfig` that is neither
link-local (`fe80::/10`) nor loopback. The current implementation does not distinguish
stable, temporary, ULA, or multiple global addresses.

### 2.3 WAN `/128` alias

The calculated local tunnel IPv6 is added to the selected WAN device as a `/128`
alias. This makes the local endpoint explicitly usable during DHCPv6 renewal timing
windows where `gif0` might otherwise remain non-running.

The last managed address is stored in:

```text
/var/run/ocnfixedip_local_tunnel_v6
```

When the calculated address changes, configure removes the previously tracked alias
before adding the new one. Only the address recorded in this state file is considered
plugin-managed.

### 2.4 MTU and TCP behavior

- Default tunnel MTU: `1460`
- Allowed model range: `1280` through `9000`
- Runtime sets `net.inet.tcp.mss_ifmtu=1`
- Recommended outbound scrub Max MSS: `1420`

The scrub rule is not created by the plugin and must be configured on the assigned
TUNNEL interface.

---

## 3. Prefix Update Behavior

Update endpoint is called when:

1. service starts/restarts
2. settings are applied
3. WAN IPv6 renewal path runs (`rc.newwanipv6` -> `newwanip(..., inet6)`)

Credentials are passed via a temporary `netrc` file when invoking `curl`.

Typical responses:

- `good ...` : update accepted
- `nochg ...` : no change needed
- `nohost` : hostname token mismatch likely

Request behavior:

- Forces IPv6 transport with `curl -6`
- Uses `--connect-timeout 2` to avoid long hangs on unreachable endpoints
- Uses a temporary mode-`0600` netrc file
- Appends `hostname=` only when a hostname is configured and the URL does not already
  contain that parameter
- Accepts URLs that already contain other query parameters
- Logs the final URL and response body

Prefix update failure does not make `configure.sh` exit nonzero, but it is consumed by
status health logic through `/var/run/ocnfixedip_prefix_update_status`.

---

## 4. Hooking Model on OPNsense

`plugins.inc.d/ocnfixedip.inc` registers:

- `newwanip => ocnfixedip_configure_do:3`

Runtime behavior:

- called for both `inet` and `inet6` paths by OPNsense
- plugin explicitly skips non-`inet6` triggers
- effective reconfiguration target is WAN IPv6 renewal events
- interface hook does not register a virtual interface (to avoid assignment visibility conflicts)

### 4.1 Hook call shape

The callback signature is:

```php
ocnfixedip_configure_do($verbose = false, $interfaces = null, $family = null)
```

If `$family` is supplied and is not `inet6`, the callback logs a skip and returns.
If the plugin is disabled, it returns without invoking configd. The configd action is
therefore executed only for relevant IPv6 events while the model is enabled.

### 4.2 Interface assignment model

`ocnfixedip_interfaces()` deliberately returns an empty array. Instead, the configure
script performs best-effort assignment directly through OPNsense configuration APIs:

- Reuses an existing assignment whose device is `gif0`.
- Otherwise selects the first unused `optN` key.
- Creates it enabled with description `TUNNEL`.
- Writes the change through `write_config()`.

This avoids virtual-interface registration conflicts while keeping `gif0` visible in
the standard Interface Assignments workflow.

---

## 5. Routing Behavior

- Attempts to set IPv4 default route via `192.0.0.1`
- If `route change` fails, falls back to `route delete` + `route add`
- Logs warning when convergence is not immediate

The route operation is system-wide rather than policy-routed. On teardown, the default
route is deleted only when `route -n get default` reports `gif0` as its interface.
The plugin does not restore a saved previous gateway; OPNsense gateway management is
expected to converge afterward.

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

The main page polls status every five seconds and performs additional status refreshes
two and five seconds after Apply. The Diagnostics page runs immediately on load
(without a manual refresh button). All user-visible settings are backed by the MVC model.

---

## 7. Repository Layout

Plugin directory:

- `os-ocnfixedip/`

Important files:

- `os-ocnfixedip/src/etc/inc/plugins.inc.d/ocnfixedip.inc`
- `os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/configure.sh`
- `os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/lib.sh`
- `os-ocnfixedip/src/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/forms/general.xml`

Additional integration files:

- `os-ocnfixedip/src/opnsense/service/conf/actions.d/actions_ocnfixedip.conf`
- `os-ocnfixedip/src/opnsense/mvc/app/controllers/OPNsense/OCNFixedIP/Api/ServiceController.php`
- `os-ocnfixedip/src/opnsense/mvc/app/models/OPNsense/OCNFixedIP/OCNFixedIP.xml`
- `os-ocnfixedip/src/opnsense/www/js/widgets/OCNFixedIP.js`
- `os-ocnfixedip/Makefile`
- `os-ocnfixedip/tools/build-pkg.sh`

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

Additional inspection commands:

```sh
ifconfig gif0
route -n get default
configctl ocnfixedip status
configctl ocnfixedip diagnostics
cat /var/run/ocnfixedip_local_tunnel_v6
```

---

## 9. Naming

For this fork, preferred naming is:

- repository: `os-ocnfixedip`
- plugin directory: `os-ocnfixedip`
- UI name: `OCN Fixed IP (IPoE)`

Legacy `DSLite` files are removed by the installer. New code and documentation should
not reintroduce the former `dslite` namespace.

---

## 10. Configuration Model

The model mounts at:

```text
//OPNsense/ocnfixedip
```

Current model version: `2.0.0`.

| Key | Type | Required | Default / validation | Runtime variable |
|---|---|---:|---|---|
| `enabled` | Boolean | Yes | `0` | `OCNFIXEDIP_ENABLED` |
| `wan_interface` | Interface | Yes | Enabled/dynamic interfaces allowed | `WAN_INTERFACE` |
| `fixedip_aftr` | IPv6 address | Yes | No netmask | `FIXEDIP_AFTR` |
| `fixedip_v4` | IPv4 address | Yes | No netmask | `FIXEDIP_V4` |
| `mtu` | Integer | Yes | `1460`, range 1280–9000 | `MTU` |
| `fixedip_update_url` | URL | Yes | URL validation | `FIXEDIP_UPDATE_URL` |
| `fixedip_update_hostname` | Text | No | None | `FIXEDIP_UPDATE_HOSTNAME` |
| `fixedip_auth_user` | Text | Yes | None | `FIXEDIP_AUTH_USER` |
| `fixedip_auth_pass` | Text/password UI | No | None | `FIXEDIP_AUTH_PASS` |

Runtime scripts read values directly from `/conf/config.xml` using `xmllint`. The
shell layer also defines these constants:

```text
TUNNEL_IF=gif0
AFTR_V4_ADDRESS=192.0.0.1
```

The password is optional at model level because some deployments may use an empty
password, but an authentication user and update URL are required before configure
continues.

---

## 11. Configure Lifecycle

`configure.sh` performs the following ordered transaction-like sequence:

1. Load configuration values.
2. Check the three-second duplicate-trigger stamp.
3. If invoked as `restart`, run teardown first.
4. If disabled, run teardown and exit successfully.
5. Validate BR IPv6 and fixed IPv4 presence.
6. Retry WAN global IPv6 discovery up to six times at one-second intervals.
7. Calculate the local tunnel IPv6 from the WAN `/56` and fixed IPv4.
8. Resolve the logical WAN name to its underlying device.
9. Remove a stale previously managed `/128` alias when necessary.
10. Add the new local tunnel `/128` alias to WAN.
11. Validate prefix update URL and authentication user presence.
12. Create `gif0` if it does not exist.
13. Configure IPv6 tunnel endpoints.
14. Configure the IPv4 point-to-point addresses.
15. Apply MTU, enable TCP MSS-from-interface behavior, and bring `gif0` up.
16. Best-effort assign `gif0` as an enabled `TUNNEL` interface.
17. Change or create the IPv4 default route through `192.0.0.1`.
18. Verify the observed gateway and log a warning if it has not converged.
19. Perform the immediate OCN prefix update.
20. Log completion and exit.

This sequence is not rolled back atomically. A failure can leave earlier steps in
place—for example, a WAN alias may exist even if later tunnel creation fails.

---

## 12. Runtime State and Idempotency

Three small state mechanisms are used:

| Path | Purpose | Lifetime |
|---|---|---|
| `/tmp/ocnfixedip_configure.stamp` | Suppress configure triggers less than three seconds apart | Until reboot or manual cleanup |
| `/var/run/ocnfixedip_local_tunnel_v6` | Track the plugin-managed WAN `/128` alias | Until teardown/reboot |
| `/var/run/ocnfixedip_prefix_update_status` | Record latest prefix-update result for status health | Until reboot or next configure/diagnostics run |

The timestamp is a debounce mechanism, not a process lock. Two long-running configure
processes can overlap if the second starts more than three seconds after the first.

Most network operations are conditionally idempotent:

- Existing `gif0` is reused.
- Existing matching WAN alias is not added again.
- Existing `gif0` assignment is reused.
- Default route uses change-first, then delete/add fallback.

Teardown destroys `gif0` and removes its state file. In the current implementation,
teardown does not remove the actual WAN `/128` alias before deleting the state file.

---

## 13. Service and API Surface

### 13.1 configd actions

| Action | Command | Output type |
|---|---|---|
| `ocnfixedip configure` | `configure.sh` | Script |
| `ocnfixedip start` | `configure.sh start` | Script |
| `ocnfixedip stop` | `teardown.sh` | Script |
| `ocnfixedip restart` | `configure.sh restart` | Script |
| `ocnfixedip status` | `status.sh` | JSON script output |
| `ocnfixedip diagnostics` | `diagnostics.sh` | JSON script output |

### 13.2 HTTP API

| Endpoint | Purpose |
|---|---|
| `/api/ocnfixedip/settings/get` | Read the MVC settings model |
| `/api/ocnfixedip/settings/set` | Validate and save settings |
| `/api/ocnfixedip/service/reconfigure` | Run `ocnfixedip configure` after POST |
| `/api/ocnfixedip/service/status` | Return parsed status JSON |
| `/api/ocnfixedip/service/diagnostics` | Return parsed diagnostics JSON |

The ACL grants access to the UI path and both settings/service API namespaces through
the `page-ocnfixedip-config` privilege.

### 13.3 Service registration

When enabled, the plugin appears in OPNsense services as `ocnfixedip`, with start,
restart, and stop configd actions. It is registered with `nocheck` because there is no
separate daemon process or PID to monitor.

---

## 14. Status and Diagnostics

### 14.1 Status state machine

Status is machine-readable and health-driven. `health=healthy` is reported only when all
required checks pass. Otherwise `health=degraded` with a comma-separated
`health_failures` list.

Current status checks include:

1. `tunnel_state` (`gif0` RUNNING)
2. `default_route` (`192.0.0.1` via `gif0`)
3. `dns` (`one.one.one.one` A resolution)
4. `mtu` (configured vs runtime)
5. `wan_alias` (WAN has CE `/128` alias)
6. `prefix_update` (last recorded update result from `/var/run/ocnfixedip_prefix_update_status`)
7. `ce_to_br` (IPv6 ping from CE source to BR)
8. `internet` (IPv4 ping to `1.1.1.1` from tunnel IPv4 source)
9. `ipv6_internet` (IPv6 ping to `2606:4700:4700::1111` from CE source)
10. `mtu_probe` (IPv4 DF probe at tunnel MTU)
11. `mtu_fragmentation` (large IPv4 packet probe with DF off)

Dashboard widget and settings-page status rely on this same status JSON.

### 14.2 Diagnostics payload

Diagnostics returns structured check-by-check JSON under `checks` and the UI renders:

- Per-check status badges (`ok` / `ng` / `skipped` / `not-configured`)
- Source/target details and RTT when available
- A summary section (`x/16 checks passed`) with success/failure guidance

Current diagnostics checks (ordered):

1. Tunnel state
2. IPv4 default route to tunnel
3. WAN `/128` alias presence
4. Tunnel MTU config match
5. IPv6 CE-to-BR Ping
6. Prefix update API check (live call)
7. IPv4 internet Ping `1.1.1.1` (tunnel IPv4 source)
8. IPv6 internet Ping `2606:4700:4700::1111` (CE source)
9. IPv4 MTU probe (DF Ping)
10. IPv6 MTU probe (DF Ping)
11. IPv4 large packet fragmentation test
12. IPv6 large packet fragmentation test
13. DNS A name resolution
14. IPv4 curl `one.one.one.one` (tunnel IPv4 source)
15. DNS AAAA name resolution
16. IPv6 curl `one.one.one.one` (CE IPv6 source)

Diagnostics also updates `/var/run/ocnfixedip_prefix_update_status` so status/widget
health remains aligned with the latest prefix-update outcome.

---

## 15. Installation and Removal

Installation/removal is package-based using FreeBSD `pkg`.

Install:

- `pkg add -f <os-ocnfixedip-*.pkg>`

Uninstall:

- `pkg delete -y os-ocnfixedip`

Embedded package lifecycle hooks:

1. `post-install`: restarts `configd`, clears OPNsense UI caches, pre-creates `gif0` if missing.
2. `pre-deinstall`: runs `configctl ocnfixedip stop` (best-effort).
3. `post-deinstall`: restarts `configd` and clears OPNsense UI caches.

It intentionally does not remove:

- `//OPNsense/ocnfixedip` from `/conf/config.xml`
- Interface assignment entries
- Gateway definitions
- Outbound NAT, firewall, or normalization rules
- Any WAN `/128` alias that remains after teardown

---

## 16. Failure Behavior

| Failure point | Exit behavior | Possible residual state |
|---|---|---|
| Required BR/IPv4 missing | Exit 1 | Existing tunnel untouched unless restart was requested |
| WAN IPv6 unavailable | Exit 1 after retries | Existing tunnel may remain |
| IPv6 calculation failure | Exit 1 | Existing tunnel may remain |
| WAN device missing | Exit 1 | Existing tunnel may remain |
| WAN alias add fails | Exit 1 | Old alias may already have been removed |
| Update URL/user missing | Exit 1 | New WAN alias has already been added |
| `gif0` create fails | Exit 1 | WAN alias remains |
| Tunnel endpoint/address setup fails | Exit 1 | Partially configured `gif0` may remain |
| Auto-assignment fails | Continue with warning | Tunnel remains usable but manual assignment is required |
| Default route operation fails | Continue with warning | Tunnel remains up without expected default route |
| Prefix update fails | Continue and exit 0 | Tunnel remains up; prefix registration may be stale and status health becomes degraded (`prefix_update`) |

Operators should inspect the `ocnfixedip` system log after any failed or ambiguous
Apply operation. A restart performs teardown first and is the normal recovery path.

---

## 17. Security Considerations

- Credentials reside in `/conf/config.xml` and therefore in OPNsense configuration
  backups. Protect and encrypt backups appropriately.
- The Web UI renders the password field as a password input, but the underlying model
  stores text rather than an external secret reference.
- Prefix update credentials are written to a randomly named mode-`0600` netrc file so
  they do not appear directly in process arguments.
- The netrc file is deleted after `curl`, but there is no signal trap guaranteeing
  deletion on abrupt termination.
- `curl -k` disables TLS certificate validation when an HTTPS endpoint is configured.
- The configured update URL, including hostname token, is written to the system log.
- Diagnostics expose interface addresses and routes and should be sanitized before
  sharing publicly.
- The auto-assignment PHP block writes OPNsense configuration as root through the
  standard configuration include and `write_config()`.

---

## 18. Known Limitations

1. Only `gif0` is supported; multiple OCN tunnels cannot coexist.
2. Peer IPv4 is fixed at `192.0.0.1`.
3. The algorithm is anchored to a `/56` base and is not configurable.
4. WAN address discovery selects the first eligible IPv6 address.
5. The plugin changes the global IPv4 default route directly.
6. Prefix update still does not fail the configure transaction (it is reflected in health state instead).
7. Configure debounce is not mutual exclusion.
8. Configure has no transactional rollback.
9. Teardown forgets, but does not remove, its WAN `/128` alias.
10. Status health depends on specific probe endpoints (BR, `1.1.1.1`, `2606:4700:4700::1111`, and DNS `one.one.one.one`).
11. Distribution is package-based (`.pkg`) but not yet integrated into the official OPNsense plugins repository feed.
12. There is no automated unit or integration test suite.

---

## 19. Development and Test Guidance

### 19.1 Minimum static checks

Run shell syntax validation for every shell entry point:

```sh
for file in os-ocnfixedip/tools/build-pkg.sh \
            os-ocnfixedip/src/opnsense/scripts/OPNsense/ocnfixedip/*.sh; do
    sh -n "$file" || exit 1
done
```

Also validate XML and PHP with tools available in the target OPNsense development
environment.

### 19.2 Local package build on OPNsense

This repository includes a local package build path:

```sh
cd /root/os-ocnfixedip/os-ocnfixedip
make pkg
```

Build output:

- `os-ocnfixedip/dist/*.pkg`

Install locally on OPNsense:

```sh
pkg add -f /root/os-ocnfixedip/dist/os-ocnfixedip-*.pkg
```

The generated package embeds lifecycle hooks:

- post-install: restart `configd`, clear OPNsense UI caches, pre-create `gif0` if missing
- pre-deinstall: `configctl ocnfixedip stop`
- post-deinstall: restart `configd`, clear OPNsense UI caches

Supported make variables:

- `PKG_VERSION`
- `PKG_MAINTAINER`
- `PKG_WWW`
- `PKG_ORIGIN`

Clean build artifacts:

```sh
make clean
```


### 19.3 OPNsense VM test matrix

At minimum, exercise these paths on a disposable OPNsense VM or lab router:

1. Fresh installation and first login.
2. Disabled Apply behavior.
3. First enable with valid settings.
4. Existing and newly created `gif0` assignment paths.
5. Repeated Apply within and outside the debounce window.
6. Service restart and stop/start.
7. WAN IPv6 prefix renewal with alias replacement.
8. Invalid BR, IPv4, update URL, hostname, and credentials.
9. Missing WAN IPv6 during the retry window.
10. Gateway, NAT, MSS, and LAN-client public IPv4 verification.
11. Dashboard and Diagnostics rendering.
12. Uninstall followed by inspection for residual configuration and aliases.

### 19.4 Change discipline

- Keep README user guidance and this implementation reference consistent.
- Do not document behavior as guaranteed until it exists in the runtime scripts.
- Treat routing, teardown, authentication, and prefix-renewal changes as high-risk.
- Preserve OPNsense configuration through `write_config()` when changing assignments.
- Avoid placing credentials in command arguments or logs.
- Test both Hikari Cross direct `/56` and downstream-HGW `/60` observations while
  confirming the intended `/56` normalization.
