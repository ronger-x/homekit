# OSPF + sing-box 快速部署指南

## 部署概述

本指南使用自动化脚本在 PVE (192.168.88.228) 上部署 OSPF + sing-box 智能分流方案。

## 前置准备

- ✅ PVE 主机：192.168.88.228
- ✅ sing-box 订阅：配置在 `.env` 文件的 `SINGBOX_SUBSCRIPTION_URL` 变量
- ✅ 订阅应包含多个代理节点（如 VMess、Shadowsocks、Trojan 等）
- ✅ 网络环境：192.168.88.0/24

## 配置 .env 文件

在仓库根目录创建 `.env` 文件（从 `.env.example` 复制）：

```bash
cp .env.example .env
vi .env
```

必须配置以下变量：

```bash
# OSPF 认证密码（强密码，RouterOS 和容器必须一致）
OSPF_PASSWORD=YourStrongOSPFPassword123

# sing-box 订阅 URL
SINGBOX_SUBSCRIPTION_URL=http://your-subscription-service/path/to/subscription?target=sing-box
```

## 自动部署步骤

### Step 1: 准备部署脚本

从本地上传脚本和配置到 PVE：

```bash
# 在本地 Windows 机器上（通过 Git Bash 或 WSL）
scp E:\workspace\homekit\deploy-ospf-singbox.sh root@192.168.88.228:/root/
scp E:\workspace\homekit\.env root@192.168.88.228:/root/
```

或手动复制脚本内容到 PVE。

### Step 2: 验证配置

SSH 登录 PVE 并检查 .env 文件：

```bash
ssh root@192.168.88.228
cd /root
cat .env
```

确保以下变量已正确设置：
- `OSPF_PASSWORD`: 强密码（后续 RouterOS 配置需要相同密码）
- `SINGBOX_SUBSCRIPTION_URL`: 有效的订阅 URL

### Step 3: 执行部署脚本

```bash
cd /root
chmod +x deploy-ospf-singbox.sh
./deploy-ospf-singbox.sh
```

脚本会自动完成：
- ✅ 创建 LXC 容器（VMID 250, IP 192.168.88.250）
- ✅ 安装必要软件包（bird2, nftables, curl 等）
- ✅ 安装 sing-box 1.8.0
- ✅ 下载订阅并配置 sing-box
- ✅ 创建 systemd 服务
- ✅ 配置 nftables NAT 规则
- ✅ 解析节点 IP 并生成排除列表
- ✅ 下载 nchnroutes 并生成非中国路由表
- ✅ 配置 BIRD OSPF

**预计时间**: 5-10 分钟

## 手动配置 RouterOS OSPF

脚本执行完成后，会输出需要在 RouterOS 上执行的命令。

### 登录 RouterOS

```bash
ssh admin@192.168.88.1
```

### 配置 OSPFv2 (IPv4)

```routeros
/routing ospf instance add disabled=no name=ospf-split-v2 router-id=192.168.88.1

/routing ospf area add disabled=no instance=ospf-split-v2 name=backbone-v2

/routing ospf interface-template add \
  area=backbone-v2 \
  auth=md5 \
  auth-id=1 \
  auth-key="YourStrongPassword" \
  cost=10 \
  disabled=no \
  interfaces=bridge \
  networks=192.168.88.0/24 \
  priority=10 \
  comment="OSPF split routing"
```

**注意**: 将 `YourStrongPassword` 替换为脚本中设置的密码。

### 配置 OSPFv3 (IPv6)

```routeros
/routing ospf instance add disabled=no name=ospf-split-v3 router-id=192.168.88.1 version=3

/routing ospf area add disabled=no instance=ospf-split-v3 name=backbone-v3

/routing ospf interface-template add \
  area=backbone-v3 \
  cost=10 \
  disabled=no \
  interfaces=bridge \
  priority=10 \
  comment="OSPFv3 split routing"
```

### 验证 OSPF 邻居

```routeros
/routing/ospf/neighbor/print
```

**预期输出**:
```
# INSTANCE       AREA         ADDRESS          ROUTER-ID        STATE
0 ospf-split-v2  backbone-v2  192.168.88.250   192.168.88.250   Full
1 ospf-split-v3  backbone-v3  fe80::xxxx...    192.168.88.250   Full
```

**关键**: `STATE` 必须是 `Full`！

### 验证路由学习

```routeros
# 查看 OSPF 路由数量
/ip/route/print count-only where ospf

# 应显示约 12,000+ 条
```

查看部分路由：

```routeros
/ip/route/print where ospf | head
```

### 测试路由

