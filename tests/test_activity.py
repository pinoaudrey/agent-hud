"""Tests for live agent activity: the per-tool status readers and enrich()."""

from __future__ import annotations

import json
import os
import sys
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import _write_jsonl

from activity import codex_status_for_file


# ---------------------------------------------------------------- live activity


def test_claude_status_maps_each_status_word():
    from activity import claude_status

    assert claude_status({"status": "busy"}).state == "working"
    assert claude_status({"status": "idle"}).state == "idle"
    assert claude_status({}).state == "unknown"

    waiting = claude_status({
        "sessionId": "S1", "status": "waiting", "waitingFor": "input needed",
        "statusUpdatedAt": 1790963152570,
    })
    assert waiting.state == "waiting"
    assert waiting.label == "input needed"  # what it waits for is the action
    assert waiting.session_id == "S1"
    assert waiting.since == datetime.fromtimestamp(1790963152.570, tz=timezone.utc)

    # a stale waitingFor on a session that has moved on is not its action
    assert claude_status({"status": "busy", "waitingFor": "input needed"}).label == ""


def _transcript(tree: Path, cwd: str, sid: str, lines: list[dict]) -> Path:
    from activity import claude_transcript_path

    path = claude_transcript_path(tree, cwd, sid)
    _write_jsonl(path, lines)
    return path


def test_claude_transcript_path_matches_claude_code_layout(tmp_path: Path):
    from activity import claude_transcript_path

    path = claude_transcript_path(tmp_path, "/Users/you/.agents/web.app", "S1")
    assert path == tmp_path / "projects" / "-Users-you--agents-web-app" / "S1.jsonl"


def test_claude_title_fallback_order(tmp_path: Path):
    from activity import claude_title

    cwd = "/Users/you/Repos/web-app"
    base = {"sessionId": "S1", "cwd": cwd}
    _transcript(tmp_path, cwd, "S1", [
        {"type": "ai-title", "aiTitle": "Old title", "sessionId": "S1"},
        {"type": "user", "message": {"role": "user", "content": "hello"}},
        {"type": "ai-title", "aiTitle": "Fix the login redirect", "sessionId": "S1"},
        {"type": "last-prompt", "lastPrompt": "now add a test", "sessionId": "S1"},
    ])

    # 1. a name the person gave wins outright
    assert claude_title({**base, "name": "Auth work", "nameSource": "user"}, tmp_path) == "Auth work"
    # the Desktop app names sessions itself and records no source: still a name
    assert claude_title({**base, "name": "Intake handoff"}, tmp_path) == "Intake handoff"
    # 2. a name made up from the directory loses to the newest ai-title
    assert claude_title({**base, "name": "you-5f", "nameSource": "derived"}, tmp_path) == "Fix the login redirect"

    # 3. no ai-title: the newest prompt typed
    _transcript(tmp_path, cwd, "S2", [
        {"type": "last-prompt", "lastPrompt": "first ask", "sessionId": "S2"},
        {"type": "last-prompt", "lastPrompt": "can you check the build", "sessionId": "S2"},
    ])
    assert claude_title({"sessionId": "S2", "cwd": cwd}, tmp_path) == "Check the build"

    # 4. nothing in the transcript (or no transcript at all): the directory
    assert claude_title({"sessionId": "S3", "cwd": cwd}, tmp_path) == "web-app"
    assert claude_title({}, tmp_path) == ""


def test_claude_title_reads_only_the_tail_and_caches_by_mtime(tmp_path: Path, monkeypatch):
    import activity

    cwd = "/tmp/proj"
    path = _transcript(tmp_path, cwd, "S1", [
        {"type": "ai-title", "aiTitle": "Buried far back", "sessionId": "S1"},
        *[{"type": "assistant", "message": {"content": "x" * 1000}} for _ in range(400)],
        {"type": "ai-title", "aiTitle": "Recent title", "sessionId": "S1"},
    ])
    record = {"sessionId": "S1", "cwd": cwd}
    assert activity.claude_title(record, tmp_path) == "Recent title"

    reads = []
    real_tail = activity._tail_text
    monkeypatch.setattr(activity, "_tail_text", lambda *a: reads.append(a) or real_tail(*a))
    assert activity.claude_title(record, tmp_path) == "Recent title"
    assert reads == []  # unchanged file, answered from the cache

    with path.open("a") as fh:
        fh.write(json.dumps({"type": "ai-title", "aiTitle": "Newest title"}) + "\n")
    os.utime(path, (time.time() + 5, time.time() + 5))
    assert activity.claude_title(record, tmp_path) == "Newest title"
    assert len(reads) == 1


