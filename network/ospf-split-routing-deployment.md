# OSPF 智能分流部署指南

## 概述

本文档记录基于 Proxmox VE (PVE) LXC 容器 + BIRD + OSPF 实现国内外流量智能分流的完整部署流程。

### 方案特点

- **高性能**: 不使用 Mangle 规则，保留 RouterOS Fast Path/Fast Track 硬件加速
- **快速收敛**: OSPF 协议几秒内同步上万条路由
- **增量更新**: IP 列表变化时不影响已建立的连接
- **自动故障切换**: 旁路由宕机后 10-40 秒自动撤回路由，流量回退到运营商直连
- **完整双栈**: 同时支持 IPv4 (OSPFv2) 和 IPv6 (OSPFv3)

### 替代方案

本方案替代现有的 **Mangle + 策略路由 (PBR)** 方案：

| 对比项 | 旧方案 (Mangle PBR) | 新方案 (OSPF) |
|--------|---------------------|---------------|
| 性能影响 | 禁用 Fast Path | 无影响 |
| IP 列表更新 | 全量导入 1-2 分钟 | 增量更新几秒 |
| 故障切换 | 无 | 自动 (10-40秒) |
| IPv6 支持 | 未配置 | 完整支持 |

### 网络拓扑

```
                      Internet
                          ↑
                    WAN (PPPoE)
                          |
              +----------------------+
              |  RouterOS Gateway    |
              |  192.168.88.1        |
              |  OSPF 实例（被动）    |
              +----------------------+
                          |
          +---------------+---------------+
          |                               |
    国内 IP 流量                    国外 IP 流量
    (直连运营商)              (学习 OSPF 路由 via .250)
          |                               |
          ↓                               ↓
      运营商出口                +----------------------+
                                |  OSPF 旁路由 (LXC)   |
                                |  192.168.88.250      |
                                |  - BIRD OSPFv2/v3   |
                                |  - WireGuard 隧道    |
                                |  - nftables NAT     |
                                +----------------------+
                                          |
                                    WireGuard 隧道
                                          |
                                      代理节点
                                          |
                                      Internet
```

### 环境信息

- **PVE 主机**: 192.168.88.228
- **RouterOS 网关**: 192.168.88.1
- **OSPF 容器**: 192.168.88.250 (新建)
- **LAN 网段**: 192.168.88.0/24
- **DNS 服务器**: 192.168.88.243 (AdGuard Home + MosDNS)

## 部署前准备

### 1. 所需信息

部署前请准备以下信息：

- [ ] WireGuard 隧道配置（服务器 IP、端口、公钥、客户端私钥、隧道 IP）
- [ ] OSPF 认证密码（用于 RouterOS 和 BIRD 之间的 OSPF 认证）
- [ ] PVE root 密码
- [ ] RouterOS admin 密码

### 2. 下载 Debian 模板

在 PVE Web UI 上下载 Debian 12 模板（如果尚未下载）：

1. 登录 PVE: https://192.168.88.228:8006
2. 选择节点 → local (pve) → CT Templates
3. 点击 "Templates" → 搜索 "debian-12"
4. 下载 `debian-12-standard_12.2-1_amd64.tar.zst`

### 3. 确认网络通畅

确保 PVE 主机可以访问：
- 192.168.88.1 (RouterOS)
- 192.168.88.243 (DNS)
- 外网（用于安装软件包）

## Phase 1: 创建 LXC 容器

### 1.1 通过 PVE CLI 创建容器

SSH 登录到 PVE 主机：

```bash
ssh root@192.168.88.228
```

创建 LXC 容器：

```bash
pct create 250 local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst \
  --hostname ospf-router \
  --memory 512 \
  --swap 512 \
  --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.250/24,gw=192.168.88.1 \
  --nameserver 192.168.88.243 \
  --onboot 1 \
  --unprivileged 1 \
  --features nesting=1 \
  --storage local-lvm \
  --rootfs local-lvm:8
```

**参数说明：**
- `250`: 容器 VMID，对应 IP 末位
- `--hostname`: 容器主机名
- `--memory 512`: 内存 512MB（BIRD 通常占用 < 100MB）
- `--net0`: 网络配置，IP 192.168.88.250/24，网关 192.168.88.1
- `--nameserver`: DNS 服务器（AdGuard Home）
- `--onboot 1`: 开机自启
- `--unprivileged 1`: 非特权容器（更安全）
- `--rootfs local-lvm:8`: 根文件系统 8GB

