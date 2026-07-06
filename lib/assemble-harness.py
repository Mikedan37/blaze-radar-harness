#!/usr/bin/env python3
"""Assemble run-trial.sh harness.json from per-agent provenance files."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def discover_roles(logdir: Path, meta: dict[str, Any]) -> list[str]:
    if meta.get("agent_roles"):
        return list(meta["agent_roles"])
    agents_list = logdir / "agents.list"
    if agents_list.is_file():
        return [line.strip() for line in agents_list.read_text().splitlines() if line.strip()]
    roles = []
    for d in sorted(logdir.iterdir()):
        if d.is_dir() and (d / "started_at").is_file():
            roles.append(d.name)
    return roles or ["feature", "tests", "audit"]


def main() -> None:
    if len(sys.argv) != 4:
        print(
            "usage: assemble-harness.py LOGDIR META_JSON OUT_JSON",
            file=sys.stderr,
        )
        sys.exit(1)

    logdir = Path(sys.argv[1])
    meta = json.loads(Path(sys.argv[2]).read_text())
    out_path = Path(sys.argv[3])

    agents: dict[str, Any] = {}
    for role in discover_roles(logdir, meta):
        role_dir = logdir / role
        entry: dict[str, Any] = {}
        commit = load_json(role_dir / "commit.json")
        if commit:
            entry["commit"] = commit
        bootstrap = load_json(role_dir / "coordination_bootstrap.json")
        if bootstrap:
            entry["coordination_bootstrap"] = bootstrap
        claude_exit = role_dir / "claude.exit"
        if claude_exit.is_file():
            entry["claude_exit"] = int(claude_exit.read_text().strip() or "0")
        if entry:
            agents[role] = entry

    meta["agents"] = agents
    postflight = load_json(logdir / "postflight.json")
    if postflight:
        meta["postflight"] = postflight

    out_path.write_text(json.dumps(meta, indent=2) + "\n")


if __name__ == "__main__":
    main()
