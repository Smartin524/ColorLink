import CryptoKit
import Foundation
import Network

public struct Knock: Sendable {
    public let deviceId: String
    public let endpoint: PhoneEndpoint
}

/// 接收手机的“敲门”UDP 包：手机醒来或换网络时发来，收到就立刻去连，不用等重试计时。
///
/// 包内容 `{"v":1,"id","port","ts","sig"}`，sig = HMAC-SHA256(令牌, "id|port|ts")。
/// 只信任签名正确、时间在 5 分钟以内的包；IP 取 UDP 包的来源地址，不信任包里写的。
public final class KnockListener: @unchecked Sendable {
    public static let port: UInt16 = 8766

    private let queue = DispatchQueue(label: "colorlink.knock")
    private var listener: NWListener?

    /// 根据设备 ID 查配对令牌（在内部队列上调用）
    public var tokenFor: ((String) -> String?)?
    /// 验证通过后回调（在内部队列上调用）
    public var onKnock: ((Knock) -> Void)?

    public init() {}

    public func start() {
        queue.async { self.startLocked() }
    }

    private func startLocked() {
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] conn in self?.receive(on: conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.queue.asyncAfter(deadline: .now() + 5) { self?.startLocked() }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            queue.asyncAfter(deadline: .now() + 5) { self.startLocked() }
        }
    }

    private func receive(on conn: NWConnection) {
        conn.start(queue: queue)
        conn.receiveMessage { [weak self] data, _, _, _ in
            defer { conn.cancel() }
            guard let self, let data, case let .hostPort(host, _) = conn.endpoint else { return }
            if let knock = Self.verify(data, from: hostString(host), tokenFor: self.tokenFor ?? { _ in nil }) {
                self.onKnock?(knock)
            }
        }
    }

    public static func verify(_ data: Data, from host: String, tokenFor: (String) -> String?, now: Date = Date()) -> Knock? {
        struct Payload: Decodable {
            let v: Int
            let id: String
            let port: Int
            let ts: Int64
            let sig: String
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data), p.v == 1,
              abs(Int64(now.timeIntervalSince1970) - p.ts) < 300,
              let token = tokenFor(p.id),
              sign(token: token, message: "\(p.id)|\(p.port)|\(p.ts)") == p.sig.lowercased()
        else { return nil }
        return Knock(deviceId: p.id, endpoint: PhoneEndpoint(host: host, port: p.port))
    }

    public static func sign(token: String, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(token.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

func hostString(_ host: NWEndpoint.Host) -> String {
    let h: String
    switch host {
    case .ipv4(let a): h = "\(a)"
    case .ipv6(let a): h = "\(a)"
    case .name(let n, _): h = n
    @unknown default: h = "\(host)"
    }
    return String(h.split(separator: "%").first ?? Substring(h))
}
