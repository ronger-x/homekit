# sing-box 配置指南（用于 OSPF 智能分流）

> 状态：历史参考。OSPF 分流方案已停用，PaoPaoDNS/PaoPaoGateWay 也已删除。

## 概述

本文档说明如何在 OSPF 智能分流容器中配置 sing-box 作为隧道客户端，替代 WireGuard 方案。

## sing-box 优势

相比 WireGuard 单一隧道：

- ✅ **多协议支持**: Shadowsocks, VMess, VLESS, Trojan, Hysteria, WireGuard 等
- ✅ **多线路负载**: 支持 urltest/fallback 自动选择最快/可用节点
- ✅ **健康检查**: 自动探测节点可用性并切换
- ✅ **灵活路由**: 内置规则引擎，可按域名/IP/geoip 细分
- ✅ **高性能**: Go 编写，性能接近原生协议

## 安装 sing-box

### 方法 1: 下载预编译二进制

```bash
# 在容器内执行
cd /tmp

# 下载最新版本（检查 https://github.com/SagerNet/sing-box/releases 获取最新版本号）
VERSION="1.8.0"
wget https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-amd64.tar.gz

# 解压并安装
tar -xzf sing-box-${VERSION}-linux-amd64.tar.gz
cp sing-box-${VERSION}-linux-amd64/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box

# 验证安装
sing-box version
```

### 方法 2: 使用包管理器（Debian 12+）

```bash
# 添加官方仓库
curl -fsSL https://sing-box.io/gpg.key -o /etc/apt/keyrings/sing-box.asc
echo "deb [signed-by=/etc/apt/keyrings/sing-box.asc] https://sing-box.io/deb/ * *" > /etc/apt/sources.list.d/sing-box.list

# 安装
apt update
apt install -y sing-box
```

## 配置 sing-box

### 1. 创建配置目录

```bash
mkdir -p /etc/sing-box
```

### 2. 创建配置文件

使用仓库模板 `network/sing-box-template.json` 作为基础：

```bash
# 复制模板（假设已从仓库获取）
cp /path/to/sing-box-template.json /etc/sing-box/config.json

# 或手动创建
vi /etc/sing-box/config.json
```

### 3. 配置文件结构说明

#### 入站（Inbound）- TUN 接口

```json
{
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",           // 接口名称
      "inet4_address": "172.19.0.1/30",   // IPv4 地址
      "inet6_address": "fdfe:dcba:9876::1/126",  // IPv6 地址（可选）
      "mtu": 9000,                        // MTU 大小
      "auto_route": false,                // 不自动创建路由（由 BIRD 管理）
      "strict_route": false,
      "stack": "system",                  // 网络栈类型
      "sniff": true                       // 流量嗅探
    }
  ]
}
```

**重要**: `auto_route` 必须设为 `false`，因为路由由 BIRD 通过 OSPF 管理。

#### 出站（Outbound）- 代理节点

支持多种协议，以下是常见示例：

**Shadowsocks 节点:**

```json
{
  "type": "shadowsocks",
  "tag": "ss-node1",
  "server": "1.2.3.4",
  "server_port": 8388,
  "method": "aes-256-gcm",
  "password": "your_password"
}
```

**VMess 节点:**

```json
{
  "type": "vmess",
  "tag": "vmess-node1",
  "server": "5.6.7.8",
  "server_port": 443,
  "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "security": "auto",
  "alter_id": 0,
  "tls": {
    "enabled": true,
    "server_name": "example.com",
    "insecure": false
  }
}
```

**Trojan 节点:**

```json
{
  "type": "trojan",
  "tag": "trojan-node1",
  "server": "9.10.11.12",
  "server_port": 443,
  "password": "your_password",
  "tls": {
    "enabled": true,
    "server_name": "example.com"
  }
}
```

**VLESS 节点:**

```json
{
  "type": "vless",
  "tag": "vless-node1",
  "server": "13.14.15.16",
  "server_port": 443,
  "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "example.com",
    "reality": {
      "enabled": true,
      "public_key": "xxxxx",
      "short_id": "xxxx"
    }
  }
}
```

#### 出站选择器 - urltest

自动选择延迟最低的节点：

