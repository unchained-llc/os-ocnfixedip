# OPNsense DS-Lite Plugin

OPNsense plugin for Japanese ISP DS-Lite (Dual-Stack Lite) IPv4-in-IPv6 tunneling. Provides IPv4 internet access over IPv6-only NTT IPoE connections.

## Supported ISPs

| ISP Service | AFTR Address | Auto-detect |
|-------------|-------------|-------------|
| Transix (Internet Multifeed) | 2001:c28:5:301::11 | Yes |
| Xpass (ARTERIA Networks) | 2001:f60:0:200::1 | Yes |
| v6 Connect (NTT Smart Connect) | 2404:8e00::feed:100 | Yes |
| Custom | Manual entry | - |

The plugin can auto-detect your AFTR address from your delegated IPv6 prefix.

## Installation

### One-line install (on OPNsense)

```sh
fetch -o /tmp/install-dslite.sh https://raw.githubusercontent.com/YOU/dslite/main/os-dslite/install.sh && sh /tmp/install-dslite.sh
```

### Manual install (from remote machine with SSH access)

```sh
git clone https://github.com/YOU/dslite.git
cd dslite/os-dslite
./deploy.sh <opnsense-ip>
```

## Prerequisites

Before enabling DS-Lite, configure your OPNsense interfaces:

1. **WAN interface** (connected to NTT ONT)
   - IPv4 Configuration Type: **None**
   - IPv6 Configuration Type: **DHCPv6**

2. **LAN interface**
   - IPv6 Configuration Type: **DHCPv6**
   - Prefix delegation size: **56**

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
# On OPNsense:
fetch -o /tmp/uninstall-dslite.sh https://raw.githubusercontent.com/YOU/dslite/main/os-dslite/uninstall.sh && sh /tmp/uninstall-dslite.sh
```

## Compatibility

- OPNsense 24.1+ (FreeBSD 14.x)
- Tested on OPNsense 25.1

## License

BSD 2-Clause
