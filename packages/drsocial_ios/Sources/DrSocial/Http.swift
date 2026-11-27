import CryptoKit
import Foundation
import Security

/// One answer: status, headers (lower-case names) and the body exactly as received (the config's signature covers it).
public struct SdkResponse {
    public let status: Int
    public let body: String
    public let headers: [String: String]

    public init(status: Int, body: String, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    public var json: JsonObject { Json.parseObject(body) }
}

/// The SDK's only way out. Throws on no network.
public protocol SdkHttp: AnyObject {
    func send(_ method: String, _ url: String, body: String?, headers: [String: String]) async throws -> SdkResponse
}

/// URLSession with no cookie, no cache and nothing but what the SDK writes. When the config gives SPKI SHA-256 pins
/// ("sha256/<base64>"), every call but the config itself must meet a chain holding one of them; the signed config is read
/// unpinned, so a wrong pin can never lock an app out of the config that fixes it.
public final class URLSessionHttp: NSObject, SdkHttp, URLSessionDelegate, URLSessionTaskDelegate {
    private let timeout: TimeInterval
    private let pins: () -> [String]
    private var session: URLSession!

    public init(timeout: TimeInterval = 15, pins: @escaping () -> [String] = { [] }) {
        self.timeout = timeout
        self.pins = pins
        super.init()
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    public func send(_ method: String, _ url: String, body: String?, headers: [String: String]) async throws -> SdkResponse {
        guard let u = URL(string: url) else { throw SdkFailure(code: "bad_url") }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body = body {
            r.httpBody = Data(body.utf8)
            r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        }
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: r) { d, resp, err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume(returning: (d ?? Data(), resp!)) }
            }.resume()
        }
        let http = response as? HTTPURLResponse
        var h: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { h[String(describing: k).lowercased()] = String(describing: v) }
        return SdkResponse(status: http?.statusCode ?? 0, body: String(decoding: data, as: UTF8.self), headers: h)
    }

    /// No redirect is followed.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let wanted = pins()
        let path = task.originalRequest?.url?.path ?? ""
        if wanted.isEmpty || path.hasSuffix("/config") {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let seen = Self.chainPins(trust)
        if seen.contains(where: wanted.contains) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// "sha256/<base64>" of a certificate's SubjectPublicKeyInfo.
    public static func pinOf(spki: Data) -> String {
        "sha256/" + Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    static func chainPins(_ trust: SecTrust) -> [String] {
        var out: [String] = []
        let certs: [SecCertificate]
        if #available(iOS 15.0, macOS 12.0, *) {
            certs = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        } else {
            certs = (0..<SecTrustGetCertificateCount(trust)).compactMap { SecTrustGetCertificateAtIndex(trust, $0) }
        }
        for cert in certs {
            guard let key = SecCertificateCopyKey(cert),
                  let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
                  let attrs = SecKeyCopyAttributes(key) as? [CFString: Any] else { continue }
            let type = attrs[kSecAttrKeyType] as? String ?? ""
            let bits = attrs[kSecAttrKeySizeInBits] as? Int ?? 0
            guard let header = spkiHeader(type: type, bits: bits) else { continue }
            out.append(pinOf(spki: header + raw))
        }
        return out
    }

    /// The ASN.1 prefix that turns a raw key (what Security gives) into its SubjectPublicKeyInfo.
    static func spkiHeader(type: String, bits: Int) -> Data? {
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch bits {
            case 256: return Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])
            case 384: return Data([0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00])
            default: return nil
            }
        }
        if type == (kSecAttrKeyTypeRSA as String) {
            switch bits {
            case 2048: return Data([0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00])
            case 4096: return Data([0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00])
            default: return nil
            }
        }
        return nil
    }
}
