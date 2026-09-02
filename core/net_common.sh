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

# ==========================================================
# Structured event stream (per-IP attribution for the pool report)
#
# The free-text log cannot be attributed back to a single IP: with
# IP_CONCURRENCY writers the "current IP" line and the later verdict
# line of one session are separated by hundreds of interleaved lines
# and carry no session id. This append-only stream fixes that.
#
# Concurrency: a single write() of <PIPE_BUF (4096) bytes to an
# O_APPEND fd is atomic on Linux. Event lines are ~80 bytes, so all
# IP_CONCURRENCY writers can append lock-free.
#
# Schema (tab-separated):
#   ts  ip  module  verdict  detail
#   module  : geo | trust | fastqc | dns | egress | round
#   verdict : OK | DRIFT | CN | BLIND   (geo, fastqc)
#             OK | BLOCKED              (trust)
#             DOH_FALLBACK | HIJACK     (dns)
#             MISMATCH                  (egress)
#             -                         (round)
# ==========================================================
sentinel_event() {
    local ip="${1:--}" module="$2" verdict="${3:--}" detail="${4:--}"
    local dir="${INSTALL_DIR:-/opt/ip_sentinel}/state"
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%s)" "$ip" "$module" "$verdict" "$detail" \
        >> "${dir}/events-$(date -u +%Y%m%d).tsv" 2>/dev/null || true
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

# ==========================================================
# Accept-Language derived from the region's LANG_PARAMS
#
# mod_trust used to send en-US,en;q=0.9 for every region and mod_google sent no
# Accept-Language at all, so a JP/HK/DE session advertised a localized hl= and a
# local persona over a US language header. Browsers lead with a region-qualified
# tag, and hl= is often bare ("ja"), so the region is borrowed from gl=.
#   hl=zh-HK&gl=HK -> zh-HK,zh;q=0.9,en;q=0.8
#   hl=ja&gl=JP    -> ja-JP,ja;q=0.9,en;q=0.8
#   hl=en&gl=GB    -> en-GB,en;q=0.9
# ==========================================================
sentinel_accept_language() {
    local hl="" gl="" tag primary
    [[ "$LANG_PARAMS" == *"hl="* ]] && { hl="${LANG_PARAMS#*hl=}"; hl="${hl%%&*}"; }
    [[ "$LANG_PARAMS" == *"gl="* ]] && { gl="${LANG_PARAMS#*gl=}"; gl="${gl%%&*}"; }

    [[ "$hl" =~ ^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$ ]] || { echo "en-US,en;q=0.9"; return 0; }

    tag="$hl"
    if [[ "$hl" != *-* && "$gl" =~ ^[A-Za-z]{2}$ ]]; then
        tag="${hl}-$(printf '%s' "$gl" | tr 'a-z' 'A-Z')"
    fi
    primary="${tag%%-*}"

    if [ "$primary" = "en" ]; then
        echo "${tag},en;q=0.9"
    else
        echo "${tag},${primary};q=0.9,en;q=0.8"
    fi
}

# functional probe of a candidate endpoint (also validates curl --doh-url support)
_sentinel_doh_ok() {
    local url="$1"
    curl "${CURL_BIND_ARGS[@]}" "$DYNAMIC_IP_PREF" --doh-url "$url" \
        -s -m 6 -o /dev/null "https://example.com/" 2>/dev/null
    return $?
}

# ----------------------------------------------------------
# Selected-endpoint cache
#
# sentinel_net_init runs once per session and a pool node opens ~8.6k sessions a
# day, so re-probing every candidate every time cost one example.com round trip
# per session — and up to 4x6s whenever the leading endpoints were down. Caching
# the winner per address family collapses that to a couple of probes per hour.
# PROBE_DOH_TTL=0 restores the previous probe-every-session behaviour.
# ----------------------------------------------------------
_sentinel_doh_cache_file() {
    echo "${INSTALL_DIR:-/opt/ip_sentinel}/state/.doh_endpoint.${1:-any}"
}

_sentinel_doh_cache_get() {
    local f ts url now
    f=$(_sentinel_doh_cache_file "$1")
    [ -r "$f" ] || return 1
    IFS=$'\t' read -r ts url < "$f" 2>/dev/null || return 1
    [[ "$ts" =~ ^[0-9]+$ ]] && [ -n "$url" ] || return 1
    now=$(date -u +%s)
    [ $(( now - ts )) -lt "${PROBE_DOH_TTL:-1800}" ] || return 1

    # A config edit must invalidate the cache, so the hit has to still be listed.
    # Compared element-wise rather than by pattern: an IPv6 endpoint URL carries
    # "[2606:4700:4700::1111]", which both a glob match and unquoted word
    # splitting would read as a character class.
    local cand hit=1 _arr
    IFS=',' read -r -a _arr <<< "${PROBE_DOH_URLS// /}"
    for cand in "${_arr[@]}"; do
        [ "$cand" = "$url" ] && { hit=0; break; }
    done
    [ "$hit" -eq 0 ] || return 1

    SENTINEL_DOH_URL="$url"
}

