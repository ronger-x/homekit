# RouterOS + PaoPaoDNS + PaoPaoGateWay 维护手册

本文记录在 PVE 上部署 PaoPaoDNS 和 PaoPaoGateWay，并由 RouterOS 主路由承接 fake-ip 静态路由的当前配置。

## 当前拓扑

- RouterOS 主路由：`192.168.88.1`
- PVE：`192.168.88.228`
- PaoPaoDNS LXC：VMID `115`，`192.168.88.220`
- PaoPaoGateWay VM：VMID `116`，`192.168.88.221`
- 上游代理：PaoPaoGateWay `suburl` 订阅模式
- fake-ip 段：`7.0.0.0/8`

流量路径：

```text
client DNS -> 192.168.88.220(PaoPaoDNS)
non-CN domain -> 192.168.88.221:53(PaoPaoGateWay fake DNS) -> 7.0.0.0/8
client traffic to 7.0.0.0/8 -> RouterOS static route -> 192.168.88.221 -> subscription-selected node
CN domain -> PaoPaoDNS returns real CN IP directly
```

## PVE 资源

PaoPaoDNS：

```text
CTID: 115
hostname: paopaodns
IP: 192.168.88.220/24
gateway: 192.168.88.1
storage: storage1
memory: 4096 MB
swap: 1024 MB
cores: 2
container: Docker, image sliamb/paopaodns:latest
compose path: /opt/paopaodns/docker-compose.yml
data path: /home/paopaodns
file editor: File Browser, http://192.168.88.220:8088
```

PaoPaoGateWay：

```text
VMID: 116
name: paopaogw
IP: 192.168.88.221/24, assigned by RouterOS static DHCP lease
MAC: BC:24:11:9D:CC:78
ISO: local:iso/paopao-gateway-20260607-8850e0c.iso
memory: 1024 MB
cores: 2
cpu: host
bridge: vmbr0
```

## PaoPaoDNS 配置

PaoPaoDNS 使用 Docker Compose，关键环境变量：

```yaml
CNAUTO: yes
CNFALL: yes
IPV6: no
SERVER_IP: 192.168.88.220
CUSTOM_FORWARD: 192.168.88.221:53
AUTO_FORWARD: yes
AUTO_FORWARD_CHECK: yes
USE_MARK_DATA: yes
HTTP_FILE: yes
```

`HTTP_FILE=yes` 会在 `7889/tcp` 暴露 `/home/paopaodns`，PaoPaoGateWay 可读取：

```text
http://192.168.88.220:7889/ppgw.ini
```

`/home/paopaodns/ppgw.ini` 当前关键配置：

```ini
#paopao-gateway
mode=suburl
fake_cidr=7.0.0.0/8
dns_ip=192.168.88.220
dns_port=5304
clash_web_port=80
clash_web_password="paopaopass"
openport=no
udp_enable=yes
sleeptime=30
suburl="http://192.168.88.243:3111/cD7wiTGitL2yoBdEguAnFWmq/download/collection/home?target=ClashMeta"
subtime=1d
fast_node=yes
test_node_url="https://www.youtube.com/generate_204"
dns_burn=yes
ex_dns="192.168.88.220:53,223.5.5.5:53"
net_rec=yes
max_rec=5000
```

历史 `socks5` 模式配置已备份在同目录，例如：

```text
/home/paopaodns/ppgw.ini.bak-20260621-015550
```

`fast_node=yes` 会让 PaoPaoGateWay 加载订阅后测速并自动选择节点。此前使用 `fast_node=check` 时，`GLOBAL` 会停在 `DIRECT`，fake-ip 流量会连接重置。

`udp_enable=yes` 允许 UDP 流量进入网关。YouTube/Chrome 会优先尝试 QUIC/UDP 443，开启 UDP 通常比强制 TCP 回退更顺滑；如果某个节点 UDP 支持不好，可以改回 `udp_enable=no`。

## Web 文件编辑器

PaoPaoDNS 的数据目录 `/home/paopaodns` 通过 File Browser 暴露为 Web 文件编辑器：

```text
URL: http://192.168.88.220:8088
username: admin
password file: /opt/filebrowser/admin-password.txt
```

