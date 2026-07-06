#!/usr/bin/env bash
# Harness-only trial runner for Radar harness trials. Spawns Claude Code agents; does not score.
#
# Usage:
#   run-trial.sh --mode radar --trial trial-002-radar --repo ~/SeekerWebsite
#   run-trial.sh --mode no-radar --trial trial-002-no-radar
#   run-trial.sh --mode both --trial trial-002
#   run-trial.sh --mode radar --trial trial-001-radar --smoke
#
# Responsibilities: worktrees, radar install (radar arm), claude -p agents, timeout,
# commit artifacts, collect-trial.sh. Does NOT inspect code or modify agent outputs.
#
# See: ../protocol/trial-1-protocol.md
set -euo pipefail

unset ANTHROPIC_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COLLECT_SCRIPT="${SCRIPT_DIR}/collect-trial.sh"
HOOK_TELEMETRY="${REPO_ROOT}/lib/hook-telemetry.py"
ASSEMBLE_HARNESS="${REPO_ROOT}/lib/assemble-harness.py"

RADAR_HOST="${RADAR_HOST:-demo}"
RADAR_DAEMON="${RADAR_DAEMON:-$(command -v blaze-radar-demo-daemon 2>/dev/null || true)}"
RADAR_CLI="${RADAR_CLI:-$(command -v blaze-radar-demo 2>/dev/null || command -v blaze 2>/dev/null || true)}"
export BLAZE_RADAR_SOCKET="${BLAZE_RADAR_SOCKET:-/tmp/blaze_radar.sock}"
export AGENTD_SOCKET_PATH="${AGENTD_SOCKET_PATH:-/tmp/blaze_agent.sock}"
export BLAZE_DAEMON_AUTOSTART=0

REPO="${HOME}/SeekerWebsite"
PARENT="${HOME}/radar-trials"
OUT_ROOT="${HOME}/radar-benchmarks"
MODE=""
TRIAL_ID=""
TRIAL_BASE=""
PROMPT_PACK="seeker-overlap-v1"
BASE_SHA="1d6695f921c9302a7733cbea3cd89bddbe2a3b10"
BASE_SHORT="1d6695f"
BASE_TAG="radar-trial-1-base"
DURATION_MINUTES=30
BRANCH_PREFIX=""
MODEL=""
CLAUDE="${CLAUDE:-$(command -v claude 2>/dev/null || true)}"
TIMEOUT_CMD="${TIMEOUT_CMD:-$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)}"
SMOKE=0
SKIP_AGENTS=0
COLLECT_ONLY=0
SETUP_ONLY=0
FRESH=0
SYNC_BEFORE_CLAUDE=1
CLAUDE_PERMISSION_MODE="bypassPermissions"
AGENT_COUNT=3
declare -a AGENT_ROLES=()

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Options:"
  echo "  --mode radar|no-radar|both     Trial arm (required unless --collect-only)"
  echo "  --trial ID                     e.g. trial-002-radar or trial-002 (with --mode both)"
  echo "  --repo PATH                    Git repo (default: ~/SeekerWebsite)"
  echo "  --parent PATH                  Worktree parent (default: ~/radar-trials)"
  echo "  --out PATH                     Collector output root (default: ~/radar-harness)"
  echo "  --prompt-pack NAME             Frozen prompts dir (seeker-overlap-v1 | seeker-swarm-v1)"
  echo "  --agents N                     Parallel agents (default: 3 role-split, 8 for swarm)"
  echo "  --base-sha SHA                 Pin base commit (default: Trial 1 SHA)"
  echo "  --branch-prefix PREFIX         Branch prefix: trial/PREFIX-feature (default: nr|r)"
  echo "  --duration-minutes N           Per-agent timeout (default: 30)"
  echo "  --model STRING                 Recorded in collector metadata"
  echo "  --host demo|projectblaze       Radar host (default: demo)"
  echo "  --radar-cli PATH               Radar CLI (default: blaze-radar-demo)"
  echo "  --claude PATH                  claude binary"
  echo "  --no-sync-before-claude        Skip radar sync before claude -p (radar arm)"
  echo "  --smoke                        Radar hook smoke test on feature worktree only"
  echo "  --setup-only                   Create worktrees + install; do not launch agents"
  echo "  --skip-agents                  Setup + collect only (expects prior agent run)"
  echo "  --collect-only                 Run collect-trial.sh only"
  echo "  --fresh                        Remove existing worktrees/branches before setup"
  exit "${1:-0}"
}

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

hook_snapshot() {
  python3 "$HOOK_TELEMETRY" snapshot "$1"
}

