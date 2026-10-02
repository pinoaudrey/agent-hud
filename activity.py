"""Live activity for running agent sessions.

Reads the cheap on-disk signals each CLI exposes so the dashboard can show what
a session is doing *right now* — working vs idle, the current action, and a live
token count — without parsing whole transcripts.

Sources (all read-only, all degrade to a neutral status rather than raising):
  claude   <tree>/sessions/<pid>.json (per-process status: busy/idle/waiting,
           what a waiting session waits for, and when the status last moved),
           plus a bounded tail of the session's transcript for its title.
  codex    newest ~/.codex/sessions/**/rollout-*.jsonl — bounded tail only, the
           files reach hundreds of MB, so we seek to the end instead of scanning.
  opencode ~/.local/share/opencode/opencode.db (SQLite): newest session's tokens
           plus whether its latest assistant message is still generating.
"""

from __future__ import annotations

import glob
import json
import os
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from models import clean_title

# codex payload.type -> (is the session working?, human label)
_CODEX_WORKING = {
    "task_started": "starting…",
    "reasoning": "thinking…",
    "function_call": "running tool…",
    "custom_tool_call": "running tool…",
    "patch_apply_begin": "applying edit…",
}
_CODEX_DONE = {
    "task_complete": "",
    "agent_message": "",
    "patch_apply_end": "",
}


@dataclass
class LiveStatus:
    state: str = "unknown"  # "working" | "idle" | "waiting" | "unknown"
    label: str = ""  # human action, e.g. "running command"
    tokens: int = 0  # live token count for the session (0 if unknown)
    session_id: str = ""  # transcript this process is writing ("" if unknown)
    since: datetime | None = None  # when `state` last changed (None if unknown)