```json
{
  "type": "urltest",
  "tag": "proxy",
  "outbounds": ["node-1", "node-2", "node-3"],
  "url": "https://www.gstatic.com/generate_204",
  "interval": "3m",           // 每 3 分钟测试一次
  "tolerance": 50             // 延迟差 50ms 内不切换
}
```

#### 出站选择器 - selector（手动切换）

```json
{
  "type": "selector",
  "tag": "proxy",
  "outbounds": ["node-1", "node-2", "node-3"],
  "default": "node-1"
}
```

### 4. 完整配置示例

将以下内容保存为 `/etc/sing-box/config.json`：

```json
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
      "outbounds": ["ss-hk", "vmess-us", "trojan-jp"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 50
    },
    {
      "type": "shadowsocks",
      "tag": "ss-hk",
      "server": "hk.example.com",
      "server_port": 8388,
      "method": "aes-256-gcm",
      "password": "password123"
    },
    {
      "type": "vmess",
      "tag": "vmess-us",
      "server": "us.example.com",
      "server_port": 443,
      "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "security": "auto",
      "alter_id": 0,
      "tls": {
        "enabled": true,
        "server_name": "us.example.com"
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-jp",
      "server": "jp.example.com",
      "server_port": 443,
      "password": "password456",
      "tls": {
        "enabled": true,
        "server_name": "jp.example.com"
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
```

### 5. 验证配置文件

```bash
# 检查配置语法
sing-box check -c /etc/sing-box/config.json

# 如果有错误会显示具体位置
```

## 创建 systemd 服务

### 1. 创建服务文件

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

### 2. 启用并启动服务

```bash
# 重载 systemd
systemctl daemon-reload

# 启用开机自启
systemctl enable sing-box

# 启动服务
systemctl start sing-box

# 查看状态
systemctl status sing-box
```

## 验证 sing-box

### 1. 检查 TUN 接口

```bash
# 查看接口
ip link show tun0

# 查看地址
ip addr show tun0

# 应显示:
# tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP>
# inet 172.19.0.1/30 scope global tun0
```

### 2. 测试隧道连通性

```bash
# 通过 tun0 接口 ping 外网
ping -I tun0 -c 3 1.1.1.1

# 测试延迟
ping -I tun0 -c 10 www.google.com
```

### 3. 查看 sing-box 日志

```bash
# 实时查看日志
journalctl -u sing-box -f

# 查看最近日志
journalctl -u sing-box -n 50
```

### 4. 测试节点连接

```bash
# sing-box 会在日志中显示节点测速结果
# 查找类似输出:
# [urltest] node-1 delay: 123ms
# [urltest] node-2 delay: 456ms
# [urltest] selected: node-1
```

## BIRD 配置调整

### 修改路由目标接口

编辑 `/etc/bird/routes4.conf` 和 `/etc/bird/routes6.conf`：

```bash
# 将所有路由指向 tun0（而不是 wg0）
sed -i 's/via "wg0"/via "tun0"/g' /etc/bird/routes4.conf
sed -i 's/via "wg0"/via "tun0"/g' /etc/bird/routes6.conf

# 或者在生成时直接指定正确的接口
# 修改 BIRD 配置模板，静态路由使用:
# route x.x.x.x/x via "tun0";
```

### 重新加载 BIRD

```bash
birdc configure
birdc show route count
```

## nchnroutes 生成路由时排除节点 IP

生成路由表时需要排除所有代理节点的 IP，避免路由环路：

```bash
cd /tmp/nchnroutes

# 排除多个节点 IP
python3 nchnroutes.py \
  --exclude 1.2.3.4/32 \
  --exclude 5.6.7.8/32 \
  --exclude 9.10.11.12/32 \
  --output bird

# 如果节点使用域名，先解析 IP
nslookup hk.example.com
# 然后排除解析出的 IP
```

## 高级配置

### 1. 按规则分流（geosite/geoip）

如果想在 sing-box 内部实现部分分流（例如特定网站走特定节点）：

```json
{
  "route": {
    "rules": [
      {
        "geosite": ["netflix"],
        "outbound": "us-node"
      },
      {
        "geosite": ["bilibili"],
        "outbound": "direct"
      },
      {
        "geoip": ["cn"],
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
```

**注意**: 由于 BIRD 已经在外层做了国内外分流，通常不需要在 sing-box 内再次分流。

