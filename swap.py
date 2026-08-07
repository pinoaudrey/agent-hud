"""Account rotation state, read from claude-swap (`cswap`).

cswap manages which Claude account holds the default profile's credential and
can rotate it mid-session, which breaks the HUD's older assumption that a
config tree implies an account. `cswap list --json` is the tool's documented
scripting interface and reads its own usage cache, so polling it does not add
load on the rate-limited usage endpoint. This module runs it and reduces the
answer to what the card needs: which slots exist, which one is active, and
whether the auto-rotator is alive.

Everything fails closed, the same way setup_health does: a machine without
cswap, a hung call, or output that is not the contract produces no block at
all, so the card omits the rotation section rather than invent one. The auto
sub-block follows the same rule on its own: `None` means the question could
not be asked, never that rotation is off.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

# cswap answers from its cache in about a second; the ceiling only exists so a
# wedged call cannot hold the poll thread.
CSWAP_TIMEOUT_SECONDS = 15.0

# The one shape of `cswap list --json` this module knows how to read.
_SCHEMA_VERSION = 1


def cswap_path() -> str | None:
    """Where cswap lives. The daemon runs from a GUI context whose PATH may not
    include `~/.local/bin` (uv's tool directory), so that is tried explicitly."""
    found = shutil.which("cswap")
    if found:
        return found
    fallback = Path.home() / ".local" / "bin" / "cswap"
    return str(fallback) if fallback.is_file() else None


def _run(args: list[str]) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(args, capture_output=True, text=True,
                              timeout=CSWAP_TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        return None


def _accounts(raw: dict) -> list[dict] | None:
    """The account rows, or None when the payload is not the contract. Valid
    JSON is not enough: a malformed list reaching the card would render as a
    confident panel built from nothing."""
    entries = raw.get("accounts")
    if not isinstance(entries, list) or not entries:
        return None
    accounts = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("number"), int):
            return None
        accounts.append({
            "slot": entry["number"],
            "alias": str(entry["alias"]) if entry.get("alias") else None,
            "email": str(entry["email"]) if entry.get("email") else None,
            "organization_uuid": (str(entry["organizationUuid"])
                                  if entry.get("organizationUuid") else None),
            # Resolved against the snapshot's subscriptions by the builder;
            # the collector only knows what cswap said.
            "subscription_id": None,
            "active": bool(entry.get("active")),
        })
    return accounts


def _auto(cswap: str, run=_run) -> dict | None:
    """Whether the auto-rotator is alive, and the threshold it switches at.
    `None` when the question could not be asked — never a stand-in for "off"."""
    probe = run(["pgrep", "-f", "cswap auto"])
    if probe is None or probe.returncode not in (0, 1):
        return None
    running = probe.returncode == 0

    threshold = None
    config = run([cswap, "config"])
    if config is not None and config.returncode == 0:
        match = re.search(r"^autoswitch\.threshold\s+(\d+)", config.stdout, re.MULTILINE)
        if match:
            threshold = int(match.group(1))
    return {"running": running, "threshold": threshold}


def collect_swap(run=_run) -> dict | None:
    """The swap block, or None when the question could not be asked.

    None is not "no rotation": callers must omit the section, because a card
    claiming an account is active on the strength of nothing is worse than one
    that says nothing.
    """
    cswap = cswap_path()
    if cswap is None:
        return None
    out = run([cswap, "list", "--json"])
    if out is None or out.returncode != 0:
        return None
    try:
        raw = json.loads(out.stdout)
    except ValueError:
        return None
    if not isinstance(raw, dict) or raw.get("schemaVersion") != _SCHEMA_VERSION:
        return None
    accounts = _accounts(raw)
    if accounts is None:
        return None
    active_slot = raw.get("activeAccountNumber")
    return {
        "active_slot": active_slot if isinstance(active_slot, int) else None,
        "accounts": accounts,
        "auto": _auto(cswap, run),
    }
