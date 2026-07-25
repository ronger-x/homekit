# OneDev 迁移到 PVE VMID 119 维护记录

本文记录 2026-07-09 将远程源机上的 OneDev 服务从 `/opt/docker/`
迁移到 PVE 新 VM 的过程和当前运行状态。源机地址和 SSH 用户只通过
`SOURCE_HOST`、`SOURCE_SSH_USER` 变量提供，不写入仓库。

## 资源

```text
VMID: 119
name: 1dev-migrated
IP: 192.168.88.37/24
MAC: BC:24:11:BB:47:A1
OS: Ubuntu 24.04.4 LTS cloud image
storage: storage1
disk: 120 GB
memory: 8192 MB
cores: 4
cpu: host
bridge: vmbr0
onboot: enabled
tags: onedev;1dev;4c8g;migrated
```

PVE 查看命令：

```bash
ssh root@192.168.88.228
qm status 119
qm config 119
qm agent 119 network-get-interfaces
```

VM 登录：

```bash
ssh ubuntu@192.168.88.37
```

## RouterOS DHCP

RouterOS 已将新 VM 的 DHCP lease 固定为 `192.168.88.37`，并按迁移
要求让该 VM 的默认网关和 DNS 都走 `192.168.88.169`。

```text
mac-address: BC:24:11:BB:47:A1
address: 192.168.88.37
dhcp-option: openclash-backup-gateway,openclash-backup-dns
comment: 1dev VMID119 via OpenClash 192.168.88.169
```

验证命令：

```routeros
/ip/dhcp-server/lease/print detail where mac-address="BC:24:11:BB:47:A1"
/ip/dhcp-server/option/print detail where name~"openclash-backup"
```

VM 内验证：

```bash
ip route show default
resolvectl dns eth0
```

预期：

```text
default via 192.168.88.169 dev eth0
Link 2 (eth0): 192.168.88.169
```

## OneDev 服务

```text
compose path: /opt/docker/docker-compose.yaml
container: onedev
image: 1dev/server:15.1.4
ports: 6610/tcp, 6611/tcp
data: /opt/docker/onedev -> /opt/onedev
docker socket: /var/run/docker.sock -> /var/run/docker.sock
```

常用命令：

```bash
ssh ubuntu@192.168.88.37
cd /opt/docker
sudo docker compose -f docker-compose.yaml ps
sudo docker compose -f docker-compose.yaml logs -f --tail=100 onedev
sudo docker compose -f docker-compose.yaml restart onedev
```

Web 访问：

```text
http://192.168.88.37:6610/
```

## 迁移结果

源服务：

```text
source: ${SOURCE_SSH_USER}@${SOURCE_HOST}:/opt/docker/
old container: stopped and removed with docker compose down
```

迁移方式：

1. 新建 Ubuntu 24.04 VMID `119`，规格 4C8G，磁盘 120G。
2. 安装 `docker.io`、`docker-compose-v2`、`qemu-guest-agent`、`rsync`。
3. 源机通过 Tailscale 路由直连 `192.168.88.37`，先在线预同步
   `/opt/docker/`，再停源机 `onedev` 做最终增量同步。
4. 最后补同步根目录的
   `onedev-pre-upgrade-12.0.4-to-15.1.4-20260606-100737.tgz` 备份包。
5. 迁移用临时 SSH key 已从源机和新 VM `authorized_keys` 中移除。

最终校验：

```text
source /opt/docker: 6.1G
target /opt/docker: 6.1G
target container: onedev Up, image 1dev/server:15.1.4
target HTTP: http://192.168.88.37:6610/ returns HTTP 200
target TCP: 6611 reachable
old source container: none
```

启动日志中出现过一次项目 `useatdak/aura` 分支计划缓存异常：

```text
Error caching branch schedules (project: useatdak/aura, branch: master)
```

应用仍正常启动并返回 HTTP 200。若后续该项目的定时构建异常，优先检查
该项目的 build spec / schedule 配置。

## 回滚边界

源机 `/opt/docker/` 数据仍保留，源容器只是被 `docker compose down`
停止并移除。若需要在产生新写入前回滚，可在源机执行：

```bash
SOURCE_HOST="<SOURCE_HOST>"
SOURCE_SSH_USER="<SOURCE_SSH_USER>"
ssh "${SOURCE_SSH_USER}@${SOURCE_HOST}"
cd /opt/docker
docker compose -f docker-compose.yaml up -d
```

如果新 VM 已产生提交、构建、账号设置等新写入，回滚前必须先决定是否
把新 VM 的 `/opt/docker/` 反向同步回源机，否则会丢失迁移后的变更。
