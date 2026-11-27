import Foundation

/// A random id the platform accepts (8–64 of A–Z a–z 0–9 _ -): 24 hex characters.
public func newSdkId() -> String { DrSocialClient.randomHex(12) }

/// One event the app tracks (`POST /sdk/{key}/track`). [id] is made once and sent again on a retry, so it is kept once.
public struct SdkEvent {
    public let name: String
    /// ≤ 20 plain values (text, numbers, true/false); never personal data.
    public let props: [String: Any]
    public let at: Date
    public let id: String

    public init(_ name: String, props: [String: Any] = [:], at: Date = Date(), id: String = newSdkId()) {
        self.name = name
        self.props = props
        self.at = at
        self.id = id
    }

    public func toMap() -> [String: Any] {
        var m: [String: Any] = ["id": id, "name": name, "at": SdkTime.format(at)]
        if !props.isEmpty { m["props"] = props }
        return m
    }

    public static func from(_ j: JsonObject) -> SdkEvent {
        SdkEvent(j.str("name") ?? "", props: j.obj("props"), at: parseTime(j.str("at")) ?? Date(), id: j.str("id") ?? newSdkId())
    }
}

/// One frame of a crash's stack. [offset] (hex) = the address in its image minus the image's load address; [lib] = the image.
public struct SdkFrame: Equatable {
    public let fn: String
    public let file: String?
    public let line: Int?
    public let lib: String?
    public let offset: String?

    public init(fn: String, file: String? = nil, line: Int? = nil, lib: String? = nil, offset: String? = nil) {
        self.fn = fn
        self.file = file
        self.line = line
        self.lib = lib
        self.offset = offset
    }

    public func toMap() -> [String: Any] {
        var m: [String: Any] = ["fn": fn]
        if let file = file { m["file"] = file }
        if let line = line { m["line"] = line }
        if let lib = lib { m["lib"] = lib }
        if let offset = offset { m["offset"] = offset }
        return m
    }
}

/// A crash to report (on the next launch for a fatal one). Never put personal data in [message].
public struct SdkCrash {
    /// fatal · non_fatal · anr.
    public let kind: String
    public let type: String
    public let frames: [SdkFrame]
    public let message: String?
    public let appVersion: String?
    public let osVersion: String?
    public let screen: String?
    public let at: Date
    public let id: String

    public init(kind: String, type: String, frames: [SdkFrame], message: String? = nil, appVersion: String? = nil,
                osVersion: String? = nil, screen: String? = nil, at: Date = Date(), id: String = newSdkId()) {
        self.kind = kind
        self.type = type
        self.frames = frames
        self.message = message
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.screen = screen
        self.at = at
        self.id = id
    }

    public func toMap() -> [String: Any] {
        var m: [String: Any] = ["id": id, "at": SdkTime.format(at), "kind": kind, "type": type,
                                "frames": frames.prefix(40).map { $0.toMap() }]
        if let message = message { m["message"] = message }
        if let v = appVersion { m["app_version"] = v }
        if let v = osVersion { m["os_version"] = v }
        if let v = screen { m["screen"] = v }
        return m
    }

    /// A crash written by [toMap] (kept on disk until sent).
    public static func parse(_ text: String) -> SdkCrash { from(Json.parseObject(text)) }

    public static func from(_ j: JsonObject) -> SdkCrash {
        SdkCrash(
            kind: j.str("kind") ?? "fatal",
            type: j.str("type") ?? "Error",
            frames: j.arr("frames").objects().map {
                SdkFrame(fn: $0.str("fn") ?? "?", file: $0.str("file"), line: $0.num("line").map { Int($0) }, lib: $0.str("lib"), offset: $0.str("offset"))
            },
            message: j.str("message"),
            appVersion: j.str("app_version"),
            osVersion: j.str("os_version"),
            screen: j.str("screen"),
            at: parseTime(j.str("at")) ?? Date(),
            id: j.str("id") ?? newSdkId()
        )
    }
}

/// What the store-review question answered: [ask] = open the store's own review box now.
public struct ReviewAnswer {
    public let ask: Bool
    /// off · asked_recently · too_new · too_few_sessions · no_event · recent_crash (when [ask] is false).
    public let reason: String
}

/// A link that opened a screen after a first install: open [link] as if it had been tapped. [likely] = matched by the
/// network within 2 hours.
public struct DeferredLink {
    public let code: String
    public let link: String
    public let likely: Bool
}

public extension DrSocialClient {
    /// Links the device to the company's own user. [identityHash] = hex HMAC-SHA256(server key secret, externalId), made on
    /// the company's server.
    @discardableResult
    func identify(_ externalId: String, identityHash: String? = nil, traits: [String: Any]? = nil, analytics: Bool? = nil,
                  messages: Bool? = nil, locale: String? = nil, country: String? = nil, profile: [String: String]? = nil) async throws -> String? {
        var body: [String: Any] = ["external_id": externalId]
        if let v = identityHash { body["identity_hash"] = v }
        if let v = traits { body["traits"] = v }
        if analytics != nil || messages != nil {
            var c: [String: Any] = [:]
            if let a = analytics { c["analytics"] = a }
            if let m = messages { c["messages"] = m }
            body["consent"] = c
        }
        if let v = locale { body["locale"] = v }
        if let v = country { body["country"] = v }
        if let v = profile { body["profile"] = v }
        return try ok(await authed("POST", "identify", body)).str("user")
    }

    func signOut() async throws {
        _ = try ok(await authed("POST", "sign-out", [String: Any]()))
    }

