import Foundation
import Security

/// The few secrets the SDK keeps in the Keychain (this device only, after the first unlock): the device key, the App
/// Attest key id and the hardware id that survives deleting the app.
enum Keychain {
    static let service = "com.drsocial.sdk"

    static func read(_ account: String) -> Data? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(_ account: String, _ data: Data?) -> Bool {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
        guard let data = data else { return true }
        var add = q
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// The SDK's plain values (the last config, the device id, its epoch, flags) in their own UserDefaults suite: removed with
/// the app, as an installation's values should be.
public final class UserDefaultsSdkStore: SdkStore {
    private let defaults: UserDefaults

    public init(suite: String = "com.drsocial.sdk") {
        defaults = UserDefaults(suiteName: suite) ?? .standard
    }

    public func read(_ name: String) -> String? { defaults.string(forKey: "drs." + name) }

    public func write(_ name: String, _ value: String?) {
        if let v = value { defaults.set(v, forKey: "drs." + name) } else { defaults.removeObject(forKey: "drs." + name) }
    }
}

public enum DeviceIds {
    /// The installation's own id: made on the first run and removed with the app.
    public static func installId(_ store: SdkStore) -> String {
        if let id = store.read("install_id") { return id }
        let id = UUID().uuidString.lowercased()
        store.write("install_id", id)
        return id
    }

    /// The phone's own id that survives deleting the app (API.md: a random id kept in the Keychain,
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Falls back to [vendorId] when the Keychain refuses.
    public static func hardwareId(vendorId: String? = nil) -> String? {
        if let d = Keychain.read("hardware_id"), let s = String(data: d, encoding: .utf8) { return s }
        let id = DrSocialClient.randomHex(16)
        if Keychain.write("hardware_id", Data(id.utf8)) { return id }
        return vendorId?.lowercased()
    }
}