write_coordination_bootstrap() {
  local wt="$1" role="$2" logdir="$3"
  local agent_log="${logdir}/${role}"
  local started_at before after manual_sync sync_exit

  [[ -f "${agent_log}/started_at" ]] || return 0
  started_at="$(cat "${agent_log}/started_at")"
  before="$(cat "${agent_log}/hook_before.json")"
  after="$(hook_snapshot "$wt")"
  printf '%s' "$after" > "${agent_log}/hook_after.json"
  manual_sync="$(cat "${agent_log}/manual_sync" 2>/dev/null || echo 0)"
  sync_exit="$(cat "${agent_log}/sync.exit" 2>/dev/null || echo "")"
  python3 "$HOOK_TELEMETRY" bootstrap "$wt" "$started_at" "$before" "$after" "$manual_sync" "$sync_exit" \
    > "${agent_log}/coordination_bootstrap.json"
}

write_commit_record() {
  local agent_log="$1" first_attempt="$2" bypass_used="$3" committed="$4" msg="$5"
  local harness_mode="${6:-false}"
  python3 - "$agent_log" "$first_attempt" "$bypass_used" "$committed" "$msg" "$harness_mode" <<'PY'
import json, sys
from pathlib import Path

agent_log, first_attempt, bypass_used, committed, msg, harness_mode = sys.argv[1:7]
record = {
    "first_attempt": first_attempt,
    "bypass_used": bypass_used == "true",
    "harness_mode": harness_mode == "true",
    "committed": committed == "true",
    "message": msg,
}
Path(agent_log).mkdir(parents=True, exist_ok=True)
(Path(agent_log) / "commit.json").write_text(json.dumps(record, indent=2) + "\n")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --trial) TRIAL_ID="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --parent) PARENT="$2"; shift 2 ;;
    --out) OUT_ROOT="$2"; shift 2 ;;
    --prompt-pack) PROMPT_PACK="$2"; shift 2 ;;
    --base-sha) BASE_SHA="$2"; BASE_SHORT="${BASE_SHA:0:7}"; shift 2 ;;
    --branch-prefix) BRANCH_PREFIX="$2"; shift 2 ;;
    --duration-minutes) DURATION_MINUTES="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --host) RADAR_HOST="$2"; shift 2 ;;
    --radar-cli|--blaze) RADAR_CLI="$2"; shift 2 ;;
    --claude) CLAUDE="$2"; shift 2 ;;
    --no-sync-before-claude) SYNC_BEFORE_CLAUDE=0; shift ;;
    --smoke) SMOKE=1; shift ;;
    --setup-only) SETUP_ONLY=1; shift ;;
    --skip-agents) SKIP_AGENTS=1; shift ;;
    --collect-only) COLLECT_ONLY=1; shift ;;
    --fresh) FRESH=1; shift ;;
    --agents) AGENT_COUNT="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

[[ -d "$REPO" ]] || die "repo not found: $REPO"
REPO="$(cd "$REPO" && pwd)"
mkdir -p "$PARENT" "$OUT_ROOT"

# Level 2 swarm defaults when using seeker-swarm-v1
if [[ -f "${REPO_ROOT}/prompts/${PROMPT_PACK}/mission.txt" ]]; then
  [[ "$AGENT_COUNT" -eq 3 ]] && AGENT_COUNT=8
fi

prompt_dir() {
  local dir="${REPO_ROOT}/prompts/${PROMPT_PACK}"
  [[ -d "$dir" ]] || die "prompt pack not found: $dir"
  printf '%s' "$dir"
}

is_swarm_pack() {
  [[ -f "$(prompt_dir)/mission.txt" ]]
}

trial_level() {
  if is_swarm_pack; then
    printf '%s' "swarm"
  else
    printf '%s' "role-split"
  fi
}

populate_agent_roles() {
  AGENT_ROLES=()
  if is_swarm_pack; then
    local i
    for i in $(seq 1 "$AGENT_COUNT"); do
      AGENT_ROLES+=("agent-$(printf '%02d' "$i")")
    done
  else
    AGENT_ROLES=(feature tests audit)
    AGENT_COUNT=3
  fi
}

first_agent_role() {
  [[ ${#AGENT_ROLES[@]} -gt 0 ]] || populate_agent_roles
  printf '%s' "${AGENT_ROLES[0]}"
}

resolve_mode_from_trial() {
  local id="$1"
  case "$id" in
    *no-radar*) printf '%s' "no-radar" ;;
    *radar*) printf '%s' "radar" ;;
    *) printf '%s' "" ;;
  esac
}

default_branch_prefix() {
  local arm="$1"
  case "$arm" in
    no-radar) printf '%s' "nr" ;;
    radar) printf '%s' "r" ;;
    *) die "unknown arm: $arm" ;;
  esac
}

