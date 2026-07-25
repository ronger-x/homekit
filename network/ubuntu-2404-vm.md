# Ubuntu 24.04 通用 VM 维护记录

本文记录在 PVE 上创建的 Ubuntu 24.04 通用虚拟机。该 VM 使用已有
Ubuntu 24.04 cloud image 导入安装，磁盘位于 `storage1`。

## 资源

```text
VMID: 112
name: ubuntu-2404
IP: 192.168.88.39/24
gateway: DHCP from RouterOS defconf
MAC: BC:24:11:AB:39:48
OS: Ubuntu 24.04.4 LTS cloud image
image: local:iso/ubuntu-24.04-server-cloudimg-amd64.img
storage: storage1
disk: 200 GB
memory: 16384 MB
cores: 8
cpu: host
bridge: vmbr0
onboot: disabled
tags: 24.04;8c16g;ubuntu
```

RouterOS DHCP 已将该 MAC 的租约转为 static lease：

```text
address: 192.168.88.39
comment: ubuntu-2404 VMID112
```

## 访问

```bash
ssh ubuntu@192.168.88.39
```

cloud-init 用户为 `ubuntu`，SSH 公钥来自 PVE 节点
`/root/.ssh/authorized_keys`。不要在仓库中记录密码或代理凭据。

## PVE 查看命令

```bash
ssh root@192.168.88.228
qm status 112
qm config 112
qm guest cmd 112 network-get-interfaces
```

## 当前验证

```text
PVE VM: running
QEMU guest agent: active, reboot 后可恢复
IPv4: 192.168.88.39
OS: Ubuntu 24.04.4 LTS
CPU: 8 cores
memory: about 16 GB
swap: 16 GB /swapfile
disk: /dev/sda 200G
root filesystem: /dev/sda1 about 193G
cloud-init: done, degraded only because PVE emits a deprecated user field
```

`qemu-guest-agent` 已安装并启动。Ubuntu 24.04 中该 unit 显示为 `static`，
但重启后已验证会随 virtio guest-agent 设备恢复。

注意：PVE 当前 VM112 配置仍保留旧的 `nameserver: 192.168.88.220 223.5.5.5`。
PaoPaoDNS 已删除，下一次维护或 cloud-init 重建前应改为 RouterOS DNS
`192.168.88.1 223.5.5.5`，不要继续依赖 `.220`。

## NovaReel2 开发服务

`/apps/NovaReel2` 上存在 `novareel2-dev.service`。2026-07-09 排查内存异常时
确认该服务运行 `npm run dev`，会同时启动 Next.js、worker、watchdog 和 Bull
Board。该服务曾导致 VM 内存打满、SSH 与 QEMU guest agent 假死。

当前处理状态：

```text
novareel2-dev.service: disabled, inactive
swap: /swapfile 16G, fstab 持久化
systemd drop-in: /etc/systemd/system/novareel2-dev.service.d/resource-guard.conf
MemoryHigh: 10G
MemoryMax: 12G
StartLimitBurst: 3 per 300s
```

如需临时恢复 3000 端口：

```bash
sudo systemctl start novareel2-dev.service
sudo journalctl -u novareel2-dev.service -f
free -h
```

不要在确认内存曲线稳定前重新启用开机自启。

## 安装/重建参考

以下为本次使用的主要流程，命令在 PVE 节点上执行：

```bash
STORAGE="storage1"
IMG="/var/lib/vz/template/iso/ubuntu-24.04-server-cloudimg-amd64.img"
VMID="$(pvesh get /cluster/nextid)"

qm create "$VMID" \
  --name ubuntu-2404 \
  --ostype l26 \
  --machine q35 \
  --memory 16384 \
  --cores 8 \
  --cpu host \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --scsihw virtio-scsi-single \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0 \
  --onboot 0 \
  --tags "24.04;8c16g;ubuntu"

qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${IMG}"
qm resize "$VMID" scsi0 200G
qm rescan --vmid "$VMID"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --ciuser ubuntu --ipconfig0 ip=dhcp \
  --nameserver "192.168.88.1 223.5.5.5" --searchdomain local
qm set "$VMID" --sshkeys /root/.ssh/authorized_keys
qm start "$VMID"
```

如果 guest agent 未预装，可在 VM 内临时设置代理环境变量后安装
`qemu-guest-agent`；不要把带账号密码的代理地址写入文件。
