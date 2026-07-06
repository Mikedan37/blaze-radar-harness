# Blaze Radar Harness

**Applying control theory to parallel AI agent systems:** measuring oscillation, damping, and throughput under shared state feedback.

A measurement harness for parallel AI coding agents.

---

## The problem

Modern agent systems don't fail only because agents make mistakes. They fail because independent workers repeatedly traverse the same state space:

- rediscovering known facts
- recreating abandoned fixes
- colliding without awareness

**Radar Harness** measures whether shared state feedback reduces repeated trajectories while preserving throughput.

The goal is not zero mistakes. **The goal is damping.**

> Proximity in workspace ≠ collision. What matters is velocity through explored space.

**Theory:** [docs/RadarDynamics.md](docs/RadarDynamics.md)

---

## Stack positioning

```
blaze-radar          →  state awareness layer (sensor + board)
blaze-radar-harness  →  control theory + measurement framework (oscilloscope)
```

| | blaze-radar | blaze-radar-harness |
|--|-------------|---------------------|
| Role | Controller / sensor implementation | Instrumentation for system behavior |
| Analogy | Feedback path | Scope on the waveform |
| Scope | One coordination system | Any parallel agent setup you wire in |

This harness is not a leaderboard. It is an **experimental framework for measuring multi-agent dynamics** — usable against Radar today, adaptable to other coordination layers tomorrow.

---

## Control theory → metrics

| Domain | What it measures | Scorer signals |
|--------|------------------|----------------|
| **Oscillation** | Repeated traversal of explored state | `duplicate_investigations`, repeated failed paths, abandoned branches |
| **Energy** | Useful work per unit time | agent-minutes, commits, useful output |
| **Damping** | Feedback converting oscillation into progress | prior context utilization, compounding events, continuations |

```
coordination_score = (useful_outputs + leverage − duplicate_work − merge_cost) / agent_minutes
```

**Good damping:** same energy, less heat loss — throughput held, repeated trajectories down.  
**Bad damping (over-damped):** fewer commits, zero duplicates — you invented fear.

Territory spread is **diagnostic only**. Five agents on one auth bug with complementary vectors is a feature, not a failure.

---

## What ships here

| Piece | Purpose |
|-------|---------|
| `harness/` | Run parallel agents in worktrees — feedback arm vs control arm |
| `lib/score_trial_v2.py` | Oscillation / energy / damping metrics from frozen artifacts |
| `prompts/` | Frozen agent instructions (overlap + swarm packs) |
| `protocol/` | Experiment contract — constants, variables, harness boundaries |

Typical experiment:

```
Claude Code × N + shared state feedback   vs   Claude Code × N, isolated
```

---

## Prerequisites

1. **[blaze-radar](https://github.com/Mikedan37/blaze-radar)** — demo CLI + daemon:

   ```bash
   git clone https://github.com/Mikedan37/blaze-radar.git
   cd blaze-radar && swift build -c release
   export PATH="$PWD/.build/release:$PATH"
   blaze-radar-demo-daemon &
   ```

2. **Claude Code** (`claude` on PATH)
3. **Target git repo** — any repo (SeekerWebsite was used in Trial 1)
4. **Python 3** — for the scorer

---

## Quick start

```bash
git clone https://github.com/Mikedan37/blaze-radar-harness.git
cd blaze-radar-harness

# Feedback arm (Radar)
./harness/run-trial.sh --mode radar --trial trial-002-radar --repo ~/YourRepo

# Control arm (no shared state)
./harness/run-trial.sh --mode no-radar --trial trial-002-no-radar --repo ~/YourRepo

# Measure oscillation, energy, damping
./harness/score-trial.sh --trial trial-002 \
  --report ~/radar-harness/trial-002/trial-report.md
```

Defaults:

- Worktrees: `~/radar-trials/`
- Frozen artifacts: `~/radar-harness/`
- Radar CLI: `blaze-radar-demo` (`--radar-cli` to override)
- Host: `demo` (`--host projectblaze` for private ProjectBlaze installs)

---

## Layout

```
blaze-radar-harness/
├── README.md
├── docs/RadarDynamics.md       control theory framing
├── protocol/trial-1-protocol.md
├── harness/
│   ├── run-trial.sh
│   ├── collect-trial.sh
│   ├── score-trial.sh
│   └── setup-trial-1.sh
├── lib/score_trial_v2.py
└── prompts/
    ├── seeker-overlap-v1/
    └── seeker-swarm-v1/
```

---

## Harness boundary

During a trial, the orchestrator **must not** tell agents what others are doing. That is the feedback layer's job in the treatment arm — and nobody's job in the control arm.

| Safe | Not safe |
|------|----------|
| Worktrees, timers, collect, score | Mid-run orchestration |
| Post-hoc analysis | Progress summaries to agents |
| Frozen prompts | Task routing between agents |

See [protocol/trial-1-protocol.md](protocol/trial-1-protocol.md).

---

## Related

| Repo | Role |
|------|------|
| [blaze-radar](https://github.com/Mikedan37/blaze-radar) | State awareness layer (public) |
| **blaze-radar-harness** | Measurement framework (public) |
| ProjectBlaze / AgentCLI | Private production host (optional) |

---

## License

MIT. See [LICENSE](LICENSE).