derive_branch_prefix() {
  local arm="$1" trial_id="$2"
  if [[ -n "$BRANCH_PREFIX" ]]; then
    printf '%s' "$BRANCH_PREFIX"
    return
  fi
  # Trial 1 frozen names in protocol.
  if [[ "$trial_id" == trial-001-* ]]; then
    default_branch_prefix "$arm"
    return
  fi
  local num
  num="$(printf '%s' "$trial_id" | sed -n 's/.*trial-\([0-9][0-9]*\).*/\1/p')"
  if [[ -n "$num" ]]; then
    case "$arm" in
      no-radar) printf 'nr%s' "$num" ;;
      radar) printf 'r%s' "$num" ;;
    esac
    return
  fi
  local slug
  slug="$(printf '%s' "$trial_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-16)"
  case "$arm" in
    no-radar) printf 'nr-%s' "$slug" ;;
    radar) printf 'r-%s' "$slug" ;;
  esac
}

branch_name() {
  local prefix="$1" role="$2"
  printf 'trial/%s-%s' "$prefix" "$role"
}

trial_arm_dir() {
  local id="$1"
  printf '%s/%s' "$PARENT" "$id"
}

build_prompt_file() {
  local arm="$1" role="$2" dest="$3"
  local pdir addendum
  pdir="$(prompt_dir)"
  case "$arm" in
    radar) addendum="addendum-radar.txt" ;;
    no-radar) addendum="addendum-no-radar.txt" ;;
    *) die "unknown arm: $arm" ;;
  esac
  if is_swarm_pack; then
    cat \
      "${pdir}/shared-preamble.txt" \
      "${pdir}/mission.txt" \
      "${pdir}/${addendum}" \
      > "$dest"
  else
    cat \
      "${pdir}/shared-preamble.txt" \
      "${pdir}/role-${role}.txt" \
      "${pdir}/${addendum}" \
      > "$dest"
  fi
}

agent_task_line() {
  local role="$1"
  if is_swarm_pack; then
    printf '%s' "Seeker activation/conversion — ${role}"
    return
  fi
  case "$role" in
    feature) printf '%s' "FEATURE — improve Seeker match/results explanation UX" ;;
    tests) printf '%s' "QUALITY — fix broken tests and test infrastructure" ;;
    audit) printf '%s' "ARCHITECTURE — read-only reliability/consistency audit" ;;
    *) printf '%s' "Trial agent — ${role}" ;;
  esac
}

verify_base_commit() {
  cd "$REPO"
  git fetch origin 2>/dev/null || true
  git rev-parse --verify "$BASE_SHA" >/dev/null 2>&1 || die "base commit not found: $BASE_SHA"
  git tag -f "$BASE_TAG" "$BASE_SHA" 2>/dev/null || true
  log "✓ base commit: $BASE_SHORT ($BASE_SHA)"
}

remove_worktree_if_fresh() {
  local wt="$1" branch="$2"
  [[ "$FRESH" -eq 1 ]] || return 0
  cd "$REPO"
  if [[ -d "$wt" ]]; then
    git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    git worktree prune 2>/dev/null || true
  fi
  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    git branch -D "$branch" 2>/dev/null || true
  fi
}

create_worktrees() {
  local arm="$1" trial_id="$2" prefix="$3"
  local arm_dir role branch wt
  arm_dir="$(trial_arm_dir "$trial_id")"
  mkdir -p "$arm_dir"

  cd "$REPO"
  for role in "${AGENT_ROLES[@]}"; do
    branch="$(branch_name "$prefix" "$role")"
    wt="${arm_dir}/${role}"
    remove_worktree_if_fresh "$wt" "$branch"
    if [[ -d "$wt" ]]; then
      log "  skip $wt (exists)"
      continue
    fi
    if git show-ref --verify --quiet "refs/heads/${branch}"; then
      git worktree add "$wt" "$branch"
    else
      git worktree add -b "$branch" "$wt" "$BASE_TAG"
    fi
    log "  ✓ $wt → $branch"
  done
}

preflight_demo_daemon() {
  local sock="${BLAZE_RADAR_SOCKET:-/tmp/blaze_radar.sock}"
  [[ -n "$RADAR_DAEMON" ]] || die "blaze-radar-demo-daemon not on PATH — build blaze-radar or pass RADAR_DAEMON"

  socket_healthy() {
    python3 - "$sock" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1.0)
s.connect(sys.argv[1])
s.close()
PY
  }

  if socket_healthy; then
    log "✓ demo daemon socket ready ($sock)"
    return 0
  fi

  log "Pre-flight: starting $RADAR_DAEMON..."
  "$RADAR_DAEMON" >> "${HOME}/.blaze/logs/radar-demo-daemon.log" 2>&1 &
  local i
  for i in $(seq 1 30); do
    if socket_healthy; then
      log "✓ demo daemon ready ($sock)"
      return 0
    fi
    sleep 1
  done
  die "demo daemon socket not ready: $sock"
}

