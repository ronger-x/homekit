# homekit

`homekit` 是一个为个人或家庭实验室（home-lab）设计的运维工具与脚本集合，目标是简化常见的网络运维、设备管理、自动化与诊断任务。仓库包含若干独立的小工具（scripts 和 utilities），可按需组合用于备份、唤醒远程主机、检查网络状态以及其他便捷运维工作。

组件示例:

- `network/wol_plus.sh` — 一个增强的 Wake-on-LAN 工具，支持配置文件别名、ARP 扫描、通过指定接口发送、交互式菜单以及自动检测并尝试安装 `netcat`。

## 下载脚本（快速命令）
将脚本下载到当前目录并赋可执行权限：

```bash
curl -L -o wol_plus.sh https://raw.githubusercontent.com/ronger-x/homekit/master/network/wol_plus.sh
chmod +x wol_plus.sh
```

将脚本安装到 `/usr/local/bin`（需要 sudo）：

```bash
sudo curl -L -o /usr/local/bin/wol_plus.sh https://raw.githubusercontent.com/ronger-x/homekit/master/network/wol_plus.sh
sudo chmod +x /usr/local/bin/wol_plus.sh
```

使用 `wget` 的等效命令：

```bash
wget -O wol_plus.sh https://raw.githubusercontent.com/ronger-x/homekit/master/network/wol_plus.sh
chmod +x wol_plus.sh
```

## `wol_plus.sh` 参数说明

从 `network/wol_plus.sh` 脚本提取的参数与行为（已在脚本中实现）：

- `-i <接口>`: 指定要使用的网络接口（例如 `eth0`）。脚本会尝试读取该接口的广播地址并使用它作为目标广播地址。
- `-l`: 列出已保存到配置文件（`~/.wol_hosts`）中的设备条目。
- `-s`: 扫描并打印本地 ARP 表，用于发现局域网内的设备及其 MAC 地址。
- `-a <别名> <MAC>`: 将一个别名与 MAC 地址保存到配置文件，格式：`别名 MAC [广播IP] [端口]`。如果未指定广播 IP，会使用接口广播或全局 255.255.255.255。
- `-h`: 显示帮助信息。

位置参数：
- `<别名/MAC>`: 如果传入的是在配置文件中存在的别名，会使用配置中的 MAC/广播设置；否则脚本会验证传入字符串是否为合法 MAC 地址并直接发送唤醒包。
- `<广播IP> <端口>`: 当直接传入 MAC 时，可追加广播 IP 和端口覆盖默认值。

默认行为与实现细节：
- 配置文件路径：`~/.wol_hosts`。首次运行会创建并加入注释示例行。
- 默认端口：`9`。
- 脚本会尝试检测并安装 `netcat`（`nc`），需要 root 权限才能自动安装。如果没有 `nc`，脚本会回退到 `/dev/udp` 方法（仅在支持该特性的 shell 下可用）。
- 交互式模式：当不传参数时，脚本提供交互菜单，可选择保存的设备、手动输入 MAC 或扫描 ARP。

更多示例：

```bash
# 使用别名唤醒
wol_plus.sh nas

# 使用 MAC + 指定广播和端口
wol_plus.sh 00:11:22:33:44:55 192.168.1.255 9

# 通过指定接口发送（脚本会自动解析广播地址）
wol_plus.sh -i eth0 pc1

# 添加别名到配置
wol_plus.sh -a pc2 00:11:22:33:44:66 -i eth0
```

## 目录结构

- `network/` — 存放与网络相关的脚本，例如 `wol_plus.sh`。

## 快速开始

下面展示如何使用仓库中的 `wol_plus.sh` 脚本来发送 Wake-on-LAN 魔术包以唤醒远程主机。

> 注意：`wol_plus.sh` 是一个基于 Unix shell 的脚本。 在 Windows 上请使用 WSL、Git Bash 或 Cygwin 等工具运行。

### 先决条件

- 一个能接收 Wake-on-LAN 的远程主机，并在 BIOS/UEFI 中启用 WOL。 
- 目标主机网卡需支持并启用 WOL。
- 在运行脚本的机器上安装 `bash`（macOS/Linux 默认可用；Windows 请安装 WSL 或 Git Bash）。

### 使用方法（示例）

在终端中运行：

```bash
cd network
./wol_plus.sh <MAC_ADDRESS>
```

示例：

```bash
./wol_plus.sh 00:11:22:33:44:55
```

如果脚本需要额外参数（例如广播地址、端口或重复次数），请参考脚本顶部注释或运行 `--help`（如果支持）。

### 在 Windows 上运行

- 使用 WSL：在 WSL 终端中按上述说明运行脚本。
- 使用 Git Bash：确保 `bash` 可用并在 Git Bash 终端中运行脚本。

## 贡献

欢迎提交 issue 或 pull request。请在提交前确保：

- 解释清楚你要添加或修复的内容。
- 保持脚本兼容常见 Unix shell。

## 许可

本项目采用 Apache-2.0 许可证，详情请参阅 `LICENSE` 文件。
