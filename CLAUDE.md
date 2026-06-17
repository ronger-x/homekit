# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

`homekit` is a collection of network operations and device management scripts for home-lab environments. The repository contains standalone utilities focused on network administration, Wake-on-LAN, and RouterOS configuration. All documentation and comments are in Chinese.

## Network Environment Context

The scripts assume a specific network topology:

- **RouterOS gateway**: `192.168.88.1` (MikroTik RouterOS 7.x)
- **OpenClash gateway**: `192.168.88.169` (legacy transparent proxy, replaced by OSPF split routing)
- **OSPF split router**: `192.168.88.250` (PVE LXC container with BIRD + WireGuard for intelligent traffic routing)
- **DNS server**: `192.168.88.243` (AdGuard Home + MosDNS for DNS split resolution)
- **LAN subnet**: `192.168.88.0/24`
- **DHCP server**: `defconf` (RouterOS default)

### Traffic Routing Architecture

**Current approach (OSPF-based split routing):**

The network uses OSPF (Open Shortest Path First) for intelligent traffic splitting:
- A dedicated LXC container (192.168.88.250) runs BIRD routing daemon
- BIRD advertises non-China IP routes to RouterOS via OSPFv2 (IPv4) and OSPFv3 (IPv6)
- RouterOS learns these routes and forwards overseas traffic to the OSPF container
- The container routes overseas traffic through WireGuard tunnel, while domestic traffic goes direct
- Automatic failover: if the container dies, OSPF routes are withdrawn within 10-40 seconds

**Benefits over previous Mangle PBR approach:**
- No performance impact (preserves RouterOS Fast Path/Fast Track)
- Fast convergence (thousands of routes sync in seconds)
- Incremental updates (no connection interruption)
- Full IPv6 support via OSPFv3
- Automatic health checking and failover

The infrastructure also supports per-device routing via DHCP options (legacy): specific devices can be configured via DHCP options to use a different gateway and DNS server.

## Key Components

### network/ospf-split-routing-deployment.md

Complete deployment guide for OSPF-based intelligent traffic splitting. Documents:
- PVE LXC container creation (VMID 250, IP 192.168.88.250)
- WireGuard tunnel configuration
- BIRD routing daemon setup (OSPFv2 + OSPFv3)
- RouterOS OSPF configuration
- Full testing and verification procedures
- Migration from Mangle PBR to OSPF

### network/ospf-split-routing-maintenance.md

Operational maintenance manual for the OSPF split routing system. Covers:
- Daily monitoring (OSPF neighbors, route counts, tunnel status)
- Updating non-China IP lists with nchnroutes
- Manual operations (disable/enable OSPF, force specific IPs direct or via tunnel)
- Comprehensive troubleshooting scenarios
- Performance monitoring and alerting
- Backup and disaster recovery procedures

### network/sing-box-configuration-guide.md

完整的 sing-box 配置指南，用于 OSPF 容器的隧道客户端。包含：
- sing-box 安装步骤（预编译二进制/包管理器）
- 多协议节点配置（Shadowsocks, VMess, VLESS, Trojan, Hysteria）
- 出站选择器配置（urltest 自动选择/selector 手动切换）
- TUN 接口配置（auto_route: false，由 BIRD 管理路由）
- systemd 服务配置
- 完整的验证和测试步骤
- 高级功能（geosite/geoip 分流、多出口策略、Clash API）
- 故障排查（TUN 接口、节点连接、流量转发、自动切换）
- 性能优化和日常维护

### network/sing-box-template.json

sing-box 配置模板文件，包含：
- TUN 入站配置（tun0 接口，auto_route: false）
- urltest 出站选择器（自动选择最低延迟节点）
- 多种协议示例节点配置
- DNS 配置（远程 DoH + 本地 DNS）
- 路由规则配置

### network/bird-ospf-template.conf

BIRD 2.x configuration template for OSPF routing. Includes:
- OSPFv2 (IPv4) and OSPFv3 (IPv6) protocol definitions
- Static route imports from nchnroutes-generated files
- OSPF authentication settings
- Kernel routing table synchronization

### network/wireguard-template.conf

WireGuard VPN configuration template for the OSPF container. Features:
- Split AllowedIPs configuration (0.0.0.0/1 + 128.0.0.0/1) to preserve default route
- MTU optimization for tunnel traffic
- PersistentKeepalive settings for NAT traversal

**Note:** This template is provided for reference. The recommended approach is to use sing-box for multi-protocol support and automatic failover.

### network/nftables-ospf.conf

nftables firewall configuration for the OSPF container. Implements:
- MSS clamping to prevent MTU issues
- SNAT/masquerade for WireGuard egress traffic
- Stateful connection tracking
- LAN → WireGuard forwarding rules

### network/routeros-cn-policy-routing.md (Legacy)

**Note:** This Mangle-based policy routing approach has been replaced by OSPF split routing for better performance and reliability. Kept for reference and rollback scenarios.

Documents the legacy approach using:
- 4,283 China IP address list (cnip)
- Mangle rules for packet marking
- Routing table with via-openclash routing mark
- Performance impact: disables Fast Path/Fast Track

