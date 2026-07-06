#!/usr/bin/env python3
"""Generate SVG charts from harness score JSON (scorer v2).

Usage:
  python3 lib/generate_trial_charts.py docs/trial-data/trial-005-score-v2.json
  python3 lib/generate_trial_charts.py docs/trial-data/*.json --out docs/charts
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_report(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def num(v: Any) -> float | None:
    if isinstance(v, (int, float)):
        return float(v)
    return None


def arm_metrics(report: dict[str, Any]) -> dict[str, dict[str, float | None]]:
    out: dict[str, dict[str, float | None]] = {}
    for key, label in ("no_radar", "No feedback"), ("radar", "+ Radar"):
        arm = report.get(key, {})
        ce = arm.get("cognitive_economics", {})
        m = arm.get("agent_minutes", {})
        conv = arm.get("convergence_score", arm.get("coordination_score"))
        out[label] = {
            "waste_rate": num(m.get("waste_rate")),
            "productive": num(m.get("productive")),
            "wasted": num(m.get("wasted")),
            "total": num(m.get("total")),
            "dup_topics": num(ce.get("duplicate_topic_count")),
            "cog_dup_rate": num(ce.get("cognitive_duplication_rate")),
            "prior_context": num(ce.get("prior_context_utilization")),
            "compounding": num(ce.get("compounding_events")),
            "convergence": num(conv) if not isinstance(conv, dict) else None,
            "commits": num(arm.get("friction", {}).get("merged_commits")),
        }
    return out


def svg_header(w: int, h: int) -> list[str]:
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
        '<style>text{font-family:ui-monospace,Menlo,monospace;font-size:12px;fill:#e6edf3}'
        '.title{font-size:14px;font-weight:600}.sub{fill:#8b949e;font-size:11px}'
        '.bar-nr{fill:#f85149}.bar-rd{fill:#3fb950}.grid{stroke:#30363d;stroke-width:1}'
        '.axis{fill:#8b949e}</style>',
        f'<rect width="{w}" height="{h}" fill="#0d1117"/>',
    ]


def grouped_bars(
    title: str,
    subtitle: str,
    metrics: list[tuple[str, str, float]],
    w: int = 720,
    h: int = 320,
) -> str:
    """metrics: (label, series_name, value 0-1 or absolute with max in group)"""
    lines = svg_header(w, h)
    lines.append(f'<text x="24" y="28" class="title">{title}</text>')
    lines.append(f'<text x="24" y="46" class="sub">{subtitle}</text>')
    # legend
    lines.append('<rect x="24" y="56" width="12" height="12" class="bar-nr"/>')
    lines.append('<text x="42" y="66" class="axis">No feedback</text>')
    lines.append('<rect x="140" y="56" width="12" height="12" class="bar-rd"/>')
    lines.append('<text x="158" y="66" class="axis">+ Radar</text>')

    groups: dict[str, list[tuple[str, float]]] = {}
    for label, series, val in metrics:
        groups.setdefault(label, []).append((series, val))

    n = len(groups)
    if n == 0:
        lines.append("</svg>")
        return "\n".join(lines)

    top = 80
    bottom = h - 40
    chart_h = bottom - top
    group_w = (w - 80) / n
    bar_w = min(28, group_w / 3)

    for i, (glabel, pairs) in enumerate(groups.items()):
        gx = 60 + i * group_w + group_w / 2
        max_v = max(v for _, v in pairs) if pairs else 1.0
        max_v = max(max_v, 0.001)
        for j, (series, val) in enumerate(pairs):
            bh = (val / max_v) * (chart_h - 20)
            x = gx - bar_w - 4 if series == "No feedback" else gx + 4
            y = bottom - bh
            cls = "bar-nr" if series == "No feedback" else "bar-rd"
            lines.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w}" height="{bh:.1f}" class="{cls}"/>')
            lines.append(f'<text x="{x + bar_w/2:.1f}" y="{y - 4}" text-anchor="middle" class="axis">{val:.2f}</text>')
        lines.append(f'<text x="{gx:.1f}" y="{bottom + 18}" text-anchor="middle" class="axis">{glabel}</text>')

    lines.append(f'<line x1="50" y1="{bottom}" x2="{w-20}" y2="{bottom}" class="grid"/>')
    lines.append("</svg>")
    return "\n".join(lines)


def stacked_energy(title: str, subtitle: str, nr: dict, rd: dict, w=520, h=280) -> str:
    lines = svg_header(w, h)
    lines.append(f'<text x="24" y="28" class="title">{title}</text>')
    lines.append(f'<text x="24" y="46" class="sub">{subtitle}</text>')
    lines.append('<rect x="24" y="56" width="12" height="12" fill="#3fb950"/>')
    lines.append('<text x="42" y="66" class="axis">Productive</text>')
    lines.append('<rect x="120" y="56" width="12" height="12" fill="#f85149"/>')
    lines.append('<text x="138" y="66" class="axis">Heat (wasted)</text>')

    arms = [("No feedback", nr), ("+ Radar", rd)]
    top, bottom = 80, h - 50
    max_total = max((a[1].get("total") or 1) for a in arms)
    col_w = 100
    start_x = (w - col_w * 2) / 2

    for i, (label, m) in enumerate(arms):
        cx = start_x + i * col_w + col_w / 2
        total = m.get("total") or 0
        prod = m.get("productive") or 0
        waste = m.get("wasted") or 0
        scale = (bottom - top) / max_total
        prod_h = prod * scale
        waste_h = waste * scale
        x = cx - 35
        lines.append(f'<rect x="{x}" y="{bottom - prod_h - waste_h}" width="70" height="{prod_h}" fill="#3fb950"/>')
        lines.append(f'<rect x="{x}" y="{bottom - waste_h}" width="70" height="{waste_h}" fill="#f85149"/>')
        lines.append(f'<text x="{cx}" y="{bottom + 18}" text-anchor="middle" class="axis">{label}</text>')
        lines.append(f'<text x="{cx}" y="{bottom + 34}" text-anchor="middle" class="sub">{total:.0f} agent-min</text>')

    lines.append("</svg>")
    return "\n".join(lines)


def trial005_dashboard(report: dict[str, Any]) -> str:
    m = arm_metrics(report)
    nr, rd = m["No feedback"], m["+ Radar"]
    metrics = [
        ("Waste rate", "No feedback", nr["waste_rate"] or 0),
        ("Waste rate", "+ Radar", rd["waste_rate"] or 0),
        ("Cog dup rate", "No feedback", nr["cog_dup_rate"] or 0),
        ("Cog dup rate", "+ Radar", rd["cog_dup_rate"] or 0),
        ("Convergence", "No feedback", nr["convergence"] or 0),
        ("Convergence", "+ Radar", rd["convergence"] or 0),
        ("Prior context", "No feedback", (nr["prior_context"] or 0) / 8),
        ("Prior context", "+ Radar", (rd["prior_context"] or 0) / 8),
    ]
    return grouped_bars(
        "Trial 005 — isolated 8-agent swarm (SeekerWebsite @ 1d6695f)",
        "Same commits (8/8) · per-arm git clone · seeker-swarm-v1 · 45m cap",
        metrics,
        w=760,
        h=340,
    )


def multi_trial_waste_delta(reports: list[tuple[str, dict]]) -> str:
    metrics: list[tuple[str, str, float]] = []
    for tid, rep in reports:
        m = arm_metrics(rep)
        nr_wr = m["No feedback"]["waste_rate"] or 0
        rd_wr = m["+ Radar"]["waste_rate"] or 0
        label = tid.replace("trial-", "T")
        metrics.append((label, "No feedback", nr_wr))
        metrics.append((label, "+ Radar", rd_wr))
    return grouped_bars(
        "Waste rate by trial (lower is better)",
        "T004 contaminated (sequential shared repo) · T005 clean isolation · T002 short overlap pack",
        metrics,
        w=640,
        h=300,
    )


def generate_all(score_paths: list[Path], out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    reports: list[tuple[str, dict]] = []

    for p in score_paths:
        rep = load_report(p)
        tid = rep.get("trial_base", p.stem)
        reports.append((tid, rep))
        m = arm_metrics(rep)
        nr, rd = m["No feedback"], m["+ Radar"]

        energy = stacked_energy(
            f"{tid} — energy partition (agent-minutes)",
            "E = productive + wasted  ·  Q_heat ≈ waste_rate · E",
            nr,
            rd,
        )
        ep = out_dir / f"{tid}-energy-heat.svg"
        ep.write_text(energy)
        written.append(ep)

    # Trial 005 focus dashboard
    t5 = next((r for tid, r in reports if tid == "trial-005"), None)
    if t5:
        p = out_dir / "trial-005-dashboard.svg"
        p.write_text(trial005_dashboard(t5))
        written.append(p)

    if len(reports) >= 2:
        p = out_dir / "trials-waste-rate.svg"
        p.write_text(multi_trial_waste_delta(reports))
        written.append(p)

    return written


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("scores", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, default=Path("docs/charts"))
    args = parser.parse_args()
    paths = [p for p in args.scores if p.is_file()]
    if not paths:
        print("error: no score files found", file=sys.stderr)
        return 1
    written = generate_all(paths, args.out)
    for w in written:
        print(w)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
