"""Tests for the subscription usage collectors: window parsing, per-account
profiles, the read cache, rate-limit backoff, and OAuth token refresh."""

from __future__ import annotations

import json
import sys
import urllib.error
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import _write_jsonl, write_claude_tree


# ---------------------------------------------------------------- usage


def test_parse_claude_usage_payload():
    from usage import _parse_claude_usage

    payload = {
        "five_hour": {"utilization": 42.0, "resets_at": "2026-07-19T20:00:00+00:00"},
        "seven_day": {"utilization": 15.0, "resets_at": "2026-07-21T01:00:00+00:00"},
    }
    windows = _parse_claude_usage(payload)
    assert [w.label for w in windows] == ["5h", "7d"]
    assert windows[0].pct == 42.0
    assert windows[0].resets_at is not None


def test_parse_claude_usage_includes_fable_scoped_limit():
    from usage import _parse_claude_usage

    payload = {
        "five_hour": {"utilization": 39.0, "resets_at": "2026-07-20T22:00:00+00:00"},
        "seven_day": {"utilization": 26.0, "resets_at": "2026-07-21T00:00:00+00:00"},
        "limits": [
            {"kind": "session", "percent": 39, "resets_at": "2026-07-20T22:00:00+00:00", "scope": None},
            {"kind": "weekly_all", "percent": 26, "resets_at": "2026-07-21T00:00:00+00:00", "scope": None},
            {"kind": "weekly_scoped", "percent": 32, "resets_at": "2026-07-21T00:00:00+00:00",
             "scope": {"model": {"id": None, "display_name": "Fable"}, "surface": None}},
        ],
    }
    windows = _parse_claude_usage(payload)
    assert [w.label for w in windows] == ["5h", "7d", "fable"]  # scoped model becomes its own window
    assert windows[-1].pct == 32.0
    assert windows[-1].resets_at is not None


def test_parse_claude_usage_enterprise_spend_cap():
    from usage import _parse_claude_usage

    # An Enterprise account: every rate window null, one monthly spend block.
    payload = {
        "five_hour": None,
        "seven_day": None,
        "limits": [],
        "spend": {
            "used": {"amount_minor": 106706, "currency": "USD", "exponent": 2},
            "limit": {"amount_minor": 305000, "currency": "USD", "exponent": 2},
            "percent": 35,
            "enabled": True,
        },
    }
    windows = _parse_claude_usage(payload)
    assert [w.label for w in windows] == ["spend"]
    assert windows[0].pct == 35.0
    assert windows[0].resets_at is None


def test_parse_claude_usage_spend_ignored_when_rate_windows_exist():
    from usage import _parse_claude_usage

    # A Max account with extra-usage credits also carries a spend block; the
    # rate windows stay the card and the spend block stays off it.
    payload = {
        "five_hour": {"utilization": 41.0, "resets_at": "2026-09-19T20:40:00+00:00"},
        "seven_day": {"utilization": 28.0, "resets_at": "2026-09-24T17:00:00+00:00"},
        "spend": {"percent": 12, "enabled": True},
    }
    windows = _parse_claude_usage(payload)
    assert [w.label for w in windows] == ["5h", "7d"]


def test_window_kind_maps_spend():
    from serve import _window_kind

    assert _window_kind("claude", "spend") == "spend"
    assert _window_kind("claude", "fable") == "weekly_fable"


def test_codex_usage_from_rollouts(codex_root: Path):
    from usage import fetch_codex_usage

    # add a rate_limits event to the user-thread rollout
    rollout = next((codex_root / "sessions").glob("**/*.jsonl"))
    with rollout.open("a") as fh:
        fh.write(json.dumps(
            {"type": "event_msg", "payload": {"type": "token_count", "info": {},
             "rate_limits": {"plan_type": "pro",
                             "primary": {"used_percent": 83.0, "window_minutes": 10080, "resets_at": 1784949909},
                             "secondary": {"used_percent": 12.0, "window_minutes": 300, "resets_at": 1784900000}}}},
            separators=(",", ":")) + "\n")
    usage = fetch_codex_usage(root=codex_root)
    assert usage.error is None
    assert usage.plan == "Pro"
    labels = [w.label for w in usage.windows]
    assert labels == ["5h", "7d"]
    assert usage.windows[1].pct == 83.0


