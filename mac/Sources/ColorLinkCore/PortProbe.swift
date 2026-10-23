import Foundation
import Network

/// 看手机上 ColorLink 的端口：通了、被拒绝（手机在线但 ColorLink 没在运行），还是根本连不到（手机不在这个网络）。
public enum PortProbe {
    public enum Result: Sendable { case open, refused, unreachable }

    public static func check(host: String, port: Int, timeout: TimeInterval = 3) async -> Result {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .unreachable }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        return await withCheckedContinuation { cont in
            let once = Once(conn, cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.finish(.open)
                case .waiting(let e), .failed(let e):
                    if case .posix(.ECONNREFUSED) = e { once.finish(.refused) } else if case .failed = state { once.finish(.unreachable) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(.unreachable) }
        }
    }

    /// 只回调一次，并关掉连接
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let conn: NWConnection
        private let cont: CheckedContinuation<Result, Never>

        init(_ conn: NWConnection, _ cont: CheckedContinuation<Result, Never>) {
            self.conn = conn
            self.cont = cont
        }

        func finish(_ r: Result) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            conn.cancel()
            cont.resume(returning: r)
        }
    }
}