### 1.2 启动容器

```bash
pct start 250
```

等待几秒后检查状态：

```bash
pct status 250
# 应显示: status: running
```

### 1.3 进入容器

```bash
pct enter 250
```

现在你已进入容器的 shell。

### 1.4 更新系统并安装软件包

```bash
apt update
apt install -y bird2 wireguard-tools nftables curl net-tools iproute2 iputils-ping traceroute tcpdump vim
```

安装的软件包：
- `bird2`: OSPF 路由守护进程
- `wireguard-tools`: WireGuard VPN 客户端
- `nftables`: 防火墙和 NAT
- `curl`, `net-tools`, `iproute2`: 网络工具
- `iputils-ping`, `traceroute`: 测试工具
- `tcpdump`, `vim`: 调试工具

### 1.5 启用 IP 转发

编辑 `/etc/sysctl.conf`：

```bash
cat >> /etc/sysctl.conf << 'EOF'

# Enable IP forwarding for OSPF split routing
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
```

应用配置：

```bash
sysctl -p
```

验证：

```bash
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding
# 两者都应返回 1
```

### 1.6 测试网络连通性

```bash
# 测试网关
ping -c 3 192.168.88.1

# 测试 DNS
ping -c 3 192.168.88.243

# 测试外网
ping -c 3 8.8.8.8
ping -c 3 baidu.com
```

全部通过后继续下一步。

## Phase 2: 配置隧道客户端（sing-box）

### 2.1 安装 sing-box

**下载并安装最新版本：**

```bash
# 查看最新版本: https://github.com/SagerNet/sing-box/releases
VERSION="1.8.0"

cd /tmp
wget https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-amd64.tar.gz
tar -xzf sing-box-${VERSION}-linux-amd64.tar.gz
cp sing-box-${VERSION}-linux-amd64/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box

# 验证安装
sing-box version
```

### 2.2 创建 sing-box 配置

**创建配置目录：**

```bash
mkdir -p /etc/sing-box
```

**创建配置文件：**

使用仓库提供的模板 `network/sing-box-template.json` 或手动创建：

```bash
cat > /etc/sing-box/config.json << 'EOF'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "proxy"
      },
      {
        "tag": "dns-local",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "dns-local"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "mtu": 9000,
      "auto_route": false,
      "stack": "system",
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "urltest",
      "tag": "proxy",
      "outbounds": ["node-1", "node-2", "node-3"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 50
    },
    {
      "type": "shadowsocks",
      "tag": "node-1",
      "server": "<SERVER_IP_1>",
      "server_port": 8388,
      "method": "aes-256-gcm",
      "password": "<PASSWORD_1>"
    },
    {
      "type": "vmess",
      "tag": "node-2",
      "server": "<SERVER_IP_2>",
      "server_port": 443,
      "uuid": "<UUID_2>",
      "security": "auto",
      "alter_id": 0,
      "tls": {
        "enabled": true,
        "server_name": "<SNI_2>"
      }
    },
    {
      "type": "trojan",
      "tag": "node-3",
      "server": "<SERVER_IP_3>",
      "server_port": 443,
      "password": "<PASSWORD_3>",
      "tls": {
        "enabled": true,
        "server_name": "<SNI_3>"
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "network": "udp",
        "port": 53,
        "outbound": "direct"
      },
      {
        "ip_cidr": ["224.0.0.0/4", "255.255.255.255/32"],
        "outbound": "block"
      }
    ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
EOF
```

**替换以下占位符：**

根据你的代理线路信息替换：
- `<SERVER_IP_1>`, `<SERVER_IP_2>`, `<SERVER_IP_3>`: 代理服务器 IP 或域名
- `<PASSWORD_1>`, `<PASSWORD_3>`: Shadowsocks/Trojan 密码
- `<UUID_2>`: VMess UUID
- `<SNI_2>`, `<SNI_3>`: TLS SNI (Server Name Indication)

可以添加更多节点，支持的协议：
- `shadowsocks` - Shadowsocks
- `vmess` - V2Ray VMess
- `vless` - V2Ray VLESS
- `trojan` - Trojan
- `hysteria` / `hysteria2` - Hysteria
- `wireguard` - WireGuard

**关键配置说明：**

