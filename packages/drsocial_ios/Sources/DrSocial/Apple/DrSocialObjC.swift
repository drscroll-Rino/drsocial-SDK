#if os(iOS)
import Foundation
import UIKit
import UserNotifications

/// The SDK for Objective-C: a thin facade over `DrSocial`. `@import DrSocial;` then
/// `[DRSocial startWithBuildKey:@"…" trustedKeys:@{@"v1": @"…"}];`.
@objc(DRSocial)
public final class DrSocialObjC: NSObject {
    @objc public static func start(buildKey: String, trustedKeys: [String: String]) {
        DrSocial.start(DrSocialOptions(buildKey: buildKey, trustedKeys: trustedKeys))
    }

    /// With the callbacks: a link to open, and the phone stopped (message, until or nil).
    @objc public static func start(buildKey: String, trustedKeys: [String: String], onLink: ((String) -> Void)?,
                                   onBanned: ((String, Date?) -> Void)?) {
        var o = DrSocialOptions(buildKey: buildKey, trustedKeys: trustedKeys)
        o.onLink = onLink
        o.onBanned = onBanned
        DrSocial.start(o)
    }

    @objc public static func identify(_ externalId: String, identityHash: String?) {
        DrSocial.shared.identify(externalId, identityHash: identityHash)
    }

    @objc public static func identify(_ externalId: String, identityHash: String?, traits: [String: Any]?, analytics: NSNumber?, messages: NSNumber?) {
        DrSocial.shared.identify(externalId, identityHash: identityHash, traits: traits, analytics: analytics?.boolValue, messages: messages?.boolValue)
    }

    @objc public static func signOut() { DrSocial.shared.signOut() }

    @objc public static func track(_ name: String, properties: [String: Any]?) { DrSocial.shared.track(name, properties ?? [:]) }

    @objc public static func screen(_ route: String) { DrSocial.shared.screen(route) }

    @objc public static func reportError(_ error: NSError) { DrSocial.shared.reportError(error) }

    @objc public static func flush(completion: (() -> Void)?) {
        Task {
            await DrSocial.shared.flush()
            DispatchQueue.main.async { completion?() }
        }
    }

    @objc public static func siteURL(_ url: String, completion: @escaping (String) -> Void) {
        Task {
            let u = await DrSocial.shared.siteUrl(url)
            DispatchQueue.main.async { completion(u) }
        }
    }

    // Remote values.
    @objc public static func string(forKey key: String, fallback: String) -> String { DrSocial.shared.string(key, fallback) }
    @objc public static func bool(forKey key: String, fallback: Bool) -> Bool { DrSocial.shared.bool(key, fallback) }
    @objc public static func integer(forKey key: String, fallback: Int) -> Int { DrSocial.shared.int(key, fallback) }
    @objc public static func double(forKey key: String, fallback: Double) -> Double { DrSocial.shared.double(key, fallback) }
    @objc public static func json(forKey key: String) -> Any? { DrSocial.shared.json(key) }

    /// 0 none · 1 suggested · 2 required.
    @objc public static var updateNeed: Int { DrSocial.shared.update.need.rawValue }

    // Push.
    @objc public static func requestPush(provisional: Bool) { DrSocial.shared.requestPush(provisional: provisional) }
    @objc public static func setPushToken(_ deviceToken: Data) { DrSocial.shared.setPushToken(deviceToken) }

    @objc @discardableResult
    public static func handleRemoteNotification(_ userInfo: [AnyHashable: Any], completion: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        DrSocial.shared.handleRemoteNotification(userInfo, completion: completion)
    }

    /// The options to show the notification with; 0 when it is not DrSocial's (show it your own way).
    @objc public static func willPresent(_ notification: UNNotification) -> UNNotificationPresentationOptions {
        DrSocial.shared.willPresent(notification) ?? []
    }

    @objc @discardableResult
    public static func didReceive(_ response: UNNotificationResponse) -> Bool { DrSocial.shared.didReceive(response) }

    /// For the Notification Service Extension (no `start` needed there).
    @objc public static func serviceExtension(_ request: UNNotificationRequest, contentHandler: @escaping (UNNotificationContent) -> Void) {
        DrSocialPush.serviceExtension(request, contentHandler: contentHandler)
    }

    // Review, Live Activities.
    @objc public static func askReviewIfDue() { DrSocial.shared.askReviewIfDue() }

    @objc public static func liveActivity(kind: String, type: String, activity: String?, token: String?) {
        DrSocial.shared.liveActivity(kind: kind, type: type, activity: activity, token: token)
    }
}
#endif
