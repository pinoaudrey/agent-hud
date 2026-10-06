import SwiftUI

// The setup panel: one row per section of `check-setup.sh`, in the script's own
// order, so the card and the terminal stay one mental model. A section that is
// fine takes one quiet line and says its count; a section with problems opens
// into its own surface, carrying each problem's message and the fix, with any
// runnable part of the fix in a chip you can copy.
//
// Kept out of PopoverCard.swift, which is already the largest file here.

public struct SetupSection: View {
    public let setup: SetupBlock?
    /// What the footer's copy button will put on the clipboard, surfaced here so
    /// the header count and the button can never disagree.
    public init(setup: SetupBlock?) {
        self.setup = setup
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionRule(title: "SETUP") { headerStatus }
            if let setup {
                if setup.isClean {
                    SetupAllClearView(sections: setup.sections)
                } else {
                    SetupProblemList(sections: setup.sections)
                }
            } else {
                SetupUnknownView()
            }
        }
    }

    /// The count sits in the header, so the panel says how much is wrong before
    /// you read a single row.
    @ViewBuilder
    private var headerStatus: some View {
        if let setup {
            Text(setup.isClean ? "consistent" : problemCount(setup.problems))
                .font(Theme.label(11))
                .tracking(0.4)
                .foregroundStyle(setup.isClean ? Theme.green : Theme.amber)
                .fixedSize()
        } else {
            Text("unknown")
                .font(Theme.label(11))
                .tracking(0.4)
                .foregroundStyle(Theme.muted)
                .fixedSize()
        }
    }

    private func problemCount(_ n: Int) -> String {
        n == 1 ? "1 problem" : "\(n) problems"
    }
}

// MARK: - Problems

/// A day with problems. The problems lead, each open with its fix; the checks
/// that passed fold behind one row, because a dozen green lines pushed the card
/// past the bottom of a laptop screen and hid the problem rows under them.
struct SetupProblemList: View {
    let sections: [SetupSectionResult]
    @State private var showsPassing: Bool

    init(sections: [SetupSectionResult], showsPassing: Bool = false) {
        self.sections = sections
        _showsPassing = State(initialValue: showsPassing)
    }

    var body: some View {
        let passing = sections.filter { !$0.isProblem }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sections.filter(\.isProblem)) { section in
                SetupRow(section: section)
            }
            if !passing.isEmpty {
                PassingToggle(count: passing.count, isExpanded: showsPassing) {
                    withAnimation(.easeOut(duration: 0.18)) { showsPassing.toggle() }
                }
                if showsPassing {
                    ForEach(passing) { section in
                        SetupRow(section: section)
                    }
                }
            }
        }
    }
}

/// The fold over the passing checks: how many, and a chevron that says which
/// way it opens.
struct PassingToggle: View {
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.green).frame(width: 6, height: 6)
            Text(count == 1 ? "1 check passes" : "\(count) checks pass")
                .font(Theme.label(12))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .clickableRow()
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Hide the passing checks" : "Show the passing checks")
    }
}

// MARK: - All clear

/// The normal day. Everything passed, so the panel collapses to one sentence and
/// a row of quiet pills naming what was checked — enough to show the gate ran,
/// small enough not to compete with the quota bars above it.
struct SetupAllClearView: View {
    let sections: [SetupSectionResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("every account agrees, everything captured and pushed")
                .font(Theme.label(13))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(sections) { section in
                    SetupPill(label: section.label)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }
}

struct SetupPill: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.green).frame(width: 5, height: 5)
            Text(label)
                .font(Theme.label(11))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.panel2))
    }
}

// MARK: - Unknown

/// The state that exists so the panel can never lie. The daemon sends no setup
/// block whenever it could not ask the question — no `~/.agents`, a check-setup
/// that predates `--json`, a crash, a hang — and an unanswered question has to
/// read as unanswered rather than as an all-clear.
struct SetupUnknownView: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.faint).frame(width: 6, height: 6)
            Text("could not run ~/.agents/bin/check-setup.sh --json")
                .font(Theme.label(12))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

// MARK: - Rows

/// One section. Fine sections stay a single line with their roll-up on the
/// right; a section with problems gets its own washed surface and opens to show
/// each problem and how to fix it.
struct SetupRow: View {
    let section: SetupSectionResult

    var body: some View {
        if section.isProblem {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(section.problems.enumerated()), id: \.offset) { index, problem in
                    // The section's roll-up belongs to the section, so it is
                    // drawn once, against the first problem.
                    header(message: problem.message, detail: index == 0 ? section.summary : "")
                    FixLine(fix: problem.fix, command: problem.fixCommand)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warnSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.warnBorder, lineWidth: 1)
            )
        } else {
            // The sentence the terminal prints, not the short label: a row has
            // the width for it, and reusing it means there is no third wording
            // of the same check to keep in step. The label earns its keep in the
            // all-clear pills, where there is no room for a sentence.
            header(message: section.title, detail: section.summary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
    }

    private func header(message: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(section.isProblem ? Theme.amber : Theme.green)
                .frame(width: 6, height: 6)
            Text(message)
                .font(Theme.label(12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.label(11))
                    .foregroundStyle(section.isProblem ? Theme.amber : Theme.muted)
                    .fixedSize()
            }
        }
    }
}

/// A fix: prose, then the runnable part in a chip. The daemon does the splitting
/// (check-setup.sh emits `fix` and `fix_command` separately), so this never has
/// to guess which words are a command.
struct FixLine: View {
    let fix: String
    let command: String

    var body: some View {
        if !fix.isEmpty || !command.isEmpty {
            HStack(alignment: .center, spacing: 8) {
                Text("fix")
                    .font(Theme.label(11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize()
                if !fix.isEmpty {
                    Text(fix)
                        .font(Theme.label(11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !command.isEmpty {
                    Text(command)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.chip)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Theme.chipBorder, lineWidth: 1)
                        )
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
        }
    }
}

// MARK: - Layout

/// Wrapping horizontal stack, for the all-clear pills. SwiftUI has no wrapping
/// HStack before macOS 15's `Layout`-based helpers, and the pill row genuinely
/// needs to wrap: the number of sections is whatever check-setup has.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && advance > width {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
