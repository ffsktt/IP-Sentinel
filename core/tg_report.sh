#!/bin/bash

# ==========================================================
# 脚本名称: tg_report.sh
# 核心功能: 收集并聚合终端特征、提取执行快照、侦测云端版本并生成简报
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${CONFIG_FILE:-${INSTALL_DIR}/config.conf}"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# --- [基础自检] ---
if [ ! -f "$CONFIG_FILE" ]; then exit 1; fi
source "$CONFIG_FILE"

if [ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "⚠️ 未配置 Telegram 机器人参数，取消播报。"
    exit 0
fi

# ==========================================================
# [防线 1] 并发风暴熔断机制 (60s 冷却池)
# ==========================================================
LOCK_FILE="${INSTALL_DIR}/core/.report_lock"
if [ -f "$LOCK_FILE" ]; then
    LAST_RUN=$(cat "$LOCK_FILE" 2>/dev/null)
    NOW=$(date +%s)
    # 严格校验最后执行时间的合法性，防御密集回调
    if [[ "$LAST_RUN" =~ ^[0-9]+$ ]]; then
        if [ $((NOW - LAST_RUN)) -lt 60 ]; then
            echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [v${AGENT_VERSION:-未知}] [WARN ] [Report ] [SYSTEM] ⚠️ 战报请求过于频繁，触发 60 秒防并发风暴拦截。" >> "${INSTALL_DIR}/logs/sentinel.log"
            exit 0
        fi
    fi
fi
echo $(date +%s) > "$LOCK_FILE"

# ==========================================================
# 1. 节点元数据与双轨身份解析
# ==========================================================
if [ -z "$NODE_NAME" ]; then
    IP_HASH=$(echo "${PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    NODE_NAME="$(hostname | cut -c 1-10)-${IP_HASH}"
fi
NODE_ALIAS="${NODE_ALIAS:-$NODE_NAME}"

# ----------------------------------------------------------
# [容灾探针 1] 底层路由锁定与多节点出口 IP 嗅探
# ----------------------------------------------------------
CURL_BIND_OPT=""
DYNAMIC_IP_PREF="-${IP_PREF:-4}"

if [ -f "${INSTALL_DIR}/core/net_common.sh" ]; then
    # [v4.x] 统一出网构建：源 IP 锁定 + DoH 绕行
    source "${INSTALL_DIR}/core/net_common.sh"
    sentinel_net_init
    CURL_BIND_OPT="${CURL_BIND_ARGS[*]}"
else
    if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\.]+$ ]]; then
        RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
        if ! ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
            CURL_BIND_OPT=""
        else
            CURL_BIND_OPT="--interface $BIND_IP"
            if [[ "$BIND_IP" == *":"* ]]; then
                DYNAMIC_IP_PREF="-6"
            elif [[ "$BIND_IP" == *"."* ]]; then
                DYNAMIC_IP_PREF="-4"
            fi
        fi
    fi
fi

# 结合协议自适应进行外部 IP 回显探测
CURRENT_IP=$( (curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/ip || curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
# 强制兜底逻辑：网络完全阻断时回退使用配置文件锚点
[ -z "$CURRENT_IP" ] && CURRENT_IP="${PUBLIC_IP:-$BIND_IP}"

# 为 IPv6 环境追加方括号安全护甲
[[ "$CURRENT_IP" == *":"* ]] && [[ "$CURRENT_IP" != *"["* ]] && CURRENT_IP="[${CURRENT_IP}]"

# ----------------------------------------------------------
# [容灾探针 2] 多级 ISP 情报探测链路
# ----------------------------------------------------------
ISP_INFO=""

# 优先级 A: 高吞吐极速纯文本接口
ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ipinfo.io/org 2>/dev/null)

# 优先级 B: 备用纯文本接口
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ip-api.com/line/?fields=isp 2>/dev/null)
fi

# 优先级 C: 需构建环境依赖的 JSON 接口
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    if command -v jq &> /dev/null; then
        ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/geoip | jq -r '.organization' 2>/dev/null)
    fi
fi

# 数据清洗过滤与类型渲染
ISP_INFO=$(echo "$ISP_INFO" | sed -E 's/^AS[0-9]+ //')
[ -z "$ISP_INFO" ] || [ "$ISP_INFO" == "null" ] && ISP_INFO="未知 ISP"

if [[ "$ISP_INFO" == *"Cloudflare"* ]]; then
    IP_TYPE="Cloudflare Warp 🛰️"
