"""agenthud serve: the resident HUD daemon.

One background process that polls subscription usage and live agent activity,
folds them into a single frozen-schema snapshot, writes that snapshot atomically
to ~/.cache/agenthud/hud.json on every meaningful change, and serves it over a tiny
loopback HTTP API for the Swift HUD app (and any other localhost tooling).

Why a single daemon: the Anthropic usage endpoint is rate-limited per account and
shared with every live Claude Code session, so nothing here reaches around
usage.py's cache and 429 backoff. Usage is polled slowly (180s) and always
through usage.py; live activity (agents, their state) is cheap file reads and one
ps, so it polls fast (2s). All polling is thread-based to match the rest of agenthud.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
from dataclasses import is_dataclass, asdict, replace
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from activity import enrich
from agents import running_agents
from setup_health import collect_setup
from subscriptions import ClaudeOrg, claude_profiles, slug, subscription_index
from swap import collect_swap
from usage import collect_usage

# Live activity is cheap (file reads + one ps); usage hits a rate-limited API and
# barely moves between reads, so it stays slow and leans on usage.py's own cache.
# Setup health sits between the two: it shells out to check-setup.sh, which is
# well under a second but not free, and drift arrives at the speed of a person
# editing a config file. Swap state polls faster than setup because a cswap
# switch lands in running sessions within ~30 seconds, and the card claiming the
# wrong account is active is the exact confusion the block exists to remove;
# the call reads cswap's own cache, so the pace costs nothing upstream.
ACTIVITY_POLL_SECONDS = 2.0
USAGE_POLL_SECONDS = 180.0
SETUP_POLL_SECONDS = 60.0
SWAP_POLL_SECONDS = 30.0
SCHEMA_VERSION = 3

# Window durations, used to project a burn line for the tightest window.
_WINDOW_SECONDS = {
    "session_5h": 5 * 3600,
    "weekly_7d": 7 * 86400,
    "weekly_fable": 7 * 86400,
    "weekly": 7 * 86400,
}

# The soft dependency: a sibling branch builds pricing. It may not exist here, so
# import the whole module defensively and treat its absence as a null "value"
# block. The preferred entry point is pricing.hud_value(), which returns exactly
# the documented value contract; older builds only expose collect_value(), which
# hands back a richer object we coerce down.
try:
    import pricing as _pricing  # type: ignore
except ImportError:
    _pricing = None

# Non-loopback binds break the "localhost only" promise (no auth, permissive
# CORS), so they're refused unless this escape hatch is explicitly set.
_LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}
_ALLOW_REMOTE_ENV = "AGENTHUD_SERVE_ALLOW_REMOTE"


# ---------------------------------------------------------------- helpers


def _default_cache_path() -> Path:
    return Path.home() / ".cache" / "agenthud" / "hud.json"


def _iso(dt: datetime | None) -> str | None:
    return dt.isoformat() if dt else None


def _codex_label(usage) -> str:
    return f"Codex {usage.plan}".strip() if usage.plan else "Codex"


def _claude_identity(usage, index) -> tuple[str, str, list[str], bool]:
    """(id, label, trees, active) for a Claude reading, resolved through the
    config tree it came from. A reading with no matching tree — no profiles were
    passed, or the machine changed under us mid-poll — is still reported,
    unattributed, rather than dropped or guessed onto somebody else's
    subscription. Unattributed means we cannot say it is the live account
    either, so it is never marked active on a guess."""
    sub = index.get(usage.config_dir)
    if sub is None:
        return "claude", f"Claude {usage.plan}".strip() if usage.plan else "Claude", [], False
    return sub.id, sub.label, sub.trees, sub.active


def _reconciled(profiles, usages):
    """The profiles, with any organization claim the tree's own credential
    contradicts replaced by one derived from that credential.

    A tree's organization comes from the account metadata Claude Code keeps
    beside it, and that file is rewritten as sessions come and go: a tree that
    spent a session on a Team org goes on naming the Team org afterwards, even
    though the token it holds is a personal Max one again. The token is the
    harder fact, because it is what the reading was fetched with and whose
    quota that reading describes, so when the two disagree the file is the one
    that is out of date.

    Believing the file in that moment costs a whole plan: two trees both
    naming one organization collapse into a single subscription, and the
    second reading is discarded as a duplicate of the first — so a plan the
    user is actively over just stops appearing. A contradicted tree is given a
    private organization id keyed to itself, which cannot collide with anyone
    else's, and is named by the plan the credential reports.

    Only a genuine disagreement counts. A reading with no plan (no credential
    to read one from) is silence, not evidence, and leaves the file alone.
    """
    plans = {
        u.config_dir: u.plan
        for u in usages
        if u.tool == "claude" and u.config_dir and u.plan
    }
    out = []
    for profile in profiles:
        plan = plans.get(str(profile.config_dir), "")
        org = profile.org
        if org is not None and org.plan and plan and org.plan.casefold() != plan.casefold():
            profile = replace(profile, org=ClaudeOrg(
                uuid=f"credential:{profile.config_dir}",
                type=f"claude_{slug(plan)}",
            ))
        out.append(profile)
    return out


def _window_kind(provider: str, label: str) -> str:
    """Map usage.py's window labels onto the frozen schema's window kinds."""
    if provider == "codex":
        return "session_5h" if label == "5h" else "weekly"
    if label == "5h":
        return "session_5h"
    if label == "7d":
        return "weekly_7d"
    return "weekly_fable"  # the model-scoped weekly limit (Fable on Max/Team)


def _pct_left(pct: float | None) -> int | None:
    if pct is None:
        return None
    return max(0, min(100, round(100 - pct)))


def _stale_text(usage) -> str | None:
    """A human reason the bars are old, or None when they're fresh. usage.py
    marks rate-limited/cached reads; a hard error (no reading at all) stands in
    as the reason so a subscription never silently looks fine."""
    raw = usage.stale or usage.error
    if not raw:
        return None
    return raw.replace(" · ", ", ")  # "rate limited · retry 4m" -> "rate limited, retry 4m"


def _pace(used_pct: float | None, resets_at: datetime | None, kind: str, now: datetime) -> dict | None:
    """Linear burn projection for one window: extend the average burn since the
    window opened to when the quota would hit zero, and how many seconds of slack
    that leaves before the window resets. None whenever it can't be computed."""
    if used_pct is None or resets_at is None or used_pct <= 0:
        return None
    duration = _WINDOW_SECONDS.get(kind)
    if not duration:
        return None
    start = resets_at - timedelta(seconds=duration)
    elapsed = (now - start).total_seconds()
    if elapsed <= 0:
        return None
    burn_per_second = used_pct / elapsed
    remaining = 100.0 - used_pct
    dry = now if remaining <= 0 else now + timedelta(seconds=remaining / burn_per_second)
    margin = (resets_at - dry).total_seconds()
    return {"projected_dry_at": dry.isoformat(), "margin_seconds": int(margin)}


