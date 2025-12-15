#!/bin/bash

# 配置文件路径
CONFIG_FILE="${HOME}/.wol_hosts"
# 默认端口
DEFAULT_PORT=9

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查并安装 netcat
check_and_install_nc() {
    if ! command -v nc >/dev/null 2>&1; then
        echo -e "${YELLOW}netcat (nc) 未找到，正在尝试自动安装...${NC}"
        # 检查 root 权限
        if [ "$(id -u)" -ne 0 ]; then
            echo -e "${RED}需要 root 权限来安装 netcat。请使用 sudo 运行此脚本或手动安装。${NC}"
            return 1
        fi

        if command -v apt-get >/dev/null 2>&1; then
            echo "检测到 apt, 正在使用 apt-get 安装..."
            apt-get update && apt-get install -y netcat-openbsd
        elif command -v yum >/dev/null 2>&1; then
            echo "检测到 yum, 正在使用 yum 安装..."
            yum install -y nc
        elif command -v dnf >/dev/null 2>&1; then
            echo "检测到 dnf, 正在使用 dnf 安装..."
            dnf install -y nc
        elif command -v pacman >/dev/null 2>&1; then
            echo "检测到 pacman, 正在使用 pacman 安装..."
            pacman -Syu --noconfirm gnu-netcat
        else
            echo -e "${RED}无法检测到包管理器 (apt, yum, dnf, pacman)。${NC}"
            echo -e "${RED}请手动安装 'netcat' (或 'nc')。${NC}"
            return 1
        fi

        if ! command -v nc >/dev/null 2>&1; then
            echo -e "${RED}netcat 安装失败。脚本可能无法正常发送唤醒包。${NC}"
            return 1
        else
            echo -e "${GREEN}netcat 安装成功！${NC}"
        fi
    fi
    return 0
}

# 初始化配置文件
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        touch "$CONFIG_FILE"
        echo "# 格式: 别名 MAC地址 [广播IP] [端口]" >> "$CONFIG_FILE"
        echo "# 示例: nas 00:11:22:33:44:55 192.168.1.255 9" >> "$CONFIG_FILE"
    fi
}

# 发送 Magic Packet 函数
send_magic_packet() {
    local mac_addr="$1"
    local broadcast_ip="${2:-255.255.255.255}"
    local port="${3:-$DEFAULT_PORT}"

    # 清理 MAC 地址
    local mac_clean=$(echo "$mac_addr" | sed 's/[:-]//g')

    # 验证 MAC
    if [[ ! "$mac_clean" =~ ^[0-9A-Fa-f]{12}$ ]]; then
        echo -e "${RED}错误: 无效的 MAC 地址格式: $mac_addr${NC}"
        return 1
    fi

    # 构建 Payload
    local b1=${mac_clean:0:2}
    local b2=${mac_clean:2:2}
    local b3=${mac_clean:4:2}
    local b4=${mac_clean:6:2}
    local b5=${mac_clean:8:2}
    local b6=${mac_clean:10:2}
    local mac_hex="\x$b1\x$b2\x$b3\x$b4\x$b5\x$b6"
    local payload="\xff\xff\xff\xff\xff\xff"
    for i in {1..16}; do payload+="$mac_hex"; done

    echo -e "正在唤醒 ${YELLOW}$mac_addr${NC} -> ${BLUE}$broadcast_ip:$port${NC} ..."
    
    # 使用 netcat (nc) 发送 UDP 包，更具可移植性
    if command -v nc >/dev/null 2>&1; then
        if printf "$payload" | nc -w1 -u -b "$broadcast_ip" "$port"; then
            echo -e "${GREEN}✔ 唤醒包发送成功！${NC}"
        else
            echo -e "${RED}✘ 使用 nc 发送失败。${NC}"
        fi
    # 备用方法：使用 bash 内置的 /dev/udp
    elif printf "$payload" > /dev/udp/"$broadcast_ip"/"$port"; then
        echo -e "${GREEN}✔ 唤醒包发送成功！${NC}"
    else
        echo -e "${RED}✘ 发送失败。请检查网络、权限或尝试安装 netcat。${NC}"
    fi
}

