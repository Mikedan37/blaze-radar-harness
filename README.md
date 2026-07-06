# Blaze Radar Harness

**Does a shared awareness board reduce wasted work when many coding agents run in parallel?**

This repo is an A/B measurement harness. You run the same agent swarm twice (with and without [Blaze Radar](https://github.com/Mikedan37/blaze-radar)), collect artifacts, and score the run. It is a lab instrument, not a leaderboard and not the Radar product itself.

---

## What you get

| Piece | What it does |
|-------|----------------|
| `harness/run-trial.sh` | Spins up parallel agents in git worktrees (Radar arm vs no-Radar arm) |
| `harness/collect-trial.sh` | Freezes logs, commits, board notes after a run |
| `harness/score-trial.sh` | Computes waste rate, duplicate topics, commits, and related metrics |
| `prompts/` | Frozen prompt packs used in published trials |
| `protocol/` | Rules so the harness does not cheat (no mid-run orchestration) |
| `docs/` | Results, charts, and optional theory write-ups |

---

## The problem this measures

Running several agents on one codebase often wastes effort:

- Agent A spends 20 minutes tracing an upload bug.
- Agent B starts the same trace from scratch because A's notes never left A's session.
- Both commit partial fixes. A human merges later.

That is duplicate **investigation**, not necessarily a git conflict. Proximity in the repo does not equal collision. What hurts is retracing ground another agent already explored.

**Blaze Radar** gives agents a shared board (tasks, notes, sync). **This harness** asks: when the board is on, do agents waste less time on the same questions while still shipping commits?

---

## How a trial works

```
  Your repo (e.g. SeekerWebsite @ fixed SHA)
           |
           +------------------+------------------+
           |                                     |
    Radar arm (treatment)              No-Radar arm (control)
    N agents + shared board            N agents, isolated sessions
    blaze radar sync / note            no shared state
           |                                     |
           +------------------+------------------+
                              |
                    collect-trial.sh
                    (logs, git, board JSON)
                              |
                    score_trial_v2.py
                              |
              waste rate, duplicate topics,
              commits, convergence_score, ...
```

**Important:** The harness sets up worktrees and timers. It does **not** tell agents what others are doing mid-run. In the Radar arm, the board is the only shared feedback. In the control arm, there is none. That keeps the comparison honest. See [protocol/trial-1-protocol.md](protocol/trial-1-protocol.md).

**Clean A/B:** Use isolated git clones per arm (`--isolated-arms` in `run-trial.sh`) so one arm cannot see the other's branches. Trial 004 failed this check; Trial 005 did not.

---

## What the scorer reports (plain language)

| Metric | Meaning |
|--------|---------|
| **Waste rate** | Share of agent-minutes that look redundant (re-tracing, abandoned paths) |
| **Duplicate topics** | How many investigation themes show up in more than one agent |
| **Commits** | Did both arms still ship? (We want less waste **without** killing throughput) |
| **Prior context use** | Radar arm only: did agents reference board notes or peer work? |
| **Convergence score** | Useful output minus duplicate cost, divided by total agent-minutes |

Full field list and formulas: [docs/CONTROL_MODEL.md](docs/CONTROL_MODEL.md).  
Frozen trial numbers and charts: [docs/EMPIRICAL_RESULTS.md](docs/EMPIRICAL_RESULTS.md).

---

## Best result so far (Trial 005)

8 agents, isolated arms, SeekerWebsite @ `1d6695f`. Same commit count (8/8). Radar arm wasted less time on duplicate investigations.

| Metric | No Radar | With Radar |
|--------|----------|------------|
| Waste rate | 77.5% | 42.5% |
| Duplicate topics | 7 | 5 |
| Commits | 8/8 | 8/8 |

![Trial 005 energy vs heat](docs/charts/trial-005-energy-heat.svg)

![Trial 005 dashboard](docs/charts/trial-005-dashboard.svg)

Example behavior ([full interpretation](docs/trial-data/trial-005-interpretation.md)): one agent read the board, saw upload work was already covered, and pivoted instead of redoing it.

This is one clean trial, not a final proof. More repeats (006+) are for variance.

---

## Quick start

**Prerequisites:** [blaze-radar](https://github.com/Mikedan37/blaze-radar) demo CLI + daemon, Claude Code (`claude`), Python 3, a target git repo.

```bash
git clone https://github.com/Mikedan37/blaze-radar-harness.git
cd blaze-radar-harness

# Build Radar demo (once)
git clone https://github.com/Mikedan37/blaze-radar.git ../blaze-radar
cd ../blaze-radar && swift build -c release
export PATH="$PWD/.build/release:$PATH"
blaze-radar-demo-daemon &

cd ../blaze-radar-harness

# Treatment arm
./harness/run-trial.sh --mode radar --trial mytrial-radar --repo ~/YourRepo

# Control arm
./harness/run-trial.sh --mode no-radar --trial mytrial-no-radar --repo ~/YourRepo

# Score (pair by trial id prefix)
./harness/score-trial.sh --trial mytrial --report ~/radar-harness/mytrial/trial-report.md
```

Defaults: worktrees under `~/radar-trials/`, artifacts under `~/radar-harness/`, CLI name `blaze-radar-demo`.

Plot frozen data without running agents:

```bash
python3 lib/plot_trial.py docs/trial-data/trial-005-score-v2.json
python3 lib/generate_trial_charts.py docs/trial-data/trial-*-score-v2.json
```

---

## How this repo relates to Blaze Radar

```
blaze-radar          shared board + daemon (the sensor)
blaze-radar-harness  run trials and score outcomes (the oscilloscope)
```

| | blaze-radar | blaze-radar-harness |
|--|-------------|---------------------|
| Role | Product: agents publish and read shared state | Experiment kit: A/B runs and metrics |
| You run it when | Agents need awareness during real work | You want evidence about whether awareness helps |

Radar does not assign tasks, block edits, or merge branches. It only surfaces state. Merging compatible agent branches is still a separate (human) step. The harness measures the feedback loop, not merge automation.

Optional control-theory framing (energy, heat, oscillation as analogies): [docs/CONTROL_MODEL.md](docs/CONTROL_MODEL.md).

---

## Repo layout

```
blaze-radar-harness/
├── harness/          run, collect, score scripts
├── lib/              score_trial_v2.py, chart generators
├── prompts/          seeker-overlap-v1, seeker-swarm-v1
├── protocol/         trial contract
└── docs/
    ├── EMPIRICAL_RESULTS.md
    ├── CONTROL_MODEL.md
    ├── trial-data/   frozen JSON + interpretations
    └── charts/       SVG plots for README
```

---

## What we claim vs what we measure

| Statement | Status |
|-----------|--------|
| Harness runs isolated A/B arms | Yes, when configured with isolated clones |
| Radar writes tasks and notes to a shared board | Yes (blaze-radar behavior) |
| Duplicate detection | Heuristic from logs and board text |
| "Radar caused X" | Needs clean trials and repeats; scorer flags contamination |
| Measured physics damping ratio | No. Heat/energy language is analogy only |

---

## Related

| Repo | Role |
|------|------|
| [blaze-radar](https://github.com/Mikedan37/blaze-radar) | Shared awareness layer (public) |
| **blaze-radar-harness** | Measurement framework (this repo) |
| ProjectBlaze / AgentCLI | Private production host (optional) |

---

## License

MIT. See [LICENSE](LICENSE).
