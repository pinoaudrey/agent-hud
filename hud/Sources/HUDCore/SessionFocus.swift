import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Bringing a session forward from a NEEDS YOU row.
///
/// A terminal session is found by its tty: Terminal.app reports each tab's
/// device ("/dev/ttys012"), which is the one fact the daemon and Terminal agree
/// on. A Desktop session has no terminal, so the Claude app is asked to open it
/// by its own session id; a build of the app that ignores the link still comes
/// to the front, which is the fallback.
///
/// The pure parts (which action, the script text, the link) are separate from
/// the part that runs them, so tests check what would happen without anything
/// on the machine moving.
public enum SessionFocus {

    public static let terminalBundleID = "com.apple.Terminal"
    public static let claudeBundleID = "com.anthropic.claudefordesktop"

    public enum Action: Equatable {
        /// Select the Terminal tab on this device, raise its window, activate Terminal.
        case terminalTab(device: String)
        /// Open this link in the Claude app, which also brings it forward.
        case claudeLink(URL)
        /// Bring the Claude app forward and nothing more.
        case activateClaude
        /// Nothing this card can do: a terminal session without a tty.
        case none
    }

    /// What clicking this agent's row does.
    public static func action(for agent: Agent) -> Action {
        if agent.isDesktop {
            if let id = agent.hostSessionID, let url = desktopLink(hostSessionID: id) {
                return .claudeLink(url)
            }
            return .activateClaude
        }
        guard let tty = agent.tty, isSafeTTY(tty) else { return .none }
        return .terminalTab(device: "/dev/\(tty)")
    }

    /// `claude://code/continue?session=local_…`, the link the Claude app's own
    /// dock menu uses to reopen one Code session. The id is checked against the
    /// shape the app itself accepts, so nothing else reaches its URL handler.
    public static func desktopLink(hostSessionID id: String) -> URL? {
        guard id.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return URL(string: "claude://code/continue?session=\(id)")
    }

    /// The tty is interpolated into a script, so only the shape `ps` prints
    /// ("ttys012") is let through.
    static func isSafeTTY(_ tty: String) -> Bool {
        tty.range(of: #"^ttys?[0-9]{1,4}$"#, options: .regularExpression) != nil
    }

    /// Select the tab on `device`, make its window frontmost, and activate
    /// Terminal. Returns false when no tab matches, so a session running in
    /// another terminal app changes nothing.
    public static func terminalScript(device: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(device)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    #if canImport(AppKit)
    /// Run the row's action. Main actor because NSAppleScript is not thread
    /// safe, and the script is short enough that the card does not notice.
    @MainActor
    public static func bringForward(_ agent: Agent) {
        switch action(for: agent) {
        case .terminalTab(let device):
            // Only ask a Terminal that is already running: `tell application`
            // would launch it for a session that lives in some other terminal.
            guard !NSRunningApplication.runningApplications(
                withBundleIdentifier: terminalBundleID).isEmpty else { return }
            var error: NSDictionary?
            NSAppleScript(source: terminalScript(device: device))?.executeAndReturnError(&error)
        case .claudeLink(let url):
            if !NSWorkspace.shared.open(url) { activateClaude() }
        case .activateClaude:
            activateClaude()
        case .none:
            break
        }
    }

    @MainActor
    private static func activateClaude() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else {
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif
}