_sentinel_doh_cache_put() {
    local f tmp
    f=$(_sentinel_doh_cache_file "$1")
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    # Atomic replace: IP_CONCURRENCY writers may refresh the same file at once.
    tmp=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 0
    if printf '%s\t%s\n' "$(date -u +%s)" "$2" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# multi-endpoint, family-aware DoH selection; first reachable endpoint wins
_sentinel_select_doh() {
    local fam="$1"
    [ -n "$PROBE_DOH_URLS" ] || return 0

    if [ "${PROBE_DOH_TTL:-1800}" -gt 0 ] 2>/dev/null && _sentinel_doh_cache_get "${fam:-any}"; then
        return 0
    fi

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
            _sentinel_doh_cache_put "${fam:-any}" "$cand"
            _sentinel_net_log "INFO " "DoH endpoint selected: ${cand}"
            return 0
        fi
    done

    _sentinel_net_log "WARN " "DOH_FALLBACK all DoH endpoints unreachable, fallback to system DNS"
    sentinel_event "$(echo "${BIND_IP:-${PUBLIC_IP:-unknown}}" | tr -d '[]')" "dns" "DOH_FALLBACK" "-"
    return 1
}

# hijack self-check: system resolver returning non-global IP for a public site
_sentinel_hijack_check() {
    local sys_ip
    sys_ip=$(getent ahostsv4 www.google.com 2>/dev/null | awk '{print $1; exit}')
    if [[ -n "$sys_ip" ]] && _sentinel_is_private_ip "$sys_ip"; then
        _sentinel_net_log "WARN " "DNS_HIJACK_SUSPECT system resolver returned non-public IP (${sys_ip}) for www.google.com"
        sentinel_event "$(echo "${BIND_IP:-${PUBLIC_IP:-unknown}}" | tr -d '[]')" "dns" "HIJACK" "sys=${sys_ip}"
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

# ==========================================================
# YouTube region probe
#
# sw.js_data is the service-worker bootstrap payload: ~1.5 KB against the ~92 KB
# /premium page and ~43 KB music.youtube.com landing page it replaces (measured
# with --compressed). Its fourth field is the egress IP Google actually observed,
# which is the only end-to-end proof that --interface pinning survived the node's
# routing — a silent failure there makes the whole pool measure one address.
#
#   )]}'\n[["yt.sw.adr",null,[[["<hl>","<gl>",null,"<observed ip>",...
#
# Undocumented endpoint, so a layout change must degrade rather than break:
# callers fall back to the HTML probe when this returns non-zero. Results land in
# globals rather than stdout because the observed IP has to escape the call, and
# a $(...) capture would strand it in a subshell.
# ==========================================================
SENTINEL_PROBE_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
SENTINEL_YT_GL=""
SENTINEL_YT_IP=""

sentinel_yt_probe() {
    local host="$1" body field
    SENTINEL_YT_GL=""
    SENTINEL_YT_IP=""

    body=$(curl "${CURL_BIND_ARGS[@]}" "$DYNAMIC_IP_PREF" -m 12 -s --compressed \
        -A "${PROBE_UA:-$SENTINEL_PROBE_UA}" "https://${host}/sw.js_data" 2>/dev/null) || return 1

    if [[ "$body" == *"www.google.cn"* ]]; then
        SENTINEL_YT_GL="CN"
        return 0
    fi

    field=$(printf '%s' "$body" \
        | grep -oE '"[a-zA-Z-]{2,10}","[A-Z]{2}",null,"[0-9a-fA-F.:]*"' | head -n 1)
    [ -n "$field" ] || return 1

    SENTINEL_YT_GL=$(printf '%s' "$field" | cut -d'"' -f4)
    SENTINEL_YT_IP=$(printf '%s' "$field" | cut -d'"' -f6)
    return 0
}

# Compare the egress IP Google observed against the one this session was told to
# bind. A mismatch means --interface never took effect (policy routing, netns
# misconfiguration), i.e. the verdict recorded for this IP belongs to another.
sentinel_check_egress() {
    local expected="$1" observed="$2"
    [ -n "$expected" ] && [ -n "$observed" ] || return 0

    # mod_google's CURRENT_IP degrades to the literal "Unknown" when neither
    # PUBLIC_IP nor BIND_IP is set (a plain single-IP node), which is not an
    # address to compare against — reporting it would be a guaranteed false
    # positive on every such session.
    case "$expected" in
        *[!0-9a-fA-F:.]*) return 0 ;;
        *.*|*:*) ;;
        *) return 0 ;;
    esac

    [ "$expected" = "$observed" ] && return 0

    # IPv6 only: Google echoes the fully expanded form (2a10:483:201:0:0:0:0:1000)
    # while the config carries the compressed one, so a plain string compare would
    # flag every v6 address in the pool. Normalise before deciding, and stay
    # silent when python3 is missing rather than emit a false positive.
    if [[ "$expected" == *:* || "$observed" == *:* ]]; then
        command -v python3 >/dev/null 2>&1 || return 0
        python3 -c 'import ipaddress, sys
try:
    sys.exit(0 if ipaddress.ip_address(sys.argv[1]) == ipaddress.ip_address(sys.argv[2]) else 1)
except ValueError:
    sys.exit(0)' "$expected" "$observed" && return 0
    fi

    _sentinel_net_log "WARN " "EGRESS_MISMATCH bound ${expected}, Google observed ${observed}"
    sentinel_event "$expected" "egress" "MISMATCH" "obs=${observed}"
}