1. **TUN 接口**：`interface_name: "tun0"` - BIRD 会将路由指向此接口
2. **auto_route: false** - 不自动创建路由，由 BIRD 管理
3. **urltest** - 自动选择延迟最低的节点
4. **outbounds 列表** - 添加你的所有代理节点

详细配置说明参考：`network/sing-box-configuration-guide.md`

### 2.3 验证配置文件语法

```bash
sing-box check -c /etc/sing-box/config.json
```

如果有错误会显示具体行号和问题。

### 2.4 创建 systemd 服务

```bash
cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
```

### 2.5 启用并启动 sing-box

```bash
systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box
```

### 2.6 验证 sing-box 运行状态

```bash
# 查看服务状态
systemctl status sing-box

# 查看日志
journalctl -u sing-box -f
```

**查找关键信息：**
- `[tun] tun interface created` - TUN 接口创建成功
- `[urltest] node-X delay: XXXms` - 节点延迟测试结果
- `[urltest] selected: node-X` - 当前选中的节点

### 2.7 验证 TUN 接口

```bash
# 查看 TUN 接口
ip link show tun0

# 查看 IP 地址
ip addr show tun0

# 应显示:
# tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP>
# inet 172.19.0.1/30 scope global tun0
```

### 2.8 测试隧道连通性

```bash
# 通过 tun0 接口 ping 外网
ping -I tun0 -c 3 1.1.1.1

# 如果成功，说明隧道工作正常
# 如果超时，检查：
# 1. sing-box 日志是否有错误
# 2. 节点配置是否正确
# 3. 节点服务器是否在线
```

## Phase 3: 配置 nftables 防火墙

### 3.1 创建 nftables 配置

```bash
cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        
        # MSS clamping - 防止 MTU 问题导致连接卡死
        tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
        
        # 允许已建立的连接
        ct state { established, related } accept
        
        # 允许 LAN (eth0) → WireGuard (wg0) 转发
        iif "eth0" oifname "wg0" accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        
        # SNAT: WireGuard 出接口做源地址伪装
        oifname "wg0" masquerade
    }
}
EOF
```

### 3.2 使配置生效

```bash
chmod +x /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables
```

### 3.3 验证规则

```bash
nft list ruleset
```

应看到 filter 和 nat 两个表的完整规则。

## Phase 4: 生成非中国 IP 路由表

### 4.1 安装 nchnroutes 工具

在**容器内**或**本地工作站**执行（推荐在容器内）：

```bash
cd /tmp
git clone https://github.com/dndx/nchnroutes.git
cd nchnroutes
```

### 4.2 生成 BIRD 格式路由文件

**重要：排除所有代理节点 IP，避免路由环路！**

假设你的 sing-box 配置中有 3 个节点：
- `node-1`: 1.2.3.4
- `node-2`: 5.6.7.8
- `node-3`: 9.10.11.12

**如果节点使用域名，先解析 IP：**

```bash
# 解析域名获取 IP
nslookup hk.example.com
nslookup us.example.com
nslookup jp.example.com

# 记录所有解析出的 IP
```

**生成路由文件（排除所有节点 IP）：**

```bash
python3 nchnroutes.py \
  --exclude 1.2.3.4/32 \
  --exclude 5.6.7.8/32 \
  --exclude 9.10.11.12/32 \
  --output bird

# 如果节点很多，可以写入文件再批量排除
cat > exclude.txt << 'EOF'
1.2.3.4/32
5.6.7.8/32
9.10.11.12/32
EOF

# 使用排除列表文件
python3 nchnroutes.py --exclude-file exclude.txt --output bird
```

**生成文件：**
- `routes4.conf`: IPv4 路由（约 12,000 条）
- `routes6.conf`: IPv6 路由（约 8,000 条）

查看文件大小：

```bash
ls -lh routes4.conf routes6.conf
wc -l routes4.conf routes6.conf
```

### 4.3 复制路由文件到 BIRD 配置目录

```bash
mkdir -p /etc/bird
cp routes4.conf routes6.conf /etc/bird/
chmod 644 /etc/bird/routes4.conf /etc/bird/routes6.conf
```

### 4.4 调整路由文件格式（指向 tun0）

nchnroutes 默认生成的格式可能需要调整：

```bash
# 检查格式
head -5 /etc/bird/routes4.conf
```

**应该是以下格式之一：**

格式 1（正确）：
```
route 1.0.0.0/24 via "tun0";
```

