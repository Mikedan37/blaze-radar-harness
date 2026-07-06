#!/usr/bin/env python3
"""ASCII comparison chart from harness score JSON (scorer v2 output).

Usage:
  python3 lib/plot_trial.py ~/radar-harness/trial-002-score.json
  score-trial.sh --trial trial-002 --out ~/radar-harness/trial-002-score.json
  python3 lib/plot_trial.py ~/radar-harness/trial-002-score.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def bar(value: float | None, width: int = 28, max_val: float = 1.0) -> str:
    if value is None:
        return " " * width + " n/a"
    if isinstance(value, dict):
        return " " * width + f" ? ({value.get('reason', 'unknown')})"
    v = max(0.0, min(float(value), max_val))
    filled = int(round(v / max_val * width)) if max_val else 0
    return "█" * filled + " " * (width - filled) + f" {v:.3f}"


def get(d: dict[str, Any], *keys: str, default: Any = None) -> Any:
    cur: Any = d
    for k in keys:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(k, default)
        if cur is default:
            return default
    return cur


def fmt_score(v: Any) -> str:
    if isinstance(v, dict) and v.get("status") == "UNKNOWN":
        return f"UNKNOWN ({v.get('reason', '?')})"
    if v is None:
        return "n/a"
    return f"{v:.4f}" if isinstance(v, (int, float)) else str(v)


def render(report: dict[str, Any]) -> str:
    nr = report.get("no_radar", {})
    rd = report.get("radar", {})
    cmp_ = report.get("comparison", {})

    lines = [
        f"Trial: {report.get('trial_base', '?')}  (scorer v{report.get('scorer_version', '?')})",
        "",
        "=== Energy & heat (agent-minutes) ===",
        "",
    ]

    for label, arm in ("No feedback", nr), ("+ Radar", rd):
        m = arm.get("agent_minutes", {})
        if m.get("status") == "UNKNOWN":
            lines.append(f"{label:12} total=UNKNOWN")
            continue
        total = m.get("total") or 0
        productive = m.get("productive") or 0
        wasted = m.get("wasted") or 0
        wr = m.get("waste_rate")
        lines.append(f"{label:12} total={total:.1f}m  productive={productive:.1f}m  wasted={wasted:.1f}m")
        if wr is not None:
            lines.append(f"{'':12} waste_rate {bar(wr, max_val=1.0)}")
        lines.append("")

    lines.extend(
        [
            "=== Oscillation proxies ===",
            "",
        ]
    )
    for label, arm in ("No feedback", nr), ("+ Radar", rd):
        ce = arm.get("cognitive_economics", {})
        dup = ce.get("duplicate_topic_count", "?")
        cdr = ce.get("cognitive_duplication_rate")
        lines.append(f"{label:12} duplicate_topics={dup}  cognitive_duplication_rate={cdr}")
        if cdr is not None:
            lines.append(f"{'':12} {bar(cdr, max_val=1.0)}")
        lines.append("")

    lines.extend(
        [
            "=== Feedback / damping proxies (Radar arm only meaningful) ===",
            "",
        ]
    )
    for label, arm in ("No feedback", nr), ("+ Radar", rd):
        ce = arm.get("cognitive_economics", {})
        pc = ce.get("prior_context_utilization", 0)
        comp = ce.get("compounding_events", 0)
        conv = arm.get("convergence_score") or arm.get("coordination_score")
        lines.append(
            f"{label:12} prior_context={pc}  compounding={comp}  convergence={fmt_score(conv)}"
        )
        lines.append("")

    lines.extend(
        [
            "=== Arm comparison (Radar − No feedback) ===",
            "",
            f"  waste_rate_delta:              {cmp_.get('waste_rate_delta')}",
            f"  duplicate_investigations_delta:{cmp_.get('duplicate_investigations_delta')}",
            f"  compounding_events_delta:      {cmp_.get('compounding_events_delta')}",
            f"  prior_context_utilization_delta:{cmp_.get('prior_context_utilization_delta')}",
            f"  convergence_score_lift_pct:    {cmp_.get('convergence_score_lift_pct')}",
            "",
            "Legend: lower waste/duplication + higher compounding/convergence = damping hypothesis supported.",
            "        We do NOT compute damping ratio ζ - these are empirical proxies from frozen trial artifacts.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="ASCII trial comparison from score JSON")
    parser.add_argument("score_json", type=Path, help="Output from score-trial.sh --out")
    args = parser.parse_args()
    if not args.score_json.is_file():
        print(f"error: not found: {args.score_json}", file=sys.stderr)
        return 1
    report = json.loads(args.score_json.read_text())
    print(render(report), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
