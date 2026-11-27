import CryptoKit
import Foundation
import Security

/// Where the SDK keeps its few values between runs (the last config, the device id, its epoch, flags).
public protocol SdkStore: AnyObject {
    func read(_ name: String) -> String?
    func write(_ name: String, _ value: String?)
}

public final class MemorySdkStore: SdkStore {
    public private(set) var values: [String: String] = [:]
    private let lock = NSLock()
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func read(_ name: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[name] }
    public func write(_ name: String, _ value: String?) { lock.lock(); defer { lock.unlock() }; values[name] = value }
}

/// The device's own P-256 key, made and kept by the platform (the Secure Enclave, or the Keychain); it never leaves the
/// device. The core only asks for the public half and a signature.
public protocol DeviceSigner: AnyObject {
    /// Base64 DER SubjectPublicKeyInfo.
    func publicKey() async throws -> String
    /// Base64 DER ECDSA-SHA256 over [message].
    func sign(_ message: Data) async throws -> String
}

/// A store proof made for a nonce (App Attest: `{kind: app_attest, token, key_id}`); nil when none can be made.
public typealias AttestationMaker = (_ nonce: String) async -> [String: String]?
/// App Attest: base64 of `generateAssertion(keyId, clientDataHash: SHA256(message))` with the key that passed; nil = none.
public typealias AssertionMaker = (_ message: Data) async -> String?
/// DeviceCheck: base64 of a fresh `DCDevice.current.generateToken`; nil when none can be made.
public typealias DeviceCheckMaker = () async -> String?

/// The phone (or its person) is stopped by the company: show a full-screen block with [message] and stop; ask the config
/// again only on the next start.
public struct SdkBanned: Error, LocalizedError {
    /// The company's words to show ('' = the SDK's own short default).
    public let message: String
    /// When the stop ends; nil = until the company lifts it.
    public let until: Date?
    public var errorDescription: String? { message }
}

public struct SdkFailure: Error, CustomStringConvertible {
    public let code: String
    public let status: Int
    public init(code: String, status: Int = 0) { self.code = code; self.status = status }
    public var description: String { "SdkFailure(\(code), \(status))" }
}