格式 2（需要修正）：
```
route 1.0.0.0/24 via 192.168.88.250;
```

**如果是格式 2，修正为指向 tun0：**

```bash
sed -i 's/via [0-9.]\+;/via "tun0";/g' /etc/bird/routes4.conf
sed -i 's/via [0-9a-f:]\+;/via "tun0";/g' /etc/bird/routes6.conf

# 验证修改
head -5 /etc/bird/routes4.conf
```

## Phase 5: 配置 BIRD OSPF

### 5.1 创建 BIRD 配置文件

```bash
cat > /etc/bird/bird.conf << 'EOF'
# BIRD 2.x Configuration for OSPF Split Routing
log syslog all;
router id 192.168.88.250;

# Kernel protocol - sync routes
protocol kernel {
    scan time 60;
    ipv4 {
        import none;
        export all;
    };
}

protocol kernel {
    scan time 60;
    ipv6 {
        import none;
        export all;
    };
}

# Device protocol
protocol device {
    scan time 60;
}

# Static routes - non-China IPv4 (via sing-box tun0)
protocol static overseas4 {
    ipv4;
    include "/etc/bird/routes4.conf";
}

# Static routes - non-China IPv6 (via sing-box tun0)
protocol static overseas6 {
    ipv6;
    include "/etc/bird/routes6.conf";
}

# OSPFv2 for IPv4
protocol ospf v2 default_v2 {
    ipv4 {
        import none;
        export where source = RTS_STATIC;
    };

    area 0.0.0.0 {
        interface "eth0" {
            type broadcast;
            cost 10;
            hello 10;
            dead 40;
            retransmit 5;
            wait 40;
            priority 1;

            authentication cryptographic;
            password "YOUR_OSPF_PASSWORD";
        };
    };
}

# OSPFv3 for IPv6
protocol ospf v3 default_v3 {
    ipv6 {
        import none;
        export where source = RTS_STATIC;
    };

    area 0.0.0.0 {
        interface "eth0" {
            type broadcast;
            cost 10;
            hello 10;
            dead 40;
        };
    };
}
EOF
```

**替换占位符：**
- `YOUR_OSPF_PASSWORD`: 设置一个强密码（与 RouterOS 配置保持一致）

**关键说明：**
- 静态路由通过 `routes4.conf` 和 `routes6.conf` 加载
- 路由指向 sing-box 的 `tun0` 接口
- OSPF 仅导出静态路由（`export where source = RTS_STATIC`）
- 不接收外部路由（`import none`）

### 5.2 检查配置语法

```bash
bird -p -c /etc/bird/bird.conf
```

如果有错误，会显示具体行号和错误信息。

### 5.3 启用并启动 BIRD

```bash
systemctl enable bird
systemctl start bird
```

### 5.4 检查 BIRD 状态

```bash
systemctl status bird

# 查看 BIRD 日志
journalctl -u bird -f
```

### 5.5 通过 birdc 验证

```bash
# 进入 BIRD 控制台
birdc

# 在 birdc 内执行：
show status
show protocols
show route count
show ospf neighbors

# 退出
quit
```

**预期输出：**
- `show status`: BIRD 版本和运行状态
- `show protocols`: 应看到 default_v2 和 default_v3 两个 OSPF 协议，状态为 `up`
- `show route count`: 应显示约 20,000+ 条路由
- `show ospf neighbors`: **此时应该为空**（因为 RouterOS 还未配置 OSPF）

## Phase 6: 配置 RouterOS OSPF

### 6.1 SSH 登录 RouterOS

从 PVE 主机或本地工作站：

```bash
ssh admin@192.168.88.1
```

### 6.2 配置 OSPFv2 (IPv4)

```routeros
# 创建 OSPF 实例
/routing ospf instance
add disabled=no name=ospf-split-v2 router-id=192.168.88.1

# 创建 OSPF 区域
/routing ospf area
add disabled=no instance=ospf-split-v2 name=backbone-v2

# 配置 OSPF 接口
/routing ospf interface-template
add area=backbone-v2 \
    auth=md5 \
    auth-id=1 \
    auth-key="YOUR_OSPF_PASSWORD" \
    cost=10 \
    disabled=no \
    interfaces=bridge \
    networks=192.168.88.0/24 \
    priority=10 \
    comment="OSPF split routing with 192.168.88.250"
```

**替换 `YOUR_OSPF_PASSWORD` 为与 BIRD 配置相同的密码。**

