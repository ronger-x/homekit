# RouterOS OpenClash DHCP 单设备维护手册

本文记录在 RouterOS 7.x 上，把指定 LAN 客户端的 DHCP 网关和 DNS 直接下发为 OpenClash 网关的方法。

> 状态：兼容方案，仅用于明确需要 OpenClash 的单设备例外，不改变 RouterOS 全局 DHCP。

当前环境约定：

- RouterOS 管理地址：`192.168.88.1`
- OpenClash 网关/DNS：`192.168.88.169`
- DHCP server：`defconf`
- LAN 网段：`192.168.88.0/24`
- 默认 DHCP network 仍保持 `gateway=192.168.88.1 dns-server=192.168.88.1`
- 单设备例外通过 DHCP lease 的 `dhcp-option` 覆盖实现

## 当前使用的 DHCP Option

以下 option 用于把网关和 DNS 下发为 `192.168.88.169`：

```routeros
/ip/dhcp-server/option
add name=openclash-gateway code=3 value=0xC0A858A9
add name=openclash-dns code=6 value=0xC0A858A9
```

说明：

- `code=3` 是 DHCP Router/Gateway option。
- `code=6` 是 DHCP DNS Server option。
- `0xC0A858A9` 是 `192.168.88.169` 的十六进制表示。

可以用仓库脚本转换 IPv4：

```bash
./network/routeros_dhcp_hex.sh 192.168.88.169
# 0xC0A858A9
```

如果 option 已存在，只需要复用，不要重复创建。

## 添加设备

目标：让某个客户端通过 DHCP 直接拿到：

- 默认网关：`192.168.88.169`
- DNS：`192.168.88.169`

### 1. 查找当前 lease

按 IP 查：

```routeros
/ip/dhcp-server/lease/print detail where active-address=192.168.88.154
```

或按主机名/MAC 查：

```routeros
/ip/dhcp-server/lease/print detail where host-name="t14p"
```

确认输出中的 `address`、`mac-address`、`host-name` 确实是目标设备。

### 2. 确保 OpenClash DHCP option 存在

```routeros
/ip/dhcp-server/option/print detail where name~"openclash"
```

如果不存在，创建：

```routeros
/ip/dhcp-server/option/add name=openclash-gateway code=3 value=0xC0A858A9
/ip/dhcp-server/option/add name=openclash-dns code=6 value=0xC0A858A9
```

### 3. 固定 lease 并绑定 option

以 `192.168.88.154` 为例：

```routeros
/ip/dhcp-server/lease/make-static [find where active-address=192.168.88.154]
/ip/dhcp-server/lease/set [find where address=192.168.88.154] dhcp-option=openclash-gateway,openclash-dns comment="via OpenClash gateway 192.168.88.169"
```

以 `192.168.88.155` 为例：

```routeros
/ip/dhcp-server/lease/make-static [find where active-address=192.168.88.155]
/ip/dhcp-server/lease/set [find where address=192.168.88.155] dhcp-option=openclash-gateway,openclash-dns comment="via OpenClash gateway 192.168.88.169"
```

### 4. 让客户端续租

RouterOS 侧配置生效后，客户端需要重新获取 DHCP lease。

Windows 客户端执行：

```powershell
ipconfig /release
ipconfig /renew
ipconfig /all
```

或断开/重连网卡。

续租后应看到：

- `Default Gateway . . . : 192.168.88.169`
- `DNS Servers . . . . . : 192.168.88.169`

## 删除设备

目标：让某个客户端恢复使用默认 DHCP network，也就是网关/DNS 回到 `192.168.88.1`。

### 1. 移除 lease 上的 OpenClash option

以 `192.168.88.154` 为例：

```routeros
/ip/dhcp-server/lease/set [find where address=192.168.88.154] dhcp-option="" comment=""
```

以 `192.168.88.155` 为例：

```routeros
/ip/dhcp-server/lease/set [find where address=192.168.88.155] dhcp-option="" comment=""
```

### 2. 是否删除静态 lease

如果只想恢复默认网关/DNS，但仍保留固定 IP，不要删除 lease。

如果想完全恢复动态 DHCP 分配，可以删除静态 lease：

```routeros
/ip/dhcp-server/lease/remove [find where address=192.168.88.154]
```

然后让客户端重新 DHCP 获取地址。

注意：删除静态 lease 后，客户端不一定还会拿到原 IP。

### 3. 让客户端续租

Windows 客户端执行：

```powershell
ipconfig /release
ipconfig /renew
ipconfig /all
```

续租后应看到默认网关/DNS 回到全局 DHCP network 配置。

## 验证

查看指定 lease：

```routeros
/ip/dhcp-server/lease/print detail where address=192.168.88.154
/ip/dhcp-server/lease/print detail where address=192.168.88.155
```

启用 OpenClash 直连网关时，目标 lease 应包含：

```text
dhcp-option=openclash-gateway,openclash-dns
```

查看 DHCP option：

```routeros
/ip/dhcp-server/option/print detail where name~"openclash"
```

应看到：

```text
openclash-gateway code=3 raw-value="c0a858a9"
openclash-dns code=6 raw-value="c0a858a9"
```

确认旧策略已清除：

```routeros
/routing/rule/print detail
/routing/table/print detail where name=to-openclash
/ip/route/print detail where routing-table=to-openclash
/ip/firewall/nat/print detail where comment~"force-dns-openclash"
```

在当前维护方案下，不需要以下旧配置：

- `src-address=192.168.88.154/32 action=lookup table=to-openclash`
- `src-address=192.168.88.155/32 action=lookup table=to-openclash`
- `force-dns-openclash` 的 DNS dstnat 规则
- `to-openclash` routing table 和对应默认路由

## 注意事项

- DHCP lease 的 `dhcp-option` 优先级高于 DHCP network，所以可以只影响指定设备。
- 不要直接修改 `/ip dhcp-server network` 为 `gateway=192.168.88.169 dns-server=192.168.88.169`，除非你希望整个 LAN 都默认走 OpenClash。
- 旧的 RouterOS 策略路由方案适用于“客户端网关仍是 `192.168.88.1`，由 RouterOS 转发到 OpenClash”的设计；现在改成“客户端直接以 `192.168.88.169` 为网关”，因此不再需要 `to-openclash`。
- 如果客户端还显示 `192.168.88.1`，通常是没有续租，不是 RouterOS 配置未生效。
