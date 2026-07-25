# DNS 分流方案部署文档

> 状态：历史参考。本文记录旧 AdGuard Home + MosDNS 链路；PaoPaoDNS/PaoPaoGateWay 也已删除。

## 架构概述

```
LAN 客户端 (192.168.88.0/24)
    ↓ DNS 查询 (UDP 53)
AdGuard Home (192.168.88.243:53)
    ↓ 上游查询 (UDP 5335)
MosDNS (容器内部 192.168.144.2:5335)
    ├─ 国内域名 → 223.5.5.5 / 119.29.29.29
    └─ GFW 域名 → 8.8.8.8 / 1.1.1.1 (通过 88.169 网关代理)
```

## 核心组件

### AdGuard Home
- **功能**: DNS 服务器 + 广告过滤 + 查询日志
- **端口**: 53 (DNS), 3100 (Web UI)
- **上游**: MosDNS 容器 (192.168.144.2:5335)
- **过滤规则**:
  - AdGuard DNS filter (id=1)
  - anti-AD (id=2)

### MosDNS
- **功能**: DNS 查询路由（域名分流）
- **端口**: 5335 (仅容器内部)
- **分流逻辑**:
  - `china-list.txt` (112,097 条) → 国内 DNS
  - `gfwlist.txt` (4,192 条) → 国外 DNS
  - 其他域名 → 国内 DNS (默认)

### 域名列表来源
- GFW: https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt (base64 解码)
- 国内: https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf

## 部署步骤

### 1. 准备目录结构
```bash
mkdir -p ~/dns-stack/{mosdns,adguard/{work,conf}}
cd ~/dns-stack
```

### 2. 下载域名列表
```bash
# GFW 列表
curl -sL https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt | \
  base64 -d | grep -v '^!' | grep -v '^@@' | grep -v '^\[' | \
  sed 's/||//g' | sed 's/^\.//g' | grep '\.' | sort -u > mosdns/gfwlist.txt

# 国内域名列表
curl -sL https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf | \
  grep '^server=/' | sed 's|^server=/||' | sed 's|/.*||' | sort -u > mosdns/china-list.txt

# 验证
wc -l mosdns/*.txt
```

### 3. 创建 MosDNS 配置
```bash
cat > mosdns/config.yaml << 'MOSDNS_EOF'
log:
  level: info

plugins:
  - tag: cache
    type: cache
    args:
      size: 10000
      lazy_cache_ttl: 86400

  - tag: gfwlist
    type: domain_set
    args:
      files:
        - "/etc/mosdns/gfwlist.txt"

  - tag: cnlist
    type: domain_set
    args:
      files:
        - "/etc/mosdns/china-list.txt"

  - tag: forward_cn
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "223.5.5.5"
        - addr: "119.29.29.29"

  - tag: forward_gfw
    type: forward
    args:
      concurrent: 2
      upstreams:
        - addr: "8.8.8.8"
        - addr: "1.1.1.1"

  - tag: main
    type: sequence
    args:
      - exec: $cache
      - matches:
          - qname $cnlist
        exec: $forward_cn
      - matches:
          - qname $gfwlist
        exec: $forward_gfw
      - exec: $forward_cn

  - tag: udp_server
    type: udp_server
    args:
      entry: main
      listen: "0.0.0.0:5335"
MOSDNS_EOF
```

### 4. 创建 Docker Compose 配置
```bash
cat > docker-compose.yml << 'COMPOSE_EOF'
services:
  mosdns:
    image: irinesistiana/mosdns:latest
    container_name: mosdns
    restart: unless-stopped
    networks:
      - dns-net
    volumes:
      - ./mosdns:/etc/mosdns:ro

  adguardhome:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    ports:
      - "0.0.0.0:53:53/tcp"
      - "0.0.0.0:53:53/udp"
      - "0.0.0.0:3100:3000/tcp"
    volumes:
      - ./adguard/work:/opt/adguardhome/work
      - ./adguard/conf:/opt/adguardhome/conf
    depends_on:
      - mosdns
    networks:
      - dns-net

networks:
  dns-net:
    driver: bridge
COMPOSE_EOF
```

### 5. 启动容器并初始化 AdGuard Home
```bash
docker compose up -d
sleep 5

# 检查容器状态
docker compose ps

# 获取 MosDNS 容器 IP
MOSDNS_IP=$(docker inspect mosdns --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "MosDNS IP: $MOSDNS_IP"
```

### 6. 配置 AdGuard Home

访问 http://192.168.88.243:3100 完成初始化后，更新上游 DNS 配置：

```bash
# 获取 MosDNS IP 并更新配置
MOSDNS_IP=$(docker inspect mosdns --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
sed -i "s/- mosdns:5335/- ${MOSDNS_IP}:5335/" adguard/conf/AdGuardHome.yaml

# 重启以应用配置
docker compose restart adguardhome
```

### 7. 配置 RouterOS DHCP

```bash
# SSH 到 RouterOS
ssh admin@192.168.88.1

# 修改 DHCP 网络配置，将 DNS 指向 AdGuard Home
/ip/dhcp-server/network/set 0 dns-server=192.168.88.243

# 验证配置
/ip/dhcp-server/network/print detail
```

### 8. 客户端更新 DNS

Windows:
```cmd
ipconfig /release
ipconfig /renew
ipconfig /all
```

Linux/macOS:
```bash
sudo dhclient -r && sudo dhclient
# 或
sudo systemctl restart NetworkManager
```

