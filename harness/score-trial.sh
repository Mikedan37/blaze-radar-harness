#!/usr/bin/env bash
# Score frozen trial artifacts (scorer v2).
#
# Usage:
#   score-trial.sh --trial trial-002
#   score-trial.sh --trial trial-002 --out ~/radar-harness/trial-002-score.json
#   score-trial.sh --trial trial-002 --report ~/radar-harness/trial-002/trial-report.md
#
# Reads:
#   ~/radar-harness/<trial>-{radar,no-radar}/
#   ~/radar-trials/<trial>-*/run-logs/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCORER_V2="${REPO_ROOT}/lib/score_trial_v2.py"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Options:"
  echo "  --trial ID           e.g. trial-002"
  echo "  --radar PATH         Radar arm benchmark dir"
  echo "  --no-radar PATH      No-radar arm benchmark dir"
  echo "  --bench-root PATH    Default: ~/radar-harness"
  echo "  --trials-root PATH   Default: ~/radar-trials"
  echo "  --out PATH           Write score JSON"
  echo "  --report PATH        Write trial-report.md"
  exit "${1:-0}"
}

TRIAL_BASE=""
RADAR_DIR=""
NO_RADAR_DIR=""
BENCH_ROOT="${HOME}/radar-benchmarks"
TRIALS_ROOT="${HOME}/radar-trials"
OUT_JSON=""
REPORT_MD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trial) TRIAL_BASE="$2"; shift 2 ;;
    --radar) RADAR_DIR="$2"; shift 2 ;;
    --no-radar) NO_RADAR_DIR="$2"; shift 2 ;;
    --bench-root) BENCH_ROOT="$2"; shift 2 ;;
    --trials-root) TRIALS_ROOT="$2"; shift 2 ;;
    --out) OUT_JSON="$2"; shift 2 ;;
    --report) REPORT_MD="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -x "$(command -v python3)" ]] || { echo "error: python3 required" >&2; exit 1; }
[[ -f "$SCORER_V2" ]] || { echo "error: scorer not found: $SCORER_V2" >&2; exit 1; }

args=()
[[ -n "$TRIAL_BASE" ]] && args+=(--trial "$TRIAL_BASE")
[[ -n "$RADAR_DIR" ]] && args+=(--radar "$RADAR_DIR")
[[ -n "$NO_RADAR_DIR" ]] && args+=(--no-radar "$NO_RADAR_DIR")
args+=(--bench-root "$BENCH_ROOT" --trials-root "$TRIALS_ROOT")
[[ -n "$OUT_JSON" ]] && args+=(--out "$OUT_JSON")
[[ -n "$REPORT_MD" ]] && args+=(--report "$REPORT_MD")

if [[ -z "$TRIAL_BASE" && ( -z "$RADAR_DIR" || -z "$NO_RADAR_DIR" ) ]]; then
  echo "error: --trial or both --radar and --no-radar required" >&2
  usage 1
fi

exec python3 "$SCORER_V2" "${args[@]}"
