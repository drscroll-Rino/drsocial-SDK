import DrSocial
import Foundation
import React
import StoreKit
import UIKit

/// `NativeModules.DrSocial` on iOS: each call goes to the running native SDK (started in the AppDelegate through
/// `DrSocialReact.start`). Before the SDK is started a call does nothing and a promise answers null.
@objc(DrSocialModule)
final class DrSocialModule: RCTEventEmitter {
    override static func requiresMainQueueSetup() -> Bool { false }

    override func supportedEvents() -> [String]! {
        ["drsocial.link", "drsocial.messages", "drsocial.config", "drsocial.banned"]
    }

    override func startObserving() { JsEvents.shared.attach(self) }
    override func stopObserving() { JsEvents.shared.detach(self) }

    private var sdk: DrSocial? { Started.sdk }

    @objc func isStarted() -> NSNumber { NSNumber(value: Started.sdk != nil) }

    @objc(identify:options:resolver:rejecter:)
    func identify(_ externalId: String, options: NSDictionary, resolve: @escaping RCTPromiseResolveBlock, reject _: @escaping RCTPromiseRejectBlock) {
        guard let s = sdk else { return resolve(nil) }
        let o = options as? [String: Any] ?? [:]
        Task {
            let user = try? await s.client.identify(
                externalId,
                identityHash: o["identityHash"] as? String,
                traits: o["traits"] as? [String: Any],
                analytics: o["analytics"] as? Bool,
                messages: o["messages"] as? Bool,
                locale: o["locale"] as? String,
                country: o["country"] as? String,
                profile: o["profile"] as? [String: String])
            resolve(user ?? nil)
        }
    }

    @objc(signOut:rejecter:)
    func signOut(_ resolve: @escaping RCTPromiseResolveBlock, reject _: @escaping RCTPromiseRejectBlock) {
        sdk?.signOut()
        resolve(nil)
    }

    @objc(track:props:)
    func track(_ name: String, props: NSDictionary) {
        sdk?.track(name, props as? [String: Any] ?? [:])
    }

    @objc(screen:)
    func screen(_ name: String) { sdk?.screen(name) }

    /// A JavaScript error, sent at once (kind non_fatal) with its JavaScript frames while `crash_lines` is on. The message is
    /// never sent, as with every crash.
    @objc(reportError:message:frames:)
    func reportError(_ type: String, message _: String, frames: NSArray) {
        guard let s = sdk, s.config.feature("crash_lines") else { return }
        let list: [SdkFrame] = (frames as? [[String: Any]] ?? []).prefix(40).map {
            SdkFrame(fn: $0["fn"] as? String ?? "?", file: $0["file"] as? String, line: ($0["line"] as? NSNumber)?.intValue)
        }
        let crash = SdkCrash(kind: "non_fatal", type: "JavaScript.\(type)", frames: Array(list), appVersion: s.client.appVersion,
                             osVersion: UIDevice.current.systemVersion)
        Task { _ = try? await s.client.crashes([crash]) }
    }

    @objc(flush:rejecter:)
    func flush(_ resolve: @escaping RCTPromiseResolveBlock, reject _: @escaping RCTPromiseRejectBlock) {
        guard let s = sdk else { return resolve(nil) }
        Task {
            await s.flush()
            resolve(nil)
        }
    }

    @objc(siteUrl:resolver:rejecter:)
    func siteUrl(_ url: String, resolve: @escaping RCTPromiseResolveBlock, reject _: @escaping RCTPromiseRejectBlock) {
        guard let s = sdk else { return resolve(url) }
        Task { resolve(await s.siteUrl(url)) }
    }

    /// A remote value as JSON text (nil = not set).
    @objc(value:)
    func value(_ key: String) -> NSString? {
        guard let s = sdk, let v = s.json(key) else { return nil }
        return JsEvents.json(v) as NSString?
    }

    @objc func update() -> NSDictionary {
        guard let u = sdk?.update else { return ["need": 0, "url": "", "message": ""] }
        return ["need": u.need.rawValue, "url": u.url, "message": u.message]
    }

    @objc(askReviewIfDue:rejecter:)
    func askReviewIfDue(_ resolve: @escaping RCTPromiseResolveBlock, reject _: @escaping RCTPromiseRejectBlock) {
        guard let s = sdk, s.config.feature("store_review") else { return resolve(false) }
        Task {
            guard let answer = try? await s.client.review(), answer.ask else { return resolve(false) }
            DispatchQueue.main.async {
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
                guard let scene = scene else { return resolve(false) }
                SKStoreReviewController.requestReview(in: scene)
                resolve(true)
            }
        }
    }

    @objc(messages:rejecter:)
    func messages(_ resolve: @escaping RCTPromiseResolveBlock, reject _: @escaping RCTPromiseRejectBlock) {
        guard let s = sdk else { return resolve("[]") }
        Task {
            let list = (try? await s.client.messages()) ?? []
            resolve(JsEvents.json(list) ?? "[]")
        }
    }

    @objc(messageEvent:kind:answer:resolver:rejecter:)
    func messageEvent(_ id: String, kind: String, answer: String?, resolve: @escaping RCTPromiseResolveBlock, reject _: @escaping RCTPromiseRejectBlock) {
        guard let s = sdk else { return resolve(nil) }
        let a = answer.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        Task {
            try? await s.client.messageEvent(id, kind: kind, answer: a)
            resolve(nil)
        }
    }

    @objc(requestPush:)
    func requestPush(_ provisional: Bool) { sdk?.requestPush(provisional: provisional) }

    @objc(liveActivity:type:activity:token:)
    func liveActivity(_ kind: String, type: String, activity: String?, token: String?) {
        sdk?.liveActivity(kind: kind, type: type, activity: activity, token: token)
    }
}

/// Whether the native SDK was started (DrSocial.shared stops the app before then).
enum Started {
    static var sdk: DrSocial? { DrSocial.isStarted ? DrSocial.shared : nil }
}
