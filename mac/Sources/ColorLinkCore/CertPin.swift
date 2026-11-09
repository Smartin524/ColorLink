import CryptoKit
import Foundation
import Security

/// 手机的 HTTPS 证书是它自己签的，系统不认。这里不看证书链和主机名，只比对证书的 SHA-256 指纹：
/// - 配对时（还没有指纹）：谁都接受，记下看到的指纹，和令牌一起存起来；
/// - 之后：只接受这一张，对不上就断开，令牌不会发出去。
public final class CertPin: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let expected: String?
    private var _seen: String?
    private var _mismatch = false

    public init(_ expected: String?) {
        self.expected = expected
    }

    /// 最近一次握手看到的证书指纹
    public var seen: String? { lock.withLock { _seen } }
    /// 是否遇到过对不上的证书（同一地址上换了设备，或有人冒充）
    public var mismatch: Bool { lock.withLock { _mismatch } }

    public func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let fp = Self.fingerprint(SecCertificateCopyData(leaf) as Data)
        let ok = expected == nil || expected == fp
        lock.withLock {
            _seen = fp
            if !ok { _mismatch = true }
        }
        if ok {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// bytes(for:) 这类请求把证书校验当作任务级的挑战发过来，不走上面那个
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    public static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
