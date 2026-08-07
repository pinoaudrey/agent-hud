import Foundation

// Codable structs mirroring the daemon contract served at
// http://127.0.0.1:8737/v1/hud (version 2). Field names match the JSON
// exactly; do not rename them. Anything the daemon may omit or send as null
// is modeled as an Optional so decoding never throws on a sparse snapshot.

public struct HUDSnapshot: Codable, Equatable {
    public let version: Int
    public let generatedAt: Date?
    public let subscriptions: [Subscription]
    public let agents: [Agent]
    public let value: ValueBlock?
    public let soonestReset: SoonestReset?
    /// Whether the shared agent setup is healthy. Optional so a v1 snapshot —
    /// written by a daemon that predates this, or by one whose `~/.agents` has
    /// no `--json` yet — still decodes. `nil` means *unknown*, never healthy.
    public let setup: SetupBlock?
    /// claude-swap's account rotation state. Optional so a pre-v3 snapshot, or
    /// one from a machine without cswap, still decodes. `nil` means the
    /// question could not be asked; the card omits the section entirely.
    public let swap: SwapBlock?

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case subscriptions
        case agents
        case value
        case soonestReset = "soonest_reset"
        case setup
        case swap
    }

    public init(
        version: Int,
        generatedAt: Date?,
        subscriptions: [Subscription],
        agents: [Agent],
        value: ValueBlock?,
        soonestReset: SoonestReset?,
        setup: SetupBlock? = nil,
        swap: SwapBlock? = nil
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.subscriptions = subscriptions
        self.agents = agents
        self.value = value
        self.soonestReset = soonestReset
        self.setup = setup
        self.swap = swap
    }
}

public struct Subscription: Codable, Equatable, Identifiable {
    public let id: String            // "claude-max" | "claude-team" | "codex"
    public let provider: String      // "claude" | "codex"
    public let label: String
    /// The Claude config trees signed into this subscription, e.g.
    /// `["~/.claude", "~/.claude-team"]`. More than one means two trees share an
    /// organization and were collapsed into this entry. Empty for Codex, and for
    /// a reading the daemon could not attribute.
    public let trees: [String]
    /// When these numbers were last true. Claude is re-read every few minutes;
    /// Codex is only as fresh as the last Codex turn, which can be days ago, so
    /// this is what stops an old percentage being shown as a current one.
    public let readAt: Date?
    public let windows: [Window]
    public let tightest: Window?
    public let stale: String?        // null, or a reason string
    public let activeAgents: Int

    enum CodingKeys: String, CodingKey {
        case id, provider, label, trees, windows, tightest, stale
        case readAt = "read_at"
        case activeAgents = "active_agents"
    }

    public init(
        id: String,
        provider: String,
        label: String,
        trees: [String] = [],
        readAt: Date? = nil,
        windows: [Window],
        tightest: Window?,
        stale: String?,
        activeAgents: Int
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.trees = trees
        self.readAt = readAt
        self.windows = windows
        self.tightest = tightest
        self.stale = stale
        self.activeAgents = activeAgents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(String.self, forKey: .provider)
        label = try c.decode(String.self, forKey: .label)
        // Absent on a snapshot written before subscriptions were keyed on the
        // organization, so decode it leniently rather than failing the whole read.
        trees = try c.decodeIfPresent([String].self, forKey: .trees) ?? []
        // Absent on a snapshot from a daemon that predates it. Unknown age is
        // not the same as fresh, but it is also not something to accuse the
        // reading of, so it simply goes unstated.
        readAt = try? c.decodeIfPresent(Date.self, forKey: .readAt)
        windows = try c.decode([Window].self, forKey: .windows)
        tightest = try c.decodeIfPresent(Window.self, forKey: .tightest)
        stale = try c.decodeIfPresent(String.self, forKey: .stale)
        activeAgents = try c.decode(Int.self, forKey: .activeAgents)
    }
}

public struct Window: Codable, Equatable {
    public let kind: String          // session_5h | weekly_7d | weekly_fable | weekly
    public let pctLeft: Int?
    public let resetsAt: Date?
    public let pace: Pace?

    enum CodingKeys: String, CodingKey {
        case kind
        case pctLeft = "pct_left"
        case resetsAt = "resets_at"
        case pace
    }

    public init(kind: String, pctLeft: Int?, resetsAt: Date?, pace: Pace?) {
        self.kind = kind
        self.pctLeft = pctLeft
        self.resetsAt = resetsAt
        self.pace = pace
    }
}

