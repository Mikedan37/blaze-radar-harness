#!/usr/bin/env python3
"""Scorer v2 - Radar harness evaluation from frozen trial artifacts only."""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

INFRA_FILES = {"CLAUDE.md", "AGENTS.md", "GEMINI.md"}
BROAD_TOPICS = {
    "analytics",
    "test-suite",
    "test suite",
    "attention-slot",
    "component",
    "route",
    "api",
}
ROLES = ("feature", "tests", "audit")
TS_FMT = "%Y-%m-%dT%H:%M:%SZ"

# Topic extraction: paths, components, domain phrases
PATH_RE = re.compile(r"`([^`]+\.(?:tsx?|jsx?|ts|js|md))`|(?:src|lib|app)/[\w./-]+\.(?:tsx?|jsx?|ts|js)")
COMPONENT_RE = re.compile(
    r"\b(MatchCard|analytics|auth|weekly-digest|weekly-blog|visibility-polling|"
    r"attention-slot|internal route|test suite|analytics-contract)\b",
    re.I,
)
INVESTIGATION_VERBS = re.compile(
    r"\b(investigat(?:e|ed|ing)|found|audit|analyz(?:e|ed)|reproduced|"
    r"root cause|failure|broken|red test|timeout|validat(?:e|ed|ing))\b",
    re.I,
)
# Diagnostic only - staying away is NOT compounding (do not score as success).
SEPARATION_RE = re.compile(
    r"\b(out of (?:my )?scope|not in (?:my )?scope|did not touch|"
    r"leaving (?:this |that )?(?:area |work )?to|went elsewhere|"
    r"I(?:'ll| will) (?:work on|change) (?:css|styling|unrelated))\b",
    re.I,
)
# Prior context utilization = informed work (awareness, not assignment).
COMPOUNDING_KINDS: list[tuple[str, re.Pattern[str]]] = [
    (
        "reused_prior_discovery",
        re.compile(
            r"\b(reused?|prior (?:discovery|finding)|their notes|board notes|"
            r"from (?:the )?board|already (?:found|discovered|noted)|"
            r"previous (?:discovery|finding|agent)|used .+ discovery|"
            r"agent-\w+.{0,40}(?:reported|noted|found))\b",
            re.I,
        ),
    ),
    (
        "inspected_before_starting",
        re.compile(
            r"\b(read (?:the )?board|checked (?:the )?board|radar (?:board|active)|"
            r"blaze radar (?:sync|active|status)|inspect(?:ed|ing)? .+ (?:branch|work|commit)|"
            r"before (?:I )?start(?:ed|ing)|looked at .+ (?:branch|agent))\b",
            re.I,
        ),
    ),
    (
        "validated_or_extended_work",
        re.compile(
            r"\b(validat(?:e|ed|ing)|incomplete|partial(?:ly)?|finish(?:ing|ed) (?:it|the)|"
            r"extended (?:the|their)|80%|complet(?:e|ing|ed) (?:the|their)|"
            r"building on|based on .+ finding)\b",
            re.I,
        ),
    ),
    (
        "continued_unfinished_work",
        re.compile(
            r"\b(continu(?:e|ed|ing) (?:the|their|where)|pick(?:ed)? up|"
            r"unfinished|left off|same area|still working)\b",
            re.I,
        ),
    ),
    (
        "avoided_known_failed_path",
        re.compile(
            r"\b(don'?t (?:re-?investigate|burn another)|known (?:dead|failed)|"
            r"already (?:tried|checked|investigated)|failed (?:path|approach)|"
            r"avoided re-|not worth re-|does not exist on (?:this )?branch)\b",
            re.I,
        ),
    ),
]
COMPLEMENT_RE = re.compile(
    r"\b(coverage (?:for|around)|tests? (?:for|around)|"
    r"adding tests? (?:for|around|to))\b",
    re.I,
)


def is_infrastructure(path: str) -> bool:
    normalized = path.strip("/")
    if normalized in INFRA_FILES:
        return True
    for prefix in (".blaze/", ".claude/", ".cursor/"):
        if normalized == prefix.rstrip("/") or normalized.startswith(prefix):
            return True
    return False


def load_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def unknown(msg: str) -> dict[str, str]:
    return {"status": "UNKNOWN", "reason": msg}


def parse_ts(text: str) -> datetime | None:
    text = text.strip()
    if not text:
        return None
    for fmt in (TS_FMT, "%Y-%m-%dT%H:%M:%S%z"):
        try:
            dt = datetime.strptime(text.replace("+00:00", "Z"), fmt.replace("%z", ""))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return None


@dataclass
class AgentArtifacts:
    role: str
    stdout: str = ""
    stderr: str = ""
    diff: str = ""
    files_changed: list[str] = field(default_factory=list)
    files_scored: list[str] = field(default_factory=list)
    commit: dict[str, Any] = field(default_factory=dict)
    started_at: datetime | None = None
    runtime_minutes: float | None = None
    runtime_method: str | None = None
    discovered_facts: list[str] = field(default_factory=list)
    gaps: list[str] = field(default_factory=list)


def trial_log_dir(trials_root: Path, trial_id: str) -> Path | None:
    p = trials_root / trial_id / "run-logs"
    return p if p.is_dir() else None