def _norm_state(state: str) -> str:
    return state if state in ("working", "waiting", "idle") else "idle"


def _elapsed_seconds(text: str) -> int | None:
    """Turn agents.py's friendly uptime ("2d 4h", "4h 12m", "12m") back into
    seconds. Approximate (the friendly form drops the smaller unit), but enough
    for a HUD's "since" line."""
    total = 0
    matched = False
    for num, unit in re.findall(r"(\d+)\s*([dhm])", text or ""):
        matched = True
        total += int(num) * {"d": 86400, "h": 3600, "m": 60}[unit]
    return total if matched else None


def _agent_sub_id(agent, profiles, index) -> str | None:
    """The subscription an agent is spending against, when determinable. Codex
    agents are always the codex subscription; a Claude agent is matched to the
    tree whose config dir holds its per-pid session file, and from there to that
    tree's subscription; everything else (opencode, unresolved) is null."""
    if agent.tool == "codex":
        return "codex"
    if agent.tool != "claude":
        return None
    for profile in profiles:
        if (profile.config_dir / "sessions" / f"{agent.pid}.json").exists():
            sub = index.get(str(profile.config_dir))
            return sub.id if sub else None
    return None


def _coerce_value(result) -> dict | None:
    """Fallback coercion for pricing.collect_value(): a schema-shaped dict passes
    through, a dataclass is unwrapped, anything else (or None) becomes null. This
    is best-effort only; the raw collect_value object can carry non-JSON types
    (sets, datetimes), which is exactly why _validate_json guards the result."""
    if result is None:
        return None
    if isinstance(result, dict):
        return result
    if is_dataclass(result):
        return asdict(result)
    return None


def _validate_json(value) -> dict | None:
    """Guarantee the value block can be serialized before it reaches the snapshot.
    A pricing object that isn't pure JSON (a set, a datetime) would otherwise
    crash json.dump when the snapshot is written, taking the daemon down. Degrade
    to null with a warning instead: the value field is never worth a crash."""
    if value is None:
        return None
    try:
        json.dumps(value)
    except (TypeError, ValueError) as exc:
        print(f"agenthud serve: value block is not JSON-serializable ({exc}); dropping it",
              file=sys.stderr)
        return None
    return value


