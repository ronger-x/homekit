#!/bin/bash
# OSPF + sing-box 智能分流部署脚本
# 使用方法: 在 PVE 主机上执行此脚本

set -e

echo "=========================================="
echo "OSPF + sing-box 智能分流部署脚本"
echo "=========================================="
echo ""

# 配置变量
VMID=250
CONTAINER_IP="192.168.88.250"
GATEWAY="192.168.88.1"
DNS_SERVER="192.168.88.243"

# 从 .env 文件加载配置（如果存在）
if [ -f "$(dirname "$0")/.env" ]; then
    echo "加载 .env 配置..."
    source "$(dirname "$0")/.env"
fi

# 必须配置的变量（如果 .env 中未设置，则使用占位符）
OSPF_PASSWORD="${OSPF_PASSWORD:-ChangeThisPassword123}"  # 必须修改！
SUBSCRIPTION_URL="${SINGBOX_SUBSCRIPTION_URL:-http://your-subscription-service/path/to/subscription}"

# 验证必须的配置
if [ "$OSPF_PASSWORD" = "ChangeThisPassword123" ]; then
    echo "错误: 请在 .env 文件中设置 OSPF_PASSWORD"
    echo "或直接修改脚本中的 OSPF_PASSWORD 变量"
    exit 1
fi

if [[ "$SUBSCRIPTION_URL" == *"your-subscription-service"* ]]; then
    echo "错误: 请在 .env 文件中设置 SINGBOX_SUBSCRIPTION_URL"
    echo "或直接修改脚本中的 SUBSCRIPTION_URL 变量"
    exit 1
fi

echo "配置信息:"
echo "  容器 VMID: $VMID"
echo "  容器 IP: $CONTAINER_IP"
echo "  网关: $GATEWAY"
echo "  DNS: $DNS_SERVER"
echo ""

# 检查是否在 PVE 上运行
if ! command -v pct &> /dev/null; then
    echo "错误: 未找到 pct 命令，请在 Proxmox VE 主机上运行此脚本"
    exit 1
fi

echo "Step 1: 检查容器是否已存在..."
if pct status $VMID &>/dev/null; then
    echo "警告: 容器 $VMID 已存在"
    read -p "是否删除并重建? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pct stop $VMID 2>/dev/null || true
        pct destroy $VMID
    else
        echo "使用现有容器，跳过创建步骤"
        SKIP_CREATE=1
    fi
fi

if [ -z "$SKIP_CREATE" ]; then
    echo "Step 2: 创建 LXC 容器..."

    # 查找 Debian 模板
    TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -1)
    if [ -z "$TEMPLATE" ]; then
        echo "未找到 Debian 12 模板，正在下载..."
        pveam update
        pveam download local debian-12-standard_12.2-1_amd64.tar.zst
        TEMPLATE=$(pveam list local | grep debian-12 | awk '{print $1}' | head -1)
    fi

    echo "使用模板: $TEMPLATE"

    pct create $VMID $TEMPLATE \
      --hostname ospf-router \
      --memory 512 \
      --swap 512 \
      --cores 1 \
      --net0 name=eth0,bridge=vmbr0,ip=${CONTAINER_IP}/24,gw=$GATEWAY \
      --nameserver $DNS_SERVER \
      --onboot 1 \
      --unprivileged 1 \
      --features nesting=1 \
      --storage local-lvm \
      --rootfs local-lvm:8

    echo "启动容器..."
    pct start $VMID
    sleep 10
fi

echo ""
echo "Step 3: 容器内基础配置..."

# 在容器内执行命令的函数
pct_exec() {
    pct exec $VMID -- bash -c "$1"
}

echo "  - 更新系统并安装软件包..."
pct_exec "apt update && DEBIAN_FRONTEND=noninteractive apt install -y bird2 nftables curl net-tools iproute2 iputils-ping traceroute tcpdump vim wget dnsutils"

echo "  - 启用 IP 转发..."
pct_exec "cat >> /etc/sysctl.conf << 'EOF'

# Enable IP forwarding for OSPF split routing
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF"
pct_exec "sysctl -p"