### 2. 多出口策略

为不同地区流量使用不同节点：

```json
{
  "outbounds": [
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": ["auto", "hk-nodes", "us-nodes", "jp-nodes"]
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["hk-1", "hk-2", "us-1", "us-2"]
    },
    {
      "type": "urltest",
      "tag": "hk-nodes",
      "outbounds": ["hk-1", "hk-2"]
    }
  ]
}
```

### 3. 启用实验性功能

```json
{
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/var/lib/sing-box/cache.db"
    },
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "secret": "your_secret"
    }
  }
}
```

启用 Clash API 后可以通过 Web UI 管理（如 Yacd, Clash Dashboard）。

## 故障排查

### 问题 1: tun0 接口未创建

**症状**: `ip link show tun0` 无输出

**原因**: 
- sing-box 未启动
- 配置文件错误
- 缺少 TUN 权限

**解决**:
```bash
# 检查服务状态
systemctl status sing-box

# 查看日志
journalctl -u sing-box -n 50

# 手动启动测试
sing-box run -c /etc/sing-box/config.json

# 检查内核是否支持 TUN
ls -l /dev/net/tun
# 应存在该设备
```

### 问题 2: 连接节点失败

**症状**: 日志显示 "dial tcp: connection refused" 或超时

**原因**:
- 节点 IP/端口/密码错误
- 节点服务器宕机
- 防火墙拦截

**解决**:
```bash
# 手动测试节点连通性
telnet node.example.com 443

# 检查 DNS 解析
nslookup node.example.com

# 尝试 curl 测试（如果是 HTTPS）
curl -v https://node.example.com
```

### 问题 3: 流量无法通过隧道

**症状**: LAN 客户端访问国外网站失败

**排查**:
```bash
# 1. 容器内测试
ping -I tun0 1.1.1.1

# 2. 检查路由
ip route get 8.8.8.8
# 应显示: via 172.19.0.1 dev tun0

# 3. 检查 nftables SNAT
nft list table inet nat

# 4. 抓包分析
tcpdump -i tun0 -n icmp
```

### 问题 4: 节点自动切换不工作

**症状**: urltest 一直使用同一节点，即使延迟高

**原因**:
- `interval` 设置过长
- `tolerance` 设置过大
- 所有节点都不可达

**解决**:
```bash
# 查看日志中的测速结果
journalctl -u sing-box | grep urltest

# 缩短测试间隔（在配置文件中）
"interval": "1m",
"tolerance": 30

# 重启服务
systemctl restart sing-box
```

## 性能优化

### 1. 调整 MTU

```json
{
  "inbounds": [{
    "type": "tun",
    "mtu": 1400  // 降低 MTU 避免分片
  }]
}
```

### 2. 启用多路复用

对于支持的协议（如 VMess, VLESS）：

```json
{
  "type": "vmess",
  "multiplex": {
    "enabled": true,
    "protocol": "h2mux",
    "max_connections": 4,
    "min_streams": 4,
    "max_streams": 0
  }
}
```

### 3. TCP 优化

```json
{
  "tcp_fast_open": true,
  "tcp_multi_path": false
}
```

## 日常维护

### 更新 sing-box

```bash
# 下载新版本
wget https://github.com/SagerNet/sing-box/releases/download/vX.X.X/sing-box-X.X.X-linux-amd64.tar.gz

# 停止服务
systemctl stop sing-box

# 替换二进制
tar -xzf sing-box-*.tar.gz
cp sing-box-*/sing-box /usr/local/bin/

# 启动服务
systemctl start sing-box
```

### 备份配置

```bash
# 备份配置文件
cp /etc/sing-box/config.json /root/sing-box-config-$(date +%Y%m%d).json.bak
```

### 添加新节点

1. 编辑配置文件
2. 在 `outbounds` 中添加新节点
3. 将新节点 tag 添加到 `urltest` 的 `outbounds` 列表
4. 重新加载: `systemctl reload sing-box`

## 参考资源

- **sing-box 官方文档**: https://sing-box.sagernet.org/
- **配置示例**: https://sing-box.sagernet.org/configuration/
- **协议配置**: https://sing-box.sagernet.org/configuration/outbound/
- **仓库模板**: `network/sing-box-template.json`