def test_codex_activity_working_then_idle(tmp_path: Path):
    from activity import codex_activity

    day = tmp_path / "codex" / "sessions" / "2026" / "07" / "20"
    day.mkdir(parents=True)
    _write_jsonl(day / "rollout-a.jsonl", [
        {"timestamp": "t", "type": "session_meta", "payload": {"session_id": "c1"}},
        {"timestamp": "t", "type": "event_msg",
         "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 1234}}}},
        {"timestamp": "t", "type": "response_item", "payload": {"type": "function_call"}},
    ])
    st = codex_activity(tmp_path / "codex" / "sessions")
    assert st.state == "working" and st.tokens == 1234 and "tool" in st.label

    # a newer rollout that has finished its turn
    _write_jsonl(day / "rollout-b.jsonl", [
        {"timestamp": "t", "type": "event_msg",
         "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": 40}}}},
        {"timestamp": "t", "type": "event_msg", "payload": {"type": "task_complete"}},
    ])
    st2 = codex_activity(tmp_path / "codex" / "sessions")
    assert st2.state == "idle" and st2.tokens == 40


def test_codex_activity_none_when_empty(tmp_path: Path):
    from activity import codex_activity
    assert codex_activity(tmp_path / "nope") is None


def test_opencode_activity_generating(tmp_path: Path):
    from activity import opencode_activity

    db = tmp_path / "oc.db"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE session (id TEXT, tokens_input INT, tokens_output INT, "
                "tokens_reasoning INT, time_updated INT, time_archived INT)")
    con.execute("CREATE TABLE message (id TEXT, session_id TEXT, time_created INT, data TEXT)")
    con.execute("INSERT INTO session VALUES ('s1', 100, 50, 10, 2000, NULL)")
    con.execute("INSERT INTO message VALUES ('m1', 's1', 1000, ?)",
                (json.dumps({"role": "assistant", "time": {"created": 1, "completed": None}}),))
    con.commit()
    con.close()

    st = opencode_activity(db)
    assert st.tokens == 160 and st.state == "working"


def test_enrich_leaves_claude_alone_and_fills_codex(tmp_path: Path):
    from activity import enrich
    from agents import RunningAgent

    day = tmp_path / "codex" / "2026" / "07" / "20"
    _write_jsonl(day / "rollout-a.jsonl", [
        {"type": "response_item", "payload": {"type": "function_call"}},
    ])
    agents = [
        RunningAgent(tool="claude", pid=1, tty="t1", elapsed="5m", cwd="/tmp",
                     state="waiting", label="input needed"),
        RunningAgent(tool="codex", pid=2, tty="t2", elapsed="9m", cwd="/tmp"),
    ]
    enrich(agents, codex_root=tmp_path / "codex", opencode_db=tmp_path / "no.db")
    # claude's status came with its session record and is not overwritten
    assert agents[0].state == "waiting" and agents[0].label == "input needed"
    assert agents[1].state == "working"


def test_codex_status_for_file_reports_working_then_idle(tmp_path: Path):
    working = tmp_path / "working.jsonl"
    _write_jsonl(working, [
        {"type": "session_meta", "payload": {"session_id": "w", "cwd": "/tmp/cx", "thread_source": "user"}},
        {"type": "response_item", "payload": {"type": "function_call", "name": "shell"}},
    ])
    assert codex_status_for_file(working).state == "working"

    idle = tmp_path / "idle.jsonl"
    _write_jsonl(idle, [
        {"type": "session_meta", "payload": {"session_id": "i", "cwd": "/tmp/cx", "thread_source": "user"}},
        {"type": "response_item", "payload": {"type": "function_call", "name": "shell"}},
        {"type": "event_msg", "payload": {"type": "task_complete"}},
    ])
    assert codex_status_for_file(idle).state == "idle"