    /// Sends the events in batches of 100; answers how many were kept (0 while the person said no to analytics).
    @discardableResult
    func track(_ events: [SdkEvent]) async throws -> Int {
        var accepted = 0
        for part in events.chunked(100) {
            let res = try ok(await authed("POST", "track", ["events": part.map { $0.toMap() }]))
            accepted += res.num("accepted").map { Int($0) } ?? 0
        }
        return accepted
    }

    /// One live beat: open · screen · ping · close. Answers the seconds until the next ping, nil while live is off.
    func live(_ session: String, kind: String, screen: String? = nil) async throws -> Int? {
        var body: [String: Any] = ["session": session, "kind": kind, "app_version": appVersion]
        if let s = screen { body["screen"] = s }
        let res = try ok(await authed("POST", "live", body))
        if res.isTrue("disabled") { return nil }
        return res.num("ping").map { Int($0) } ?? 30
    }

    /// The installation's notification token: apns (hex) · fcm; permission granted · denied · provisional. False while push is off.
    @discardableResult
    func pushToken(provider: String, token: String, permission: String) async throws -> Bool {
        !(try ok(await authed("POST", "push-token", ["provider": provider, "token": token, "permission": permission])).isTrue("disabled"))
    }

    /// The person opened a notification ([push] = its `drs_push`), or pressed one of its buttons ([action]).
    func pushOpened(_ push: String, action: String? = nil) async throws {
        var body: [String: Any] = ["push": push]
        if let a = action { body["action"] = a }
        _ = try ok(await authed("POST", "push-opened", body))
    }

    /// What this installation should have inside the app now (in-app messages, inbox, surveys, tours).
    func messages() async throws -> [JsonObject] {
        try ok(await authed("GET", "messages")).arr("messages").objects()
    }

    /// shown · clicked · dismissed · answered · completed · read; a survey's [answer] is {question id: value}.
    func messageEvent(_ id: String, kind: String, answer: [String: Any]? = nil) async throws {
        var body: [String: Any] = ["kind": kind]
        if let a = answer { body["answer"] = a }
        _ = try ok(await authed("POST", "messages/\(id)/event", body))
    }

    /// Where the installation came from, once on the first open (iOS: the link that opened the app, when there is one).
    @discardableResult
    func attribution(referrer: String? = nil, link: String? = nil) async throws -> String? {
        if store.read("attributed") != nil { return nil }
        var body: [String: Any] = [:]
        if let r = referrer { body["referrer"] = r }
        if let l = link { body["link"] = l }
        let res = try ok(await authed("POST", "attribution", body))
        if res.isTrue("disabled") { return nil }
        store.write("attributed", "1")
        return res.str("network")
    }

    /// A link tapped before the app was installed, once on the very first open (iOS sends `{}`).
    func deferred(referrer: String? = nil) async throws -> DeferredLink? {
        if store.read("deferred") != nil { return nil }
        var body: [String: Any] = [:]
        if let r = referrer { body["referrer"] = r }
        let res = try ok(await authed("POST", "deferred", body))
        if res.isTrue("disabled") { return nil }
        store.write("deferred", "1")
        guard res.isTrue("matched") else { return nil }
        return DeferredLink(code: res.str("code") ?? "", link: res.str("link") ?? "", likely: res.str("by") == "network")
    }

    /// Whether to open the store's review box now; ask at a calm moment, never on launch or after an error.
    func review() async throws -> ReviewAnswer {
        let res = try ok(await authed("POST", "review", [String: Any]()))
        return ReviewAnswer(ask: res.isTrue("ask"), reason: res.str("reason") ?? (res.isTrue("disabled") ? "off" : ""))
    }

    /// The icons built into this release and the one shown now, on start.
    func reportIcons(available: [String], current: String) async throws {
        _ = try ok(await authed("POST", "icons", ["available": Array(available.prefix(10)), "current": current, "app_version": appVersion]))
    }

    /// Up to 20 crashes a call; answers how many were kept.
    @discardableResult
    func crashes(_ list: [SdkCrash]) async throws -> Int {
        var accepted = 0
        for part in list.chunked(20) {
            let res = try ok(await authed("POST", "crashes", ["crashes": part.map { $0.toMap() }]))
            accepted += res.num("accepted").map { Int($0) } ?? 0
        }
        return accepted
    }

    /// A Live Activity's token (hex): `start` = the type's push-to-start token (iOS 17.2+), `update` = a running activity's
    /// push token, `end` = the activity ended on the phone (no token). [type] = the ActivityAttributes' Swift type name.
    @discardableResult
    func liveActivity(kind: String, type: String, activity: String? = nil, token: String? = nil) async throws -> Bool {
        var body: [String: Any] = ["kind": kind, "type": type]
        if let a = activity { body["activity"] = a }
        if let t = token { body["token"] = t }
        return !(try ok(await authed("POST", "live-activity", body)).isTrue("disabled"))
    }

    /// The company's own site with the device id added (`drs_d=<device id>`), so a stopped phone is refused there too.
    func siteUrl(_ url: String) -> String {
        guard let device = deviceId else { return url }
        let param = config.siteBanParam
        let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts[0])
        let tail = parts.count > 1 ? "#" + parts[1] : ""
        let sep = head.contains("?") ? "&" : "?"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return head + sep + param + "=" + (device.addingPercentEncoding(withAllowedCharacters: allowed) ?? device) + tail
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// Bytes as lower-case hex (an APNs or Live Activity token).
public func hexString(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