public struct Pace: Codable, Equatable {
    public let projectedDryAt: Date
    public let marginSeconds: Int

    enum CodingKeys: String, CodingKey {
        case projectedDryAt = "projected_dry_at"
        case marginSeconds = "margin_seconds"
    }

    public init(projectedDryAt: Date, marginSeconds: Int) {
        self.projectedDryAt = projectedDryAt
        self.marginSeconds = marginSeconds
    }
}

public struct Agent: Codable, Equatable, Identifiable {
    public let pid: Int
    public let tool: String          // "claude" | "codex" | "opencode"
    public let project: String
    public let cwd: String
    public let state: String         // "working" | "waiting" | "idle"
    public let action: String?
    public let sinceSeconds: Int?
    public let subscriptionID: String?

    public var id: Int { pid }

    enum CodingKeys: String, CodingKey {
        case pid, tool, project, cwd, state, action
        case sinceSeconds = "since_seconds"
        case subscriptionID = "subscription_id"
    }

    public init(
        pid: Int,
        tool: String,
        project: String,
        cwd: String,
        state: String,
        action: String?,
        sinceSeconds: Int?,
        subscriptionID: String?
    ) {
        self.pid = pid
        self.tool = tool
        self.project = project
        self.cwd = cwd
        self.state = state
        self.action = action
        self.sinceSeconds = sinceSeconds
        self.subscriptionID = subscriptionID
    }
}

public struct ValueBlock: Codable, Equatable {
    public let todayUSD: Double
    public let monthUSD: Double
    public let subsCostUSD: Double?
    public let multiple: Double?
    public let bySub: [String: SubValue]

    enum CodingKeys: String, CodingKey {
        case todayUSD = "today_usd"
        case monthUSD = "month_usd"
        case subsCostUSD = "subs_cost_usd"
        case multiple
        case bySub = "by_sub"
    }

    public init(
        todayUSD: Double,
        monthUSD: Double,
        subsCostUSD: Double?,
        multiple: Double?,
        bySub: [String: SubValue]
    ) {
        self.todayUSD = todayUSD
        self.monthUSD = monthUSD
        self.subsCostUSD = subsCostUSD
        self.multiple = multiple
        self.bySub = bySub
    }
}

public struct SubValue: Codable, Equatable {
    public let todayUSD: Double
    public let monthUSD: Double

    enum CodingKeys: String, CodingKey {
        case todayUSD = "today_usd"
        case monthUSD = "month_usd"
    }

    public init(todayUSD: Double, monthUSD: Double) {
        self.todayUSD = todayUSD
        self.monthUSD = monthUSD
    }
}

// MARK: - Setup health

/// The findings of `~/.agents/bin/check-setup.sh --json`, passed through by the
/// daemon verbatim. `version` here is that script's own contract version, not
/// the snapshot's.
public struct SetupBlock: Codable, Equatable {
    public let version: Int
    public let generatedAt: Date?
    public let problems: Int
    public let sections: [SetupSectionResult]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedAt = "generated_at"
        case problems
        case sections
    }

    public init(version: Int, generatedAt: Date?, problems: Int, sections: [SetupSectionResult]) {
        self.version = version
        self.generatedAt = generatedAt
        self.problems = problems
        self.sections = sections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // This block crosses a repo boundary, so a timestamp in a shape this
        // build cannot parse must cost the timestamp and nothing else — losing
        // the whole snapshot over it would blank the quota bars too.
        generatedAt = try? c.decodeIfPresent(Date.self, forKey: .generatedAt)
        problems = try c.decode(Int.self, forKey: .problems)
        sections = try c.decode([SetupSectionResult].self, forKey: .sections)
    }

    public var isClean: Bool { problems == 0 }
}

/// One section of the gate: a group of related checks. `label` is the short name
/// a row shows; `title` is the full sentence the terminal prints, kept so the
/// panel and the terminal describe the same thing.
public struct SetupSectionResult: Codable, Equatable, Identifiable {
    public let title: String
    public let label: String
    public let summary: String
    public let status: String  // "ok" | "problem"
    public let results: [SetupResult]

    public var id: String { title }
    public var isProblem: Bool { status == "problem" }

    /// The failing results, which is all a row shows: a section that is fine
    /// says so with its summary and takes one line.
    public var problems: [SetupResult] { results.filter(\.isProblem) }