def load_agent_artifacts(
    bench_dir: Path,
    log_dir: Path | None,
    role: str,
    harness: dict[str, Any] | None,
    board_regs: list[dict[str, Any]],
) -> AgentArtifacts:
    art = AgentArtifacts(role=role)
    stats = load_json(bench_dir / "agents" / role / "stats.json") or {}
    art.files_changed = stats.get("files_changed", [])
    art.files_scored = [f for f in art.files_changed if not is_infrastructure(f)]

    diff_path = bench_dir / "agents" / role / "diff.patch"
    if diff_path.is_file():
        art.diff = diff_path.read_text(errors="replace")

    if log_dir:
        for name, attr in (("claude.stdout", "stdout"), ("claude.stderr", "stderr")):
            p = log_dir / role / name
            if p.is_file():
                setattr(art, attr, p.read_text(errors="replace"))
            else:
                art.gaps.append(f"missing run-logs/{role}/{name}")
        started_path = log_dir / role / "started_at"
        if started_path.is_file():
            art.started_at = parse_ts(started_path.read_text())
        else:
            art.gaps.append(f"missing run-logs/{role}/started_at")
    else:
        art.gaps.append(f"missing run-logs for trial (no log dir)")

    if harness:
        agent_h = (harness.get("agents") or {}).get(role) or {}
        art.commit = agent_h.get("commit") or {}

    for reg in board_regs:
        if reg.get("role_hint") == role or _reg_matches_role(reg, role):
            art.discovered_facts.extend(reg.get("discoveredFacts") or [])

    return art


def _reg_matches_role(reg: dict[str, Any], role: str) -> bool:
    task = (reg.get("task") or "").lower()
    branch = (reg.get("branch") or "").lower()
    if role in branch:
        return True
    keywords = {
        "feature": ("feature", "match", "ux", "ui"),
        "tests": ("test", "quality", "suite"),
        "audit": ("audit", "architecture", "read-only"),
    }
    return any(k in task for k in keywords.get(role, ()))


def estimate_agent_runtimes(
    agents: list[AgentArtifacts],
    harness: dict[str, Any] | None,
    meta: dict[str, Any],
) -> None:
    """Parallel harness: each agent ≈ arm wall duration when claude ran."""
    arm_minutes: float | None = None
    method = None
    if harness and harness.get("started_at") and harness.get("finished_at"):
        a = parse_ts(harness["started_at"])
        b = parse_ts(harness["finished_at"])
        if a and b:
            arm_minutes = round((b - a).total_seconds() / 60.0, 2)
            method = "parallel_arm_wall"
    if arm_minutes is None and meta.get("duration_minutes"):
        arm_minutes = float(meta["duration_minutes"])
        method = "configured_duration_cap"

    for art in agents:
        if arm_minutes is None:
            art.runtime_minutes = None
            art.runtime_method = None
            if not art.gaps:
                art.gaps.append("missing per-agent finished_at and arm timestamps")
            continue
        ran = art.stdout or art.commit.get("committed") or art.commit.get("first_attempt")
        if ran:
            art.runtime_minutes = arm_minutes
            art.runtime_method = method
        else:
            art.runtime_minutes = 0.0
            art.runtime_method = "not_launched"


def extract_topics(text: str) -> set[str]:
    topics: set[str] = set()
    for m in PATH_RE.finditer(text):
        raw = m.group(1) if m.lastindex else m.group(0)
        raw = raw.strip("`")
        topics.add(_normalize_topic(raw))
        base = Path(raw).stem
        if base and len(base) > 2:
            topics.add(_normalize_topic(base))
    for m in COMPONENT_RE.finditer(text):
        topics.add(_normalize_topic(m.group(0)))
    return {t for t in topics if t and len(t) > 2}


def _normalize_topic(s: str) -> str:
    s = s.lower().strip().replace("_", "-")
    s = re.sub(r"\.(tsx?|jsx?|ts|js)$", "", s)
    if "/" in s:
        s = Path(s).name
    return s


def agent_topic_evidence(art: AgentArtifacts) -> dict[str, set[str]]:
    """Map topic -> evidence snippets."""
    blob = "\n".join(
        [art.stdout, art.stderr, art.diff, " ".join(art.discovered_facts)]
        + ([art.commit.get("message", "")] if art.commit else [])
    )
    topics = extract_topics(blob)
    for f in art.files_scored:
        topics.add(_normalize_topic(f))
    return {t: {art.role} for t in topics}


def detect_duplicate_investigations(agents: list[AgentArtifacts]) -> dict[str, Any]:
    role_topics: dict[str, set[str]] = defaultdict(set)
    topic_agents: dict[str, set[str]] = defaultdict(set)
    topic_evidence: dict[str, list[str]] = defaultdict(list)

    for art in agents:
        blob = "\n".join([art.stdout, art.stderr, " ".join(art.discovered_facts)])
        if not INVESTIGATION_VERBS.search(blob) and art.role == "audit":
            # audit role investigates by definition if it produced stdout
            pass
        topics = set()
        for t_map in [agent_topic_evidence(art)]:
            topics.update(t_map.keys())
        for t in topics:
            if t in ("md", "tsx", "ts", "jsx", "js"):
                continue
            role_topics[art.role].add(t)
            topic_agents[t].add(art.role)
            snippet = _topic_snippet(blob, t)
            if snippet:
                topic_evidence[t].append(f"{art.role}: {snippet}")

    duplicates = []
    for topic, agent_set in sorted(topic_agents.items()):
        if len(agent_set) < 2:
            continue
        # Skip ultra-generic topics unless multiple agents have investigation language
        if topic in ("test", "route", "api", "lib", "src", "component"):
            continue
        agents_list = sorted(agent_set)
        if topic in BROAD_TOPICS and len(agents_list) >= 3:
            continue
        severity = "low"
        if len(agents_list) >= 3:
            severity = "high"
        elif any(
            t in topic
            for t in ("auth", "matchcard", "timeout", "weekly-digest", "weekly-blog")
        ):
            severity = "medium"
        duplicates.append(
            {
                "topic": topic,
                "agents": agents_list,
                "severity": severity,
                "evidence": topic_evidence.get(topic, [])[:4],
            }
        )

    missing = []
    if not any(a.stdout for a in agents):
        missing.append("agent stdout (all empty)")

    return {
        "duplicate_investigations": duplicates,
        "gaps": missing,
    }