preflight_daemon_singleton() {
  local count pids i sock daemon_bin
  sock="${AGENTD_SOCKET_PATH:-/tmp/blaze_agent.sock}"
  count="$( (pgrep -x AgentDaemon 2>/dev/null || true) | wc -l | tr -d ' ')"
  count="${count:-0}"

  socket_healthy() {
    python3 - "$sock" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1.0)
s.connect(sys.argv[1])
s.close()
PY
  }

  if [[ "$count" -eq 0 ]]; then
    [[ -n "$RADAR_CLI" ]] || die "blaze required to start daemon"
    log "Pre-flight: starting AgentDaemon..."
    blaze daemon stop 2>/dev/null || true
    pkill -x AgentDaemon 2>/dev/null || true
    sleep 2
    rm -f "$sock"
    blaze daemon start 2>/dev/null || true
    sleep 5
    if ! socket_healthy; then
      log "Pre-flight: launchd daemon not ready — starting manual AgentDaemon..."
      daemon_bin="${AGENTD_BINARY:-$HOME/Developer/ProjectBlaze/AgentDaemon/.build/release/AgentDaemon}"
      [[ -x "$daemon_bin" ]] || die "AgentDaemon binary not found: $daemon_bin"
      AGENTD_SOCKET_PATH="$sock" "$daemon_bin" >> "${HOME}/.blaze/logs/daemon.stdout.log" 2>> "${HOME}/.blaze/logs/daemon.stderr.log" &
      sleep 5
    fi
    count="$( (pgrep -x AgentDaemon 2>/dev/null || true) | wc -l | tr -d ' ')"
    count="${count:-0}"
  fi

  if [[ "$count" -ne 1 ]]; then
    pids="$(pgrep -x AgentDaemon 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)"
    die "environment invalid: expected exactly 1 AgentDaemon, found ${count} (pids: ${pids:-none}). Run: blaze daemon restart"
  fi

  log "Pre-flight: waiting for daemon socket..."
  for i in $(seq 1 45); do
    if socket_healthy; then
      log "✓ single AgentDaemon (pid $(pgrep -x AgentDaemon | head -1)), socket ready"
      return 0
    fi
    sleep 1
  done
  die "daemon socket not ready: $sock (pid $(pgrep -x AgentDaemon | head -1))"
}

preflight_daemon_rpc() {
  local wt="$1"
  [[ -n "$RADAR_CLI" ]] || die "blaze required for daemon RPC check"
  log "Pre-flight: daemon RPC (radar active)..."
  local out ec=0
  out="$(cd "$wt" && "$RADAR_CLI" radar active --json 2>&1)" || ec=$?
  if [[ "$ec" -ne 0 ]]; then
    die "daemon RPC failed (exit $ec): ${out:0:300}. Run: blaze daemon restart && make -C AgentCLI install"
  fi
  if ! printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    die "daemon RPC returned invalid JSON: ${out:0:300}. Run: blaze daemon restart"
  fi
  log "✓ daemon RPC healthy (radar active)"
}

install_radar_arm() {
  local trial_id="$1"
  local arm_dir role wt
  arm_dir="$(trial_arm_dir "$trial_id")"
  [[ -n "$RADAR_CLI" ]] || die "radar CLI not on PATH — install blaze-radar-demo or pass --radar-cli"

  wt="${arm_dir}/$(first_agent_role)"
  [[ -d "$wt" ]] || die "first agent worktree missing: $wt"

  if [[ "$RADAR_HOST" == "projectblaze" ]]; then
    preflight_daemon_singleton
    preflight_daemon_rpc "$wt"
    for role in "${AGENT_ROLES[@]}"; do
      wt="${arm_dir}/${role}"
      log "  radar install: $wt"
      (cd "$wt" && "$RADAR_CLI" radar install) || die "radar install failed in $wt"
    done
  else
    preflight_demo_daemon
    preflight_daemon_rpc "$wt"
    log "  demo host: prompt-driven sync (no radar install)"
  fi
}

preflight_radar() {
  [[ "$RADAR_HOST" == "projectblaze" ]] || {
    log "✓ demo host: skipping hook doctor (prompt-driven sync)"
    return 0
  }
  local trial_id="$1"
  local wt doctor_out
  wt="$(trial_arm_dir "$trial_id")/$(first_agent_role)"
  [[ -n "$RADAR_CLI" ]] || die "blaze required for radar arm"

  log "Pre-flight: blaze radar doctor (first worktree)..."
  doctor_out="$(cd "$wt" && "$RADAR_CLI" radar doctor 2>&1 || true)"
  printf '%s\n' "$doctor_out"

  if printf '%s' "$doctor_out" | grep -qE '✖ Claude hooks in checkout|not wired in this worktree'; then
    die "radar pre-flight failed: Claude hooks missing in $wt"
  fi
  if ! printf '%s' "$doctor_out" | grep -q 'Claude hooks in checkout'; then
    die "radar pre-flight failed: could not verify hooks in $wt"
  fi
  if ! printf '%s' "$doctor_out" | grep -qE '✔ Claude hooks in checkout|Claude hooks in checkout'; then
    log "⚠ hooks line not clearly passing — verify manually"
  fi
  log "✓ radar hooks wired in checkout"
}

