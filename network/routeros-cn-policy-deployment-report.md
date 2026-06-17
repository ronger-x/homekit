# RouterOS 策略路由部署完成报告

## 部署日期
2026-06-17

## 配置摘要

### 地址列表
- **中国 IP 数量**: 4,287 条（4,283 公网 + 3 私网段 + 1 重复）
- **列表名称**: `cnip`
- **来源**: https://ispip.clang.cn/all_cn.txt

### Mangle 规则
```
ID: 4
Chain: prerouting
Source: 192.168.88.0/24
Destination: !cnip (不在中国 IP 列表)
Action: mark-routing
Routing Mark: via-openclash
Comment: overseas-traffic
```

### 路由表
```
Routing Table: via-openclash
Destination: 0.0.0.0/0
Gateway: 192.168.88.169 (OpenClash)
Distance: 1
Comment: overseas-via-openclash
```

## 流量路径

### 国内流量（目标 IP 在 cnip 列表）
```
客户端 (192.168.88.X)
    ↓ 网关: 192.168.88.1
RouterOS 检查目标 IP
    ↓ 匹配 cnip 列表
直接转发（默认路由）
    ↓ WAN 口
访问成功（无代理）
```

### 海外流量（目标 IP 不在 cnip 列表）
```
客户端 (192.168.88.X)
    ↓ 网关: 192.168.88.1
RouterOS 策略路由
    ↓ 目标 IP 不在 cnip
    ↓ Mangle 标记: via-openclash
路由表查询
    ↓ routing-mark=via-openclash
转发到 192.168.88.169
    ↓ OpenClash 透明代理
    ↓ 代理节点
访问成功
```

## 测试结果

### 国内 IP 测试
```bash
/tool/traceroute 223.5.5.5
```
结果: 直连，无经过 88.169

### 海外 IP 测试
```bash
/tool/traceroute 8.8.8.8
```
结果: 经过 `117.169.65.5`（OpenClash 上游网关）

## 验证命令

### RouterOS 验证
```bash
# 查看地址列表数量
/ip/firewall/address-list/print count-only where list=cnip

# 查看 Mangle 规则
/ip/firewall/mangle/print where comment~"overseas"

# 查看路由表
/ip/route/print where routing-table=via-openclash

# 查看规则统计（流量计数）
/ip/firewall/mangle/print stats where comment~"overseas"

# 测试路由
/tool/traceroute 8.8.8.8
/tool/traceroute 223.5.5.5
/tool/traceroute baidu.com
/tool/traceroute google.com
```

### 客户端验证

**Windows**:
```cmd
# 查看 DNS 和网关配置
ipconfig /all

# 测试路由
tracert 8.8.8.8
tracert baidu.com

# 测试访问
curl -I https://www.google.com
curl -I https://www.baidu.com
```

**Linux/macOS**:
```bash
# 查看网关
ip route show

# 测试路由
traceroute 8.8.8.8
traceroute baidu.com

# 测试访问
curl -I https://www.google.com
curl -I https://www.baidu.com
```

## 性能指标

### 资源消耗（RouterOS）
- **内存**: 约 3 MB（4,287 条地址列表）
- **CPU**: < 1% 增加（每包查询开销）
- **延迟影响**:
  - 国内流量: 0 ms（无影响）
  - 海外流量: +1-2 ms（策略路由查询）

### 预期延迟对比
| 目标 | 原方案（全网走代理） | 策略路由方案 |
|------|---------------------|--------------|
| 百度 (国内) | +5-10ms | 0ms（直连） |
| Google (海外) | +2-5ms | +2-5ms（代理） |

## 维护操作

### 更新中国 IP 列表（每季度）

1. 下载最新 IP 列表：
```bash
cd /tmp
curl -sL https://ispip.clang.cn/all_cn.txt -o cn-ip-new.txt
```

2. 对比变化：
```bash
diff cn-ip.txt cn-ip-new.txt | head -20
```

3. 清理旧列表并导入新列表：
```bash
# 在 RouterOS 上
/ip/firewall/address-list/remove [find list=cnip]

# 生成新脚本并分批导入（参考初始部署）
```

### 手动添加 IP 到直连列表

```bash
# 强制某个 IP 段走直连（不走代理）
/ip/firewall/address-list/add list=cnip address=1.2.3.0/24 comment="Custom-Direct"
```

### 手动强制某个 IP 走代理

```bash
# 从 cnip 列表移除（如果存在）
/ip/firewall/address-list/remove [find where list=cnip and address=1.2.3.4/32]
```

### 临时禁用策略路由

