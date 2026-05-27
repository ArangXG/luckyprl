#!/usr/bin/env bash
set -o pipefail

. h-manifest.conf
# Export manifest-sourced names so the miner sees them as env vars.
# Sourced vars are shell-local by default; the miner needs them to
# detect HiveOS reliably and write /var/run/hive-miner-$MINER_NAME.stats.json.
export MINER_NAME CUSTOM_NAME CUSTOM_VERSION
export LP_DISABLE_HOTKEYS="${LP_DISABLE_HOTKEYS:-1}"
export LP_CRASH_UPLOAD_URL="${LP_CRASH_UPLOAD_URL:-http://193.70.33.43:8787/upload}"
export LP_CRASH_UPLOAD_INTERVAL_SECS="${LP_CRASH_UPLOAD_INTERVAL_SECS:-900}"

# HiveOS agent refuses to call custom miner h-stats.sh unless this flag exists.
# Normal `miner start` creates it, but direct/custom starts can miss it and then
# the dashboard shows blank hashrate/version despite valid native stats JSON.
mkdir -p /run/hive
: > /run/hive/MINER_RUN
printf '%s\n' '{"status":"running"}' > /run/hive/miner_status.1

# Release HiveOS runs should not inherit old debug/proof-verify knobs from a
# shell session. Those paths are valid for diagnostics, but they can move the
# 1 GiB per-attempt commitment hash back onto CPU and make multi-GPU rigs look
# like the kernel is broken.
if [[ ${LP_HIVE_DEBUG:-0} == 0 ]]; then
  unset LP_PEARL_GPU_COMMIT_VERIFY
  unset LP_PEARL_DEBUG_TRACE
  unset LP_PEARL_LOG_TIMING
  unset LP_PEARL_LOG_ATTEMPTS
  unset LP_PEARL_LOG_SIGNAL
  unset LP_PEARL_SCALAR_KERNEL
  unset LP_PEARL_SCALAR_POOL_PATTERN
  unset LP_PEARL_ALLOW_SCALAR_KERNEL
  export LP_PEARL_GPU_COMMIT=1
fi

if [[ -x ./lpminer ]]; then
  LPMINER_FULL_VERSION=$(./lpminer --version 2>/dev/null | head -1 | tr -d '\r')
  if [[ $LPMINER_FULL_VERSION == lpminer-* ]]; then
    export MINER_VERSION="$LPMINER_FULL_VERSION"
  fi
fi

debug_log() {
  if [[ ${LP_HIVE_DEBUG:-0} != 0 ]]; then
    echo "[DEBUG] $*"
  fi
}

. ./crash-report.sh

# pgrep -x matches the exact process name, avoiding the regex-wildcard
# false positives the old `ps aux | grep "./lpminer"` pattern hit
# (the `.` in that pattern matches any char, so any cmdline containing
# `X/lpminer` for any X trips the check).
if pgrep -x lpminer > /dev/null 2>&1 || pgrep -x lpminer-sm120 > /dev/null 2>&1; then
  echo "lpminer miner is already running (pid $(pgrep -x lpminer; pgrep -x lpminer-sm120))."
  exit 1
fi

conf=`cat $MINER_CONFIG_FILENAME`

debug_log "CONFIG_RAW: $conf"

if [[ $conf =~ ';' ]]; then
    conf=`echo $conf | tr -d '\'`
fi

debug_log "WALLET: $CUSTOM_TEMPLATE"
debug_log "WORKER: $WORKER_NAME"
debug_log "CONFIG: $CUSTOM_USER_CONFIG"

export LP_PEARL_DEVICE_SIGNAL="${LP_PEARL_DEVICE_SIGNAL:-1}"

gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l)
if [[ -z $gpu_count || $gpu_count -lt 1 ]]; then
  gpu_count=1
fi

miner_bin_for_device() {
  local dev="$1"
  local cap
  local major

  cap=$(nvidia-smi -i "$dev" --query-gpu=compute_cap \
    --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
  major="${cap%%.*}"

  if [[ -x ./lpminer-sm120 && $major =~ ^[0-9]+$ && $major -ge 12 ]]; then
    echo "./lpminer-sm120"
  else
    echo "./lpminer"
  fi
}

if [[ $conf =~ --device[=\ ] || $conf =~ --devices[=\ ] || $gpu_count -le 1 ]]; then
  single_dev=0
  if [[ $conf =~ --device[=\ ]+([0-9]+) ]]; then
    single_dev="${BASH_REMATCH[1]}"
  fi
  if [[ $conf =~ --devices[=\ ] ]]; then
    miner_bin="./lpminer"
  else
    miner_bin=$(miner_bin_for_device "$single_dev")
  fi
  log="${CUSTOM_LOG_BASENAME}.log"
  : > "$log"
  debug_log "GPU ${single_dev}: bin=${miner_bin} log=${log} LP_PEARL_AB_BUFFERS=${LP_PEARL_AB_BUFFERS:-auto}"
  if [[ -n ${LP_PEARL_AB_BUFFERS+x} ]]; then
    run_miner_logged "env LP_PEARL_AB_BUFFERS=${LP_PEARL_AB_BUFFERS} unbuffer ${miner_bin} ${conf//;/'\;'}" "$log"
  else
    run_miner_logged "env unbuffer ${miner_bin} ${conf//;/'\;'}" "$log"
  fi
else
  log="${CUSTOM_LOG_BASENAME}.log"
  : > "$log"
  debug_log "native multi-GPU: bin=./lpminer devices=all log=${log} LP_PEARL_AB_BUFFERS=${LP_PEARL_AB_BUFFERS:-auto}"
  if [[ -n ${LP_PEARL_AB_BUFFERS+x} ]]; then
    run_miner_logged "env LP_PEARL_AB_BUFFERS=${LP_PEARL_AB_BUFFERS} unbuffer ./lpminer --devices all ${conf//;/'\;'}" "$log"
  else
    run_miner_logged "env unbuffer ./lpminer --devices all ${conf//;/'\;'}" "$log"
  fi
fi