    public init(title: String, label: String, summary: String, status: String, results: [SetupResult]) {
        self.title = title
        self.label = label
        self.summary = summary
        self.status = status
        self.results = results
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        // A check-setup that names a section but not its short form still has to
        // render, so the sentence stands in for the label rather than blanking it.
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? title
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = try c.decode(String.self, forKey: .status)
        results = try c.decodeIfPresent([SetupResult].self, forKey: .results) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case title, label, summary, status, results
    }
}

/// One check. `fix` is the prose half and `fixCommand` the runnable half, split
/// by the emitter so the panel does not have to guess which words are a command.
public struct SetupResult: Codable, Equatable, Identifiable {
    public let status: String  // "ok" | "problem"
    public let message: String
    public let fix: String
    public let fixCommand: String

    public var id: String { message }
    public var isProblem: Bool { status == "problem" }

    enum CodingKeys: String, CodingKey {
        case status, message, fix
        case fixCommand = "fix_command"
    }

    public init(status: String, message: String, fix: String = "", fixCommand: String = "") {
        self.status = status
        self.message = message
        self.fix = fix
        self.fixCommand = fixCommand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        message = try c.decode(String.self, forKey: .message)
        fix = try c.decodeIfPresent(String.self, forKey: .fix) ?? ""
        fixCommand = try c.decodeIfPresent(String.self, forKey: .fixCommand) ?? ""
    }
}

// MARK: - Account rotation (claude-swap)

/// What cswap knows: the managed account slots, which one currently holds the
/// default profile's credential, and whether the auto-rotator is alive. The
/// daemon resolves each account to a subscription id by organization uuid, so
/// the card can name accounts the way the pods do.
public struct SwapBlock: Codable, Equatable {
    /// The slot whose credential `~/.claude` currently holds, or nil when
    /// cswap could not say.
    public let activeSlot: Int?
    public let accounts: [SwapAccount]
    /// The auto-rotator's state. `nil` means it could not be asked — render as
    /// unknown, never as "off".
    public let auto: SwapAuto?

    enum CodingKeys: String, CodingKey {
        case activeSlot = "active_slot"
        case accounts
        case auto
    }

    public init(activeSlot: Int?, accounts: [SwapAccount], auto: SwapAuto?) {
        self.activeSlot = activeSlot
        self.accounts = accounts
        self.auto = auto
    }
}

public struct SwapAccount: Codable, Equatable, Identifiable {
    public let slot: Int
    public let alias: String?
    public let email: String?
    public let organizationUuid: String?
    /// The subscription this account maps to on this machine, resolved by the
    /// daemon through the organization uuid. Nil when the account's
    /// organization is not signed in here.
    public let subscriptionID: String?
    public let active: Bool

    public var id: Int { slot }

    /// How the row names the account: the cswap alias is what its owner calls
    /// it ("work"), the email stands in, and the slot number is the floor.
    public var displayName: String {
        alias ?? email ?? "slot \(slot)"
    }

    enum CodingKeys: String, CodingKey {
        case slot, alias, email, active
        case organizationUuid = "organization_uuid"
        case subscriptionID = "subscription_id"
    }

    public init(
        slot: Int,
        alias: String?,
        email: String?,
        organizationUuid: String?,
        subscriptionID: String?,
        active: Bool
    ) {
        self.slot = slot
        self.alias = alias
        self.email = email
        self.organizationUuid = organizationUuid
        self.subscriptionID = subscriptionID
        self.active = active
    }
}

public struct SwapAuto: Codable, Equatable {
    public let running: Bool
    /// The window percentage the rotator switches at, when readable.
    public let threshold: Int?

    public init(running: Bool, threshold: Int?) {
        self.running = running
        self.threshold = threshold
    }
}

public struct SoonestReset: Codable, Equatable {
    public let subscriptionID: String
    public let kind: String
    public let resetsAt: Date

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
        case kind
        case resetsAt = "resets_at"
    }

    public init(subscriptionID: String, kind: String, resetsAt: Date) {
        self.subscriptionID = subscriptionID
        self.kind = kind
        self.resetsAt = resetsAt
    }
}

// MARK: - Decoding

extension HUDSnapshot {
    /// A JSONDecoder configured for the daemon contract's ISO8601 timestamps.
    /// The daemon may or may not emit fractional seconds, so we try both.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.hudWithFraction.date(from: raw)
                ?? ISO8601DateFormatter.hudPlain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable ISO8601 date: \(raw)"
            )
        }
        return decoder
    }

    public static func decode(from data: Data) throws -> HUDSnapshot {
        try makeDecoder().decode(HUDSnapshot.self, from: data)
    }
}

extension ISO8601DateFormatter {
    static let hudWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let hudPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