run_smoke_test() {
  local trial_id="$1"
  local wt logdir
  wt="$(trial_arm_dir "$trial_id")/feature"
  logdir="$(trial_arm_dir "$trial_id")/run-logs"
  mkdir -p "$logdir"

  [[ -n "$RADAR_CLI" ]] || die "blaze required for smoke test"
  [[ -n "$CLAUDE" ]] || die "claude required for smoke test"

  log "=== Radar smoke test (claude -p + hooks) ==="
  log "  worktree: $wt"

  local smoke_prompt="Radar smoke test. Read CLAUDE.md. Do not edit any files. Report whether Radar hooks and board integration appear configured."
  (cd "$wt" && "$RADAR_CLI" radar sync --task "Radar smoke test") || true

  log "  launching: claude -p (smoke)..."
  set +e
  (cd "$wt" && "$CLAUDE" -p "$smoke_prompt" \
    --permission-mode "$CLAUDE_PERMISSION_MODE" \
    > "${logdir}/smoke.stdout" 2> "${logdir}/smoke.stderr")
  local smoke_ec=$?
  set -e
  log "  claude exit: $smoke_ec (logs: ${logdir}/smoke.*)"

  log ""
  log "Post-smoke: blaze radar status"
  (cd "$wt" && "$RADAR_CLI" radar status) || true

  log ""
  log "If UserPromptSubmit did not fire in -p mode, use run-trial.sh with default"
  log "sync-before-claude (blaze radar sync --task before each agent)."
}

launch_agent() {
  local arm="$1" trial_id="$2" role="$3" wt="$4" logdir="$5"
  local prompt_file task_line agent_log="${logdir}/${role}"
  mkdir -p "$agent_log"

  prompt_file="${agent_log}/prompt.txt"
  build_prompt_file "$arm" "$role" "$prompt_file"
  task_line="$(agent_task_line "$role")"

  local started_at
  started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '%s' "$started_at" > "${agent_log}/started_at"

  if [[ "$arm" == "no-radar" ]]; then
    printf '0' > "${agent_log}/manual_sync"
  else
    hook_snapshot "$wt" > "${agent_log}/hook_before.json"
    if [[ "$SYNC_BEFORE_CLAUDE" -eq 1 ]]; then
      printf '1' > "${agent_log}/manual_sync"
      log "  [$role] blaze radar sync --task ..."
      set +e
      (cd "$wt" && "$RADAR_CLI" radar sync --task "$task_line") \
        > "${agent_log}/sync.stdout" 2> "${agent_log}/sync.stderr"
      local sync_ec=$?
      set -e
      printf '%s' "$sync_ec" > "${agent_log}/sync.exit"
      if [[ "$sync_ec" -ne 0 ]]; then
        log "  ⚠ [$role] sync failed (exit $sync_ec) — see ${agent_log}/sync.stderr"
      fi
    else
      printf '0' > "${agent_log}/manual_sync"
      printf '' > "${agent_log}/sync.exit"
    fi
  fi
}

start_agent_claude() {
  local arm="$1" role="$2" wt="$3" logdir="$4"
  local agent_log="${logdir}/${role}"
  local prompt_file="${agent_log}/prompt.txt"
  local radar_hooks_off=0
  [[ "$arm" == "no-radar" ]] && radar_hooks_off=1

  log "  [$role] launching claude -p (timeout ${DURATION_MINUTES}m)..."
  (
    cd "$wt"
    if [[ "$radar_hooks_off" -eq 1 ]]; then
      env BLAZE_RADAR_HOOKS=0 "$TIMEOUT_CMD" "${DURATION_MINUTES}m" \
        "$CLAUDE" -p "$(cat "$prompt_file")" \
        --permission-mode "$CLAUDE_PERMISSION_MODE" \
        > "${agent_log}/claude.stdout" \
        2> "${agent_log}/claude.stderr"
    else
      "$TIMEOUT_CMD" "${DURATION_MINUTES}m" \
        "$CLAUDE" -p "$(cat "$prompt_file")" \
        --permission-mode "$CLAUDE_PERMISSION_MODE" \
        > "${agent_log}/claude.stdout" \
        2> "${agent_log}/claude.stderr"
    fi
    echo $? > "${agent_log}/claude.exit"
  ) &
  echo $! > "${agent_log}/claude.pid"
}