else
    IP_TYPE="$ISP_INFO 🏠"
fi

# [全视界旗帜引擎] 动态国旗渲染装配
BASE_CC="${REGION_CODE%%-*}"
case "$BASE_CC" in
    US) FLAG="🇺🇸" ;; JP) FLAG="🇯🇵" ;; HK) FLAG="🇭🇰" ;; TW) FLAG="🇹🇼" ;; SG) FLAG="🇸🇬" ;;
    UK|GB) FLAG="🇬🇧" ;; DE) FLAG="🇩🇪" ;; FR) FLAG="🇫🇷" ;; NL) FLAG="🇳🇱" ;; CA) FLAG="🇨🇦" ;;
    AU) FLAG="🇦🇺" ;; KR) FLAG="🇰🇷" ;; IN) FLAG="🇮🇳" ;; BR) FLAG="🇧🇷" ;; RU) FLAG="🇷🇺" ;;
    CH) FLAG="🇨🇭" ;; SE) FLAG="🇸🇪" ;; NO) FLAG="🇳🇴" ;; DK) FLAG="🇩🇰" ;; FI) FLAG="🇫🇮" ;;
    IT) FLAG="🇮🇹" ;; ES) FLAG="🇪🇸" ;; PT) FLAG="🇵🇹" ;; IE) FLAG="🇮🇪" ;; PL) FLAG="🇵🇱" ;;
    AT) FLAG="🇦🇹" ;; BE) FLAG="🇧🇪" ;; TR) FLAG="🇹🇷" ;; ZA) FLAG="🇿🇦" ;; AE) FLAG="🇦🇪" ;;
    MY) FLAG="🇲🇾" ;; ID) FLAG="🇮🇩" ;; VN) FLAG="🇻🇳" ;; TH) FLAG="🇹🇭" ;; PH) FLAG="🇵🇭" ;;
    NZ) FLAG="🇳🇿" ;; AR) FLAG="🇦🇷" ;; CL) FLAG="🇨🇱" ;; MX) FLAG="🇲🇽" ;; IL) FLAG="🇮🇱" ;;
    SA) FLAG="🇸🇦" ;; EG) FLAG="🇪🇬" ;; NG) FLAG="🇳🇬" ;; KE) FLAG="🇰🇪" ;; RO) FLAG="🇷🇴" ;;
    BG) FLAG="🇧🇬" ;; CZ) FLAG="🇨🇿" ;; HU) FLAG="🇭🇺" ;; GR) FLAG="🇬🇷" ;; UA) FLAG="🇺🇦" ;;
    MO) FLAG="🇲🇴" ;; KH) FLAG="🇰🇭" ;; MM) FLAG="🇲🇲" ;; LA) FLAG="🇱🇦" ;;
    MN) FLAG="🇲🇳" ;; NP) FLAG="🇳🇵" ;; BD) FLAG="🇧🇩" ;;
    *) FLAG="🌐" ;;
esac

