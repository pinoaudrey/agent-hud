import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// The click-through card. Top to bottom: a slim header, one pod per subscription
// showing every window it reports, the account-rotation panel (when cswap
// manages this machine), the setup panel, the API-value strip, and a footer.
// Colors are the dynamic Theme tokens, so the whole card follows the system
// light/dark appearance. Width 520, radius 16, hairline border.

public struct PopoverCard: View {
    public let snapshot: HUDSnapshot?
    public var now: Date
    /// Called when the footer's refresh is pressed. Nil in previews and tests,
    /// which is why the control is a seam rather than a direct call into the store.
    public var onRefresh: (() -> Void)?

    public init(snapshot: HUDSnapshot?, now: Date = Date(), onRefresh: (() -> Void)? = nil) {
        self.snapshot = snapshot
        self.now = now
        self.onRefresh = onRefresh
    }

    private var orderedSubs: [Subscription] {
        snapshot?.orderedSubscriptions ?? []
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snap = snapshot {
                CardHeaderView(now: now)
                LimitsSection(subs: orderedSubs, now: now)
                if let swap = snap.swap {
                    SwapSection(swap: swap, subs: orderedSubs)
                }
                SetupSection(setup: snap.setup)
                if let value = snap.value {
                    ValueStripView(value: value, subs: orderedSubs, now: now)
                }
                FooterView(setup: snap.setup, generatedAt: snap.generatedAt,
                           now: now, onRefresh: onRefresh)
            } else {
                OfflineView()
            }
        }
        .padding(22)
        .frame(width: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Header

/// A slim card head: the wordmark, a hairline that fills the row, and the
/// current date and time, so the card reads as a dated snapshot.
struct CardHeaderView: View {
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            Text("AGENT HUD")
                .font(Theme.label(11, weight: .semibold))
                .tracking(2.0)
                .foregroundStyle(Theme.text)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(Self.dateText(now))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.muted)
                .fixedSize()
        }
    }

    static func dateText(_ now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return "\(f.string(from: now)) · \(Fmt.clock(now))"
    }
}

// MARK: - Section header rule

/// A section rule: a caps letterspaced label, a hairline that fills the row,
/// and an optional right-aligned accessory.
struct SectionRule<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.label(10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.muted)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            accessory()
        }
    }
}

extension SectionRule where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title, accessory: { EmptyView() })
    }
}

// MARK: - Limits

/// Every limit on every plan, one row each.
///
/// This used to be three side-by-side pods, each headlining the window with the
/// least headroom. That number was the problem: which window it quoted moved
/// with whatever happened to be tightest, so the same big figure meant the
/// 5-hour session on one plan and the Fable weekly on another, and the reset
/// line under it moved with it. Naming the windows helped and did not fix it —
/// the shape of a pod still changed depending on its own data.
///
/// So there is no headline any more. A row is one window on one plan: what it
/// is, how much is left, and when it comes back. Nothing shifts, and a plan with
/// three limits is three rows rather than one number plus footnotes.
struct LimitsSection: View {
    let subs: [Subscription]
    /// Whether "which account is signed in" is a live question. With a single
    /// Claude plan the answer is always the same one, and a badge that never
    /// moves is decoration rather than information.
    private var marksActive: Bool {
        subs.filter { $0.provider == "claude" }.count > 1
    }
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionRule(title: "LIMITS")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(subs) { sub in
                    PlanLimits(sub: sub, now: now, marksActive: marksActive)
                }
            }
        }
    }
}

/// One plan: its name, then a row per window it reports.
struct PlanLimits: View {
    let sub: Subscription
    let now: Date
    var marksActive: Bool = false

    /// Only Claude switches accounts, so only Claude earns the badge. Codex is
    /// reported active because its one login is the one in use, which is true
    /// but not worth saying on a card.
    private var showsActive: Bool {
        marksActive && sub.active && sub.provider == "claude"
    }

