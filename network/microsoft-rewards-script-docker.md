# Microsoft Rewards Script Docker 部署手册（192.168.88.243）

本文记录在 `192.168.88.243` 上用 Docker 部署
`chiihero/Microsoft-Rewards-Script` 的推荐流程。

上次核对：`2026-07-08`，上游仓库 HEAD：`c7a1b74`。

注意：Microsoft Rewards 自动化可能违反服务规则，账号存在暂停或封禁风险。只在自己控制的账号上使用，不要用于规避风控、批量滥用或售卖积分。

## 部署目标

```text
host: 192.168.88.243
path: /opt/microsoft-rewards-script
container: microsoft-rewards-script
image: microsoft-rewards-script:local
schedule: 0 7 * * *（Asia/Shanghai，每天 07:00）
persisted data:
  /opt/microsoft-rewards-script/config
  /opt/microsoft-rewards-script/sessions
secret file:
  /opt/microsoft-rewards-script/.env
```

上游项目没有发布包含国内适配的公共镜像。`compose.yaml` 会从源码本地构建镜像，不要替换成 `ghcr.io/thenetsky/...` 之类的原版镜像。

容器默认不暴露端口，不需要 RouterOS 额外端口转发。

## 前置检查

登录 `192.168.88.243`：

```bash
ssh root@192.168.88.243
```

检查 Docker、Compose 和 Git：

```bash
docker version
docker compose version
git --version
```

Debian/Ubuntu 缺少基础工具时安装：

```bash
apt-get update
apt-get install -y git ca-certificates curl
```

验证主机能访问 Bing 和 Rewards：

```bash
curl -I https://cn.bing.com
curl -I https://rewards.bing.com
```

## 拉取源码

```bash
cd /opt
git clone https://github.com/chiihero/Microsoft-Rewards-Script.git microsoft-rewards-script
cd /opt/microsoft-rewards-script
git rev-parse --short HEAD
```

如果目录已存在：

```bash
cd /opt/microsoft-rewards-script
git status --short
git pull --ff-only
```

## 配置账号

复制模板并设置权限：

```bash
cd /opt/microsoft-rewards-script
cp -n env.example .env
chmod 600 .env
```

编辑 `.env`：

```bash
nano .env
```

最小配置：

```dotenv
ACCOUNT_1_EMAIL=you@example.com
ACCOUNT_1_PASSWORD=your_password
ACCOUNT_1_GEO_LOCALE=cn
ACCOUNT_1_LANG_CODE=zh
```

多账号按 `ACCOUNT_2_*`、`ACCOUNT_3_*` 继续递增，编号必须连续。账号需要二次验证时，优先补充：

```dotenv
ACCOUNT_1_TOTP_SECRET=
ACCOUNT_1_RECOVERY_EMAIL=
```

国内查询源推荐保留：

```dotenv
CONFIG_QUERY_ENGINES=china,local
```

需要 PushPlus 微信推送时追加：

```dotenv
CONFIG_PUSHPLUS_ENABLED=true
CONFIG_PUSHPLUS_TOKEN=your_pushplus_token
CONFIG_PUSHPLUS_TITLE=Microsoft-Rewards-Script
CONFIG_PUSHPLUS_TEMPLATE=txt
CONFIG_WEBHOOK_LOG_FILTER_ENABLED=true
CONFIG_WEBHOOK_LOG_FILTER_MODE=whitelist
CONFIG_WEBHOOK_LOG_FILTER_LEVELS=error,warn
```

不要把 `.env` 提交到 Git，也不要把它放到 Web 可访问目录。

## Compose 覆盖配置

上游 `compose.yaml` 会自动读取 `.env` 做变量替换，但只有写在 `environment:` 里的变量才会传入容器。为了让 `.env` 中的可选账号字段、PushPlus、调度和 `CONFIG_*` 项也稳定生效，新增 `compose.override.yaml`：

```bash
cd /opt/microsoft-rewards-script
nano compose.override.yaml
```

写入：

```yaml
# 如果只是预置环境、还没填写真实账号，先把 RUN_ON_START 设为 false。
services:
    microsoft-rewards-script:
        env_file:
            - .env
        environment:
            TZ: "Asia/Shanghai"
            NODE_ENV: "production"
            CRON_SCHEDULE: "0 7 * * *"
            RUN_ON_START: "true"
            SKIP_RANDOM_SLEEP: "false"
            MIN_SLEEP_MINUTES: "5"
            MAX_SLEEP_MINUTES: "50"
            STUCK_PROCESS_TIMEOUT_HOURS: "8"
            CONFIG_QUERY_ENGINES: "china,local"
```

说明：

