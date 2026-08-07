"""Tests for subscription identity: which organization a config tree belongs to,
and how trees collapse into subscriptions.

The three bugs this replaces all came from inferring identity from *where* a
config directory sat rather than *what account* it held, so every test here
pins the behaviour to the organization and none of them to a path.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import write_claude_tree, write_cswap_store
from subscriptions import (
    ClaudeOrg,
    ClaudeProfile,
    claude_profiles,
    claude_subscriptions,
    subscription_index,
)

MAX_ORG = "3f3b964d-1111-2222-3333-444444444444"
TEAM_ORG = "780d6270-5555-6666-7777-888888888888"


def _machine(tmp_path: Path) -> Path:
    """The real shape of this machine: a personal Max org in the default tree and
    a work Team org in a sibling, both belonging to one person."""
    write_claude_tree(tmp_path, ".claude", org_uuid=MAX_ORG,
                      org_name="joseph@carepilot.com", org_type="claude_max")
    write_claude_tree(tmp_path, ".claude-team", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    return tmp_path


# ------------------------------------------------------- reading the account


def test_default_tree_reads_its_metadata_from_beside_the_tree(tmp_path: Path):
    """The regression: the default account's metadata is at ~/.claude.json, not
    inside ~/.claude, so reading the tree's own copy left it unidentifiable."""
    write_claude_tree(tmp_path, ".claude", org_uuid=MAX_ORG,
                      org_name="joseph@carepilot.com", org_type="claude_max")
    # Claude Code also leaves an empty .claude.json *inside* the tree; picking
    # that one up is exactly how the account went unnamed.
    (tmp_path / ".claude" / ".claude.json").write_text("{}")

    profile = claude_profiles(home=tmp_path)[0]
    assert profile.default is True
    assert profile.org is not None and profile.org.uuid == MAX_ORG
    assert profile.org.plan == "Max"


def test_default_tree_labels_as_max_when_that_is_what_it_holds(tmp_path: Path):
    write_claude_tree(tmp_path, ".claude", org_uuid=MAX_ORG,
                      org_name="joseph@carepilot.com", org_type="claude_max")
    subs = claude_subscriptions(claude_profiles(home=tmp_path))
    assert [(s.id, s.label) for s in subs] == [("claude-max", "Claude Max")]


def test_a_signed_out_tree_is_still_reported(tmp_path: Path):
    """No account to read is not the same as no tree. It keeps its directory
    name so the row still says which tree it is."""
    write_claude_tree(tmp_path, ".claude", org_uuid=None)
    write_claude_tree(tmp_path, ".claude-spare", org_uuid=None)
    subs = claude_subscriptions(claude_profiles(home=tmp_path))
    assert [s.id for s in subs] == ["claude-default", "claude-spare"]
    # and two unreadable trees are never assumed to be the same subscription
    assert len(subs) == 2


# --------------------------------------------------------------- collapsing