def _topic_snippet(text: str, topic: str, max_len: int = 120) -> str:
    for line in text.splitlines():
        if topic.replace("-", "") in line.lower().replace("-", ""):
            s = line.strip()
            if len(s) > max_len:
                return s[: max_len - 3] + "..."
            return s
    return ""


def detect_coordination_leverage(
    agents: list[AgentArtifacts],
    group: str,
) -> dict[str, Any]:
    separation: list[dict[str, str]] = []
    compounding_events: list[dict[str, str]] = []
    by_kind: dict[str, int] = defaultdict(int)
    complementary: list[dict[str, str]] = []

    by_role = {a.role: a for a in agents}

    for art in agents:
        blob = art.stdout + "\n" + art.stderr + " ".join(art.discovered_facts)
        seen_spans: list[tuple[int, int]] = []

        for kind, pattern in COMPOUNDING_KINDS:
            for m in pattern.finditer(blob):
                span = (m.start(), m.end())
                if any(s[0] <= span[0] < s[1] or span[0] <= s[0] < span[1] for s in seen_spans):
                    continue
                seen_spans.append(span)
                by_kind[kind] += 1
                compounding_events.append(
                    {
                        "agent": art.role,
                        "kind": kind,
                        "signal": m.group(0),
                        "excerpt": _excerpt(blob, m.start()),
                    }
                )

        for m in SEPARATION_RE.finditer(blob):
            separation.append(
                {
                    "agent": art.role,
                    "signal": m.group(0),
                    "excerpt": _excerpt(blob, m.start()),
                }
            )

    # Complementary: agents building on each other's file areas
    role_list = list(by_role.keys())
    for i, ra in enumerate(role_list):
        for rb in role_list[i + 1 :]:
            a, b = by_role[ra], by_role[rb]
            overlap = set(a.files_scored) & set(b.files_scored)
            if overlap:
                complementary.append(
                    {
                        "kind": "same_component_files",
                        "agents": [ra, rb],
                        "files": sorted(overlap),
                    }
                )
            blob_b = b.stdout.lower()
            for comp in a.files_scored:
                comp_name = Path(comp).stem.lower()
                if comp_name and comp_name in blob_b and COMPLEMENT_RE.search(b.stdout):
                    complementary.append(
                        {
                            "kind": "coverage_reference",
                            "agents": [ra, rb],
                            "topic": comp_name,
                        }
                    )

    # Deduplicate complementary entries
    seen = set()
    comp_unique = []
    for c in complementary:
        key = json.dumps(c, sort_keys=True)
        if key not in seen:
            seen.add(key)
            comp_unique.append(c)

    gaps = []
    if group == "radar" and not any(a.stdout for a in agents):
        gaps.append("stdout empty - cannot detect leverage signals")

    return {
        "coordination_leverage": {
            "prior_context_utilization": len(compounding_events),
            "compounding_events": len(compounding_events),
            "compounding_by_kind": dict(by_kind),
            "complementary_changes": len(comp_unique),
            "separation_events": len(separation),
        },
        "prior_context_details": compounding_events[:15],
        "compounding_details": compounding_events[:15],
        "separation_details": separation[:10],
        "complementary_details": comp_unique[:10],
        "gaps": gaps,
    }


def _excerpt(text: str, pos: int, radius: int = 80) -> str:
    start = max(0, pos - radius)
    end = min(len(text), pos + radius)
    s = text[start:end].replace("\n", " ").strip()
    return s[:160]


def compute_agent_minutes(
    agents: list[AgentArtifacts],
    harness: dict[str, Any] | None,
    merge_doc: dict[str, Any],
    duplicate_count: int,
    overlap_files: int,
) -> dict[str, Any]:
    estimate_agent_runtimes(agents, harness, {})

    runtimes = [a.runtime_minutes for a in agents if a.runtime_minutes is not None]
    if not runtimes:
        return {
            **unknown("missing arm timestamps and per-agent finished_at"),
            "gaps": list(
                {g for a in agents for g in a.gaps}
                | {"cannot sum agent runtime without harness timestamps"}
            ),
        }

    total = round(sum(runtimes), 2)
    method = agents[0].runtime_method if agents else None

    merged_roles = set()
    for m in merge_doc.get("sequential_merge") or []:
        if m.get("success"):
            role = m.get("role")
            if role:
                merged_roles.add(role)

    productive = 0.0
    wasted_breakdown: dict[str, float] = {
        "abandoned_commits": 0.0,
        "duplicate_investigations": 0.0,
        "conflicting_work": 0.0,
        "merge_repair": 0.0,
    }
    gaps: list[str] = []

    per_agent_minutes = min(runtimes) if runtimes else 0.0

    for art in agents:
        mins = art.runtime_minutes or 0.0
        committed = art.commit.get("committed", False)
        attempted = art.commit.get("first_attempt") not in (None, "skipped_no_changes")

        survived = committed and (art.role in merged_roles or not merged_roles)
        if survived and committed:
            productive += mins
        elif attempted and not committed:
            wasted_breakdown["abandoned_commits"] += mins
        elif not committed and art.stdout:
            # worked but no commit - partial waste
            wasted_breakdown["abandoned_commits"] += mins * 0.5
            productive += mins * 0.5
            gaps.append(f"{art.role}: worked without commit - waste split 50/50 (estimate)")

    if duplicate_count:
        # Allocate one agent-minute per duplicate topic per extra agent (estimate)
        dup_waste = round(min(per_agent_minutes * 0.25, total) * duplicate_count, 2)
        wasted_breakdown["duplicate_investigations"] = dup_waste

    if overlap_files:
        wasted_breakdown["conflicting_work"] = round(
            per_agent_minutes * 0.15 * overlap_files, 2
        )

    merge_fails = sum(
        1 for m in (merge_doc.get("sequential_merge") or []) if not m.get("success")
    )
    if merge_fails:
        wasted_breakdown["merge_repair"] = round(per_agent_minutes * merge_fails, 2)

    wasted = round(
        min(
            total,
            sum(wasted_breakdown.values()),
        ),
        2,
    )
    # Reconcile: productive = total - wasted (cap)
    productive = round(max(0.0, total - wasted), 2)
    waste_rate = round(wasted / total, 3) if total else None

    return {
        "total": total,
        "productive": productive,
        "wasted": wasted,
        "waste_rate": waste_rate,
        "wasted_breakdown": wasted_breakdown,
        "method": method,
        "gaps": gaps,
        "note": (
            "Parallel harness: each agent assigned arm wall duration. "
            "Duplicate/conflict waste uses conservative estimates when timing unavailable."
        ),
    }


