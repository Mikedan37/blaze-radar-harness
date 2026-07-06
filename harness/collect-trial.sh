#!/usr/bin/env bash
# Collect frozen facts from a multi-agent coordination trial. No opinions.
#
# Usage:
#   collect-trial.sh \
#     --trial trial-001 \
#     --out ~/radar-benchmarks \
#     --repo ~/SeekerWebsite \
#     --group radar \
#     --agent feature:radar-feature \
#     --agent tests:radar-tests \
#     --agent audit:radar-audit \
#     --merge-order feature,tests,audit
#
# Optional:
#   --base main
#   --model "Claude Opus 4.6"
#   --duration-minutes 30
#   --prompt-pack seeker-overlap-v1
#   --test-cmd "npm test"
#   --transcripts ~/trial-transcripts
#   --blaze ~/.local/bin/blaze
#
# Output: $OUT/$TRIAL_ID/ — metadata, per-agent git facts, merge rehearsal, radar snapshot.
set -euo pipefail

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

TRIAL_ID=""
OUT_ROOT=""
REPO=""
BASE_BRANCH="main"
GROUP=""
MERGE_ORDER=""
TEST_CMD=""
TRANSCRIPTS_SRC=""
MODEL=""
DURATION_MINUTES=""
PROMPT_PACK=""
RADAR_CLI="${RADAR_CLI:-$(command -v blaze-radar-demo 2>/dev/null || command -v blaze 2>/dev/null || true)}"
RADAR_WORKSPACE=""
declare -a AGENT_ROLES=()
declare -a AGENT_BRANCHES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trial) TRIAL_ID="$2"; shift 2 ;;
    --out) OUT_ROOT="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE_BRANCH="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --merge-order) MERGE_ORDER="$2"; shift 2 ;;
    --test-cmd) TEST_CMD="$2"; shift 2 ;;
    --transcripts) TRANSCRIPTS_SRC="$2"; shift 2 ;;
    --radar-cli|--blaze) RADAR_CLI="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --duration-minutes) DURATION_MINUTES="$2"; shift 2 ;;
    --prompt-pack) PROMPT_PACK="$2"; shift 2 ;;
    --radar-workspace) RADAR_WORKSPACE="$2"; shift 2 ;;
    --agent)
      role="${2%%:*}"
      branch="${2#*:}"
      if [[ -z "$role" || -z "$branch" || "$role" == "$branch" ]]; then
        echo "error: --agent requires role:branch (got: $2)" >&2
        exit 1
      fi
      AGENT_ROLES+=("$role")
      AGENT_BRANCHES+=("$branch")
      shift 2
      ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$TRIAL_ID" ]] || { echo "error: --trial required" >&2; exit 1; }