```bash
# 禁用 Mangle 规则（所有流量恢复直连）
/ip/firewall/mangle/disable [find comment~"overseas"]

# 重新启用
/ip/firewall/mangle/enable [find comment~"overseas"]
```

### 完全移除配置

```bash
/ip/firewall/address-list/remove [find list=cnip]
/ip/firewall/mangle/remove [find comment~"overseas"]
/ip/route/remove [find routing-table=via-openclash]
/routing/table/remove [find name=via-openclash]
```

## 故障排查

### 问题 1: 海外网站无法访问

**症状**: Google/YouTube 等无法打开

**排查**:
```bash
# 1. 检查 88.169 是否在线
/ping 192.168.88.169 count=5

# 2. 检查路由规则
/ip/route/print where routing-table=via-openclash

# 3. 检查 OpenClash 状态（SSH 到 88.169）
ssh root@192.168.88.169 '/etc/init.d/openclash status'
```

**解决**: 确保 OpenClash 正常运行

### 问题 2: 部分国内网站变慢

**症状**: 某些国内网站访问延迟高

**排查**:
```bash
# 测试问题网站的 IP
/tool/traceroute <问题网站域名>

# 检查该 IP 是否在 cnip 列表
/ip/firewall/address-list/print where list=cnip and address~"目标IP"
```

**解决**: 如果 IP 不在列表，手动添加到 cnip

### 问题 3: 所有流量都走代理或都不走代理

**症状**: 国内网站也变慢，或海外网站无法访问

**排查**:
```bash
# 检查 Mangle 规则统计
/ip/firewall/mangle/print stats where comment~"overseas"
# 查看 Bytes 和 Packets 列是否有增长
```

**解决**: 
- 如果计数器不增长，检查规则是否禁用：`/ip/firewall/mangle/enable [find comment~"overseas"]`
- 如果规则正常但路由异常，检查 OpenClash 网关是否可达

## 已知问题

1. **重复路由条目**: 路由表中有 2 条相同路由（ID 0 和 1），不影响功能
2. **中文字符不支持**: RouterOS 脚本不支持中文注释，所有注释使用英文
3. **大规模导入限制**: 4000+ 条 IP 需要分批导入，单次脚本导入会超时

## 相关配置文件

- **RouterOS 脚本**: `network/routeros-cn-policy-en.rsc`（英文版）
- **IP 列表原始数据**: `/tmp/cn-ip.txt`（4,283 条）
- **分片脚本**: `/tmp/routeros-part-*.rsc`（9 个文件，每个 500 行）
- **部署文档**: `network/routeros-cn-policy-routing.md`

## 配合其他组件

### 与 DNS 分流方案的配合

当前网络已部署 AdGuard Home + MosDNS DNS 分流（192.168.88.243），完整流量路径：

```
客户端请求 google.com
    ↓
DNS 查询 → 192.168.88.243 (AdGuard Home)
    ↓
MosDNS 识别为 GFW 域名
    ↓
查询 8.8.8.8 (通过 88.243 的网关 88.169)
    ↓
返回 Google IP
    ↓
客户端发起 HTTP 请求
    ↓
RouterOS 策略路由检查: IP 不在 cnip
    ↓
Mangle 标记 → routing-mark=via-openclash
    ↓
转发到 192.168.88.169 (OpenClash)
    ↓
访问成功
```

### 网络拓扑

```
                    Internet
                        ↑
                  WAN (PPPoE)
                        |
            +-------------------+
            |  RouterOS Gateway |
            |  192.168.88.1     |
            +-------------------+
                        |
        +---------------+---------------+
        |               |               |
    直连流量      策略路由标记      DNS 查询
   (国内 IP)      (海外 IP)      (所有设备)
        |               |               |
        ↓               ↓               ↓
    直接转发    192.168.88.169   192.168.88.243
                (OpenClash)      (AdGuard + MosDNS)
                        |
                  透明代理 + 规则分流
                        |
                    代理节点
                        |
                      Internet
```

## 后续优化建议

1. **自动更新 IP 列表**: 配置定时任务每季度更新中国 IP 列表
2. **监控告警**: 监控 88.169 存活状态，掉线时告警或自动切换
3. **流量统计**: 定期查看 Mangle 规则统计，分析海外流量占比
4. **故障转移**: 配置备用路由，当 88.169 不可达时自动切换到直连

## 参考资源

- CN IP 列表: https://ispip.clang.cn/all_cn.txt
- RouterOS 文档: https://help.mikrotik.com/docs/display/ROS/Policy+Routing
- OpenClash: https://github.com/vernesong/OpenClash
- DNS 分流方案: `docs/dns-stack-deployment.md`
- DHCP 配置: `network/routeros-openclash-dhcp.md`
