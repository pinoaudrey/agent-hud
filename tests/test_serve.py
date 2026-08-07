"""Tests for the agenthud serve HUD daemon: snapshot shape, atomic writes, stale
propagation, value fallback, and the HTTP endpoints."""

from __future__ import annotations

import json
import sys
import threading
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

import serve as serve_module
from agents import RunningAgent
from helpers import write_claude_tree, write_cswap_store
from serve import (
    HudDaemon,
    build_snapshot,
    make_server,
    write_snapshot_atomic,
)
from subscriptions import claude_profiles
from usage import ToolUsage, UsageWindow

MAX_ORG = "3f3b964d-1111-2222-3333-444444444444"
TEAM_ORG = "780d6270-5555-6666-7777-888888888888"


# ---------------------------------------------------------------- fixtures


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _claude_usage(**kw) -> ToolUsage:
    resets_5h = _now() + timedelta(hours=2)
    resets_7d = _now() + timedelta(days=5)
    defaults = dict(
        tool="claude",
        plan="Team",
        windows=[UsageWindow("5h", 38.0, resets_5h), UsageWindow("7d", 12.0, resets_7d)],
    )
    defaults.update(kw)
    return ToolUsage(**defaults)


def _codex_usage(**kw) -> ToolUsage:
    defaults = dict(
        tool="codex",
        plan="Max",
        windows=[UsageWindow("5h", 20.0, _now() + timedelta(hours=1)),
                 UsageWindow("7d", 55.0, _now() + timedelta(days=3))],
    )
    defaults.update(kw)
    return ToolUsage(**defaults)


def _fake_usages() -> list[ToolUsage]:
    return [_claude_usage(), _codex_usage(),
            ToolUsage(tool="opencode", spend=1.0, spend_sessions=2)]  # BYOK, must be dropped


def _fake_agents() -> list[RunningAgent]:
    return [
        RunningAgent(tool="claude", pid=1, tty="ttys001", elapsed="4h 12m",
                     cwd="/tmp/web-app", state="working", label="editing auth.py"),
        RunningAgent(tool="codex", pid=2, tty="ttys002", elapsed="9m",
                     cwd="/tmp/api", state="unknown"),
    ]


# ---------------------------------------------------------------- snapshot shape


def test_snapshot_has_frozen_top_level_shape():
    snap = build_snapshot(_fake_usages(), _now(), _fake_agents())
    assert snap["version"] == 3
    # generated_at is ISO8601 with an offset
    assert datetime.fromisoformat(snap["generated_at"]).tzinfo is not None
    assert set(snap) == {"version", "generated_at", "subscriptions", "agents",
                         "value", "soonest_reset", "setup", "swap"}
    # opencode is BYOK, never a subscription
    assert [s["provider"] for s in snap["subscriptions"]] == ["claude", "codex"]


def test_claude_windows_map_to_frozen_kinds():
    resets = _now() + timedelta(days=6)
    usage = _claude_usage(windows=[
        UsageWindow("5h", 40.0, _now() + timedelta(hours=1)),
        UsageWindow("7d", 10.0, resets),
        UsageWindow("fable", 25.0, resets),  # model-scoped weekly limit
    ])
    snap = build_snapshot([usage], _now(), [])
    kinds = [w["kind"] for w in snap["subscriptions"][0]["windows"]]
    assert kinds == ["session_5h", "weekly_7d", "weekly_fable"]


def test_codex_windows_map_to_session_and_weekly():
    snap = build_snapshot([_codex_usage()], _now(), [])
    sub = snap["subscriptions"][0]
    assert sub["id"] == "codex" and sub["label"] == "Codex Max"
    assert [w["kind"] for w in sub["windows"]] == ["session_5h", "weekly"]


def test_pct_left_is_hundred_minus_utilization():
    snap = build_snapshot([_claude_usage()], _now(), [])
    windows = {w["kind"]: w for w in snap["subscriptions"][0]["windows"]}
    assert windows["session_5h"]["pct_left"] == 62  # 100 - 38
    assert windows["weekly_7d"]["pct_left"] == 88


def test_tightest_is_the_least_headroom_window_with_pace():
    snap = build_snapshot([_claude_usage()], _now(), [])
    sub = snap["subscriptions"][0]
    assert sub["tightest"]["kind"] == "session_5h"  # 62% left beats 88%
    assert sub["tightest"]["pct_left"] == 62
    # pace is computed only on the tightest window
    windows = {w["kind"]: w for w in sub["windows"]}
    assert windows["session_5h"]["pace"] is not None
    assert set(windows["session_5h"]["pace"]) == {"projected_dry_at", "margin_seconds"}
    assert windows["weekly_7d"]["pace"] is None


