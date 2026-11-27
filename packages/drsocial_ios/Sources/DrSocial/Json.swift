import Foundation

/// A JSON object as Foundation reads it (`JSONSerialization`): values are String, NSNumber, Bool, [Any], [String: Any] or NSNull.
public typealias JsonObject = [String: Any]

enum Json {
    /// Plain Swift values (dictionaries, arrays, text, numbers, true/false, nil) as JSON text, the way the platform reads them.
    static func encode(_ value: Any?) -> String {
        let clean = normalize(value)
        guard JSONSerialization.isValidJSONObject(clean),
              let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Text into an object; an empty object when it is not one.
    static func parseObject(_ text: String) -> JsonObject {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let obj = any as? JsonObject
        else { return [:] }
        return obj
    }

    static func parseAny(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Whether a Foundation value is a JSON true/false (NSNumber made from a Bool), not a number.
    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func normalize(_ value: Any?) -> Any {
        switch value {
        case nil: return NSNull()
        case let v as NSNull: return v
        case let v as String: return v
        // Bool, Int, Double… all bridge to NSNumber, and a Bool's NSNumber stays a JSON true/false.
        case let v as NSNumber: return v
        case let v as Date: return SdkTime.format(v)
        case let v as [String: Any?]: return v.mapValues { normalize($0) }
        case let v as [String: Any]: return v.mapValues { normalize($0) }
        case let v as [Any?]: return v.map { normalize($0) }
        case let v as [Any]: return v.map { normalize($0) }
        default: return String(describing: value!)
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func obj(_ key: String) -> JsonObject { self[key] as? JsonObject ?? [:] }
    func arr(_ key: String) -> [Any] { self[key] as? [Any] ?? [] }
    /// A string only when the value is JSON text (a number is not a string).
    func str(_ key: String) -> String? { self[key] as? String }
    func num(_ key: String) -> Double? {
        guard let n = self[key] as? NSNumber, !Json.isBool(n) else { return nil }
        return n.doubleValue
    }
    func bool(_ key: String) -> Bool? {
        guard let n = self[key] as? NSNumber, Json.isBool(n) else { return nil }
        return n.boolValue
    }
    func isTrue(_ key: String) -> Bool { bool(key) == true }
}

extension Array where Element == Any {
    func strings() -> [String] { compactMap { $0 as? String } }
    func objects() -> [JsonObject] { compactMap { $0 as? JsonObject } }
}

/// Times as the platform writes and reads them (ISO 8601, UTC).
public enum SdkTime {
    private static func formatter(_ fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    public static func format(_ date: Date) -> String { formatter(false).string(from: date) }

    /// Reads an ISO time as the platform writes it ("2026-12-01T00:00:00Z", "…+00:00", with or without fractions); nil when it is not one.
    public static func parse(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return formatter(false).date(from: s) ?? formatter(true).date(from: s)
    }
}

/// Reads an ISO time as the platform writes it; nil when it is not one (the Kotlin and Dart `parseTime`).
public func parseTime(_ s: String?) -> Date? { SdkTime.parse(s) }
