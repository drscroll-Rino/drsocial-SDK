import CryptoKit
import Foundation

/// Compares two dotted versions number by number: -1, 0 or 1 ("1.10" > "1.9"; a missing part is 0; anything that is not a
/// number counts as 0). The same rule as the platform's `RemoteControl::compare`, the Dart core and the Kotlin SDK.
public func compareVersions(_ a: String, _ b: String) -> Int {
    func parts(_ v: String) -> [Int] { v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 } }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l < r ? -1 : 1 }
    }
    return 0
}

/// The installation's bucket for one key, 0–99: first 4 bytes of `sha256("<install id>|<key>")` as an unsigned big-endian
/// number, mod 100. Every DrSocial SDK and the platform (`RemoteControl::bucket`) use this same rule.
public func rolloutBucket(_ installId: String, _ key: String) -> Int {
    let d = Array(SHA256.hash(data: Data("\(installId)|\(key)".utf8)))
    let n = (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
    return Int(n % 100)
}

/// One remote value as the platform sends it.
public struct RemoteValue {
    /// bool · number · string · json.
    public let type: String
    public let value: Any?
    /// The share of installations (0–100) that get the value.
    public let rollout: Int
    /// Below this app version the value is not given ('' = every version).
    public let minVersion: String

    init(_ j: JsonObject) {
        type = j.str("type") ?? "string"
        value = j["value"]
        rollout = j.num("rollout").map { Int($0) } ?? 100
        minVersion = j.str("min_version") ?? ""
    }
}

public enum UpdateNeed: Int { case none, suggested, required }

public struct UpdateAdvice {
    public let need: UpdateNeed
    /// The store page (https) to open, '' when the company gave none.
    public let url: String
    public let message: String
}

/// What the build's config says (GET /sdk/{key}/config, API v1).
public struct SdkConfig {
    public let raw: JsonObject

    /// Every feature off and nothing remote: the first run with no network.
    public static let empty = SdkConfig(raw: [:])

    public init(raw: JsonObject) { self.raw = raw }

    public static func parse(_ body: String) -> SdkConfig { SdkConfig(raw: Json.parseObject(body)) }

    /// A feature the SDK may start; anything not named is off.
    public func feature(_ name: String) -> Bool { raw.obj("features").isTrue(name) }

    /// How long the config may be used before it is read again (seconds).
    public var ttlSeconds: Int { raw.num("ttl").map { Int($0) } ?? 300 }

    public func endpoint(_ name: String) -> String? { raw.obj("endpoints").str(name) }

    /// The key generation; a device registered on an older one registers again.
    public var epoch: Int { raw.obj("security").num("epoch").map { Int($0) } ?? 1 }

    public var requireToken: Bool { raw.obj("security").isTrue("require_token") }

    /// off · monitor · enforce.
    public var attestation: String { raw.obj("security").str("attestation") ?? "off" }

    /// SPKI SHA-256 pins ("sha256/…") of the platform's certificate chain; empty = the system's trust only.
    public var pins: [String] { raw.obj("security").arr("pins").strings() }

    /// The remote values, or an empty map while remote config is off.
    public var remote: [String: RemoteValue] {
        guard let r = raw["remote"] as? JsonObject else { return [:] }
        var out: [String: RemoteValue] = [:]
        for (k, v) in r { if let o = v as? JsonObject { out[k] = RemoteValue(o) } }
        return out
    }

    /// The raw remote value of [key] for this installation and app version, or nil when it is not given to it.
    public func valueFor(_ key: String, installId: String, appVersion: String) -> Any? {
        guard let v = remote[key] else { return nil }
        if v.rollout < 100 && rolloutBucket(installId, key) >= v.rollout { return nil }
        if !v.minVersion.isEmpty && compareVersions(appVersion, v.minVersion) < 0 { return nil }
        if v.value is NSNull { return nil }
        return v.value
    }

    public func string(_ key: String, _ fallback: String, installId: String, appVersion: String) -> String {
        valueFor(key, installId: installId, appVersion: appVersion) as? String ?? fallback
    }

    public func bool(_ key: String, _ fallback: Bool, installId: String, appVersion: String) -> Bool {
        let v = valueFor(key, installId: installId, appVersion: appVersion)
        guard Json.isBool(v), let n = v as? NSNumber else { return fallback }
        return n.boolValue
    }

    public func int(_ key: String, _ fallback: Int, installId: String, appVersion: String) -> Int {
        let v = valueFor(key, installId: installId, appVersion: appVersion)
        guard !Json.isBool(v), let n = v as? NSNumber else { return fallback }
        let d = n.doubleValue
        return d == d.rounded() ? n.intValue : fallback
    }

    public func double(_ key: String, _ fallback: Double, installId: String, appVersion: String) -> Double {
        let v = valueFor(key, installId: installId, appVersion: appVersion)
        guard !Json.isBool(v), let n = v as? NSNumber else { return fallback }
        return n.doubleValue
    }

    /// A `json` value (object or array); [fallback] when it is not given.
    public func json(_ key: String, _ fallback: Any?, installId: String, appVersion: String) -> Any? {
        let v = valueFor(key, installId: installId, appVersion: appVersion)
        if v is JsonObject || v is [Any] { return v }
        return fallback
    }

    private var iconObj: JsonObject? { raw["icon"] as? JsonObject }

    /// The icon the app should show: an alternate icon's name, '' for the app's own, nil while icon switching is off.
    /// Only names built into the release are ever returned.
    public var icon: String? {
        guard let i = iconObj else { return nil }
        let current = i.str("current") ?? ""
        return current.isEmpty || i.arr("available").strings().contains(current) ? current : ""
    }

    /// The icon to show at [now], applying the coming switches of `schedule` even offline: between `from` and `to` show its
    /// `icon`; when two cover [now] the one that started last wins; outside them the `default`. Nil while switching is off.
    public func iconAt(_ now: Date) -> String? {
        guard let i = iconObj else { return nil }
        let available = Set(i.arr("available").strings())
        func pick(_ name: String) -> String { name.isEmpty || available.contains(name) ? name : "" }
        let schedule = i.arr("schedule").objects()
        var started: Date?
        var chosen: String?
        for s in schedule {
            guard let from = parseTime(s.str("from")), let to = parseTime(s.str("to")) else { continue }
            if now < from || now >= to { continue }
            if started == nil || from > started! {
                started = from
                chosen = s.str("icon") ?? ""
            }
        }
        if let chosen = chosen { return pick(chosen) }
        // `current` is the platform's answer when the config was read; once a switch it named has ended, fall back to `default`.
        let current = i.str("current") ?? ""
        let inSchedule = schedule.contains { $0.str("icon") == current }
        return pick(inSchedule ? (i.str("default") ?? "") : current)
    }

    /// The icon names built into this release, as the config lists them.
    public var availableIcons: [String] { iconObj?.arr("available").strings() ?? [] }

    /// The store-review rules while `store_review` is on, else nil.
    public var review: JsonObject? { raw["review"] as? JsonObject }

    /// The query name the app adds to the company's own site's address with the device id.
    public var siteBanParam: String { raw.obj("bans").str("site_param") ?? "drs_d" }

    /// What the app must do about updating, for [appVersion].
    public func update(_ appVersion: String) -> UpdateAdvice {
        guard let u = raw["update"] as? JsonObject else { return UpdateAdvice(need: .none, url: "", message: "") }
        let min = u.str("min_version") ?? "", latest = u.str("latest_version") ?? ""
        let url = u.str("url") ?? "", message = u.str("message") ?? ""
        if !min.isEmpty && compareVersions(appVersion, min) < 0 { return UpdateAdvice(need: .required, url: url, message: message) }
        if !latest.isEmpty && compareVersions(appVersion, latest) < 0 { return UpdateAdvice(need: .suggested, url: url, message: message) }
        return UpdateAdvice(need: .none, url: "", message: "")
    }
}