    private var dotColor: Color {
        sub.provider == "codex" ? Theme.codexGreen : Theme.claudeCoral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(sub.label.uppercased())
                    .font(Theme.label(10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(showsActive ? Theme.text : Theme.muted)
                if showsActive {
                    Text("SIGNED IN")
                        .font(Theme.label(9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.claudeCoral)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.claudeCoral.opacity(0.45), lineWidth: 1)
                        )
                        .fixedSize()
                }
                Spacer(minLength: 8)
                trailingNote
            }
            if sub.windows.isEmpty {
                Text(sub.stale ?? "no limits reported")
                    .font(Theme.label(11))
                    .foregroundStyle(Theme.amber)
                    .padding(.leading, 14)
            } else {
                ForEach(Array(sub.windows.enumerated()), id: \.offset) { _, window in
                    LimitRow(window: window, now: now)
                }
                if sub.sessionWindow == nil {
                    // Codex reports only a weekly limit. Saying so beats leaving
                    // a reader to wonder where the 5h row went.
                    Text("no session limit")
                        .font(Theme.label(10))
                        .foregroundStyle(Theme.faint)
                        .padding(.leading, 14)
                }
            }
        }
    }

    /// The right-hand note on the plan's own line: why its numbers are suspect,
    /// how old they are, or how many agents are spending against it — in that
    /// order, because a reason to distrust the row outranks a detail about it.
    @ViewBuilder
    private var trailingNote: some View {
        if let stale = sub.stale, !sub.windows.isEmpty {
            Text(stale)
                .font(Theme.label(10))
                .foregroundStyle(Theme.amber)
                .lineLimit(1)
                .fixedSize()
        } else if let readAt = sub.agedReading(now: now) {
            Text("as of \(Fmt.ago(readAt, now: now))")
                .font(Theme.label(10))
                .foregroundStyle(Theme.faint)
                .fixedSize()
        } else if sub.activeAgents > 0 {
            HStack(spacing: 5) {
                Circle().fill(Theme.agentDot).frame(width: 5, height: 5)
                Text(sub.activeAgents == 1 ? "1 agent" : "\(sub.activeAgents) agents")
                    .font(Theme.label(10))
                    .foregroundStyle(Theme.muted)
            }
            .fixedSize()
        }
    }
}

/// One window: what it is, a fuel bar for how much is left, the number, and when
/// it comes back. Every row has the same shape whichever plan it belongs to.
struct LimitRow: View {
    let window: Window
    let now: Date

    /// Amber and red pull the number forward; a healthy row leaves it plain, so
    /// the colour on the card means something rather than being everywhere.
    private var isPressured: Bool { (window.pctLeft ?? 100) < 25 }

    var body: some View {
        HStack(spacing: 9) {
            Text(Fmt.windowName(kind: window.kind))
                .font(Theme.label(11))
                .foregroundStyle(Theme.muted)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule()
                        .fill(Theme.severity(pctLeft: window.pctLeft))
                        .frame(width: Fmt.remaining(pctLeft: window.pctLeft) * geo.size.width)
                }
            }
            .frame(height: 4)
            Text(Fmt.glancePercent(pctLeft: window.pctLeft) + "%")
                .font(Theme.mono(11, weight: isPressured ? .semibold : .regular))
                .foregroundStyle(isPressured ? Theme.severity(pctLeft: window.pctLeft) : Theme.text)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
            Text(resetText)
                .font(Theme.label(10))
                .foregroundStyle(Theme.faint)
                .frame(width: 132, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.leading, 14)
    }

    /// A day and a clock time rather than a countdown: you are deciding whether
    /// to wait, which is a question about when, not about how long.
    private var resetText: String {
        guard let reset = window.resetsAt else { return "no reset reported" }
        return "resets \(Fmt.dayClock(reset, now: now))"
    }
}

// MARK: - Value strip

/// The API-value readout: three tiles for today, the month, and the multiple
/// over what the subscriptions cost, then a line per subscription. The
/// per-subscription split is the part that answers "which plan is doing the
/// work", which the totals alone cannot.
struct ValueStripView: View {
    let value: ValueBlock
    let subs: [Subscription]
    let now: Date

