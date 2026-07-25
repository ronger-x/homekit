# OSPF 智能分流维护手册

> 状态：历史参考。OSPF 分流方案已放弃，PaoPaoDNS/PaoPaoGateWay 也已删除。

## 概述

本文档记录 OSPF 智能分流方案的日常维护、监控和故障排查操作。

## 系统架构

- **OSPF 容器**: 192.168.88.250 (PVE VMID 250)
- **RouterOS 网关**: 192.168.88.1
- **OSPF 协议**: OSPFv2 (IPv4) + OSPFv3 (IPv6)
- **隧道**: WireGuard (wg0)
- **路由守护进程**: BIRD 2.x

## 日常监控

### 检查 OSPF 邻居状态

**在 RouterOS 上：**

```routeros
# 查看 OSPF 邻居
/routing/ospf/neighbor/print

# 应显示:
# STATE=Full (正常)
# ROUTER-ID=192.168.88.250
```

状态说明：
- `Full`: 邻居关系正常，路由已同步
- `ExStart`, `Exchange`, `Loading`: 正在同步（短暂状态）
- `Init`, `2-Way`: 邻居发现阶段
- `Down`: 邻居不可达（异常）

**在容器内：**

```bash
birdc show ospf neighbors

# 应显示:
# 192.168.88.1     eth0     Full
```

### 检查路由数量

**在 RouterOS 上：**

```routeros
# 查看 OSPF 路由总数
/ip/route/print count-only where ospf

# 正常应在 12,000+ 条
```

**在容器内：**

```bash
birdc show route count

# 应显示约 20,000+ 条（IPv4 + IPv6）
```

### 检查 WireGuard 隧道

**在容器内：**

```bash
# 查看隧道状态
wg show

# 关键指标:
# - latest handshake: 应在最近 1-2 分钟内
# - transfer: 应有接收和发送数据
```

如果 `latest handshake` 显示很久以前或 `(none)`，隧道可能断开。

重启 WireGuard：

```bash
systemctl restart wg-quick@wg0
wg show
```

### 检查容器服务状态

**在 PVE 主机上：**

```bash
# 查看容器状态
pct status 250

# 查看容器资源使用
pct exec 250 -- free -h
pct exec 250 -- df -h
```

**在容器内：**

```bash
# 检查关键服务
systemctl status bird
systemctl status wg-quick@wg0
systemctl status nftables

# 查看系统日志
journalctl -u bird -n 50
journalctl -u wg-quick@wg0 -n 50
```

### 查看流量统计

**在 RouterOS 上：**

```routeros
# 查看 OSPF 路由的流量统计（需要启用 routing table stats）
/ip/route/print stats where ospf

# 查看接口流量
/interface/monitor-traffic bridge once
```

**在容器内：**

```bash
# 查看 WireGuard 流量
wg show wg0 transfer

# 查看接口流量
ip -s link show wg0
ip -s link show eth0
```

## 更新 IP 列表

中国 IP 地址段会定期变化，建议每季度更新一次。

### 手动更新流程

**1. 在容器内重新生成路由文件：**

```bash
cd /tmp
git clone https://github.com/dndx/nchnroutes.git
cd nchnroutes

# ⚠️ 重要：创建排除列表
cat > /tmp/exclude_ips.txt << 'EOF'
# Tailscale CGNAT 地址段（必须排除！）
100.64.0.0/10

# 如果使用其他 VPN，也需要排除：
# 172.22.0.0/16    # Zerotier
# 10.x.x.x/x       # 其他私有网络
EOF

# 追加代理节点 IP（如果使用 sing-box）
grep '"server"' /etc/sing-box/config.json 2>/dev/null | \
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
  awk '{print $1"/32"}' >> /tmp/exclude_ips.txt

# 或追加 WireGuard 服务器 IP
# echo "<WIREGUARD_SERVER_IP>/32" >> /tmp/exclude_ips.txt

# 生成新的路由文件
python3 nchnroutes.py --exclude-file /tmp/exclude_ips.txt --output bird

# 检查文件
wc -l routes4.conf routes6.conf
```

**⚠️ 关键警告：必须排除的网段**

| 网段 | 用途 | 后果（如不排除） |
|------|------|-----------------|
| `100.64.0.0/10` | **Tailscale/CGNAT** | ❌ Tailscale 完全失联，无法访问设备 |
| `172.22.0.0/16` | Zerotier | ❌ Zerotier 网络中断 |
| `10.0.0.0/8` | 企业 VPN | ❌ VPN 连接断开 |

