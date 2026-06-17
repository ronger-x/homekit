# RouterOS 策略路由配置 - 国内直连海外走代理

## 方案说明

使用 RouterOS 策略路由实现智能分流，避免全网流量经过代理设备导致国内访问变慢。

### 流量路径

```
LAN 客户端 (192.168.88.0/24)
    ↓ 网关: 192.168.88.1 (RouterOS)
RouterOS 策略路由判断
    ├─ 目标 IP 在中国 (cnip 列表) → 直连（默认路由）
    └─ 目标 IP 在海外 (!cnip) → 转发到 192.168.88.169 (OpenClash)
```

### 核心机制

1. **IP 地址列表**: 维护 4,283 条中国 IP 段 (`/ip/firewall/address-list list=cnip`)
2. **Mangle 标记**: 目标 IP 不在 cnip 列表的流量标记为 `via-openclash`
3. **路由表**: 标记的流量使用专用路由，网关指向 192.168.88.169

### 优势

- ✅ 国内网站直连，延迟不增加
- ✅ 海外网站自动走 OpenClash 代理
- ✅ 不修改 DHCP 网关配置
- ✅ 对客户端完全透明
- ✅ 配置后立即生效，无需客户端重启

## 部署步骤

### 1. 上传配置文件

```bash
# 从本地上传（已完成）
scp network/routeros-cn-policy-full.rsc admin@192.168.88.1:/
```

### 2. SSH 登录 RouterOS

```bash
ssh admin@192.168.88.1
```

### 3. 导入配置

```bash
# 查看文件
/file/print

# 导入配置（约需 1-2 分钟）
/import routeros-cn-policy-full.rsc

# 观察日志
/log/print where message~"中国 IP"
```

### 4. 验证配置

```bash
# 检查地址列表数量（应该约 4,286 条：4,283 CN IP + 3 私网段）
/ip/firewall/address-list/print count-only where list=cnip

# 查看 Mangle 规则
/ip/firewall/mangle/print where comment~"海外"

# 查看路由表
/ip/route/print where routing-mark=via-openclash

# 查看详细信息
/ip/firewall/address-list/print where list=cnip
```

### 5. 测试连通性

```bash
# 测试海外 IP（应该经过 88.169）
/tool/traceroute 8.8.8.8

# 测试国内 IP（应该直连）
/tool/traceroute 223.5.5.5

# 测试域名（先 DNS 解析，再路由）
/tool/traceroute baidu.com
/tool/traceroute google.com
```

## 客户端测试

### Windows

```cmd
# 查看路由
tracert 8.8.8.8
tracert baidu.com

# 测试访问
curl -v https://www.google.com
curl -v https://www.baidu.com
```

### Linux/macOS

```bash
traceroute 8.8.8.8
traceroute baidu.com

curl -I https://www.google.com
curl -I https://www.baidu.com
```

## 配置详解

### 1. 地址列表 (Address List)

```bash
# 查看中国 IP 列表
/ip/firewall/address-list/print where list=cnip

# 手动添加特定 IP 到 cnip（强制直连）
/ip/firewall/address-list/add list=cnip address=1.2.3.4 comment="Custom-Direct"

# 移除特定 IP（强制走代理）
/ip/firewall/address-list/remove [find where address=1.2.3.4]
```

### 2. Mangle 规则

```bash
# 查看规则
/ip/firewall/mangle/print detail where comment~"海外"

# 规则解释：
# - chain=prerouting: 在路由决策前处理
# - src-address=192.168.88.0/24: 仅处理 LAN 客户端流量
# - dst-address-list=!cnip: 目标 IP 不在 cnip 列表中（!表示取反）
# - action=mark-routing: 标记路由
# - new-routing-mark=via-openclash: 标记名称
```

### 3. 路由表

```bash
# 查看路由
/ip/route/print where routing-mark=via-openclash

# 规则解释：
# - dst-address=0.0.0.0/0: 匹配所有目标（默认路由）
# - gateway=192.168.88.169: 网关为 OpenClash
# - routing-mark=via-openclash: 仅对标记的流量生效
# - distance=1: 路由优先级（数值越小优先级越高）
```

## 故障排查