**参数说明：**
- `router-id`: RouterOS 的唯一标识，使用管理 IP
- `auth=md5`: MD5 认证
- `interfaces=bridge`: 监听的接口（根据实际情况调整，如 `bridge` 或 `ether2`）
- `networks=192.168.88.0/24`: OSPF 宣告的网络
- `priority=10`: 优先级（大于 BIRD 的 1，确保 RouterOS 成为 DR）

### 6.3 配置 OSPFv3 (IPv6)

```routeros
# 创建 OSPFv3 实例
/routing ospf instance
add disabled=no name=ospf-split-v3 router-id=192.168.88.1 version=3

# 创建 OSPFv3 区域
/routing ospf area
add disabled=no instance=ospf-split-v3 name=backbone-v3

# 配置 OSPFv3 接口
/routing ospf interface-template
add area=backbone-v3 \
    cost=10 \
    disabled=no \
    interfaces=bridge \
    priority=10 \
    comment="OSPFv3 split routing"
```

**注意：** OSPFv3 暂不支持认证（RouterOS 限制）。

### 6.4 验证 OSPF 邻居

等待 10-20 秒后执行：

```routeros
/routing/ospf/neighbor/print
```

**预期输出：**

```
Flags: V - virtual; D - dynamic 
 #   INSTANCE       AREA         ADDRESS            ROUTER-ID      STATE
 0 D ospf-split-v2  backbone-v2  192.168.88.250     192.168.88.250 Full
 1 D ospf-split-v3  backbone-v3  fe80::xxxx:...     192.168.88.250 Full
```

**关键检查：**
- `STATE` 必须是 `Full`（邻居关系已建立）
- 如果是 `Init`, `2-Way`, `ExStart` 等，说明正在协商，等待几秒
- 如果一直是 `Down` 或无输出，检查：
  - 容器网络是否连通（`ping 192.168.88.250`）
  - BIRD 是否运行（在容器内 `systemctl status bird`）
  - OSPF 密码是否一致
  - RouterOS 防火墙是否拦截 OSPF 包（协议 89）

### 6.5 验证路由学习

```routeros
# 查看 OSPF 学到的路由数量
/ip/route/print count-only where ospf

# 应显示约 12,000+
```

查看部分路由：

```routeros
/ip/route/print where ospf detail
```

应看到类似：

```
 Flags: D - dynamic; A - active; o - ospf
 #   DST-ADDRESS      GATEWAY           DISTANCE
 DA o 1.0.0.0/24      192.168.88.250%bridge  110
 DA o 1.0.4.0/22      192.168.88.250%bridge  110
 ...
```

### 6.6 测试路由

```routeros
# 测试国外 IP（应通过 192.168.88.250）
/tool/traceroute 8.8.8.8

# 测试国内 IP（应直连）
/tool/traceroute 223.5.5.5
```

**预期结果：**
- `8.8.8.8` 第一跳是 `192.168.88.250`
- `223.5.5.5` 第一跳直接是 WAN 接口的下一跳

## Phase 7: 全面测试

### 7.1 容器内测试

SSH 进入容器（或 `pct enter 250`）：

```bash
# 测试国外 IP（应通过 tun0）
ping -c 3 1.1.1.1
traceroute 8.8.8.8

# 测试国内 IP（应通过 eth0 直连）
ping -c 3 223.5.5.5
traceroute baidu.com

# 查看路由表
ip route get 1.1.1.1
ip route get 223.5.5.5

# 查看 sing-box 状态
systemctl status sing-box
journalctl -u sing-box -n 20

# 查看 TUN 接口
ip link show tun0
ip addr show tun0
```

**预期：**
- `1.1.1.1` 路由通过 `tun0` 接口
- `223.5.5.5` 路由通过 `eth0` 接口到 `192.168.88.1`
- sing-box 日志显示节点连接正常
- tun0 接口状态为 UP

### 7.2 LAN 客户端测试

在任意局域网设备（Windows/Linux/macOS）：

**Windows:**

```powershell
# 查看网关（应为 192.168.88.1）
ipconfig /all

# 测试路由
tracert 8.8.8.8
tracert baidu.com

# 测试访问
curl -I https://www.google.com
curl -I https://www.baidu.com
```

**Linux/macOS:**

