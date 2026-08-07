# HUD snapshot schema (v3)

The `agenthud serve` daemon maintains one JSON snapshot of subscription usage and
live agent activity. It is written atomically to `~/.cache/agenthud/hud.json` on
every meaningful change and served over a loopback HTTP API. This document is the
contract for the Swift HUD app: the field names below are frozen and will not be
renamed.

**v2** added the `setup` block, and later `subscriptions[].read_at`,
`subscriptions[].trees`, and `subscriptions[].active`. **v3** added the `swap`
block. Everything from v1 is unchanged, and every field added since is optional
on the reading side, so an older snapshot still decodes.

## Serving it

- `GET /v1/hud` returns the snapshot as `application/json`.
- `GET /v1/health` returns `{"ok": true, "version": 2}`.
- Any other path returns `404`.
- The server binds loopback only (default `127.0.0.1:8737`). CORS is permissive
  (`Access-Control-Allow-Origin: *`) because only localhost can reach it anyway.
- Because the API has no authentication, a non-loopback `--host` (anything other
  than `127.0.0.1`, `::1`, or `localhost`) is refused with a clear error. Set the
  environment variable `AGENTHUD_SERVE_ALLOW_REMOTE=1` to override at your own risk.
- No credentials, tokens, or file paths beyond the agent working directory ever
  appear in the snapshot.

Run it with `agenthud serve` (or `agenthud --serve`), optionally with `--host` and
`--port`.

## Polling

- Subscription usage polls every 180 seconds, always through usage.py's cache and
  429 backoff, because the Anthropic usage endpoint is rate-limited per account
  and shared with every live Claude Code session. This daemon is meant to be the
  single resident poller.
- Live activity (running agents and their state) polls every 2 seconds, since it
  is cheap on-disk reads plus one `ps`.
- Setup health polls every 60 seconds. It shells out to `~/.agents/bin/check-setup.sh`,
  which is well under a second but not free, and drift arrives at the speed of a
  person editing a config file.
- Swap state polls every 30 seconds. `cswap list --json` answers from claude-swap's
  own usage cache (its auto-rotator is the poller), so this adds nothing to the
  rate-limited usage endpoint; the faster pace exists because a switch lands in
  running sessions within about 30 seconds, and the card claiming the wrong
  account is active is the confusion the block exists to remove.

## Top-level shape

```json
{
  "version": 2,
  "generated_at": "2026-07-21T18:04:05.123456+00:00",
  "subscriptions": [ ... ],
  "agents": [ ... ],
  "value": { ... } | null,
  "soonest_reset": { ... } | null,
  "setup": { ... } | null,
  "swap": { ... } | null
}
```

| field | type | meaning |
|---|---|---|
| `version` | int | Schema version. `2` for this contract. |
| `generated_at` | ISO8601 string with offset | When this snapshot was built (UTC). |
| `subscriptions` | array | One entry per Claude account plus Codex. OpenCode is BYOK, not a subscription, so it never appears here. |
| `agents` | array | Every running claude / codex / opencode terminal session detected right now. |
| `value` | object or null | Dollar value delivered vs. subscription cost. `null` when the pricing collector is unavailable. |
| `soonest_reset` | object or null | The single earliest-resetting window across all subscriptions, or `null` when no window reports a reset time. |
| `setup` | object or null | Whether the shared agent setup in `~/.agents` is healthy, verbatim from `check-setup.sh --json`. `null` means the question could not be asked — **never that the setup is fine**. |
| `swap` | object or null | claude-swap's account rotation state: the managed slots, which one holds the default profile's credential, and whether the auto-rotator is alive. `null` means cswap is absent or could not answer — the card omits the section, **never renders it as "rotation off"**. |

## `subscriptions[]`

```json
{
  "id": "claude-team",
  "provider": "claude",
  "label": "Claude Team",
  "trees": ["cswap:team"],
  "active": false,
  "read_at": "2026-08-02T21:38:04+00:00",
  "windows": [ ... ],
  "tightest": { "kind": "session_5h", "pct_left": 62, "resets_at": "..." } | null,
  "stale": null,
  "active_agents": 2
}
```

A Claude subscription is an **organization**, not a config directory. Claude Code
keeps one tree per account you are signed into — the built-in `~/.claude` plus any
`~/.claude-<name>` made with `CLAUDE_CONFIG_DIR` — but the tree is only where the
session state lives; the organization is what holds the quota. So two trees signed
into one organization are reported as **one** subscription naming both, and two
trees on different organizations stay apart even when the same person owns both.
`accountUuid` is deliberately not used: it is the same person on both, so keying
on it would fold two real subscriptions into one and halve the quota reported.

The organization is read from the account metadata Claude Code keeps beside each
tree, and that file is rewritten as sessions come and go, so a tree can go on
naming an organization it no longer spends against. The credential the tree
actually holds settles it: when the plan on that credential contradicts the
organization on file, the tree is reported on its own, named by the credential.
Otherwise a tree carrying a stale claim collapses into somebody else's
subscription and its reading is dropped as a duplicate, which takes a whole plan
off the readout at the moment its quota is most worth seeing.

