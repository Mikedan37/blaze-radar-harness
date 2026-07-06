# Radar Coordination Trial 1

Freeze this document before running. Change only `prompt_pack` version if prompts change.

## Experiment

| Field | Value |
|-------|-------|
| **repo** | SeekerWebsite |
| **base_commit** | `1d6695f921c9302a7733cbea3cd89bddbe2a3b10` |
| **base_short** | `1d6695f` |
| **duration** | 30 minutes per agent (hard stop) |
| **agents** | 3 (feature, tests, audit) |
| **model** | Claude Opus 4.6 (record exact version in metadata) |
| **prompt_pack** | `seeker-overlap-v1` |
| **merge_order** | feature → tests → audit |

**Question:** Does Radar reduce wasted parallel work - not “better code,” but less duplicate effort and cleanup?

**Variable isolated:** coordination layer (board, tasks, notes, collision warnings).  
**Held constant:** repo, SHA, model, duration, roles, merge order, baseline parallel etiquette.

---

## Roles & boundaries (do not blur these)

What you are measuring:

```
Claude Code × 3 + Radar   vs   Claude Code × 3, no Radar
```

**Cursor / harness (lab assistant)** - safe:

- Create worktrees, verify SHA, start timers
- Run `collect-trial.sh`, merge rehearsals, package transcripts
- Generate facts JSON; help fill `judgments.json` from **frozen** evidence after the run

**Cursor / harness** - not safe during the run:

- Tell Claude agents what others are doing
- Summarize progress mid-run, route tasks, decide who edits what

That is Radar's job in the Radar arm - and nobody's job in the no-Radar arm.  
If Cursor orchestrates agents, you measure `Claude + Cursor coordination + Radar` vs `Claude + Cursor coordination`. Three steering wheels. Haunted graph.

**Clean flow:**

1. Harness sets up worktrees (`setup-trial-1.sh`)
2. **You** open three Claude Code windows per arm, paste frozen prompts
3. Agents run 30 minutes (manual launch is intentional for Trial 1)
4. Harness collects facts (`collect-trial.sh`)

Product boundary mirrored in the benchmark:

| Layer | Role |
|-------|------|
| Radar | Coordinates (arm B only) |
| Claude agents | Work |
| Harness + human | Observe, measure, judge |

After Trial 1 proves signal, consider `blaze bench run seeker-overlap-v1`. Not before.

---

## Arms

| Arm | Trial ID | Radar |
|-----|----------|-------|
| A | `trial-001-no-radar` | `BLAZE_RADAR_HOOKS=0`, no board reads |
| B | `trial-001-radar` | `blaze radar install`, hooks on, daemon running |

Both arms get the **shared preamble** (parallel etiquette).  
Only arm B gets the **Radar addendum** (board, tasks, notes, collisions).

Trial 1 order: either arm first is fine. Later trials: randomize arm order to avoid human learning effects.

---

## Setup (run once per arm)

Harness script (worktrees + SHA only - does not launch agents):

```bash
AgentCLI/scripts/setup-trial-1.sh --repo ~/SeekerWebsite --parent ~/radar-trials
```

Or manual steps below.

### 0. Pin base

```bash
cd ~/SeekerWebsite
git fetch origin 2>/dev/null || true
git checkout 1d6695f
git tag -f radar-trial-1-base 1d6695f   # optional anchor
```

### 1. Worktrees (separate dirs per arm)

**No-Radar arm:**

```bash
PARENT=~/radar-trials/trial-001-no-radar
mkdir -p "$PARENT"
cd ~/SeekerWebsite

git worktree add -b trial/nr-feature  "$PARENT/feature" radar-trial-1-base
git worktree add -b trial/nr-tests    "$PARENT/tests"   radar-trial-1-base
git worktree add -b trial/nr-audit    "$PARENT/audit"   radar-trial-1-base
```

**Radar arm:**

```bash
PARENT=~/radar-trials/trial-001-radar
mkdir -p "$PARENT"
cd ~/SeekerWebsite

git worktree add -b trial/r-feature  "$PARENT/feature" radar-trial-1-base
git worktree add -b trial/r-tests    "$PARENT/tests"   radar-trial-1-base
git worktree add -b trial/r-audit    "$PARENT/audit"   radar-trial-1-base
```

