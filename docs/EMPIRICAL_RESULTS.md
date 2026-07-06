# Empirical results

Frozen A/B trials on SeekerWebsite @ git SHA `1d6695f`, scored with `score_trial_v2.py`. Raw JSON lives in [`trial-data/`](trial-data/).

**How to read this page:** Each trial compares a **Radar arm** (shared board) to a **no-Radar arm** (isolated agents). We care whether the Radar arm keeps commit throughput while cutting wasted investigation. Theory and formulas are optional: [CONTROL_MODEL.md](CONTROL_MODEL.md).

---

## Trial 005 (best clean A/B)

**Setup:** 8 agents, `seeker-swarm-v1` prompts, isolated git clone per arm, 45 minute cap, zero cross-arm branch visibility.

**Headline:** Same commits (8/8), much lower waste rate on the Radar arm.

| Metric | No Radar | With Radar | Change |
|--------|----------|------------|--------|
| Waste rate | 77.5% | 42.5% | -35.0 pp |
| Wasted agent-min | 122.3 | 51.7 | -58% |
| Duplicate topics | 7 | 5 | -29% |
| Same-arm prior context | 5 | 7 | +2 |
| Commits | 8/8 | 8/8 | same |
| Wall time | 19.7 min | 15.2 min | radar faster (n=1) |
| Convergence score | 0.055 | 0.070 | +26% |

![Trial 005 energy partition](charts/trial-005-energy-heat.svg)

![Trial 005 dashboard](charts/trial-005-dashboard.svg)

**Example:** Agent 06 saw upload work on the board and pivoted instead of redoing it ([interpretation](trial-data/trial-005-interpretation.md)).

Treat wall-time and score lift as single-run signals until repeats land.

---

## Trial 004 (mechanism yes, comparison invalid)

Both arms ran sequentially against the same repo checkout. The Radar arm could see no-Radar branches, so arm deltas are contaminated.

**Still useful:** Agents did consume surfaced context (e.g. cherry-pick across trial branches). Proves the board is read; does not prove performance delta.

![Trial 004 energy partition](charts/trial-004-energy-heat.svg)

Details: [trial-004-interpretation.md](trial-data/trial-004-interpretation.md).

---

## Trial 002 (short 3-agent overlap)

Early ~15 agent-minute run. Waste rate improved; duplication flat; Radar arm showed compounding events. Exploratory, not headline.

![Trial 002 energy partition](charts/trial-002-energy-heat.svg)

---

## Waste rate across trials

![Waste rate by trial](charts/trials-waste-rate.svg)

Trial 004 is noisy (contamination + different effort). **Trial 005** is the clean comparison to cite.

---

## Reproduce charts locally

```bash
python3 lib/plot_trial.py docs/trial-data/trial-005-score-v2.json
python3 lib/generate_trial_charts.py docs/trial-data/trial-*-score-v2.json
```

---

## Batch repeats

Trials 006-010 were run locally for variance (may not yet appear in `trial-data/`). Copy new `*-score-v2.json` files into `docs/trial-data/` and rerun the chart command above.
