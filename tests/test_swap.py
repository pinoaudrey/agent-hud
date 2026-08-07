"""Tests for reading account-rotation state out of claude-swap.

Same failing-closed posture as setup health: every way of not getting an answer
must produce no block at all, because a card claiming an account is active on
the strength of nothing is worse than one that says nothing.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest

import swap
from swap import collect_swap

LIST_JSON = {
    "schemaVersion": 1,
    "activeAccountNumber": 1,
    "accounts": [
        {"number": 1, "email": "a@work.com", "organizationName": "Work",
         "organizationUuid": "org-work", "active": True, "alias": "work"},
        {"number": 2, "email": "a@home.com", "organizationName": "a@home.com's Organization",
         "organizationUuid": "org-home", "active": False, "alias": "personal"},
    ],
}

CONFIG_TEXT = (
    "autoswitch.threshold              90     (default)\n"
    "autoswitch.intervalSeconds        60     (default)\n"
    "autoswitch.model                  all\n"
)


def _completed(stdout: str = "", returncode: int = 0) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr="")


def _runner(list_out=None, config_out=None, pgrep_rc=0):
    """A fake _run keyed on the command being asked for."""
    def run(args):
        if args[0] == "pgrep":
            return None if pgrep_rc is None else _completed(returncode=pgrep_rc)
        if args[-1] == "--json":
            return list_out
        return config_out
    return run


@pytest.fixture(autouse=True)
def _cswap_on_path(monkeypatch):
    monkeypatch.setattr(swap, "cswap_path", lambda: "/fake/cswap")


def test_a_healthy_answer_reduces_to_the_block():
    block = collect_swap(run=_runner(
        list_out=_completed(json.dumps(LIST_JSON)),
        config_out=_completed(CONFIG_TEXT),
        pgrep_rc=0,
    ))
    assert block == {
        "active_slot": 1,
        "accounts": [
            {"slot": 1, "alias": "work", "email": "a@work.com",
             "organization_uuid": "org-work", "subscription_id": None, "active": True},
            {"slot": 2, "alias": "personal", "email": "a@home.com",
             "organization_uuid": "org-home", "subscription_id": None, "active": False},
        ],
        "auto": {"running": True, "threshold": 90},
    }


def test_no_cswap_on_the_machine_omits_the_block(monkeypatch):
    monkeypatch.setattr(swap, "cswap_path", lambda: None)
    assert collect_swap(run=_runner()) is None


def test_a_failed_or_hung_call_omits_the_block():
    assert collect_swap(run=_runner(list_out=None)) is None
    assert collect_swap(run=_runner(list_out=_completed("", returncode=1))) is None


def test_output_that_is_not_the_contract_is_refused():
    for stdout in [
        "not json",
        json.dumps({"schemaVersion": 2, "accounts": []}),   # a shape we don't know
        json.dumps({"schemaVersion": 1, "accounts": []}),   # nothing managed
        json.dumps({"schemaVersion": 1, "accounts": [{"email": "x"}]}),  # no slot number
    ]:
        assert collect_swap(run=_runner(list_out=_completed(stdout))) is None


def test_auto_not_running_is_a_definite_answer():
    block = collect_swap(run=_runner(
        list_out=_completed(json.dumps(LIST_JSON)),
        config_out=_completed(CONFIG_TEXT),
        pgrep_rc=1,
    ))
    assert block["auto"] == {"running": False, "threshold": 90}


def test_an_unaskable_auto_question_is_null_not_off():
    """pgrep failing to run is not the same as pgrep finding nothing."""
    block = collect_swap(run=_runner(
        list_out=_completed(json.dumps(LIST_JSON)),
        config_out=_completed(CONFIG_TEXT),
        pgrep_rc=None,
    ))
    assert block["auto"] is None


def test_an_unreadable_config_costs_the_threshold_and_nothing_else():
    block = collect_swap(run=_runner(
        list_out=_completed(json.dumps(LIST_JSON)),
        config_out=_completed("garbage", returncode=1),
        pgrep_rc=0,
    ))
    assert block["auto"] == {"running": True, "threshold": None}


def test_missing_alias_and_org_decay_to_null_not_empty_string():
    raw = {
        "schemaVersion": 1,
        "activeAccountNumber": None,
        "accounts": [{"number": 3, "email": "", "active": False}],
    }
    block = collect_swap(run=_runner(
        list_out=_completed(json.dumps(raw)),
        config_out=_completed(""),
        pgrep_rc=1,
    ))
    assert block["active_slot"] is None
    account = block["accounts"][0]
    assert account["alias"] is None
    assert account["email"] is None
    assert account["organization_uuid"] is None