Each worktree is one Claude window. Do not share a checkout between agents.

### 2. Radar arm only

```bash
# once on machine
cd ~/Developer/ProjectBlaze/AgentCLI && make install
blaze daemon start

# once per radar worktree (or install from main repo - board is shared per git root)
cd ~/radar-trials/trial-001-radar/feature
blaze radar install
```

No-Radar arm: do **not** run `blaze radar install`. Set in each Claude session:

```bash
export BLAZE_RADAR_HOOKS=0
```

### 3. Branch names for collector

| Role | No-Radar branch | Radar branch |
|------|-----------------|--------------|
| feature | `trial/nr-feature` | `trial/r-feature` |
| tests | `trial/nr-tests` | `trial/r-tests` |
| audit | `trial/nr-audit` | `trial/r-audit` |

---

## Prompt pack: `seeker-overlap-v1`

Copy verbatim into each Claude window. Replace `{ROLE}` with the role block below.

### Shared preamble (BOTH arms)

```
You are one of three agents working in parallel on SeekerWebsite at commit 1d6695f.

You are working alongside other agents with separate roles. Stay focused on your role.
Avoid unnecessary changes outside your scope. Do not rewrite areas another agent likely owns.

Hard stop: 30 minutes. Prefer small, mergeable contributions over large refactors.

When you learn something important, write it down clearly (one or two sentences).
When you finish or stop, summarize what you did and what you did NOT touch.
```

### Role: feature (window 1 - `feature` worktree)

```
{SHARED PREAMBLE}

Your role: FEATURE - improve Seeker match/results explanation UX.

Focus on user-facing copy, match card presentation, and results explanation clarity.
You may read tests for context but do not own the test suite cleanup.

If you are unsure about a product tradeoff, implement the smallest reversible change and
document the tradeoff - do not block the whole session waiting for approval unless the
change is irreversible (pricing, auth, data deletion).
```

### Role: tests (window 2 - `tests` worktree)

```
{SHARED PREAMBLE}

Your role: QUALITY - fix broken tests and test infrastructure around the current HEAD.

HEAD (1d6695f) has known red tests. Diagnose root causes before adding dependencies.
This repo may not use jsdom or @testing-library - check conventions before installing packages.

Do not refactor product UX unless required for tests. Stay in test files and minimal fixes.
```

### Role: audit (window 3 - `audit` worktree)

```
{SHARED PREAMBLE}

Your role: ARCHITECTURE - read-only reliability/consistency audit.

Look for cross-cutting risks: API route consistency, timeout patterns, internal route guards,
error handling drift. Report findings; do not implement broad fixes unless trivial and safe.

Defer test-suite repair and UX changes to the other agents unless you find a critical security issue.
```

### Radar addendum (arm B only - append to each role prompt)

```
Radar is enabled. Hooks show the board automatically. Your first prompt declares your task.

Before editing, read the board output. Note other agents' declared tasks and notes.
If another agent owns a surface, say so explicitly and work elsewhere.

Post findings: blaze radar note "AREA: ... - ..."
Change focus: blaze radar sync --task "..."
When done: blaze radar done
```

### No-Radar addendum (arm A only - append to each role prompt)

```
Radar is disabled for this trial. Do not read ~/.blaze/radar or run blaze radar commands.
Coordinate only through git and your own judgment.
```

---

## During trial

1. Start three Claude Code sessions (one per worktree).
2. Paste the full prompt for that role (preamble + role + arm addendum).
3. Run 30 minutes. Stop all agents at the same wall clock if possible.
4. Commit on each branch (even WIP - facts need git artifacts):

```bash
# in each worktree
git add -A
git commit -m "trial-001: {role} session end" || true
```

5. Log **human interventions** as they happen (minute, agent, reason).

---

## Collect facts (no opinions)