def test_opencode_usage_spend(opencode_db: Path):
    from usage import fetch_opencode_usage

    usage = fetch_opencode_usage(db_path=opencode_db)
    assert usage.error is None
    assert usage.plan == "pay-as-you-go"  # framed as a first-party plan, not "no subscription"
    assert usage.spend == 0.50
    assert usage.spend_sessions == 1
    assert usage.spend_days == 7


# ---------------------------------------------------------------- dual claude plans


def test_claude_profiles_discovers_extra_accounts(tmp_path: Path):
    from usage import claude_profiles

    write_claude_tree(tmp_path, ".claude", org_uuid="org-team",
                      org_name="CarePilot", org_type="claude_team", token="tok-team")
    write_claude_tree(tmp_path, ".claude-personal", org_uuid="org-max",
                      org_name="joseph@carepilot.com", org_type="claude_max", token="tok-personal")

    profiles = claude_profiles(home=tmp_path)
    assert [p.label for p in profiles] == ["team", "max"]
    assert profiles[0].default is True and profiles[1].default is False
    assert profiles[1].config_dir == tmp_path / ".claude-personal"


def test_profile_credentials_from_file(tmp_path: Path):
    from usage import ClaudeProfile, _profile_credentials

    d = write_claude_tree(tmp_path, ".claude-personal", org_uuid="org-max",
                          org_name="joseph@carepilot.com", org_type="claude_max",
                          sub_type="claude_max_20x", token="tok-xyz")
    creds = _profile_credentials(ClaudeProfile(label="max", config_dir=d))
    assert creds.token == "tok-xyz"
    assert creds.plan == "Max 20X"
    assert creds.file_path == d / ".credentials.json"  # write refreshes back here


def test_fetch_claude_usages_stamp_the_tree_they_came_from(monkeypatch: pytest.MonkeyPatch):
    """A reading has to say which config tree produced it, because that is the
    only thing the caller can attribute it by. A label two accounts could share
    is not."""
    import usage as usage_module
    from usage import ClaudeProfile, ToolUsage

    profiles = [
        ClaudeProfile(label="max", config_dir=Path("/x/.claude"), default=True),
        ClaudeProfile(label="team", config_dir=Path("/x/.claude-team")),
    ]
    monkeypatch.setattr(usage_module, "fetch_claude_usage_for",
                        lambda p, force=False: ToolUsage(tool="claude", plan=p.label.title()))

    usages = usage_module.fetch_claude_usages(profiles)
    assert [u.config_dir for u in usages] == ["/x/.claude", "/x/.claude-team"]


def test_fetch_claude_usages_discovers_profiles_when_not_given_any(monkeypatch: pytest.MonkeyPatch):
    import usage as usage_module
    from usage import ClaudeProfile, ToolUsage

    profiles = [ClaudeProfile(label="max", config_dir=Path("/x/.claude"), default=True)]
    monkeypatch.setattr(usage_module, "claude_profiles", lambda home=None: profiles)
    monkeypatch.setattr(usage_module, "fetch_claude_usage_for",
                        lambda p, force=False: ToolUsage(tool="claude"))
    assert [u.config_dir for u in usage_module.fetch_claude_usages()] == ["/x/.claude"]



# ------------------------------------------------- usage cache + rate limiting


