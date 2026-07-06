# Blaze Radar Harness

## In 30 seconds

1. **Question:** If parallel coding agents share a notes board, do they stop redoing each other's investigations?
2. **Method:** Run the same swarm twice - once **with** [Blaze Radar](https://github.com/Mikedan37/blaze-radar), once **without** - then score both runs.
3. **This repo:** Scripts to run that experiment and math to compare the results. Not Radar itself. Not a leaderboard.

---

## What we saw (Trial 005)

8 agents on the same codebase, 45 minutes, isolated so neither run could peek at the other's git branches.

**Bottom line:** Both runs landed **8 commits**. The Radar run wasted **much less time** on duplicate investigations.

| | No Radar | With Radar |
|--|----------|------------|
| Waste rate | 77.5% | 42.5% |
| Duplicate topics | 7 | 5 |
| Commits | 8/8 | 8/8 |

**How to read the charts:** Blue/green = useful agent-minutes. Red/orange = wasted (re-tracing, abandoned paths). You want the red slice to shrink **without** losing commits.

![Trial 005: same total effort, less waste on Radar arm](docs/charts/trial-005-energy-heat.svg)

![Trial 005: duplicate topics and context reuse](docs/charts/trial-005-dashboard.svg)

**Concrete example:** Agent 06 opened the board, saw upload work was already in progress, and switched tasks instead of redoing the same trace ([details](docs/trial-data/trial-005-interpretation.md)).

One trial is a signal, not proof. More repeats live in [docs/EMPIRICAL_RESULTS.md](docs/EMPIRICAL_RESULTS.md).

---

## The problem (why bother)

```
Without a board:
  Agent A investigates upload bug for 20 min, writes notes in its own session
  Agent B starts the same investigation from zero
  Both commit. A human merges later.

With Radar:
  Agent A posts "upload: traced to X, fix in progress" on the shared board
  Agent B reads that and works on something else (or extends A's fix)
```

That is wasted **investigation**, not necessarily a git merge conflict. This harness measures whether the board actually changes agent behavior.

---

## How a trial works

```
  Your repo (fixed git SHA, same code both times)
           |
           +------------------+------------------+
           |                                     |
    WITH Radar board                   WITHOUT Radar board
    (agents sync + note)               (agents fully isolated)
           |                                     |
           +------------------+------------------+
                              |
                     collect logs + commits
                              |
                          score both runs
                              |
              compare waste rate, duplicates, commits
```

The harness only sets up worktrees and collects artifacts. It **never** tells agents what teammates are doing mid-run - that would break the test. Rules: [protocol/trial-1-protocol.md](protocol/trial-1-protocol.md).

Use `--isolated-arms` so each run gets its own git clone. Trial 004 skipped that and the comparison was invalid. Trial 005 did it correctly.

---

## Two repos, two jobs

| | [blaze-radar](https://github.com/Mikedan37/blaze-radar) | blaze-radar-harness (here) |
|--|--|--|
| **Job** | Shared board agents use while coding | Lab setup that tests if the board helps |
| **Analogy** | The whiteboard in the room | The stopwatch and checklist comparing two rooms |

Radar does not assign tasks, block files, or merge branches. It only publishes what agents already did. This repo measures whether that publication reduces duplicate work.

---

## Run it yourself

**Need:** blaze-radar demo daemon, Claude Code (`claude`), Python 3, any git repo.

```bash
git clone https://github.com/Mikedan37/blaze-radar-harness.git
cd blaze-radar-harness

# Radar demo (once)
git clone https://github.com/Mikedan37/blaze-radar.git ../blaze-radar
cd ../blaze-radar && swift build -c release
export PATH="$PWD/.build/release:$PATH"
blaze-radar-demo-daemon &

cd ../blaze-radar-harness

./harness/run-trial.sh --mode radar    --trial mytrial-radar    --repo ~/YourRepo
./harness/run-trial.sh --mode no-radar --trial mytrial-no-radar --repo ~/YourRepo
./harness/score-trial.sh --trial mytrial --report ~/radar-harness/mytrial/trial-report.md
```

Replay charts from frozen data (no agents needed):

```bash
python3 lib/plot_trial.py docs/trial-data/trial-005-score-v2.json
python3 lib/generate_trial_charts.py docs/trial-data/trial-*-score-v2.json
```

---

## What's in the box

| Folder / script | Purpose |
|-----------------|---------|
| `harness/run-trial.sh` | Start parallel agents (Radar or no-Radar mode) |
| `harness/collect-trial.sh` | Snapshot logs and git state after a run |
| `harness/score-trial.sh` | Output metrics JSON + report |
| `prompts/` | Agent instructions used in published trials |
| `docs/` | Results, charts, optional theory |

**Metrics the scorer prints:** waste rate, duplicate topics, commit counts, and (Radar arm only) whether agents cited board notes. Formulas: [docs/CONTROL_MODEL.md](docs/CONTROL_MODEL.md).

---

## License

MIT. See [LICENSE](LICENSE).