| field | type | meaning |
|---|---|---|
| `id` | string | Stable id, derived from the organization: `claude-<plan>` (`claude-max`, `claude-team`, `claude-pro`, …). Two organizations on one plan are told apart by name (`claude-team-carepilot`) and, failing that, by a slice of the organization uuid. A tree with no readable account keeps a directory-derived id (`claude-default`, `claude-<suffix>`) so it is still reported rather than dropped. Codex is always `codex`. |
| `provider` | `"claude"` \| `"codex"` | Which vendor this subscription is. |
| `label` | string | Display name, e.g. `Claude Max`, `Claude Team`, `Claude Team (CarePilot)`, `Codex Pro`. |
| `trees` | array of strings | The config trees signed into this subscription, e.g. `["~/.claude", "~/.claude-work"]`. More than one means they were collapsed into this entry. Empty for Codex, and for a reading the daemon could not attribute to a tree. |
| `active` | bool | Whether a session started right now with no account named would spend this subscription. Exactly one Claude subscription is active at a time: claude-swap switches accounts by rewriting `~/.claude`, so this moves as it swaps and is the only field that says which plan is currently paying. Always `true` for Codex, which has one login and no switcher. `false` for a reading the daemon could not attribute to a tree, since an unattributed reading cannot be shown to be the live one. Absent in snapshots from a daemon older than this field; decode it as `false`. |
| `read_at` | ISO8601 string, or null | When these numbers were last **true** — not when the snapshot was built. Claude is re-read on the usage poll, so this tracks it closely. Codex has no API to ask: its figures come out of a rollout file written as a side effect of a turn. The daemon uses the newest account-wide rate-limit event timestamp, falling back to the file mtime only for older event records that did not carry a timestamp, so a model-specific limit or another active session cannot overwrite the subscription reading. A reader must treat an old `read_at` as a reason to say so, because a weekly window that has since reset makes an old percentage wrong rather than merely late. `null` when the reading carries no timestamp (an older daemon, or a subscription with no successful read yet). |
| `windows` | array | The usage windows this subscription reports (see below). |
| `tightest` | object or null | The window with the least headroom (lowest `pct_left`), copied out for quick access. `null` when no window has a percentage. Carries `kind`, `pct_left`, `resets_at`. |
| `stale` | string or null | `null` when the reading is fresh. A human reason like `"rate limited, retry 4m"` when the values are last-good rather than current (rate limit cooldown or a fetch failure). Stale data is never presented as fresh: the windows keep their last-good numbers and this field says why. |
| `active_agents` | int | How many entries in `agents[]` are attributed to this subscription. |

### `subscriptions[].windows[]`

```json
{
  "kind": "session_5h",
  "pct_left": 62,
  "resets_at": "2026-07-21T22:00:00+00:00",
  "pace": { "projected_dry_at": "2026-07-21T21:10:00+00:00", "margin_seconds": -3000 } | null
}
```

| field | type | meaning |
|---|---|---|
| `kind` | string | The window type. Claude reports `session_5h` (the 5-hour session limit), `weekly_7d` (the 7-day limit), and `weekly_fable` (the model-scoped weekly limit, Fable on Max/Team). Codex reports `session_5h` and `weekly`. |
| `pct_left` | int 0-100, or null | Percent of the quota still available (`100 - utilization`). `null` when the subscription doesn't report a percentage for this window. |
| `resets_at` | ISO8601 string, or null | When the window rolls over. `null` when unknown. |
| `pace` | object or null | A linear burn projection, computed only for the subscription's tightest window and only when computable (needs a reset time and some usage). `null` on every other window. |

`pace.projected_dry_at` is when the quota would hit zero if the average burn since
the window opened continued. `pace.margin_seconds` is how many seconds of slack
that leaves before `resets_at`: positive means the window resets before you run
dry (safe), negative means you would run out first at the current pace.

## `agents[]`

```json
{
  "pid": 59001,
  "tool": "claude",
  "project": "web-app",
  "cwd": "/Users/you/Repos/web-app",
  "state": "working",
  "action": "editing auth.py",
  "since_seconds": 720,
  "subscription_id": "claude-team"
}
```

| field | type | meaning |
|---|---|---|
| `pid` | int | Process id of the terminal agent session. |
| `tool` | `"claude"` \| `"codex"` \| `"opencode"` | Which CLI this is. |
| `project` | string | Basename of the working directory. |
| `cwd` | string | Full working directory path. |
| `state` | `"working"` \| `"waiting"` \| `"idle"` | Live status. `waiting` means it is blocked on the user (e.g. a permission prompt). An unknown status is reported as `idle`. |
| `action` | string or null | The current action text (e.g. `editing auth.py`) when known, else `null`. |
| `since_seconds` | int or null | Approximate session uptime in seconds, or `null` when not derivable. |
| `subscription_id` | string or null | The subscription this agent spends against, when determinable. Codex agents are always `codex`; a Claude agent is matched to the config tree holding its per-pid session file, and from there to that tree's subscription; opencode and unresolved agents are `null`. |

## `value`