@pytest.fixture
def usage_probe(monkeypatch: pytest.MonkeyPatch):
    """A stubbed usage endpoint with a call counter, plus a clean cache.

    Returns (profile, probe) where probe.calls counts endpoint hits and
    probe.fail is set to a RateLimited instance to make the next call 429.
    """
    import usage as usage_module
    from usage import ClaudeCredentials, ClaudeProfile, ToolUsage, UsageWindow

    usage_module._claude_cache.clear()

    class Probe:
        calls = 0
        fail: Exception | None = None  # set to RateLimited/Unauthorized to raise on the next call
        fail_calls: int | None = None  # how many calls `fail` applies to; None means every one
        error: str | None = None  # set to simulate a transient (non-429) failure
        pct = 40.0
        refreshes = 0
        refresh_ok = True  # flip off to simulate a dead/revoked refresh token
        expires_in = 3600.0  # seconds from now on the stored access token
        tokens: list[str] = []  # every access token the endpoint was called with

    probe = Probe()
    probe.tokens = []

    def fake_fetch(token: str, plan: str) -> ToolUsage:
        probe.calls += 1
        probe.tokens.append(token)
        if probe.fail is not None and probe.fail_calls != 0:
            if probe.fail_calls is not None:
                probe.fail_calls -= 1
            raise probe.fail
        if probe.error is not None:
            return ToolUsage(tool="claude", plan=plan, error=probe.error)
        return ToolUsage(tool="claude", plan=plan, windows=[UsageWindow("5h", probe.pct)])

    def fake_creds(profile):
        return ClaudeCredentials(
            oauth={"accessToken": "tok", "refreshToken": "r", "subscriptionType": "max",
                   "expiresAt": int((time.time() + probe.expires_in) * 1000)},
            keychain_service="svc")

    def fake_refresh(creds):
        probe.refreshes += 1
        if not probe.refresh_ok:
            return None
        return ClaudeCredentials(
            oauth={**creds.oauth, "accessToken": "tok-refreshed",
                   "expiresAt": int((time.time() + 28800) * 1000)},
            keychain_service=creds.keychain_service)

    monkeypatch.setattr(usage_module, "_profile_credentials", fake_creds)
    monkeypatch.setattr(usage_module, "_refresh_claude_token", fake_refresh)
    monkeypatch.setattr(usage_module, "_claude_usage_from_token", fake_fetch)
    yield ClaudeProfile(label="personal", config_dir=Path("/x/.claude-personal")), probe
    usage_module._claude_cache.clear()


def test_claude_usage_serves_cache_within_ttl(usage_probe):
    import usage as usage_module

    profile, probe = usage_probe
    first = usage_module.fetch_claude_usage_for(profile)
    second = usage_module.fetch_claude_usage_for(profile)

    assert probe.calls == 1  # the second read never touched the endpoint
    assert first.windows[0].pct == second.windows[0].pct == 40.0
    assert not second.stale  # a fresh cache hit isn't flagged as old

    # the manual refresh key skips the freshness check
    usage_module.fetch_claude_usage_for(profile, force=True)
    assert probe.calls == 2

    # ...but an expired entry refetches on its own
    entry = usage_module._claude_cache[str(profile.config_dir)]
    entry.fetched_at -= usage_module.USAGE_CACHE_TTL_SECONDS + 1
    usage_module.fetch_claude_usage_for(profile)
    assert probe.calls == 3


def test_claude_cache_hands_out_copies(usage_probe):
    """fetch_claude_usages stamps .config_dir on what it gets back; if that were
    the cached object the stamp would leak into every later read."""
    import usage as usage_module

    profile, _ = usage_probe
    first = usage_module.fetch_claude_usage_for(profile)
    first.config_dir = "/x/.claude-somewhere-else"
    second = usage_module.fetch_claude_usage_for(profile)
    assert second.config_dir == ""


def test_claude_429_keeps_last_bars_and_backs_off(usage_probe):
    import usage as usage_module

    profile, probe = usage_probe
    usage_module.fetch_claude_usage_for(profile)  # prime the cache with real bars
    probe.fail = usage_module.RateLimited()

    limited = usage_module.fetch_claude_usage_for(profile, force=True)
    assert limited.windows[0].pct == 40.0  # last good reading survives the 429
    assert limited.error is None  # no raw "HTTP Error 429" splattered on the row
    assert "rate limited" in limited.stale

    # inside the cooldown we stop asking entirely, even when the user mashes `r`
    calls_before = probe.calls
    again = usage_module.fetch_claude_usage_for(profile, force=True)
    assert probe.calls == calls_before
    assert "rate limited" in again.stale

    entry = usage_module._claude_cache[str(profile.config_dir)]
    assert entry.backoff == usage_module.RATE_LIMIT_BACKOFF_START

    # a repeat 429 once the cooldown lapses doubles the penalty
    entry.cooldown_until = 0.0
    usage_module.fetch_claude_usage_for(profile, force=True)
    assert entry.backoff == usage_module.RATE_LIMIT_BACKOFF_START * 2
    assert entry.backoff <= usage_module.RATE_LIMIT_BACKOFF_MAX