def test_two_trees_on_one_org_collapse_to_one_subscription(tmp_path: Path):
    """Signing two config trees into the same organization is one plan with one
    quota. Reporting it twice double-counts the headroom."""
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    write_claude_tree(tmp_path, ".claude-work", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")

    subs = claude_subscriptions(claude_profiles(home=tmp_path))
    assert len(subs) == 1
    assert subs[0].id == "claude-team"
    assert subs[0].trees == ["~/.claude", "~/.claude-work"]


def test_two_trees_on_two_orgs_stay_separate(tmp_path: Path):
    """The same human owns both, so accountUuid matches. Keying on it would
    collapse two real subscriptions; keying on the organization does not."""
    subs = claude_subscriptions(claude_profiles(home=_machine(tmp_path)))
    assert [(s.id, s.label) for s in subs] == [
        ("claude-max", "Claude Max"),
        ("claude-team", "Claude Team"),
    ]
    assert [s.trees for s in subs] == [["~/.claude"], ["~/.claude-team"]]


def test_two_orgs_on_one_plan_are_told_apart_by_name(tmp_path: Path):
    """Two Team organizations both want to be `claude-team`. The organization
    name breaks the tie, so neither silently swallows the other."""
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    write_claude_tree(tmp_path, ".claude-other", org_uuid="99999999-aaaa",
                      org_name="Other Co", org_type="claude_team")

    subs = claude_subscriptions(claude_profiles(home=tmp_path))
    assert sorted(s.id for s in subs) == ["claude-team-carepilot", "claude-team-other-co"]
    assert sorted(s.label for s in subs) == ["Claude Team (CarePilot)", "Claude Team (Other Co)"]


def test_two_unnamed_orgs_on_one_plan_fall_back_to_the_uuid(tmp_path: Path):
    """Personal orgs are named after the account's email, which is the same on
    both, so the only thing guaranteed to differ is the organization uuid."""
    write_claude_tree(tmp_path, ".claude", org_uuid="aaaaaaaa-1111",
                      org_name="joseph@carepilot.com", org_type="claude_max")
    write_claude_tree(tmp_path, ".claude-second", org_uuid="bbbbbbbb-2222",
                      org_name="joseph@carepilot.com", org_type="claude_max")

    subs = claude_subscriptions(claude_profiles(home=tmp_path))
    assert sorted(s.id for s in subs) == ["claude-max-aaaaaaaa", "claude-max-bbbbbbbb"]


# ------------------------------------------------------------------- naming


def test_an_unknown_plan_shows_up_as_itself(tmp_path: Path):
    """A tier this build has never heard of must not vanish into a fallback."""
    write_claude_tree(tmp_path, ".claude", org_uuid=MAX_ORG,
                      org_name="joseph@carepilot.com", org_type="claude_ultra")
    subs = claude_subscriptions(claude_profiles(home=tmp_path))
    assert [(s.id, s.label) for s in subs] == [("claude-ultra", "Claude Ultra")]


def test_org_named_after_an_email_never_becomes_the_label(tmp_path: Path):
    """A personal org is named after the account's own address, which is a
    stand-in for a name rather than one."""
    org = ClaudeOrg(uuid="x", name="joseph@carepilot.com", type="claude_max")
    profile = ClaudeProfile(label="max", config_dir=Path("/x/.claude"), default=True, org=org)
    sub = claude_subscriptions([profile])[0]
    assert "@" not in sub.id and "@" not in sub.label


# -------------------------------------------------------------- attribution


def test_index_maps_every_tree_to_its_subscription(tmp_path: Path):
    write_claude_tree(tmp_path, ".claude", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")
    write_claude_tree(tmp_path, ".claude-work", org_uuid=TEAM_ORG,
                      org_name="CarePilot", org_type="claude_team")

    index = subscription_index(claude_profiles(home=tmp_path))
    assert set(index) == {str(tmp_path / ".claude"), str(tmp_path / ".claude-work")}
    assert {sub.id for sub in index.values()} == {"claude-team"}


def test_a_malformed_metadata_file_is_tolerated(tmp_path: Path):
    write_claude_tree(tmp_path, ".claude", org_uuid=None)
    (tmp_path / ".claude.json").write_text("not json{")
    profiles = claude_profiles(home=tmp_path)
    assert profiles[0].org is None  # unreadable, not a crash


def test_metadata_without_an_org_is_not_an_identity(tmp_path: Path):
    """An oauthAccount that has an email but no organizationUuid tells us who
    the human is, not which subscription pays. That is not enough to key on."""
    tree = tmp_path / ".claude"
    tree.mkdir(parents=True)
    (tmp_path / ".claude.json").write_text(
        json.dumps({"oauthAccount": {"accountUuid": "b46054a2", "emailAddress": "j@x.com"}})
    )
    assert claude_profiles(home=tmp_path)[0].org is None


# ------------------------------------------------------------- claude-swap


def _swapped_machine(tmp_path: Path, active_org: str = MAX_ORG) -> Path:
    """The machine after the hand-made `~/.claude-team` is gone: one default tree
    holding whichever account is signed in, and a cswap profile per account."""
    write_claude_tree(tmp_path, ".claude", org_uuid=active_org,
                      org_name="joseph@carepilot.com" if active_org == MAX_ORG else "CarePilot",
                      org_type="claude_max" if active_org == MAX_ORG else "claude_team")
    write_cswap_store(tmp_path, [
        {"num": 1, "org_uuid": MAX_ORG, "org_name": "joseph@carepilot.com",
         "org_type": "claude_max", "alias": "personal"},
        {"num": 2, "org_uuid": TEAM_ORG, "org_name": "CarePilot",
         "org_type": "claude_team", "alias": "team"},
    ], active=1 if active_org == MAX_ORG else 2)
    return tmp_path


def test_both_subscriptions_survive_with_no_sibling_tree(tmp_path: Path):
    """The point of the whole change: with `~/.claude-team` deleted, the Team
    seat has to keep showing up, and it does because cswap's session profile is
    a config tree in its own right."""
    subs = claude_subscriptions(claude_profiles(home=_swapped_machine(tmp_path)))
    assert [(s.id, s.label) for s in subs] == [
        ("claude-max", "Claude Max"),
        ("claude-team", "Claude Team"),
    ]


def test_the_swapped_out_account_still_reports(tmp_path: Path):
    """Swapping to the Team seat must not make the Max plan's quota vanish from
    the card. Both accounts keep a profile, so both stay readable whichever one
    `~/.claude` currently holds."""
    subs = claude_subscriptions(claude_profiles(home=_swapped_machine(tmp_path, TEAM_ORG)))
    assert sorted(s.id for s in subs) == ["claude-max", "claude-team"]


def test_active_follows_whichever_account_is_signed_in(tmp_path: Path):
    """`active` is what the card marks, and it has to track the swap rather than
    a fixed tree, since a bare `claude` bills whatever `~/.claude` holds."""
    on_max = claude_subscriptions(claude_profiles(home=_swapped_machine(tmp_path)))
    assert {s.id: s.active for s in on_max} == {"claude-max": True, "claude-team": False}


def test_active_moves_when_the_account_is_swapped(tmp_path: Path):
    on_team = claude_subscriptions(claude_profiles(home=_swapped_machine(tmp_path, TEAM_ORG)))
    assert {s.id: s.active for s in on_team} == {"claude-max": False, "claude-team": True}


def test_exactly_one_subscription_is_ever_active(tmp_path: Path):
    """Two rows both claiming to be the live account would be worse than none."""
    subs = claude_subscriptions(claude_profiles(home=_swapped_machine(tmp_path)))
    assert sum(1 for s in subs if s.active) == 1


def test_the_active_account_collapses_with_its_own_profile(tmp_path: Path):
    """`~/.claude` and the profile for the same slot are one organization, so
    they are one subscription — reporting them separately would double-count the
    active plan's headroom, which is the bug this module was written to stop."""
    subs = claude_subscriptions(claude_profiles(home=_swapped_machine(tmp_path)))
    max_sub = next(s for s in subs if s.id == "claude-max")
    assert max_sub.trees == ["~/.claude", "cswap:personal"]


def test_a_profile_is_named_by_its_alias_not_its_directory(tmp_path: Path):
    """The profile directory is a slot number and a mangled email. `cswap:team`
    is what the person types, so it is what the card shows."""
    subs = claude_subscriptions(claude_profiles(home=_swapped_machine(tmp_path)))
    team = next(s for s in subs if s.id == "claude-team")
    assert team.trees == ["cswap:team"]


def test_the_cswap_backup_root_is_not_a_config_tree(tmp_path: Path):
    """`.claude-swap-backup` matches the `.claude-*` glob that finds sibling
    trees. Left in, it reports as a signed-out subscription called
    "swap-backup" that no account will ever fill."""
    subs = claude_subscriptions(claude_profiles(home=_swapped_machine(tmp_path)))
    assert not any("swap" in s.id for s in subs)


def test_an_unaliased_slot_falls_back_to_its_plan(tmp_path: Path):
    """An account added without `cswap alias` still has to name itself."""
    write_claude_tree(tmp_path, ".claude", org_uuid=MAX_ORG,
                      org_name="joseph@carepilot.com", org_type="claude_max")
    write_cswap_store(tmp_path, [
        {"num": 2, "org_uuid": TEAM_ORG, "org_name": "CarePilot", "org_type": "claude_team"},
    ])
    team = next(s for s in claude_subscriptions(claude_profiles(home=tmp_path))
                if s.id == "claude-team")
    assert team.profiles[0].label == "team"


def test_a_machine_with_no_cswap_is_unchanged(tmp_path: Path):
    """cswap is not a dependency. A machine that has never installed it must
    report exactly what it did before."""
    subs = claude_subscriptions(claude_profiles(home=_machine(tmp_path)))
    assert [s.trees for s in subs] == [["~/.claude"], ["~/.claude-team"]]
    assert [s.active for s in subs] == [True, False]
