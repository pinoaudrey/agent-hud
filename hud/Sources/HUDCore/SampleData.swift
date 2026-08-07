import Foundation

// A hand-built snapshot used by the preview render and SwiftUI previews. It is
// deliberately shaped to exercise every visual state in the spec: a pressured
// sub with a pace line, a healthy sub, a spent Fable limit, waiting agents, and
// a full value block. The `now` is pinned so countdowns render deterministically.
extension HUDSnapshot {
    public static let previewNow: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 21
        c.hour = 9; c.minute = 41; c.second = 0
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    private static func at(_ minutesFromNow: Int) -> Date {
        previewNow.addingTimeInterval(TimeInterval(minutesFromNow * 60))
    }

    public static let sample: HUDSnapshot = {
        let team = Subscription(
            id: "claude-team",
            provider: "claude",
            label: "Claude Team",
            trees: ["~/.claude-team"],
            readAt: at(-2),
            windows: [
                Window(kind: "session_5h", pctLeft: 18, resetsAt: at(126),
                       pace: Pace(projectedDryAt: at(41), marginSeconds: 85 * 60)),
                Window(kind: "weekly_7d", pctLeft: 61, resetsAt: at(4 * 24 * 60 + 3 * 60), pace: nil),
            ],
            tightest: Window(kind: "session_5h", pctLeft: 18, resetsAt: at(126), pace: nil),
            stale: nil,
            activeAgents: 2
        )
        let personal = Subscription(
            id: "claude-max",
            provider: "claude",
            label: "Claude Max",
            trees: ["~/.claude"],
            readAt: at(-2),
            windows: [
                Window(kind: "session_5h", pctLeft: 74, resetsAt: at(72), pace: nil),
                Window(kind: "weekly_7d", pctLeft: 88, resetsAt: at(5 * 24 * 60), pace: nil),
                Window(kind: "weekly_fable", pctLeft: 0, resetsAt: at(2 * 24 * 60 + 6 * 60), pace: nil),
            ],
            tightest: Window(kind: "weekly_fable", pctLeft: 0, resetsAt: at(2 * 24 * 60 + 6 * 60), pace: nil),
            stale: nil,
            activeAgents: 0
        )
        let codex = Subscription(
            id: "codex",
            provider: "codex",
            label: "Codex Pro",
            // Deliberately old: Codex only updates when you use Codex, so this
            // is its normal state after a quiet day and the pod must say so.
            readAt: at(-3 * 24 * 60),
            windows: [
                Window(kind: "session_5h", pctLeft: 52, resetsAt: at(38), pace: nil),
                Window(kind: "weekly", pctLeft: 43, resetsAt: at(3 * 24 * 60 + 8 * 60), pace: nil),
            ],
            tightest: Window(kind: "session_5h", pctLeft: 52, resetsAt: at(38), pace: nil),
            stale: nil,
            activeAgents: 1
        )

        let agents = [
            Agent(pid: 4821, tool: "claude", project: "prototype-ehr",
                  cwd: "/Users/j/prototype-ehr", state: "waiting",
                  action: "waiting on approval to run tests", sinceSeconds: 72,
                  subscriptionID: "claude-team"),
            Agent(pid: 4822, tool: "claude", project: "web-app",
                  cwd: "/Users/j/web-app", state: "working",
                  action: "editing MeterRow.swift", sinceSeconds: 8 * 60 + 12,
                  subscriptionID: "claude-team"),
            Agent(pid: 5140, tool: "codex", project: "agent-hud",
                  cwd: "/Users/j/agent-hud", state: "working",
                  action: "running swift build", sinceSeconds: 44,
                  subscriptionID: "codex"),
            Agent(pid: 5602, tool: "opencode", project: "docs",
                  cwd: "/Users/j/docs", state: "idle",
                  action: nil, sinceSeconds: 61 * 60,
                  subscriptionID: nil),
        ]

        let value = ValueBlock(
            todayUSD: 182,
            monthUSD: 3140,
            subsCostUSD: 250,
            multiple: 12.6,
            bySub: [
                "claude-team": SubValue(todayUSD: 120, monthUSD: 2100),
                "claude-max": SubValue(todayUSD: 22, monthUSD: 480),
                "codex": SubValue(todayUSD: 40, monthUSD: 560),
            ]
        )

        let swap = SwapBlock(
            activeSlot: 1,
            accounts: [
                SwapAccount(slot: 1, alias: "work", email: "j@carepilot.com",
                            organizationUuid: "org-team", subscriptionID: "claude-team",
                            active: true),
                SwapAccount(slot: 2, alias: "personal", email: "j@home.com",
                            organizationUuid: "org-max", subscriptionID: "claude-max",
                            active: false),
            ],
            auto: SwapAuto(running: true, threshold: 90)
        )

        return HUDSnapshot(
            version: 3,
            generatedAt: previewNow,
            subscriptions: [personal, team, codex],
            agents: agents,
            value: value,
            soonestReset: SoonestReset(subscriptionID: "codex", kind: "session_5h", resetsAt: at(38)),
            setup: .sampleWithProblems,
            swap: swap
        )
    }()
}