# 获取接口广播地址
get_iface_broadcast() {
    local iface="$1"
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show "$iface" | grep -oP '(?<=brd )[\d.]+' | head -n 1
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$iface" | grep -oP '(?<=broadcast )[\d.]+' | head -n 1
    fi
}

# 扫描 ARP 表
scan_arp() {
    echo -e "${BLUE}正在扫描 ARP 缓存...${NC}"
    echo "------------------------------------------------"
    printf "%-20s %-20s %-10s\n" "IP地址" "MAC地址" "接口"
    echo "------------------------------------------------"
    
    # 尝试读取 /proc/net/arp 或使用 ip neigh
    if command -v ip >/dev/null 2>&1; then
        ip neigh show | grep -v "FAILED" | while read -r line; do
            ip=$(echo "$line" | awk '{print $1}')
            mac=$(echo "$line" | awk '{print $5}')
            dev=$(echo "$line" | awk '{print $3}')
            if [[ "$mac" =~ ^[0-9a-fA-F:]{17}$ ]]; then
                printf "%-20s %-20s %-10s\n" "$ip" "$mac" "$dev"
            fi
        done
    else
        cat /proc/net/arp | tail -n +2 | while read -r line; do
            ip=$(echo "$line" | awk '{print $1}')
            mac=$(echo "$line" | awk '{print $4}')
            dev=$(echo "$line" | awk '{print $6}')
            if [[ "$mac" != "00:00:00:00:00:00" ]]; then
                printf "%-20s %-20s %-10s\n" "$ip" "$mac" "$dev"
            fi
        done
    fi
    echo "------------------------------------------------"
}

# 显示帮助
show_help() {
    echo "用法: $0 [选项] [别名/MAC]"
    echo "选项:"
    echo "  -i <接口>    指定发送接口 (自动获取广播地址)"
    echo "  -l           列出已保存的设备"
    echo "  -s           扫描局域网设备 (ARP)"
    echo "  -a <别名> <MAC>  添加设备到配置"
    echo "  -h           显示帮助"
    echo ""
    echo "示例:"
    echo "  $0 pc1                  # 唤醒别名为 pc1 的设备"
    echo "  $0 00:11:22:33:44:55    # 直接唤醒 MAC"
    echo "  $0 -i eth0 pc1          # 通过 eth0 接口唤醒"
    echo "  $0                      # 进入交互式菜单"
}

# 主逻辑
check_and_install_nc
init_config

INTERFACE=""
BROADCAST_IP=""
ADD_ALIAS=""

# 解析参数
while getopts "i:lsa:h" opt; do
    case $opt in
        i)
            INTERFACE="$OPTARG"
            BROADCAST_IP=$(get_iface_broadcast "$INTERFACE")
            if [ -z "$BROADCAST_IP" ]; then
                echo -e "${RED}错误: 无法获取接口 $INTERFACE 的广播地址${NC}"
                exit 1
            fi
            ;;
        l)
            echo -e "${YELLOW}已保存的设备 ($CONFIG_FILE):${NC}"
            grep -v "^#" "$CONFIG_FILE" | column -t
            exit 0
            ;;
        s)
            scan_arp
            exit 0
            ;;
        a)
            ADD_ALIAS="$OPTARG"
            ;;
        h)
            show_help
            exit 0
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
done

shift $((OPTIND-1))

