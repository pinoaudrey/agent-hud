import SwiftUI

// The sessions that are waiting on you, at the top of the card because it is
// the one section that asks you to do something. Two groups: Blocked (a
// session stopped on a question or a permission prompt) and Finished (a
// session that went idle in the last two hours, with work you have not looked
// at). A click on a row brings that session forward.
//
// Rendered only when either group has a row. A card with nothing waiting
// should not carry an empty heading about it.

public struct NeedsYouSection: View {
    public let needsYou: NeedsYou
    public let now: Date
    /// Called with the row's agent on a click. Nil in previews and tests, which
    /// is why it is a seam rather than a direct call into SessionFocus.
    public var onSelect: ((Agent) -> Void)?
    /// Finished starts folded: a finished session can wait for a look, and its
    /// rows pushed the limits and the setup panel down the card.
    @State private var showsFinished: Bool

    public init(needsYou: NeedsYou, now: Date, onSelect: ((Agent) -> Void)? = nil,
                showsFinished: Bool = false) {
        self.needsYou = needsYou
        self.now = now
        self.onSelect = onSelect
        _showsFinished = State(initialValue: showsFinished)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionRule(title: "NEEDS YOU")
            VStack(alignment: .leading, spacing: 10) {
                if !needsYou.blocked.isEmpty {
                    group("BLOCKED", dot: Theme.claudeCoral, agents: needsYou.blocked)
                }
                if !needsYou.finished.isEmpty {
                    group("FINISHED", dot: Theme.agentDot, agents: needsYou.finished,
                          isExpanded: showsFinished) {
                        withAnimation(.easeOut(duration: 0.18)) { showsFinished.toggle() }
                    }
                }
            }
        }
    }

    /// A group with `onToggle` folds: its heading becomes the control, with a
    /// chevron, and its rows show only while it is open.
    private func group(_ title: String, dot: Color, agents: [Agent],
                       isExpanded: Bool = true, onToggle: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            groupHeading(title, dot: dot, count: agents.count,
                         isExpanded: isExpanded, onToggle: onToggle)
            ForEach(isExpanded ? agents : []) { agent in
                NeedsYouRow(agent: agent, now: now)
                    .padding(.vertical, 2)
                    .padding(.trailing, 6)
                    .clickableRow(isEnabled: isClickable(agent))
                    .onTapGesture { onSelect?(agent) }
                    .help(agent.isDesktop ? "Open in Claude" : "Bring its Terminal tab forward")
            }
        }
    }

    @ViewBuilder
    private func groupHeading(_ title: String, dot: Color, count: Int,
                              isExpanded: Bool, onToggle: (() -> Void)?) -> some View {
        let heading = HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(title)
                .font(Theme.label(10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Theme.muted)
            Text("\(count)")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)
            if onToggle != nil {
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.trailing, 10)
            }
        }
        if let onToggle {
            heading
                .padding(.vertical, 3)
                .clickableRow()
                .onTapGesture(perform: onToggle)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isExpanded ? "Hide the finished sessions" : "Show the finished sessions")
                .padding(.bottom, isExpanded ? 1 : 0)
        } else {
            heading.padding(.bottom, 4)
        }
    }

    /// A row is a control only when a click can do something: a terminal
    /// session with no tty has no tab to bring forward.
    func isClickable(_ agent: Agent) -> Bool {
        onSelect != nil && SessionFocus.action(for: agent) != .none
    }
}

/// One session: where it lives (a Terminal tab or the Desktop app), what it
/// is called, and how long it has been
/// in its state. A blocked row also says what it waits for, since "input
/// needed" and "permission to run tests" are different asks.
struct NeedsYouRow: View {
    let agent: Agent
    let now: Date

    var body: some View {
        HStack(spacing: 9) {
            // Named the way a limit row names its window, in the same column,
            // so the titles line up with the bars below. At this size the
            // terminal and window glyphs were indistinguishable.
            Text(agent.isDesktop ? "app" : "term")
                .font(Theme.label(11))
                .foregroundStyle(Theme.faint)
                .frame(width: 44, alignment: .leading)
            Text(agent.displayTitle)
                .font(Theme.label(12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if agent.isWaiting, let action = agent.action, !action.isEmpty {
                Text(action)
                    .font(Theme.label(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, 14)
    }

    @ViewBuilder
    private var trailing: some View {
        if let since = agent.stateSince {
            if agent.isWaiting {
                Text(Fmt.waited(since: since, now: now))
                    .font(Theme.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.claudeCoral)
                    .monospacedDigit()
                    .fixedSize()
            } else {
                Text("finished \(Fmt.ago(since, now: now))")
                    .font(Theme.label(10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize()
            }
        }
    }
}

/// The menu bar's needs-you mark: how many sessions are blocked on you, on a
/// coral pill. The caller leaves it out at zero, so the bar says nothing when
/// nobody waits.
///
/// A pill rather than a dot beside the number: the bar already puts a small
/// coral dot before the signed-in plan's figure, and "●2 •74" read as two plans.
/// White on the coral rather than the bar's ink, because the pill is its own
/// surface and reads the same on a light bar and a dark one.
struct NeedsYouBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Theme.mono(11, weight: .bold))
            .foregroundStyle(Color.white)
            .monospacedDigit()
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 15)
            .background(Capsule().fill(Theme.claudeCoral))
            .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 session needs you" : "\(count) sessions need you")
    }
}
