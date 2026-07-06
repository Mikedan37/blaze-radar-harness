#!/usr/bin/env python3
"""Read Radar hook-activity telemetry for trial harness provenance."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def canonical_path(path: str) -> str:
    return os.path.realpath(os.path.expanduser(path))


def git_common_dir(workspace: str) -> str:
    workspace = canonical_path(workspace)
    try:
        out = subprocess.check_output(
            ["git", "-C", workspace, "rev-parse", "--git-common-dir"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return workspace
    if not os.path.isabs(out):
        out = os.path.join(workspace, out)
    return canonical_path(out)


def workspace_hash(workspace: str) -> str:
    key = git_common_dir(workspace)
    digest = hashlib.sha256(key.encode("utf-8")).digest()
    return "".join(f"{b:02x}" for b in digest[:3])


def hook_activity_dir(workspace: str) -> Path:
    home = Path.home()
    ws_hash = workspace_hash(workspace)
    return home / ".blaze" / "radar" / "workspaces" / ws_hash / "hook-activity"


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def read_latest_hook_activity(workspace: str) -> dict[str, Any]:
    """Return newest hook activity timestamps for a workspace."""
    directory = hook_activity_dir(workspace)
    best: dict[str, datetime | None] = {
        "lastSessionStart": None,
        "lastPromptSubmit": None,
        "lastPreEdit": None,
        "lastSync": None,
    }
    if not directory.is_dir():
        return {k: None for k in best}

    for path in directory.glob("*.json"):
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        for key in best:
            ts = _parse_iso(data.get(key))
            if ts is None:
                continue
            if best[key] is None or ts > best[key]:
                best[key] = ts

    return {k: (v.isoformat() if v else None) for k, v in best.items()}


def hook_fired_after(activity: dict[str, Any], field: str, since_iso: str) -> bool:
    since = _parse_iso(since_iso)
    ts = _parse_iso(activity.get(field))
    if since is None or ts is None:
        return False
    return ts > since


def coordination_bootstrap_report(
    workspace: str,
    started_at: str,
    before: dict[str, Any],
    after: dict[str, Any],
    manual_sync: bool,
    manual_sync_exit: int | None,
) -> dict[str, Any]:
    return {
        "manual_sync": manual_sync,
        "manual_sync_exit": manual_sync_exit,
        "user_prompt_hook": hook_fired_after(after, "lastPromptSubmit", started_at),
        "session_start_hook": hook_fired_after(after, "lastSessionStart", started_at),
        "hook_activity": {
            "before": before,
            "after_claude": after,
        },
    }


def cmd_snapshot(workspace: str) -> None:
    print(json.dumps(read_latest_hook_activity(workspace), indent=2))


def cmd_bootstrap(args: list[str]) -> None:
  # bootstrap WORKSPACE STARTED_AT BEFORE_JSON AFTER_JSON MANUAL_SYNC [SYNC_EXIT]
    if len(args) < 5:
        print("usage: bootstrap WORKSPACE STARTED_AT BEFORE_JSON AFTER_JSON MANUAL_SYNC [SYNC_EXIT]", file=sys.stderr)
        sys.exit(1)
    workspace, started_at, before_s, after_s, manual_sync_s = args[:5]
    sync_exit = int(args[5]) if len(args) > 5 and args[5] != "" else None
    before = json.loads(before_s)
    after = json.loads(after_s)
    manual_sync = manual_sync_s.lower() in ("1", "true", "yes")
    report = coordination_bootstrap_report(
        workspace, started_at, before, after, manual_sync, sync_exit
    )
    print(json.dumps(report, indent=2))


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: hook-telemetry.py snapshot WORKSPACE | bootstrap ...", file=sys.stderr)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "snapshot":
        if len(sys.argv) != 3:
            print("usage: hook-telemetry.py snapshot WORKSPACE", file=sys.stderr)
            sys.exit(1)
        cmd_snapshot(sys.argv[2])
    elif cmd == "bootstrap":
        cmd_bootstrap(sys.argv[2:])
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
