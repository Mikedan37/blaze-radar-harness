# Trial 004 — Interpretation

## Labels

| Question | Verdict |
|----------|---------|
| **Mechanism validation** | Yes — agents consume surfaced context (radar agent-02 cherry-picked `trial/nr004-agent-05`) |
| **Performance A/B** | Contaminated — rerun needed with isolated arms |

## What went wrong (experiment design, not product)

Trial 004 ran **sequentially** on a **shared git source** (`~/SeekerWebsite`):

```
commit X (1d6695f)
  ├─ no-radar arm runs → creates trial/nr004-* branches
  └─ radar arm runs afterward → can see and cherry-pick those branches
```

Radar got access to **control-group future knowledge**. That invalidates “Radar outperforms no-Radar from identical starting conditions.”

It **does** validate the mechanism: when prior work exists and is visible, agents with awareness reuse it.

## Source attribution (Trial 004 re-score)

Trial 004 radar arm prior-context events break down by source. The headline **same-arm** count excludes cross-arm cherry-picks (`trial/nr004-*`). Re-run `score-trial.sh --trial trial-004` after scorer updates for current numbers.

**Claims separated:**

| Claim | Trial 004 |
|-------|-----------|
| Agents consume surfaced context | ✅ (including cross-arm) |
| Radar improves **internal** swarm feedback | ❓ — measure same-arm only in Trial 005 |
| Less duplicate trajectories | ❓ — contaminated + short run |

---

- Prior context utilization 12 → 22
- Qualitative cherry-pick across arms (the behavior you want in production *within* a team)
- Both arms shipped real activation/conversion work in ~30 min

## Trial 005 — clean isolation

```bash
run-trial.sh --mode both --trial trial-005 \
  --prompt-pack seeker-swarm-v1 --agents 8 --duration-minutes 45 \
  --isolated-arms --randomize-arm-order --fresh
```

Each arm gets its own `git clone --dissociate` under `~/radar-trials/trial-005-*/repo/` — no cross-arm branch visibility. Trial-scoped Radar boards remain separate via `BLAZE_RADAR_TRIAL_ID`.

Measure within-arm compounding: does agent-08 build on agent-02? Does agent-05 avoid agent-03's dead end?
