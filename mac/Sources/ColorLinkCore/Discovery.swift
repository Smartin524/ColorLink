import Foundation
import Network
import SystemConfiguration

public struct DiscoveredPhone: Hashable, Sendable {
    public let name: String
    public let deviceId: String?
    public let endpoint: NWEndpoint
}

/// 用 Bonjour 持续寻找局域网里的 `_colorlink._tcp` 服务。
public final class PhoneBrowser: @unchecked Sendable {
    public static let serviceType = "_colorlink._tcp"

    private let queue = DispatchQueue(label: "colorlink.browser")
    private var browser: NWBrowser?

    /// 在内部队列上回调。
    public var onChange: (([DiscoveredPhone]) -> Void)?

    public init() {}

    public func start() {
        queue.async { self.startLocked() }
    }

    public func stop() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
        }
    }

    private func startLocked() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let phones = results.compactMap { r -> DiscoveredPhone? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var id: String?
                if case let .bonjour(txt) = r.metadata { id = txt["id"] }
                return DiscoveredPhone(name: name, deviceId: id, endpoint: r.endpoint)
            }
            self?.onChange?(phones)
        }
        b.stateUpdateHandler = { [weak self] state in
            // 网络切换等情况下浏览器会失败，过几秒重开
            if case .failed = state {
                self?.queue.asyncAfter(deadline: .now() + 3) { self?.startLocked() }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    /// Mac 当前的默认网关。连着手机热点时，网关就是手机本身。
    public static func defaultGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "ColorLink" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return dict["Router"] as? String
    }

    /// 把 Bonjour 服务解析成 IPv4 地址和端口（URLSession 需要具体地址）。
    public static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 5) async throws -> PhoneEndpoint {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4 // 避开带网卡后缀的 IPv6 链路本地地址
        }
        let conn = NWConnection(to: endpoint, using: params)
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        let h = hostString(host)
                        once.run { cont.resume(returning: PhoneEndpoint(host: h, port: Int(port.rawValue))) }
                    } else {
                        once.run { cont.resume(throwing: PhoneError.timeout) }
                    }
                    conn.cancel()
                case .failed(let e), .waiting(let e):
                    once.run { cont.resume(throwing: e) }
                    conn.cancel()
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { cont.resume(throwing: PhoneError.timeout) }
                conn.cancel()
            }
        }
    }
}

final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ f: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}