- `RUN_ON_START=true` 适合首次部署，容器启动后立即跑一次用于验证。
- 未填写真实账号前，先设为 `RUN_ON_START=false`。
- 稳定运行后可以改成 `RUN_ON_START=false`，只保留 cron 定时执行。
- `SKIP_RANDOM_SLEEP=false` 会在每日任务前随机等待，默认 5-50 分钟。

验证 Compose 文件：

```bash
docker compose config --quiet
```

## 构建并启动

```bash
cd /opt/microsoft-rewards-script
docker compose up -d --build
docker compose ps
```

查看启动日志：

```bash
docker compose logs -f --tail=200 microsoft-rewards-script
```

首次构建会下载 Node 24 slim 镜像、安装依赖并安装 Chromium headless shell，耗时较长是正常现象。

## 首次登录和会话

Docker 环境下入口脚本会强制 `headless=true`，没有可见浏览器窗口。如果账号能用密码、TOTP、恢复邮箱完成登录，容器可直接生成会话。

如果日志提示必须手动完成网页登录，处理方式：

1. 在桌面环境按上游 README 的本地运行方式先生成 `sessions/`。
2. 停止 88.243 上的容器。
3. 把桌面环境生成的 `sessions/` 复制到 `/opt/microsoft-rewards-script/sessions/`。
4. 重新启动容器。

```bash
cd /opt/microsoft-rewards-script
docker compose down
# 复制 sessions 后：
docker compose up -d
```

会话和配置持久化在本机目录：

```bash
ls -lah /opt/microsoft-rewards-script/config
ls -lah /opt/microsoft-rewards-script/sessions
```

## 验证

确认容器和 cron：

```bash
docker compose ps
docker exec microsoft-rewards-script pgrep cron
docker exec microsoft-rewards-script date
docker exec microsoft-rewards-script cat /etc/cron.d/microsoft-rewards-cron
```

查看应用日志：

```bash
docker compose logs --tail=200 microsoft-rewards-script
docker exec microsoft-rewards-script tail -n 120 /var/log/microsoft-rewards.log
```

运行上游诊断脚本：

```bash
cd /opt/microsoft-rewards-script
bash diagnose-cron.sh microsoft-rewards-script
```

诊断脚本会创建一个临时 cron 测试任务并等待约 90 秒。

## 日常维护

重启：

```bash
cd /opt/microsoft-rewards-script
docker compose restart
```

停止：

```bash
cd /opt/microsoft-rewards-script
docker compose down
```

更新：

```bash
cd /opt/microsoft-rewards-script
git fetch --all --prune
git pull --ff-only
docker compose up -d --build
docker image prune -f
```

备份配置和会话：

```bash
cd /opt
tar -czf /root/microsoft-rewards-script-$(date +%F).tgz \
  microsoft-rewards-script/.env \
  microsoft-rewards-script/compose.override.yaml \
  microsoft-rewards-script/config \
  microsoft-rewards-script/sessions
chmod 600 /root/microsoft-rewards-script-*.tgz
```

备份文件含账号凭据和登录会话，按敏感文件处理。

## 常见问题

### 修改 `.env` 后没有生效

重新创建容器：

```bash
cd /opt/microsoft-rewards-script
docker compose up -d --build
```

如果只改了 cron、账号、PushPlus 或 `CONFIG_*`，通常不需要改源码，但 `--build` 可以避免旧镜像干扰。

### `.env` 中的可选字段没有进入容器

确认 `compose.override.yaml` 存在，并包含：

```yaml
env_file:
    - .env
```

然后检查容器内环境变量：

```bash
docker exec microsoft-rewards-script env | grep -E 'ACCOUNT_1_GEO_LOCALE|CONFIG_QUERY_ENGINES|PUSHPLUS'
```

不要打印密码相关变量。

### cron 没有按时执行

检查时区和 cron 文件：

```bash
docker exec microsoft-rewards-script date
docker exec microsoft-rewards-script cat /etc/timezone
docker exec microsoft-rewards-script cat /etc/cron.d/microsoft-rewards-cron
```

再运行：

```bash
bash /opt/microsoft-rewards-script/diagnose-cron.sh microsoft-rewards-script
```

### 构建失败

先看完整日志：

```bash
cd /opt/microsoft-rewards-script
docker compose build --no-cache microsoft-rewards-script
```

常见原因：

- `192.168.88.243` 无法访问 npm 或 Debian 软件源。
- Docker Hub 镜像拉取失败。
- 磁盘空间不足。

检查：

```bash
df -h
docker system df
curl -I https://registry.npmjs.org
```

### 需要临时只跑手动验证

把 `compose.override.yaml` 中的 `RUN_ON_START` 改为 `"true"`，然后：

```bash
cd /opt/microsoft-rewards-script
docker compose up -d
docker compose logs -f --tail=200 microsoft-rewards-script
```

验证完成后再改回 `"false"`。
