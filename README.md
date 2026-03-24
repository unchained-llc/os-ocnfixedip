# OPNsense DS-Lite Plugin

OPNsense plugin for Japanese ISP DS-Lite (Dual-Stack Lite) IPv4-in-IPv6 tunneling. Provides IPv4 internet access over IPv6-only NTT IPoE connections.

## Supported ISPs

| ISP Service | AFTR Address | Auto-detect |
|-------------|-------------|-------------|
| Transix (Internet Multifeed) | 2001:c28:5:301::11 | Yes |
| Xpass (ARTERIA Networks) | 2001:f60:0:200::1 | Yes |
| v6 Connect (NTT Smart Connect) | 2404:8e00::feed:100 | Yes |
| Custom | Manual entry | - |

The plugin auto-detects your AFTR address from your delegated IPv6 prefix.

### Tested on

- **Asahi Net** (asahi-net.jp) + NTT West Flets Hikari Cross (10G plan)
- OPNsense 25.1 (FreeBSD 14.2)

## Installation

### On OPNsense (IPv6-only safe)

Since DS-Lite users may only have IPv6 connectivity before the tunnel is up, the install command uses GitHub's IPv6-accessible CDN:

```sh
curl -6 -skL -o /tmp/install-dslite.sh "https://raw.githubusercontent.com/kawaii-not-kawaii/ds-lite-opnsense/main/os-dslite/install.sh" && sh /tmp/install-dslite.sh
```

### Remote install via SSH (from another machine)

```sh
git clone https://github.com/kawaii-not-kawaii/ds-lite-opnsense.git
cd ds-lite-opnsense/os-dslite
./deploy.sh <opnsense-ip>
```

## Prerequisites

Before enabling DS-Lite, configure your OPNsense interfaces:

1. **WAN interface** (connected to NTT ONT)
   - IPv4 Configuration Type: **None**
   - IPv6 Configuration Type: **DHCPv6**

2. **LAN interface**
   - IPv6 Configuration Type: **DHCPv6**
   - Prefix delegation size: match your plan (see table below)

### NTT Prefix Delegation by Plan

| Plan | Typical PD Size | Notes |
|------|----------------|-------|
| Hikari Cross (10G) | /56 | Guaranteed PD, IPoE only |
| Flets Hikari Next (1G) | /56 or /64 | PD available with current firmware |
| Legacy 1G (no Hikari Denwa) | /64 | May require manual prefix config |

Set the **Prefix delegation size** in OPNsense LAN settings to match what your ISP provides (56 for /56, 64 for /64).

## Usage

1. Navigate to **Interfaces > DS-Lite** in the web UI
2. Check **Enable DS-Lite**
3. Select your ISP profile (or "Auto-detect")
4. Select your WAN interface
5. Click **Apply**

The status panel shows real-time tunnel status including connectivity checks.

## How it works

DS-Lite tunnels IPv4 traffic inside IPv6 packets to your ISP's AFTR (Address Family Transition Router). The AFTR performs NAT44 to give you IPv4 internet access.

```
[LAN clients] -> [OPNsense gif0 tunnel] -> [IPv6 to AFTR] -> [AFTR NAT44] -> [IPv4 Internet]
```

The plugin:
- Creates a FreeBSD `gif` tunnel interface (IPv4-in-IPv6)
- Derives a tunnel source address from the DHCPv6 prefix delegation
- Auto-detects the AFTR address from known Japanese ISP prefix ranges
- Configures NAT (pf masquerade) and TCP MSS clamping
- Monitors tunnel health with connectivity checks

## Uninstall

```sh
curl -6 -skL -o /tmp/uninstall-dslite.sh "https://raw.githubusercontent.com/kawaii-not-kawaii/ds-lite-opnsense/main/os-dslite/uninstall.sh" && sh /tmp/uninstall-dslite.sh
```

## Compatibility

- OPNsense 24.1+ (FreeBSD 14.x)
- Tested on OPNsense 25.1

## License

BSD 2-Clause