```json
{
  "today_usd": 42.10,
  "month_usd": 830.55,
  "subs_cost_usd": 400.0,
  "multiple": 2.08,
  "by_sub": { "claude-team": { "today_usd": 30.0, "month_usd": 600.0 } }
}
```

`null` as a whole when the pricing module is not present on this build, or when
its output cannot be JSON-serialized (the daemon validates the block and drops it
rather than crash). When present, the daemon prefers `pricing.hud_value()`, which
returns exactly this contract; older builds exposing only `collect_value()` are
coerced down to it. The block estimates the API-equivalent dollar value of the
work done today and this month, the flat monthly subscription cost
(`subs_cost_usd`, may be `null`), the value-to-cost `multiple` (may be `null`),
and a per-subscription breakdown keyed by subscription id.

## `soonest_reset`

```json
{ "subscription_id": "claude-team", "kind": "session_5h", "resets_at": "2026-07-21T22:00:00+00:00" }
```

The earliest upcoming window reset across every subscription, so the HUD can show
a single "next reset" without walking the whole tree. `null` when nothing reports
a reset time.

## `setup`

```json
{
  "version": 1,
  "generated_at": "2026-08-03T01:23:32+00:00",
  "problems": 2,
  "sections": [
    {
      "title": "every Claude account behaves the same",
      "label": "accounts",
      "summary": "model",
      "status": "problem",
      "results": [
        {
          "status": "problem",
          "message": ".claude-team differs from ~/.claude in: model",
          "fix": "decide which is right, apply it to both, then",
          "fix_command": "bin/capture.sh"
        }
      ]
    }
  ]
}
```

Passed through verbatim from `~/.agents/bin/check-setup.sh --json`, which is the
same gate a human runs in a terminal. The daemon deliberately performs no checks
of its own: two implementations would eventually disagree about what healthy
means, and the HUD is the one nobody re-derives. `version` here is the
check-setup contract's own, independent of the snapshot's.

| field | type | meaning |
|---|---|---|
| `problems` | int | How many results across all sections are problems. |
| `sections[].title` | string | The full sentence the terminal prints. |
| `sections[].label` | string | A short name for one row in a panel, e.g. `accounts`. |
| `sections[].summary` | string | The section's roll-up: `12 on PATH` when it is fine, or what went wrong (`model`, `3 files`) when it is not. |
| `sections[].status` | `"ok"` \| `"problem"` | `problem` when any result in the section is. |
| `results[].message` | string | The line the terminal prints for this result. |
| `results[].fix` | string | The prose part of the fix, possibly empty. |
| `results[].fix_command` | string | The runnable part, split out so a reader can offer it as copyable. Empty when the fix is prose all the way through. |

`null` rather than an object whenever the question could not be asked: no script,
a script that predates `--json`, a crash, a hang, or output that is not the
contract. **A reader must render `null` as unknown, not as healthy.** A green
panel that is really "we could not ask" is worse than no panel, and the daemon
clears the block on a failed poll rather than holding the last good answer, so
the card can never show yesterday's all-clear.

The check exiting non-zero is *success*: exit 1 is how it reports problems. Only
exit 2, its own "I could not run", produces a `null` block.

## `swap`

```json
{
  "active_slot": 1,
  "accounts": [
    {
      "slot": 1,
      "alias": "work",
      "email": "audrey@carepilot.com",
      "organization_uuid": "780d6270-...",
      "subscription_id": "claude-team",
      "active": true
    }
  ],
  "auto": { "running": true, "threshold": 90 } | null
}
```

Read from `cswap list --json` (claude-swap's documented scripting interface,
schemaVersion 1), which answers from its own cache. cswap can rotate which
account holds the default `~/.claude` profile's credential mid-session, so a
config tree no longer implies an account; this block is the card's answer to
"which account is billing right now".

| field | type | meaning |
|---|---|---|
| `active_slot` | int or null | The cswap slot whose credential the default profile currently holds. `null` when cswap could not say. |
| `accounts[].slot` | int | cswap's slot number for this account. |
| `accounts[].alias` | string or null | The short name its owner gave it (`work`, `personal`). |
| `accounts[].email` | string or null | The account's email, a display fallback when there is no alias. |
| `accounts[].organization_uuid` | string or null | The organization the account belongs to — the same key `subscriptions[]` entries are grouped by. |
| `accounts[].subscription_id` | string or null | The `subscriptions[]` entry this account resolves to on this machine, joined by organization uuid. `null` when the organization is not signed in here; an account is never guessed onto another subscription. |
| `accounts[].active` | bool | Whether this slot holds the default profile's credential. This is the same fact `subscriptions[].active` reports, reached through cswap instead of through the tree; the two can disagree only transiently, because subscriptions rebuild on the slower usage poll. A reader showing both should use the same words for them. |
| `auto` | object or null | The auto-rotator's state: `running` (a `cswap auto` process is alive) and `threshold` (the window percentage it switches at, `null` when unreadable). The whole object is `null` when the question could not be asked — **unknown, never "off"**: a rotator we could not see might be switching accounts right now. |

`null` as a whole whenever cswap is absent, hangs, fails, or answers outside the
contract. The daemon clears the block on a failed poll rather than holding the
last good answer, because the block's entire claim is about *right now*.