/// Speaks API v1 for one store build: the signed config, the device's registration and its short token.
public actor DrSocialClient {
    /// The build's public key (32 hex), from Settings → Mobile app.
    public nonisolated let buildKey: String
    public nonisolated let installId: String
    /// The platform's Ed25519 public keys this release trusts, {"v1": base64}. Empty = the config is not checked.
    public nonisolated let trustedKeys: [String: String]
    public nonisolated let base: String
    public nonisolated let store: SdkStore
    public nonisolated let os: String
    public nonisolated let appVersion: String
    /// The phone's own id that survives deleting the app (a random id kept in the Keychain); only its hash is kept.
    public nonisolated let hardwareId: String?
    let http: SdkHttp
    private let now: () -> Date

    public private(set) var config: SdkConfig = .empty
    /// When [config] was last read from the platform (its `ttl` counts from here).
    public private(set) var configAt: Date?

    private var signer: DeviceSigner?
    private var attest: AttestationMaker?
    private var assertion: AssertionMaker?
    private var deviceCheck: DeviceCheckMaker?
    private var token: String?
    private var tokenUntil = Date(timeIntervalSince1970: 0)
    private var pendingToken: Task<String, Error>?

    public init(buildKey: String, installId: String, trustedKeys: [String: String],
                base: String = "https://social.drscroll.com/api/v1", http: SdkHttp? = nil,
                store: SdkStore = MemorySdkStore(), os: String = "", appVersion: String = "", hardwareId: String? = nil,
                now: @escaping () -> Date = Date.init) {
        self.buildKey = buildKey
        self.installId = installId
        self.trustedKeys = trustedKeys
        self.base = base
        self.store = store
        self.os = os
        self.appVersion = appVersion
        self.hardwareId = hardwareId
        self.now = now
        if let http = http {
            self.http = http
        } else {
            let box = PinBox()
            self.http = URLSessionHttp(pins: { box.pins })
            self.pinBox = box
        }
    }

    private var pinBox: PinBox?

    /// The device's key and the store proofs every call after [refresh] uses ([authed]).
    public func use(_ signer: DeviceSigner, attest: AttestationMaker? = nil, assertion: AssertionMaker? = nil,
                    deviceCheck: DeviceCheckMaker? = nil) {
        self.signer = signer
        self.attest = attest
        self.assertion = assertion
        self.deviceCheck = deviceCheck
    }

    /// Whether the config is older than its `ttl` (or was never read this run).
    public var configStale: Bool {
        guard let at = configAt else { return true }
        return now().timeIntervalSince(at) >= Double(config.ttlSeconds)
    }

    /// Reads the config again only when its `ttl` has passed.
    public func refreshIfStale() async throws -> SdkConfig {
        if configStale { return try await refresh() }
        return config
    }

    /// Reads the config. A signature that does not check, or no network, keeps the last good answer; an unknown key turns
    /// everything off and forgets it.
    @discardableResult
    public func refresh() async throws -> SdkConfig {
        if config.raw.isEmpty, let kept = store.read("config") { setConfig(SdkConfig.parse(kept)) }
        let res: SdkResponse
        do {
            res = try await http.send("GET", "\(base)/sdk/\(buildKey)/config", body: nil,
                                      headers: token.map { ["authorization": "Bearer \($0)"] } ?? [:])
        } catch {
            return config
        }
        try banned(res)
        if res.status == 404 {
            setConfig(.empty)
            configAt = now()
            store.write("config", nil)
            return config
        }
        guard res.status == 200, verify(res.body, header: res.headers["x-drs-signature"]) else { return config }
        setConfig(SdkConfig.parse(res.body))
        configAt = now()
        store.write("config", res.body)
        return config
    }

    private func setConfig(_ c: SdkConfig) {
        config = c
        pinBox?.pins = c.pins
    }

    /// Whether [body] carries a good signature from a trusted key (`v1:<base64>`).
    public nonisolated func verify(_ body: String, header: String?) -> Bool {
        if trustedKeys.isEmpty { return true }
        guard let header = header, let i = header.firstIndex(of: ":"), i > header.startIndex else { return false }
        guard let key = trustedKeys[String(header[..<i])], let keyData = Data(base64Encoded: key),
              let sig = Data(base64Encoded: String(header[header.index(after: i)...])),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return pub.isValidSignature(sig, for: Data(body.utf8))
    }

    /// The device id the platform gave this installation, once registered.
    public nonisolated var deviceId: String? { store.read("device") }

    /// Registers the device (again when the key generation moved), with a store proof when [attest] is given.
    public func register(_ signer: DeviceSigner, attest: AttestationMaker? = nil) async throws -> String {
        let kept = store.read("device")
        let keptEpoch = Int(store.read("epoch") ?? "") ?? 0
        if let kept = kept, keptEpoch >= config.epoch { return kept }
        var body: [String: Any] = ["install_id": installId, "public_key": try await signer.publicKey(), "os": os, "app_version": appVersion]
        if let hw = hardwareId { body["hardware_id"] = hw }
        if let dc = await deviceCheck?() { body["device_check_token"] = dc }
        if let attest = attest {
            let c = try await http.send("GET", "\(base)/sdk/\(buildKey)/challenge", body: nil, headers: [:])
            try banned(c)
            if let nonce = c.json.str("nonce") {
                body["nonce"] = nonce
                if let proof = await attest(nonce) { body["attestation"] = proof }
            }
        }
        let res = try await http.send("POST", "\(base)/sdk/\(buildKey)/devices", body: Json.encode(body), headers: [:])
        try banned(res)
        guard res.status == 201 else { throw SdkFailure(code: res.json.str("error") ?? "register_failed", status: res.status) }
        guard let id = res.json.str("device_id") else { throw SdkFailure(code: "register_failed", status: res.status) }
        store.write("device", id)
        store.write("epoch", String(res.json.num("epoch").map { Int($0) } ?? 1))
        return id
    }

    /// A short token for the calls, asked again a minute before it ends. On `re_register` the device registers again once.
    /// Calls made at the same time share one request.
    public func token(_ signer: DeviceSigner, attest: AttestationMaker? = nil, assertion: AssertionMaker? = nil) async throws -> String {
        if let t = token, now() < tokenUntil.addingTimeInterval(-60) { return t }
        if let p = pendingToken { return try await p.value }
        let task = Task { try await self.fetchToken(signer, attest: attest, assertion: assertion ?? self.assertion) }
        pendingToken = task
        defer { pendingToken = nil }
        return try await task.value
    }

    private func fetchToken(_ signer: DeviceSigner, attest: AttestationMaker?, assertion: AssertionMaker?) async throws -> String {
        let t = now()
        for attempt in 0..<2 {
            let device = try await register(signer, attest: attest)
            let time = String(Int(t.timeIntervalSince1970))
            let nonce = DrSocialClient.randomHex(16)
            let message = Data(DrSocialClient.tokenMessage(key: buildKey, device: device, time: time, nonce: nonce).utf8)
            var body: [String: Any] = ["device_id": device, "time": time, "nonce": nonce, "signature": try await signer.sign(message)]
            if let a = await assertion?(message) { body["assertion"] = a }
            if let dc = await deviceCheck?() { body["device_check_token"] = dc }
            let res = try await http.send("POST", "\(base)/sdk/\(buildKey)/token", body: Json.encode(body), headers: [:])
            try banned(res)
            if res.status == 200 {
                guard let tok = res.json.str("token") else { throw SdkFailure(code: "token_failed", status: res.status) }
                token = tok
                tokenUntil = t.addingTimeInterval(res.json.num("expires_in") ?? 900)
                return tok
            }
            if res.json.str("error") == "re_register" && attempt == 0 {
                store.write("device", nil)
                continue
            }
            throw SdkFailure(code: res.json.str("error") ?? "token_failed", status: res.status)
        }
        throw SdkFailure(code: "token_failed")
    }

    /// A call made with the device's token ([use] first). A token that ended or a device the platform no longer knows is
    /// fixed once (a new token, or registering again); a stopped phone throws [SdkBanned].
    public func authed(_ method: String, _ path: String, _ body: Any? = nil) async throws -> SdkResponse {
        guard let signer = signer else { throw SdkFailure(code: "no_signer") }
        for attempt in 0..<2 {
            let t = try await token(signer, attest: attest)
            let res = try await http.send(method, "\(base)/sdk/\(buildKey)/\(path)", body: body.map { Json.encode($0) },
                                          headers: ["authorization": "Bearer \(t)"])
            try banned(res)
            let error = res.json.str("error")
            if res.status == 401 && attempt == 0 && (error == "token_required" || error == "re_register") {
                token = nil
                if error == "re_register" { store.write("device", nil) }
                continue
            }
            return res
        }
        throw SdkFailure(code: "token_failed")
    }

    private func banned(_ res: SdkResponse) throws {
        guard res.status == 403, res.json.str("error") == "device_banned" else { return }
        token = nil
        throw SdkBanned(message: res.json.str("message") ?? "", until: parseTime(res.json.str("until")))
    }

    func ok(_ res: SdkResponse) throws -> JsonObject {
        if (200...299).contains(res.status) { return res.json }
        throw SdkFailure(code: res.json.str("error") ?? "http_\(res.status)", status: res.status)
    }

    /// What the device signs to get a token (API.md): `drs-token\n{key}\n{device}\n{time}\n{nonce}`.
    public static func tokenMessage(key: String, device: String, time: String, nonce: String) -> String {
        "drs-token\n\(key)\n\(device)\n\(time)\n\(nonce)"
    }

    static func randomHex(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &b) != errSecSuccess {
            for i in 0..<bytes { b[i] = UInt8.random(in: 0...255) }
        }
        return b.map { String(format: "%02x", $0) }.joined()
    }
}

/// The config's pins, read by the HTTP layer on its own queue.
final class PinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    var pins: [String] {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
