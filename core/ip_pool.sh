#!/bin/bash
# ==========================================================
# Module: ip_pool.sh
# Multi-IP pool management — enumeration, CIDR filtering,
# round-robin batch selection, and concurrent dispatch.
# Sourced by runner.sh when MULTI_IP_MODE is configured.
# ==========================================================

_IP_POOL=()
_IP_BATCH=()

_ip_pool_enum() {
    local mode="${MULTI_IP_MODE}"
    _IP_POOL=()

    case "$mode" in
        netns)
            local iface="${NETNS_IFACE:-veth0}"
            if ! ip link show "$iface" >/dev/null 2>&1; then
                iface=$(ip -o link show up 2>/dev/null \
                    | awk -F'[ :]+' '$2 != "lo" {print $2; exit}')
            fi
            if [[ -z "$iface" ]]; then
                log "POOL" "ERROR" "netns mode: no usable interface found"
                return 1
            fi

            local proto="${IP_POOL_PROTO}"
            if [[ -z "$proto" || "$proto" == *"4"* ]]; then
                while IFS= read -r addr; do
                    [[ -n "$addr" ]] && _IP_POOL+=("$addr")
                done < <(ip -4 addr show dev "$iface" 2>/dev/null \
                    | awk '/inet /{split($2,a,"/"); print a[1]}')
            fi
            if [[ -z "$proto" || "$proto" == *"6"* ]]; then
                while IFS= read -r addr; do
                    [[ -n "$addr" ]] && _IP_POOL+=("$addr")
                done < <(ip -6 addr show dev "$iface" scope global 2>/dev/null \
                    | awk '/inet6 /{split($2,a,"/"); print a[1]}')
            fi
            ;;
        list)
            local entry clean
            IFS=',' read -ra _ip_pool_list <<< "${IP_POOL}"
            for entry in "${_ip_pool_list[@]}"; do
                clean=$(echo "$entry" | tr -d '[] ')
                [[ -n "$clean" ]] && _IP_POOL+=("$clean")
            done
            unset _ip_pool_list

            if [[ -n "$IP_POOL_PROTO" ]]; then
                local filtered=()
                for addr in "${_IP_POOL[@]}"; do
                    if [[ "$IP_POOL_PROTO" == "4" && "$addr" == *"."* ]]; then
                        filtered+=("$addr")
                    elif [[ "$IP_POOL_PROTO" == "6" && "$addr" == *":"* ]]; then
                        filtered+=("$addr")
                    fi
                done
                _IP_POOL=("${filtered[@]}")
            fi
            ;;
        *)
            return 1
            ;;
    esac

    if [ ${#_IP_POOL[@]} -eq 0 ]; then
        log "POOL" "WARN" "Enumeration returned 0 addresses"
        return 1
    fi

    # CIDR include filter (comma-separated network prefixes)
    if [[ -n "$IP_POOL_FILTER" ]]; then
        local filtered=()
        while IFS= read -r addr; do
            [[ -n "$addr" ]] && filtered+=("$addr")
        done < <(printf '%s\n' "${_IP_POOL[@]}" | python3 -c "
import ipaddress, sys
nets = []
for c in sys.argv[1].split(','):
    c = c.strip()
    if c:
        nets.append(ipaddress.ip_network(c, strict=False))
for line in sys.stdin:
    s = line.strip()
    if not s:
        continue
    try:
        a = ipaddress.ip_address(s)
        if any(a in n for n in nets):
            print(s)
    except ValueError:
        pass
" "$IP_POOL_FILTER")
        _IP_POOL=("${filtered[@]}")
    fi

    if [ ${#_IP_POOL[@]} -eq 0 ]; then
        log "POOL" "WARN" "Pool empty after CIDR filtering (filter=${IP_POOL_FILTER})"
        return 1
    fi

    return 0
}

_ip_pool_select_batch() {
    local pool_size=${#_IP_POOL[@]}
    local batch_size=${IP_BATCH_SIZE:-5}
    local cursor_file="${INSTALL_DIR}/core/.ip_pool_cursor"
    local cursor=0

    if [[ -f "$cursor_file" ]]; then
        cursor=$(cat "$cursor_file" 2>/dev/null | tr -d '[:space:]')
        [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
    fi
    [ "$cursor" -ge "$pool_size" ] && cursor=0

    _IP_BATCH=()
    local count=0
    while [ "$count" -lt "$batch_size" ] && [ "$count" -lt "$pool_size" ]; do
        local idx=$(( (cursor + count) % pool_size ))
        _IP_BATCH+=("${_IP_POOL[$idx]}")
        ((count++))
    done

    echo $(( (cursor + count) % pool_size )) > "$cursor_file"
}

_ip_pool_dispatch() {
    _ip_pool_enum || return 1
    _ip_pool_select_batch

    local pool_size=${#_IP_POOL[@]}
    local batch_size=${#_IP_BATCH[@]}
    local concurrency=${IP_CONCURRENCY:-3}
    local ns_id
    ns_id=$(ip netns identify $$ 2>/dev/null) || true

    log "POOL" "INFO" "Pool: ${pool_size} IPs (ns=${ns_id:-default}), batch=${batch_size}, concurrency=${concurrency}"

    local pids=()
    local tmp_files=()
    local orig_config="${CONFIG_FILE}"

    _ip_pool_cleanup() { for f in "${tmp_files[@]}"; do rm -f "$f"; done; }
    trap _ip_pool_cleanup EXIT

    local has_wait_n=false
    (wait -n 2>/dev/null; true) 2>/dev/null && has_wait_n=true

    for ip_addr in "${_IP_BATCH[@]}"; do
        local ip_pref="4"
        local safe_ip="$ip_addr"
        if [[ "$ip_addr" == *":"* ]]; then
            ip_pref="6"
            safe_ip="[${ip_addr}]"
        fi

        local tmp_cfg
        tmp_cfg=$(mktemp /tmp/ip_sentinel_rc.XXXXXX)
        cp "$orig_config" "$tmp_cfg"
        sed -i "s|^PUBLIC_IP=.*|PUBLIC_IP=\"${safe_ip}\"|" "$tmp_cfg"
        sed -i "s|^BIND_IP=.*|BIND_IP=\"${safe_ip}\"|" "$tmp_cfg"
        sed -i "s|^IP_PREF=.*|IP_PREF=\"${ip_pref}\"|" "$tmp_cfg"
        tmp_files+=("$tmp_cfg")

        local target_mod="" mod_name=""
        if [ "$ENABLE_GOOGLE" == "true" ] && [ "$ENABLE_TRUST" == "true" ]; then
            if [ $((RANDOM % 100 + 1)) -le 70 ]; then
                target_mod="mod_google.sh"; mod_name="Google"
            else
                target_mod="mod_trust.sh"; mod_name="Trust"
            fi
        elif [ "$ENABLE_GOOGLE" == "true" ]; then
            target_mod="mod_google.sh"; mod_name="Google"
        elif [ "$ENABLE_TRUST" == "true" ]; then
            target_mod="mod_trust.sh"; mod_name="Trust"
        else
            continue
        fi

        if [ -x "${INSTALL_DIR}/core/${target_mod}" ]; then
            log "POOL" "INFO" "Dispatch: ${mod_name} -> ${ip_addr}"
            CONFIG_FILE="$tmp_cfg" nice -n 19 bash "${INSTALL_DIR}/core/${target_mod}" 200>&- &
            pids+=($!)
        fi

        if [ ${#pids[@]} -ge "$concurrency" ]; then
            if $has_wait_n; then
                wait -n 2>/dev/null || true
                local alive=()
                for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive+=("$p"); done
                pids=("${alive[@]}")
            else
                wait "${pids[0]}" 2>/dev/null || true
                pids=("${pids[@]:1}")
            fi
        fi
    done

    wait 2>/dev/null || true
    _ip_pool_cleanup
    trap - EXIT

    log "POOL" "INFO" "Batch complete: ${batch_size} IPs processed"
    return 0
}