### 问题 1: 海外网站无法访问

**可能原因**: 192.168.88.169 (OpenClash) 未运行或配置错误

**排查步骤**:
```bash
# 检查 88.169 是否可达
/ping 192.168.88.169 count=5

# 检查路由表
/ip/route/print where routing-mark=via-openclash

# 在客户端测试
ping 192.168.88.169
curl -x http://192.168.88.169:7890 https://www.google.com  # 如果 OpenClash 开启了 HTTP 代理
```

**解决**: 确保 OpenClash 正常运行并配置透明代理模式

### 问题 2: 国内网站访问变慢

**可能原因**: 国内 IP 列表不完整，部分 IP 被错误路由到 OpenClash

**排查步骤**:
```bash
# 测试国内网站的 IP
/tool/traceroute baidu.com

# 检查该 IP 是否在 cnip 列表中
/ip/firewall/address-list/print where list=cnip and address~"目标IP"

# 如果不在列表中，手动添加
/ip/firewall/address-list/add list=cnip address=目标IP/32 comment="Baidu"
```

### 问题 3: 所有流量都走代理或都不走代理

**可能原因**: Mangle 规则未生效

**排查步骤**:
```bash
# 检查 Mangle 规则
/ip/firewall/mangle/print where comment~"海外"

# 查看规则统计（Bytes 和 Packets 应该有增长）
/ip/firewall/mangle/print stats where comment~"海外"

# 临时禁用规则测试
/ip/firewall/mangle/disable [find where comment~"海外"]

# 重新启用
/ip/firewall/mangle/enable [find where comment~"海外"]
```

### 问题 4: 配置导入失败

**可能原因**: RouterOS 存储空间不足或版本不兼容

**解决**:
```bash
# 检查存储空间
/system/resource/print

# 检查 RouterOS 版本（需要 7.x）
/system/package/print

# 分批导入（手动执行）
# 将 routeros-cn-policy-full.rsc 拆分为多个小文件
```

## 维护操作

### 更新中国 IP 列表

中国 IP 地址段会随时间变化，建议每季度更新一次：

```bash
# 1. 在本地重新生成配置文件
cd /tmp
curl -sL https://ispip.clang.cn/all_cn.txt -o cn-ip.txt

# 2. 生成新的 RouterOS 配置（使用项目脚本）
# ... （参考初始部署流程）

# 3. 上传并导入
scp routeros-cn-policy-full.rsc admin@192.168.88.1:/
ssh admin@192.168.88.1
/import routeros-cn-policy-full.rsc
```

### 添加自定义规则

**强制特定 IP 走代理**:
```bash
# 方法 1: 从 cnip 列表中移除（如果存在）
/ip/firewall/address-list/remove [find where list=cnip and address=1.2.3.4/32]

# 方法 2: 创建优先级更高的 Mangle 规则
/ip/firewall/mangle/add \
  chain=prerouting \
  src-address=192.168.88.0/24 \
  dst-address=1.2.3.4 \
  action=mark-routing \
  new-routing-mark=via-openclash \
  place-before=0 \
  comment="强制代理-自定义"
```

**强制特定设备所有流量走代理**:
```bash
/ip/firewall/mangle/add \
  chain=prerouting \
  src-address=192.168.88.100 \
  action=mark-routing \
  new-routing-mark=via-openclash \
  passthrough=yes \
  comment="设备88.100强制代理"
```

### 临时禁用策略路由

```bash
# 禁用 Mangle 规则（流量恢复直连）
/ip/firewall/mangle/disable [find where comment~"海外"]

# 重新启用
/ip/firewall/mangle/enable [find where comment~"海外"]
```

### 完全移除配置

```bash
/ip/firewall/address-list/remove [find list=cnip]
/ip/firewall/mangle/remove [find comment~"海外"]
/ip/route/remove [find routing-mark=via-openclash]

:log info "策略路由配置已完全移除"
```

## 性能影响

### 资源消耗

- **内存**: 约 2-3 MB（4,286 条地址列表条目）
- **CPU**: 每个数据包需查询地址列表，增加约 < 1% CPU 使用率
- **延迟**: 
  - 国内流量：无影响（直连）
  - 海外流量：增加约 1-2ms（策略路由查询 + 转发到 88.169）

