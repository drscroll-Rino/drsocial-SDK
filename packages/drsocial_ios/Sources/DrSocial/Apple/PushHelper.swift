#if os(iOS)
import UIKit
import UserNotifications

/// UNUserNotificationCenter glue: the `drs_actions` category from `drs_buttons`, silent pushes, opens and button presses,
/// and the vibration pattern as haptics while the app is open.
public enum DrSocialPush {
    /// The category with the notification's own buttons (`drs_buttons`). Call it from the Notification Service Extension
    /// before the notification shows (`didReceive(_:withContentHandler:)`), and it is also done by [willPresent].
    public static func registerCategory(for push: DrsPush, center: UNUserNotificationCenter = .current(), done: (() -> Void)? = nil) {
        let buttons = push.buttons
        guard !buttons.isEmpty else { done?(); return }
        let actions = buttons.map { b in
            UNNotificationAction(identifier: b.id, title: b.label, options: b.link.isEmpty ? [] : [.foreground])
        }
        let category = UNNotificationCategory(identifier: DrsPush.category, actions: actions, intentIdentifiers: [], options: [])
        center.getNotificationCategories { existing in
            var set = existing.filter { $0.identifier != DrsPush.category }
            set.insert(category)
            center.setNotificationCategories(set)
            done?()
        }
    }

    /// For a Notification Service Extension: registers the buttons and adds the `drs_image` picture, then hands the
    /// content on. Call from `didReceive(_:withContentHandler:)`.
    public static func serviceExtension(_ request: UNNotificationRequest, contentHandler: @escaping (UNNotificationContent) -> Void) {
        let push = DrsPush(userInfo: request.content.userInfo)
        guard push.isDrSocial, let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        registerCategory(for: push) {
            guard let url = URL(string: push.image), url.scheme == "https" else {
                contentHandler(content)
                return
            }
            URLSession.shared.downloadTask(with: url) { file, response, _ in
                if let file = file {
                    let ext = (response?.suggestedFilename as NSString?)?.pathExtension ?? url.pathExtension
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (ext.isEmpty ? "jpg" : ext))
                    if (try? FileManager.default.moveItem(at: file, to: dest)) != nil,
                       let att = try? UNNotificationAttachment(identifier: "drs_image", url: dest) {
                        content.attachments = [att]
                    }
                }
                contentHandler(content)
            }.resume()
        }
    }

    /// The permission as the platform names it: granted · denied · provisional.
    public static func permission(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .ephemeral: return "granted"
        case .provisional: return "provisional"
        default: return "denied"
        }
    }

    public static func currentPermission() async -> String {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings { cont.resume(returning: permission($0.authorizationStatus)) }
        }
    }
}
#endif
