#!/usr/bin/env bash

lp_crash_now() {
  date -Is 2>/dev/null || date
}

lp_crash_redact_command() {
  sed -E \
    -e 's/(--password(=|[[:space:]]+))([^[:space:]]+)/\1[redacted]/g' \
    -e 's/(--pool-password(=|[[:space:]]+))([^[:space:]]+)/\1[redacted]/g' \
    -e 's/(LP_CRASH_UPLOAD_TOKEN=)[^[:space:]]+/\1[redacted]/g' \
    -e 's/(LP_CRASH_UPLOAD_HEADER=)[^[:space:]]+/\1[redacted]/g'
}

lp_crash_safe_name() {
  tr -c 'A-Za-z0-9._+-' '_' | cut -c1-96
}

lp_crash_version() {
  printf '%s\n' "${MINER_VERSION:-${CUSTOM_VERSION:-unknown}}"
}

lp_crash_upload_interval_secs() {
  local v="${LP_CRASH_UPLOAD_INTERVAL_SECS:-900}"
  case "$v" in
    ''|*[!0-9]*) echo 900 ;;
    *) echo "$v" ;;
  esac
}

lp_crash_upload_stamp_dir() {
  printf '%s\n' "${LP_CRASH_UPLOAD_STAMP_DIR:-/var/tmp/lpminer-crash-upload}"
}

lp_crash_upload_rate_key() {
  lp_crash_version | lp_crash_safe_name
}

lp_crash_upload_allowed() {
  local interval
  local dir
  local key
  local stamp
  local now
  local last

  interval="$(lp_crash_upload_interval_secs)"
  [[ "$interval" -le 0 ]] && return 0

  dir="$(lp_crash_upload_stamp_dir)"
  key="$(lp_crash_upload_rate_key)"
  [[ -z "$key" ]] && key="unknown"
  stamp="${dir}/${key}.last"
  now="$(date +%s 2>/dev/null || echo 0)"
  [[ "$now" -le 0 ]] && return 0

  mkdir -p "$dir" 2>/dev/null || return 0
  if [[ -r "$stamp" ]]; then
    read -r last < "$stamp" || last=0
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [[ "$last" -gt 0 && $((now - last)) -lt "$interval" ]]; then
      echo "crash upload skipped: already attempted for version $(lp_crash_version) $((now - last))s ago (limit ${interval}s)"
      return 1
    fi
  fi

  printf '%s\n' "$now" > "${stamp}.$$" 2>/dev/null &&
    mv -f "${stamp}.$$" "$stamp" 2>/dev/null || true
  return 0
}

lp_crash_gpu_count() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo 0
    return
  fi
  nvidia-smi -L 2>/dev/null | awk '/^GPU [0-9]+:/ {count++} END {print count + 0}'
}

lp_crash_gpu_model() {
  local models
  local unique_count

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "unknown-gpu"
    return
  fi

  models="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sort -u)"
  unique_count="$(printf '%s\n' "$models" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ -z "$models" || "$unique_count" -eq 0 ]]; then
    echo "unknown-gpu"
  elif [[ "$unique_count" -eq 1 ]]; then
    printf '%s\n' "$models"
  else
    echo "mixed-gpu"
  fi
}

lp_crash_print_diagnostics() {
  local rc="$1"
  local cmd="${2:-}"

  echo "--- lpminer crash diagnostics rc=${rc} $(lp_crash_now) ---"
  if [[ -n "$cmd" ]]; then
    printf '%s\n' "$cmd" | lp_crash_redact_command | sed 's/^/command: /'
  fi
  echo "--- host ---"
  hostname 2>/dev/null || true
  uname -a 2>/dev/null || true
  if [[ -r /etc/os-release ]]; then
    sed -n '1,12p' /etc/os-release 2>/dev/null || true
  fi
  if [[ -r /hive/etc/hive-release ]]; then
    echo "--- hive release ---"
    cat /hive/etc/hive-release 2>/dev/null || true
  fi
  echo "--- nvidia-smi ---"
  nvidia-smi 2>&1 || true
  echo "--- gpu processes ---"
  nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory \
    --format=csv 2>&1 || true
  echo "--- memory ---"
  free -h 2>/dev/null || true
  echo "--- disk ---"
  df -h / /tmp 2>/dev/null || true
  echo "--- recent kernel messages ---"
  dmesg -T 2>/dev/null \
    | egrep -i 'lpminer|segfault|core dumped|killed|oom|xid|nvrm|cuda|nvidia' \
    | tail -160 || true
  if command -v coredumpctl >/dev/null 2>&1; then
    echo "--- coredumpctl list lpminer ---"
    coredumpctl list lpminer --no-pager 2>/dev/null | tail -60 || true
  fi
  echo "--- end diagnostics ---"
}