def legacy_friction_score(
    merged_commits: int,
    files_changed: int,
    collision_rate: float,
) -> float:
    if files_changed == 0:
        return 0.0
    return round((merged_commits / files_changed) * (1.0 - collision_rate), 3)


def convergence_score(
    useful_outputs: float,
    leverage_total: float,
    duplicate_work: float,
    merge_cost: float,
    agent_minutes_total: float | None,
) -> float | dict[str, str]:
    if not agent_minutes_total or agent_minutes_total <= 0:
        return unknown("missing agent_minutes.total")
    numerator = useful_outputs + leverage_total - duplicate_work - merge_cost
    return round(numerator / agent_minutes_total, 4)


def filter_board_regs(
    board: dict[str, Any] | None, meta: dict[str, Any]
) -> list[dict[str, Any]]:
    if not board:
        return []
    regs = board.get("registrations") or []
    trial_branches = {a.get("branch") for a in meta.get("agents", []) if a.get("branch")}
    if trial_branches:
        filtered = [r for r in regs if r.get("branch") in trial_branches]
        if filtered:
            return filtered
    return regs


AREA_RULES = [
    (re.compile(r"auth|login|register|session|oauth", re.I), "auth"),
    (re.compile(r"upload|onboard|signup|activation", re.I), "upload-onboarding"),
    (re.compile(r"analytics|event|tracking|contract", re.I), "analytics"),
    (re.compile(r"match|results|hero|homepage|landing|conversion|matchcard", re.I), "homepage-conversion"),
    (re.compile(r"mobile|responsive", re.I), "mobile"),
    (re.compile(r"pricing|paywall|stripe|billing", re.I), "pricing"),
    (re.compile(r"performance|polling|visibility", re.I), "performance"),
    (re.compile(r"cron|internal|api/", re.I), "backend-api"),
    (re.compile(r"test|vitest|spec|suite", re.I), "test-infrastructure"),
    (re.compile(r"state/|arbiter|attention", re.I), "state-attention"),
]


def classify_work_area(text: str) -> str | None:
    if not text or not text.strip():
        return None
    for pattern, area in AREA_RULES:
        if pattern.search(text):
            return area
    if "/" in text and not text.startswith("."):
        parts = [p for p in text.split("/") if p and p not in ("src", "app", "lib", "components")]
        if parts:
            return parts[0].lower().replace("_", "-")
    return None


def compute_territory_spread(
    agents: list[AgentArtifacts],
    board_regs: list[dict[str, Any]],
    meta: dict[str, Any],
) -> dict[str, Any]:
    branch_to_role = {a.get("branch"): a.get("role") for a in meta.get("agents", []) if a.get("branch")}
    agent_areas: dict[str, set[str]] = {a.role: set() for a in agents}
    all_areas: set[str] = set()
    gaps: list[str] = []

    for art in agents:
        for fp in art.files_scored:
            area = classify_work_area(fp)
            if area:
                agent_areas[art.role].add(area)
        for fact in art.discovered_facts:
            area = classify_work_area(fact)
            if area:
                agent_areas[art.role].add(area)
        for area in extract_topics(art.stdout):
            classified = classify_work_area(area)
            if classified:
                agent_areas[art.role].add(classified)

    valid_roles = {a.role for a in agents}
    for reg in board_regs:
        branch = reg.get("branch") or ""
        role = branch_to_role.get(branch)
        if not role and branch:
            role = branch.rsplit("-", 1)[-1]
        if not role or role not in valid_roles:
            continue
        task = reg.get("task") or ""
        for text in (task, " ".join(reg.get("discoveredFacts") or [])):
            area = classify_work_area(text)
            if area:
                agent_areas.setdefault(role, set()).add(area)

    for role, areas in agent_areas.items():
        all_areas.update(areas)
        if not areas:
            gaps.append(f"{role}: no work area inferred")

    n_agents = len(agents)
    if n_agents == 0:
        return {**unknown("no agents in metadata"), "gaps": ["missing metadata agents"]}

    spread = round(len(all_areas) / n_agents, 3)
    return {
        "unique_areas": sorted(all_areas),
        "unique_area_count": len(all_areas),
        "agents": n_agents,
        "territory_spread": spread,
        "agent_areas": {k: sorted(v) for k, v in agent_areas.items()},
        "gaps": gaps,
    }


def compute_organizational_waste(
    dup: dict[str, Any],
    friction: dict[str, Any],
    minutes: dict[str, Any],
) -> dict[str, Any]:
    waste_rate = minutes.get("waste_rate")
    if minutes.get("status") == "UNKNOWN":
        waste_rate = None
    return {
        "duplicate_investigations": len(dup.get("duplicate_investigations", [])),
        "abandoned_commits": max(
            0,
            friction.get("proposed_commits", 0) - friction.get("merged_commits", 0),
        ),
        "merge_conflicts": friction.get("merge_conflicts", 0),
        "overlap_files": friction.get("overlap_files", 0),
        "waste_rate": waste_rate,
        "wasted_minutes": minutes.get("wasted"),
    }