echo ""
echo "Step 4: 安装 sing-box..."
SINGBOX_VERSION="1.8.0"
pct_exec "cd /tmp && wget -q https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
pct_exec "cd /tmp && tar -xzf sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"
pct_exec "cp /tmp/sing-box-${SINGBOX_VERSION}-linux-amd64/sing-box /usr/local/bin/"
pct_exec "chmod +x /usr/local/bin/sing-box"
echo "  sing-box 版本: $(pct_exec 'sing-box version' | head -1)"

echo ""
echo "Step 5: 下载并配置 sing-box..."
pct_exec "mkdir -p /etc/sing-box"

# 下载订阅配置
echo "  - 下载订阅配置..."
pct_exec "curl -s -L '$SUBSCRIPTION_URL' -o /tmp/subscription.json"

# 创建完整的 sing-box 配置
pct_exec 'cat > /etc/sing-box/config.json << '\''SINGBOXEOF'\''
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "https://1.1.1.1/dns-query",
        "detour": "proxy"
      },
      {
        "tag": "dns-local",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "dns-local"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "mtu": 9000,
      "auto_route": false,
      "stack": "system",
      "sniff": true
    }
  ],
  "outbounds": [],
  "route": {
    "rules": [
      {
        "network": "udp",
        "port": 53,
        "outbound": "direct"
      },
      {
        "ip_cidr": ["224.0.0.0/4", "255.255.255.255/32"],
        "outbound": "block"
      }
    ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
SINGBOXEOF'

# 合并订阅的节点到配置
pct_exec 'python3 << '\''PYEOF'\''
import json

# 读取基础配置
with open("/etc/sing-box/config.json", "r") as f:
    config = json.load(f)

# 读取订阅
with open("/tmp/subscription.json", "r") as f:
    subscription = json.load(f)

# 提取节点标签
node_tags = []
for node in subscription.get("outbounds", []):
    if "tag" in node and "server" in node:
        node_tags.append(node["tag"])
        config["outbounds"].append(node)

# 添加 urltest 选择器
config["outbounds"].insert(0, {
    "type": "urltest",
    "tag": "proxy",
    "outbounds": node_tags,
    "url": "https://www.gstatic.com/generate_204",
    "interval": "3m",
    "tolerance": 50
})

# 添加 direct 和 block
config["outbounds"].append({"type": "direct", "tag": "direct"})
config["outbounds"].append({"type": "block", "tag": "block"})

# 保存
with open("/etc/sing-box/config.json", "w") as f:
    json.dump(config, f, indent=2)

print(f"配置完成，共 {len(node_tags)} 个节点")
PYEOF'

# 验证配置
pct_exec "sing-box check -c /etc/sing-box/config.json"

echo ""
echo "Step 6: 创建 sing-box systemd 服务..."
pct_exec 'cat > /etc/systemd/system/sing-box.service << '\''EOF'\''
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF'

pct_exec "systemctl daemon-reload"
pct_exec "systemctl enable sing-box"
pct_exec "systemctl start sing-box"
sleep 5

echo "  检查 sing-box 状态..."
pct_exec "systemctl status sing-box --no-pager" || true

echo ""
echo "Step 7: 配置 nftables..."
pct_exec 'cat > /etc/nftables.conf << '\''EOF'\''
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        tcp flags & (syn | rst) == syn tcp option maxseg size set rt mtu
        ct state { established, related } accept
        iif "eth0" oifname "tun0" accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "tun0" masquerade
    }
}
EOF'

pct_exec "chmod +x /etc/nftables.conf"
pct_exec "systemctl enable nftables"
pct_exec "systemctl restart nftables"

echo ""
echo "Step 8: 解析节点 IP 并生成路由表..."

