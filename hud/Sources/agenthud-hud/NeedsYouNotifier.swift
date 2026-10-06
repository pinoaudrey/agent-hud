import Foundation
import HUDCore
import UserNotifications

/// Posts a macOS notification when a session starts waiting on you, and takes
/// it down when the wait ends. Clicking one brings the session forward, as a
/// click on its NEEDS YOU row does.
///
/// `UNUserNotificationCenter` needs a bundle identifier, which `swift run`
/// does not have; the notifier stays off there and works in AgentHUD.app.
@MainActor
final class NeedsYouNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var alerts = NeedsYouAlerts()
    private let center: UNUserNotificationCenter?
    private let agentForPID: (Int) -> Agent?

    init(agentForPID: @escaping (Int) -> Agent?) {
        self.agentForPID = agentForPID
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func update(with snapshot: HUDSnapshot?) {
        let change = alerts.update(with: snapshot)
        guard let center else { return }
        if !change.ended.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: change.ended)
        }
        for agent in change.arrived {
            let notice = NeedsYouNotice(agent: agent)
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            content.userInfo = ["pid": notice.pid]
            center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
        }
    }

    /// AgentHUD has no windows to be in front of, so macOS would treat it as
    /// active and swallow the banner without this.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let pid = response.notification.request.content.userInfo["pid"] as? Int
        Task { @MainActor in
            if let pid, let agent = self.agentForPID(pid) {
                SessionFocus.bringForward(agent)
            }
            completionHandler()
        }
    }
}
