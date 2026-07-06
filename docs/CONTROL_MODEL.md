# Control model (optional read)

This page gives a math-friendly view of what the harness scores. You do not need it to run trials. For setup and results, start with the [README](../README.md) and [EMPIRICAL_RESULTS.md](EMPIRICAL_RESULTS.md).

---

## Summary in plain language

1. **Goal:** Agents should make progress without re-walking the same investigation paths.
2. **Treatment:** Blaze Radar shared board so agents see each other's tasks and notes.
3. **Control:** Same agents and prompts, but no board.
4. **Success pattern:** Similar total effort and commit count, but lower waste rate and fewer duplicate topics on the Radar arm.
5. **Out of scope:** Automatically merging agent branches. Humans (or a future tool) still decide what composes.

---

## Two loops (only one is measured here)

| Loop | Question | Who closes it today |
|------|----------|---------------------|
| **State feedback** | Did agents know what was already tried? | Radar (board) + harness (measures) |
| **Integration** | Which partial fixes combine into one release? | Human review / merge |

Radar is sensor-only. It does not actuate merges or block files.

---

## Feedback path (ASCII)

```
                    Shared board
                   (tasks + notes)
                  /      |      \
         writes  /       |       \  reads
                /        |        \
           Agent 1    Agent 2    Agent 3
                \        |        /
                 \       |       /
                  v      v       v
                    Codebase
              (each agent edits git)
```

Agents publish what they learned; peers read before starting new work. Without the board, each arrow back to the board is missing and agents retrace the same paths blindly.

---

## Variables (analogy, not fitted physics)

**x(t)** = distance from "done" (bug fixed, feature shipped). We do not measure x directly.

Useful mental model only (not a measured damping ratio):

```
x_dot ≈ progress - heat + disturbance
```

| Term | Plain meaning | Scorer proxy |
|------|---------------|--------------|
| progress | Work that moves the repo forward | useful commits, diffs |
| heat | Effort spent re-exploring known ground | waste_rate, duplicate_investigations |
| disturbance | Parallel exploration, merge friction | merge failures, conflicts |

**Proximity is not collision.** Two agents on the same folder is fine if the second builds on the first's notes instead of repeating the same trace.

---

## Energy balance (what score_trial_v2.py computes)

Total agent effort:

```
E = agent_minutes_total
```

Split into useful work and waste:

```
E = E_useful + Q_heat
Q_heat ≈ waste_rate * E
```

**Hypothesis under test:**

```
E_radar ≈ E_no_radar           (same throughput)
Q_heat_radar < Q_heat_no_radar (less redundant work)
convergence_score_radar > convergence_score_no_radar
```

**Convergence score:**

```
convergence_score = (useful_outputs + leverage - duplicate_work - merge_cost) / E
```

Higher score at similar E means more forward progress per agent-minute.

**Bad outcome:** Waste hits zero because agents stopped working (over-constrained), not because they converged smarter.

---

## Measured signals

| Domain | Question | Scorer field |
|--------|----------|--------------|
| Oscillation | Retracing explored state? | duplicate_investigations, cognitive_duplication_rate |
| Energy | How much effort in? | agent_minutes.total, output_per_agent_hour |
| Heat | How much redundant? | waste_rate, wasted_breakdown |
| Damping | Did feedback change paths? | prior_context_utilization, compounding_events |
| Convergence | Progress per energy | convergence_score |

Arm comparison block: waste_rate_delta, duplicate_investigations_delta, compounding_events_delta, convergence_score_lift_pct.

---

## Claim checklist

| Claim | Status |
|-------|--------|
| Feedback reduces heat at similar throughput | Empirical - see EMPIRICAL_RESULTS.md |
| Duplicate detection | Heuristic (stdout, diffs, board text) |
| Compounding detection | Heuristic (transcript language) |
| Measured damping ratio zeta | No - analogy only |
| Branch integration | No - future layer |

---

## Generate charts

```bash
python3 lib/generate_trial_charts.py docs/trial-data/trial-*-score-v2.json
python3 lib/plot_trial.py docs/trial-data/trial-005-score-v2.json
```
