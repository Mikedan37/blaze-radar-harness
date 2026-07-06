# Trial 005 — Interpretation

## Honest summary

In an isolated 8-agent run against a strong baseline (agents + git + filesystem), Radar preserved throughput while reducing repeated investigations (7→5, −29%) and increasing within-team context reuse (same-arm 5→7). Early signal; needs larger trials (5–10 repeats).

**Not:** solved coordination. **Not:** victory lap.

**Outcome matrix:** leans **A** — same-arm context ↑, duplicate trajectories ↓, throughput not obviously killed.

## Isolation

- Per-arm `git clone --dissociate` at same SHA
- Arm order: radar first, then no-radar (randomized)
- Radar arm: **0 cross_arm** prior-context events
- Radar v1 frozen (sync, notes, board, warnings)

## UploadPageClient cluster (manual trace)

Real damping behavior, not scorer fiction:

| Agent | Behavior |
|-------|----------|
| **agent-01** | Independent funnel analysis → desktop proof tile. Posted distinct evidence to board; noted overlap risk with peers on upload. |
| **agent-02** | Same fix class (desktop example tile) — converged independently. |
| **agent-03** | Validated demo CTA gating thesis; extended for cold visitors (`isColdVisitor`). |
| **agent-05** | Board empty at start; posted funnel notes after shipping so others don't re-investigate. |
| **agent-06** | **Read board** → saw 2 agents on `UploadPageClient` + "do NOT re-add desktop tile" warning → **abandoned** duplicate path → pivoted to signup form. |
| **agent-07** | **Read board** → agent-05 claimed upload activation → **deferred** to guides sticky CTA instead. |

Shape: discover → (board) → validate/defer/extend — not discover→implement loops in isolation.

## Runtime (Trial 005)

| Arm | Wall time |
|-----|-----------|
| no-radar | 19.7 min |
| radar | 15.2 min |

Radar finished **4.5 min faster** this run — same 8/8 commits. Not claiming speedup until batch variance is known.

## Agent-06 vs agent-07 (mechanism nuance)

**agent-06** is the damping trace: overlap happened → board feedback → trajectory changed (upload → signup). Not "Radar prevented overlap."

**agent-07** deferred upload — distinguish optimization ("coverage exists, marginal value elsewhere") from obedience ("forbidden lane").

## Caveats

- ~30 min runs; small n; waste-rate deltas noisy
- Hooks don't fire in `claude -p`; manual sync only

## Next

1. Harness commit accounting fixed
2. Batch trials 006–010 running (variance + wall-time)
3. If ~20–30% duplicate reduction persists across repeats → meaningful damping coefficient
