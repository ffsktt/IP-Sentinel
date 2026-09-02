#!/bin/bash

# ==========================================================
# 脚本名称: runner.sh
# 核心功能: 主控调度枢纽，管理防并发锁与 Feature Flag 概率轮盘
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

# --- [基础环境构建] ---
if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件丢失，请重新运行 install.sh"
    exit 1
fi
source "$CONFIG_FILE"

# ==========================================================
# [防线 1] 进程排他锁管控
# 严格防止高频并发重入引发的底层内存雪崩与死锁
# ==========================================================
exec 200>"/tmp/ip_sentinel_runner.lock"
if ! flock -n 200; then
    echo "[$(date)] ⚠️ 上一轮巡逻任务尚未结束，本次触发自动取消。" >> "$LOG_FILE"
    exit 0
fi

# --- [系统级日志通道] ---
log() {
    local module=$1
    local level=$2
    local msg=$3
    local local_ver="${AGENT_VERSION:-未知}"
    
    mkdir -p "${INSTALL_DIR}/logs"
    
    local core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$level" "$module" "$REGION_CODE" "$msg")
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"

    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$core_msg"
    else
        echo "$core_msg"
    fi
}
export -f log
export CONFIG_FILE INSTALL_DIR

# ==========================================================
# [防线 2] 行为学隐蔽 (Cron Jitter)
# 彻底消除僵尸网络同频定时唤醒特征，自然打散全球并发请求
# ==========================================================
if [ -t 1 ]; then
    log "SYSTEM" "INFO " "💻 检测到人工终端干预，跳过静默休眠，立即执行任务！"
else
    # [预算保护] 全局 jitter 在 flock 之内串行空转，直接吃掉巡逻周期预算。
    # 多 IP 池模式下改由 ip_pool.sh 给每个任务单独错峰 (与其他任务重叠执行，
    # makespan 成本约为 0)，反指纹效果更强——打散批内请求而非平移整块。
    if [[ -n "$MULTI_IP_MODE" ]] || [[ -n "$NETNS_NAME" ]]; then
        JITTER_TIME=$((RANDOM % 30))
    else
        JITTER_TIME=$((RANDOM % 180))
    fi
    log "SYSTEM" "INFO " "⏱️ 主控引擎由后台唤醒，进入防并发随机休眠状态: ${JITTER_TIME} 秒..."
    sleep $JITTER_TIME
fi

# ==========================================================
# 智能轮盘赌调度系统 (基于 Feature Flag)
# ==========================================================
log "SYSTEM" "INFO" "休眠结束，开始计算本轮任务轮盘..."

# Multi-IP pool dispatch
if [[ -z "$MULTI_IP_MODE" ]] && [[ -n "$NETNS_NAME" ]]; then
    MULTI_IP_MODE="netns"
fi
if [[ -n "$MULTI_IP_MODE" ]] && [[ -f "${INSTALL_DIR}/core/ip_pool.sh" ]]; then
    # net_common.sh 提供 sentinel_event()，ip_pool.sh 的轮次标记依赖它
    [ -f "${INSTALL_DIR}/core/net_common.sh" ] && source "${INSTALL_DIR}/core/net_common.sh"
    source "${INSTALL_DIR}/core/ip_pool.sh"
    if _ip_pool_dispatch; then
        log "SYSTEM" "INFO" "本轮所有模块调度完毕，哨兵继续隐蔽待命。"
        exit 0
    fi
    log "POOL" "WARN" "Multi-IP dispatch failed, falling back to single-IP mode"
fi

TARGET_MOD=""
MOD_NAME=""

# 概率任务分配模型
if [ "$ENABLE_GOOGLE" == "true" ] && [ "$ENABLE_TRUST" == "true" ]; then
    # 优先锚定地理画像，辅助洗刷风控分
    ROLL=$((RANDOM % 100 + 1))
    if [ $ROLL -le 70 ]; then
        TARGET_MOD="mod_google.sh"
        MOD_NAME="Google 区域纠偏"
    else
        TARGET_MOD="mod_trust.sh"
        MOD_NAME="IP 信用净化"
    fi
elif [ "$ENABLE_GOOGLE" == "true" ]; then
    TARGET_MOD="mod_google.sh"
    MOD_NAME="Google 区域纠偏"
elif [ "$ENABLE_TRUST" == "true" ]; then
    TARGET_MOD="mod_trust.sh"
    MOD_NAME="IP 信用净化"
else
    log "SYSTEM" "WARN" "节点未开启任何养护模块，跳过本轮执行。"
    exit 0
fi

# ----------------------------------------------------------
# 安全执行与资源剥离
# ----------------------------------------------------------
if [ -n "$TARGET_MOD" ] && [ -x "${INSTALL_DIR}/core/${TARGET_MOD}" ]; then
    log "SYSTEM" "INFO" "命中触发条件，加载并执行子模块: ${MOD_NAME}"
    # [进程隔离与降耗] 赋予最低 CPU 优先级，并强制剥离排他锁的继承权，防止子进程假死拖垮全局
    nice -n 19 bash "${INSTALL_DIR}/core/${TARGET_MOD}" 200>&-
else
    log "SYSTEM" "ERROR" "配置了模块 ${MOD_NAME}，但未找到对应的可执行脚本: ${TARGET_MOD}"
fi

# ----------------------------------------------------------
# [快速声呐] 单 IP 模式每轮固定追加轻量送中探测
# 纯本地日志，不发 TG、不落趋势库，结果并入每日简报送中计数。
# ----------------------------------------------------------
if [ -x "${INSTALL_DIR}/core/mod_quality.sh" ]; then
    log "SYSTEM" "INFO" "快速声呐: 单 IP 轻量送中探测启动"
    QC_MODE=fast nice -n 19 bash "${INSTALL_DIR}/core/mod_quality.sh" 200>&- || true
fi

log "SYSTEM" "INFO" "本轮所有模块调度完毕，哨兵继续隐蔽待命。"