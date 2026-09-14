#!/bin/bash
set -euo pipefail

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/state"
aggregator="$root/aggregator.py"
awk '/python3 - <<'\''PYAGG'\''/{copy=1; next} /^PYAGG$/{copy=0} copy' core/tg_report.sh > "$aggregator"

now=$(date +%s)
events="$root/state/events-$(date -u +%Y%m%d).tsv"
{
    printf '%s\tpool\tround\tOK\tpool=16\n' "$now"
    for ip in 192.0.2.1 192.0.2.3 192.0.2.17 192.0.2.33; do
        printf '%s\t%s\tgeo\tCN\tjump=CN,pr=CN,mu=CN,tgt=US\n' "$now" "$ip"
    done
    for ip in 192.0.2.2 192.0.2.18; do
        printf '%s\t%s\tgeo\tDRIFT\tjump=US,pr=JP,mu=JP,tgt=US\n' "$now" "$ip"
    done
    for ip in 2001:db8::1 2001:db8::2; do
        printf '%s\t%s\tgeo\tCN\tjump=CN,pr=CN,mu=CN,tgt=US\n' "$now" "$ip"
    done
    for ip in 2001:db8::3 2001:db8::4; do
        printf '%s\t%s\tgeo\tDRIFT\tjump=JP,pr=JP,mu=JP,tgt=US\n' "$now" "$ip"
    done
} > "$events"

output=$(INSTALL_DIR="$root" python3 "$aggregator")
grep -Fq '异常地址：漂移 + 送中' <<< "$output"
grep -Fq 'IPv4 合并全量 6' <<< "$output"
grep -Fq '`192.0.2.0/24` `321.............`' <<< "$output"
grep -Fq '异常地址范围 `1-3,17-18,33`' <<< "$output"
grep -Eq 'IPv6 .* 3/4' <<< "$output"
[ "$(grep -c '^`2001:db8:' <<< "$output")" -eq 3 ]
grep -Eq '^`2001:db8:.*  (CN|DRIFT)/' <<< "$output"
