#!/usr/bin/env bash
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir" || exit 1

if [[ -r ./h-manifest.conf ]]; then
  . ./h-manifest.conf
fi
. ./crash-report.sh

export CUSTOM_NAME="${CUSTOM_NAME:-lpminer}"
export MINER_NAME="${MINER_NAME:-$CUSTOM_NAME}"
export CUSTOM_VERSION="${CUSTOM_VERSION:-unknown}"
export LP_DISABLE_HOTKEYS="${LP_DISABLE_HOTKEYS:-1}"
export LP_CRASH_UPLOAD_URL="${LP_CRASH_UPLOAD_URL:-http://193.70.33.43:8787/upload}"
export LP_CRASH_UPLOAD_INTERVAL_SECS="${LP_CRASH_UPLOAD_INTERVAL_SECS:-900}"

if [[ -x ./lpminer ]]; then
  LPMINER_FULL_VERSION=$(./lpminer --version 2>/dev/null | head -1 | tr -d '\r')
  if [[ $LPMINER_FULL_VERSION == lpminer-* ]]; then
    export MINER_VERSION="$LPMINER_FULL_VERSION"
  fi
fi

usage() {
  cat <<'EOF'
usage:
  ./run.sh lpminer [miner args...]
  ./run.sh ./lpminer [miner args...]

crash upload:
  set LP_CRASH_UPLOAD_URL=https://your-upload-endpoint before running.
  optional: LP_CRASH_UPLOAD_TOKEN=... or LP_CRASH_UPLOAD_HEADER='X-Key: ...'
EOF
}

if [[ $# -lt 1 || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 2
fi

bin="$1"
shift

case "$bin" in
  lpminer)
    bin="./lpminer"
    ;;
  lpminer-sm120)
    bin="./lpminer-sm120"
    ;;
esac

if [[ ! -x "$bin" ]]; then
  echo "error: miner binary not executable: $bin" >&2
  exit 127
fi

log="${LP_RUN_LOG:-${script_dir}/lpminer-run.log}"
: > "$log"

echo "lpminer run log: $log"
if [[ -n ${LP_CRASH_UPLOAD_URL:-} ]]; then
  echo "crash upload: enabled"
else
  echo "crash upload: disabled (set LP_CRASH_UPLOAD_URL to enable)"
fi

run_argv_logged "$log" "$bin" "$@"
exit "$?"