def _collect_value() -> dict | None:
    """The value block, or None. Prefer pricing.hud_value() (the documented
    contract); fall back to coercing collect_value() on older builds. Any failure,
    including a non-serializable result, degrades to None rather than propagating."""
    if _pricing is None:
        return None
    try:
        if hasattr(_pricing, "hud_value"):
            value = _pricing.hud_value()
        elif hasattr(_pricing, "collect_value"):
            value = _coerce_value(_pricing.collect_value())
        else:
            return None
    except Exception:
        return None
    return _validate_json(value)


# ---------------------------------------------------------------- snapshot


def _subscription_entry(usage, sub_id, label, trees, active, now, soonest) -> tuple[dict, tuple | None]:
    """One subscription entry, plus the earliest reset seen while building it.
    `soonest` is threaded through rather than closed over so this stays pure."""
    windows_out = []
    tightest_pair = None  # (window dict, source UsageWindow)
    for win in usage.windows:
        kind = _window_kind(usage.tool, win.label)
        pct_left = _pct_left(win.pct)
        entry = {"kind": kind, "pct_left": pct_left, "resets_at": _iso(win.resets_at), "pace": None}
        windows_out.append(entry)
        if pct_left is not None and (tightest_pair is None or pct_left < tightest_pair[0]["pct_left"]):
            tightest_pair = (entry, win)
        if win.resets_at is not None and (soonest is None or win.resets_at < soonest[0]):
            soonest = (win.resets_at, sub_id, kind)

    tightest = None
    if tightest_pair is not None:
        entry, win = tightest_pair
        entry["pace"] = _pace(win.pct, win.resets_at, entry["kind"], now)
        tightest = {"kind": entry["kind"], "pct_left": entry["pct_left"], "resets_at": entry["resets_at"]}

    return {
        "id": sub_id,
        "provider": usage.tool,
        "label": label,
        "trees": trees,
        # Whether a session started right now with no account named would spend
        # this subscription. Under claude-swap the answer moves between Claude
        # accounts as it switches, so this is the one field on the card that
        # says which plan is currently paying.
        "active": active,
        # When these numbers were last true, which is not when the snapshot was
        # built. Claude is re-read every few minutes; Codex is only as fresh as
        # the last Codex turn, and that can be days.
        "read_at": _iso(usage.read_at),
        "windows": windows_out,
        "tightest": tightest,
        "stale": _stale_text(usage),
        "active_agents": 0,  # filled once agents are resolved
    }, soonest


def _pick_reading(existing, candidate):
    """Which of two readings for the same subscription to show. They are the
    same organization polled through two trees, so the numbers agree; what can
    differ is whether one of them is a cached fallback. A fresh reading always
    beats a stale one, so one tree sitting in a rate-limit cooldown cannot make
    a subscription look old when the other tree just read it cleanly."""
    if existing["stale"] and not candidate["stale"]:
        return candidate
    if existing["stale"] == candidate["stale"]:
        # Both equally trustworthy, so prefer whichever was read more recently.
        if (candidate["read_at"] or "") > (existing["read_at"] or ""):
            return candidate
    return existing


def _resolve_swap(swap: dict | None, index) -> dict | None:
    """The swap block with each account resolved to the subscription its
    organization maps to. cswap and this daemon key accounts the same way (the
    organization uuid), so the join is exact; an account whose organization is
    not signed in on this machine keeps a null subscription_id rather than
    being guessed onto someone else's pod."""
    if swap is None:
        return None
    by_org: dict[str, str] = {}
    for sub in index.values():
        for profile in sub.profiles:
            if profile.org is not None:
                by_org[profile.org.uuid] = sub.id
    accounts = [
        {**account, "subscription_id": by_org.get(account.get("organization_uuid") or "")}
        for account in swap.get("accounts", [])
    ]
    return {**swap, "accounts": accounts}


