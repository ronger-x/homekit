# 环境配置说明

## 配置步骤

### 1. 创建 .env 文件

复制示例文件并填写实际配置：

```bash
cp .env.example .env
```

### 2. 获取 NETBOX API Token

1. 登录 NETBOX: http://192.168.88.243:8001
2. 进入 **用户设置** → **API Tokens**
3. 点击 **Add a token**
4. 设置权限（建议至少 Read/Write 权限）
5. 复制生成的 Token 填入 `.env` 的 `NETBOX_API_TOKEN`

### 3. 获取 LibreNMS API Token

1. 登录 LibreNMS: http://192.168.88.243:18082
2. 进入 **Settings** → **API** → **API Settings**
3. 创建新的 API Token 或使用现有的
4. 复制 Token 填入 `.env` 的 `LIBRENMS_API_TOKEN`

### 4. 配置 RouterOS 认证（可选）

如果需要脚本直接操作 RouterOS：

```bash
ROUTER_USER=admin
ROUTER_PASSWORD=your_routeros_password
```

## 测试配置

创建 `.env` 后，可以使用以下命令测试连接：

```bash
# 测试 NETBOX 连接 (v4.x v2 Token 使用 Bearer)
curl -H "Authorization: Bearer ${NETBOX_API_TOKEN}" \
     ${NETBOX_URL}/api/dcim/devices/

# 测试 LibreNMS 连接
curl -H "X-Auth-Token: ${LIBRENMS_API_TOKEN}" \
     ${LIBRENMS_URL}/api/v0/devices
```

## 安全提示

- ✅ `.env` 文件已添加到 `.gitignore`，不会被提交到 Git
- ✅ 永远不要将 `.env` 文件分享或提交到公共仓库
- ✅ API Token 权限应该按需最小化
- ✅ 定期轮换 API Token

## 在脚本中使用

脚本可以通过以下方式读取配置：

**Bash 示例:**
```bash
#!/bin/bash
source .env

curl -H "Authorization: Bearer ${NETBOX_API_TOKEN}" \
     "${NETBOX_URL}/api/dcim/devices/"
```

**Python 示例:**
```python
from dotenv import load_dotenv
import os

load_dotenv()

netbox_url = os.getenv('NETBOX_URL')
netbox_token = os.getenv('NETBOX_API_TOKEN')
```

## 变量说明

| 变量名 | 说明 | 必需 |
|--------|------|------|
| `NETBOX_URL` | NETBOX 访问地址 | ✓ |
| `NETBOX_API_TOKEN` | NETBOX API 认证令牌 | ✓ |
| `LIBRENMS_URL` | LibreNMS 访问地址 | ✓ |
| `LIBRENMS_API_TOKEN` | LibreNMS API 认证令牌 | ✓ |
| `ROUTER_HOST` | 主路由 IP 地址 | - |
| `ROUTER_USER` | RouterOS 用户名 | - |
| `ROUTER_PASSWORD` | RouterOS 密码 | - |
| `MSF_HOST` | 运行中的 MSF 测试/兼容网关地址 | - |
| `MSF_FAKE_IP_CIDR` | MSF fake-ip 网段 | - |
| `OPENCLASH_HOST` | 单设备兼容用 OpenClash 网关地址 | - |
