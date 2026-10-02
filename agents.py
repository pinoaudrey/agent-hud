"""Detect currently running claude / codex / opencode / gemini sessions.

Claude Code announces itself: every live session, terminal or Desktop app,
writes `<tree>/sessions/<pid>.json` with its transcript id, working directory,
status, and name. Those records are the source for Claude, checked against the
process table so a record left behind by a dead process (or one whose pid has
since been reused) never reports as a session.

The other CLIs say nothing on disk, so they come from a scan of the process
table for the binaries with a real controlling terminal (which filters out
desktop apps, dev servers, and crashpad helpers), with each process's working
directory resolved so the dashboard can match it back to a session title.
"""

from __future__ import annotations

import glob
import json
import os
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from activity import claude_status, claude_title
from subscriptions import config_trees

_TOOL_PATTERNS = {
    "codex": re.compile(r"(?:^|\s|/)codex(?:\s|$)"),
    "opencode": re.compile(r"(?:^|\s|/)opencode(?:\s|$)"),
    # Gemini is a Node CLI, so a running session shows up as
    # `node .../@google/gemini-cli/bundle/gemini.js`; match the entrypoint
    # filename (and the bare `gemini` command) rather than a native binary.
    "gemini": re.compile(r"(?:^|\s|/)gemini(?:-cli)?(?:\.js)?(?:\s|$)"),
}

# lines that look like a match but aren't an interactive agent session
_EXCLUDE = re.compile(r"agenthud|grep|pgrep|/bin/z?sh -c|/bin/ba?sh -c|-z?sh\b|--version|--help")

# Claude Code entrypoints that never wait on a person. An SDK run is headless,
# so listing it would only add sessions nobody can bring forward.
_HEADLESS_ENTRYPOINTS = {"sdk-cli"}


@dataclass
class RunningAgent:
    tool: str
    pid: int
    tty: str
    elapsed: str  # friendly: "4h 12m"
    cwd: str
    title: str = ""  # what to call the session ("" when the tool gives no way to tell)
    session_id: str = ""  # exact transcript id when the tool exposes one
    # live activity: claude's comes with its session record, the rest is filled
    # in by activity.enrich (defaults = not-yet-known)
    state: str = "unknown"  # "working" | "idle" | "waiting" | "unknown"
    label: str = ""  # current action, e.g. "running command"
    tokens: int = 0  # live token count for this session (0 if unknown)
    surface: str = "terminal"  # "terminal" | "desktop" (the Claude Desktop app)
    state_since: datetime | None = None  # when `state` last changed (None if unknown)


def _elapsed(etime: str) -> str:
    """ps etime is [[dd-]hh:]mm:ss; compress to '2d 4h' / '4h 12m' / '12m'."""
    days = 0
    if "-" in etime:
        day_part, etime = etime.split("-", 1)
        days = int(day_part)
    parts = [int(p) for p in etime.split(":")]
    if len(parts) == 3:
        hours, minutes = parts[0], parts[1]
    elif len(parts) == 2:
        hours, minutes = 0, parts[0]
    else:
        hours, minutes = 0, 0
    total_min = days * 24 * 60 + hours * 60 + minutes
    if total_min >= 24 * 60:
        return f"{total_min // (24 * 60)}d {(total_min % (24 * 60)) // 60}h"
    if total_min >= 60:
        return f"{total_min // 60}h {total_min % 60}m"
    return f"{max(total_min, 1)}m"


def _parse_ps(output: str) -> list[RunningAgent]:
    agents = []
    codex_ttys: set[str] = set()
    for line in output.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        pid, tty, etime, cmdline = parts
        if tty == "??" or _EXCLUDE.search(cmdline):
            continue
        for tool, pattern in _TOOL_PATTERNS.items():
            if pattern.search(cmdline):
                # The Codex CLI is a Node wrapper around a native binary. Both
                # processes share the terminal, but represent one interactive
                # session. `ps ax` is PID ordered, so the wrapper arrives first.
                if tool == "codex" and tty in codex_ttys:
                    break
                agents.append(
                    RunningAgent(tool=tool, pid=int(pid), tty=tty, elapsed=_elapsed(etime), cwd="")
                )
                if tool == "codex":
                    codex_ttys.add(tty)
                break
    return agents