# 在容器内解析域名
pct_exec 'cat > /tmp/get_node_ips.sh << '\''SCRIPT'\''
#!/bin/bash
cat /etc/sing-box/config.json | grep "\"server\":" | grep -oE "[a-zA-Z0-9.-]+" | sort -u | while read domain; do
    if [[ "$domain" =~ ^[0-9.]+$ ]]; then
        echo "$domain/32"
    else
        ip=$(nslookup "$domain" 8.8.8.8 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk "'\'''{print $2}'\'' | head -1)
        if [ -z "$ip" ]; then
            ip=$(nslookup "$domain" 8.8.8.8 2>/dev/null | grep "Address:" | grep -v "#53" | awk "'\'''{print $2}'\'' | head -1)
        fi
        if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
            echo "$ip/32"
        fi
    fi
done | sort -u > /tmp/exclude_ips.txt
SCRIPT'
pct_exec "chmod +x /tmp/get_node_ips.sh"
pct_exec "/tmp/get_node_ips.sh"

echo "  需要排除的 IP:"
pct_exec "cat /tmp/exclude_ips.txt"

echo ""
echo "  - 安装 git 和克隆 nchnroutes..."
pct_exec "apt install -y git python3"
pct_exec "cd /tmp && git clone https://github.com/dndx/nchnroutes.git || (cd nchnroutes && git pull)"

echo "  - 生成非中国路由表..."
pct_exec 'cd /tmp/nchnroutes && python3 nchnroutes.py --exclude-file /tmp/exclude_ips.txt --output bird'
pct_exec "mkdir -p /etc/bird"
pct_exec "cp /tmp/nchnroutes/routes4.conf /tmp/nchnroutes/routes6.conf /etc/bird/"

# 修正路由格式为 via "tun0"
pct_exec 'sed -i '\''s/via [0-9.]\+;/via "tun0";/g'\'' /etc/bird/routes4.conf'
pct_exec 'sed -i '\''s/via [0-9a-f:]\+;/via "tun0";/g'\'' /etc/bird/routes6.conf'

echo "  路由表统计:"
pct_exec "wc -l /etc/bird/routes4.conf /etc/bird/routes6.conf"

echo ""
echo "Step 9: 配置 BIRD..."
pct_exec "cat > /etc/bird/bird.conf << 'BIRDEOF'
log syslog all;
router id $CONTAINER_IP;

protocol kernel {
    scan time 60;
    ipv4 { import none; export all; };
}

protocol kernel {
    scan time 60;
    ipv6 { import none; export all; };
}

protocol device {
    scan time 60;
}

protocol static overseas4 {
    ipv4;
    include \"/etc/bird/routes4.conf\";
}

protocol static overseas6 {
    ipv6;
    include \"/etc/bird/routes6.conf\";
}

protocol ospf v2 default_v2 {
    ipv4 {
        import none;
        export where source = RTS_STATIC;
    };
    area 0.0.0.0 {
        interface \"eth0\" {
            type broadcast;
            cost 10;
            hello 10;
            dead 40;
            retransmit 5;
            wait 40;
            priority 1;
            authentication cryptographic;
            password \"$OSPF_PASSWORD\";
        };
    };
}

protocol ospf v3 default_v3 {
    ipv6 {
        import none;
        export where source = RTS_STATIC;
    };
    area 0.0.0.0 {
        interface \"eth0\" {
            type broadcast;
            cost 10;
            hello 10;
            dead 40;
        };
    };
}
BIRDEOF"

pct_exec "bird -p -c /etc/bird/bird.conf"
pct_exec "systemctl enable bird"
pct_exec "systemctl restart bird"
sleep 5

echo "  检查 BIRD 状态..."
pct_exec "birdc show protocols" || true

echo ""
echo "=========================================="
echo "容器配置完成！"
echo "=========================================="
echo ""
echo "接下来需要在 RouterOS 上配置 OSPF:"
echo ""
echo "SSH 登录 RouterOS: ssh admin@$GATEWAY"
echo ""
echo "执行以下命令:"
echo ""
echo "# OSPFv2 (IPv4)"
echo "/routing ospf instance add disabled=no name=ospf-split-v2 router-id=$GATEWAY"
echo "/routing ospf area add disabled=no instance=ospf-split-v2 name=backbone-v2"
echo "/routing ospf interface-template add area=backbone-v2 auth=md5 auth-id=1 auth-key=\"$OSPF_PASSWORD\" cost=10 disabled=no interfaces=bridge networks=192.168.88.0/24 priority=10 comment=\"OSPF split routing\""
echo ""
echo "# OSPFv3 (IPv6)"
echo "/routing ospf instance add disabled=no name=ospf-split-v3 router-id=$GATEWAY version=3"
echo "/routing ospf area add disabled=no instance=ospf-split-v3 name=backbone-v3"
echo "/routing ospf interface-template add area=backbone-v3 cost=10 disabled=no interfaces=bridge priority=10 comment=\"OSPFv3 split routing\""
echo ""
echo "# 验证"
echo "/routing/ospf/neighbor/print"
echo "/ip/route/print count-only where ospf"
echo ""
echo "=========================================="