```routeros
# 测试国外 IP（应通过 192.168.88.250）
/tool/traceroute 8.8.8.8

# 测试国内 IP（应直连）
/tool/traceroute 223.5.5.5
```

## 测试验证

### 1. 容器内测试

进入容器：

```bash
# 在 PVE 上
pct enter 250
```

测试隧道：

```bash
# 查看 TUN 接口
ip link show tun0
ip addr show tun0

# 查看 sing-box 状态
systemctl status sing-box
journalctl -u sing-box -n 30

# 测试通过 tun0 访问外网
ping -I tun0 -c 3 1.1.1.1

# 测试路由
ip route get 8.8.8.8  # 应通过 tun0
ip route get 223.5.5.5  # 应通过 eth0 到 192.168.88.1
```

### 2. LAN 客户端测试

在局域网任意设备：

```bash
# Windows
tracert 8.8.8.8
tracert baidu.com

# Linux/macOS
traceroute 8.8.8.8
traceroute baidu.com

# 测试访问
curl -I https://www.google.com
curl -I https://www.baidu.com
```

**预期**:
- `8.8.8.8` 第一跳是 `192.168.88.1`，第二跳是 `192.168.88.250`
- `baidu.com` 不经过 `.250`

### 3. 故障切换测试

模拟容器宕机：

```bash
# 在 PVE 上
pct stop 250
```

在 LAN 客户端立即测试：

```bash
ping 1.1.1.1
# 前 10-40 秒可能丢包，之后恢复（走运营商直连）
```

重启容器：

```bash
pct start 250
# 等待 10-20 秒，OSPF 重新收敛
```

## 移除旧的 PBR 配置

**确认 OSPF 工作正常后**，清理旧的 Mangle 策略路由：

SSH 登录 RouterOS：

```routeros
# 备份当前配置
/export file=backup-before-ospf

# 移除 Mangle 规则
/ip/firewall/mangle/remove [find comment~"overseas"]

# 移除策略路由表
/ip/route/remove [find routing-table=via-openclash]
/routing/table/remove [find name=via-openclash]

# 可选：移除 cnip 地址列表（保留一段时间以备回退）
# /ip/firewall/address-list/remove [find list=cnip]

# 验证 Fast Path 恢复
/ip/settings/print
```

## 完成检查清单

- [ ] LXC 容器运行正常（`pct status 250` 显示 running）
- [ ] sing-box 运行正常（容器内 `systemctl status sing-box` 显示 active）
- [ ] TUN 接口已创建（容器内 `ip link show tun0` 显示 UP）
- [ ] BIRD 运行正常（容器内 `systemctl status bird` 显示 active）
- [ ] OSPF 邻居状态为 Full（RouterOS `/routing/ospf/neighbor/print`）
- [ ] RouterOS 学到约 12,000+ 条路由（`/ip/route/print count-only where ospf`）
- [ ] 国外 IP traceroute 经过 192.168.88.250
- [ ] 国内 IP traceroute 不经过 192.168.88.250
- [ ] Google、Baidu 等网站都能访问
- [ ] 容器重启后自动恢复（故障切换测试通过）
- [ ] 旧的 PBR 配置已移除

## 常见问题

### Q1: OSPF 邻居无法建立（State 不是 Full）

**检查**:
1. 容器网络连通性：`ping 192.168.88.250`
2. BIRD 状态：容器内 `systemctl status bird`
3. OSPF 密码是否一致
4. RouterOS 防火墙是否拦截 OSPF (协议 89)

### Q2: sing-box 节点连接失败

**检查**:
```bash
# 容器内查看日志
journalctl -u sing-box -n 50

# 测试节点连通性
nslookup a.orcl.cc 8.8.8.8
ping -c 3 <节点IP>
```

### Q3: 路由数量为 0 或很少

**检查**:
1. OSPF 邻居必须是 Full 状态
2. 容器内 `birdc show route count` 查看路由数量
3. 容器内 `birdc show route export default_v2` 查看导出的路由

### Q4: 隧道流量无法通过

**检查**:
```bash
# 容器内
ping -I tun0 1.1.1.1  # 测试隧道
nft list table inet nat  # 检查 SNAT 规则
sysctl net.ipv4.ip_forward  # 应返回 1
```

## 日常维护

参考以下文档：
- `network/ospf-split-routing-maintenance.md` - 维护手册
- `network/sing-box-configuration-guide.md` - sing-box 配置指南

## 相关文档

- 部署文档: `network/ospf-split-routing-deployment.md`
- 维护手册: `network/ospf-split-routing-maintenance.md`
- sing-box 指南: `network/sing-box-configuration-guide.md`