主要编辑这些文件：

```text
custom_cn_mark.txt       直连/CN 标记
force_forward_list.txt   强制走 PaoPaoGateWay/fake-ip
force_dnscrypt_list.txt  强制真实解析
ppgw.ini                 PaoPaoGateWay 配置
```

PaoPaoDNS 会监听多数列表文件变化，修改后通常几秒内生效。改 `ppgw.ini` 后，PaoPaoGateWay 会按 `sleeptime=30` 周期重新拉取；也可以重启 VM `116` 立即应用。

当前直连修正：

```text
custom_cn_mark.txt:
domain:gstatic.com
```

背景：YouTube 页面依赖 `gstatic.com` 静态资源。经 PaoPaoGateWay fake-ip 访问 `gstatic.com` 会超时，而真实解析到国内边缘 IP 后首包约 0.13-0.15 秒。`googleusercontent.com` 直连测试不可达，暂不加入直连。

注意：PaoPaoDNS 内存占用较高，1 GB 会导致 `unbound`/`mosdns` 卡住；当前已调到 4 GB。

## RouterOS 配置

DHCP option：给 PaoPaoGateWay 下发 DNS `192.168.88.220`。

```routeros
/ip/dhcp-server/option/add name=paopao-dns code=6 value=0xC0A858DC
```

PaoPaoGateWay 静态 DHCP lease：

```routeros
/ip/dhcp-server/lease/make-static [find where mac-address="BC:24:11:9D:CC:78"]
/ip/dhcp-server/lease/set [find where mac-address="BC:24:11:9D:CC:78"] address=192.168.88.221 dhcp-option=paopao-dns comment="PaoPaoGateWay VM 116"
```

fake-ip 静态路由：

```routeros
/ip/route/add dst-address=7.0.0.0/8 gateway=192.168.88.221 comment="PaoPaoGateWay fake_cidr"
```

如果客户端要使用该方案，应将 DNS 指向 `192.168.88.220`。可以在 RouterOS DHCP network 全局下发，也可以只对指定 lease 下发 DHCP option `code=6`。

## 验证

PaoPaoDNS 国内域名应返回真实 IP：

```bash
dig @192.168.88.220 baidu.com +short
```

PaoPaoDNS 非 CN 域名应返回 fake-ip：

```bash
dig @192.168.88.220 google.com +short
# expected: 7.0.0.x
```

PaoPaoGateWay fake DNS：

```bash
dig @192.168.88.221 google.com +short
# expected: 7.0.0.x
```

fake-ip 路由和代理出站：

```bash
FAKE=$(dig @192.168.88.220 google.com +short | head -1)
curl -H 'Host: www.google.com' "http://${FAKE}/generate_204" -v
# expected: HTTP/1.1 204 No Content
```

查看当前订阅节点选择：

```bash
HASH=$(printf 'paopaopass' | sha256sum | awk '{print $1}')
curl -H "Authorization: Bearer ${HASH}" http://192.168.88.221/proxies/GLOBAL
```

PaoPaoGateWay 面板：

```text
http://192.168.88.221/ui
password: paopaopass
```

## 常用维护命令

查看 PaoPaoDNS：

```bash
ssh root@192.168.88.228
pct exec 115 -- bash -lc 'free -m; docker ps; ps -o pid,pcpu,pmem,rss,cmd -C unbound -C mosdns -C dnscrypt-proxy'
```

查看 File Browser 密码：

```bash
ssh root@192.168.88.228
pct exec 115 -- bash -lc 'cat /opt/filebrowser/admin-password.txt'
```

重启 PaoPaoDNS：

```bash
ssh root@192.168.88.228
pct exec 115 -- bash -lc 'cd /opt/paopaodns && docker compose restart'
```

查看 PaoPaoGateWay：

```bash
ssh root@192.168.88.228
qm status 116
qm config 116
```

查看 RouterOS 规则：

```routeros
/ip/dhcp-server/lease/print detail where mac-address="BC:24:11:9D:CC:78"
/ip/dhcp-server/option/print detail where name="paopao-dns"
/ip/route/print detail where dst-address="7.0.0.0/8"
```
