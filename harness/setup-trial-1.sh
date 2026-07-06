#!/usr/bin/env bash
# Harness-only setup for Radar Trial 1. Creates worktrees and verifies SHA.
# Does NOT launch, prompt, or orchestrate Claude agents.
#
# Usage:
#   setup-trial-1.sh [--repo ~/SeekerWebsite] [--parent ~/radar-trials]
#
# See: radar-trial-1-protocol.md
set -euo pipefail

REPO="${HOME}/SeekerWebsite"
PARENT="${HOME}/radar-trials"
BASE_SHA="1d6695f921c9302a7733cbea3cd89bddbe2a3b10"
BASE_SHORT="1d6695f"
TAG="radar-trial-1-base"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --parent) PARENT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

REPO="$(cd "$REPO" && pwd)"
mkdir -p "$PARENT"

echo "Radar Trial 1 — harness setup (no agents)"
echo "  repo:   $REPO"
echo "  parent: $PARENT"
echo "  base:   $BASE_SHORT"
echo ""

cd "$REPO"
git fetch origin 2>/dev/null || true

if ! git rev-parse --verify "$BASE_SHA" >/dev/null 2>&1; then
  echo "error: base commit not found: $BASE_SHA" >&2
  exit 1
fi

git tag -f "$TAG" "$BASE_SHA" 2>/dev/null || true
echo "✓ base commit verified: $BASE_SHA"
echo "✓ tag: $TAG"
echo ""

create_arm() {
  local arm="$1"   # no-radar | radar
  local prefix="$2" # nr | r
  local trial_id="trial-001-$arm"
  local arm_dir="$PARENT/$trial_id"

  mkdir -p "$arm_dir"

  for role in feature tests audit; do
    local branch="trial/${prefix}-${role}"
    local wt="$arm_dir/$role"
    if [[ -d "$wt" ]]; then
      echo "  skip $wt (exists)"
      continue
    fi
    git worktree add -b "$branch" "$wt" "$TAG"
    echo "  ✓ $wt → $branch"
  done

  if [[ "$arm" == "radar" ]]; then
    local cli="${RADAR_CLI:-$(command -v blaze-radar-demo 2>/dev/null || command -v blaze 2>/dev/null || true)}"
    if [[ -n "$cli" ]] && [[ "${RADAR_HOST:-demo}" == "projectblaze" ]]; then
      (cd "$arm_dir/feature" && "$cli" radar install >/dev/null 2>&1) && \
        echo "  ✓ radar install (feature worktree)" || \
        echo "  ⚠ radar install failed — run manually from $arm_dir/feature"
    else
      echo "  ✓ demo host — skip radar install (prompt-driven sync)"
    fi
  fi

  echo ""
  echo "  $trial_id ready:"
  echo "    feature → $arm_dir/feature"
  echo "    tests   → $arm_dir/tests"
  echo "    audit   → $arm_dir/audit"
  echo ""
}

echo "=== trial-001-no-radar ==="
create_arm "no-radar" "nr"

echo "=== trial-001-radar ==="
create_arm "radar" "r"

echo "Done. For automated runs use run-trial.sh (harness only):"
echo "  AgentCLI/scripts/run-trial.sh --mode both --trial trial-002 --repo $REPO"
echo ""
echo "Manual fallback (Trial 1):"
echo "  1. Open 3 Claude Code windows per arm"
echo "  2. Paste prompts from radar-trial-1-protocol.md (seeker-overlap-v1)"
echo "  3. No-radar arm: export BLAZE_RADAR_HOOKS=0 in each session"
echo "  4. Run 30 min, commit on each branch"
echo "  5. collect-trial.sh for each arm"