### network/wol_plus.sh

Enhanced Wake-on-LAN tool with the following features:

- **Config file**: `~/.wol_hosts` stores device aliases with format: `alias MAC [broadcast_IP] [port]`
- **Dependencies**: Attempts to auto-install `netcat` if missing; falls back to `/dev/udp` method
- **Interactive mode**: Provides menu when run without arguments
- **ARP scanning**: Can discover devices from ARP cache

Usage patterns:
```bash
# Wake by alias
./network/wol_plus.sh nas

# Wake by MAC with custom broadcast
./network/wol_plus.sh 00:11:22:33:44:55 192.168.1.255 9

# Wake via specific interface
./network/wol_plus.sh -i eth0 pc1

# Add device alias
./network/wol_plus.sh -a pc2 00:11:22:33:44:66 -i eth0

# List saved devices
./network/wol_plus.sh -l

# Scan ARP table
./network/wol_plus.sh -s
```

### network/routeros_dhcp_hex.sh

Converts IPv4 addresses to RouterOS DHCP option hex format (required for DHCP option values).

```bash
./network/routeros_dhcp_hex.sh 192.168.88.4
# Output: 0xC0A85804
```

### network/routeros-openclash-dhcp.md

Operational manual for configuring per-device DHCP overrides on RouterOS to route specific LAN clients through the OpenClash gateway. Documents the complete workflow:

- Creating reusable DHCP options (`openclash-gateway` code=3, `openclash-dns` code=6)
- Making DHCP leases static and binding options
- Removing devices from OpenClash routing
- Verification commands

This approach uses DHCP option overrides on individual leases rather than routing tables, simplifying the configuration and avoiding the need for policy-based routing rules.

## Script Conventions

- **Shell**: All scripts use bash with `#!/bin/bash` or `#!/usr/bin/env bash`
- **Error handling**: Critical scripts use `set -euo pipefail`
- **Colors**: ANSI color codes used for user feedback (RED, GREEN, YELLOW, BLUE, NC)
- **Validation**: MAC addresses validated as 12 hex digits (cleaned of `:` or `-` separators)
- **Portability**: Scripts detect available tools (`ip` vs `ifconfig`, `nc` availability, package managers)

## Testing Scripts

There is no automated test framework. To verify changes:

1. **Syntax check**: `bash -n script.sh`
2. **ShellCheck** (if available): `shellcheck script.sh`
3. **Manual execution**: Test with safe parameters (e.g., non-existent MAC for WOL, known IPs for hex converter)

For `wol_plus.sh` specifically:
- Test interactive mode: run without arguments
- Test ARP scan: `./wol_plus.sh -s` (safe, read-only)
- Test help: `./wol_plus.sh -h`
- Test config operations: use `-l` to list, `-a` to add test entries

For RouterOS changes documented in the manual:
- Always use `/print detail` to verify configuration before applying changes
- Test DHCP renewals on non-critical devices first
- Keep the old configuration documented in comments when migrating approaches

## Adding New Scripts

When adding network utilities:

1. Place in `network/` directory
2. Use bash for shell scripts
3. Include usage/help output (via `-h` flag or `usage()` function)
4. Add entry to README.md under "组件示例" section
5. Use Chinese for user-facing messages and documentation to match existing style
6. Consider portability across Linux distributions (detect tools, provide fallbacks)
7. For RouterOS-related tools, document the assumed network topology and RouterOS version

## Git Workflow

- Default branch: `master`
- Keep commits atomic and descriptive
- Document user-facing changes in README.md
- Use Chinese for commit messages to match repository language

## Common RouterOS Operations

When adding RouterOS-related utilities or documentation:

- Always specify full paths: `/ip/dhcp-server/lease`, not shortcuts
- Use `print detail where <filter>` for precise queries
- Document the `code=` values for DHCP options (standard codes: 3=gateway, 6=DNS, 15=domain, etc.)
- Hex values in RouterOS display as lowercase without `0x` prefix in output (e.g., `c0a85804`)
- Include verification commands after destructive changes
- Note compatibility: scripts assume RouterOS 7.x syntax

## Environment Configuration

The repository supports `.env` file for storing credentials and API tokens:

- **File**: `.env` (gitignored, must be created from `.env.example`)
- **Purpose**: Store NETBOX/LibreNMS API tokens, RouterOS credentials
- **Documentation**: See `ENV_SETUP.md` for setup instructions

Scripts that interact with NETBOX or LibreNMS should source `.env` to read configuration:
```bash
[ -f .env ] && source .env || { echo "Error: .env not found"; exit 1; }
```

Never commit `.env` files or hardcode credentials in scripts.

## Dependencies

- **bash**: Required for all scripts
- **netcat (nc)**: Used by `wol_plus.sh`, auto-installed if possible
- **iproute2 or net-tools**: For network interface queries
- **column**: Optional, improves tabular output formatting
- **curl**: For API interactions with NETBOX/LibreNMS
- **jq**: Recommended for parsing JSON responses from APIs

Scripts gracefully degrade when optional tools are missing.