[[ -n "$OUT_ROOT" ]] || { echo "error: --out required" >&2; exit 1; }
[[ -n "$REPO" ]] || { echo "error: --repo required" >&2; exit 1; }
[[ -n "$GROUP" ]] || { echo "error: --group required (radar|no-radar)" >&2; exit 1; }
[[ "$GROUP" == "radar" || "$GROUP" == "no-radar" ]] || { echo "error: --group must be radar or no-radar" >&2; exit 1; }
[[ ${#AGENT_ROLES[@]} -gt 0 ]] || { echo "error: at least one --agent role:branch" >&2; exit 1; }

REPO="$(cd "$REPO" && pwd)"
OUT_ROOT="$(mkdir -p "$OUT_ROOT" && cd "$OUT_ROOT" && pwd)"
TRIAL_DIR="$OUT_ROOT/$TRIAL_ID"

if [[ -d "$TRIAL_DIR" ]]; then
  echo "error: trial dir already exists: $TRIAL_DIR" >&2
  echo "  (refusing to overwrite frozen evidence)" >&2
  exit 1
fi

git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: not a git repo: $REPO" >&2
  exit 1
}

BASE_SHA="$(git -C "$REPO" rev-parse "$BASE_BRANCH" 2>/dev/null || git -C "$REPO" rev-parse "origin/$BASE_BRANCH")"
COLLECTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$TRIAL_DIR/agents" "$TRIAL_DIR/merge" "$TRIAL_DIR/radar" "$TRIAL_DIR/transcripts"

AGENTS_MANIFEST="$TRIAL_DIR/.agents.tsv"
: > "$AGENTS_MANIFEST"
for i in "${!AGENT_ROLES[@]}"; do
  printf '%s\t%s\n' "${AGENT_ROLES[$i]}" "${AGENT_BRANCHES[$i]}" >> "$AGENTS_MANIFEST"
done

# ── metadata.json ─────────────────────────────────────────────────────────────
export COLLECT_TRIAL_ID="$TRIAL_ID" COLLECT_GROUP="$GROUP" COLLECT_COLLECTED_AT="$COLLECTED_AT"
export COLLECT_REPO="$REPO" COLLECT_BASE_BRANCH="$BASE_BRANCH" COLLECT_BASE_SHA="$BASE_SHA"
export COLLECT_MERGE_ORDER="$MERGE_ORDER" COLLECT_TEST_CMD="$TEST_CMD"
export COLLECT_MODEL="$MODEL" COLLECT_DURATION_MINUTES="$DURATION_MINUTES" COLLECT_PROMPT_PACK="$PROMPT_PACK"

python3 - "$TRIAL_DIR" "$AGENTS_MANIFEST" <<'PY'
import json, sys

trial_dir, manifest_path = sys.argv[1], sys.argv[2]
agents = []
with open(manifest_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        role, branch = line.split("\t", 1)
        agents.append({"role": role, "branch": branch})

import os
merge_order_raw = os.environ.get("COLLECT_MERGE_ORDER", "")
merge_order = [m.strip() for m in merge_order_raw.split(",") if m.strip()] if merge_order_raw else [a["role"] for a in agents]

doc = {
    "trial_id": os.environ["COLLECT_TRIAL_ID"],
    "group": os.environ["COLLECT_GROUP"],
    "collected_at": os.environ["COLLECT_COLLECTED_AT"],
    "repo": os.environ["COLLECT_REPO"],
    "base_branch": os.environ["COLLECT_BASE_BRANCH"],
    "base_commit": os.environ["COLLECT_BASE_SHA"],
    "agents": agents,
    "merge_order": merge_order,
    "test_cmd": os.environ.get("COLLECT_TEST_CMD") or None,
    "model": os.environ.get("COLLECT_MODEL") or None,
    "duration_minutes": int(os.environ["COLLECT_DURATION_MINUTES"]) if os.environ.get("COLLECT_DURATION_MINUTES") else None,
    "prompt_pack": os.environ.get("COLLECT_PROMPT_PACK") or None,
}
with open(os.path.join(trial_dir, "metadata.json"), "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

echo "Collecting trial ${TRIAL_ID} (${GROUP}) → ${TRIAL_DIR}"

# ── per-agent git facts ───────────────────────────────────────────────────────
for i in "${!AGENT_ROLES[@]}"; do
  role="${AGENT_ROLES[$i]}"
  branch="${AGENT_BRANCHES[$i]}"
  agent_dir="$TRIAL_DIR/agents/$role"
  mkdir -p "$agent_dir"

  if ! git -C "$REPO" rev-parse --verify "$branch" >/dev/null 2>&1; then
    echo "error: branch not found in repo: $branch" >&2
    exit 1
  fi

  BRANCH_SHA="$(git -C "$REPO" rev-parse "$branch")"
  MERGE_BASE="$(git -C "$REPO" merge-base "$BASE_SHA" "$BRANCH_SHA")"

  git -C "$REPO" diff "$MERGE_BASE".."$branch" > "$agent_dir/diff.patch" || true
  git -C "$REPO" diff --name-only "$MERGE_BASE".."$branch" > "$agent_dir/files.txt" || true

  python3 - <<PY
import json, subprocess, os

repo = "${REPO}"
merge_base = "${MERGE_BASE}"
branch = "${BRANCH_SHA}"
role = "${role}"
branch_name = "${branch}"
out = "${agent_dir}/stats.json"

def run(*args):
    return subprocess.check_output(args, text=True, cwd=repo).strip()

numstat = run("git", "diff", "--numstat", f"{merge_base}..{branch}").splitlines()
files_changed = []
insertions = 0
deletions = 0
for line in numstat:
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    add, delete, path = parts[0], parts[1], parts[2]
    if add != "-":
        insertions += int(add)
    if delete != "-":
        deletions += int(delete)
    files_changed.append(path)

shortstat = run("git", "diff", "--shortstat", f"{merge_base}..{branch}")
commit_count = run("git", "rev-list", "--count", f"{merge_base}..{branch}")

doc = {
    "role": role,
    "branch": branch_name,
    "branch_sha": branch,
    "merge_base_sha": merge_base,
    "files_changed": files_changed,
    "file_count": len(files_changed),
    "insertions": insertions,
    "deletions": deletions,
    "commit_count": int(commit_count),
    "shortstat": shortstat,
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

  echo "  agent/$role: ${BRANCH_SHA:0:8} ($(wc -l < "$agent_dir/files.txt" | tr -d ' ') files)"
done

# ── cross-agent file overlap (fact) ───────────────────────────────────────────
python3 - "$TRIAL_DIR" "$AGENTS_MANIFEST" <<'PY'
import json, os, sys
from itertools import combinations

trial, manifest_path = sys.argv[1], sys.argv[2]
roles = []
with open(manifest_path) as f:
    for line in f:
        if line.strip():
            roles.append(line.split("\t", 1)[0])

INFRA_FILES = {"CLAUDE.md", "AGENTS.md", "GEMINI.md"}

def is_infrastructure(path: str) -> bool:
    normalized = path.strip("/")
    if normalized in INFRA_FILES:
        return True
    if normalized == ".blaze" or normalized.startswith(".blaze/"):
        return True
    if normalized == ".claude" or normalized.startswith(".claude/"):
        return True
    if normalized == ".cursor" or normalized.startswith(".cursor/"):
        return True
    return False

def filter_files(files):
    return {f for f in files if not is_infrastructure(f)}

files_by_role = {}
for role in roles:
    path = os.path.join(trial, "agents", role, "files.txt")
    with open(path) as f:
        files_by_role[role] = {line.strip() for line in f if line.strip()}

pairs = {}
pairs_scored = {}
all_files = {}
all_files_scored = {}
for role, files in files_by_role.items():
    scored = filter_files(files)
    for fp in files:
        all_files.setdefault(fp, []).append(role)
    for fp in scored:
        all_files_scored.setdefault(fp, []).append(role)

multi_file_agents = {fp: agents for fp, agents in all_files.items() if len(agents) > 1}
multi_file_agents_scored = {fp: agents for fp, agents in all_files_scored.items() if len(agents) > 1}

for a, b in combinations(roles, 2):
    overlap = sorted(files_by_role[a] & files_by_role[b])
    if overlap:
        pairs[f"{a}+{b}"] = overlap
    overlap_scored = sorted(filter_files(files_by_role[a] & files_by_role[b]))
    if overlap_scored:
        pairs_scored[f"{a}+{b}"] = overlap_scored

doc = {
    "infrastructure_ignored": sorted(INFRA_FILES) + [".blaze/", ".claude/", ".cursor/"],
    "pairwise_overlap": pairs,
    "pairwise_overlap_scored": pairs_scored,
    "files_touched_by_multiple_agents": multi_file_agents,
    "files_touched_by_multiple_agents_scored": multi_file_agents_scored,
}
with open(os.path.join(trial, "agents", "file_overlap.json"), "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

# ── merge rehearsal (facts only) ──────────────────────────────────────────────
MERGE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/collect-trial-merge.XXXXXX")"
trap 'rm -rf "$MERGE_TMP"' EXIT

git -C "$REPO" worktree add --detach "$MERGE_TMP" "$BASE_SHA" >/dev/null 2>&1

if [[ -n "$MERGE_ORDER" ]]; then
  IFS=',' read -ra MERGE_ROLES <<< "$MERGE_ORDER"
else
  MERGE_ROLES=("${AGENT_ROLES[@]}")
fi

declare -a MERGE_RESULTS=()

for role in "${MERGE_ROLES[@]}"; do
  role="$(echo "$role" | tr -d '[:space:]')"
  [[ -n "$role" ]] || continue

  branch=""
  for i in "${!AGENT_ROLES[@]}"; do
    if [[ "${AGENT_ROLES[$i]}" == "$role" ]]; then
      branch="${AGENT_BRANCHES[$i]}"
      break
    fi
  done
  [[ -n "$branch" ]] || { echo "warning: merge-order role not in agents: $role" >&2; continue; }

  {
    echo "=== merge $branch into rehearsal (base ${BASE_SHA:0:8}) ==="
    echo "started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } >> "$TRIAL_DIR/merge/merge.log"

  set +e
  OUT="$(git -C "$MERGE_TMP" merge --no-edit --no-ff "$branch" 2>&1)"
  CODE=$?
  set -e
  {
    echo "$OUT"
    echo "exit_code: $CODE"
    echo ""
  } >> "$TRIAL_DIR/merge/merge.log"

  CONFLICT_FILES=""
  if [[ $CODE -ne 0 ]]; then
    CONFLICT_FILES="$(git -C "$MERGE_TMP" diff --name-only --diff-filter=U 2>/dev/null || true)"
    git -C "$MERGE_TMP" merge --abort 2>/dev/null || git -C "$MERGE_TMP" reset --hard "$BASE_SHA" 2>/dev/null || true
    MERGE_RESULTS+=("{\"role\":\"$role\",\"branch\":\"$branch\",\"success\":false,\"exit_code\":$CODE}")
  else
    MERGE_RESULTS+=("{\"role\":\"$role\",\"branch\":\"$branch\",\"success\":true,\"exit_code\":0}")
    BASE_SHA="$(git -C "$MERGE_TMP" rev-parse HEAD)"
  fi
done

MERGE_RESULTS_FILE="$TRIAL_DIR/merge/sequential_merge.json"
if [[ ${#MERGE_RESULTS[@]} -gt 0 ]]; then
  printf '[%s]\n' "$(IFS=,; echo "${MERGE_RESULTS[*]}")" > "$MERGE_RESULTS_FILE"
else
  echo '[]' > "$MERGE_RESULTS_FILE"
fi

export COLLECT_CONFLICT_FILES="${CONFLICT_FILES:-}"
python3 - "$REPO" "$TRIAL_DIR" "$AGENTS_MANIFEST" "$BASE_BRANCH" "$MERGE_RESULTS_FILE" <<'PY'
import json, subprocess, os, sys

repo, trial_dir, manifest_path, base_branch, merge_results_path = sys.argv[1:6]
agents = []
with open(manifest_path) as f:
    for line in f:
        if line.strip():
            role, branch = line.rstrip("\n").split("\t", 1)
            agents.append((role, branch))

base = subprocess.check_output(["git", "-C", repo, "rev-parse", base_branch], text=True).strip()

with open(merge_results_path) as f:
    merge_results = json.load(f)

merge_tree = []
for role, branch in agents:
    branch_sha = subprocess.check_output(["git", "-C", repo, "rev-parse", branch], text=True).strip()
    mb = subprocess.check_output(["git", "-C", repo, "merge-base", base, branch_sha], text=True).strip()
    try:
        out = subprocess.check_output(
            ["git", "-C", repo, "merge-tree", mb, base, branch_sha],
            text=True,
            stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError as e:
        out = e.output or ""
    conflict_markers = out.count("<<<<<<<")
    merge_tree.append({
        "role": role,
        "branch": branch,
        "merge_base": mb,
        "conflict_marker_count": conflict_markers,
        "would_conflict": conflict_markers > 0,
    })

conflict_raw = os.environ.get("COLLECT_CONFLICT_FILES", "").strip()
doc = {
    "sequential_merge": merge_results,
    "merge_tree_preview": merge_tree,
    "conflict_files_last_attempt": conflict_raw.splitlines() if conflict_raw else [],
}
with open(os.path.join(trial_dir, "merge", "conflicts.json"), "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

# conflicts.json from merge-tree preview per branch (non-destructive extra fact)

git -C "$REPO" worktree remove --force "$MERGE_TMP" 2>/dev/null || rm -rf "$MERGE_TMP"
trap - EXIT

# ── optional CI fact ──────────────────────────────────────────────────────────
if [[ -n "$TEST_CMD" ]]; then
  set +e
  (cd "$REPO" && eval "$TEST_CMD") > "$TRIAL_DIR/tests.log" 2>&1
  TEST_CODE=$?
  set -e
  python3 - <<PY
import json
with open("${TRIAL_DIR}/tests.json", "w") as f:
    json.dump({"command": """${TEST_CMD}""", "exit_code": ${TEST_CODE}, "passed": ${TEST_CODE} == 0}, f, indent=2)
    f.write("\n")
PY
fi

# ── radar board snapshot (facts) ──────────────────────────────────────────────
if [[ "$GROUP" == "radar" && -n "$RADAR_CLI" ]]; then
  RADAR_WS="${RADAR_WORKSPACE:-$REPO}"
  RADAR_WS="$(cd "$RADAR_WS" && pwd)"
  set +e
  BOARD="$("$RADAR_CLI" radar active --json --workspace "$RADAR_WS" 2>/dev/null | sed -n '/^{/,$p')"
  set -e
  if [[ -n "$BOARD" ]]; then
    printf '%s\n' "$BOARD" > "$TRIAL_DIR/radar/board.json"
  else
    echo '{"registrations":[],"relatedAreas":[],"fileOverlaps":[]}' > "$TRIAL_DIR/radar/board.json"
  fi

  export COLLECT_RADAR_WORKSPACE="$RADAR_WS"
  python3 - "$TRIAL_DIR" <<'PY'
import hashlib, json, os, subprocess, sys

trial_dir = sys.argv[1]
workspace = os.environ["COLLECT_RADAR_WORKSPACE"]
home = os.path.expanduser("~")

def git_common_dir(path):
    try:
        common = subprocess.check_output(
            ["git", "-C", path, "rev-parse", "--git-common-dir"],
            text=True,
        ).strip()
    except Exception:
        return ""
    if common and not common.startswith("/"):
        toplevel = subprocess.check_output(
            ["git", "-C", path, "rev-parse", "--show-toplevel"],
            text=True,
        ).strip()
        common = os.path.normpath(os.path.join(toplevel, common))
    return os.path.realpath(common) if common else ""

def trial_scope(path):
    env = os.environ.get("BLAZE_RADAR_TRIAL_ID", "").strip()
    if env:
        return env
    parts = os.path.realpath(path).split("/")
    if "radar-trials" in parts:
        idx = parts.index("radar-trials")
        if idx + 1 < len(parts):
            return parts[idx + 1]
    return None

common = git_common_dir(workspace)
base = os.path.realpath(common if common else workspace)
trial = trial_scope(workspace)
board_key = f"{base}#trial={trial}" if trial else base
digest_bytes = hashlib.sha256(board_key.encode()).digest()
workspace_hash = "".join(f"{b:02x}" for b in digest_bytes[:3])
store = os.path.join(home, ".blaze", "radar", "workspaces", workspace_hash, "radar.blazedb")
doc = {
    "workspace_path": os.path.realpath(workspace),
    "board_key": board_key,
    "trial_scope": trial,
    "workspace_hash": workspace_hash,
    "store_path": store if os.path.exists(store) else None,
    "board_export": "radar/board.json",
}
with open(os.path.join(trial_dir, "radar", "store.json"), "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
else
  echo '{"skipped":true,"reason":"no-radar or blaze missing"}' > "$TRIAL_DIR/radar/board.json"
fi

# ── transcripts (optional copy) ───────────────────────────────────────────────
if [[ -n "$TRANSCRIPTS_SRC" && -d "$TRANSCRIPTS_SRC" ]]; then
  cp -R "$TRANSCRIPTS_SRC/." "$TRIAL_DIR/transcripts/"
  echo "  transcripts: copied from $TRANSCRIPTS_SRC"
fi

# Empty scaffold for human/judge phase — not filled by this script.
cat > "$TRIAL_DIR/judgments.template.json" <<'JSON'
{
  "purchased_agent_minutes": null,
  "contributions": [
    {
      "role": "feature",
      "kind": "finding|fix|test|other",
      "summary": "",
      "accepted": null,
      "evidence": "transcripts/... or agents/.../diff.patch"
    }
  ],
  "interference": { "L1": 0, "L2": 0, "L3": 0, "L4": 0 },
  "interference_evidence": [],
  "avoidance_events": [],
  "human_interventions": [
    {
      "minute": null,
      "agent": "feature|tests|audit",
      "reason": "e.g. asked product decision before editing"
    }
  ],
  "cleanup_minutes": null,
  "coordination_overhead_minutes": null,
  "notes": "Fill after inspecting frozen artifacts. Do not evaluate code quality here — use merge/CI/revert reality."
}
JSON

echo ""
echo "Done. Facts only:"
echo "  ${TRIAL_DIR}/metadata.json"
echo "  ${TRIAL_DIR}/agents/*/stats.json"
echo "  ${TRIAL_DIR}/agents/file_overlap.json"
echo "  ${TRIAL_DIR}/merge/conflicts.json"
echo "  ${TRIAL_DIR}/radar/board.json"
echo "  ${TRIAL_DIR}/judgments.template.json"
echo ""
echo "Next: score judgments (L1–L4, avoidance) from frozen artifacts — not in this script."
