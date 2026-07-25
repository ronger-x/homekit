# MSF 测试 VM 维护手册

本文记录 PVE 上仍在运行的 MSF 测试 VM。PaoPaoDNS/PaoPaoGateWay 已删除；MSF 当前保留为测试/兼容路径，但尚不能仅凭服务运行状态认定为全局生产 DNS。

## 测试边界

- VMID `115`/`116` 已删除，`192.168.88.220`/`.221` 不再提供 PaoPao 服务。
- RouterOS 全局 DHCP 仍下发网关/DNS `192.168.88.1`，MSF 没有接管全局 DHCP DNS。
- RouterOS 的 `28.0.0.0/8 -> 192.168.88.222` 路由当前有效。
- RouterOS 仍残留 `7.0.0.0/8 -> 192.168.88.221` 路由；这是指向已删除 VM 的过期配置，需另行确认后清理。
- 继续优先让指定测试设备使用 MSF DNS，确认稳定后再扩大范围。

## PVE 资源

```text
VMID: 117
name: msf-test
IP: 192.168.88.222/24
gateway: 192.168.88.1
MAC: BC:24:11:54:56:01
OS: Ubuntu 24.04 cloud image
storage: storage1
disk: 20 GB
memory: 4096 MB
cores: 2
cpu: host
bridge: vmbr0
onboot: disabled
tags: 88.222;msf;test
```

PVE 查看命令：

```bash
ssh root@192.168.88.228
qm status 117
qm config 117
qm agent 117 network-get-interfaces
```

VM 登录：

```bash
ssh ubuntu@192.168.88.222
```

## MSF 安装状态

安装方式：Linux tarball/systemd。

```text
MSF version: 0.3.9.2
binary: /usr/local/bin/msf
compat alias: /usr/local/bin/msm
data directory: /opt/msf
systemd service: msf.service
WebUI: http://192.168.88.222:7777
```

常用命令：

```bash
ssh ubuntu@192.168.88.222
sudo systemctl status msf
sudo journalctl -u msf -f
sudo msf status
sudo msf logs
sudo msf doctor
```

当前验证结果：

```text
PVE VM: running
QEMU guest agent: working
MSF systemd service: active
WebUI: http://192.168.88.222:7777 returns HTTP 200
MSF app: initialized
MosDNS: running
Mihomo: running
systemd-resolved: disabled, port 53 released for MSF
```

`sudo msf status` 在首次 WebUI 初始化前显示 `app: stopped` 属于预期状态。完成初始化后应显示 `mosdns: running` 和 `mihomo: running`。

### 53 端口占用修复

Ubuntu cloud image 默认启用 `systemd-resolved` DNS stub，会占用 `127.0.0.53:53` / `127.0.0.54:53`。MSF 初始化前已在本测试 VM 上停用它，并把 `/etc/resolv.conf` 改为静态上游 DNS：

```text
nameserver 192.168.88.1
nameserver 223.5.5.5
options timeout:2 attempts:2
search local
```

验证命令：

```bash
systemctl is-active systemd-resolved
sudo ss -lntup | grep ':53' || true
getent hosts github.com
```

预期：`systemd-resolved` 为 `inactive`，`ss` 不再显示 `:53` 监听，域名解析仍正常。

## 首次初始化建议

打开：

```text
http://192.168.88.222:7777
```

按向导完成：

1. 创建管理员账号。
2. 确认系统参数，服务器 IP 使用 `192.168.88.222`。
3. DNS 入口使用 MSF 默认 MosDNS。
4. Fake-IP IPv4 保持 MSF 默认 `28.0.0.0/8`；不要复用已退役 PaoPaoGateWay 的 `7.0.0.0/8`。
5. 按需配置 IPv6；当前测试阶段先关闭 DNS AAAA fake-ip 返回，只使用 IPv4 fake-ip。
6. 配置订阅和节点后，先在 MSF 内部完成连通性测试。

如果 GitHub 下载组件较慢，可以临时在 shell 中设置 `HTTP_PROXY` / `HTTPS_PROXY`，或使用 MSF WebUI 的组件本地上传功能；不要把代理账号密码写入仓库。