lp_crash_make_bundle() {
  local rc="$1"
  local log="$2"
  local cmd="${3:-}"
  local tmpdir
  local bundle
  local host
  local ts

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/lpminer-crash.XXXXXX")" || return 1
  host="$(hostname 2>/dev/null | lp_crash_safe_name)"
  [[ -z "$host" ]] && host="unknown-host"
  ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
  bundle="${TMPDIR:-/tmp}/lpminer-crash-${host}-${ts}-rc${rc}.tar.gz"

  {
    echo "timestamp=$(lp_crash_now)"
    echo "exit_code=${rc}"
    echo "host=${host}"
    echo "miner_version=${MINER_VERSION:-${CUSTOM_VERSION:-unknown}}"
    echo "worker=${WORKER_NAME:-unknown}"
    echo "pool=${LP_POOL_URL:-unknown}"
    echo "gpu_count=$(lp_crash_gpu_count)"
    echo "gpu_model=$(lp_crash_gpu_model)"
    if [[ -n "$cmd" ]]; then
      printf 'command='
      printf '%s\n' "$cmd" | lp_crash_redact_command
    fi
  } > "${tmpdir}/meta.txt"

  if [[ -r "$log" ]]; then
    cp "$log" "${tmpdir}/lpminer.log" 2>/dev/null || true
  fi
  lp_crash_print_diagnostics "$rc" "$cmd" > "${tmpdir}/diagnostics.txt" 2>&1 || true
  env | sort \
    | egrep '^(CUSTOM_|MINER_|WORKER_NAME=|LP_|CUDA_VISIBLE_DEVICES=|NVIDIA_|PATH=)' \
    | grep -v -E '^(LP_CRASH_UPLOAD_TOKEN|LP_CRASH_UPLOAD_HEADER)=' \
    > "${tmpdir}/env.txt" 2>/dev/null || true

  if [[ -r /var/run/hive-miner-lpminer.stats.json ]]; then
    cp /var/run/hive-miner-lpminer.stats.json "${tmpdir}/hive-stats.json" \
      2>/dev/null || true
  fi

  tar -C "$tmpdir" -czf "$bundle" . 2>/dev/null || {
    rm -rf "$tmpdir"
    return 1
  }
  rm -rf "$tmpdir"
  printf '%s\n' "$bundle"
}

lp_crash_upload_bundle() {
  local rc="$1"
  local log="$2"
  local cmd="${3:-}"
  local url="${LP_CRASH_UPLOAD_URL:-}"
  local bundle
  local gpu_count
  local gpu_model
  local curl_args=()

  [[ -z "$url" ]] && return 0
  if ! command -v curl >/dev/null 2>&1; then
    echo "crash upload skipped: curl not found"
    return 0
  fi

  bundle="$(lp_crash_make_bundle "$rc" "$log" "$cmd" 2>/dev/null || true)"
  if [[ -z "$bundle" || ! -s "$bundle" ]]; then
    echo "crash upload skipped: failed to create bundle"
    return 0
  fi

  if [[ -n ${LP_CRASH_UPLOAD_HEADER:-} ]]; then
    curl_args+=(-H "$LP_CRASH_UPLOAD_HEADER")
  fi
  if [[ -n ${LP_CRASH_UPLOAD_TOKEN:-} ]]; then
    curl_args+=(-H "Authorization: Bearer ${LP_CRASH_UPLOAD_TOKEN}")
  fi

  if ! lp_crash_upload_allowed; then
    rm -f "$bundle"
    return 0
  fi

  gpu_count="$(lp_crash_gpu_count)"
  gpu_model="$(lp_crash_gpu_model)"

  echo "uploading crash report: ${url}"
  if curl -fsS --connect-timeout "${LP_CRASH_UPLOAD_CONNECT_TIMEOUT:-3}" \
      --max-time "${LP_CRASH_UPLOAD_MAX_TIME:-12}" \
      "${curl_args[@]}" \
      -F "file=@${bundle};type=application/gzip" \
      -F "exit_code=${rc}" \
      -F "host=$(hostname 2>/dev/null || echo unknown)" \
      -F "version=$(lp_crash_version)" \
      -F "worker=${WORKER_NAME:-unknown}" \
      -F "gpu_count=${gpu_count}" \
      -F "gpu_model=${gpu_model}" \
      "$url"; then
    echo
    echo "crash report uploaded: ${bundle}"
  else
    echo
    echo "crash upload failed; bundle kept at ${bundle}"
    return 0
  fi
  rm -f "$bundle"
}

append_exit_diagnostics() {
  local rc="$1"
  local log="$2"
  local cmd="${3:-}"

  echo "lpminer exited rc=${rc}" | tee -a "$log"
  if [[ "$rc" -eq 0 ]]; then
    return
  fi

  lp_crash_print_diagnostics "$rc" "$cmd" 2>&1 | tee -a "$log"
  lp_crash_upload_bundle "$rc" "$log" "$cmd" 2>&1 | tee -a "$log"
}

run_miner_logged() {
  local cmd="$1"
  local log="$2"
  eval "$cmd" 2>&1 | tee -a "$log"
  local rc=${PIPESTATUS[0]}
  append_exit_diagnostics "$rc" "$log" "$cmd"
  exit "$rc"
}

run_argv_logged() {
  local log="$1"
  shift
  "$@" 2>&1 | tee -a "$log"
  local rc=${PIPESTATUS[0]}
  append_exit_diagnostics "$rc" "$log" "$*"
  return "$rc"
}
