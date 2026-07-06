# blaze-radar-benchmark

**Does Radar reduce repeated trajectories without reducing throughput?**

This repository is the public benchmark for [Blaze Radar](https://github.com/Mikedan37/blaze-radar) — not the Radar engine itself, and not a private host CLI. It is a frozen experiment kit: harness scripts, scorer, prompt packs, and evaluation criteria.

> AI coding doesn't need a boss. It needs **state awareness**.
>
> Proximity in workspace ≠ collision. What matters is velocity through explored space.

**Design doc:** [docs/RadarDynamics.md](docs/RadarDynamics.md)

---

## What this repo is

| Piece | Purpose |
|-------|---------|
| **Harness** (`harness/`) | Run parallel Claude Code agents in git worktrees — Radar arm vs no-Radar arm |
| **Collector** | Freeze git facts, merge rehearsal, board snapshot — no opinions |
| **Scorer v2** (`lib/score_trial_v2.py`) | Measure duplicate work, compounding, throughput, merge cost |
| **Prompt packs** (`prompts/`) | Frozen agent instructions (overlap + swarm scenarios) |
| **Protocol** (`protocol/`) | Experiment contract — what is held constant, what varies |

This repo answers one question:

```
Claude Code × N + Radar   vs   Claude Code × N, no Radar
```

**Good win:** same agent-minutes, fewer duplicate investigations, higher prior-context reuse.  
**Bad win:** fewer commits, zero duplicates — you invented fear (over-damping).

---

## Prerequisites

1. **[blaze-radar](https://github.com/Mikedan37/blaze-radar)** — build and install the demo CLI + daemon:

   ```bash
   git clone https://github.com/Mikedan37/blaze-radar.git
   cd blaze-radar && swift build -c release
   export PATH="$PWD/.build/release:$PATH"
   blaze-radar-demo-daemon &
   ```

2. **Claude Code** (`claude` on PATH)

3. **Target git repo** — any repo you want to benchmark (SeekerWebsite was used in Trial 1)

4. **Python 3** — for the scorer

---

## Quick start

```bash
git clone https://github.com/Mikedan37/blaze-radar-benchmark.git
cd blaze-radar-benchmark

# Radar arm
./harness/run-trial.sh --mode radar --trial trial-002-radar --repo ~/YourRepo

# No-Radar arm (same repo, same SHA, same duration)
./harness/run-trial.sh --mode no-radar --trial trial-002-no-radar --repo ~/YourRepo

# Score both
./harness/score-trial.sh --trial trial-002 \
  --report ~/radar-benchmarks/trial-002/benchmark-report.md
```

Defaults:

- Worktrees: `~/radar-trials/`
- Frozen facts: `~/radar-benchmarks/`
- Radar CLI: `blaze-radar-demo` (override with `--radar-cli`)
- Host: `demo` (override with `--host projectblaze` for private ProjectBlaze installs)

---

## Repository layout

```
blaze-radar-benchmark/
├── README.md                 ← you are here
├── docs/
│   └── RadarDynamics.md      ← control theory framing + pass/fail criteria
├── protocol/
│   └── trial-1-protocol.md   ← frozen experiment contract
├── harness/
│   ├── run-trial.sh          ← spawn agents, timeout, collect
│   ├── collect-trial.sh      ← freeze facts (no scoring)
│   ├── score-trial.sh        ← scorer wrapper
│   └── setup-trial-1.sh      ← worktree-only setup
├── lib/
│   └── score_trial_v2.py     ← coordination score + waste breakdown
└── prompts/
    ├── seeker-overlap-v1/    ← 3 agents, role-split
    └── seeker-swarm-v1/      ← 8 agents, shared mission
```

---

## Scorer signals

```
coordination_score = (useful_outputs + leverage − duplicate_work − merge_cost) / agent_minutes
```

| Signal | Meaning |
|--------|---------|
| `duplicate_investigations` | Same topic, multiple agents, no compounding — **penalized** |
| `compounding_events` | Agent reused board findings — **credited** (Radar arm) |
| `complementary_changes` | Agents on same files with different vectors — **credited** |
| `territory_spread` | Areas touched per agent — **diagnostic only** |

Clustering five agents on one auth bug with complementary roles is a **feature**, not a coordination failure.

---

## Harness boundary (critical)

During a trial, the harness **must not** tell agents what others are doing.

| Safe | Not safe |
|------|----------|
| Worktrees, timers, collect, score | Mid-run orchestration |
| Post-hoc analysis | Progress summaries to agents |
| Frozen prompts | Task routing between agents |

If the orchestrator coordinates agents, you measure `Claude + orchestrator + Radar` vs `Claude + orchestrator`. Three steering wheels.

See [protocol/trial-1-protocol.md](protocol/trial-1-protocol.md).

---

## Related repos

| Repo | Role |
|------|------|
| [blaze-radar](https://github.com/Mikedan37/blaze-radar) | RadarCore + demo CLI (public) |
| **blaze-radar-benchmark** | This repo — evaluation harness (public) |
| AgentCLI / ProjectBlaze | Private production host (not required) |

---

## License

MIT. See [LICENSE](LICENSE).
