#!/bin/bash
# ==========================================================
# Module: net_common.sh
# Unified outbound builder for probe/care traffic.
#   - source-IP pinning (--interface) with IP-drift degradation
#   - DoH bypass: multi-endpoint, address-family aware, probe-selected
#   - observability: stable tokens DOH_FALLBACK / DNS_HIJACK_SUSPECT
# Sourced by modules. Safe when PROBE_DOH_URLS is empty (full disable).
# ==========================================================

# --- runtime anchors (re-source config so BIND_IP / IP_PREF are available) ---
_sentinel_cfg="${CONFIG_FILE:-${INSTALL_DIR:-/opt/ip_sentinel}/config.conf}"
[ -f "$_sentinel_cfg" ] && source "$_sentinel_cfg" 2>/dev/null || true

_sentinel_log_file="${LOG_FILE:-${INSTALL_DIR:-/opt/ip_sentinel}/logs/sentinel.log}"

# --- logger (independent of host log function, stable NetGuard module tag) ---
_sentinel_net_log() {
    local level="$1" msg="$2"
    local ver="${AGENT_VERSION:-unknown}"
    local region="${REGION_CODE:-SYSTEM}"
    local core_msg
    core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$ver" "$level" "NetGuard" "$region" "$msg")
    mkdir -p "$(dirname "$_sentinel_log_file")" 2>/dev/null || true
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$_sentinel_log_file"
    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$core_msg" 2>/dev/null || true
    fi
}

# --- globals produced by sentinel_net_init ---
SENTINEL_DOH_URL=""
CURL_BIND_ARGS=()
DYNAMIC_IP_PREF="-${IP_PREF:-4}"

# --- helpers ---------------------------------------------------------------

_sentinel_is_private_ip() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^127\. ]] || \
    [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^169\.254\. ]] || \
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] || \
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
    [[ "$ip" =~ ^198\.1[89]\. ]]
}

# functional probe of a candidate endpoint (also validates curl --doh-url support)
_sentinel_doh_ok() {
    local url="$1"
    curl "${CURL_BIND_ARGS[@]}" "$DYNAMIC_IP_PREF" --doh-url "$url" \
        -s -m 6 -o /dev/null "https://example.com/" 2>/dev/null
    return $?
}

# multi-endpoint, family-aware DoH selection; first reachable endpoint wins
_sentinel_select_doh() {
    local fam="$1"
    [ -n "$PROBE_DOH_URLS" ] || return 0

    local _doh_arr cand host
    IFS=',' read -r -a _doh_arr <<< "$PROBE_DOH_URLS"
    for cand in "${_doh_arr[@]}"; do
        cand=$(printf '%s' "$cand" | tr -d '[:space:]')
        [ -n "$cand" ] || continue

        host=$(printf '%s' "$cand" | sed -E 's#^https?://##; s#/.*$##' | tr -d '[]')
        if [[ -n "$fam" ]]; then
            if [[ "$fam" == "6" && "$host" != *":"* ]]; then continue; fi
            if [[ "$fam" == "4" && "$host" == *":"* ]]; then continue; fi
        fi

        if _sentinel_doh_ok "$cand"; then
            SENTINEL_DOH_URL="$cand"
            _sentinel_net_log "INFO " "DoH endpoint selected: ${cand}"
            return 0
        fi
    done

    _sentinel_net_log "WARN " "DOH_FALLBACK all DoH endpoints unreachable, fallback to system DNS"
    return 1
}

# hijack self-check: system resolver returning non-global IP for a public site
_sentinel_hijack_check() {
    local sys_ip
    sys_ip=$(getent ahostsv4 www.google.com 2>/dev/null | awk '{print $1; exit}')
    if [[ -n "$sys_ip" ]] && _sentinel_is_private_ip "$sys_ip"; then
        _sentinel_net_log "WARN " "DNS_HIJACK_SUSPECT system resolver returned non-public IP (${sys_ip}) for www.google.com"
    fi
}

# ==========================================================
# sentinel_net_init [doh-only]
# Build CURL_BIND_ARGS / DYNAMIC_IP_PREF / SENTINEL_DOH_URL.
#   doh-only: skip source-interface pinning (keep default route).
# ==========================================================
sentinel_net_init() {
    local mode="$1"
    CURL_BIND_ARGS=()
    DYNAMIC_IP_PREF="-${IP_PREF:-4}"

    # ---- 1. source-IP pinning with drift degradation ----
    if [[ "$mode" != "doh-only" && -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\.]+$ ]]; then
        local raw_bind
        raw_bind=$(echo "$BIND_IP" | tr -d '[]')
        if ! ip addr show 2>/dev/null | grep -Fq "$raw_bind"; then
            _sentinel_net_log "WARN " "configured egress IP ($raw_bind) lost, degraded to default route"
            CURL_BIND_ARGS=()
        else
            CURL_BIND_ARGS=(--interface "$raw_bind")
            if [[ "$BIND_IP" == *":"* ]]; then
                DYNAMIC_IP_PREF="-6"
            elif [[ "$BIND_IP" == *"."* ]]; then
                DYNAMIC_IP_PREF="-4"
            fi
        fi
    fi

    # ---- 2. address-family for DoH candidate filtering ----
    local fam=""
    if [[ "$BIND_IP" == *":"* ]]; then
        fam="6"
    elif [[ "$BIND_IP" == *"."* ]]; then
        fam="4"
    elif [[ "$DYNAMIC_IP_PREF" == "-6" ]]; then
        fam="6"
    elif [[ "$DYNAMIC_IP_PREF" == "-4" ]]; then
        fam="4"
    fi

    # ---- 3. DoH selection ----
    SENTINEL_DOH_URL=""
    _sentinel_select_doh "$fam"

    # ---- 4. attach DoH to bind args ----
    if [[ -n "$SENTINEL_DOH_URL" ]]; then
        CURL_BIND_ARGS+=(--doh-url "$SENTINEL_DOH_URL")
    fi

    # ---- 5. hijack self-check (local log only) ----
    _sentinel_hijack_check
}

# build a temp CURL_HOME with .curlrc carrying the selected DoH endpoint
# echo the dir path, or empty when no DoH endpoint selected
sentinel_make_doh_curlrc() {
    if [[ -z "$SENTINEL_DOH_URL" ]]; then
        echo ""
        return 0
    fi
    local d
    d=$(mktemp -d /tmp/ip_sentinel_curlhome.XXXXXX 2>/dev/null) || return 1
    printf 'doh-url = "%s"\n' "$SENTINEL_DOH_URL" > "$d/.curlrc"
    echo "$d"
}

sentinel_rm_doh_curlrc() {
    [[ -n "$1" && -d "$1" ]] && rm -rf "$1" 2>/dev/null || true
}