def compute_cognitive_economics(
    agents: list[AgentArtifacts],
    dup: dict[str, Any],
    lev: dict[str, Any],
    friction: dict[str, Any],
    minutes: dict[str, Any],
) -> dict[str, Any]:
    """Shared-memory metrics: rediscovery vs compounding (not territory separation)."""
    topic_agents: dict[str, set[str]] = defaultdict(set)
    investigation_count = 0

    for art in agents:
        blob = art.stdout + "\n" + art.stderr + " ".join(art.discovered_facts)
        if INVESTIGATION_VERBS.search(blob) or art.files_scored:
            investigation_count += 1
        for topic in extract_topics(blob):
            if topic in BROAD_TOPICS and len(topic) < 4:
                continue
            topic_agents[topic].add(art.role)
        for fact in art.discovered_facts:
            for topic in extract_topics(fact):
                topic_agents[topic].add(art.role)

    dup_topics = {d["topic"] for d in dup.get("duplicate_investigations", [])}
    total_topics = len(topic_agents)
    unique_topics = sum(1 for agents_set in topic_agents.values() if len(agents_set) == 1)
    novel_contribution_rate = (
        round(unique_topics / total_topics, 3) if total_topics else None
    )

    dup_pairs = len(dup.get("duplicate_investigations", []))
    cognitive_duplication_rate = (
        round(dup_pairs / max(investigation_count, 1), 3)
        if investigation_count
        else None
    )

    lev_counts = lev.get("coordination_leverage", {})
    prior_context = lev_counts.get("prior_context_utilization", 0)
    compounding = lev_counts.get("compounding_events", 0)
    separation = lev_counts.get("separation_events", 0)
    lost_work = (
        max(0, friction.get("proposed_commits", 0) - friction.get("merged_commits", 0))
        + (minutes.get("wasted") or 0)
    )

    total_min = minutes.get("total")
    merged = friction.get("merged_commits", 0)
    output_per_agent_hour = None
    if total_min and total_min > 0:
        output_per_agent_hour = round(merged / (total_min / 60.0), 3)

    prior_context_rate = (
        round(prior_context / max(investigation_count, 1), 3)
        if investigation_count
        else None
    )

    return {
        "cognitive_duplication_rate": cognitive_duplication_rate,
        "novel_contribution_rate": novel_contribution_rate,
        "investigation_count": investigation_count,
        "duplicate_topic_count": dup_pairs,
        "prior_context_utilization": prior_context,
        "prior_context_utilization_rate": prior_context_rate,
        "prior_context_by_kind": lev_counts.get("compounding_by_kind", {}),
        "compounding_events": compounding,
        "separation_events": separation,
        "lost_work_signal": round(lost_work, 2) if isinstance(lost_work, (int, float)) else lost_work,
        "output_per_agent_hour": output_per_agent_hour,
        "waste_rate": minutes.get("waste_rate"),
        "trial_pillars": {
            "reduced_duplicate_cognition": cognitive_duplication_rate,
            "reduced_lost_work": minutes.get("waste_rate"),
            "prior_context_utilization": prior_context_rate,
        },
        "note": (
            "Compounding = informed work (reuse, inspect, validate, continue, avoid failed paths). "
            "Not staying away from occupied areas. Overlap is fine; uninformed duplication is not."
        ),
    }