def test_null_percentages_yield_null_tightest():
    usage = _claude_usage(windows=[UsageWindow("5h", None, None), UsageWindow("7d", None, None)])
    snap = build_snapshot([usage], _now(), [])
    sub = snap["subscriptions"][0]
    assert sub["tightest"] is None
    assert all(w["pct_left"] is None and w["pace"] is None for w in sub["windows"])


def test_soonest_reset_picks_the_earliest_window():
    snap = build_snapshot(_fake_usages(), _now(), _fake_agents())
    # codex 5h resets in ~1h, sooner than everything else
    assert snap["soonest_reset"]["subscription_id"] == "codex"
    assert snap["soonest_reset"]["kind"] == "session_5h"


def test_soonest_reset_null_when_no_resets():
    usage = _claude_usage(windows=[UsageWindow("5h", 40.0, None)])
    assert build_snapshot([usage], _now(), [])["soonest_reset"] is None


# ---------------------------------------------------------------- agents


def test_agents_are_mapped_and_state_normalised():
    snap = build_snapshot(_fake_usages(), _now(), _fake_agents())
    agents = {a["pid"]: a for a in snap["agents"]}
    assert agents[1]["state"] == "working" and agents[1]["action"] == "editing auth.py"
    assert agents[1]["project"] == "web-app"
    assert agents[1]["since_seconds"] == 4 * 3600 + 12 * 60  # parsed from "4h 12m"
    assert agents[2]["state"] == "idle"  # "unknown" normalises to idle
    assert agents[2]["action"] is None
    assert agents[2]["subscription_id"] == "codex"  # codex agents are always codex


def test_active_agents_counted_per_subscription(tmp_path: Path):
    # a claude agent whose per-pid session file lives in the default config dir
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    default = tmp_path / ".claude"
    (default / "sessions").mkdir(parents=True)
    (default / "sessions" / "1.json").write_text("{}")
    profiles = claude_profiles(home=tmp_path)

    usages = [_claude_usage(config_dir=str(default)), _codex_usage()]
    snap = build_snapshot(usages, _now(), _fake_agents(), profiles=profiles)
    subs = {s["id"]: s for s in snap["subscriptions"]}
    assert subs["claude-team"]["active_agents"] == 1
    assert subs["codex"]["active_agents"] == 1
    claude_agent = next(a for a in snap["agents"] if a["pid"] == 1)
    assert claude_agent["subscription_id"] == "claude-team"