# ==========================================================
# 2A. 池级态势聚合 (多 IP 节点)
#
# 自由文本日志无法做 per-IP 归因: IP_CONCURRENCY 个并发写入者会把同一会话的
# "当前出网 IP" 行与其后的 [SCORE] 行冲散数百行, 且两者都不带 session id。
# 故池级数字全部取自 net_common.sh 的结构化事件流, 与日志轮转彻底解耦。
# 单 IP 节点无 round 事件, 聚合器以 exit 2 让位给下方的旧版扁平报文。
# ==========================================================
POOL_BLOCK=""
if [ -d "${INSTALL_DIR}/state" ]; then
    POOL_BLOCK=$(INSTALL_DIR="$INSTALL_DIR" IP_POOL_FILTER="${IP_POOL_FILTER:-}" python3 - <<'PYAGG'
import os, sys, time, ipaddress

root = os.environ.get('INSTALL_DIR', '/opt/ip_sentinel')
state = os.path.join(root, 'state')
now = int(time.time())

# The 48h comparison window can span three UTC day files.
rows = []
for back in range(3):
    d = time.strftime('%Y%m%d', time.gmtime(now - back * 86400))
    try:
        with open(os.path.join(state, 'events-%s.tsv' % d)) as f:
            for line in f:
                p = line.rstrip('\n').split('\t')
                if len(p) != 5:
                    continue
                try:
                    ts = int(p[0])
                    # Reject unparseable addresses here so they cannot inflate
                    # coverage or leak into the offender samples downstream.
                    if p[2] != 'round':
                        ipaddress.ip_address(p[1])
                except ValueError:
                    continue
                rows.append((ts, p[1], p[2], p[3], p[4]))
    except OSError:
        pass

if not rows:
    sys.exit(2)

W1, W2 = now - 86400, now - 172800
# Upper bound tolerates events stamped in the current second (and up to a day
# of forward clock skew); a bare `ts < now` silently drops them.
INF = now + 86400

def geo_state(lo, hi):
    """Latest geo/fastqc verdict per IP within [lo, hi)."""
    m = {}
    for ts, ip, mod, verdict, detail in rows:
        if mod in ('geo', 'fastqc') and lo <= ts < hi:
            if ip not in m or ts > m[ip][0]:
                m[ip] = (ts, verdict, detail)
    return m

cur, prev = geo_state(W1, INF), geo_state(W2, W1)

pool = rounds = 0
for ts, ip, mod, verdict, detail in rows:
    if mod == 'round' and W1 <= ts < INF:
        rounds += 1
        for kv in detail.split(','):
            if kv.startswith('pool='):
                try:
                    pool = max(pool, int(kv[5:]))
                except ValueError:
                    pass

# Single-IP node (no pool markers): caller falls back to the legacy report.
if pool <= 1:
    sys.exit(2)

t_total = t_ok = visits = doh_fb = hijack = 0
seen = set()
egress_mm = set()
for ts, ip, mod, verdict, detail in rows:
    if not (W1 <= ts < INF):
        continue
    if mod == 'trust':
        t_total += 1
        if verdict == 'OK':
            t_ok += 1
    elif mod == 'dns':
        if verdict == 'DOH_FALLBACK':
            doh_fb += 1
        elif verdict == 'HIJACK':
            hijack += 1
    elif mod == 'egress':
        # Google observed a different source address than the job bound, so the
        # geo verdict recorded for this IP actually describes another one.
        egress_mm.add(ip)
    if mod in ('geo', 'fastqc', 'trust'):
        seen.add(ip)
    # fastqc is a read-only probe, not a maintenance pass, so it must not
    # shorten the reported lap interval.
    if mod in ('geo', 'trust'):
        visits += 1

# CIDR grouping: IP_POOL_FILTER first-match (overlapping entries are not a
# real scenario for a hand-written include list), else natural /24 or /48.
nets = []
for c in (os.environ.get('IP_POOL_FILTER') or '').split(','):
    c = c.strip()
    if c:
        try:
            nets.append(ipaddress.ip_network(c, strict=False))
        except ValueError:
            pass

def group_of(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return None
    for n in nets:
        if a in n:
            return str(n)
    plen = 24 if a.version == 4 else 48
    return str(ipaddress.ip_network('%s/%d' % (ip, plen), strict=False))

STATES = ('OK', 'DRIFT', 'CN', 'BLIND')

def tally(m):
    g = {}
    for ip, (ts, verdict, detail) in m.items():
        k = group_of(ip)
        if k is None:
            continue
        d = g.setdefault(k, dict.fromkeys(STATES, 0))
        if verdict in d:
            d[verdict] += 1
    return g

gcur, gprev = tally(cur), tally(prev)
tot = dict.fromkeys(STATES, 0)
for d in gcur.values():
    for s in STATES:
        tot[s] += d[s]
ntot = sum(tot.values()) or 1

def cn_rate(d):
    n = sum(d.values())
    return (d['CN'] * 100.0 / n) if n else 0.0

out = []
lap = (24.0 * pool / visits) if visits else 0.0
out.append('🌐 池 %d IP · 轮次 %d/72 · 巡回 %.1fh' % (pool, rounds, lap))
out.append('🔄 24h 养护覆盖 %d/%d (%.1f%%)' % (len(seen), pool, len(seen) * 100.0 / pool))

def delta(s):
    if not gprev:
        return ''
    d = tot[s] - sum(x[s] for x in gprev.values())
    return '' if d == 0 else (' (↑%d)' % d if d > 0 else ' (↓%d)' % -d)

out.append('')
out.append('🎯 **[区域态势]**')
out.append('✅ %d (%.1f%%)  ⚠️ %d  ❌ %d%s  🚨 %d%s'
           % (tot['OK'], tot['OK'] * 100.0 / ntot, tot['DRIFT'],
              tot['CN'], delta('CN'), tot['BLIND'], delta('BLIND')))

# Worst CN rate first; only the top 8 render, the rest fold into one line so
# the message stays inside Telegram's 4096-char ceiling.
ranked = sorted(gcur.items(), key=lambda kv: (-cn_rate(kv[1]), kv[0]))
shown, hidden = ranked[:8], ranked[8:]
w = max([len(k) for k, _ in shown] + [4])
lines = ['%-*s %5s %5s %5s %5s %5s %8s %7s'
         % (w, '网段', '已测', 'OK', 'DRIFT', 'CN', 'BLIND', '送中率', '环比')]
alerts = []
for k, d in shown:
    r = cn_rate(d)
    pr = cn_rate(gprev[k]) if k in gprev else None
    lines.append('%-*s %5d %5d %5d %5d %5d %7.1f%% %7s'
                 % (w, k, sum(d.values()), d['OK'], d['DRIFT'], d['CN'], d['BLIND'],
                    r, '  —' if pr is None else ('%+.1f' % (r - pr))))
    if r >= 5.0 or (pr is not None and r - pr >= 5.0):
        alerts.append((k, r, pr))

out.append('')
out.append('🧭 **[网段分布]**')
out.append('```')
out.extend(lines)
out.append('```')
if hidden:
    out.append('_其余 %d 段送中率 ≤ %.1f%%_' % (len(hidden), cn_rate(hidden[0][1])))
for k, r, pr in alerts[:2]:
    if pr is not None and r - pr >= 5.0:
        out.append('🔴 `%s` 送中率 %.1f%% → %.1f%%，建议核查' % (k, pr, r))
    else:
        out.append('🔴 `%s` 送中率 %.1f%%，建议核查' % (k, r))

# Rank offenders by how bad the owning segment is, then by recency: a one-off
# CN in a healthy /24 is noise, the cluster in a degraded segment is the finding.
cns = sorted(((ts, ip, detail) for ip, (ts, v, detail) in cur.items() if v == 'CN'),
             key=lambda r: (-gcur.get(group_of(r[1]), {}).get('CN', 0), -r[0]))
if cns:
    out.append('')
    out.append('❌ **[送中样本]** Jump/Prem/Music')
    for ts, ip, detail in cns[:3]:
        kv = dict(x.split('=', 1) for x in detail.split(',') if '=' in x)
        out.append('`%s`  %s/%s/%s  %.1fh 前'
                   % (ip, kv.get('jump', 'x'), kv.get('pr', 'x'),
                      kv.get('mu', 'x'), (now - ts) / 3600.0))
    if len(cns) > 3:
        top = max(gcur.items(), key=lambda kv: kv[1]['CN'])
        out.append('_共 %d 个，其中 %d 个属 `%s`_' % (len(cns), top[1]['CN'], top[0]))

if t_total:
    out.append('')
    out.append('🔰 **[信用净化]** %d 轮 · 成功率 %.1f%%' % (t_total, t_ok * 100.0 / t_total))

# Counted from the same 24h window as everything above; the legacy log-grep
# path below would only see the last ~1000 lines (a fraction of one round).
if doh_fb or hijack:
    out.append('')
    out.append('⚠️ **[DNS 链路健康]** DoH 降级 %d 次 · 疑似劫持 %d 次' % (doh_fb, hijack))

# Ranks above everything else: a source-pinning failure invalidates the geo
# numbers themselves rather than merely degrading them.
if egress_mm:
    out.append('')
    out.append('🧨 **[出口绑定异常]** %d 个 IP 的探测流量未从自身出网，其区域裁决不可信'
               % len(egress_mm))
    out.append('样本 %s' % ' '.join('`%s`' % x for x in sorted(egress_mm)[:3]))

print('\n'.join(out))
PYAGG
) || POOL_BLOCK=""
fi

# ==========================================================
# 2B. 行为日志萃取与快照分析 (单 IP 节点回退口径)
# ==========================================================
LOG_CONTENT=$(tail -n 1000 "$LOG_FILE" 2>/dev/null)

# 池级数据可用时不得走"无日志"告警：事件流独立于日志轮转，日志被截断
# 并不代表节点失联。
if [ -z "$LOG_CONTENT" ] && [ -z "$POOL_BLOCK" ]; then
    read -r -d '' MSG <<EOT
🛑 **[IP-Sentinel] 告警：节点异常**
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
⚠️ **警告**: 过去 24 小时无运行日志！
🛠️ **建议**: 节点可能刚部署完毕，请在面板手动执行一次养护动作。
EOT
else
    # 抓取末次执行模块的运行态势图
    LAST_LOG_LINE=$(echo "$LOG_CONTENT" | grep "\[SCORE\]" | tail -n 1)
    LAST_TIME=$(echo "$LAST_LOG_LINE" | awk '{print $1,$2}' | tr -d '[]')
    LAST_MOD=$(echo "$LAST_LOG_LINE" | awk '{print $4}' | tr -d '[]')
    LAST_SCORE=$(echo "$LAST_LOG_LINE" | awk -F'自检结论: ' '{print $2}')

    if [ -n "$POOL_BLOCK" ]; then
        MSG="📊 **IP-Sentinel 舰队简报 (${FLAG} ${REGION_NAME})**"
    else
        MSG="📊 **IP-Sentinel 每日简报 (${FLAG} ${REGION_NAME})**"
    fi
    MSG="$MSG
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
📡 **出口 IP**: \`${CURRENT_IP}\`
🛡️ **IP 属性**: ${IP_TYPE}"

    # 池级节点：整块态势由聚合器渲染，跳过下方基于日志 grep 的单 IP 口径
    if [ -n "$POOL_BLOCK" ]; then
        MSG="$MSG
${POOL_BLOCK}"
    else

    # [快速声呐] Quality 快速检测模块统计 (送中判定补充口径)
    # fast 探测在任一养护模块开启时均会执行，故统计独立于 Google 板块：
    # Google 开启时并入其送中计数，仅 Trust 开启时单独追加。
    QUALITY_LOGS=$(echo "$LOG_CONTENT" | grep "\[Quality")
    Q_TOTAL=$(echo "$QUALITY_LOGS" | grep "\[START\]" -c)
    Q_CN=$(echo "$QUALITY_LOGS" | grep "❌" -c)

    # 统计 Google 纠偏阵列数据
    if [ "$ENABLE_GOOGLE" == "true" ]; then
        GOOGLE_LOGS=$(echo "$LOG_CONTENT" | grep "\[Google")
        G_TOTAL=$(echo "$GOOGLE_LOGS" | grep "\[START\]" -c)
        G_SUCCESS=$(echo "$GOOGLE_LOGS" | grep "✅" -c)
        G_FAILED=$(echo "$GOOGLE_LOGS" | grep "❌" -c)
        G_WARN=$(echo "$GOOGLE_LOGS" | grep "⚠️" -c)

        G_RATE="0.0"
        [ "$G_TOTAL" -gt 0 ] && G_RATE=$(awk "BEGIN {printf \"%.1f\", ($G_SUCCESS/$G_TOTAL)*100}")

        TOTAL_CN=$(( G_FAILED + Q_CN ))

        MSG="$MSG

🎯 **[Google 区域纠偏]**
🚀 执行总数: ${G_TOTAL} 次 (胜率: **${G_RATE}%**)
✅ 成功: ${G_SUCCESS} | ❌ 送中: ${TOTAL_CN} | ⚠️ 警告: ${G_WARN}
📡 快速声呐: ${Q_TOTAL} 次探测 (送中: ${Q_CN})"
    fi

    # 统计 Trust 净化阵列数据
    if [ "$ENABLE_TRUST" == "true" ]; then
        TRUST_LOGS=$(echo "$LOG_CONTENT" | grep "\[Trust")
        T_TOTAL=$(echo "$TRUST_LOGS" | grep "\[START\]" -c)
        T_SUCCESS=$(echo "$TRUST_LOGS" | grep "✅" -c)
        T_FAILED=$(echo "$TRUST_LOGS" | grep "❌" -c)
        
        T_RATE="0.0"
        [ "$T_TOTAL" -gt 0 ] && T_RATE=$(awk "BEGIN {printf \"%.1f\", ($T_SUCCESS/$T_TOTAL)*100}")

        MSG="$MSG

🔰 **[IP 信用净化]**
🚀 净化总数: ${T_TOTAL} 轮 (成功率: **${T_RATE}%**)
✅ 成功注入: ${T_SUCCESS} | ❌ 访问受阻: ${T_FAILED}"

        # 仅 Trust 开启时 (Google 板块未展示)，快速声呐统计独立追加
        if [ "$ENABLE_GOOGLE" != "true" ] && [ "${Q_TOTAL:-0}" -gt 0 ]; then
            MSG="$MSG

📡 快速声呐: ${Q_TOTAL} 次探测 (送中: ${Q_CN})"
        fi
    fi

    fi   # end: 单 IP 日志 grep 口径

    # [DNS 链路健康] DoH 降级与疑似劫持统计（仅在命中时渲染）
    # 池模式由聚合器按同一 24h 窗口渲染；此处的 tail -n 1000 口径在池节点上
    # 只覆盖不到一轮，会把数量低报约两个数量级，故仅用于单 IP 节点。
    DOH_FB_COUNT=$(echo "$LOG_CONTENT" | grep -c "DOH_FALLBACK")
    DNS_HJ_COUNT=$(echo "$LOG_CONTENT" | grep -c "DNS_HIJACK_SUSPECT")
    if [ -z "$POOL_BLOCK" ] && { [ "$DOH_FB_COUNT" -gt 0 ] || [ "$DNS_HJ_COUNT" -gt 0 ]; }; then
        MSG="$MSG

⚠️ **[DNS 链路健康]**
🔻 DoH 降级系统解析: ${DOH_FB_COUNT} 次 | 🕸️ 疑似 DNS 劫持: ${DNS_HJ_COUNT} 次"
    fi

    # 追加末次快照 (池模式下这只是上千个 IP 里随机一个的结论，无参考价值，故跳过)
    if [ -z "$POOL_BLOCK" ]; then
        MSG="$MSG

🕒 **最近执行快照:  \`${LAST_MOD:-"System"} \`**
时间: ${LAST_TIME:-"暂无数据"} (节点本地)
结论: ${LAST_SCORE:-"暂无数据"}"
    fi

fi

# ==========================================================
# 3. 云端版本探针与 OTA 调度模块
# ==========================================================
LOCAL_VER="${AGENT_VERSION:-未知}"
LOCAL_FORK="${FORK_TAG:-}"
FORK_LABEL=""
[ -n "$LOCAL_FORK" ] && FORK_LABEL="-${LOCAL_FORK}"
# [时间线对齐] 强制采用绝对 UTC 时间消除多节点的系统偏差
REPORT_UTC_TIME=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/ffsktt/IP-Sentinel/main}"
_VER_TXT=$(curl -s -m 3 "${REPO_RAW_URL}/version.txt")
REMOTE_VER=$(echo "$_VER_TXT" | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
REMOTE_FORK=$(echo "$_VER_TXT" | grep "^FORK_TAG=" | cut -d'=' -f2 | tr -d '[:space:]')

MSG="$MSG
----------------------------
🛡️ **系统引擎状态**
⏱️ 战报生成: \`${REPORT_UTC_TIME}\`"

# 根据云端版本一致性自动渲染更新提示面板
if [ -n "$REMOTE_VER" ]; then
    if [ "$REMOTE_VER" != "$LOCAL_VER" ] || [ "$REMOTE_FORK" != "$LOCAL_FORK" ]; then
        REMOTE_FORK_LABEL=""
        [ -n "$REMOTE_FORK" ] && REMOTE_FORK_LABEL="-${REMOTE_FORK}"
        MSG="$MSG
当前运行版本: \`v${LOCAL_VER}${FORK_LABEL}\`
✨ **发现新版本**: \`v${REMOTE_VER}${REMOTE_FORK_LABEL}\` (建议更新)
💡 *系统提示：检测到新版引擎，建议通过中枢控制台执行 OTA 热更新！*"
    else
        MSG="$MSG
当前运行版本: \`v${LOCAL_VER}${FORK_LABEL}\` (✅已是最新)
💡 *IP-Sentinel 持续为您守护节点。*
*若本项目对您有帮助，欢迎前往 GitHub 赐予 🌟*"
    fi
else
    MSG="$MSG
当前运行版本: \`v${LOCAL_VER}\`
💡 *IP-Sentinel 持续为您守护节点。*
*若本项目对您有帮助，欢迎前往 GitHub 赐予 🌟*"
fi

# --- [下发 API 载荷] ---
JSON_PAYLOAD=$(jq -n \
  --arg cid "$CHAT_ID" \
  --arg txt "$MSG" \
  --arg cb "manage:${NODE_NAME}" \
  '{
    chat_id: $cid,
    text: $txt,
    parse_mode: "Markdown",
    disable_web_page_preview: true,
    reply_markup: {
      inline_keyboard: [[{"text": "⚙️ 调出该节点控制台", "callback_data": $cb}]]
    }
  }')

RESPONSE=$(curl -s -m 10 -X POST "${TG_API_URL}" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD")

if [[ "$RESPONSE" != *"\"ok\":true"* ]]; then
    echo "❌ 战报发送失败！API 响应: $RESPONSE" >> "${INSTALL_DIR}/logs/error.log"
else
    echo "✅ 战报推送成功！"
fi