# 处理添加设备模式
if [ -n "$ADD_ALIAS" ]; then
    TARGET_MAC="$1"
    if [ -z "$TARGET_MAC" ]; then
        echo -e "${RED}错误: 添加设备需要指定 MAC 地址。${NC}"
        echo "用法: $0 -a <别名> <MAC> [-i 接口]"
        exit 1
    fi

    # 验证 MAC
    CLEAN_MAC=$(echo "$TARGET_MAC" | sed 's/[:-]//g')
    if [[ ! "$CLEAN_MAC" =~ ^[0-9A-Fa-f]{12}$ ]]; then
         echo -e "${RED}错误: 无效的 MAC 地址格式: $TARGET_MAC${NC}"
         exit 1
    fi

    # 检查别名是否存在
    if grep -q "^$ADD_ALIAS " "$CONFIG_FILE"; then
        echo -e "${RED}错误: 别名 '$ADD_ALIAS' 已存在。${NC}"
        exit 1
    fi

    # 确定广播 IP (优先使用 -i 指定的接口广播地址)
    SAVE_IP="${BROADCAST_IP:-255.255.255.255}"
    
    echo "$ADD_ALIAS $TARGET_MAC $SAVE_IP $DEFAULT_PORT" >> "$CONFIG_FILE"
    echo -e "${GREEN}已添加: $ADD_ALIAS -> $TARGET_MAC ($SAVE_IP)${NC}"
    exit 0
fi

TARGET="$1"
ARG_IP="$2"
ARG_PORT="$3"

# 如果没有参数，进入交互模式
if [ -z "$TARGET" ]; then
    echo -e "${BLUE}=== WOL Plus 交互模式 ===${NC}"
    echo "1. 选择已保存设备唤醒"
    echo "2. 输入 MAC 地址唤醒"
    echo "3. 扫描 ARP 表"
    echo "4. 退出"
    read -p "请选择 [1-4]: " choice
    
    case $choice in
        1)
            echo -e "\n${YELLOW}设备列表:${NC}"
            # 读取配置到数组
            mapfile -t hosts < <(grep -v "^#" "$CONFIG_FILE" | grep -v "^$")
            if [ ${#hosts[@]} -eq 0 ]; then
                echo "没有已保存的设备。"
                exit 0
            fi
            
            i=1
            for host in "${hosts[@]}"; do
                echo "$i) $host"
                ((i++))
            done
            
            read -p "输入序号: " num
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#hosts[@]}" ]; then
                line="${hosts[$((num-1))]}"
                TARGET=$(echo "$line" | awk '{print $1}') # 获取别名
            else
                echo "无效选择"
                exit 1
            fi
            ;;
        2)
            read -p "输入 MAC 地址: " mac_input
            TARGET="$mac_input"
            ;;
        3)
            scan_arp
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
fi

# 检查 TARGET 是别名还是 MAC
# 尝试在配置中查找别名
CONFIG_LINE=$(grep -w "^$TARGET" "$CONFIG_FILE" | head -n 1)

if [ -n "$CONFIG_LINE" ]; then
    # 是别名
    MAC=$(echo "$CONFIG_LINE" | awk '{print $2}')
    CFG_BCAST=$(echo "$CONFIG_LINE" | awk '{print $3}')
    CFG_PORT=$(echo "$CONFIG_LINE" | awk '{print $4}')
    
    # 优先级: 命令行指定接口广播 > 配置文件广播 > 默认全局广播
    [ -z "$BROADCAST_IP" ] && BROADCAST_IP=${CFG_BCAST:-255.255.255.255}
    PORT=${CFG_PORT:-$DEFAULT_PORT}
    
    echo -e "找到别名 '${TARGET}': MAC=${MAC}"
    send_magic_packet "$MAC" "$BROADCAST_IP" "$PORT"
else
    # 假设是 MAC 地址
    # 验证是否像 MAC 地址
    CLEAN_TARGET=$(echo "$TARGET" | sed 's/[:-]//g')
    if [[ "$CLEAN_TARGET" =~ ^[0-9A-Fa-f]{12}$ ]]; then
        if [ -n "$ARG_IP" ]; then
            BROADCAST_IP="$ARG_IP"
        elif [ -z "$BROADCAST_IP" ]; then
            BROADCAST_IP="255.255.255.255"
        fi
        PORT="${ARG_PORT:-$DEFAULT_PORT}"
        send_magic_packet "$TARGET" "$BROADCAST_IP" "$PORT"
    else
        echo -e "${RED}错误: 未找到别名 '$TARGET' 且不是有效的 MAC 地址。${NC}"
        exit 1
    fi
fi