def _cwd_for_pid(pid: int) -> str:
    try:
        out = subprocess.run(
            ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    for line in out.stdout.splitlines():
        if line.startswith("n/"):
            return line[1:]
    return ""


def _read_json(path: str | Path) -> dict | None:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _process_table(pids: list[int]) -> dict[int, tuple[str, str, str]]:
    """pid -> (tty, etime, lstart) for each pid that is alive right now.

    `lstart` is read in UTC with the C locale, because that is how Claude Code
    writes the `procStart` it compares against ("Fri Oct  2 16:17:44 2026")."""
    if not pids:
        return {}
    try:
        out = subprocess.run(
            ["ps", "-o", "pid=,tty=,etime=,lstart=", "-p", ",".join(str(p) for p in pids)],
            capture_output=True,
            text=True,
            timeout=5,
            env={**os.environ, "TZ": "UTC", "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    table = {}
    for line in out.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0].isdigit():
            table[int(parts[0])] = (parts[1], parts[2], " ".join(parts[3].split()))
    return table


def _parse_lstart(text: str) -> float | None:
    try:
        began = datetime.strptime(text, "%a %b %d %H:%M:%S %Y")
    except ValueError:
        return None
    return began.replace(tzinfo=timezone.utc).timestamp()


def _same_process(record: dict, lstart: str) -> bool:
    """Whether the live process at this pid is the one that wrote the record.

    pids are reused, so liveness alone would let a stale record describe some
    unrelated process. `procStart` is the process start time as `ps` prints it,
    so an exact match settles it. A record without one falls back to a sanity
    check: the process must have started no later than the session did, which
    a reused pid (started afterwards) fails."""
    proc_start = record.get("procStart")
    if isinstance(proc_start, str) and proc_start.strip():
        return " ".join(proc_start.split()) == lstart
    started_ms = record.get("startedAt")
    began = _parse_lstart(lstart)
    if not isinstance(started_ms, (int, float)) or began is None:
        return False
    return began <= started_ms / 1000 + 1  # lstart has one-second resolution


def claude_sessions(trees: list[str | Path]) -> list[RunningAgent]:
    """Every live interactive Claude Code session across the given config trees,
    from the per-pid records Claude Code writes, with status and title attached."""
    records: dict[int, tuple[dict, Path]] = {}
    for tree in trees:
        for path in glob.glob(str(Path(tree) / "sessions" / "*.json")):
            stem = Path(path).stem
            if not stem.isdigit():
                continue
            record = _read_json(path)
            if not record or record.get("entrypoint") in _HEADLESS_ENTRYPOINTS:
                continue
            records.setdefault(int(stem), (record, Path(tree)))
    table = _process_table(sorted(records))
    agents = []
    for pid, (record, tree) in records.items():
        proc = table.get(pid)
        if proc is None or not _same_process(record, proc[2]):
            continue
        tty, etime, _ = proc
        desktop = record.get("entrypoint") == "claude-desktop"
        status = claude_status(record)
        cwd = record.get("cwd") if isinstance(record.get("cwd"), str) else ""
        agents.append(RunningAgent(
            tool="claude",
            pid=pid,
            tty="" if desktop or tty in ("??", "-") else tty,
            elapsed=_elapsed(etime),
            cwd=cwd,
            title=claude_title(record, tree),
            session_id=status.session_id,
            state=status.state,
            label=status.label,
            surface="desktop" if desktop else "terminal",
            state_since=status.since,
        ))
    return agents


def running_agents(trees: list[str | Path] | None = None) -> list[RunningAgent]:
    """Claude sessions from their per-pid records in every config tree, plus
    the other CLIs from the process table."""
    agents = claude_sessions(config_trees() if trees is None else trees)
    try:
        out = subprocess.run(
            ["ps", "ax", "-o", "pid=,tty=,etime=,command=", "-ww"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        out = None
    if out is not None:
        for agent in _parse_ps(out.stdout):
            agent.cwd = _cwd_for_pid(agent.pid)
            agents.append(agent)
    agents.sort(key=lambda a: (a.tool, a.pid))
    return agents
