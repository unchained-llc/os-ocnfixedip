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

WAN candidates must be global addresses in `2000::/3`, excluding temporary,
tentative, duplicated, deprecated, detached addresses and the tracked tunnel alias. An empty candidate
set or multiple `/56` bases causes discovery to fail and retry. The selected stable
WAN address must share the intended OCN `/56`; separate delegated prefixes are not
automatically inferred.

### 2.3 WAN `/128` alias

The calculated local tunnel IPv6 is added to the selected WAN device as a `/128`
alias. This makes the local endpoint explicitly usable during DHCPv6 renewal timing
windows where `gif0` might otherwise remain non-running.

The last managed address is stored in:

```text
/var/run/ocnfixedip_local_tunnel_v6
```

State contains `device address owned` (one line). The ownership flag is `1` only
when the plugin created the alias, or migrated its legacy one-address record on the
configured WAN. Existing matching aliases are recorded with ownership `0` and are
preserved on stop. A prefix/device change removes the owned alias from the recorded
old device. Deletion failure retains the record for retry. Older aliases whose state
was already lost cannot safely be identified as owned.

### 2.4 MTU and TCP behavior

- Default tunnel MTU: `1460`
- Allowed model range: `1280` through `9000`
- When available, runtime saves `net.inet.tcp.mss_ifmtu` and sets it to `1`; stop restores it. Missing OIDs (including FreeBSD 15) are optional and never block configure/stop.
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
- Uses `--connect-timeout 2`, `--max-time 10`, a 4096-byte response limit and a Python watchdog
- Uses a temporary mode-`0600` netrc file with quoted credentials and cleanup on
  completion, timeout and handled signals; curl 7.84+ is required for quoted tokens
- Appends `hostname=` only when a hostname is configured and the URL does not already
  contain that parameter
- Accepts URLs that already contain other query parameters
- Restricts URLs to HTTP(S), validates/encodes hostname tokens and verifies HTTPS certificates
- Logs only a recognized result code; URLs, credentials and response bodies are omitted
- Serializes updates through a separate lock and writes result state atomically

Prefix update failure is returned as `warning=prefix_update`, while the tunnel result
remains successful. Health reads `/var/run/ocnfixedip_prefix_update_status`.

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
If the plugin is disabled, it returns without invoking configd. An explicitly supplied
interface list must contain the configured logical WAN. Other IPv6 events are ignored.

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

The main page schedules a status request five seconds after the previous response;
requests do not overlap, and polling pauses during Apply. Apply validation, backend
failure phase and prefix-update warnings are displayed explicitly. Status health
failures are shown separately from overall connectivity.

Diagnostics runs immediately on load via POST (normal OPNsense CSRF protection).
All diagnostic data is JSON serialized and HTML escaped. Plugin UI messages are
English. Japanese support is limited to documentation; no plugin-local translation
module or DOM localization pass is included.

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
   - (when removing a managed alias) `Removed managed WAN /128 alias on ...`
   - `Prefix update result: good` or `nochg`
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

The current package hooks do not remove legacy `DSLite` files. Inspect and remove
obsolete files from earlier manual installations separately. New code and documentation
should not reintroduce the former `dslite` namespace.

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

1. Acquire the shared kernel runtime lock, waiting up to 30 seconds.
2. Load configuration; disabled Apply runs stop without requiring valid update fields.
3. Check prerequisites and validate update URL, credentials, hostname and tunnel values.
4. Discover a stable WAN IPv6 with retries and calculate the local address.
5. Snapshot the previous tunnel, gateway, alias ownership and sysctl state.
6. Accept a tracked tunnel or an OPNsense-restored tunnel matching the BR, IPv4/peer and local IPv6 formula; reject unrelated configured GIFs.
7. For restart, stop only after preflight succeeds.
8. Replace the managed WAN alias and persist its device/address/ownership.
9. Create/configure `gif0`, MTU and MSS sysctl; bring it up.
10. Best-effort assign an enabled `TUNNEL` interface through `write_config()`.
11. Change the default route, with delete/add fallback, and verify gateway/interface.
12. Perform a bounded prefix update; return a warning for endpoint/auth failures.
13. Invalidate status cache and emit structured `result`, `phase`, `warning` JSON.

Network-operation failure returns nonzero and attempts to restore the previous
network snapshot. A failed recovery is reported as `warning=rollback` and logged.
This is best-effort: OPNsense interface assignments are retained and rollback
commands may themselves fail. Keep console access available.

---

## 12. Runtime State and Idempotency

| Path | Purpose |
|---|---|
| `/var/run/ocnfixedip.lock` | Shared configure/restart/stop kernel lock |
| `/var/run/ocnfixedip_local_tunnel_v6` | Device, IPv6 and ownership flag |
| `/var/run/ocnfixedip_mss_ifmtu` | Original MSS sysctl value, preserved across restart |
| `/var/run/ocnfixedip_prefix_update_status` | Timestamp, curl result, recognized response token |
| `/var/run/ocnfixedip_prefix_update_status.lock` | Serialize live prefix updates |
| `/var/run/ocnfixedip_status.json` | Status payload cached for up to five seconds |
| `/var/run/ocnfixedip_status.json.lock` | Serialize cache refreshes across consumers |

