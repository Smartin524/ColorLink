import Foundation
import Network

/// 给 AVPlayer 用的本机转发。
///
/// AVPlayer 没法自定义证书校验，连不上手机自签名的 HTTPS。所以让它连 127.0.0.1 上的明文地址，
/// 这里再带着令牌、按固定的证书去手机分块取，视频照样能边下边播、随意拖动。
/// 只监听本机回环地址；每个地址带一段随机路径，本机别的程序猜不到。
public final class LocalRelay: @unchecked Sendable {
    public static let shared = LocalRelay()

    private let queue = DispatchQueue(label: "colorlink.relay")
    private var listener: NWListener?
    private var port: UInt16?
    private var waiting: [CheckedContinuation<UInt16, Error>] = []
    /// 路径 → 要取的文件；只留最近的几个
    private var routes: [(key: String, client: PhoneClient, item: MediaItem)] = []

    public func url(for item: MediaItem, client: PhoneClient) async throws -> URL {
        let port = try await start()
        let key = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        queue.sync {
            routes.append((key, client, item))
            if routes.count > 20 { routes.removeFirst(routes.count - 20) }
        }
        let ext = (item.name as NSString).pathExtension
        // 带上扩展名，AVPlayer 靠它判断格式
        return URL(string: "http://127.0.0.1:\(port)/\(key)\(ext.isEmpty ? "" : "." + ext)")!
    }

    private func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let port = self.port { return cont.resume(returning: port) }
                self.waiting.append(cont)
                guard self.listener == nil else { return }
                do {
                    let params = NWParameters.tcp
                    params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let l = try NWListener(using: params)
                    l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                    l.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                    self.listener = l
                    l.start(queue: self.queue)
                } catch {
                    self.fail(error)
                }
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let p = listener?.port?.rawValue else { return }
            port = p
            waiting.forEach { $0.resume(returning: p) }
            waiting = []
        case .failed(let e):
            fail(e)
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        listener?.cancel()
        listener = nil
        port = nil
        waiting.forEach { $0.resume(throwing: error) }
        waiting = []
    }

    // MARK: - 每个连接只处理一个请求，回完就关

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHead(conn, Data())
    }

    private func readHead(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return conn.cancel() }
            var buf = buffer
            if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil || buf.count > 64 * 1024 { conn.cancel() } else { self.readHead(conn, buf) }
                return
            }
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            Task { await self.serve(conn, head) }
        }
    }

    private func route(_ path: Substring) -> (PhoneClient, MediaItem)? {
        let key = path.dropFirst().prefix { $0 != "." }
        return queue.sync { routes.last { $0.key == key }.map { ($0.client, $0.item) } }
    }

    private func serve(_ conn: NWConnection, _ head: String) async {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD", let (client, item) = route(parts[1]) else {
            try? await send(conn, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return finish(conn)
        }
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        let total = item.size
        guard let (from, to, partial) = Self.parse(range, total: total) else {
            try? await send(conn, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return finish(conn)
        }
        var out = partial ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(from)-\(to)/\(total)\r\n" : "HTTP/1.1 200 OK\r\n"
        out += "Content-Type: \(item.mime)\r\nContent-Length: \(to - from + 1)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        // 分块向手机要（每块一个 Range 请求，连接复用），发这一块的同时取下一块。
        // 发不出去（播放器暂停）时也就不再往下取，不会把整个文件攒在内存里
        func fetch(_ pos: Int64) -> Task<Data, Error> {
            let size: Int64 = pos == from ? 1 << 20 : 4 << 20 // 第一块小一点，起播快
            return Task {
                let (data, resp) = try await client.rawRequest(item, range: "bytes=\(pos)-\(min(pos + size, to + 1) - 1)")
                guard resp.statusCode == 206 else { throw PhoneError.http(resp.statusCode) }
                return data
            }
        }
        var pending: Task<Data, Error>?
        do {
            try await send(conn, Data(out.utf8))
            if parts[0] == "GET" {
                var pos = from
                pending = fetch(pos)
                while let t = pending {
                    let chunk = try await t.value
                    guard !chunk.isEmpty else { break }
                    pos += Int64(chunk.count)
                    pending = pos <= to ? fetch(pos) : nil
                    try await send(conn, chunk)
                }
            }
        } catch {
            // 播放器拖动进度条时会直接关掉旧连接，正常
            pending?.cancel()
        }
        finish(conn)
    }

    /// 解析 `bytes=a-b` / `bytes=a-` / `bytes=-n`；没有 Range 时是整个文件。范围不合法返回 nil
    static func parse(_ range: String?, total: Int64) -> (Int64, Int64, partial: Bool)? {
        guard let range, range.hasPrefix("bytes="), !range.contains(",") else { return total > 0 ? (0, total - 1, false) : nil }
        let p = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 2 else { return nil }
        var from: Int64, to = total - 1
        if p[0].isEmpty {
            guard let n = Int64(p[1]), n > 0 else { return nil }
            from = max(0, total - n)
        } else {
            guard let a = Int64(p[0]) else { return nil }
            from = a
            if !p[1].isEmpty {
                guard let b = Int64(p[1]) else { return nil }
                to = min(b, total - 1)
            }
        }
        return from <= to ? (from, to, true) : nil
    }

    private func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func finish(_ conn: NWConnection) {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }
}