def test_claude_429_recovery_clears_backoff(usage_probe):
    import usage as usage_module

    profile, probe = usage_probe
    usage_module.fetch_claude_usage_for(profile)
    probe.fail = usage_module.RateLimited()
    usage_module.fetch_claude_usage_for(profile, force=True)

    entry = usage_module._claude_cache[str(profile.config_dir)]
    entry.cooldown_until = 0.0
    probe.fail, probe.pct = None, 55.0
    recovered = usage_module.fetch_claude_usage_for(profile, force=True)

    assert recovered.windows[0].pct == 55.0
    assert not recovered.stale
    assert entry.backoff == 0.0 and entry.cooldown_until == 0.0


def test_claude_429_honors_retry_after(usage_probe):
    import usage as usage_module

    profile, probe = usage_probe
    probe.fail = usage_module.RateLimited(retry_after=45.0)
    limited = usage_module.fetch_claude_usage_for(profile)

    # no cached reading yet, so the marker lands in the error slot -- but short,
    # and using the server's own number rather than our default backoff
    assert limited.error == "rate limited · retry 45s"
    entry = usage_module._claude_cache[str(profile.config_dir)]
    assert 40 < entry.cooldown_until - time.monotonic() <= 45


def test_expired_token_is_refreshed_before_the_call(usage_probe):
    """The bug behind the blank plan cards: Claude Code only mints a new access
    token when it makes its own API call, so an account left idle overnight has
    a dead token sitting in the Keychain. Sending it is a guaranteed 401."""
    import usage as usage_module

    profile, probe = usage_probe
    probe.expires_in = -86400  # expired a day ago, like the personal account was

    usage = usage_module.fetch_claude_usage_for(profile)

    assert probe.refreshes == 1
    assert probe.tokens == ["tok-refreshed"]  # the dead one was never sent
    assert usage.windows[0].pct == 40.0 and not usage.error


def test_401_refreshes_once_and_retries(usage_probe):
    """A live-looking token can still be refused (revoked, or rotated by another
    tool). One refresh, one retry -- not a silent failure."""
    import usage as usage_module

    profile, probe = usage_probe
    probe.fail, probe.fail_calls = usage_module.Unauthorized(), 1  # refused once, then fine

    usage = usage_module.fetch_claude_usage_for(profile)

    assert probe.refreshes == 1
    assert probe.tokens == ["tok", "tok-refreshed"]
    assert usage.windows[0].pct == 40.0 and not usage.error


def test_dead_credential_backs_off_instead_of_hammering(usage_probe):
    """What turned a fixable auth problem into an hour-long 429 lockout: a 401
    was treated as transient, so the daemon re-fired every poll forever. A
    credential that needs a human can't heal on the next poll."""
    import usage as usage_module

    profile, probe = usage_probe
    probe.fail = usage_module.Unauthorized()
    probe.refresh_ok = False  # the refresh token is dead too

    first = usage_module.fetch_claude_usage_for(profile)
    assert "claude auth login" in first.error  # says what to actually do

    calls_before, refreshes_before = probe.calls, probe.refreshes
    for _ in range(5):
        again = usage_module.fetch_claude_usage_for(profile, force=True)
    assert probe.calls == calls_before  # never touched the endpoint again
    assert probe.refreshes == refreshes_before
    assert "claude auth login" in again.error

    entry = usage_module._claude_cache[str(profile.config_dir)]
    assert entry.cooldown_until - time.monotonic() > usage_module.USAGE_CACHE_TTL_SECONDS
    assert usage_module.AUTH_FAILURE_COOLDOWN_SECONDS >= 600


def test_dead_credential_keeps_the_last_known_bars(usage_probe):
    """Losing auth shouldn't blank a card that had a real number a minute ago."""
    import usage as usage_module

    profile, probe = usage_probe
    usage_module.fetch_claude_usage_for(profile)  # a good reading first
    probe.fail = usage_module.Unauthorized()
    probe.refresh_ok = False

    degraded = usage_module.fetch_claude_usage_for(profile, force=True)
    assert degraded.windows[0].pct == 40.0
    assert "claude auth login" in degraded.stale
    assert degraded.error is None


