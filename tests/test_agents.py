"""Tests for running-agent detection: the ps scan for the terminal CLIs and the
per-pid session records Claude Code writes."""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))


# ---------------------------------------------------------------- agents


def test_parse_ps_detects_only_terminal_agents():
    from agents import _parse_ps

    ps_output = """\
 64028 ttys003   01:48:12 opencode
 59001 ttys005      12:03 /Users/josephtutera/.local/bin/claude --resume abc-123
 59002 ttys005      12:03 /bin/zsh -c codex --resume abc-123
  1046 ??      07-09:23:04 /Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler --monitor-self
 30591 ??      07-03:02:18 node /Users/x/Repos/prototype-ehr/.claude/worktrees/foo/platform/node_modules/.bin/../tsx/dist/cli.mjs watch src/index.ts
 60200 ttys007      03:45 node /Users/josephtutera/.nvm/versions/node/v24.14.1/bin/codex
 61000 ttys008      01:10 nvim claude.md
"""
    agents = _parse_ps(ps_output)
    tools = sorted(a.tool for a in agents)
    # claude comes from its session records instead; shell wrapper, desktop app,
    # dev server, and editor are all excluded
    assert tools == ["codex", "opencode"]
    opencode = next(a for a in agents if a.tool == "opencode")
    assert opencode.pid == 64028
    assert opencode.tty == "ttys003"
    assert opencode.elapsed == "1h 48m"


def test_parse_ps_keeps_one_codex_agent_per_terminal():
    from agents import _parse_ps

    ps_output = """\
 60200 ttys007      03:45 node /Users/josephtutera/.nvm/versions/node/v24.14.1/bin/codex
 60201 ttys007      03:45 /Users/josephtutera/.nvm/versions/node/v24.14.1/lib/node_modules/@openai/codex/vendor/bin/codex
"""

    agents = _parse_ps(ps_output)

    assert [(agent.tool, agent.pid, agent.tty) for agent in agents] == [("codex", 60200, "ttys007")]


def test_elapsed_formatting():
    from agents import _elapsed

    assert _elapsed("12:03") == "12m"
    assert _elapsed("01:48:12") == "1h 48m"
    assert _elapsed("07-09:23:04") == "7d 9h"


# ---------------------------------------------------------------- claude records

# What Claude Code writes for a live session, trimmed to the fields read here.
_PROC_START = "Fri Oct  2 16:17:44 2026"


def _record(pid: int, **kw) -> dict:
    record = {
        "pid": pid,
        "sessionId": f"sess-{pid}",
        "cwd": "/Users/you/Repos/web-app",
        "startedAt": 1790957865918,
        "procStart": _PROC_START,
        "entrypoint": "cli",
        "status": "idle",
        "statusUpdatedAt": 1790963152570,
    }
    record.update(kw)
    return record


def _write_records(tree: Path, *records: dict) -> None:
    (tree / "sessions").mkdir(parents=True, exist_ok=True)
    for record in records:
        (tree / "sessions" / f"{record['pid']}.json").write_text(json.dumps(record))
    # the encryption key Claude Code keeps beside each record is not a record
    (tree / "sessions" / "1.abcdef.key").write_text("secret")


class _Result:
    def __init__(self, stdout: str):
        self.stdout = stdout


def _fake_ps(monkeypatch: pytest.MonkeyPatch, rows: dict[int, tuple[str, str, str]]):
    """Answer the `ps -p` liveness query with `rows` (pid -> tty, etime,
    lstart); any pid not listed is dead. Records the env it was asked under."""
    import agents as agents_module

    calls = []

    def fake_run(cmd, **kwargs):
        if cmd[0] == "ps" and "-p" in cmd:
            calls.append(kwargs.get("env") or {})
            wanted = {int(p) for p in cmd[cmd.index("-p") + 1].split(",")}
            return _Result("".join(
                f"{pid} {tty} {etime} {lstart}\n"
                for pid, (tty, etime, lstart) in rows.items() if pid in wanted
            ))
        return _Result("")

    monkeypatch.setattr(agents_module.subprocess, "run", fake_run)
    return calls


