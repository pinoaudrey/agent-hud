"""Which Claude subscriptions this machine has, and what to call them.

A Claude subscription is an *organization*, not a directory. Claude Code keeps
one config tree per account you are signed into — the built-in `~/.claude` plus
any sibling `~/.claude-<name>` made with CLAUDE_CONFIG_DIR — but the tree is
just where the session state lives. What decides whose quota a session spends
is the organization the tree is logged into, and one person can hold several
(a personal Max org and a work Team org), or point two trees at the same one.

So everything here keys on `organizationUuid`. Two trees on one org collapse
into a single subscription that names both; two trees on different orgs stay
apart even when they belong to the same human. `accountUuid` deliberately plays
no part: it is the same person on both, so keying on it would fold two real
subscriptions into one and halve the quota the HUD reports.

The account metadata is a plain JSON file Claude Code maintains. For the default
tree it lives at `~/.claude.json`; a tree opened with CLAUDE_CONFIG_DIR keeps its
own copy inside the tree. Reading the wrong one is how the default account ended
up unidentifiable.

Sibling trees are no longer the only place an account lives. claude-swap keeps a
per-account profile under `~/.claude-swap-backup/sessions/<slot>-<email>/`, which
is a config tree in every respect that matters here: it holds its own
`.claude.json` and its own credentials, and Claude Code runs against it whenever
`cswap run` points `CLAUDE_CONFIG_DIR` at it. Treating those profiles as trees is
what keeps every subscription on the card once the hand-made `~/.claude-team` is
gone.

It also changes what `~/.claude` means. It used to be one fixed account; under
claude-swap it is whichever account is *currently* signed in, and swapping
rewrites its `oauthAccount` in place. So the default tree no longer identifies a
subscription, it identifies the active one — which is why `ClaudeSubscription`
exposes `active` and why every account needs a session profile of its own. An
account with no profile drops off the card the moment it is swapped out of
`~/.claude`, and reappears when it is swapped back, which reads as quota
vanishing.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

# claude-swap's store. macOS and Windows keep the legacy layout; Linux and WSL
# follow XDG. Both are checked rather than detecting the platform, since the
# wrong guess silently loses every account that has no sibling tree.
_CSWAP_ROOTS = (
    Path(".claude-swap-backup"),
    Path(".local/share/claude-swap"),
)

# organizationType -> the word that names the plan on the card.
_PLAN_WORDS = {
    "claude_free": "Free",
    "claude_pro": "Pro",
    "claude_max": "Max",
    "claude_team": "Team",
    "claude_enterprise": "Enterprise",
}


def _read_json(path: Path) -> dict | None:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


@dataclass(frozen=True)
class ClaudeOrg:
    """The organization a config tree is signed into: the subscription itself."""

    uuid: str
    name: str = ""
    type: str = ""  # "claude_max", "claude_team", ...

    @property
    def plan(self) -> str:
        """The plan word, e.g. "Max". Unknown types are title-cased rather than
        dropped, so a new tier shows up as itself instead of disappearing."""
        if self.type in _PLAN_WORDS:
            return _PLAN_WORDS[self.type]
        stripped = self.type.removeprefix("claude_").replace("_", " ").strip()
        return stripped.title() if stripped else ""


@dataclass
class ClaudeProfile:
    """One config tree, and the organization it is signed into (None when the
    tree holds no readable account, e.g. signed out)."""

    label: str  # short name, e.g. "max" or "team"
    config_dir: Path  # the account's ~/.claude tree (default, or a CLAUDE_CONFIG_DIR)
    default: bool = False  # the built-in ~/.claude, launched without CLAUDE_CONFIG_DIR
    org: ClaudeOrg | None = None
    # The claude-swap alias for this profile ("team"), when it is one of cswap's
    # session profiles. Names the row, since the profile's own directory is a
    # slot number and a mangled email that mean nothing on a card.
    cswap_alias: str = ""
    # How this tree is worth naming on screen, resolved against the home it was
    # discovered under rather than against the process's own, so a snapshot built
    # for one home never prints paths from another.
    display: str = ""

    @property
    def tree(self) -> str:
        return self.display or str(self.config_dir)


@dataclass
class ClaudeSubscription:
    """One subscription: an organization, plus every tree signed into it."""

    id: str
    label: str
    profiles: list[ClaudeProfile] = field(default_factory=list)

    @property
    def trees(self) -> list[str]:
        return [p.tree for p in self.profiles]

    @property
    def active(self) -> bool:
        """Whether this is the subscription a bare `claude` spends right now.

        The default tree is the active login by definition: claude-swap switches
        accounts by rewriting `~/.claude`, so whichever organization that tree
        holds is the one an unqualified session bills to. Reading it this way
        rather than asking cswap keeps the answer true on a machine that has
        never heard of cswap, where the default tree is simply the only login.
        """
        return any(p.default for p in self.profiles)


def _display_path(path: Path, home: Path, cswap_alias: str = "") -> str:
    """`~/.claude-team` rather than the full home path, since the full path is
    the user's name and adds nothing to a label.

    A claude-swap profile is named for its slot and a slugged email
    (`2-joseph_carepilot.com`), which is machinery rather than information, so it
    shows as `cswap:team` — the name the person actually types to run it.
    """
    if cswap_alias:
        return f"cswap:{cswap_alias}"
    try:
        return "~/" + str(path.relative_to(home))
    except ValueError:
        return str(path)


def _account_metadata(config_dir: Path, default: bool, home: Path) -> dict:
    """The `oauthAccount` block for a tree.

    The default tree's metadata is at `~/.claude.json`, beside the tree rather
    than inside it. Both locations are tried anyway, newest layout first, so a
    Claude Code that moves the file does not silently make the account
    unidentifiable — which is exactly the failure this module exists to fix.
    """
    candidates = [home / ".claude.json"] if default else []
    candidates.append(config_dir / ".claude.json")
    for path in candidates:
        account = (_read_json(path) or {}).get("oauthAccount")
        if isinstance(account, dict) and account.get("organizationUuid"):
            return account
    return {}


def _org_for(config_dir: Path, default: bool, home: Path) -> ClaudeOrg | None:
    account = _account_metadata(config_dir, default, home)
    uuid = account.get("organizationUuid")
    if not isinstance(uuid, str) or not uuid:
        return None
    return ClaudeOrg(
        uuid=uuid,
        name=str(account.get("organizationName") or ""),
        type=str(account.get("organizationType") or ""),
    )


def _is_email(name: str) -> bool:
    """A personal org is named after the account's own email address, which is
    a stand-in for a name rather than one."""
    return "@" in name


def _profile_label(
    org: ClaudeOrg | None, config_dir: Path, default: bool, cswap_alias: str = ""
) -> str:
    """A short name for the tree. The plan names it when we know it, since that
    is how a person thinks of a subscription ("my Team seat"); a tree with no
    readable account falls back to its directory suffix, so an unnamed row still
    says which tree it is."""
    if org is not None:
        if org.plan:
            return org.plan.lower()
        if org.name and not _is_email(org.name):
            return org.name.split()[0].lower()
    if cswap_alias:
        return cswap_alias
    name = config_dir.name
    if name.startswith(".claude-"):
        return name[len(".claude-"):] or name
    return "default" if default else name


def claude_profiles(home: Path | None = None) -> list[ClaudeProfile]:
    """Every Claude config tree on this machine, each with the organization it
    is signed into. The built-in `~/.claude` comes first, then the sibling
    `~/.claude-<name>` trees in name order, then claude-swap's session
    profiles."""
    home = Path(home) if home else Path.home()
    profiles: list[ClaudeProfile] = []
    for config_dir, default, alias in _config_dirs(home):
        org = _org_for(config_dir, default, home)
        profiles.append(
            ClaudeProfile(
                label=_profile_label(org, config_dir, default, alias),
                config_dir=config_dir,
                default=default,
                org=org,
                cswap_alias=alias,
                display=_display_path(config_dir, home, alias),
            )
        )
    return profiles


def _cswap_profile_dirs(home: Path) -> list[tuple[Path, str]]:
    """(profile dir, alias) for every claude-swap session profile.

    The alias comes from cswap's `sequence.json`, keyed by slot number, which is
    the leading segment of the profile's directory name. A slot with no alias set
    yields an empty one and falls back to the plan word, so an unaliased account
    is still named by something a person recognizes.
    """
    for root in _CSWAP_ROOTS:
        sessions = home / root / "sessions"
        if not sessions.is_dir():
            continue
        aliases = {
            str(num): str((meta or {}).get("alias") or "")
            for num, meta in (
                (_read_json(home / root / "sequence.json") or {}).get("accounts", {})
            ).items()
        }
        found = []
        for d in sorted(sessions.iterdir()):
            if not d.is_dir():
                continue
            found.append((d, aliases.get(d.name.split("-", 1)[0], "")))
        return found
    return []


def _config_dirs(home: Path) -> list[tuple[Path, bool, str]]:
    """(tree, is_default, cswap alias) for every config tree, default first.

    A machine with no `~/.claude` at all still yields it, so callers always have
    something to report against rather than an empty list.
    """
    default = home / ".claude"
    dirs: list[tuple[Path, bool, str]] = []
    if default.is_dir():
        dirs.append((default, True, ""))
    # `.claude-*` is also how claude-swap's own store is named, and its backup
    # root is a store rather than a login. Left in, it reports as a permanently
    # signed-out subscription called "swap-backup".
    reserved = {r.name for r in _CSWAP_ROOTS}
    for d in sorted(home.glob(".claude-*")):
        if d.is_dir() and d.name not in reserved:
            dirs.append((d, False, ""))
    dirs.extend((d, False, alias) for d, alias in _cswap_profile_dirs(home))
    return dirs or [(default, True, "")]


def slug(text: str) -> str:
    """A word turned into the id form used throughout: lowercase, hyphenated.
    Public because a subscription id is sometimes built from what a credential
    says rather than from what a config tree says, and both spellings have to
    land on the same string."""
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def _base_id(profile: ClaudeProfile) -> str:
    """The readable half of a subscription id. Ids end up in the value block and
    in `~/.config/agenthud/config.toml`, so they are named after the plan rather
    than after a uuid nobody can type. The organization's own name is held back
    as a tiebreaker: most people have one Team seat, and `claude-team` reads
    better than `claude-carepilot` until a second one turns up."""
    org = profile.org
    if org is not None:
        if org.plan:
            return f"claude-{slug(org.plan)}"
        if org.name and not _is_email(org.name):
            return f"claude-{slug(org.name)}"
        return "claude"
    name = profile.config_dir.name
    if name.startswith(".claude-"):
        return f"claude-{slug(name[len('.claude-'):])}"
    return "claude-default" if profile.default else f"claude-{slug(name)}"


def _base_label(profile: ClaudeProfile) -> str:
    org = profile.org
    if org is not None and org.plan:
        return f"Claude {org.plan}"
    if org is not None and org.name and not _is_email(org.name):
        return f"Claude {org.name}"
    suffix = profile.label
    return f"Claude {suffix.title()}" if suffix and suffix != "default" else "Claude"


def claude_subscriptions(profiles: list[ClaudeProfile]) -> list[ClaudeSubscription]:
    """Collapse config trees into subscriptions, one per organization.

    Trees sharing an `organizationUuid` become a single entry naming both, since
    they are one plan with one quota however many windows you sign into it from.
    A tree with no readable organization cannot be shown to be the same
    subscription as anything else, so it stays on its own row rather than being
    merged on a guess.

    Ids and labels are named after the organization; when two organizations
    would land on the same name (two Team orgs, say) the organization name and
    then a slice of its uuid are appended, so an id is always unique and the
    common case still reads as `claude-team`.
    """
    groups: dict[str, list[ClaudeProfile]] = {}
    for profile in profiles:
        key = profile.org.uuid if profile.org else f"dir:{profile.config_dir}"
        groups.setdefault(key, []).append(profile)

    bases: dict[str, list[str]] = {}  # base id -> the group keys wanting it
    for key, group in groups.items():
        bases.setdefault(_base_id(group[0]), []).append(key)

    subscriptions: list[ClaudeSubscription] = []
    for key, group in groups.items():
        head = group[0]
        base, label = _base_id(head), _base_label(head)
        if len(bases[base]) > 1:
            base, label = _disambiguate(base, label, head)
        subscriptions.append(ClaudeSubscription(id=base, label=label, profiles=group))
    return subscriptions


def _disambiguate(base: str, label: str, profile: ClaudeProfile) -> tuple[str, str]:
    """Two organizations landing on one name. Prefer the organization's own name
    to tell them apart, and fall back to a slice of its uuid, which is the only
    thing guaranteed to differ."""
    org = profile.org
    if org is not None and org.name and not _is_email(org.name):
        return f"{base}-{slug(org.name)}", f"{label} ({org.name})"
    if org is not None:
        short = org.uuid[:8]
        return f"{base}-{short}", f"{label} ({short})"
    return f"{base}-{slug(profile.config_dir.name)}", f"{label} ({profile.config_dir.name})"


def subscription_index(profiles: list[ClaudeProfile]) -> dict[str, ClaudeSubscription]:
    """config dir (as a string) -> the subscription that tree belongs to. This is
    how a usage reading or a running agent is attributed: by the tree it came
    from, never by a label that two accounts could share."""
    index: dict[str, ClaudeSubscription] = {}
    for sub in claude_subscriptions(profiles):
        for profile in sub.profiles:
            index[str(profile.config_dir)] = sub
    return index
