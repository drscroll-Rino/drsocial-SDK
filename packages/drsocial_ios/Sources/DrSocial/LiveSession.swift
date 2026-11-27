import Foundation

/// The live session's rule (API.md): a new session id each time the app comes to the front after 30 minutes away; the
/// same one when it comes back sooner.
public final class LiveSession {
    public private(set) var id: String = newSdkId()
    private let gap: TimeInterval
    private var leftAt: Date?
    private var started = false

    public init(gap: TimeInterval = 30 * 60) { self.gap = gap }

    /// The app came to the front: answers true when this starts a new session (send `open`), false when it goes on.
    public func front(_ now: Date) -> Bool {
        let left = leftAt
        leftAt = nil
        if !started {
            started = true
            return true
        }
        if let left = left, now.timeIntervalSince(left) >= gap {
            id = newSdkId()
            return true
        }
        return false
    }

    public func back(_ now: Date) { leftAt = now }
}

/// A screen name or route as the platform keeps it: no query, no fragment, ids become `{id}`.
public func screenName(_ route: String) -> String {
    let path = route.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
        let s = String(part)
        if !s.isEmpty && (s.allSatisfy { $0.isASCII && $0.isNumber } || s.range(of: "^[0-9a-fA-F-]{16,}$", options: .regularExpression) != nil) {
            return "{id}"
        }
        return s
    }
    return String(parts.joined(separator: "/").prefix(120))
}