def build_snapshot(usages, fetched_at, agents, value=None, profiles=None, setup=None,
                   swap=None) -> dict:
    """Fold collector outputs into a v3 HUD snapshot dict. Pure given its args:
    pass the Claude `profiles` list so each reading can be attributed to the
    subscription its config tree belongs to. No credentials ever land in the
    returned dict.

    Two trees signed into one organization are one subscription with one quota,
    so they collapse into a single entry naming both trees; two trees on
    different organizations stay apart even when the same person owns both.

    The burn projection is anchored to `fetched_at` (when the usage was read),
    not wall-clock time, so a rebuild triggered by an activity poll reuses the
    same usage reading and produces byte-identical pace rather than churning."""
    generated_at = datetime.now(timezone.utc)
    now = fetched_at or generated_at  # pace/reset math uses the reading's own timestamp
    # A tree's own credential outranks the account metadata beside it, so the
    # reconciliation happens before anything is grouped or attributed.
    profiles = _reconciled(profiles or [], usages)
    index = subscription_index(profiles)

    subscriptions: list[dict] = []
    by_id: dict[str, dict] = {}
    soonest = None  # (resets_at dt, sub_id, kind)
    for usage in usages:
        if usage.tool not in ("claude", "codex"):
            continue  # opencode is BYOK, not a subscription
        if usage.tool == "codex":
            # Codex signs into one account at a time and has no switcher, so the
            # login it has is the one any session spends.
            sub_id, label, trees, active = "codex", _codex_label(usage), [], True
        else:
            sub_id, label, trees, active = _claude_identity(usage, index)

        entry, soonest = _subscription_entry(usage, sub_id, label, trees, active, now, soonest)
        if sub_id in by_id:
            kept = _pick_reading(by_id[sub_id], entry)
            subscriptions[subscriptions.index(by_id[sub_id])] = kept
            by_id[sub_id] = kept
            continue
        by_id[sub_id] = entry
        subscriptions.append(entry)

    agents_out = []
    for agent in agents:
        sub_id = _agent_sub_id(agent, profiles, index)
        agents_out.append({
            "pid": agent.pid,
            "tool": agent.tool,
            "project": Path(agent.cwd).name if agent.cwd else "",
            "cwd": agent.cwd,
            "state": _norm_state(agent.state),
            "action": agent.label or None,
            "since_seconds": _elapsed_seconds(agent.elapsed),
            "subscription_id": sub_id,
        })

    counts: dict[str, int] = {}
    for a in agents_out:
        if a["subscription_id"]:
            counts[a["subscription_id"]] = counts.get(a["subscription_id"], 0) + 1
    for sub in subscriptions:
        sub["active_agents"] = counts.get(sub["id"], 0)

    soonest_reset = None
    if soonest is not None:
        soonest_reset = {"subscription_id": soonest[1], "kind": soonest[2], "resets_at": _iso(soonest[0])}

    return {
        "version": SCHEMA_VERSION,
        "generated_at": _iso(generated_at),
        "subscriptions": subscriptions,
        "agents": agents_out,
        "value": value,
        "soonest_reset": soonest_reset,
        # Absent whenever the question could not be asked. Never a stand-in for
        # "healthy": the card reads null as unknown and says so.
        "setup": _validate_json(setup),
        # Null when cswap is absent or could not answer, which the card renders
        # by omitting the rotation section — never as "rotation off".
        "swap": _validate_json(_resolve_swap(swap, index)),
    }


def write_snapshot_atomic(path: Path, snapshot: dict) -> None:
    """Write the snapshot without ever exposing a half-written file: dump to a
    temp file in the same directory, then os.replace onto the target. The temp
    file is always cleaned up, so a serialization error can't orphan a .tmp."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with open(tmp, "w") as fh:
            json.dump(snapshot, fh, indent=2)
        os.replace(tmp, path)  # atomic rename; on success tmp no longer exists
    finally:
        tmp.unlink(missing_ok=True)


def _comparable(snapshot: dict) -> dict:
    """The snapshot minus its timestamp, so a rebuild that changed nothing but
    generated_at doesn't churn the file on disk every couple of seconds."""
    return {k: v for k, v in snapshot.items() if k != "generated_at"}


# ---------------------------------------------------------------- daemon