Locks use `fcntl.flock`; lock files are never unlinked while processes may wait on
them. Kernel ownership is released on process exit, so stale PID files are not used.
After reboot, volatile ownership state is absent. `tunnel_matches_config()` recognizes
OPNsense-restored GIFs by contract addresses and the derived local IPv6 formula; this
does not claim unrelated WAN aliases.

The former three-second debounce stamp is unused. Explicit restart and disabled
Apply are always processed after acquiring the runtime lock.

Managed alias deletion happens before discarding ownership state. Status cache is
invalidated by configure, stop and diagnostics updates. Cached health may otherwise
be up to five seconds old. JSON state writes in Python use atomic replacement.

---

## 13. Service and API Surface

### 13.1 configd actions

| Action | Command | Output type |
|---|---|---|
| `ocnfixedip configure` | `configure.sh` | Structured JSON (`script_output`, `errors:no`) |
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
| `/api/ocnfixedip/service/diagnostics` | POST only; live update and parsed diagnostics JSON |

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

Dashboard widget and settings-page status rely on the same cached status JSON.
FreeBSD ping probes use `-W 2000 -t 3` (milliseconds per reply, seconds overall).

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

- `pkg add -f /root/os-ocnfixedip/dist/os-ocnfixedip-2026.10.28.pkg`

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
- Unowned WAN aliases and previously orphaned aliases from old versions

Owned aliases are removed and the saved MSS sysctl is restored on stop. Cleanup
failures preserve the alias record for retry and require operator attention. The
package pre-install hook checks runtime commands before installation, and includes
the project LICENSE under `/usr/local/share/licenses/os-ocnfixedip/`.

---

## 16. Failure Behavior

| Failure | Result |
|---|---|
| Runtime lock timeout | Failed backend response; active operation is not interrupted |
| Invalid settings, missing/ambiguous WAN IPv6 | Fail before network changes/restart teardown |
| Unmanaged configured `gif0` | Fail with `phase=ownership` |
| Alias, tunnel, MTU, sysctl or route failure | Fail with phase; attempt network snapshot recovery |
| Recovery itself fails | Fail with `warning=rollback`; inspect system logs/state |
| Auto-assignment fails | Continue with logged warning; assign manually |
| Prefix update fails | Successful tunnel result with `warning=prefix_update`; degraded health |
| Backend output is missing/invalid | HTTP API returns failed, never success |

The PHP Apply endpoint checks structured backend output. The configd configure
action uses `errors:no` to preserve the failure JSON even when the shell exits
nonzero. The API does not infer success from process invocation alone.

---

## 17. Security Considerations

Credentials remain in `/conf/config.xml` and backups. Prefix requests pass credentials
through stdin to the Python helper, then through a temporary quoted netrc file to
curl. They do not appear in command arguments or update logs. Credential control
characters are rejected. The netrc is removed on completion, timeout and handled
signals; SIGKILL cannot guarantee cleanup.

HTTPS uses certificate validation. HTTP remains supported for OCN compatibility and
has no TLS protection. Only HTTP(S) URLs without embedded authentication/fragments
are accepted; hostname tokens are validated and query parameters encoded. No update
URL, hostname token or arbitrary response body is logged or exposed by Diagnostics.

Diagnostics requires POST and standard OPNsense CSRF protection because it sends a
live update. JSON uses a real serializer; dynamic UI values are text or escaped at
HTML sinks. Interface/routing details remain sensitive operational information.

---

## 18. Known Limitations

1. One dedicated `gif0` and fixed peer `192.0.0.1`; no multi-tunnel support.
2. Address derivation requires the intended OCN `/56` to match the stable WAN address.
3. The plugin changes the system IPv4 default route directly; gateway/NAT/firewall/MSS rules remain administrator-managed.
4. Recovery is best-effort, and OPNsense assignment changes are retained after failure.
5. Previously orphaned aliases without ownership state require manual inspection.
6. Health depends on fixed external probes and does not prove a complete Internet outage.
7. Distribution is package-based, outside the official OPNsense plugins repository feed.
8. Automated tests use mocks; FreeBSD/OPNsense VM and real OCN integration tests remain required.

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

Run the portable checks and regression suite from the plugin directory:

```sh
make check
```

Python 3, Node.js 20.11+ and `xmllint` are needed. PHP lint runs if PHP CLI is
available; CI runs `python3 os-ocnfixedip/tools/check.py --require-php` and fails
if PHP is absent. Tests cover kernel locking, lifecycle/rollback, alias ownership,
WAN changes, update authentication, safe JSON/HTML, UI localization, status caching
and package staging. The package test mocks `pkg`, so it is not a FreeBSD build.

### 19.2 Local package build on OPNsense

This repository includes a local package build path:

```sh
cd /root/os-ocnfixedip/os-ocnfixedip
make pkg
```

Build output:

- `os-ocnfixedip/dist/*.pkg`

Install locally on OPNsense (select one explicit version; do not use a wildcard):

```sh
pkg add -f /root/os-ocnfixedip/dist/os-ocnfixedip-2026.10.28.pkg
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
5. Concurrent/repeated Apply, explicit restart and disabled Apply while another operation holds the lock.
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