wait_for_agents() {
  local arm="$1" trial_id="$2" logdir="$3"
  local arm_dir wt
  arm_dir="$(trial_arm_dir "$trial_id")"
  local role pid ec
  for role in "${AGENT_ROLES[@]}"; do
    pid="$(cat "${logdir}/${role}/claude.pid" 2>/dev/null || true)"
    [[ -n "$pid" ]] || continue
    log "  waiting for $role (pid $pid)..."
    set +e
    wait "$pid"
    ec=$?
    set -e
    echo "$ec" > "${logdir}/${role}/wait.exit"
    wt="${arm_dir}/${role}"
    if [[ "$arm" == "radar" ]]; then
      write_coordination_bootstrap "$wt" "$role" "$logdir"
    fi
    if [[ "$ec" -eq 124 ]]; then
      log "  [$role] timed out after ${DURATION_MINUTES}m (expected at hard stop)"
    elif [[ "$ec" -ne 0 ]]; then
      log "  ⚠ [$role] claude exited $ec (see ${logdir}/${role}/claude.stderr)"
    else
      log "  ✓ [$role] claude finished"
    fi
  done
}

commit_agent_outputs() {
  local arm="$1" trial_id="$2" logdir="$3"
  local arm_dir role wt msg agent_log
  arm_dir="$(trial_arm_dir "$trial_id")"

  for role in "${AGENT_ROLES[@]}"; do
    wt="${arm_dir}/${role}"
    agent_log="${logdir}/${role}"
    msg="${trial_id}: ${role} session end"
    log "  commit: $role"

    local first_attempt="ok" bypass_used=false committed=false

    (
      cd "$wt"
      export BLAZE_RADAR_HARNESS=1
      export BLAZE_RADAR_TRIAL_ID="$trial_id"
      if [[ "$arm" == "no-radar" ]]; then
        export BLAZE_RADAR_HOOKS=0
      fi
      git add -A
      if git diff --cached --quiet; then
        first_attempt="skipped_no_changes"
        write_commit_record "$agent_log" "$first_attempt" "false" "false" "$msg" "true"
        log "    (no staged changes — skipping commit)"
        exit 0
      fi
      if git commit -m "$msg" 2>"${agent_log}/commit.stderr"; then
        committed=true
        write_commit_record "$agent_log" "$first_attempt" "false" "true" "$msg" "true"
        exit 0
      fi
      first_attempt="blocked"
      if [[ "$arm" == "radar" ]]; then
        log "    ⚠ pre-commit blocked despite BLAZE_RADAR_HARNESS=1 — retry with SKIP_HOOK"
        if BLAZE_RADAR_SKIP_HOOK=1 git commit -m "$msg" 2>>"${agent_log}/commit.stderr"; then
          bypass_used=true
          committed=true
          write_commit_record "$agent_log" "$first_attempt" "true" "true" "$msg" "true"
          exit 0
        fi
      fi
      first_attempt="failed"
      write_commit_record "$agent_log" "$first_attempt" "$bypass_used" "false" "$msg" "true"
      return 1
    ) || log "  ⚠ commit failed for $role"
  done
}

postflight_radar() {
  local trial_id="$1" expected="$2" logdir="$3" prefix="$4"
  local wt count ok=true detail names roles_file
  wt="$(trial_arm_dir "$trial_id")/$(first_agent_role)"
  roles_file="${logdir}/agents.list"
  [[ -n "$RADAR_CLI" ]] || return 0

  log "Post-flight: radar board agent count (expect exactly $expected, trial-scoped)..."
  detail="$(
    cd "$wt" && export BLAZE_RADAR_TRIAL_ID="$trial_id" && "$RADAR_CLI" radar active --json 2>/dev/null \
      | python3 - "$expected" "$prefix" "$roles_file" <<'PY' 2>/dev/null || echo "0|[]"
import json, sys
from pathlib import Path

expected = int(sys.argv[1])
prefix = sys.argv[2]
roles_path = Path(sys.argv[3])
roles = [r.strip() for r in roles_path.read_text().splitlines() if r.strip()] if roles_path.is_file() else []
trial_branches = {f"trial/{prefix}-{role}" for role in roles}
d = json.load(sys.stdin)
regs = d.get("registrations", [])
matched = [r for r in regs if r.get("branch") in trial_branches]
names = [r.get("agentName", "?") for r in matched]
print(f"{len(matched)}|{json.dumps(names)}")
PY
  )"
  count="${detail%%|*}"
  names="${detail#*|}"
  if [[ "$count" -ne "$expected" ]]; then
    log "⚠ radar post-flight: $count trial registration(s) on board (expected $expected)"
    log "  Hooks may not fire in claude -p mode — sync-before-claude is the fallback."
    ok=false
  else
    log "✓ radar post-flight: $count trial agent(s) on board ($names)"
  fi
  python3 - "$logdir/postflight.json" "$count" "$expected" "$ok" <<'PY'
import json, sys
from pathlib import Path

out, count, expected, ok = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "true"
Path(out).write_text(json.dumps({
    "radar_registrations": count,
    "expected_registrations": expected,
    "trial_scoped": True,
    "passed": ok,
}, indent=2) + "\n")
PY
  [[ "$ok" == true ]]
}

