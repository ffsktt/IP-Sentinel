# Changelog

## [fork]

### 🐛 Bug Fixes
- **`BLIND` verdict was unreachable in `mod_google.sh`** — the jump probe fell back to a hardcoded `"US"` when `http://www.google.com/` returned no `Location`, which is now the normal case (Google dropped ccTLD redirection in 2017 and folded every ccTLD back into `google.com` in 2025, so the request answers `200` directly). `VALID_PROBES` was therefore permanently `>=1`: a total probe outage was filed as `DRIFT`, inflating the drift column, and non-US nodes logged a permanent "Jump 副雷达漂移至 US". Now reports "no signal", matching what `mod_quality.sh`'s fast branch already did
- **`Accept-Language` contradicted the session persona** — `mod_trust.sh` sent `en-US,en;q=0.9` for every region while `mod_google.sh` sent none at all, against a localized `hl=` and a hash-seeded local UA. Both now derive the header from the region's `LANG_PARAMS` via `sentinel_accept_language()`; this also gives `LANG_ACCEPT` a value, which `mod_google.sh` had been reading for the ecosystem-roam `?hl=` without it ever being assigned anywhere in the repo
- **IPv6 source pinning broken on the inline fallback path** — `mod_google.sh` and `mod_trust.sh` passed `--interface "$BIND_IP"` with the brackets `ip_pool.sh` writes into the per-job config; `net_common.sh` already stripped them, so this only bit when `net_common.sh` was absent
- **`IP_CONCURRENCY` could be ignored entirely** — `(wait -n 2>/dev/null; true)` is unconditionally true because `; true` swallows the return value, so on bash < 4.3 the reap step never blocked and the whole batch went concurrent at once. Replaced with a `BASH_VERSINFO` check

### ⚡ Performance
- **YouTube region probe via `sw.js_data`** — ~1.5 KB replaces the ~92 KB `/premium` page and ~43 KB `music.youtube.com` landing page (measured with `--compressed`), cutting ~135 KB per probing session. The payload also carries the egress IP Google actually observed, so `sentinel_check_egress()` can verify that `--interface` pinning survived the node's routing — previously nothing anywhere checked this, and a netns/policy-routing misconfiguration would silently make the entire pool measure a single address. Mismatches are emitted as `egress` events and surfaced in the fleet report above every other metric. The endpoint is undocumented, so a layout change degrades to the old full-page regex rather than breaking
- **DoH endpoint selection is cached per address family** — `sentinel_net_init` runs once per session and a pool node opens ~8.6k sessions/day, so the old code spent one `example.com` round trip per session (and up to 4x6s whenever the leading endpoints were down). `PROBE_DOH_TTL` (default 1800s, `0` disables) collapses that to a couple of probes per hour; a `PROBE_DOH_URLS` edit invalidates the cache

### ✨ Features
- **Multi-IP pool support** — single Agent can maintain hundreds of IPs via round-robin batch dispatch
- **Network namespace integration** — systemd units auto-prefixed with `ip netns exec` when `NETNS_NAME` is set
- **CIDR filtering** — `IP_POOL_FILTER` selects which IPs from a netns interface to include in the maintenance pool
- **Concurrent dispatch** — configurable `IP_BATCH_SIZE` and `IP_CONCURRENCY` with per-IP isolated config and cookie/persona separation
- **Config-driven REPO_RAW_URL** — runtime scripts read OTA source from config.conf, supporting fork redirection without per-file edits
- **Data/code URL separation** — `DATA_RAW_URL` (upstream) for keywords/UA/region data, `REPO_RAW_URL` (fork) for code OTA, eliminating data commit conflicts on rebase
- **Pool-level daily report** — per-CIDR geo posture with four-state verdicts (OK / DRIFT / CN / BLIND), 24h coverage ratio, day-over-day deltas, and worst-segment offender samples, replacing the log-grep report that could only see ~0.4 of a single round
- **Structured event stream** — `core/net_common.sh` gains `sentinel_event()`, an append-only TSV at `state/events-YYYYMMDD.tsv`. Lock-free under concurrent writers (a single sub-PIPE_BUF write to an O_APPEND fd is atomic on Linux), giving the per-IP attribution the interleaved free-text log cannot provide

### ⚡ Performance
- **Schedule budget fit** — batch makespan p99 cut from ~29 min to ~15 min at `IP_BATCH_SIZE=120` / `IP_CONCURRENCY=40`, so rounds no longer overrun the 20-minute cron window and get dropped whole by `runner.sh`'s `flock -n`. Effective throughput roughly doubles: ~4.5 → ~8.6 maintenance passes per IP per day
- **Variance over mean** — `mod_trust.sh` dwell distribution collapsed from four buckets to three with a hard 90s ceiling (the old 5% / 180-480s tail alone drove over half the makespan overrun); `mod_google.sh` dwell narrowed to 30-50s. Action-count ranges and the three-tier probability shape are deliberately preserved — a robotic signature comes from low variance, not short duration
- **Per-job stagger replaces global jitter** — the 0-180s pre-dispatch sleep in `runner.sh` was held inside the `flock` and burned schedule budget serially; pool mode now staggers each dispatched job by 0-30s inside `ip_pool.sh`, which overlaps with sibling jobs at near-zero makespan cost and spreads requests within the batch instead of shifting the whole block
- **`--compressed` on HTML probes** — added to `mod_google.sh` roaming/YouTube requests and the `mod_quality.sh` fast-sonar probes. Outbound traffic drops ~40% versus the previous baseline even with throughput doubled (~37 GB/day → ~22 GB/day)

### 🔧 Changes
- `CONFIG_FILE` in all modules changed from hardcoded to `${CONFIG_FILE:-default}` for per-IP override support
- New file: `core/ip_pool.sh` — IP enumeration, CIDR filtering, batch selection, concurrent dispatch
- All REPO_RAW_URL references redirected to `ffsktt/IP-Sentinel`
- Log rotation in `core/updater.sh` switched from a fixed 2000-line truncation to 50 MiB size-based rotation; a pool node produces ~90k log lines per day, so the old threshold retained less than one round
- `core/install.sh` now fetches `core/net_common.sh`, which had only ever been in the `install/sys_daemon.sh` OTA list — fresh installs silently lost both DoH bypass and the event stream because every call site is `declare -f` guarded
- Runtime schedule-budget warning in `core/ip_pool.sh` when `ceil(batch/concurrency)` cannot fit the cron period
- DoH degradation and DNS-hijack counts are emitted as `dns` events by `core/net_common.sh`, so on pool nodes they share the report's 24h window; the legacy `tail -n 1000` sample would have under-reported them by roughly two orders of magnitude, and it now renders only for single-IP nodes

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