```bash
# 查看网关
ip route show default

# 测试路由
traceroute 8.8.8.8
traceroute baidu.com

# 测试访问
curl -I https://www.google.com
curl -I https://www.baidu.com
```

**预期结果：**
- `traceroute 8.8.8.8` 显示第一跳 `192.168.88.1`，第二跳 `192.168.88.250`
- `traceroute baidu.com` 不经过 `.250`，直接走运营商
- 两个网站都能正常访问

### 7.3 故障切换测试

模拟容器宕机，测试自动故障切换：

**在 PVE 上停止容器：**

```bash
pct stop 250
```

**在 LAN 客户端立即测试：**

```bash
# 持续 ping 国外 IP
ping 1.1.1.1
```

**预期行为：**
1. 前 10-40 秒可能出现丢包（OSPF Dead 超时时间）
2. 之后恢复，走运营商直连（虽然可能被墙，但路由恢复）

**在 RouterOS 上观察：**

```routeros
# 查看 OSPF 邻居（应变为空或 Down）
/routing/ospf/neighbor/print

# 查看 OSPF 路由数量（应变为 0）
/ip/route/print count-only where ospf
```

**重启容器恢复：**

```bash
pct start 250
```

等待 10-20 秒，OSPF 重新收敛，路由恢复。

### 7.4 性能测试

对比切换前后的速度（可选）：

```bash
# 国内网站延迟（应无变化）
ping -c 10 baidu.com

# 国外网站延迟（取决于隧道质量）
ping -c 10 google.com

# 带宽测试
curl -o /dev/null https://速度测试文件URL
```

## Phase 8: 移除旧的 PBR 配置

**确认 OSPF 工作正常后**，清理旧的 Mangle 策略路由配置。

### 8.1 备份当前配置

```routeros
# SSH 登录 RouterOS
ssh admin@192.168.88.1

# 导出完整配置作为备份
/export file=backup-before-removing-pbr

# 下载到本地（可选）
# scp admin@192.168.88.1:/backup-before-removing-pbr.rsc ./
```

### 8.2 移除 Mangle 规则

```routeros
# 查看当前 Mangle 规则
/ip/firewall/mangle/print where comment~"overseas"

# 移除标记规则
/ip/firewall/mangle/remove [find comment~"overseas"]

# 验证已删除
/ip/firewall/mangle/print
```

### 8.3 移除策略路由表

```routeros
# 移除标记路由
/ip/route/remove [find routing-table=via-openclash]

# 移除路由表
/routing/table/remove [find name=via-openclash]

# 验证
/ip/route/print where routing-table!=main
/routing/table/print
```

### 8.4 移除 cnip 地址列表（可选）

如果不需要保留 cnip 列表用于其他用途，可以删除：

```routeros
# 查看数量
/ip/firewall/address-list/print count-only where list=cnip

# 删除（需要一定时间，约 1-2 分钟）
/ip/firewall/address-list/remove [find list=cnip]

# 验证
/ip/firewall/address-list/print where list=cnip
```

**建议：** 可以保留 cnip 列表一段时间，以备回退或其他用途。

### 8.5 验证 Fast Path 恢复

```routeros
# 查看 Fast Path 状态
/ip/settings/print

# 应显示:
# tcp-syncookies: yes
# ip-forward: yes
# allow-fast-path: yes
```

Fast Path 应该自动恢复（移除 Mangle 规则后）。

### 8.6 监控一段时间

在生产环境中，建议保留备份配置文件并监控网络稳定性 1-2 天，确认无问题后再删除备份。

## 部署完成

### 验证清单

- [ ] LXC 容器运行正常（`pct status 250`）
- [ ] WireGuard 隧道连通（容器内 `wg show`，有最近握手）
- [ ] BIRD 运行正常（容器内 `systemctl status bird`）
- [ ] OSPF 邻居状态为 Full（RouterOS `/routing/ospf/neighbor/print`）
- [ ] RouterOS 学到约 12,000+ 条 OSPF 路由（`/ip/route/print count-only where ospf`）
- [ ] 国外 IP traceroute 经过 192.168.88.250
- [ ] 国内 IP traceroute 不经过 192.168.88.250
- [ ] LAN 客户端可以访问 Google、Baidu 等网站
- [ ] 容器重启后 OSPF 自动恢复（故障切换测试通过）
- [ ] 旧的 PBR 配置已移除

### 配置文件位置