**为什么必须排除**：
- nchnroutes 将这些段识别为"非中国 IP"
- OSPF 将其宣告给 RouterOS
- RouterOS 将这些流量路由到代理容器
- VPN 流量被错误转发到代理隧道
- **结果：VPN/私有网络完全失联**

**如果忘记排除，紧急恢复**：
```routeros
# 在 RouterOS 上立即禁用 OSPF
/routing/ospf/instance/disable ospf-split-v2
/routing/ospf/instance/disable ospf-split-v3
# 然后重新生成路由表（添加排除），再重新启用
```

**2. 对比变化：**

```bash
# 备份旧文件
cp /etc/bird/routes4.conf /etc/bird/routes4.conf.old
cp /etc/bird/routes6.conf /etc/bird/routes6.conf.old

# 对比差异
diff -u /etc/bird/routes4.conf.old routes4.conf | head -50
```

**3. 修正格式（如果需要）：**

```bash
# 确保路由指向 wg0 接口
sed -i 's/via [0-9.]\+;/via "wg0";/g' routes4.conf
sed -i 's/via [0-9a-f:]\+;/via "wg0";/g' routes6.conf
```

**4. 更新配置文件：**

```bash
# 复制到 BIRD 配置目录
cp routes4.conf routes6.conf /etc/bird/
chmod 644 /etc/bird/routes4.conf /etc/bird/routes6.conf
```

**5. 重新加载 BIRD 配置：**

```bash
# 检查配置语法
bird -p -c /etc/bird/bird.conf

# 重新加载（不中断连接）
birdc configure

# 验证
birdc show route count
```

**6. 验证路由更新：**

在 RouterOS 上检查路由数量：

```routeros
/ip/route/print count-only where ospf
```

数量可能略有变化（增加或减少几十到几百条）。

### 自动化更新（可选）

可以配置 cron 任务在容器内定期更新：

```bash
cat > /root/update-routes.sh << 'EOF'
#!/bin/bash
set -e

WIREGUARD_SERVER="<WIREGUARD_SERVER_IP>"
BACKUP_DIR="/etc/bird/backups"
NCHN_DIR="/tmp/nchnroutes-update"

mkdir -p $BACKUP_DIR

# 备份当前路由文件
cp /etc/bird/routes4.conf $BACKUP_DIR/routes4.conf.$(date +%Y%m%d)
cp /etc/bird/routes6.conf $BACKUP_DIR/routes6.conf.$(date +%Y%m%d)

# 克隆或更新 nchnroutes
if [ -d "$NCHN_DIR" ]; then
    cd $NCHN_DIR && git pull
else
    git clone https://github.com/dndx/nchnroutes.git $NCHN_DIR
    cd $NCHN_DIR
fi

# 生成新路由
python3 nchnroutes.py --exclude $WIREGUARD_SERVER/32 --output bird

# 修正格式
sed -i 's/via [0-9.]\+;/via "wg0";/g' routes4.conf
sed -i 's/via [0-9a-f:]\+;/via "wg0";/g' routes6.conf

# 更新文件
cp routes4.conf routes6.conf /etc/bird/

# 重新加载 BIRD
birdc configure

logger "OSPF routes updated successfully"
EOF

chmod +x /root/update-routes.sh
```

配置 cron（每月 1 号凌晨 3 点执行）：

```bash
crontab -e

# 添加:
0 3 1 * * /root/update-routes.sh >> /var/log/route-update.log 2>&1
```

## 手动操作

### 临时禁用 OSPF

有时需要临时禁用 OSPF（如调试、维护），但不停止容器。

**方法 1: 在容器内禁用 BIRD OSPF 协议**

```bash
# 进入 BIRD 控制台
birdc

# 禁用 OSPF
disable default_v2
disable default_v3

# 查看状态
show protocols

# 退出
quit
```

此时 RouterOS 会在 40 秒内（Dead 超时）撤销所有 OSPF 路由，流量回退到运营商。

**重新启用：**

```bash
birdc
enable default_v2
enable default_v3
quit
```

**方法 2: 在 RouterOS 上禁用 OSPF**

