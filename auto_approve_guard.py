#!/usr/bin/env python3
"""
auto_approve_guard.py — PermissionRequest hook for Context Guard.

Only auto-approves the narrow operations Context Guard needs during handoff:
- Write/Edit/MultiEdit files under ~/.claude/context-guard
- Legacy Bash marker writes like: echo ... > ~/.claude/context-guard/next_prompt

All other permission requests are left untouched by producing no output.
"""

import json
import os
import shlex
import sys
from pathlib import Path


def state_dir() -> Path:
    return Path(
        os.environ.get(
            "CONTEXT_GUARD_STATE_DIR",
            os.path.expanduser("~/.claude/context-guard"),
        )
    ).expanduser()


def normalize_path(path: str, cwd: str | None = None) -> Path:
    p = Path(path).expanduser()
    if not p.is_absolute():
        p = Path(cwd or os.getcwd()) / p
    return p.resolve(strict=False)


def is_inside(path: Path, directory: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(directory.resolve(strict=False))
        return True
    except ValueError:
        return False


def approve(reason: str) -> None:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "allow"},
                },
                "suppressOutput": True,
                "systemMessage": reason,
            },
            ensure_ascii=False,
        )
    )


def get_tool_path(tool_name: str, tool_input: object) -> str | None:
    if not isinstance(tool_input, dict):
        return None
    if tool_name in {"Write", "Edit", "MultiEdit"}:
        value = tool_input.get("file_path")
        return value if isinstance(value, str) else None
    return None


def bash_redirect_target(command: str) -> str | None:
    try:
        parts = shlex.split(command, posix=True)
    except ValueError:
        return None

    if not parts or parts[0] not in {"echo", "printf"}:
        return None

    target = None
    for i, part in enumerate(parts):
        if part in {">", "1>"} and i + 1 < len(parts):
            target = parts[i + 1]
        elif part.startswith(">") and len(part) > 1:
            target = part[1:]
        elif part.startswith("1>") and len(part) > 2:
            target = part[2:]

    return target


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    cwd = data.get("cwd")
    guard_dir = state_dir().resolve(strict=False)

    file_path = get_tool_path(tool_name, tool_input)
    if file_path:
        target = normalize_path(file_path, cwd if isinstance(cwd, str) else None)
        if is_inside(target, guard_dir):
            approve("Context Guard handoff file write auto-approved")
        return 0

    if tool_name == "Bash" and isinstance(tool_input, dict):
        command = tool_input.get("command")
        if isinstance(command, str):
            target_raw = bash_redirect_target(command)
            if target_raw:
                target = normalize_path(target_raw, cwd if isinstance(cwd, str) else None)
                if target.name == "next_prompt" and is_inside(target, guard_dir):
                    approve("Context Guard restart marker write auto-approved")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
