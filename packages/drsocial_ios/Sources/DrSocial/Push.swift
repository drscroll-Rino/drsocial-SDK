import Foundation

/// The vibration patterns the platform names (`PushVibration::PATTERNS`): wait, buzz, wait, buzz… in ms.
public enum PushVibration {
    public static let names = ["default", "none", "short", "double", "long", "heartbeat", "ripple", "urgent"]

    public static let patterns: [String: [Int]?] = [
        "default": nil,
        "none": [],
        "short": [0, 150],
        "double": [0, 120, 100, 120],
        "long": [0, 700],
        "heartbeat": [0, 90, 110, 90, 500, 90, 110, 90],
        "ripple": [0, 60, 60, 90, 60, 120, 60, 160],
        "urgent": [0, 400, 150, 400, 150, 400],
    ]

    /// `drs_vibe_ms` ("0,120,100,120") read back; nil when absent or not numbers.
    public static func parseMs(_ s: String?) -> [Int]? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        var out: [Int] = []
        for p in s.split(separator: ",", omittingEmptySubsequences: false) {
            guard let n = Int(p.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    /// One buzz for Core Haptics: when it starts and how long it lasts, in seconds.
    public struct Buzz: Equatable {
        public let start: Double
        public let duration: Double
    }

    /// The pattern (wait, buzz, wait, buzz… ms) as Core Haptics buzzes; Apple allows no custom pattern for the
    /// notification itself, so the SDK plays it with Core Haptics while the app is open.
    public static func buzzes(_ ms: [Int]) -> [Buzz] {
        var out: [Buzz] = []
        var t = 0
        for (i, v) in ms.enumerated() {
            if i % 2 == 1 && v > 0 { out.append(Buzz(start: Double(t) / 1000, duration: Double(v) / 1000)) }
            t += v
        }
        return out
    }
}

/// One button of a notification (`drs_buttons`): [link] opens a screen when the app's deep links are on.
public struct PushButton: Equatable {
    public let id: String
    public let label: String
    public let link: String
}

/// A DrSocial notification's data, as APNs (or FCM) hands it to the app. Not ours ([isDrSocial] false) when it carries
/// no `drs_push`.
public struct DrsPush {
    public let data: [String: String]

    public init(_ data: [String: String]) { self.data = data }

    /// From a notification's `userInfo`: the top-level keys (the `aps` dictionary is skipped); values become text.
    public init(userInfo: [AnyHashable: Any]) {
        var d: [String: String] = [:]
        for (k, v) in userInfo {
            guard let key = k as? String, key != "aps" else { continue }
            switch v {
            case let s as String: d[key] = s
            case let n as NSNumber: d[key] = n.stringValue
            case let a as [Any]: d[key] = Json.encode(a)
            case let o as [String: Any]: d[key] = Json.encode(o)
            default: break
            }
        }
        data = d
    }

    public var push: String? { data["drs_push"].flatMap { $0.isEmpty ? nil : $0 } }
    public var isDrSocial: Bool { push != nil }
    public var link: String { data["drs_link"] ?? "" }
    /// refresh = read the config, the messages and the remote values again; ping = do nothing at all. Nil = a visible notification.
    public var silent: String? { data["drs_silent"].flatMap { $0.isEmpty ? nil : $0 } }
    public var title: String { data["drs_title"] ?? "" }
    public var body: String { data["drs_body"] ?? "" }
    public var image: String { data["drs_image"] ?? "" }

    public var vibration: String {
        guard let v = data["drs_vibe"], PushVibration.patterns.keys.contains(v) else { return "default" }
        return v
    }

    public var vibrationMs: [Int]? { PushVibration.parseMs(data["drs_vibe_ms"]) ?? (PushVibration.patterns[vibration] ?? nil) }

    /// Up to 3 buttons; `drs_buttons` comes as a JSON string.
    public var buttons: [PushButton] {
        guard let raw = data["drs_buttons"], !raw.trimmingCharacters(in: .whitespaces).isEmpty,
              let arr = Json.parseAny(raw) as? [Any] else { return [] }
        let buttons: [PushButton] = arr.objects().compactMap { b in
            guard let id = b.str("id"), DrsPush.validId(id) else { return nil }
            return PushButton(id: id, label: b.str("label") ?? id, link: b.str("link") ?? "")
        }
        return Array(buttons.prefix(3))
    }

    /// The category every DrSocial notification with buttons names (`aps.category`).
    public static let category = "drs_actions"

    static func validId(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9_]{1,32}$", options: .regularExpression) != nil
    }
}
