import DrSocial
import Foundation

/// Starts the native SDK for a React Native app: `DrSocialReact.start(options)` in
/// `application(_:didFinishLaunchingWithOptions:)`, before React. The app's own callbacks still run; links, messages,
/// config reads and a stop also go to JavaScript (`DrSocial.on(...)`), kept until JavaScript listens.
@objc(DrSocialReact)
public final class DrSocialReact: NSObject {
    @discardableResult
    public static func start(_ options: DrSocialOptions) -> DrSocial {
        var o = options
        let link = options.onLink, config = options.onConfig, messages = options.onMessages, banned = options.onBanned
        o.onLink = { l in
            link?(l)
            JsEvents.shared.send("link", l)
        }
        o.onConfig = { c in
            config?(c)
            JsEvents.shared.send("config", nil)
        }
        o.onMessages = { list in
            messages?(list)
            JsEvents.shared.send("messages", JsEvents.json(list) ?? "[]")
        }
        o.onBanned = { message, until in
            banned?(message, until)
            JsEvents.shared.send("banned", ["message": message, "until": until.map { ISO8601DateFormatter().string(from: $0) } ?? ""])
        }
        return DrSocial.start(o)
    }

    /// For Objective-C app delegates.
    @objc public static func start(buildKey: String, trustedKeys: [String: String]) {
        start(DrSocialOptions(buildKey: buildKey, trustedKeys: trustedKeys))
    }
}

/// What the SDK hands JavaScript; what comes before JavaScript listens waits here (≤ 20, newest kept).
final class JsEvents {
    static let shared = JsEvents()
    static let maxWaiting = 20

    private let lock = NSLock()
    private var waiting: [(String, Any?)] = []
    private weak var emitter: DrSocialModule?

    func send(_ name: String, _ value: Any?) {
        lock.lock()
        guard let e = emitter else {
            if waiting.count >= JsEvents.maxWaiting { waiting.removeFirst() }
            waiting.append((name, value))
            lock.unlock()
            return
        }
        lock.unlock()
        e.sendEvent(withName: "drsocial.\(name)", body: value)
    }

    /// JavaScript listens: what waited goes out in order.
    func attach(_ e: DrSocialModule) {
        lock.lock()
        emitter = e
        let out = waiting
        waiting.removeAll()
        lock.unlock()
        for (name, value) in out { e.sendEvent(withName: "drsocial.\(name)", body: value) }
    }

    func detach(_ e: DrSocialModule) {
        lock.lock()
        if emitter === e { emitter = nil }
        lock.unlock()
    }

    static func json(_ value: Any?) -> String? {
        guard let v = value, JSONSerialization.isValidJSONObject([v]),
              let data = try? JSONSerialization.data(withJSONObject: [v], options: []),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // The value was wrapped in a list so a bare string or number is valid JSON too.
        return String(text.dropFirst().dropLast())
    }
}