def test_claude_sessions_keep_desktop_and_drop_headless(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from agents import claude_sessions

    tree = tmp_path / ".claude"
    _write_records(
        tree,
        _record(100, entrypoint="cli", status="waiting", waitingFor="input needed"),
        _record(200, entrypoint="claude-desktop", status="busy"),
        _record(300, entrypoint="sdk-cli", status="busy"),  # headless, never waits on you
    )
    calls = _fake_ps(monkeypatch, {
        100: ("ttys012", "12:03", _PROC_START),
        200: ("??", "01:48:12", _PROC_START),
        300: ("??", "05:00", _PROC_START),
    })

    agents = {a.pid: a for a in claude_sessions([tree])}
    assert sorted(agents) == [100, 200]
    cli, desktop = agents[100], agents[200]
    assert (cli.surface, cli.tty, cli.state, cli.label) == ("terminal", "ttys012", "waiting", "input needed")
    assert (desktop.surface, desktop.tty, desktop.state) == ("desktop", "", "working")
    assert cli.session_id == "sess-100" and cli.cwd == "/Users/you/Repos/web-app"
    assert cli.elapsed == "12m"
    assert cli.state_since == datetime.fromtimestamp(1790963152.570, tz=timezone.utc)
    # procStart is written in UTC, so the comparison must read lstart in UTC too
    assert calls and calls[0].get("TZ") == "UTC"


def test_claude_sessions_drop_dead_and_reused_pids(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from agents import claude_sessions

    tree = tmp_path / ".claude"
    _write_records(
        tree,
        _record(100),  # the process is gone; the record was left behind
        _record(200),  # pid alive, but it is some newer process reusing it
        _record(300),  # the real thing
    )
    _fake_ps(monkeypatch, {
        200: ("ttys002", "00:30", "Fri Oct  2 18:00:00 2026"),
        300: ("ttys003", "00:30", "Fri Oct 2 16:17:44 2026"),  # spacing differs, same time
    })
    assert [a.pid for a in claude_sessions([tree])] == [300]


def test_claude_sessions_without_proc_start_check_the_start_time(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from agents import claude_sessions

    tree = tmp_path / ".claude"
    started_ms = int(datetime(2026, 10, 2, 16, 17, 45, tzinfo=timezone.utc).timestamp() * 1000)
    old = _record(100, startedAt=started_ms)
    reused = _record(200, startedAt=started_ms)
    del old["procStart"], reused["procStart"]
    _write_records(tree, old, reused)
    _fake_ps(monkeypatch, {
        100: ("ttys001", "00:30", "Fri Oct  2 16:17:44 2026"),  # started before the session did
        200: ("ttys002", "00:30", "Fri Oct  2 19:00:00 2026"),  # started after it: a reused pid
    })
    assert [a.pid for a in claude_sessions([tree])] == [100]


def test_claude_sessions_read_every_config_tree(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    from agents import claude_sessions

    _write_records(tmp_path / ".claude", _record(100))
    _write_records(tmp_path / "cswap-profile", _record(200, entrypoint="claude-desktop"))
    _fake_ps(monkeypatch, {
        100: ("ttys001", "00:30", _PROC_START),
        200: ("??", "00:30", _PROC_START),
    })
    found = claude_sessions([tmp_path / ".claude", tmp_path / "cswap-profile"])
    assert sorted(a.pid for a in found) == [100, 200]


def test_running_agents_joins_claude_records_and_the_ps_scan(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    import agents as agents_module

    tree = tmp_path / ".claude"
    _write_records(tree, _record(56817, sessionId="sess-4b5d", name="Fix the login", nameSource="user"))

    def fake_run(cmd, **kwargs):
        if cmd[0] == "ps" and "-p" in cmd:
            return _Result(f"56817 ttys003 05:00 {_PROC_START}\n")
        if cmd[0] == "ps":
            # the terminal claude shows up in ps too; its record is what counts
            return _Result("56817 ttys003 05:00 claude\n60200 ttys007 03:45 codex\n")
        if cmd[0] == "lsof":
            return _Result("p60200\nn/Users/josephtutera/Repos/api\n")
        return _Result("")

    monkeypatch.setattr(agents_module.subprocess, "run", fake_run)
    agents = agents_module.running_agents([tree])
    assert [(a.tool, a.pid) for a in agents] == [("claude", 56817), ("codex", 60200)]
    assert agents[0].session_id == "sess-4b5d" and agents[0].title == "Fix the login"
    assert agents[1].cwd == "/Users/josephtutera/Repos/api" and agents[1].surface == "terminal"