```bash
COLLECT=~/Developer/ProjectBlaze/AgentCLI/scripts/collect-trial.sh
OUT=~/radar-benchmarks

# No-Radar
"$COLLECT" \
  --trial trial-001-no-radar \
  --out "$OUT" \
  --repo ~/SeekerWebsite \
  --base 1d6695f \
  --group no-radar \
  --model "Claude Opus 4.6" \
  --duration-minutes 30 \
  --prompt-pack seeker-overlap-v1 \
  --agent feature:trial/nr-feature \
  --agent tests:trial/nr-tests \
  --agent audit:trial/nr-audit \
  --merge-order feature,tests,audit

# Radar
"$COLLECT" \
  --trial trial-001-radar \
  --out "$OUT" \
  --repo ~/SeekerWebsite \
  --base 1d6695f \
  --group radar \
  --model "Claude Opus 4.6" \
  --duration-minutes 30 \
  --prompt-pack seeker-overlap-v1 \
  --agent feature:trial/r-feature \
  --agent tests:trial/r-tests \
  --agent audit:trial/r-audit \
  --merge-order feature,tests,audit
```

Copy `judgments.template.json` → `judgments.json` in each trial dir and fill manually.

---

## Ugly ledger (fill after both arms)

Do not calculate a fancy score first. If these two blocks read obviously different, Radar won.

### NO RADAR (`trial-001-no-radar`)

```
Purchased:     90 agent-minutes (3 × 30)

Accepted:      ___  (findings/fixes/tests you kept)
Duplicate:     ___  (same finding or fix from 2+ agents)
Thrown away:   ___  (proposed but rejected / reverted)
Cleanup:       ___ min (merge conflicts, manual repair)
Human interrupts: ___  (you became the scheduler)

Notes:
-
```

### RADAR (`trial-001-radar`)

```
Purchased:     90 agent-minutes

Accepted:      ___
Avoided:       ___  (agents explicitly routed around each other - quote evidence)
Thrown away:   ___
Cleanup:       ___ min
Human interrupts: ___

Notes:
-
```

**Hunting for this sentence in Radar arm transcripts:**

> "I see agent-X working on Y, so I'll avoid / defer / not touch that."

No-Radar arm cannot produce `Avoided` with board evidence.

---

## Judgments schema (`judgments.json`)

See `judgments.template.json` in each trial dir. Key fields:

- `contributions[]` - accepted units (finding / fix / test), not LOC
- `interference` - L1-L4 counts with quoted evidence
- `avoidance_events[]` - Radar arm only
- `human_interventions[]` - hidden scheduler cost
- `cleanup_minutes`, `coordination_overhead_minutes`

### Interference rubric (weighted)

| Level | Event | Weight |
|-------|-------|--------|
| L0 | same file read | log only, 0 |
| L1 | duplicate investigation (same root cause) | -1 |
| L2 | same finding independently discovered | -3 |
| L3 | overlapping edits, one discarded | -5 |
| L4 | merge conflict / human repair | -10 |

File overlap in `agents/file_overlap.json` is **fact only** - not a penalty by itself.

---

## Success criteria (Trial 1)

Not “Radar produced better code.”

| Signal | No-Radar | Radar |
|--------|----------|-------|
| Duplicate findings (L2+) | ? | lower |
| Avoidance events | 0 | 2+ with quotes |
| Cleanup minutes | ? | lower |
| Human interventions | ? | lower (optional) |
| Ugly ledger | worse | readable win |

If delta is obvious → automate scoring.  
If you need a seven-factor equation → effect may be too weak to ship yet.

---

## Cleanup after trial

```bash
cd ~/SeekerWebsite
git worktree remove ~/radar-trials/trial-001-no-radar/feature
git worktree remove ~/radar-trials/trial-001-no-radar/tests
git worktree remove ~/radar-trials/trial-001-no-radar/audit
# repeat for trial-001-radar
# branches can stay for forensics or delete when done
```

---

## Changelog

| prompt_pack | Change |
|-------------|--------|
| `seeker-overlap-v1` | Initial Trial 1 - SeekerWebsite @ 1d6695f, shared preamble, isolated Radar addendum |
