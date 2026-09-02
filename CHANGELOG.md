# Changelog

## [fork]

### ✨ Features
- **Multi-IP pool support** — single Agent can maintain hundreds of IPs via round-robin batch dispatch
- **Network namespace integration** — systemd units auto-prefixed with `ip netns exec` when `NETNS_NAME` is set
- **CIDR filtering** — `IP_POOL_FILTER` selects which IPs from a netns interface to include in the maintenance pool
- **Concurrent dispatch** — configurable `IP_BATCH_SIZE` and `IP_CONCURRENCY` with per-IP isolated config and cookie/persona separation
- **Config-driven REPO_RAW_URL** — runtime scripts read OTA source from config.conf, supporting fork redirection without per-file edits
- **Data/code URL separation** — `DATA_RAW_URL` (upstream) for keywords/UA/region data, `REPO_RAW_URL` (fork) for code OTA, eliminating data commit conflicts on rebase

### 🔧 Changes
- `CONFIG_FILE` in all modules changed from hardcoded to `${CONFIG_FILE:-default}` for per-IP override support
- New file: `core/ip_pool.sh` — IP enumeration, CIDR filtering, batch selection, concurrent dispatch
- All REPO_RAW_URL references redirected to `ffsktt/IP-Sentinel`

## [v4.3.4] - 2026-08-26

### ✨ Features
- **全舰队切换 Bot 凭证** (#102) — 更换 TG Bot 不再需要逐台卸载重装。Master 主菜单新增「🔁 全舰队切换 Bot 凭证」按钮：填写新 Token + Chat ID 后，司令部先 getMe 验证，再向所有开启 OTA 权限的节点批量下发切换指令；各节点自动完成凭证验证、向新 Bot 推送注册回执、原子重写本地配置，Chat ID 变更时自动重启守护进程完成 HMAC 密钥轮换
- **Agent 端新增 /trigger_reconfig 路由** — 复用 b64 安全 Base64 载荷与 HMAC 签名鉴权；ENABLE_OTA=false 的节点自动熔断（与 Master 下发范围对齐）；先推注册后改配置，任一步失败旧凭证保持完好

### 🐛 Bug Fixes
- **修复 TG API 无效凭证返回 HTTP 401 时 Agent 误报 500** — urllib 对非 2xx 抛异常，现捕获 HTTPError 并解析响应体，正确回传 403 + 失败原因

## [v4.3.2] - 2026-07-24

### ✨ Features
- **新增重新发送注册指令** — Master 重新部署导致 Agent 节点信息丢失时，无需重新安装 Agent，直接运行 `bash /opt/ip_sentinel/core/install.sh` 选择选项 3，一键向 Telegram 推送注册命令即可恢复节点连接
- **添加布法罗地区信息** (#100)
- **注入尔湾 (Irvine) 节点** (#98)
- **扩编芝加哥 (Chicago) 节点** (#90)

### 🐛 Bug Fixes
- **修复模块化入口缺少选项3** — `install/ui_menu.sh` 同步新增重新注册功能（实际运行走此入口）
- **Telegram MarkdownV2 消息换行乱码** — `\n` 字面量改为实际换行，特殊字符正确转义

### 🎨 Improvements
- **暗黑模式星标图表修复** — 采用 GitHub 原生深色主题渲染，坐标轴不再隐形
- **升级星标趋势图引擎** — 自研渲染引擎，彻底摆脱第三方服务 502 问题

### 🔒 Security
- **添加 .gitignore** — 防止密钥泄露

## [v4.3.1] - 2026-07-24

### ✨ Features
- 分布式 VPS IP 养护系统 v4.3.1
- Master-Agent 架构，Telegram Bot 控制
- Agent 每20分钟执行养护循环（mod_google 区域模拟搜索、mod_quality IP质量探测、mod_trust 白名单访问）
- HMAC-SHA256 动态签名 60 秒有效期
- WARP 过滤、防火墙自动管理
- Python3 标准库零第三方依赖
