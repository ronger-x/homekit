# 紧急修复：Tailscale 网络被 OSPF 路由覆盖

> 状态：历史故障记录。OSPF 分流方案已停用，不代表当前网络架构。

## 问题描述

OSPF 路由宣告了 100.64.0.0/10 段，覆盖了 Tailscale 的 CGNAT 地址，导致：
- Tailscale 流量被错误路由到 192.168.88.250 容器
- 容器将其转发到隧道，导致 Tailscale 连接失败
- 无法通过 SSH 访问 RouterOS 和 PVE

## 立即修复步骤

### 方案 1: 通过 RouterOS 终端（推荐）

1. 连接 RouterOS（WinBox/SSH/Web）
2. 执行以下命令立即禁用 OSPF：

```routeros
# 立即禁用 OSPF（恢复网络）
/routing/ospf/instance/disable ospf-split-v2
/routing/ospf/instance/disable ospf-split-v3

# 验证 OSPF 路由已清除
/ip/route/print count-only where ospf
# 应显示 0
```

**注意**：RouterOS 7.x 不支持 `type=blackhole`，直接禁用 OSPF 是最快的修复方式。

### 方案 2: 通过 RouterOS Web 界面

1. 浏览器访问 `http://192.168.88.1`
2. 登录后点击 Terminal
3. 执行上述 RouterOS 命令

### 方案 3: 物理访问 RouterOS

如果网络完全断开，需要物理连接到 RouterOS 的控制台端口。

## 长期修复方案

修复后，需要更新 nchnroutes 配置排除 Tailscale 段：

### 1. 在容器内创建排除列表

SSH 到 PVE (192.168.88.228)，然后：

```bash
pct enter 250

# 创建排除文件（追加 Tailscale 段）
cat >> /tmp/exclude_ips.txt << 'EOF'
100.64.0.0/10
EOF

# 重新生成路由表
cd /tmp/nchnroutes
python3 nchnroutes.py --exclude-file /tmp/exclude_ips.txt --output bird

# 更新 BIRD 配置
cp routes4.conf routes6.conf /etc/bird/

# 重启 BIRD
systemctl restart bird

# 验证
birdc show route count
```

### 2. 更新部署脚本

编辑 `deploy-ospf-singbox.sh`，在生成路由表时添加排除：

```bash
# 在生成 nchnroutes 时排除 Tailscale
python3 nchnroutes.py \
  --exclude-file /tmp/exclude_ips.txt \
  --exclude 100.64.0.0/10 \
  --output bird
```

### 3. 更新文档

在 `network/ospf-split-routing-maintenance.md` 的"更新路由表"章节添加：

```markdown
### 排除特殊网段

除了代理节点 IP，还需要排除以下网段：

- `100.64.0.0/10` - Tailscale/CGNAT 地址段
- `10.0.0.0/8` - 私有网络（如果使用）
- `172.16.0.0/12` - 私有网络（如果使用）
```

## 验证修复

修复后验证：

```bash
# 检查 Tailscale 状态
tailscale status

# 检查 RouterOS 路由
ssh admin@192.168.88.1 "/ip/route/print where dst-address~\"100.64\""

# 应该看到：
# distance=1 的静态黑洞路由（优先级高）
# 没有 OSPF 路由指向 192.168.88.250
```

## 其他可能需要排除的网段

如果使用其他 VPN 或私有网络服务，也需要排除：

- **Zerotier**: `172.22.0.0/16`, `172.23.0.0/16`
- **Nebula**: 取决于你的配置
- **内网 VPN**: 取决于你的内网地址段
- **Docker/Podman**: `172.17.0.0/16` (docker0), `10.88.0.0/16` (podman)

## 预防措施

在 RouterOS 上预先添加保护路由（在启用 OSPF 之前）：

```routeros
# Tailscale
/ip/route/add dst-address=100.64.0.0/10 type=blackhole distance=1 comment="Tailscale protection"

# 其他 VPN 段（根据实际情况添加）
# /ip/route/add dst-address=172.22.0.0/16 type=blackhole distance=1 comment="Zerotier protection"
```

这样即使 OSPF 宣告了这些段，静态路由也会优先生效。