def test_transient_error_keeps_the_last_known_bars(usage_probe):
    """A network blip is not a reason to throw away a good reading."""
    import usage as usage_module

    profile, probe = usage_probe
    usage_module.fetch_claude_usage_for(profile)
    probe.error = "urlopen error timed out"

    degraded = usage_module.fetch_claude_usage_for(profile, force=True)
    assert degraded.windows[0].pct == 40.0
    assert "timed out" in degraded.stale


def test_recovering_from_a_dead_credential_clears_the_cooldown(usage_probe):
    import usage as usage_module

    profile, probe = usage_probe
    probe.fail = usage_module.Unauthorized()
    probe.refresh_ok = False
    usage_module.fetch_claude_usage_for(profile)

    entry = usage_module._claude_cache[str(profile.config_dir)]
    entry.cooldown_until = 0.0  # as if the cooldown lapsed
    probe.fail, probe.refresh_ok = None, True

    recovered = usage_module.fetch_claude_usage_for(profile, force=True)
    assert recovered.windows[0].pct == 40.0
    assert not recovered.stale and entry.cooldown_until == 0.0


def test_transient_error_is_not_cached(usage_probe):
    """A network blip should retry on the next poll, not stick around for the
    whole TTL the way a good reading does."""
    import usage as usage_module

    profile, probe = usage_probe
    probe.error = "urlopen error timed out"

    first = usage_module.fetch_claude_usage_for(profile)
    assert first.error == "urlopen error timed out"

    second = usage_module.fetch_claude_usage_for(profile)
    assert probe.calls == 2  # retried immediately rather than serving the failure
    assert usage_module._claude_cache[str(profile.config_dir)].usage is None




# --------------------------------------------------------------- keychain



def test_keychain_service_hashes_nondefault_config_dir():
    import hashlib
    from usage import ClaudeProfile, _keychain_service

    default = ClaudeProfile(label="team", config_dir=Path("/Users/j/.claude"), default=True)
    assert _keychain_service(default) == "Claude Code-credentials"

    personal = ClaudeProfile(label="personal", config_dir=Path("/Users/j/.claude-personal"))
    digest = hashlib.sha256(b"/Users/j/.claude-personal").hexdigest()[:8]
    assert _keychain_service(personal) == f"Claude Code-credentials-{digest}"