    private var monthName: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f.string(from: now).uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionRule(title: "VALUE AT API RATES")
            HStack(spacing: 9) {
                tile(caption: "TODAY", value: Fmt.usd(value.todayUSD))
                tile(caption: monthName, value: Fmt.usd(value.monthUSD))
                multipleTile
            }
            if !bySub.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(bySub, id: \.label) { row in
                        HStack(spacing: 8) {
                            Circle().fill(row.color).frame(width: 7, height: 7)
                            Text(row.label)
                                .font(Theme.label(12))
                                .foregroundStyle(row.isSpent ? Theme.text : Theme.faint)
                            Spacer(minLength: 8)
                            Text(Fmt.usdExact(row.monthUSD))
                                .font(Theme.label(12))
                                .foregroundStyle(row.isSpent ? Theme.text : Theme.faint)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal, 3)
            }
        }
    }

    private struct SubRow {
        let label: String
        let color: Color
        let monthUSD: Double
        /// A plan that spent nothing this month recedes rather than disappearing:
        /// "this one is idle" is itself worth seeing.
        var isSpent: Bool { monthUSD > 0 }
    }

    /// Biggest spender first, so the line that explains the total leads.
    private var bySub: [SubRow] {
        subs.compactMap { sub in
            guard let v = value.bySub[sub.id] else { return nil }
            let color = sub.provider == "codex" ? Theme.codexGreen : Theme.claudeCoral
            return SubRow(label: sub.label,
                          color: v.monthUSD > 0 ? color : Theme.faint,
                          monthUSD: v.monthUSD)
        }
        .sorted { $0.monthUSD > $1.monthUSD }
    }

    private func tile(caption: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(Theme.label(9, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(Theme.mono(22, weight: .bold))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    /// The multiple needs to know what the subscriptions cost, which lives in a
    /// config file nobody has to fill in. Unset, the tile says what to do about
    /// it rather than showing a dash that reads like a bug.
    @ViewBuilder
    private var multipleTile: some View {
        if let multiple = value.multiple {
            tile(caption: "MULTIPLE", value: Fmt.multiple(multiple))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("MULTIPLE")
                    .font(Theme.label(9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Theme.muted)
                Text("set what the subs cost")
                    .font(Theme.label(12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Theme.hairline)
            )
        }
    }
}

// MARK: - Footer

/// When the setup was last checked, a refresh, the copy-for-an-agent button, and
/// quit. Both new controls are read-only: one re-reads, one writes to the
/// clipboard. Nothing on this card mutates the machine.
struct FooterView: View {
    let setup: SetupBlock?
    let generatedAt: Date?
    let now: Date
    var onRefresh: (() -> Void)?

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 12) {
            Text(checkedLabel)
                .font(Theme.label(11))
                .foregroundStyle(Theme.faint)
                .fixedSize()
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .onTapGesture { onRefresh?() }
                .help("Re-read the daemon now")
            Spacer(minLength: 0)
            if let setup, !setup.isClean {
                copyButton(setup: setup)
            }
            Text("quit")
                .font(Theme.label(11))
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
                .onTapGesture { AppActions.quit() }
        }
        .padding(.top, 6)
    }

    private func copyButton(setup: SetupBlock) -> some View {
        HStack(spacing: 7) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
            Text(didCopy ? "copied" : copyLabel(setup.problems))
                .font(Theme.label(11))
        }
        .foregroundStyle(Theme.amber)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.warnSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.warnBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            AppActions.copyToClipboard(SetupClipboard.payload(for: setup, now: now))
            didCopy = true
        }
    }

    private func copyLabel(_ n: Int) -> String {
        n == 1 ? "copy 1 problem for an agent" : "copy \(n) problems for an agent"
    }

    /// The setup block carries its own timestamp, which is what "checked" means
    /// here; the snapshot's own `generated_at` stands in when there is no block.
    private var checkedLabel: String {
        guard let stamped = setup?.generatedAt ?? generatedAt else { return "setup not checked" }
        return "setup checked \(Fmt.ago(stamped, now: now))"
    }
}

// MARK: - Offline

struct OfflineView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    RingCluster(session: nil, weekly: nil).opacity(0.35)
                }
            }
            Text("daemon offline, run: agenthud serve")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

/// Side effects the card triggers. Kept behind a seam so the views stay pure
/// and the tests never shell out. Every one of these is read-only or writes to
/// the clipboard: nothing on this card changes the machine.
public enum AppActions {
    /// Put the setup problems, and the rules for fixing them properly, on the
    /// clipboard so they can be pasted into any agent.
    public static func copyToClipboard(_ text: String) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }

    /// Quit the HUD. There's no dock icon or app menu (it's an accessory app),
    /// so this is the only way out short of `kill`; the footer button and the
    /// status item's right-click menu both call it.
    public static func quit() {
        #if canImport(AppKit)
        NSApplication.shared.terminate(nil)
        #endif
    }
}