def score_arm_v2(
    bench_dir: Path,
    trials_root: Path,
    harness: dict[str, Any] | None,
) -> dict[str, Any]:
    meta = load_json(bench_dir / "metadata.json") or {}
    trial_id = meta.get("trial_id") or bench_dir.name
    group = meta.get("group", "unknown")
    roles = [a["role"] for a in meta.get("agents", [])] or list(ROLES)

    log_dir = trial_log_dir(trials_root, trial_id)
    board = load_json(bench_dir / "radar" / "board.json") or {}
    board_regs = filter_board_regs(board, meta)

    agents = [
        load_agent_artifacts(bench_dir, log_dir, role, harness, board_regs)
        for role in roles
    ]
    estimate_agent_runtimes(agents, harness, meta)

    # Friction (v1)
    files_scored: set[str] = set()
    proposed = merged = 0
    for art in agents:
        files_scored.update(art.files_scored)
        if art.commit.get("first_attempt") not in (None, "skipped_no_changes"):
            proposed += 1
        if art.commit.get("committed"):
            merged += 1

    overlap_doc = load_json(bench_dir / "agents" / "file_overlap.json") or {}
    scored_multi = overlap_doc.get("files_touched_by_multiple_agents_scored") or {}
    overlap_files = len(scored_multi)

    merge_doc = load_json(bench_dir / "merge" / "conflicts.json") or {}
    merge_conflicts = sum(
        1 for m in (merge_doc.get("sequential_merge") or []) if not m.get("success")
    )
    collision_rate = round(overlap_files / len(files_scored), 3) if files_scored else 0.0

    dup = detect_duplicate_investigations(agents)
    lev = detect_coordination_leverage(agents, group)
    minutes = compute_agent_minutes(
        agents,
        harness,
        merge_doc,
        len(dup["duplicate_investigations"]),
        overlap_files,
    )

    leverage = lev["coordination_leverage"]
    # Prior context utilization only - separation is diagnostic, not credit.
    compounding_total = leverage.get("compounding_events", 0)
    if group == "no-radar":
        leverage_total = 0
        lev["role_boundary_signals"] = leverage.get("separation_events", 0)
    else:
        leverage_total = compounding_total
    dup_weight = sum(
        {"low": 0.5, "medium": 1.0, "high": 1.5}.get(d["severity"], 1.0)
        for d in dup["duplicate_investigations"]
    )
    merge_cost = merge_conflicts * 2.0 + overlap_files * 0.5
    useful_outputs = float(merged) + len(files_scored) * 0.25

    conv = convergence_score(
        useful_outputs, leverage_total, dup_weight, merge_cost, minutes.get("total")
    )

    friction = {
        "files_changed": len(files_scored),
        "overlap_files": overlap_files,
        "collision_rate": collision_rate,
        "merge_conflicts": merge_conflicts,
        "proposed_commits": proposed,
        "merged_commits": merged,
    }
    territory = compute_territory_spread(agents, board_regs, meta)
    org_waste = compute_organizational_waste(dup, friction, minutes)
    cognitive = compute_cognitive_economics(agents, dup, lev, friction, minutes)

    arm_wall = None
    if harness and harness.get("started_at") and harness.get("finished_at"):
        a, b = parse_ts(harness["started_at"]), parse_ts(harness["finished_at"])
        if a and b:
            arm_wall = round((b - a).total_seconds() / 60.0, 1)

    gaps_set = {g for a in agents for g in a.gaps}
    gaps_set.update(dup.get("gaps", []))
    gaps_set.update(lev.get("gaps", []))
    gaps_set.update(minutes.get("gaps") or [])
    if not log_dir:
        gaps_set.add(f"UNKNOWN: missing ~/radar-trials/{trial_id}/run-logs/")
    if not harness:
        gaps_set.add(f"UNKNOWN: missing harness.json for {trial_id}")
    gaps = sorted(gaps_set)

    return {
        "trial_id": trial_id,
        "group": group,
        "arm_wall_minutes": arm_wall,
        "agent_minutes": minutes,
        "duplicate_investigations": dup,
        "coordination_leverage": lev,
        "territory_spread": {**territory, "diagnostic_only": True},
        "organizational_waste": org_waste,
        "cognitive_economics": cognitive,
        "friction": friction,
        "legacy_efficiency": legacy_friction_score(
            merged, len(files_scored), collision_rate
        ),
        "convergence_score": conv,
        "convergence_score_components": {
            "useful_outputs": useful_outputs,
            "state_feedback_leverage": leverage_total,
            "duplicate_work": dup_weight,
            "merge_cost": merge_cost,
        },
        # Deprecated aliases (pre-v2 rename)
        "coordination_score": conv,
        "coordination_score_components": {
            "useful_outputs": useful_outputs,
            "coordination_leverage": leverage_total,
            "duplicate_work": dup_weight,
            "merge_cost": merge_cost,
        },
        "measurement_gaps": gaps,
    }


def compare_arms(no_radar: dict[str, Any], radar: dict[str, Any]) -> dict[str, Any]:
    def lift(key: str) -> float | None | dict[str, str]:
        nr = no_radar.get(key)
        rd = radar.get(key)
        if isinstance(nr, dict) and nr.get("status") == "UNKNOWN":
            return unknown(f"no-radar {key}: {nr.get('reason')}")
        if isinstance(rd, dict) and rd.get("status") == "UNKNOWN":
            return unknown(f"radar {key}: {rd.get('reason')}")
        if nr is None or rd is None:
            return unknown(f"missing {key}")
        if isinstance(nr, (int, float)) and isinstance(rd, (int, float)) and nr > 0:
            return round((rd - nr) / nr, 3)
        if isinstance(nr, (int, float)) and nr == 0:
            return None
        return None

    nr_score = no_radar.get("convergence_score") or no_radar.get("coordination_score")
    rd_score = radar.get("convergence_score") or radar.get("coordination_score")
    conv_lift = None
    if isinstance(nr_score, (int, float)) and isinstance(rd_score, (int, float)) and nr_score > 0:
        conv_lift = round((rd_score - nr_score) / nr_score, 3)
    elif isinstance(nr_score, dict) or isinstance(rd_score, dict):
        conv_lift = unknown("convergence_score incomplete for one or both arms")

    nr_legacy = no_radar.get("legacy_efficiency", 0)
    rd_legacy = radar.get("legacy_efficiency", 0)
    legacy_lift = None
    if nr_legacy > 0:
        legacy_lift = round((rd_legacy - nr_legacy) / nr_legacy, 3)

    return {
        "convergence_score_lift_pct": conv_lift,
        "coordination_score_lift_pct": conv_lift,
        "legacy_efficiency_lift_pct": legacy_lift,
        "waste_rate_delta": _delta(
            no_radar.get("cognitive_economics", {}).get("waste_rate"),
            radar.get("cognitive_economics", {}).get("waste_rate"),
        ),
        "territory_spread_delta": _delta(
            no_radar.get("territory_spread", {}).get("territory_spread")
            if isinstance(no_radar.get("territory_spread"), dict)
            else None,
            radar.get("territory_spread", {}).get("territory_spread")
            if isinstance(radar.get("territory_spread"), dict)
            else None,
        ),
        "duplicate_investigations_delta": len(
            radar.get("duplicate_investigations", {}).get("duplicate_investigations", [])
        ) - len(
            no_radar.get("duplicate_investigations", {}).get("duplicate_investigations", [])
        ),
        "cognitive_duplication_rate_delta": _delta(
            no_radar.get("cognitive_economics", {}).get("cognitive_duplication_rate"),
            radar.get("cognitive_economics", {}).get("cognitive_duplication_rate"),
        ),
        "compounding_events_delta": _delta(
            no_radar.get("cognitive_economics", {}).get("compounding_events"),
            radar.get("cognitive_economics", {}).get("compounding_events"),
        ),
        "prior_context_utilization_delta": _delta(
            no_radar.get("cognitive_economics", {}).get("prior_context_utilization"),
            radar.get("cognitive_economics", {}).get("prior_context_utilization"),
        ),
    }


def _delta(a: Any, b: Any) -> float | None:
    if a is None or b is None:
        return None
    return round(b - a, 3)


