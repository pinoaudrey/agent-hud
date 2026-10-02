# agent-hud

A macOS menu-bar readout for the three things that decide whether a working day
goes well: how much subscription quota is left across Claude and Codex, what
that usage would have cost at API rates, and whether the shared agent setup in
`~/.agents` is still healthy.

It is read-only. Nothing in here mutates the machine; the worst it can do is
tell you to go run something yourself.

Two halves:

- **`agenthud serve`** — a resident Python daemon that polls subscription usage
  and live agent activity, folds them into one snapshot, writes it atomically to
  `~/.cache/agenthud/hud.json`, and serves it on `http://127.0.0.1:8737/v1/hud`.
  Standard library only, so it runs against a bare `python3`.
- **`hud/`** — a SwiftPM package holding `HUDCore` (the contract structs, theme
  tokens, formatting helpers, and SwiftUI views) and `agenthud-hud`, the thin
  AppKit menu-bar shell that renders them.

This is a fork of [agent-dash](https://github.com/josephtutera/agent-dash),
which paired the same daemon with a terminal TUI. The TUI is gone; the daemon
and the HUD came across intact.

## Run it

```sh
cd hud
swift build -c release
swift run agenthud-hud          # menu-bar app, no dock icon
```

Launching the app is all it takes: it checks whether a daemon is already
answering on the loopback port and starts `python3 main.py serve` itself if not,
stopping it again on quit. To run the daemon on its own instead:

```sh
python3 main.py serve           # --host / --port to move it
```

## Install it as an app

```sh
cd hud
./build-app.sh --install        # builds AgentHUD.app and copies it to /Applications
```

The bundle records this checkout's path in `AHDaemonRoot`, so an installed copy
still finds the daemon as long as the checkout stays put. Add it under System
Settings > General > Login Items to have it start with the machine.

## Preview render (the review artifact)

The card renders headlessly to a PNG from a committed fixture snapshot, so a
reviewer can see the UI without running the menu bar:

```sh
swift run agenthud-hud --render-preview preview.png                        # problems, dark
swift run agenthud-hud --render-preview-light preview-light.png            # problems, light
swift run agenthud-hud --render-preview-clear preview-all-clear.png        # all clear, dark
swift run agenthud-hud --render-preview-clear-light preview-all-clear-light.png
swift run agenthud-hud --render-preview-menubar preview-menubar.png
swift run agenthud-hud --render-preview-menubar-light preview-menubar-light.png
```

The card follows the system appearance: every semantic colour is a
`Theme.dynamic(light:dark:)` pair, and a test resolves each one against both
appearances and fails if the two match, so a token added as a plain hex cannot
ship looking right on only one card.

## Tests

```sh
cd hud && swift test            # HUDCore: decoding, formatting, derivations, render smoke
python3 -m pytest tests         # the daemon: collectors, usage, pricing, snapshot, HTTP
```

## Where things live

| Path | What it is |
|---|---|
| `serve.py` | the daemon: polling, snapshot assembly, atomic write, loopback HTTP |
| `usage.py` | Claude usage over OAuth (with Keychain token refresh and 429 backoff), Codex from its newest account-wide rollout rate-limit event, OpenCode spend |
| `pricing.py` | what the same usage would have cost at published API rates |
| `agents.py` / `activity.py` | which agent sessions are running, and what each is doing |
| `subscriptions.py` | which Claude organizations this machine is signed into, and what to call them |
| `setup_health.py` | runs `~/.agents/bin/check-setup.sh --json` and folds the answer in |
| `collectors.py` / `models.py` | the shared session model the collectors are built on |
| `docs/hud-schema.md` | the frozen snapshot contract the Swift app decodes |
| `hud/Sources/HUDCore` | contract structs, theme, formatting, and every SwiftUI view |
| `hud/Sources/agenthud-hud` | the AppKit shell: status item, panel, daemon launcher |

## The card

Each section is a plain list: **NEEDS YOU** (only when something does),
**LIMITS**, **SETUP**, **VALUE AT API RATES**.

A limits row is one window on one plan — what it is, a fuel bar for how much is
left, the number, and when it comes back. It used to be three pods each
headlining "the window with the least headroom", and that number was the
problem: which window it quoted moved with whatever happened to be tightest, so
the same big figure meant the 5-hour session on one plan and the Fable weekly on
another, and the reset line under it moved too. There is no headline now, and
nothing shifts.

## Needs you

Sessions sit stopped while you work elsewhere. The daemon reads the record
Claude Code writes for every live session, terminal or Desktop app, so it knows
which ones wait on you and what they wait for.

- **The menu bar** leads with a coral pill that counts the sessions blocked on
  you. It is absent at zero.
- **The card** opens with NEEDS YOU, in two groups. **Blocked** lists the
  waiting sessions, longest wait first, with what each waits for. **Finished**
  lists the sessions that went idle in the last two hours, newest first.
- **A click on a row** brings that session forward. A terminal session selects
  its Terminal.app tab by tty and raises the window. The first click triggers
  the macOS Automation prompt for Terminal. A Desktop session opens in the
  Claude app through `claude://code/continue?session=<id>`. A build of the app
  that ignores the link still comes to the front.

## The menu bar

One concentric ring cluster per subscription, and a single amber dot when the
agent setup has problems (nothing at all when it is clean, or when the daemon
could not check it).

Deliberately no countdown. The only one that fits in a status item is the soonest
reset across every plan, which is a single number that does not say which plan it
belongs to. The card, a click away, gives each plan its own reset and its own
5-hour clock.

Each ring is a fuel gauge for one window: the arc is how much is **left**, so a
healthy plan is a full ring and a burnt one is nearly bare, and it is coloured
green, amber or red by severity. A plan with three limits draws three rings; a
plan with one draws one. A fully spent limit has no arc to carry its colour, so
its track goes solid red instead: empty is the state most worth seeing, and it
must not render as an absence.

That colour is why the status item is **not** a template image, which is the
conventional choice. A template throws its pixels away and takes AppKit's tint,
guaranteeing contrast over any wallpaper, but it would also flatten green, amber
and red into one shade and leave a ring that says how full it is without saying
whether that is fine. So the glance draws in real colour and resolves everything
that is not severity against the menu bar's own appearance instead, re-rendering
whenever that appearance changes.

## Setup health

The panel is a passthrough of `~/.agents/bin/check-setup.sh --json`, which is the
same gate a human runs in a terminal. The daemon performs no checks of its own,
so the panel and the terminal cannot drift apart.

It fails closed. The check exiting non-zero is *success* — that is how it reports
problems — but anything meaning "we could not ask" (no script, a script that
predates `--json`, a crash, a hang, output that is not the contract) produces no
block at all, and the card says **setup unknown** rather than showing a green
panel nobody established. The daemon clears the block on a failed poll rather
than holding the last good answer, so the card can never show yesterday's
all-clear.

## Staying current

| what can go stale | what happens |
|---|---|
| the Claude OAuth token (they last ~8h) | refreshed from the stored refresh token before it expires, and once more on a 401; the new token is written back so Claude Code and the HUD keep sharing one credential |
| the refresh token itself, or a signed-out account | the reading keeps its last-good numbers and the pod says `signed out · run claude auth login`, then sits out 15 minutes rather than hammering a dead credential |
| a locked Keychain | same, with `unlock Keychain or sign in to Claude Code` |
| the usage endpoint rate-limiting us | exponential backoff from 2 to 15 minutes, and the pod says `rate limited · retry 4m` |
| the network | the reading is not cached, so the next poll retries; the pod shows the last-good numbers with the reason |
| Codex figures going old | Codex has no API — its numbers come from the newest account-wide rate-limit event written by a turn — so the reading carries `read_at`, and a pod older than 10 minutes says `as of 3d ago` |
| the daemon dying | the app notices it has no snapshot and restarts it, backing off from 15 seconds to 5 minutes so a port held by something else cannot cause a spawn loop |
| `check-setup.sh` being absent, old, slow or broken | the setup block is omitted and the card says **setup unknown**, never a false all-clear |

Poll intervals: live agent activity every 2s, setup health every 60s, subscription
usage every 180s. Usage is deliberately slow and always goes through `usage.py`'s
own cache and backoff, because the endpoint is rate-limited per account and every
running Claude Code session polls it too.

## Safety

The HTTP API has no authentication and permissive CORS, so it refuses to bind
anything but loopback unless `AGENTHUD_SERVE_ALLOW_REMOTE=1` is set. No
credentials, tokens, or paths beyond an agent's working directory ever reach the
snapshot.