```routeros
# 禁用 OSPF 接口模板
/routing ospf interface-template disable [find comment~"OSPF split"]

# 重新启用
/routing ospf interface-template enable [find comment~"OSPF split"]
```

### 强制某些 IP 走直连

如果某些国外 IP 不希望走隧道（如 CDN 节点），可以从路由列表中排除。

**临时排除（容器内）：**

```bash
# 编辑路由文件，删除或注释相应行
vi /etc/bird/routes4.conf

# 例如排除 1.2.3.0/24
# 搜索并删除: route 1.2.3.0/24 via "wg0";

# 重新加载
birdc configure
```

**永久排除：**

在下次更新 IP 列表时，使用 `--exclude` 参数：

```bash
python3 nchnroutes.py \
  --exclude <WIREGUARD_SERVER_IP>/32 \
  --exclude 1.2.3.0/24 \
  --output bird
```

### 强制某些 IP 走隧道

如果某些国内 IP 需要走隧道，可以手动添加到路由文件。

**在容器内：**

```bash
# 编辑路由文件，添加路由
cat >> /etc/bird/routes4.conf << 'EOF'
route 114.114.114.0/24 via "wg0";
EOF

# 重新加载
birdc configure
```

验证：

```bash
birdc show route 114.114.114.0/24
```

在 RouterOS 上应看到该路由通过 OSPF 学习。

## 故障排查

### 场景 1: OSPF 邻居无法建立

**症状：**
- RouterOS 上 `/routing/ospf/neighbor/print` 无输出
- 或邻居状态一直是 `Init`, `2-Way`，不变为 `Full`

**可能原因：**
1. 网络不通
2. OSPF 认证密码不匹配
3. 防火墙拦截 OSPF 包
4. BIRD 未运行或配置错误

**排查步骤：**

**1. 检查网络连通性**

从 RouterOS：
```routeros
/ping 192.168.88.250 count=5
```

从容器：
```bash
ping -c 3 192.168.88.1
```

如果不通，检查：
- 容器网络配置（`ip addr show eth0`）
- PVE 网桥配置
- 物理网络连接

**2. 检查 BIRD 状态**

在容器内：
```bash
systemctl status bird

# 如果未运行
systemctl start bird

# 查看日志
journalctl -u bird -n 50
```

常见错误：
- `Configuration file error`: 配置文件语法错误，运行 `bird -p -c /etc/bird/bird.conf` 检查
- `Cannot open listening socket`: 端口被占用或权限问题

**3. 检查 OSPF 认证密码**

在容器内查看：
```bash
grep "password" /etc/bird/bird.conf
```

在 RouterOS 查看：
```routeros
/routing ospf interface-template print detail where comment~"OSPF split"
```

确保 `auth-key` 与 BIRD 的 `password` 一致。

**4. 检查防火墙**

在 RouterOS 上：
```routeros
# 查看是否有规则拦截 OSPF (协议 89)
/ip/firewall/filter/print where protocol=ospf

# 如果有 drop 规则，临时禁用测试
/ip/firewall/filter/disable [find where protocol=ospf and action=drop]
```

在容器内：
```bash
# 查看 nftables 规则
nft list ruleset | grep -i ospf

# OSPF 通常不需要特殊规则（使用组播地址）
```

**5. 抓包分析**

在容器内：
```bash
# 抓取 OSPF 包（协议 89）
tcpdump -i eth0 proto ospf -v

# 应看到 Hello 包
```

如果看不到任何包，说明 RouterOS 没有发送 OSPF Hello。

### 场景 2: 路由数量不对或未学习

**症状：**
- RouterOS 上 `/ip/route/print count-only where ospf` 返回 0
- 或数量远少于预期（正常 12,000+）

**可能原因：**
1. OSPF 邻居未建立（先解决场景 1）
2. BIRD 静态路由未加载
3. OSPF 导出配置错误
4. RouterOS 路由表冲突

**排查步骤：**

**1. 确认邻居状态为 Full**

```routeros
/routing/ospf/neighbor/print
```

必须是 `Full`，否则先解决邻居问题。

**2. 检查 BIRD 静态路由**

在容器内：
```bash
birdc show static | head -20
birdc show route count
```

如果静态路由为 0 或很少，检查 routes4.conf 文件：
```bash
wc -l /etc/bird/routes4.conf
head /etc/bird/routes4.conf
```

如果文件为空或格式错误，重新生成。