def score_line(arm: dict[str, Any]) -> str:
    cs = arm.get("convergence_score") or arm.get("coordination_score")
    if isinstance(cs, dict):
        return f"UNKNOWN ({cs.get('reason')})"
    return str(cs)


def _fmt_spread(arm: dict[str, Any]) -> str:
    ts = arm.get("territory_spread", {})
    if isinstance(ts, dict) and ts.get("status") == "UNKNOWN":
        return f"UNKNOWN ({ts.get('reason')})"
    if not isinstance(ts, dict):
        return "?"
    areas = ts.get("unique_area_count", 0)
    agents = ts.get("agents", "?")
    spread = ts.get("territory_spread", "?")
    return f"{spread} ({areas} areas / {agents} agents)"


def render_report(report: dict[str, Any]) -> str:
    base = report.get("trial_base", "trial")
    label = base[len("trial-") :] if base.startswith("trial-") else base
    cmp_ = report.get("comparison", {})
    nr = report["no_radar"]
    rd = report["radar"]

    conv_lift = cmp_.get("convergence_score_lift_pct") or cmp_.get("coordination_score_lift_pct")
    legacy_lift = cmp_.get("legacy_efficiency_lift_pct")

    def fmt_lift(v: Any) -> str:
        if isinstance(v, dict) and v.get("status") == "UNKNOWN":
            return f"UNKNOWN ({v.get('reason')})"
        if v is None:
            return "n/a"
        sign = "+" if v >= 0 else ""
        return f"{sign}{v * 100:.1f}%"

    def fmt_minutes(arm: dict[str, Any]) -> str:
        m = arm.get("agent_minutes", {})
        if m.get("status") == "UNKNOWN":
            return f"UNKNOWN ({m.get('reason')})"
        return (
            f"total {m.get('total', '?')} / productive {m.get('productive', '?')} / "
            f"wasted {m.get('wasted', '?')} ({(m.get('waste_rate') or 0) * 100:.1f}%)"
        )

    nce = nr.get("cognitive_economics", {})
    rce = rd.get("cognitive_economics", {})
    waste_delta = cmp_.get("waste_rate_delta")

    lines = [
        f"# Trial {label.upper()} Results",
        "",
        "## Summary",
        "",
        "**Question:** Do agents with shared memory avoid uninformed work - not just avoid work?",
        "",
        f"**Waste rate:** no-radar {(nce.get('waste_rate') or 0)*100:.1f}% → radar {(rce.get('waste_rate') or 0)*100:.1f}%"
        + (f" (Δ {waste_delta*100:.1f} pp)" if waste_delta is not None else ""),
        f"**Prior context utilization:** {nce.get('prior_context_utilization', 0)} → {rce.get('prior_context_utilization', 0)}",
        f"**Cognitive duplication rate:** {nce.get('cognitive_duplication_rate', '?')} → {rce.get('cognitive_duplication_rate', '?')}",
        "",
        "> Radar = shared working memory, not an AI manager. Awareness, not assignment. "
        "Two agents on auth is fine if the second one reads history and finishes the job. "
        "The failure mode is paying the same investigation cost twice because neither knew the other existed.",
        "",
        "## 1. Cognitive waste",
        "",
        "| | No Radar | Radar |",
        "|--|----------|-------|",
        f"| Waste rate | {(nce.get('waste_rate') or 0)*100:.1f}% | {(rce.get('waste_rate') or 0)*100:.1f}% |",
        f"| Wasted agent-min | {nr.get('agent_minutes', {}).get('wasted', '?')} | {rd.get('agent_minutes', {}).get('wasted', '?')} |",
        f"| Duplicate investigations | {nce.get('duplicate_topic_count', '?')} | {rce.get('duplicate_topic_count', '?')} |",
        f"| Cognitive duplication rate | {nce.get('cognitive_duplication_rate', '?')} | {rce.get('cognitive_duplication_rate', '?')} |",
        f"| Abandoned commits | {nr.get('organizational_waste', {}).get('abandoned_commits', 0)} | {rd.get('organizational_waste', {}).get('abandoned_commits', 0)} |",
        "",
        "## 2. Prior context utilization (compounding)",
        "",
        "Counts informed work: reused discovery, inspected before starting, validated/extended work, "
        "continued unfinished work, avoided known failed paths. **Separation is not credited.**",
        "",
        f"**No Radar:** prior context events {nce.get('prior_context_utilization', 0)}",
        f"**Radar:** prior context events {rce.get('prior_context_utilization', 0)} "
        f"(rate {rce.get('prior_context_utilization_rate', '?')})",
        "",
    ]

    by_kind = rce.get("prior_context_by_kind") or {}
    if by_kind:
        lines.append("**Radar by kind:**")
        for kind, count in sorted(by_kind.items()):
            lines.append(f"- {kind.replace('_', ' ')}: {count}")
        lines.append("")

    lev = rd.get("coordination_leverage", {})
    sep = lev.get("coordination_leverage", {}).get("separation_events", 0)
    if sep:
        lines.extend(
            [
                f"*(Diagnostic only - separation events: {sep}; not scored as success)*",
                "",
            ]
        )

    lines.extend(
        [
            "## 3. Output efficiency",
            "",
            f"**No Radar:** {nce.get('output_per_agent_hour', '?')} commits / agent-hour | commits {nr.get('friction', {}).get('merged_commits')}/{nr.get('friction', {}).get('proposed_commits')}",
            f"**Radar:** {rce.get('output_per_agent_hour', '?')} commits / agent-hour | commits {rd.get('friction', {}).get('merged_commits')}/{rd.get('friction', {}).get('proposed_commits')}",
            "",
            "## Diagnostic: territory spread (overlap ≠ waste)",
            "",
            f"- No Radar: {_fmt_spread(nr)}",
            f"- Radar: {_fmt_spread(rd)}",
            "",
            "## Legacy scores (ignore lift % on short runs)",
            "",
            f"- Convergence score lift: {fmt_lift(conv_lift)}",
            f"- Legacy efficiency lift: {fmt_lift(legacy_lift)}",
            "",
        ]
    )

    # Duplicate details
    for arm_name, arm in ("No Radar", nr), ("Radar", rd):
        dups = arm.get("duplicate_investigations", {}).get("duplicate_investigations", [])
        if dups:
            lines.append(f"### Duplicate investigations ({arm_name})")
            lines.append("")
            for d in dups:
                lines.append(
                    f"- **{d['topic']}** - agents: {', '.join(d['agents'])} "
                    f"({d['severity']})"
                )
            lines.append("")

    lev = rd.get("coordination_leverage", {})
    if lev.get("prior_context_details"):
        lines.extend(["### Radar prior-context signals", ""])
        for h in lev["prior_context_details"][:5]:
            kind = h.get("kind", "unknown").replace("_", " ")
            lines.append(f"- `{h['agent']}` ({kind}): …{h['excerpt']}…")
        lines.append("")

    gaps = sorted(
        set(nr.get("measurement_gaps", [])) | set(rd.get("measurement_gaps", []))
    )
    lines.extend(
        [
            "## Interpretation",
            "",
            "### What this data can prove",
            "- Mechanical friction: file overlap, merge conflicts, commit survival.",
            "- Agent-minute waste estimates when harness timestamps exist.",
            "- Heuristic duplicate investigation topics from stdout/diffs/board facts.",
            "- Prior context utilization signals when agents reuse, inspect, validate, or continue informed work (radar arm).",
            "",
            "### What this data does NOT prove",
            "- Code quality or correctness (no CI gate in these trials unless collected).",
            "- Causal Radar effect when board is contaminated or runtime is too short.",
            "- Token-dollar economics (subscription billing not captured per agent).",
            "- Full cognition leverage without richer transcripts / per-agent end times.",
            "",
        ]
    )

    waste_delta = cmp_.get("waste_rate_delta")
    if waste_delta is not None and waste_delta > 0:
        lines.extend(
            [
                "### Caution",
                "",
                f"Radar waste rate is **higher** by {waste_delta * 100:.1f} percentage points "
                "in this trial - convergence score lift may reflect leverage heuristics, "
                "not reduced waste. Treat short/contaminated runs as scorer validation only.",
                "",
            ]
        )
    if gaps:
        lines.extend(["### Measurement gaps", ""])
        for g in gaps:
            lines.append(f"- {g}")
        lines.append("")

    lines.append(f"_Scored at {report.get('scored_at', '')}_")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Radar harness scorer v2")
    parser.add_argument("--trial", help="Trial base id e.g. trial-002")
    parser.add_argument("--radar", type=Path, help="Radar harness dir")
    parser.add_argument("--no-radar", type=Path, help="No-radar benchmark dir")
    parser.add_argument("--bench-root", type=Path, default=Path.home() / "radar-benchmarks")
    parser.add_argument("--trials-root", type=Path, default=Path.home() / "radar-trials")
    parser.add_argument("--out", type=Path, help="Write score JSON")
    parser.add_argument("--report", type=Path, help="Write trial-report.md")
    args = parser.parse_args()

    if args.trial:
        radar_dir = args.bench_root / f"{args.trial}-radar"
        no_radar_dir = args.bench_root / f"{args.trial}-no-radar"
        trial_base = args.trial
    else:
        if not args.radar or not args.no_radar:
            parser.error("--trial or both --radar and --no-radar required")
        radar_dir = args.radar
        no_radar_dir = args.no_radar
        trial_base = radar_dir.name.replace("-radar", "")

    if not radar_dir.is_dir():
        print(f"error: radar dir not found: {radar_dir}", file=sys.stderr)
        return 1
    if not no_radar_dir.is_dir():
        print(f"error: no-radar dir not found: {no_radar_dir}", file=sys.stderr)
        return 1

    radar_meta = load_json(radar_dir / "metadata.json") or {}
    no_meta = load_json(no_radar_dir / "metadata.json") or {}
    radar_id = radar_meta.get("trial_id") or f"{trial_base}-radar"
    no_id = no_meta.get("trial_id") or f"{trial_base}-no-radar"

    def harness(trial_id: str) -> dict[str, Any] | None:
        return load_json(args.trials_root / trial_id / "run-logs" / "harness.json")

    no_radar = score_arm_v2(no_radar_dir, args.trials_root, harness(no_id))
    radar = score_arm_v2(radar_dir, args.trials_root, harness(radar_id))

    report = {
        "scorer_version": 2,
        "scored_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "trial_base": trial_base,
        "no_radar": no_radar,
        "radar": radar,
        "comparison": compare_arms(no_radar, radar),
        # v1 compatibility
        "scorecard": {
            "headline": {
                "no_radar_efficiency": no_radar.get("legacy_efficiency"),
                "radar_efficiency": radar.get("legacy_efficiency"),
                "radar_lift_pct": compare_arms(no_radar, radar).get(
                    "legacy_efficiency_lift_pct"
                ),
                "convergence_score_lift_pct": compare_arms(no_radar, radar).get(
                    "convergence_score_lift_pct"
                ),
                "coordination_score_lift_pct": compare_arms(no_radar, radar).get(
                    "convergence_score_lift_pct"
                ),
            },
        },
    }

    text = json.dumps(report, indent=2) + "\n"
    if args.out:
        args.out.write_text(text)
    else:
        print(text, end="")

    md = render_report(report)
    if args.report:
        args.report.write_text(md)
    else:
        print(md, end="")

    return 0


if __name__ == "__main__":
    sys.exit(main())
