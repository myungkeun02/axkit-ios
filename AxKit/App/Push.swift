import AxKitCore
import SwiftUI
import UIKit
import UserNotifications

/// Push notifications (§7.7). A 결재 arrives on the lock screen with 승인/거절 (both need Face ID / unlock);
/// tapping a notification opens the right tab.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let approve = "AX_APPROVE"
    static let deny = "AX_DENY"
    /// Set at launch (`AppModel.shared`), not only after the permission prompt: a lock-screen answer can wake the app
    /// in the background before any screen appears.
    weak var model: AppModel?
    private var pendingToken: String?
    /// Answers that came before the model was there; sent once it is.
    private var waiting: [(info: [AnyHashable: Any], action: String)] = []

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        MainActor.assumeIsolated { attach(AppModel.shared) }
        let approve = UNNotificationAction(identifier: Self.approve, title: "승인", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.deny, title: "거절", options: [.authenticationRequired, .destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "AX_CARD", actions: [approve, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "AX_OPEN", actions: [], intentIdentifiers: []),
        ])
        return true
    }

    @MainActor func attach(_ model: AppModel) {
        self.model = model
        let replay = waiting
        waiting = []
        for item in replay { Task { await self.handle(item.info, action: item.action) } }
    }

    /// Ask once, after pairing, when the Mac can send pushes.
    @MainActor func enable(for model: AppModel) async {
        if self.model !== model { attach(model) }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
        if let pendingToken { await send(pendingToken) }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        pendingToken = token
        Task { @MainActor in await send(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    @MainActor private func send(_ token: String) async {
        guard let client = model?.client else { return }
        #if DEBUG
        let production = false
        #else
        let production = true
        #endif
        try? await client.registerPush(token: token, production: production, topic: Bundle.main.bundleIdentifier ?? "")
    }

    // Show banners while the app is open too (the stream already updates the screen).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        // 승인/거절 run with the app in the background: keep it alive until the Mac has the answer. If iOS ends the
        // time first, the task is closed properly (never left open, which would get the app killed).
        let ender = BackgroundTaskEnder()
        let task = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "card-answer") { ender.end() }
        }
        ender.set(task)
        await handle(info, action: action)
        ender.end()
    }

    @MainActor private func handle(_ info: [AnyHashable: Any], action: String) async {
        guard let model else {
            waiting.append((info, action))
            return
        }
        let cardId = info["cardId"] as? String
        switch action {
        case Self.approve, Self.deny:
            guard let cardId else { return }
            let approve = action == Self.approve
            // ax-kit sends `decision:true` (answer with approve/deny); ax-hq names the button ids.
            let answer: CardAnswer
            if info["decision"] as? Bool == true { answer = .decision(approve ? "approve" : "deny") }
            else if let id = info[approve ? "approve" : "deny"] as? String { answer = .option(id) }
            else { answer = .decision(approve ? "approve" : "deny") }
            await model.answerFromNotification(cardId: cardId, answer, title: info["title"] as? String)
        default:
            if cardId != nil { model.tab = .approvals }
            else if let channel = info["channel"] as? String { model.showRoom(channel) }
            else { model.showRoom("") }
        }
    }
}

/// Ends a background task exactly once, from the expiration handler or the normal end, whichever comes first.
final class BackgroundTaskEnder: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UIBackgroundTaskIdentifier = .invalid
    private var ended = false

    func set(_ id: UIBackgroundTaskIdentifier) {
        lock.lock(); defer { lock.unlock() }
        if ended { DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) } } else { self.id = id }
    }

    func end() {
        lock.lock()
        let id = self.id
        let first = !ended
        ended = true
        self.id = .invalid
        lock.unlock()
        guard first, id != .invalid else { return }
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
    }
}