**3. 检查 BIRD OSPF 导出**

在容器内：
```bash
# 查看导出到 OSPF 的路由
birdc show route export default_v2 | head -20

# 应看到大量路由
```

如果为空，检查 BIRD 配置中的 `export` 语句：
```bash
grep "export" /etc/bird/bird.conf

# 应为: export where source = RTS_STATIC;
```

**4. 检查 RouterOS 路由表**

```routeros
# 查看是否有冲突的静态路由
/ip/route/print where dst-address~"1.0.0.0"

# 如果有优先级更高的静态路由，OSPF 路由不会生效
# distance 越小优先级越高，OSPF 默认 110
```

### 场景 3: 部分国外网站无法访问

**症状：**
- Google、YouTube 等能访问
- 但某些特定国外网站无法访问或很慢

**可能原因：**
1. 隧道带宽不足或不稳定
2. 某些 IP 被运营商封锁
3. DNS 解析问题
4. MTU 问题导致部分大包丢失

**排查步骤：**

**1. 测试隧道连通性**

在容器内：
```bash
# 测试隧道延迟
ping -I wg0 -c 10 8.8.8.8

# 测试隧道带宽
curl -o /dev/null -w "Speed: %{speed_download} bytes/sec\n" https://某大文件URL
```

**2. 测试 DNS 解析**

在 LAN 客户端：
```bash
# 解析域名
nslookup 问题网站.com

# 检查返回的 IP 是否正确
```

如果解析错误，检查 DNS 配置（192.168.88.243 AdGuard Home）。

**3. 测试 MTU**

在 LAN 客户端：
```bash
# 测试不同包大小
ping -M do -s 1400 8.8.8.8
ping -M do -s 1450 8.8.8.8
ping -M do -s 1472 8.8.8.8

# 如果大包丢失，说明 MTU 问题
```

在容器内调整 WireGuard MTU：
```bash
# 编辑配置
vi /etc/wireguard/wg0.conf

# 修改 MTU（尝试 1380、1400、1420）
MTU = 1400

# 重启
systemctl restart wg-quick@wg0
```

**4. 检查特定 IP 路由**

在 RouterOS 上：
```routeros
# 查看问题网站 IP 的路由
/ip/route/print where dst-address~"具体IP"

# 应通过 192.168.88.250
```

在容器内：
```bash
# 查看路由
ip route get 具体IP

# 应通过 wg0
```

### 场景 4: 国内网站变慢

**症状：**
- 百度、淘宝等国内网站访问延迟高
- 或某些国内网站走了隧道

**可能原因：**
1. 国内 IP 被错误地包含在非中国列表中
2. DNS 返回了国外 CDN IP

**排查步骤：**

**1. 测试国内网站路由**

在 LAN 客户端：
```bash
traceroute baidu.com
```

如果第二跳是 `192.168.88.250`，说明走了隧道（错误）。

**2. 查看域名解析的 IP**

```bash
nslookup baidu.com
```

记下返回的 IP。

**3. 在 RouterOS 上检查该 IP 路由**

```routeros
/ip/route/print where dst-address~"记录的IP"
```

如果显示 `ospf` 标记，说明该 IP 被错误地宣告为国外 IP。

**4. 从路由列表中排除该 IP**

在容器内：
```bash
# 编辑路由文件
vi /etc/bird/routes4.conf

# 搜索并删除该 IP 段
# 例如删除: route 1.2.3.0/24 via "wg0";

# 或者添加到国内静态路由（如果 nchnroutes 有误）
cat >> /etc/bird/bird.conf << 'EOF'

# Override: Force specific IP to go direct
protocol static china_override {
    ipv4;
    route 1.2.3.0/24 reject;  # 拒绝宣告此路由
}
EOF

# 重新加载
birdc configure
```

**5. 下次更新时排除**

在生成路由时使用 `--exclude`：
```bash
python3 nchnroutes.py \
  --exclude <WIREGUARD_SERVER_IP>/32 \
  --exclude 1.2.3.0/24 \
  --output bird
```

### 场景 5: 容器无法启动

**症状：**
- `pct start 250` 失败
- 或容器启动后 BIRD 无法运行

**可能原因：**
1. 磁盘空间不足
2. 配置文件损坏
3. 内存不足
4. PVE 主机资源问题

**排查步骤：**

**1. 检查 PVE 资源**