def test_subscriptions_are_named_by_organization_not_directory(tmp_path: Path):
    """The default tree is whatever account it holds — here a personal Max, not
    a team seat, which the old directory-derived id asserted it was."""
    write_claude_tree(tmp_path, ".claude", org_uuid=MAX_ORG,
                      org_name="joseph@carepilot.com", org_type="claude_max")
    write_claude_tree(tmp_path, ".claude-team", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    profiles = claude_profiles(home=tmp_path)

    usages = [
        _claude_usage(config_dir=str(profiles[0].config_dir), plan="Max"),
        _claude_usage(config_dir=str(profiles[1].config_dir), plan="Team"),
    ]
    snap = build_snapshot(usages, _now(), [], profiles=profiles)
    subs = {s["id"]: s["label"] for s in snap["subscriptions"]}
    assert subs == {"claude-max": "Claude Max", "claude-team": "Claude Team"}


def test_two_trees_on_one_org_are_one_subscription(tmp_path: Path):
    """Two config trees signed into one organization spend one quota. Reporting
    both would show the headroom twice."""
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    write_claude_tree(tmp_path, ".claude-work", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    profiles = claude_profiles(home=tmp_path)

    usages = [_claude_usage(config_dir=str(p.config_dir)) for p in profiles]
    snap = build_snapshot(usages, _now(), [], profiles=profiles)
    assert [s["id"] for s in snap["subscriptions"]] == ["claude-team"]
    assert snap["subscriptions"][0]["trees"] == ["~/.claude", "~/.claude-work"]


def test_a_tree_is_believed_over_a_stale_org_claim(tmp_path: Path):
    """The real failure this guards: the default tree's account metadata still
    named the Team org after a Team session, while the token it holds — and the
    reading fetched with it — was the personal Max one. Believing the file
    folded both trees into one subscription and threw the Max reading away as a
    duplicate, so a plan the user was actively over simply vanished from the
    card. The credential decides, and both plans stay on screen."""
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    write_claude_tree(tmp_path, ".claude-team", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    profiles = claude_profiles(home=tmp_path)

    spent = [UsageWindow("5h", 100.0, _now() + timedelta(hours=3))]
    usages = [
        _claude_usage(config_dir=str(profiles[0].config_dir), plan="Max", windows=spent),
        _claude_usage(config_dir=str(profiles[1].config_dir), plan="Team"),
    ]
    snap = build_snapshot(usages, _now(), [], profiles=profiles)
    subs = {s["id"]: s for s in snap["subscriptions"]}
    assert set(subs) == {"claude-max", "claude-team"}
    assert subs["claude-max"]["label"] == "Claude Max"
    assert subs["claude-max"]["trees"] == ["~/.claude"]
    assert subs["claude-max"]["windows"][0]["pct_left"] == 0  # the spent plan is still shown
    assert subs["claude-team"]["trees"] == ["~/.claude-team"]


def test_a_reading_with_no_plan_leaves_the_org_claim_alone(tmp_path: Path):
    """A reading that could not name its plan (no credential to read it from) is
    no evidence against the config tree, so the trees still collapse. Splitting
    on silence would report one quota twice."""
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    write_claude_tree(tmp_path, ".claude-work", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    profiles = claude_profiles(home=tmp_path)

    usages = [_claude_usage(config_dir=str(p.config_dir), plan="") for p in profiles]
    snap = build_snapshot(usages, _now(), [], profiles=profiles)
    assert [s["id"] for s in snap["subscriptions"]] == ["claude-team"]


def test_a_fresh_tree_beats_a_stale_one_for_the_same_subscription(tmp_path: Path):
    """One tree sitting in a rate-limit cooldown must not make the subscription
    look old when the other tree read it cleanly a second ago."""
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    write_claude_tree(tmp_path, ".claude-work", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    profiles = claude_profiles(home=tmp_path)

    usages = [
        _claude_usage(config_dir=str(profiles[0].config_dir), stale="rate limited · retry 4m"),
        _claude_usage(config_dir=str(profiles[1].config_dir)),
    ]
    snap = build_snapshot(usages, _now(), [], profiles=profiles)
    assert len(snap["subscriptions"]) == 1
    assert snap["subscriptions"][0]["stale"] is None


def test_an_unattributable_reading_is_still_reported():
    """No profiles to match against (a machine we could not read, or a tree that
    vanished mid-poll). The reading is shown unattributed rather than dropped or
    guessed onto somebody else's subscription."""
    snap = build_snapshot([_claude_usage()], _now(), [], profiles=[])
    sub = snap["subscriptions"][0]
    assert sub["id"] == "claude" and sub["label"] == "Claude Team"  # plan from the reading
    assert sub["trees"] == []


# ---------------------------------------------------------------- stale


def test_stale_reason_propagates_and_keeps_last_good_bars():
    usage = _claude_usage(stale="rate limited · retry 4m")
    sub = build_snapshot([usage], _now(), [])["subscriptions"][0]
    assert sub["stale"] == "rate limited, retry 4m"  # normalised to a plain human string
    # the bars are still there: staleness never blanks the last-good numbers
    assert sub["windows"][0]["pct_left"] == 62


def test_hard_error_surfaces_as_stale_with_empty_windows():
    usage = ToolUsage(tool="claude", error="unlock Keychain or sign in to Claude Code")
    sub = build_snapshot([usage], _now(), [])["subscriptions"][0]
    assert sub["stale"] == "unlock Keychain or sign in to Claude Code"
    assert sub["windows"] == [] and sub["tightest"] is None


def test_fresh_reading_is_not_flagged_stale():
    assert build_snapshot([_claude_usage()], _now(), [])["subscriptions"][0]["stale"] is None


# ---------------------------------------------------------------- value


def _fake_pricing(**attrs) -> SimpleNamespace:
    """A stand-in for the pricing module exposing whatever entry points a test
    wants (hud_value / collect_value)."""
    return SimpleNamespace(**attrs)


def test_value_is_null_when_module_absent(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(serve_module, "_pricing", None)
    assert serve_module._collect_value() is None


def test_value_prefers_hud_value_adapter(monkeypatch: pytest.MonkeyPatch):
    payload = {"today_usd": 42.1, "month_usd": 830.5, "subs_cost_usd": 400.0,
               "multiple": 2.08, "by_sub": {"claude-team": {"today_usd": 30.0, "month_usd": 600.0}}}
    # collect_value would raise: hud_value must win when both exist
    monkeypatch.setattr(serve_module, "_pricing",
                        _fake_pricing(hud_value=lambda: payload,
                                      collect_value=lambda: (_ for _ in ()).throw(AssertionError)))
    snap = build_snapshot(_fake_usages(), _now(), [], value=serve_module._collect_value())
    assert snap["value"] == payload


def test_value_falls_back_to_collect_value(monkeypatch: pytest.MonkeyPatch):
    payload = {"today_usd": 1.0, "month_usd": 2.0, "subs_cost_usd": None,
               "multiple": None, "by_sub": {}}
    monkeypatch.setattr(serve_module, "_pricing", _fake_pricing(collect_value=lambda: payload))
    assert serve_module._collect_value() == payload


def test_value_collector_error_is_swallowed(monkeypatch: pytest.MonkeyPatch):
    def boom():
        raise RuntimeError("pricing exploded")

    monkeypatch.setattr(serve_module, "_pricing", _fake_pricing(hud_value=boom))
    assert serve_module._collect_value() is None


def test_value_with_non_json_type_degrades_to_none(monkeypatch: pytest.MonkeyPatch):
    """A value block carrying a set (or any non-JSON type) must never crash the
    snapshot write: it degrades to None instead of raising."""
    bad = {"today_usd": 1.0, "by_sub": {"claude-team"}}  # a set is not JSON-serializable
    monkeypatch.setattr(serve_module, "_pricing", _fake_pricing(hud_value=lambda: bad))
    assert serve_module._collect_value() is None
    # and the snapshot around it still serializes cleanly
    snap = build_snapshot(_fake_usages(), _now(), [], value=serve_module._collect_value())
    assert snap["value"] is None
    json.dumps(snap)  # must not raise


def test_pricing_hud_value_contract_is_serializable(monkeypatch: pytest.MonkeyPatch):
    """Cross-contract seam: once the pricing branch lands, run a real ValueReport
    through the value path and assert the snapshot serializes and the value keys
    match docs/hud-schema.md. Skips while pricing is absent on this branch."""
    pricing = pytest.importorskip("pricing")
    if not hasattr(pricing, "hud_value"):
        pytest.skip("pricing.hud_value adapter not present yet")

    value = serve_module._collect_value()
    snap = build_snapshot(_fake_usages(), _now(), _fake_agents(), value=value)
    json.dumps(snap)  # the whole snapshot must serialize with the real value block
    if snap["value"] is not None:
        assert set(snap["value"]) == {"today_usd", "month_usd", "subs_cost_usd", "multiple", "by_sub"}


def test_snapshot_carries_no_credentials():
    """A token accidentally left on a ToolUsage-like object must not reach the
    snapshot; only known fields are ever read."""
    blob = json.dumps(build_snapshot(_fake_usages(), _now(), _fake_agents()))
    assert "accessToken" not in blob and "Bearer" not in blob


# ---------------------------------------------------------------- atomic write


def test_write_snapshot_atomic_roundtrips(tmp_path: Path):
    path = tmp_path / "sub" / "hud.json"
    snap = build_snapshot(_fake_usages(), _now(), _fake_agents())
    write_snapshot_atomic(path, snap)
    assert json.loads(path.read_text()) == snap
    # no temp files left behind
    assert list(path.parent.glob(".*.tmp")) == []


def test_write_snapshot_atomic_replaces_existing(tmp_path: Path):
    path = tmp_path / "hud.json"
    write_snapshot_atomic(path, {"version": 1, "n": 1})
    write_snapshot_atomic(path, {"version": 1, "n": 2})
    assert json.loads(path.read_text())["n"] == 2


def test_write_snapshot_atomic_leaves_no_temp_on_serialization_error(tmp_path: Path):
    """A non-serializable snapshot must not orphan a .tmp file."""
    path = tmp_path / "hud.json"
    with pytest.raises(TypeError):
        write_snapshot_atomic(path, {"bad": {1, 2, 3}})  # a set can't be dumped
    assert list(tmp_path.glob(".*.tmp")) == []
    assert not path.exists()  # nothing half-written landed at the target


def test_daemon_writes_file_only_on_content_change(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    path = tmp_path / "hud.json"
    daemon = HudDaemon(cache_path=path)
    # stable reading: same objects and same fetched_at each poll, so only
    # generated_at would differ between rebuilds
    usages, fetched_at, agents = _fake_usages(), _now(), _fake_agents()
    monkeypatch.setattr(serve_module, "collect_usage", lambda profiles=None: (usages, fetched_at))
    monkeypatch.setattr(serve_module, "claude_profiles", lambda: [])
    monkeypatch.setattr(serve_module, "running_agents", lambda: agents)
    monkeypatch.setattr(serve_module, "enrich", lambda a, **kw: a)
    # the value block reads live session spend, which ticks up while any agent
    # is running; pin it too or "identical inputs" isn't what the test measures
    monkeypatch.setattr(serve_module, "_collect_value", lambda: {"today_usd": 1.0, "month_usd": 2.0})

    daemon.poll_usage_once()
    daemon.poll_activity_once()
    first = path.stat().st_mtime_ns

    # a re-poll with identical content differs only in generated_at, so no rewrite
    daemon.poll_usage_once()
    assert path.stat().st_mtime_ns == first
    snap = daemon.snapshot()
    assert snap["subscriptions"] and snap["agents"]


# ---------------------------------------------------------------- http


@pytest.fixture
def running_server(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setattr(serve_module, "collect_usage", lambda profiles=None: (_fake_usages(), _now()))
    monkeypatch.setattr(serve_module, "claude_profiles", lambda: [])
    monkeypatch.setattr(serve_module, "running_agents", lambda: _fake_agents())
    monkeypatch.setattr(serve_module, "enrich", lambda agents, **kw: agents)

    daemon = HudDaemon(cache_path=tmp_path / "hud.json")
    daemon.poll_usage_once()
    daemon.poll_activity_once()
    server = make_server("127.0.0.1", 0, daemon)  # port 0 -> an ephemeral free port
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    try:
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()


def test_hud_endpoint_serves_the_snapshot(running_server: str):
    with urllib.request.urlopen(f"{running_server}/v1/hud", timeout=5) as resp:
        assert resp.status == 200
        assert resp.headers["Content-Type"] == "application/json"
        assert resp.headers["Access-Control-Allow-Origin"] == "*"
        snap = json.loads(resp.read().decode())
    assert snap["version"] == 3
    assert [s["provider"] for s in snap["subscriptions"]] == ["claude", "codex"]
    assert len(snap["agents"]) == 2


def test_health_endpoint(running_server: str):
    with urllib.request.urlopen(f"{running_server}/v1/health", timeout=5) as resp:
        assert resp.status == 200
        assert json.loads(resp.read().decode()) == {"ok": True, "version": 3}


def test_unknown_path_404s(running_server: str):
    with pytest.raises(urllib.error.HTTPError) as exc:
        urllib.request.urlopen(f"{running_server}/v1/nope", timeout=5)
    assert exc.value.code == 404


# ---------------------------------------------------------------- loopback guard


def test_loopback_hosts_are_allowed(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.delenv(serve_module._ALLOW_REMOTE_ENV, raising=False)
    for host in ("127.0.0.1", "::1", "localhost"):
        serve_module._ensure_loopback(host)  # must not raise


def test_non_loopback_bind_is_refused(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.delenv(serve_module._ALLOW_REMOTE_ENV, raising=False)
    with pytest.raises(SystemExit) as exc:
        serve_module._ensure_loopback("0.0.0.0")
    assert serve_module._ALLOW_REMOTE_ENV in str(exc.value)  # the message names the escape hatch


def test_non_loopback_bind_allowed_with_env_override(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv(serve_module._ALLOW_REMOTE_ENV, "1")
    serve_module._ensure_loopback("0.0.0.0")  # must not raise


# ---------------------------------------------------------------- setup block


def test_snapshot_carries_the_setup_block():
    setup = {"version": 1, "generated_at": "x", "problems": 2, "sections": []}
    snap = build_snapshot(_fake_usages(), _now(), [], setup=setup)
    assert snap["version"] == 3
    assert snap["setup"] == setup


def test_setup_is_null_when_the_question_could_not_be_asked():
    """None is not "healthy". It has to reach the app as null so the card can say
    it does not know, instead of showing an all-clear nobody established."""
    snap = build_snapshot(_fake_usages(), _now(), [], setup=None)
    assert "setup" in snap and snap["setup"] is None


def test_a_non_serializable_setup_block_degrades_to_null():
    """The block comes from another repo's script. Whatever it hands back must
    not be able to take the snapshot write down with it."""
    snap = build_snapshot(_fake_usages(), _now(), [], setup={"sections": {1, 2}})
    assert snap["setup"] is None
    json.dumps(snap)  # must not raise


def test_daemon_polls_setup_and_folds_it_in(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    setup = {"version": 1, "generated_at": "x", "problems": 0, "sections": []}
    monkeypatch.setattr(serve_module, "collect_setup", lambda: setup)
    daemon = HudDaemon(cache_path=tmp_path / "hud.json")
    daemon.poll_setup_once()
    assert daemon.snapshot()["setup"] == setup


def test_a_failed_setup_poll_clears_the_block_rather_than_keeping_the_last_good_one(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    """Setup health is a claim about right now. Holding yesterday's all-clear
    while the check is unavailable is exactly the false green this must avoid."""
    good = {"version": 1, "generated_at": "x", "problems": 0, "sections": []}
    answers = [good, None]
    monkeypatch.setattr(serve_module, "collect_setup", lambda: answers.pop(0))
    daemon = HudDaemon(cache_path=tmp_path / "hud.json")
    daemon.poll_setup_once()
    assert daemon.snapshot()["setup"] == good
    daemon.poll_setup_once()
    assert daemon.snapshot()["setup"] is None


# ---------------------------------------------------------------- freshness


def test_a_reading_carries_when_it_was_true():
    """Not when the snapshot was built. Claude is re-read every few minutes, but
    Codex is only as fresh as your last Codex turn."""
    read_at = _now() - timedelta(days=3)
    usage = _codex_usage(read_at=read_at)
    sub = build_snapshot([usage], _now(), [])["subscriptions"][0]
    assert sub["read_at"] == read_at.isoformat()


def test_a_reading_with_no_timestamp_says_so_rather_than_guessing():
    sub = build_snapshot([_claude_usage()], _now(), [])["subscriptions"][0]
    assert sub["read_at"] is None


def test_the_fresher_of_two_trees_on_one_org_wins(tmp_path: Path):
    """Both readings are equally trustworthy, so the tiebreak is recency: the
    other tree may have been polled minutes ago."""
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    write_claude_tree(tmp_path, ".claude-work", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    profiles = claude_profiles(home=tmp_path)
    older, newer = _now() - timedelta(minutes=30), _now()

    usages = [
        _claude_usage(config_dir=str(profiles[0].config_dir), read_at=older),
        _claude_usage(config_dir=str(profiles[1].config_dir), read_at=newer),
    ]
    snap = build_snapshot(usages, _now(), [], profiles=profiles)
    assert len(snap["subscriptions"]) == 1
    assert snap["subscriptions"][0]["read_at"] == newer.isoformat()


# ---------------------------------------------------------------- swap block


def _swap_block(**accounts_by_org) -> dict:
    """A collector-shaped swap block: subscription_id still unresolved."""
    return {
        "active_slot": 1,
        "accounts": [
            {"slot": i + 1, "alias": alias, "email": f"{alias}@x.com",
             "organization_uuid": org, "subscription_id": None, "active": i == 0}
            for i, (alias, org) in enumerate(accounts_by_org.items())
        ],
        "auto": {"running": True, "threshold": 90},
    }


def test_swap_accounts_resolve_to_subscriptions_by_organization(tmp_path: Path):
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    write_claude_tree(tmp_path, ".claude-personal", org_uuid=MAX_ORG,
                      org_name="a@home.com", org_type="claude_max")
    profiles = claude_profiles(home=tmp_path)

    swap = _swap_block(work=TEAM_ORG, personal=MAX_ORG)
    snap = build_snapshot(_fake_usages(), _now(), [], profiles=profiles, swap=swap)
    by_alias = {a["alias"]: a for a in snap["swap"]["accounts"]}
    assert by_alias["work"]["subscription_id"] == "claude-team"
    assert by_alias["personal"]["subscription_id"] == "claude-max"
    assert snap["swap"]["active_slot"] == 1
    assert snap["swap"]["auto"] == {"running": True, "threshold": 90}


def test_a_swap_account_with_no_matching_org_stays_unattributed(tmp_path: Path):
    """An account whose organization is not signed in on this machine must keep
    a null subscription_id rather than being guessed onto someone else's pod."""
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    profiles = claude_profiles(home=tmp_path)

    swap = _swap_block(work=TEAM_ORG, stranger="org-nobody-here")
    snap = build_snapshot(_fake_usages(), _now(), [], profiles=profiles, swap=swap)
    by_alias = {a["alias"]: a for a in snap["swap"]["accounts"]}
    assert by_alias["work"]["subscription_id"] == "claude-team"
    assert by_alias["stranger"]["subscription_id"] is None


def test_swap_is_null_when_the_question_could_not_be_asked():
    snap = build_snapshot(_fake_usages(), _now(), [], swap=None)
    assert "swap" in snap and snap["swap"] is None


def test_daemon_polls_swap_and_clears_it_on_a_failed_ask(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    """The block's whole claim is which account is billing right now, so a
    failed poll writes null through rather than holding the last good answer."""
    good = _swap_block(work=TEAM_ORG)
    answers = [good, None]
    monkeypatch.setattr(serve_module, "collect_swap", lambda: answers.pop(0))
    daemon = HudDaemon(cache_path=tmp_path / "hud.json")
    daemon.poll_swap_once()
    assert daemon.snapshot()["swap"]["active_slot"] == 1
    daemon.poll_swap_once()
    assert daemon.snapshot()["swap"] is None


# ----------------------------------------------- which account is paying now


def _swapped(tmp_path: Path, active_org: str):
    """A cswap machine: `~/.claude` holds whichever account is signed in, and
    every account keeps a session profile so none of them drop off the card."""
    is_max = active_org == MAX_ORG
    write_claude_tree(tmp_path, ".claude", org_uuid=active_org,
                      org_name="joseph@carepilot.com" if is_max else "CarePilot",
                      org_type="claude_max" if is_max else "claude_team")
    write_cswap_store(tmp_path, [
        {"num": 1, "org_uuid": MAX_ORG, "org_name": "joseph@carepilot.com",
         "org_type": "claude_max", "alias": "personal"},
        {"num": 2, "org_uuid": TEAM_ORG, "org_name": "CarePilot",
         "org_type": "claude_team", "alias": "team"},
    ], active=1 if is_max else 2)
    profiles = claude_profiles(home=tmp_path)
    # Each reading has to report the plan its own profile holds. A reading whose
    # credential contradicts the tree is treated as the tree being out of date
    # (see _reconciled), so a fixture that gets this wrong tests that path
    # instead of this one.
    usages = [
        _claude_usage(config_dir=str(p.config_dir), plan=p.org.plan)
        for p in profiles
    ]
    return build_snapshot(usages, _now(), [], profiles=profiles)


def test_snapshot_marks_the_account_that_is_currently_paying(tmp_path: Path):
    snap = _swapped(tmp_path, MAX_ORG)
    assert {s["id"]: s["active"] for s in snap["subscriptions"]} == {
        "claude-max": True, "claude-team": False}


def test_the_active_mark_moves_with_the_swap(tmp_path: Path):
    """The whole point of putting it on the card: after cswap switches, the HUD
    has to say so, or it is reporting last hour's billing."""
    snap = _swapped(tmp_path, TEAM_ORG)
    assert {s["id"]: s["active"] for s in snap["subscriptions"]} == {
        "claude-max": False, "claude-team": True}


def test_both_claude_plans_stay_on_the_card_after_a_swap(tmp_path: Path):
    """Swapping must not make the other plan's quota disappear."""
    snap = _swapped(tmp_path, TEAM_ORG)
    assert sorted(s["id"] for s in snap["subscriptions"]) == ["claude-max", "claude-team"]


def test_codex_is_always_its_own_active_account(tmp_path: Path):
    """Codex has one login and no switcher, so whatever it holds is what a
    session spends."""
    snap = build_snapshot([_codex_usage()], _now(), [])
    assert snap["subscriptions"][0]["active"] is True


def test_an_unattributed_reading_is_never_marked_active(tmp_path: Path):
    """A reading we cannot tie to a tree cannot be shown to be the live account,
    and guessing would put the mark on the wrong plan."""
    snap = build_snapshot([_claude_usage()], _now(), [])
    assert snap["subscriptions"][0]["active"] is False