def test_profile_credentials_reads_hashed_keychain_when_no_file(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    import usage as usage_module
    from usage import ClaudeProfile, _profile_credentials

    d = tmp_path / ".claude-personal"
    d.mkdir()  # no .credentials.json -> must fall back to keychain
    seen = {}

    def fake_keychain(service="Claude Code-credentials"):
        seen["service"] = service
        return usage_module.ClaudeCredentials(
            oauth={"accessToken": "tok-personal", "subscriptionType": "claude_max_20x"},
            keychain_service=service)

    monkeypatch.setattr(usage_module, "_keychain_claude_credentials", fake_keychain)
    creds = _profile_credentials(ClaudeProfile(label="personal", config_dir=d))
    assert creds.token == "tok-personal" and creds.plan == "Max 20X"
    assert seen["service"] == usage_module._keychain_service(ClaudeProfile(label="personal", config_dir=d))
    assert creds.keychain_service == seen["service"]  # refreshes write back to the same item


# --------------------------------------------------- oauth token refresh


def _oauth_creds(**over) -> "usage_module.ClaudeCredentials":  # type: ignore[name-defined]
    import usage as usage_module

    oauth = {
        "accessToken": "tok-old",
        "refreshToken": "refresh-old",
        "expiresAt": int((time.time() + 3600) * 1000),
        "subscriptionType": "max",
        "scopes": ["user:inference"],
    }
    oauth.update(over.pop("oauth", {}))
    return usage_module.ClaudeCredentials(oauth=oauth, keychain_service="Claude Code-credentials-abc", **over)


def test_credentials_expiry_uses_a_refresh_skew():
    """A token that dies in the next few minutes is already useless to a poller
    that only wakes every 3 minutes, so it counts as expired."""
    import usage as usage_module

    live = _oauth_creds()
    assert live.expired() is False

    dying = _oauth_creds(oauth={"expiresAt": int((time.time() + 60) * 1000)})
    assert dying.expired() is True  # inside the skew

    dead = _oauth_creds(oauth={"expiresAt": int((time.time() - 86400) * 1000)})
    assert dead.expired() is True

    # an entry with no expiry recorded can't be judged; assume it's usable
    unknown = _oauth_creds(oauth={"expiresAt": None})
    assert unknown.expired() is False
    assert usage_module.TOKEN_REFRESH_SKEW_SECONDS > 0


def test_refresh_persists_rotated_credentials(monkeypatch: pytest.MonkeyPatch):
    """The server may hand back a new refresh token. Keeping it only in memory
    would leave Claude Code holding a dead one, so it must be written back."""
    import usage as usage_module

    posted = {}

    def fake_post(url, body, timeout=10):
        posted["url"], posted["body"] = url, body
        return {
            "access_token": "tok-new",
            "refresh_token": "refresh-new",
            "expires_in": 28800,
            "refresh_token_expires_in": 2592000,
        }

    saved = {}
    monkeypatch.setattr(usage_module, "_post_json", fake_post)
    monkeypatch.setattr(usage_module, "_persist_credentials", lambda c: saved.setdefault("oauth", c.oauth) or True)

    fresh = usage_module._refresh_claude_token(_oauth_creds(oauth={"expiresAt": 0}))

    assert posted["url"] == usage_module.CLAUDE_OAUTH_TOKEN_URL
    assert posted["body"]["grant_type"] == "refresh_token"
    assert posted["body"]["refresh_token"] == "refresh-old"
    assert posted["body"]["client_id"] == usage_module.CLAUDE_OAUTH_CLIENT_ID

    assert fresh.token == "tok-new"
    assert fresh.oauth["refreshToken"] == "refresh-new"  # rotation taken up
    assert fresh.expired() is False
    assert saved["oauth"]["refreshToken"] == "refresh-new"  # ...and written back
    assert saved["oauth"]["subscriptionType"] == "max"  # untouched fields survive


def test_refresh_keeps_old_refresh_token_when_server_omits_one(monkeypatch: pytest.MonkeyPatch):
    import usage as usage_module

    monkeypatch.setattr(usage_module, "_post_json",
                        lambda url, body, timeout=10: {"access_token": "tok-new", "expires_in": 3600})
    monkeypatch.setattr(usage_module, "_persist_credentials", lambda c: True)

    fresh = usage_module._refresh_claude_token(_oauth_creds())
    assert fresh.oauth["refreshToken"] == "refresh-old"


def test_refresh_returns_none_when_the_grant_is_refused(monkeypatch: pytest.MonkeyPatch):
    import usage as usage_module

    monkeypatch.setattr(usage_module, "_post_json", lambda url, body, timeout=10: None)
    persisted = []
    monkeypatch.setattr(usage_module, "_persist_credentials", lambda c: persisted.append(c))

    assert usage_module._refresh_claude_token(_oauth_creds()) is None
    assert persisted == []  # nothing to write when the refresh failed


def test_keychain_write_round_trips_a_quoted_payload(monkeypatch: pytest.MonkeyPatch):
    """The blob is JSON, so it is full of the quotes and backslashes that
    `security -i` treats as syntax. Verify what we hand the tool is escaped."""
    import usage as usage_module

    captured = {}

    class Result:
        returncode = 0

    def fake_run(argv, **kw):
        captured["argv"], captured["input"] = argv, kw.get("input")
        return Result()

    monkeypatch.setattr(usage_module.subprocess, "run", fake_run)
    creds = usage_module.ClaudeCredentials(
        oauth={"accessToken": 'a"b\\c'}, keychain_service="Claude Code-credentials-abc")
    assert usage_module._persist_credentials(creds) is True

    assert captured["argv"][:2] == ["security", "-i"]  # payload over stdin, never argv
    assert 'a"b\\c' not in captured["argv"]
    line = captured["input"]
    assert "add-generic-password -U" in line and "Claude Code-credentials-abc" in line
    assert '\\"' in line and "\\\\" in line  # quotes and backslashes escaped for the tool




def test_a_codex_reading_falls_back_to_the_rollout_mtime_without_an_event_timestamp(tmp_path: Path):
    """Codex has no API to ask, so its numbers are exactly as old as the file a
    turn last wrote. That age has to travel with the reading, or a percentage
    from three days ago is drawn like one from three minutes ago."""
    import os
    from usage import fetch_codex_usage

    root = tmp_path / "codex"
    rollout = root / "sessions" / "2026" / "07" / "30" / "rollout-2026-07-30T10-00-00-abc.jsonl"
    _write_jsonl(rollout, [
        {"type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
            "primary": {"window_minutes": 10080, "used_percent": 19.0, "resets_at": None},
        }}},
    ])
    stamp = time.time() - 3 * 86400
    os.utime(rollout, (stamp, stamp))

    usage = fetch_codex_usage(root=root)
    assert usage.error is None
    assert usage.windows and usage.windows[0].pct == 19.0
    assert usage.read_at is not None
    assert abs(usage.read_at.timestamp() - stamp) < 2