postflight_no_radar() {
  local trial_id="$1" logdir="$2" prefix="$3"
  local wt count ok=true roles_file
  wt="$(trial_arm_dir "$trial_id")/$(first_agent_role)"
  roles_file="${logdir}/agents.list"
  [[ -n "$RADAR_CLI" ]] || return 0

  count="$(
    cd "$wt" && export BLAZE_RADAR_TRIAL_ID="$trial_id" && "$RADAR_CLI" radar active --json 2>/dev/null \
      | python3 - "$prefix" "$roles_file" <<'PY' 2>/dev/null || echo "0"
import json, sys
from pathlib import Path

prefix = sys.argv[1]
roles_path = Path(sys.argv[2])
roles = [r.strip() for r in roles_path.read_text().splitlines() if r.strip()] if roles_path.is_file() else []
trial_branches = {f"trial/{prefix}-{role}" for role in roles}
d = json.load(sys.stdin)
regs = d.get("registrations", [])
matched = [r for r in regs if r.get("branch") in trial_branches]
print(len(matched))
PY
  )"
  if [[ "$count" -gt 0 ]]; then
    log "⚠ no-radar post-flight: $count trial radar registration(s) — arm may be contaminated"
    ok=false
  else
    log "✓ no-radar post-flight: no trial radar registrations"
  fi
  python3 - "$logdir/postflight.json" "$count" "$ok" <<'PY'
import json, sys
from pathlib import Path

out, count, ok = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "true"
Path(out).write_text(json.dumps({
    "radar_registrations": count,
    "trial_scoped": True,
    "contamination_free": ok,
    "passed": ok,
}, indent=2) + "\n")
PY
  [[ "$ok" == true ]]
}

run_collect() {
  local arm="$1" trial_id="$2" prefix="$3"
  local model_arg=() radar_ws merge_order
  local -a agent_args=()
  [[ -n "$MODEL" ]] && model_arg=(--model "$MODEL")
  radar_ws="$(trial_arm_dir "$trial_id")/$(first_agent_role)"

  for role in "${AGENT_ROLES[@]}"; do
    agent_args+=(--agent "${role}:$(branch_name "$prefix" "$role")")
  done
  merge_order="$(IFS=,; echo "${AGENT_ROLES[*]}")"

  [[ -x "$COLLECT_SCRIPT" ]] || die "collect script not found: $COLLECT_SCRIPT"

  log "Collecting facts → ${OUT_ROOT}/${trial_id}"
  "$COLLECT_SCRIPT" \
    --trial "$trial_id" \
    --out "$OUT_ROOT" \
    --repo "$REPO" \
    --base "$BASE_SHORT" \
    --group "$arm" \
    --duration-minutes "$DURATION_MINUTES" \
    --prompt-pack "$PROMPT_PACK" \
    --radar-workspace "$radar_ws" \
    --merge-order "$merge_order" \
    "${model_arg[@]}" \
    "${agent_args[@]}" \
    ${RADAR_CLI:+--radar-cli "$RADAR_CLI"}
}