```bash
# 磁盘空间
df -h
lvs

# 内存
free -h

# CPU
top
```

**2. 查看容器启动日志**

```bash
pct start 250
journalctl -xe | tail -50
```

**3. 尝试进入容器**

```bash
pct enter 250

# 如果能进入，手动启动服务
systemctl status bird
systemctl start bird
```

**4. 检查配置文件**

```bash
# 检查 BIRD 配置语法
bird -p -c /etc/bird/bird.conf

# 检查 WireGuard 配置
wg-quick up wg0
```

**5. 恢复备份**

如果配置文件损坏，从备份恢复：
```bash
cp /etc/bird/backups/routes4.conf.最近日期 /etc/bird/routes4.conf
systemctl restart bird
```

### 场景 6: WireGuard 隧道频繁断开

**症状：**
- `wg show` 显示 `latest handshake` 时间很久以前
- 或频繁出现 `(none)`

**可能原因：**
1. NAT 超时导致 UDP 连接断开
2. 网络不稳定
3. 服务器端问题
4. ISP 限制 UDP

**解决方案：**

**1. 调整 PersistentKeepalive**

编辑 WireGuard 配置：
```bash
vi /etc/wireguard/wg0.conf

# 修改 PersistentKeepalive 为更短时间（秒）
PersistentKeepalive = 15

# 重启
systemctl restart wg-quick@wg0
```

**2. 监控并自动重启**

创建监控脚本：
```bash
cat > /root/monitor-wg.sh << 'EOF'
#!/bin/bash
# 检查 WireGuard 握手时间，超过 3 分钟则重启

LAST_HANDSHAKE=$(wg show wg0 latest-handshakes | awk '{print $2}')
CURRENT_TIME=$(date +%s)
DIFF=$((CURRENT_TIME - LAST_HANDSHAKE))

if [ $DIFF -gt 180 ]; then
    logger "WireGuard handshake timeout, restarting..."
    systemctl restart wg-quick@wg0
fi
EOF

chmod +x /root/monitor-wg.sh

# 添加到 cron（每 5 分钟检查）
crontab -e
# 添加: */5 * * * * /root/monitor-wg.sh
```

## 性能监控

### 查看 OSPF 性能指标

**在 RouterOS 上：**

```routeros
# 查看 OSPF 路由处理时间
/routing/ospf/instance/print detail

# 查看路由表更新频率
/log/print where topics~"ospf"
```

### 查看隧道性能

**在容器内：**

```bash
# 实时监控流量
watch -n 1 'wg show wg0 transfer'

# 查看接口统计
ip -s link show wg0
ip -s link show eth0

# 使用 iftop（需要安装）
apt install iftop
iftop -i wg0
```

### 查看容器资源使用

**在 PVE 上：**

```bash
# CPU 和内存使用
pct exec 250 -- top -bn1 | head -20

# 磁盘 I/O
pct exec 250 -- iostat

# 网络流量
pct exec 250 -- iftop -t -s 10
```

### 设置告警（可选）

可以配置 Prometheus + Grafana 监控 OSPF 状态：

1. 在容器内安装 node_exporter
2. 导出 BIRD 指标（使用 bird_exporter）
3. 配置 Prometheus 抓取
4. 在 Grafana 中创建仪表板

或使用简单的脚本告警：

```bash
cat > /root/alert-ospf.sh << 'EOF'
#!/bin/bash
# 检查 OSPF 邻居状态，如果 Down 则发送告警

NEIGHBOR_COUNT=$(birdc show ospf neighbors | grep -c "Full")

if [ $NEIGHBOR_COUNT -eq 0 ]; then
    # 发送告警（可以是邮件、webhook、短信等）
    logger "ALERT: OSPF neighbor down!"
    # curl -X POST webhook_url -d "OSPF neighbor down"
fi
EOF

chmod +x /root/alert-ospf.sh

# 添加到 cron（每分钟检查）
crontab -e
# 添加: * * * * * /root/alert-ospf.sh
```

## 备份与恢复

### 备份配置

**备份容器配置文件：**

```bash
# 在 PVE 主机上
mkdir -p /root/ospf-backups
pct exec 250 -- tar czf - /etc/bird /etc/wireguard /etc/nftables.conf > \
  /root/ospf-backups/ospf-config-$(date +%Y%m%d).tar.gz
```