def test_codex_usage_uses_the_newest_rate_limit_event_not_the_newest_file(tmp_path: Path):
    """Another active session can touch a file after a newer rate-limit event
    was written elsewhere. File mtime would turn that unrelated write into a
    false 100%-remaining reading, so event time decides when it exists."""
    import os
    from usage import fetch_codex_usage

    root = tmp_path / "codex"
    newer_event = root / "sessions" / "2026" / "08" / "04" / "rollout-current.jsonl"
    later_file_write = root / "sessions" / "2026" / "08" / "04" / "rollout-other-session.jsonl"
    _write_jsonl(newer_event, [
        {"timestamp": "2026-08-04T20:47:37.575Z", "type": "event_msg", "payload": {
            "type": "token_count", "rate_limits": {
                "plan_type": "pro",
                "primary": {"window_minutes": 10080, "used_percent": 38.0, "resets_at": None},
            },
        }},
    ])
    _write_jsonl(later_file_write, [
        {"timestamp": "2026-08-04T20:46:55.957Z", "type": "event_msg", "payload": {
            "type": "token_count", "rate_limits": {
                "plan_type": "pro",
                "primary": {"window_minutes": 10080, "used_percent": 0.0, "resets_at": None},
            },
        }},
    ])
    now = time.time()
    os.utime(newer_event, (now - 60, now - 60))
    os.utime(later_file_write, (now, now))

    usage = fetch_codex_usage(root=root)
    assert usage.windows and usage.windows[0].pct == 38.0
    assert usage.read_at is not None
    assert usage.read_at.isoformat() == "2026-08-04T20:47:37.575000+00:00"


def test_codex_usage_prefers_the_account_limit_over_a_newer_model_limit(tmp_path: Path):
    """A model-specific limit is not the account-wide Codex quota shown in the HUD."""
    from usage import fetch_codex_usage

    root = tmp_path / "codex"
    account = root / "sessions" / "2026" / "08" / "04" / "rollout-account.jsonl"
    model = root / "sessions" / "2026" / "08" / "04" / "rollout-model.jsonl"
    _write_jsonl(account, [
        {"timestamp": "2026-08-04T21:08:57.263Z", "type": "event_msg", "payload": {
            "type": "token_count", "rate_limits": {
                "plan_type": "pro", "limit_id": "codex",
                "primary": {"window_minutes": 10080, "used_percent": 39.0, "resets_at": None},
            },
        }},
    ])
    _write_jsonl(model, [
        {"timestamp": "2026-08-04T21:18:58.050Z", "type": "event_msg", "payload": {
            "type": "token_count", "rate_limits": {
                "plan_type": "pro", "limit_id": "codex_bengalfox",
                "primary": {"window_minutes": 10080, "used_percent": 0.0, "resets_at": None},
            },
        }},
    ])

    usage = fetch_codex_usage(root=root)
    assert usage.windows and usage.windows[0].pct == 39.0
    assert usage.read_at is not None
    assert usage.read_at.isoformat() == "2026-08-04T21:08:57.263000+00:00"