run_arm() {
  local arm="$1" trial_id="$2"
  local prefix logdir start_ts expected n_agents
  prefix="$(derive_branch_prefix "$arm" "$trial_id")"
  logdir="$(trial_arm_dir "$trial_id")/run-logs"
  mkdir -p "$logdir"
  start_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  populate_agent_roles
  printf '%s\n' "${AGENT_ROLES[@]}" > "${logdir}/agents.list"
  n_agents="${#AGENT_ROLES[@]}"
  expected="$n_agents"

  log ""
  log "=========================================="
  log "Trial harness: $trial_id ($arm)"
  log "  level:    $(trial_level) ($PROMPT_PACK)"
  log "  agents:   $n_agents (${AGENT_ROLES[*]})"
  log "  prefix:   trial/${prefix}-*"
  log "  duration: ${DURATION_MINUTES}m per agent"
  log "  logs:     $logdir"
  log "=========================================="

  export BLAZE_RADAR_HARNESS=1
  export BLAZE_RADAR_TRIAL_ID="$trial_id"

  verify_base_commit
  create_worktrees "$arm" "$trial_id" "$prefix"

  if [[ "$arm" == "radar" ]]; then
    install_radar_arm "$trial_id"
    preflight_radar "$trial_id"
  fi

  if [[ "$SMOKE" -eq 1 ]]; then
    run_smoke_test "$trial_id"
    return 0
  fi

  if [[ "$SETUP_ONLY" -eq 1 ]]; then
    log "Setup only — agents not launched."
    return 0
  fi

  [[ -n "$CLAUDE" ]] || die "claude not on PATH — pass --claude"
  [[ -n "$TIMEOUT_CMD" ]] || die "timeout not found (brew install coreutils for gtimeout)"

  if [[ "$SKIP_AGENTS" -eq 0 ]]; then
    log ""
    log "Preparing agents (sequential sync for radar)..."
    local arm_dir wt
    arm_dir="$(trial_arm_dir "$trial_id")"
    for role in "${AGENT_ROLES[@]}"; do
      wt="${arm_dir}/${role}"
      launch_agent "$arm" "$trial_id" "$role" "$wt" "$logdir"
    done

    log ""
    log "Launching agents (parallel claude)..."
    for role in "${AGENT_ROLES[@]}"; do
      wt="${arm_dir}/${role}"
      start_agent_claude "$arm" "$role" "$wt" "$logdir"
    done

    wait_for_agents "$arm" "$trial_id" "$logdir"

    log ""
    log "Committing agent outputs..."
    commit_agent_outputs "$arm" "$trial_id" "$logdir"

    log ""
    log "Post-flight checks..."
    if [[ "$arm" == "radar" ]]; then
      postflight_radar "$trial_id" "$expected" "$logdir" "$prefix" || true
    else
      postflight_no_radar "$trial_id" "$logdir" "$prefix" || true
    fi
  else
    log "Skipping agent launch (--skip-agents)."
  fi

  run_collect "$arm" "$trial_id" "$prefix"

  python3 - "${logdir}/harness-meta.json" <<META
import json, sys
from datetime import datetime, timezone

meta = {
    "trial_id": "${trial_id}",
    "arm": "${arm}",
    "branch_prefix": "${prefix}",
    "trial_level": "$(trial_level)",
    "agent_count": ${n_agents},
    "agent_roles": $(printf '%s\n' "${AGENT_ROLES[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'),
    "base_sha": "${BASE_SHA}",
    "prompt_pack": "${PROMPT_PACK}",
    "duration_minutes": ${DURATION_MINUTES},
    "started_at": "${start_ts}",
    "finished_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "sync_before_claude": bool(${SYNC_BEFORE_CLAUDE}),
    "harness": "run-trial.sh",
    "harness_version": 3,
}
open(sys.argv[1], "w").write(json.dumps(meta, indent=2) + "\n")
META
  python3 "$ASSEMBLE_HARNESS" "$logdir" "${logdir}/harness-meta.json" "${logdir}/harness.json"
  rm -f "${logdir}/harness-meta.json"

  if [[ -f "${logdir}/harness.json" ]]; then
    log ""
    log "Harness provenance (see harness.json):"
    python3 - "${logdir}/harness.json" <<'PY'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
for role, info in sorted((data.get("agents") or {}).items()):
    commit = info.get("commit") or {}
    boot = info.get("coordination_bootstrap") or {}
    parts = []
    if commit:
        parts.append(f"commit={commit.get('first_attempt')}")
        if commit.get("bypass_used"):
            parts.append("SKIP_HOOK bypass")
    if boot:
        parts.append(f"manual_sync={boot.get('manual_sync')}")
        parts.append(f"user_prompt_hook={boot.get('user_prompt_hook')}")
    if parts:
        print(f"  {role}: " + ", ".join(parts))
PY
  fi

  log ""
  log "Done: $trial_id"
  log "  artifacts: ${OUT_ROOT}/${trial_id}"
  log "  run logs:  $logdir"
}

# --- main ---

if [[ "$COLLECT_ONLY" -eq 1 ]]; then
  [[ -n "$MODE" ]] || MODE="$(resolve_mode_from_trial "$TRIAL_ID")"
  [[ -n "$TRIAL_ID" ]] || die "--trial required"
  [[ -n "$MODE" ]] || die "--mode required (or trial id must contain radar|no-radar)"
  populate_agent_roles
  prefix="$(derive_branch_prefix "$MODE" "$TRIAL_ID")"
  run_collect "$MODE" "$TRIAL_ID" "$prefix"
  exit 0
fi

[[ -n "$MODE" ]] || die "--mode required (radar|no-radar|both)"

if [[ -z "$MODEL" && -n "$CLAUDE" ]]; then
  MODEL="$("$CLAUDE" --version 2>/dev/null | head -1 || true)"
fi

case "$MODE" in
  both)
    [[ -n "$TRIAL_ID" ]] || die "--trial required for both (e.g. trial-002)"
    TRIAL_BASE="${TRIAL_ID%-radar}"
    TRIAL_BASE="${TRIAL_BASE%-no-radar}"
    run_arm "no-radar" "${TRIAL_BASE}-no-radar"
    run_arm "radar" "${TRIAL_BASE}-radar"
    ;;
  radar|no-radar)
  if [[ -z "$TRIAL_ID" ]]; then
    TRIAL_ID="trial-001-${MODE}"
  fi
  run_arm "$MODE" "$TRIAL_ID"
  ;;
  *)
    die "unknown --mode: $MODE"
    ;;
esac

log ""
log "Harness complete. No scoring — review ${OUT_ROOT} and fill judgments.json manually."