def _tail_text(path: str, n_bytes: int = 65536) -> str:
    """Return the last `n_bytes` of a (possibly huge) file, dropping a partial
    first line so JSON parsing stays clean."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > n_bytes:
                fh.seek(size - n_bytes)
                fh.readline()  # discard the partial line we landed in
            data = fh.read()
    except OSError:
        return ""
    return data.decode("utf-8", "replace")


# ---------------------------------------------------------------- claude


# Claude Code's per-pid status word -> the snapshot's state. "waiting" is the
# session blocked on the person (a permission prompt, a question).
_CLAUDE_STATES = {"busy": "working", "waiting": "waiting", "idle": "idle"}

# Bytes of transcript read from the end when looking for a title. Claude Code
# appends `ai-title` and `last-prompt` entries as the session goes, so the
# newest of each sits near the end; the files themselves reach megabytes.
_TITLE_TAIL_BYTES = 262144

# transcript path -> (mtime, newest ai-title, newest last-prompt). A busy
# session's transcript moves every poll, an idle one does not, so this keeps
# the 2s activity poll from rereading tails that cannot have changed.
_transcript_cache: dict[str, tuple[float, str, str]] = {}
_TRANSCRIPT_CACHE_MAX = 256


def _epoch_ms(value) -> datetime | None:
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
        return None
    return datetime.fromtimestamp(value / 1000, tz=timezone.utc)


def claude_status(record: dict) -> LiveStatus:
    """LiveStatus for one Claude Code session, from its per-pid record
    (`<tree>/sessions/<pid>.json`). A waiting session's `waitingFor` (for
    example "input needed") becomes its action, since that is the one thing
    worth reading about a session that is blocked on you."""
    status = str(record.get("status") or "").lower()
    state = _CLAUDE_STATES.get(status, "unknown")
    waiting_for = record.get("waitingFor")
    sid = record.get("sessionId")
    return LiveStatus(
        state=state,
        label=waiting_for if state == "waiting" and isinstance(waiting_for, str) else "",
        session_id=sid if isinstance(sid, str) else "",
        since=_epoch_ms(record.get("statusUpdatedAt")),
    )


def claude_transcript_path(tree: str | Path, cwd: str, session_id: str) -> Path:
    """Where Claude Code keeps a session's transcript: one directory per working
    directory, named by the path with every non-alphanumeric character turned
    into a dash."""
    return Path(tree) / "projects" / re.sub(r"[^A-Za-z0-9]", "-", cwd) / f"{session_id}.jsonl"


def _transcript_titles(path: Path) -> tuple[str, str]:
    """(newest ai-title, newest last-prompt) from the transcript's tail, either
    empty when the tail holds none."""
    try:
        mtime = path.stat().st_mtime
    except OSError:
        return "", ""
    key = str(path)
    cached = _transcript_cache.get(key)
    if cached and cached[0] == mtime:
        return cached[1], cached[2]
    ai_title = last_prompt = ""
    for line in _tail_text(key, _TITLE_TAIL_BYTES).splitlines():
        if '"ai-title"' not in line and '"last-prompt"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        kind = obj.get("type")
        if kind == "ai-title" and isinstance(obj.get("aiTitle"), str) and obj["aiTitle"].strip():
            ai_title = obj["aiTitle"].strip()
        elif kind == "last-prompt" and isinstance(obj.get("lastPrompt"), str) and obj["lastPrompt"].strip():
            last_prompt = obj["lastPrompt"]
    if len(_transcript_cache) >= _TRANSCRIPT_CACHE_MAX:
        _transcript_cache.clear()
    _transcript_cache[key] = (mtime, ai_title, last_prompt)
    return ai_title, last_prompt


def claude_title(record: dict, tree: str | Path) -> str:
    """What to call a Claude Code session, best source first:

    1. The name the person gave it. The Desktop app names its sessions itself
       and records no `nameSource`, which is the name its sidebar shows, so that
       counts too. A CLI name Claude Code made up from the directory
       (`nameSource: "derived"`, e.g. "audreypino-5f") does not.
    2. The newest `ai-title` in the transcript.
    3. The newest prompt typed (`last-prompt`).
    4. The working directory's basename.
    """
    name = record.get("name")
    if isinstance(name, str) and name.strip() and record.get("nameSource") in ("user", None):
        return name.strip()
    cwd = record.get("cwd") if isinstance(record.get("cwd"), str) else ""
    sid = record.get("sessionId")
    if cwd and isinstance(sid, str) and sid:
        ai_title, last_prompt = _transcript_titles(claude_transcript_path(tree, cwd, sid))
        if ai_title:
            return ai_title
        if last_prompt:
            return clean_title(last_prompt)
    return Path(cwd).name if cwd else ""


# ---------------------------------------------------------------- codex


def codex_status_for_file(path: str | Path) -> LiveStatus:
    """LiveStatus (working/idle + tokens + last action) for one codex rollout,
    from a bounded tail of its end so it stays cheap on hundred-MB files. Used
    both for the newest-session dashboard signal and, per tab, by the in-tab
    codex title daemon."""
    tokens = 0
    last_activity = ""
    for line in _tail_text(str(path)).splitlines():
        if '"payload"' not in line:
            continue
        try:
            payload = json.loads(line).get("payload") or {}
        except ValueError:
            continue
        ptype = payload.get("type")
        if ptype in _CODEX_WORKING or ptype in _CODEX_DONE:
            last_activity = ptype
        info = payload.get("info") or {}
        usage = info.get("total_token_usage") or {}
        if isinstance(usage.get("total_tokens"), int):
            tokens = usage["total_tokens"]
    if last_activity in _CODEX_WORKING:
        return LiveStatus(state="working", label=_CODEX_WORKING[last_activity], tokens=tokens)
    return LiveStatus(state="idle" if last_activity else "unknown", tokens=tokens)


def codex_activity(root: str | Path | None = None) -> LiveStatus | None:
    """LiveStatus for the newest codex rollout (tokens + last action), or None."""
    base = Path(root) if root else Path.home() / ".codex" / "sessions"
    files = sorted(
        glob.glob(str(base / "**" / "rollout-*.jsonl"), recursive=True),
        key=os.path.getmtime,
        reverse=True,
    )
    if not files:
        return None
    return codex_status_for_file(files[0])


# ---------------------------------------------------------------- opencode


def opencode_activity(db_path: str | Path | None = None) -> LiveStatus | None:
    """LiveStatus for the newest active opencode session, or None."""
    path = str(db_path or Path.home() / ".local/share/opencode/opencode.db")
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1.0)
    except sqlite3.Error:
        return None
    try:
        row = con.execute(
            "SELECT id, tokens_input, tokens_output, tokens_reasoning FROM session "
            "WHERE time_archived IS NULL ORDER BY time_updated DESC LIMIT 1"
        ).fetchone()
        if not row:
            return None
        sid, ti, to, tr = row
        tokens = (ti or 0) + (to or 0) + (tr or 0)
        state = "idle"
        msg = con.execute(
            "SELECT data FROM message WHERE session_id = ? ORDER BY time_created DESC LIMIT 1",
            (sid,),
        ).fetchone()
        if msg:
            try:
                data = json.loads(msg[0])
                if data.get("role") == "assistant" and not (data.get("time") or {}).get("completed"):
                    state = "working"
            except (ValueError, TypeError):
                pass
        return LiveStatus(state=state, tokens=tokens)
    except sqlite3.Error:
        return None
    finally:
        con.close()


# ---------------------------------------------------------------- join


def enrich(agents, codex_root=None, opencode_db=None):
    """Attach live status to running agents in place, and return them.

    Claude agents arrive with their status already attached, because the
    per-pid record they were discovered from is also their status source.
    codex/opencode expose a single global activity signal, applied to that
    tool's agents (typically just one).
    """
    codex = ...  # lazily fetched only if a codex agent is present
    opencode = ...
    for agent in agents:
        if agent.tool == "codex":
            if codex is ...:
                codex = codex_activity(codex_root)
            status = codex
        elif agent.tool == "opencode":
            if opencode is ...:
                opencode = opencode_activity(opencode_db)
            status = opencode
        else:
            status = None
        if status:
            agent.state = status.state
            agent.label = status.label
            agent.tokens = status.tokens
            agent.session_id = status.session_id
    return agents
