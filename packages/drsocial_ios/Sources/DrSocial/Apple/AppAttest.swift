import CryptoKit
import DeviceCheck
import Foundation

/// Apple's App Attest (iOS 14+, a real device; never the simulator) and DeviceCheck for the registration and the token.
/// Needs the App Attest capability (`com.apple.developer.devicecheck.appattest-environment`) in the app's entitlements.
public final class AppAttest {
    private let account = "app_attest_key"
    private let attestedAccount = "app_attest_ok"

    public init() {}

    /// Whether this phone can make an App Attest proof.
    public var isSupported: Bool {
        if #available(iOS 14.0, macOS 11.0, *) { return DCAppAttestService.shared.isSupported }
        return false
    }

    /// The registration's proof: a new App Attest key attested over `SHA256(nonce)` →
    /// `{kind: app_attest, token: base64 attestation, key_id: base64 key id}`; nil when the phone cannot.
    public func attestation(nonce: String) async -> [String: String]? {
        guard #available(iOS 14.0, macOS 11.0, *), isSupported else { return nil }
        let service = DCAppAttestService.shared
        do {
            // A key can be attested only once: every registration makes a new one.
            let keyId = try await service.generateKey()
            let hash = Data(SHA256.hash(data: Data(nonce.utf8)))
            let object = try await service.attestKey(keyId, clientDataHash: hash)
            Keychain.write(account, Data(keyId.utf8))
            Keychain.write(attestedAccount, Data("1".utf8))
            return ["kind": "app_attest", "token": object.base64EncodedString(), "key_id": keyId]
        } catch {
            return nil
        }
    }

    /// The token's assertion over `SHA256(message)` with the key that was attested; nil when there is none.
    public func assertion(message: Data) async -> String? {
        guard #available(iOS 14.0, macOS 11.0, *), isSupported,
              Keychain.read(attestedAccount) != nil,
              let k = Keychain.read(account), let keyId = String(data: k, encoding: .utf8) else { return nil }
        do {
            let hash = Data(SHA256.hash(data: message))
            return try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: hash).base64EncodedString()
        } catch {
            // The key is no longer valid (restored backup, reinstall): the next registration makes a new one.
            Keychain.write(attestedAccount, nil)
            return nil
        }
    }

    public var attestationMaker: AttestationMaker { { [self] nonce in await self.attestation(nonce: nonce) } }
    public var assertionMaker: AssertionMaker { { [self] message in await self.assertion(message: message) } }
}

public enum DeviceCheckToken {
    /// A fresh `DCDevice.current.generateToken` as base64; nil when the phone cannot make one (the simulator).
    public static func make() async -> String? {
        guard DCDevice.current.isSupported else { return nil }
        return await withCheckedContinuation { cont in
            DCDevice.current.generateToken { data, _ in cont.resume(returning: data?.base64EncodedString()) }
        }
    }

    public static var maker: DeviceCheckMaker { { await make() } }
}