### 监控命令

```bash
# 查看 Mangle 规则统计
/ip/firewall/mangle/print stats where comment~"海外"

# 查看路由表命中次数
/ip/route/print stats where routing-mark=via-openclash

# 监控 CPU 和内存
/system/resource/print
```

## 高级优化

### 1. 使用域名列表（结合 DNS）

如果 DNS 已配置智能分流（MosDNS + AdGuard Home），可以基于 DNS 查询结果动态添加 IP：

```bash
# 创建动态地址列表（DNS 查询结果自动添加）
/ip/firewall/address-list/add list=gfw-domains address=0.0.0.0 timeout=none

# 配合 DNS 静态规则（已在 RouterOS DNS 中配置 GFW 域名）
# 当查询 GFW 域名时，解析结果自动加入 gfw-domains 列表
```

### 2. 分级路由（多个代理节点）

```bash
# 为不同目标使用不同网关
/ip/firewall/mangle/add chain=prerouting dst-address-list=us-ip action=mark-routing new-routing-mark=via-us-proxy
/ip/firewall/mangle/add chain=prerouting dst-address-list=jp-ip action=mark-routing new-routing-mark=via-jp-proxy

/ip/route/add dst-address=0.0.0.0/0 gateway=192.168.88.170 routing-mark=via-us-proxy
/ip/route/add dst-address=0.0.0.0/0 gateway=192.168.88.171 routing-mark=via-jp-proxy
```

### 3. 自动故障转移

```bash
# 配置多个网关，主网关不可达时自动切换
/ip/route/add dst-address=0.0.0.0/0 gateway=192.168.88.169 routing-mark=via-openclash distance=1 check-gateway=ping
/ip/route/add dst-address=0.0.0.0/0 gateway=192.168.88.1 routing-mark=via-openclash distance=2 comment="Failover"
```

## 与 DNS 分流方案的配合

当前方案已部署 AdGuard Home + MosDNS DNS 分流，结合策略路由实现完整的智能分流：

### 完整流量路径

```
客户端发起请求 google.com
    ↓
DNS 查询 → AdGuard Home (192.168.88.243:53)
    ↓
MosDNS 识别为 GFW 域名
    ↓
查询 8.8.8.8 (通过 88.243 的网关 88.169 代理)
    ↓
返回 Google IP: 142.250.xxx.xxx
    ↓
客户端发起 HTTP 请求到 142.250.xxx.xxx
    ↓
RouterOS 策略路由检查: 142.250.xxx.xxx 不在 cnip
    ↓
标记流量 routing-mark=via-openclash
    ↓
转发到 192.168.88.169 (OpenClash)
    ↓
OpenClash 透明代理
    ↓
访问成功
```

### 关键配置检查

1. **192.168.88.243 网关配置**:
```bash
ssh admin@192.168.88.1
/ip/dhcp-server/lease/print detail where address=192.168.88.243
# 确认: gateway=192.168.88.169，DNS=192.168.88.243
```

2. **OpenClash 透明代理模式**:
- 确保 OpenClash 运行在透明代理模式（Redir-Host 或 Fake-IP）
- iptables 规则正确配置，拦截转发流量

3. **防火墙规则优先级**:
```bash
# RouterOS Mangle 规则应在 NAT 之前执行
/ip/firewall/mangle/print
# 确认 chain=prerouting
```

## 参考资源

- **CN IP 列表**: https://ispip.clang.cn/all_cn.txt
- **RouterOS 文档**: https://help.mikrotik.com/docs/display/ROS/Policy+Routing
- **OpenClash**: https://github.com/vernesong/OpenClash
- **相关文档**: 
  - `docs/dns-stack-deployment.md` - DNS 分流方案
  - `network/routeros-openclash-dhcp.md` - DHCP 选项配置

## 状态记录

- **部署日期**: 2026-06-17
- **配置文件**: `network/routeros-cn-policy-full.rsc`
- **CN IP 数量**: 4,283 + 3 私网段 = 4,286 条
- **OpenClash 网关**: 192.168.88.169
- **DNS 服务器**: 192.168.88.243 (AdGuard Home + MosDNS)
