#!/usr/bin/env bash
# HiveOS sources this file inside /hive/bin/agent, not executes it. Set the
# caller-scope variables `khs` and `stats`. lpminer pearl logs one status line
# per process; h-run.sh writes either lpminer.log or lpminer-gpuN.log.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/h-manifest.conf"

miner_ver="${CUSTOM_NAME}-${CUSTOM_VERSION}"
if [[ -x "$script_dir/lpminer" ]]; then
    bin_ver=$("$script_dir/lpminer" --version 2>/dev/null | head -1 | tr -d '\r')
    if [[ $bin_ver == lpminer-* ]]; then
        miner_ver="$bin_ver"
    fi
fi

nvidia_bus_numbers_json() {
    local out="["
    local first=1
    local pci_bus
    while IFS= read -r pci_bus; do
        pci_bus=$(awk -F: '{print $2}' <<< "$pci_bus")
        [[ -z $pci_bus ]] && continue
        if [[ $first -eq 0 ]]; then
            out+=","
        fi
        if [[ $pci_bus =~ ^[0-9A-Fa-f]+$ ]]; then
            out+="$((16#$pci_bus))"
        else
            out+="0"
        fi
        first=0
    done < <(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null)
    out+="]"
    echo "$out"
}

gpu_stats_bus_numbers_json() {
    local out="["
    local first=1
    local pci_bus
    while IFS= read -r pci_bus; do
        pci_bus=$(awk -F: '{print $1}' <<< "$pci_bus")
        [[ -z $pci_bus ]] && continue
        if [[ $first -eq 0 ]]; then
            out+=","
        fi
        if [[ $pci_bus =~ ^[0-9A-Fa-f]+$ ]]; then
            out+="$((16#$pci_bus))"
        else
            out+="0"
        fi
        first=0
    done < <(jq -r '.busids[]? // empty' <<< "${gpu_stats:-}" 2>/dev/null)
    out+="]"
    echo "$out"
}