## 验证测试

### 1. 容器内测试
```bash
# 测试国内域名
docker exec adguardhome nslookup baidu.com 127.0.0.1

# 测试 GFW 域名
docker exec adguardhome nslookup google.com 127.0.0.1

# 测试 GitHub
docker exec adguardhome nslookup github.com 127.0.0.1
```

### 2. 宿主机测试
```bash
nslookup baidu.com 127.0.0.1
nslookup google.com 127.0.0.1
```

### 3. LAN 客户端测试
```bash
# Windows
nslookup baidu.com
nslookup google.com

# Linux/macOS
dig baidu.com
dig google.com
```

### 4. 查看 MosDNS 日志（调试用）
```bash
docker compose logs -f mosdns
```

### 5. 查看 AdGuard Home 日志
```bash
docker compose logs -f adguardhome
```

## 故障排查

### 问题 1: AdGuard 无法连接 MosDNS
**症状**: `dialing mosdns:5335 over udp: no addresses`

**原因**: Docker 容器 DNS 解析失败

**解决**:
```bash
# 获取 MosDNS 容器 IP
MOSDNS_IP=$(docker inspect mosdns --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

# 更新 AdGuard 配置使用 IP 而非容器名
sed -i "s/- mosdns:5335/- ${MOSDNS_IP}:5335/" adguard/conf/AdGuardHome.yaml

# 重启
docker compose restart adguardhome
```

### 问题 2: 端口 53 已被占用
**症状**: `Bind for 0.0.0.0:53 failed: port is already allocated`

**解决**:
```bash
# 检查占用进程
sudo netstat -tulpn | grep :53

# 如果是 systemd-resolved
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
```

### 问题 3: GFW 域名无法解析
**症状**: Google/GitHub 等域名超时

**原因**: 88.243 的网关未配置为 88.169，无法通过代理访问 8.8.8.8

**验证**: 检查 RouterOS 配置
```bash
ssh admin@192.168.88.1 '/ip/dhcp-server/lease/print detail where address=192.168.88.243'
```

**确认**: 88.243 必须配置网关为 88.169 才能访问外网 DNS

### 问题 4: 域名列表下载失败
**备用方案**:
```bash
# 手动创建最小测试列表
echo "google.com" > mosdns/gfwlist.txt
echo "youtube.com" >> mosdns/gfwlist.txt
echo "github.com" >> mosdns/gfwlist.txt

echo "baidu.com" > mosdns/china-list.txt
echo "qq.com" >> mosdns/china-list.txt
echo "taobao.com" >> mosdns/china-list.txt
```

## 维护操作

### 更新域名列表
```bash
cd ~/dns-stack

# 重新下载
curl -sL https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt | \
  base64 -d | grep -v '^!' | grep -v '^@@' | grep -v '^\[' | \
  sed 's/||//g' | sed 's/^\.//g' | grep '\.' | sort -u > mosdns/gfwlist.txt

curl -sL https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf | \
  grep '^server=/' | sed 's|^server=/||' | sed 's|/.*||' | sort -u > mosdns/china-list.txt

# 重启 MosDNS
docker compose restart mosdns
```

### 更新 AdGuard 过滤规则
访问 http://192.168.88.243:3100 → 过滤器 → 更新过滤器

### 查看查询日志
访问 http://192.168.88.243:3100 → 查询日志

### 备份配置
```bash
tar -czf dns-stack-backup-$(date +%Y%m%d).tar.gz ~/dns-stack/
```

## 性能优化

### MosDNS 缓存调整
编辑 `mosdns/config.yaml`:
```yaml
- tag: cache
  type: cache
  args:
    size: 20000        # 增加缓存条目数
    lazy_cache_ttl: 172800  # 延长缓存时间（48小时）
```

### AdGuard Home 缓存调整
编辑 `adguard/conf/AdGuardHome.yaml`:
```yaml
dns:
  cache_size: 8388608  # 8MB (默认 4MB)
```

## 监控指标

### 关键日志位置
- MosDNS: `docker compose logs mosdns`
- AdGuard Home: `docker compose logs adguardhome`
- AdGuard 查询日志: Web UI → 查询日志

### 性能指标
- DNS 查询响应时间: < 50ms (缓存命中), < 200ms (缓存未命中)
- 内存占用: MosDNS ~50MB, AdGuard Home ~100MB
- 缓存命中率: 通过 AdGuard Web UI 查看统计

## 安全注意事项

1. **88.243 网关配置**: 必须配置为 88.169 以使用外网代理访问 8.8.8.8/1.1.1.1
2. **AdGuard 密码**: 修改默认密码（bcrypt hash）
3. **端口暴露**: 仅暴露必要端口（53, 3100）
4. **更新策略**: 定期更新 Docker 镜像和过滤规则

## 当前部署状态（192.168.88.243）

- **部署日期**: 2026-06-17
- **MosDNS 容器 IP**: 192.168.88.144.2
- **AdGuard Home Web UI**: http://192.168.88.243:3100
- **RouterOS DHCP DNS**: 已配置为 192.168.88.243
- **域名列表统计**:
  - GFW: 4,192 条
  - 国内: 112,097 条

## 参考资源

- MosDNS: https://github.com/IrineSistiana/mosdns
- AdGuard Home: https://github.com/AdguardTeam/AdGuardHome
- GFW List: https://github.com/gfwlist/gfwlist
- China List: https://github.com/felixonmars/dnsmasq-china-list