## RouterOS 测试接入

在 MSF WebUI 初始化、组件下载和节点连通性确认之前，不要改 RouterOS。

完成初始化后，建议只接入一个测试设备：

1. 在 RouterOS 给测试设备下发 DNS `192.168.88.222`。
2. 添加 MSF fake-ip 静态路由。
3. 测试通过后再扩大范围。

RouterOS 参考命令：

```routeros
/ip/route/add dst-address=28.0.0.0/8 gateway=192.168.88.222 comment="MSF test FakeIP v4"
```

如启用 IPv6 fake-ip，再添加：

```routeros
/ipv6/route/add dst-address=f2b0::/18 gateway=2409:8a38:12:4bf0:be24:11ff:fe54:5601 comment="MSF FakeIP v6"
```

给单台测试设备下发 DNS 时，优先使用 DHCP option 或静态 lease 绑定，不要直接改全局 DHCP network：

```routeros
/ip/dhcp-server/option/add name=msf-test-dns code=6 value=0xC0A858DE
/ip/dhcp-server/lease/set [find where mac-address="<TEST_DEVICE_MAC>"] dhcp-option=msf-test-dns comment="MSF test DNS"
```

`0xC0A858DE` 对应 `192.168.88.222`。

### 当前测试客户端：192.168.88.144

`192.168.88.144` 已作为临时测试客户端验证 MSF。该主机上只加了临时路由，未写入持久网络配置：

```bash
ssh root@192.168.88.144
ip route replace 28.0.0.0/8 via 192.168.88.222 dev ens18
ip -6 route replace f2b0::/18 via fe80::be24:11ff:fe54:5601 dev ens18
```

`192.168.88.144` 使用 `resolvconf` 管理 `/etc/resolv.conf`。当前通过高优先级 `lo.msf-test` 条目临时把 MSF DNS 放在第一位：

```bash
printf 'nameserver 192.168.88.222\n' | resolvconf -a lo.msf-test
resolvconf -u
```

当前 `/etc/resolv.conf` 预期：

```text
nameserver 192.168.88.222
nameserver 192.168.88.1
```

当前验证：

```text
dig @192.168.88.222 google.com +short -> 28.0.0.x
dig google.com A +short -> 28.0.0.x
dig google.com AAAA +short -> 空
dig @192.168.88.222 baidu.com +short -> 真实国内 IP
curl -x http://192.168.88.222:7890 https://www.google.com/generate_204 -> HTTP 204
curl --resolve www.google.com:443:28.0.0.x https://www.google.com/generate_204 -> HTTP 204
curl --resolve www.youtube.com:443:28.0.0.x https://www.youtube.com/generate_204 -> HTTP 204
curl -4 https://www.google.com/generate_204 -> HTTP 204
curl -6 https://www.google.com/generate_204 -> 无 AAAA 记录，预期解析失败
```

测试期间发现 `节点选择` 默认指向 `香港节点`，但 `香港节点` 只有 `COMPATIBLE` 占位，没有实际出站节点，导致 Google/YouTube TLS 被断开。已在 Mihomo 控制接口把 `节点选择` 切到 `新加坡节点`：

```bash
curl -X PUT http://127.0.0.1:9090/proxies/%E8%8A%82%E7%82%B9%E9%80%89%E6%8B%A9 \
  -H 'Content-Type: application/json' \
  --data '{"name":"新加坡节点"}'
```

当前链路：

```text
192.168.88.144 DNS -> 192.168.88.222 MosDNS
non-CN domain -> 28.0.0.0/8 fake-ip
192.168.88.144 route 28.0.0.0/8 -> 192.168.88.222
MSF nftables -> Mihomo redir/tproxy
节点选择 -> 新加坡节点 -> 华为新加坡1-Halo
```

### 当前测试客户端：192.168.88.155

`192.168.88.155` 是 Win11 测试客户端。已在 MSF WebUI 客户端白名单中加入：

```text
192.168.88.155
```

RouterOS 已有测试路由：

