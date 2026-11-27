import CryptoKit
import Foundation

/// The device's P-256 key: made in the Secure Enclave when the phone has one (the key never leaves it; only an encrypted
/// handle is kept in the Keychain), otherwise a CryptoKit key kept in the Keychain (this device only).
public final class SecureEnclaveSigner: DeviceSigner {
    private enum Key {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private let key: Key
    /// Whether the key lives in the Secure Enclave.
    public let inSecureEnclave: Bool

    /// Loads the key kept under [account], or makes one.
    public init(account: String = "device_key") throws {
        if let data = Keychain.read(account + ".se"), let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            key = .enclave(k)
            inSecureEnclave = true
            return
        }
        if let data = Keychain.read(account + ".sw"), let k = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            key = .software(k)
            inSecureEnclave = false
            return
        }
        if SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey(),
           Keychain.write(account + ".se", k.dataRepresentation) {
            key = .enclave(k)
            inSecureEnclave = true
            return
        }
        let k = P256.Signing.PrivateKey()
        guard Keychain.write(account + ".sw", k.rawRepresentation) else { throw SdkFailure(code: "keychain") }
        key = .software(k)
        inSecureEnclave = false
    }

    /// A signer over a key the caller holds (tests).
    public init(software: P256.Signing.PrivateKey) {
        key = .software(software)
        inSecureEnclave = false
    }

    /// Forgets the key (the device registers again with a new one).
    public static func reset(account: String = "device_key") {
        Keychain.write(account + ".se", nil)
        Keychain.write(account + ".sw", nil)
    }

    public func publicKey() async throws -> String {
        switch key {
        case .enclave(let k): return k.publicKey.derRepresentation.base64EncodedString()
        case .software(let k): return k.publicKey.derRepresentation.base64EncodedString()
        }
    }

    public func sign(_ message: Data) async throws -> String {
        switch key {
        case .enclave(let k): return try k.signature(for: message).derRepresentation.base64EncodedString()
        case .software(let k): return try k.signature(for: message).derRepresentation.base64EncodedString()
        }
    }
}