| 文件 | 位置 |
|------|------|
| LXC 容器 | PVE VMID 250, IP 192.168.88.250 |
| BIRD 配置 | 容器内 `/etc/bird/bird.conf` |
| 路由文件 | 容器内 `/etc/bird/routes4.conf`, `/etc/bird/routes6.conf` |
| sing-box 配置 | 容器内 `/etc/sing-box/config.json` |
| nftables 配置 | 容器内 `/etc/nftables.conf` |
| RouterOS 备份 | RouterOS `/backup-before-removing-pbr.rsc` |

### 日常维护

参考以下文档了解：
- `network/ospf-split-routing-maintenance.md` - OSPF 维护手册（监控、更新、故障排查）
- `network/sing-box-configuration-guide.md` - sing-box 配置指南（添加节点、协议配置、优化）

## 故障排查

### 问题 1: OSPF 邻居无法建立

**症状：** `/routing/ospf/neighbor/print` 无输出或状态不是 `Full`

**排查步骤：**

1. 检查容器网络连通性：
   ```bash
   # 从 RouterOS
   /ping 192.168.88.250 count=5
   ```

2. 检查 BIRD 状态（容器内）：
   ```bash
   systemctl status bird
   birdc show ospf
   ```

3. 检查认证密码是否一致：
   - 容器内：`grep password /etc/bird/bird.conf`
   - RouterOS：`/routing ospf interface-template print detail`

4. 检查 RouterOS 防火墙：
   ```routeros
   /ip/firewall/filter/print where protocol=ospf
   # 确保没有 drop OSPF (协议 89) 的规则
   ```

### 问题 2: 路由未学习或数量不对

**症状：** `/ip/route/print count-only where ospf` 返回 0 或远少于预期

**排查步骤：**

1. 确认 OSPF 邻居状态必须为 `Full`

2. 检查 BIRD 路由导出（容器内）：
   ```bash
   birdc show route export default_v2 | head -20
   birdc show route count
   ```

3. 检查静态路由是否加载（容器内）：
   ```bash
   birdc show static
   ```

4. 检查 routes4.conf 文件：
   ```bash
   wc -l /etc/bird/routes4.conf
   head /etc/bird/routes4.conf
   ```

### 问题 3: 隧道流量无法通过

**症状：** LAN 客户端无法访问国外网站，但路由正确

**排查步骤：**

1. 容器内测试隧道（容器内）：
   ```bash
   ping -I tun0 1.1.1.1
   ```

2. 检查 sing-box 状态（容器内）：
   ```bash
   systemctl status sing-box
   journalctl -u sing-box -n 50
   
   # 查看节点连接状态
   # 日志应显示类似：
   # [urltest] node-1 delay: 123ms
   # [urltest] selected: node-1
   ```

3. 检查 TUN 接口（容器内）：
   ```bash
   ip link show tun0
   # 应显示: UP,LOWER_UP
   
   ip addr show tun0
   # 应显示: inet 172.19.0.1/30
   ```

4. 检查 nftables SNAT 规则（容器内）：
   ```bash
   nft list table inet nat
   # 应看到 oifname "tun0" masquerade
   ```

5. 检查 IP 转发（容器内）：
   ```bash
   sysctl net.ipv4.ip_forward
   # 应返回 1
   ```

6. 检查路由表（容器内）：
   ```bash
   ip route get 8.8.8.8
   # 应通过 tun0
   ```

7. 测试具体节点（容器内）：
   ```bash
   # 测试节点连通性
   telnet <节点IP> <端口>
   
   # 或使用 curl（如果是 HTTPS）
   curl -v https://<节点域名>
   ```

### 问题 4: 容器无法启动

**症状：** `pct start 250` 失败

**排查步骤：**

1. 查看错误日志：
   ```bash
   pct start 250
   journalctl -xe
   ```

2. 检查磁盘空间：
   ```bash
   df -h
   lvs
   ```

3. 尝试进入容器修复：
   ```bash
   pct enter 250
   # 如果能进入，检查配置文件
   ```

## 参考资源

- **nchnroutes**: https://github.com/dndx/nchnroutes
- **BIRD 文档**: https://bird.network.cz/?get_doc
- **RouterOS OSPF**: https://help.mikrotik.com/docs/display/ROS/OSPF
- **WireGuard**: https://www.wireguard.com/
- **原文参考**: https://idndx.com/use-routeros-ospf-and-raspberry-pi-to-create-split-routing-for-different-ip-ranges/