```routeros
/ip/route/add dst-address=28.0.0.0/8 gateway=192.168.88.222 comment="MSF FakeIP v4"
/ipv6/route/add dst-address=f2b0::/18 gateway=2409:8a38:12:4bf0:be24:11ff:fe54:5601 comment="MSF FakeIP v6"
```

当前 MSF DNS 策略：

- `dns.ipv6` 已临时改为 `false`，避免 Win11 优先使用 `f2b0::/18` fake-ip。
- MosDNS 持久缓存已清理一次，避免继续返回旧的 `f2b0::x`。
- 当前预期 YouTube/X 只返回 `28.0.0.x`，AAAA 查询为空。
- 相关备份：
  - `/opt/msf/configs/mihomo/config.yaml.bak-disable-dns-ipv6-20260701-123859`
  - `/opt/msf/configs/mosdns/cache/backup-20260701-1240/`

排障记录：

- 只把 Win11 DNS 改成 `192.168.88.222` 不够；客户端拿到 Fake-IP 后，RouterOS 必须能把 `28.0.0.0/8` 和 `f2b0::/18` 转发到 MSF。
- MSF Mihomo 配置曾有 `fake-ip-filter: ["*"]`，这会让所有域名都绕过 Fake-IP，导致 YouTube/X 返回真实或污染 IP。已删除全局 `*`，只保留 `+.lan`。
- 如果 MSF WebUI 后续保存配置又生成 `fake-ip-filter: ["*"]`，需要在 UI 的 Fake-IP 过滤列表中删除 `*`，然后重启 MSF。
- Win11 透明代理 TLS 失败时，优先区分显式代理和 fake-ip 透明代理：`curl.exe -x http://192.168.88.222:7890 -I https://www.youtube.com/generate_204` 成功，说明节点和 Windows SChannel 基本正常；`curl.exe -I` 失败则重点检查客户端 DNS 缓存、AAAA fake-ip、浏览器 DoH/QUIC 和透明代理路径。

Win11 修改 DNS 或 MSF 规则后，先在管理员 PowerShell 执行：

```powershell
ipconfig /flushdns
```

然后验证：

```powershell
nslookup www.youtube.com 192.168.88.222
nslookup x.com 192.168.88.222
Test-NetConnection 28.0.0.6 -Port 443
curl.exe -I https://www.youtube.com/generate_204
curl.exe -I https://x.com
```

预期：YouTube/X 返回 `28.0.0.x`，不再返回 `f2b0::x`；访问应进入 MSF/Mihomo。

## 验证流程

测试设备续租 DHCP 后：

```bash
dig @192.168.88.222 baidu.com +short
dig @192.168.88.222 google.com +short
```

预期：

- 国内域名返回真实 IP。
- 非 CN 域名返回 `28.0.0.0/8` fake-ip。

RouterOS 查看 fake-ip 路由：

```routeros
/ip/route/print detail where dst-address="28.0.0.0/8"
```

VM 内查看 MSF：

```bash
sudo msf status
sudo msf logs --lines 200 mosdns
sudo msf logs --lines 200 mihomo
sudo ss -lntup | grep -E ':(53|7777|7890|7891|7892|7896|7877|9090)\b'
```

## 回滚

如果测试设备网络异常：

1. 把测试设备 DHCP DNS 改回 RouterOS 默认 DNS `192.168.88.1`。
2. 删除测试设备 lease 上的 `msf-test-dns` option。
3. 如已添加 `28.0.0.0/8` 路由，确认没有其他设备使用 MSF DNS 后删除。
4. 保留 VM 117 便于排障；需要停用时执行：

```bash
ssh root@192.168.88.228
qm shutdown 117
```

`192.168.88.144` 当前临时配置的回滚命令：

```bash
ssh root@192.168.88.144
resolvconf -d lo.msf-test
resolvconf -u
ip route del 28.0.0.0/8 via 192.168.88.222 dev ens18
ip -6 route del f2b0::/18 via fe80::be24:11ff:fe54:5601 dev ens18
```

需要彻底删除测试 VM 时，先确认不再需要 `/opt/msf` 数据，再执行：

```bash
ssh root@192.168.88.228
qm stop 117
qm destroy 117 --purge
```