align_stats_to_gpu_slots() {
    [[ -z ${gpu_stats:-} || -z ${stats:-} || $stats == "null" ]] && return
    local full_bus temp fan
    full_bus=$(gpu_stats_bus_numbers_json)
    [[ $full_bus == "[]" ]] && return
    temp=$(jq -c '.temp // []' <<< "$gpu_stats" 2>/dev/null)
    fan=$(jq -c '.fan // []' <<< "$gpu_stats" 2>/dev/null)
    stats=$(jq -c \
        --argjson full_bus "$full_bus" \
        --argjson temp "$temp" \
        --argjson fan "$fan" \
        '
        (.bus_numbers // []) as $src_bus |
        (.hs // []) as $src_hs |
        .hs = ($full_bus | map(. as $b |
            ($src_bus | index($b)) as $idx |
            if $idx == null then 0 else ($src_hs[$idx] // 0) end
        )) |
        .bus_numbers = $full_bus |
        .temp = $temp |
        .fan = $fan
        ' <<< "$stats" 2>/dev/null)
}

native_ok=0
native_stats_file="${LP_HIVE_STATS_FILE:-/var/run/hive-miner-${CUSTOM_NAME}.stats.json}"
if [[ -s $native_stats_file ]]; then
    native_stats=$(cat "$native_stats_file" 2>/dev/null)
    if jq -e . >/dev/null 2>&1 <<< "$native_stats"; then
        bus=$(nvidia_bus_numbers_json)
        stats=$(jq -c --arg ver "$miner_ver" --argjson bus "$bus" \
            '
            def hs_as_kh:
                if (.hs_units // "khs") == "mhs" then (.hs // [] | map(. * 1000))
                elif (.hs_units // "khs") == "hs" then (.hs // [] | map(. / 1000))
                else (.hs // []) end;
            .ver = $ver |
            if ((.bus_numbers // []) | length) == 0 then .bus_numbers = $bus else . end |
            .hs = hs_as_kh |
            .hs_units = "khs" |
            .total_khs = ([.hs[]?] | add // 0)
            ' \
            <<< "$native_stats" 2>/dev/null)
        [[ -z $stats ]] && stats="$native_stats"
        khs=$(jq -r '
            ([.hs[]?] | add // 0) as $sum |
            if (.hs_units // "hs") == "mhs" then $sum * 1000
            elif (.hs_units // "hs") == "khs" then $sum
            else $sum / 1000 end
        ' <<< "$stats" 2>/dev/null)
        khs=${khs:-0}

        native_temp_count=$(jq -r '.temp | if type == "array" then length else 0 end' \
            <<< "$stats" 2>/dev/null)
        native_fan_count=$(jq -r '.fan | if type == "array" then length else 0 end' \
            <<< "$stats" 2>/dev/null)
        hs_count=$(jq -r '.hs | if type == "array" then length else 0 end' \
            <<< "$stats" 2>/dev/null)
        if [[ -n ${gpu_stats:-} && ( $native_temp_count -eq 0 || $native_fan_count -eq 0 ) ]]; then
            temp=$(jq -c ".temp // [] | .[:$hs_count]" <<< "$gpu_stats" 2>/dev/null)
            fan=$(jq -c ".fan // [] | .[:$hs_count]" <<< "$gpu_stats" 2>/dev/null)
            if [[ -n $temp && -n $fan ]]; then
                stats=$(jq -c \
                    --argjson temp "$temp" \
                    --argjson fan "$fan" \
                    '.temp = $temp | .fan = $fan' \
                    <<< "$stats" 2>/dev/null)
            fi
        fi
        [[ -z $stats ]] && stats="null"
        native_ok=1
    fi
fi

if [[ $native_ok -eq 0 ]]; then
logs=()
for f in "${CUSTOM_LOG_BASENAME}".log "${CUSTOM_LOG_BASENAME}"-gpu*.log; do
    [[ -f $f ]] && logs+=("$f")
done
if [[ ${#logs[@]} -eq 0 && -f /root/lpminer-pearl.screen.log ]]; then
    logs+=(/root/lpminer-pearl.screen.log)
fi

# HiveOS handles kH/s reliably in miner_stats. Raw H/s for Pearl can exceed
# 1e12 per GPU and some UI fields clamp/display it as 1000.0 GH.
hs_json="["
temps_json="["
fans_json="["
bus_json="["
accepted_total=0
rejected_total=0
sum_tmac="0"
sum_khs="0"
uptime=0
gpu_idx=0

for log in "${logs[@]}"; do
    line=$(perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r$//' "$log" 2>/dev/null \
        | grep 'stratum.*stats:' \
        | tail -1)
    [[ -z $line ]] && continue

    tmac=$(sed -n 's/.*kernel_tmac_s=\([0-9.]*\).*/\1/p' <<< "$line")
    accepted=$(sed -n 's/.* accepted=\([0-9]*\) .*/\1/p' <<< "$line")
    rejected=$(sed -n 's/.* rejected=\([0-9]*\) .*/\1/p' <<< "$line")
    elapsed=$(sed -n 's/.* elapsed=\([0-9.]*\)s .*/\1/p' <<< "$line")

    [[ -z $tmac ]] && tmac=0
    [[ -z $accepted ]] && accepted=0
    [[ -z $rejected ]] && rejected=0
    [[ -z $elapsed ]] && elapsed=0

    hs=$(awk -v x="$tmac" 'BEGIN { printf "%.3f", x * 1000000000.0 }')
    gpu_khs=$(awk -v x="$tmac" 'BEGIN { printf "%.3f", x * 1000000000.0 }')

    if [[ $hs_json != "[" ]]; then
        hs_json+=","
        temps_json+=","
        fans_json+=","
        bus_json+=","
    fi
    hs_json+="$hs"

    temp=$(nvidia-smi -i "$gpu_idx" --query-gpu=temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    fan=$(nvidia-smi -i "$gpu_idx" --query-gpu=fan.speed \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    [[ $temp =~ ^[0-9]+$ ]] || temp=0
    [[ $fan =~ ^[0-9]+$ ]] || fan=0
    temps_json+="$temp"
    fans_json+="$fan"
    pci_bus=$(nvidia-smi -i "$gpu_idx" --query-gpu=pci.bus_id \
        --format=csv,noheader 2>/dev/null | head -1 | awk -F: '{print $2}')
    if [[ $pci_bus =~ ^[0-9A-Fa-f]+$ ]]; then
        bus_json+="$((16#$pci_bus))"
    else
        bus_json+="$gpu_idx"
    fi

    accepted_total=$((accepted_total + accepted))
    rejected_total=$((rejected_total + rejected))
    sum_tmac=$(awk -v a="$sum_tmac" -v b="$tmac" 'BEGIN { printf "%.3f", a + b }')
    sum_khs=$(awk -v a="$sum_khs" -v b="$gpu_khs" 'BEGIN { printf "%.3f", a + b }')
    uptime=$(awk -v a="$uptime" -v b="$elapsed" 'BEGIN { printf "%d", (b > a ? b : a) }')
    gpu_idx=$((gpu_idx + 1))
done

hs_json+="]"
temps_json+="]"
fans_json+="]"
bus_json+="]"

if [[ $hs_json == "[]" ]]; then
    khs=0
    stats="null"
else
    khs="$sum_khs"
    stats=$(jq -nc \
        --argjson hs "$hs_json" \
        --argjson temp "$temps_json" \
        --argjson fan "$fans_json" \
        --argjson bus "$bus_json" \
        --argjson ar "[$accepted_total,$rejected_total]" \
        --arg ver "$miner_ver" \
        --argjson total_khs "$sum_khs" \
        --argjson uptime "$uptime" \
        '{hs:$hs,hs_units:"khs",total_khs:$total_khs,temp:$temp,fan:$fan,bus_numbers:$bus,ar:$ar,uptime:$uptime,ver:$ver,algo:"pearl"}' \
        2>/dev/null)
    [[ -z $stats ]] && stats="null"
fi
fi

align_stats_to_gpu_slots