**备份 RouterOS 配置：**

```routeros
# 导出完整配置
/export file=ospf-backup

# 下载到本地
# scp admin@192.168.88.1:/ospf-backup.rsc ./
```

### 恢复配置

**恢复容器配置：**

```bash
# 在 PVE 主机上
pct exec 250 -- tar xzf /root/ospf-backups/ospf-config-YYYYMMDD.tar.gz -C /

# 重启服务
pct exec 250 -- systemctl restart bird wg-quick@wg0 nftables
```

**恢复 RouterOS 配置：**

```routeros
# 导入配置
/import ospf-backup.rsc
```

### 容器克隆（灾难恢复）

在 PVE 上克隆容器作为备份：

```bash
# 停止容器
pct stop 250

# 克隆为新容器
pct clone 250 251 --full --hostname ospf-router-backup

# 启动原容器
pct start 250

# 备份容器可以保持关闭状态
```

## 升级维护

### 升级 BIRD

```bash
# 在容器内
apt update
apt list --upgradable | grep bird

# 升级
apt upgrade bird2

# 检查版本
bird --version

# 重启
systemctl restart bird
```

### 升级 WireGuard

```bash
# 在容器内
apt upgrade wireguard-tools

# 重启
systemctl restart wg-quick@wg0
```

### 升级容器系统

```bash
# 在容器内
apt update
apt upgrade

# 或完整升级
apt full-upgrade

# 重启容器
reboot
```

## 迁移到新容器

如果需要重建容器或迁移到新硬件：

**1. 在新容器上重复部署流程**

参考 `network/ospf-split-routing-deployment.md`

**2. 复制配置文件**

```bash
# 从旧容器导出
pct exec 250 -- tar czf /tmp/ospf-config.tar.gz \
  /etc/bird /etc/wireguard /etc/nftables.conf

# 复制到 PVE
pct pull 250 /tmp/ospf-config.tar.gz /tmp/

# 导入到新容器
pct push 251 /tmp/ospf-config.tar.gz /tmp/
pct exec 251 -- tar xzf /tmp/ospf-config.tar.gz -C /
```

**3. 修改 IP 地址**

如果新容器使用不同 IP（如 192.168.88.251）：

```bash
# 在新容器内修改 BIRD router-id
vi /etc/bird/bird.conf
# 修改: router id 192.168.88.251;

# 重启服务
systemctl restart bird
```

**4. 在 RouterOS 上更新配置**

```routeros
# 如果使用新 IP，更新 OSPF 配置
# （通常不需要，OSPF 会自动发现）
```

**5. 停止旧容器，启动新容器**

```bash
pct stop 250
pct start 251
```

## 常用命令速查

### 容器管理

```bash
# 启动/停止/重启容器
pct start 250
pct stop 250
pct reboot 250

# 查看状态
pct status 250

# 进入容器
pct enter 250

# 从宿主机执行容器内命令
pct exec 250 -- <command>
```

### BIRD 控制

```bash
# 进入 BIRD 控制台
birdc

# 常用命令（在 birdc 内）
show status
show protocols
show ospf neighbors
show route count
show route export default_v2
configure  # 重新加载配置
disable default_v2  # 禁用协议
enable default_v2   # 启用协议
```

### WireGuard 控制

```bash
# 查看状态
wg show

# 启动/停止
systemctl start wg-quick@wg0
systemctl stop wg-quick@wg0

# 手动启动/停止（不使用 systemd）
wg-quick up wg0
wg-quick down wg0
```

### RouterOS OSPF

```routeros
# 查看邻居
/routing/ospf/neighbor/print

# 查看路由
/ip/route/print where ospf

# 查看 OSPF 实例
/routing/ospf/instance/print

# 查看 OSPF 接口
/routing/ospf/interface-template/print

# 测试路由
/tool/traceroute 8.8.8.8
```

## 参考资源

- **BIRD 官方文档**: https://bird.network.cz/?get_doc
- **WireGuard 文档**: https://www.wireguard.com/quickstart/
- **RouterOS OSPF**: https://help.mikrotik.com/docs/display/ROS/OSPF
- **nchnroutes**: https://github.com/dndx/nchnroutes
- **本地部署文档**: `network/ospf-split-routing-deployment.md`
- **配置模板**: `network/bird-ospf-template.conf`, `network/wireguard-template.conf`