class HudDaemon:
    """Holds the latest collector outputs, rebuilds the snapshot on each poll,
    and serves it. Thread-safe: pollers write components under a lock, readers
    (the HTTP handler) get the current snapshot under the same lock."""

    def __init__(self, cache_path: Path | None = None):
        self.cache_path = cache_path or _default_cache_path()
        self._lock = threading.Lock()
        self._usages: list = []
        self._fetched_at: datetime | None = None
        self._profiles: list = []
        self._value: dict | None = None
        self._agents: list = []
        self._setup: dict | None = None
        self._swap: dict | None = None
        self._snapshot = build_snapshot([], None, [], None, [], None)
        self._last_comparable = _comparable(self._snapshot)
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []

    def snapshot(self) -> dict:
        with self._lock:
            return self._snapshot

    def _rebuild(self) -> None:
        with self._lock:
            snapshot = build_snapshot(
                self._usages, self._fetched_at, self._agents,
                self._value, self._profiles, self._setup, self._swap,
            )
            self._snapshot = snapshot
            comparable = _comparable(snapshot)
            changed = comparable != self._last_comparable
            self._last_comparable = comparable
        if changed:
            write_snapshot_atomic(self.cache_path, snapshot)

    def poll_usage_once(self) -> None:
        # One discovery, shared: reading the trees twice could hand build_snapshot
        # a usage list and a profile list that disagree about what exists.
        profiles = claude_profiles()
        usages, fetched_at = collect_usage(profiles)  # via usage.py's cache + 429 backoff
        value = _collect_value()
        with self._lock:
            self._usages, self._fetched_at = usages, fetched_at
            self._profiles, self._value = profiles, value
        self._rebuild()

    def poll_activity_once(self) -> None:
        agents = enrich(running_agents())
        with self._lock:
            self._agents = agents
        self._rebuild()

    def poll_setup_once(self) -> None:
        # collect_setup returns None whenever the question could not be asked,
        # and None is written through as a null block rather than left at the
        # last good answer: a panel showing yesterday's all-clear is worse than
        # one saying it does not know.
        setup = collect_setup()
        with self._lock:
            self._setup = setup
        self._rebuild()

    def poll_swap_once(self) -> None:
        # Same contract as setup: a failed ask writes null through rather than
        # holding the last good answer, because the block's whole job is saying
        # which account is billing *right now*.
        swap = collect_swap()
        with self._lock:
            self._swap = swap
        self._rebuild()

    def _loop(self, fn, interval: float) -> None:
        while not self._stop.is_set():
            try:
                fn()
            except Exception:  # a bad poll must never kill the loop
                pass
            if self._stop.wait(interval):
                break

    def start_polling(self) -> None:
        for fn, interval in ((self.poll_usage_once, USAGE_POLL_SECONDS),
                             (self.poll_setup_once, SETUP_POLL_SECONDS),
                             (self.poll_swap_once, SWAP_POLL_SECONDS),
                             (self.poll_activity_once, ACTIVITY_POLL_SECONDS)):
            thread = threading.Thread(target=self._loop, args=(fn, interval), daemon=True)
            thread.start()
            self._threads.append(thread)

    def stop(self) -> None:
        self._stop.set()


# ---------------------------------------------------------------- http


class _HudHandler(BaseHTTPRequestHandler):
    """GET /v1/hud -> the snapshot; GET /v1/health -> liveness; else 404.
    CORS is permissive because the bind is loopback-only, so 'anyone' is already
    just localhost tooling."""

    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_OPTIONS(self) -> None:  # noqa: N802 (http.server naming)
        self._send(204, b"")

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/v1/hud":
            body = json.dumps(self.server.hud_daemon.snapshot()).encode()  # type: ignore[attr-defined]
            self._send(200, body)
        elif self.path == "/v1/health":
            self._send(200, json.dumps({"ok": True, "version": SCHEMA_VERSION}).encode())
        else:
            self._send(404, json.dumps({"error": "not found"}).encode())

    def log_message(self, *args) -> None:  # keep the daemon quiet
        pass


def make_server(host: str, port: int, daemon: HudDaemon) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((host, port), _HudHandler)
    server.hud_daemon = daemon  # type: ignore[attr-defined]
    return server


def _ensure_loopback(host: str) -> None:
    """Refuse a non-loopback bind unless explicitly overridden. The HUD API has no
    auth and permissive CORS, so exposing it off localhost would hand every
    subscription reading and running-agent list to the local network."""
    if host in _LOOPBACK_HOSTS or os.environ.get(_ALLOW_REMOTE_ENV) == "1":
        return
    raise SystemExit(
        f"agenthud serve: refusing to bind non-loopback host {host!r}. The HUD API has "
        f"no authentication and permissive CORS, so it must stay on localhost. Set "
        f"{_ALLOW_REMOTE_ENV}=1 to override at your own risk."
    )


def serve(host: str = "127.0.0.1", port: int = 8737) -> None:
    """Run the HUD daemon: start the pollers, prime the snapshot once, and serve
    it on the loopback interface until interrupted."""
    _ensure_loopback(host)
    daemon = HudDaemon()
    # prime once so /v1/hud has data on the first request; a failing collector must
    # log and let startup continue rather than kill the daemon (the loop retries).
    for prime in (daemon.poll_usage_once, daemon.poll_setup_once,
                  daemon.poll_swap_once, daemon.poll_activity_once):
        try:
            prime()
        except Exception as exc:
            print(f"agenthud serve: initial poll failed ({exc}); will retry in the loop",
                  file=sys.stderr)
    daemon.start_polling()
    server = make_server(host, port, daemon)
    print(f"agenthud serve: HUD snapshot on http://{host}:{port}/v1/hud (cache {daemon.cache_path})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        daemon.stop()
        server.shutdown()
        server.server_close()