// The setup block in both of its interesting states. Problems are the sample the
// preview render uses, since a card is only worth reviewing in the state that
// has something to show.
extension SetupBlock {
    static let sampleWithProblems = SetupBlock(
        version: 1,
        generatedAt: HUDSnapshot.previewNow.addingTimeInterval(-12),
        problems: 2,
        sections: [
            .ok("shared instructions, skills and memory are linked into the repo", "links", "8 links"),
            .ok("Codex has a link for every skill, and none left over", "codex skills", "15 skills"),
            SetupSectionResult(
                title: "every Claude account behaves the same",
                label: "accounts",
                summary: "model",
                status: "problem",
                results: [SetupResult(
                    status: "problem",
                    message: ".claude-team differs from ~/.claude in: model",
                    fix: "decide which is right, apply it to both, then",
                    fixCommand: "bin/capture.sh"
                )]
            ),
            .ok("every harness wakes the memory", "memory", "3 harnesses"),
            .ok("every CLI the instructions promise is installed", "CLI contract", "12 on PATH"),
            .ok("every shared MCP server is registered in both harnesses", "MCP contract", "5 in both"),
            SetupSectionResult(
                title: "everything the manifest tracks is captured",
                label: "captured",
                summary: "3 files",
                status: "problem",
                results: [SetupResult(
                    status: "problem",
                    message: "the machine is ahead of the repo for: .claude/settings.json, .codex/config.toml, .copilot/config.json",
                    fix: "",
                    fixCommand: "bin/capture.sh"
                )]
            ),
            .ok("the repo is committed and pushed", "pushed", "main"),
        ]
    )

    static let sampleAllClear = SetupBlock(
        version: 1,
        generatedAt: HUDSnapshot.previewNow.addingTimeInterval(-12),
        problems: 0,
        sections: sampleWithProblems.sections.map {
            SetupSectionResult(title: $0.title, label: $0.label,
                               summary: $0.summary, status: "ok", results: [])
        }
    )
}

extension SetupSectionResult {
    static func ok(_ title: String, _ label: String, _ summary: String) -> SetupSectionResult {
        SetupSectionResult(title: title, label: label, summary: summary, status: "ok",
                           results: [SetupResult(status: "ok", message: summary)])
    }
}

// A day when nothing is wrong: the state the setup panel is in almost always,
// and a different layout rather than the same one with fewer rows. The menu bar
// shows no dot at all here.
extension HUDSnapshot {
    public static let sampleAllClear: HUDSnapshot = {
        let s = HUDSnapshot.sample
        return HUDSnapshot(
            version: s.version,
            generatedAt: s.generatedAt,
            subscriptions: s.subscriptions,
            agents: s.agents,
            value: s.value,
            soonestReset: s.soonestReset,
            setup: .sampleAllClear,
            swap: s.swap
        )
    }()
}
