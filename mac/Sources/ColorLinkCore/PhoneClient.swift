import Foundation
import UniformTypeIdentifiers

public struct PhoneEndpoint: Codable, Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// 接受 `192.168.1.5`、`192.168.1.5:8765`、`localhost:8765`。
    public init(parsing text: String, defaultPort: Int = 8765) throws {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { throw PhoneError.badAddress(text) }
        if let i = s.lastIndex(of: ":"), !s.contains("]"), s.filter({ $0 == ":" }).count == 1 {
            guard let p = Int(s[s.index(after: i)...]) else { throw PhoneError.badAddress(text) }
            self.init(host: String(s[..<i]), port: p)
        } else {
            self.init(host: s, port: defaultPort)
        }
    }

    public var baseURL: URL {
        let h = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(h):\(port)/")!
    }

    public var description: String { "\(host):\(port)" }
}

/// 手机端 HTTP 协议的客户端，协议见 PROTOCOL.md。
public final class PhoneClient: @unchecked Sendable {
    public let endpoint: PhoneEndpoint
    public let token: String
    /// 告诉手机这台电脑叫什么，显示在流体云里
    public let clientName: String
    private let session: URLSession
    private let eventSession: URLSession

    public init(endpoint: PhoneEndpoint, token: String, clientName: String = Host.current().localizedName ?? "Mac") {
        self.endpoint = endpoint
        self.token = token
        self.clientName = clientName

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 6 // 缩略图并发拉取
        cfg.timeoutIntervalForRequest = 15
        cfg.urlCache = nil // 缩略图有自己的磁盘缓存
        session = URLSession(configuration: cfg)

        let ev = URLSessionConfiguration.ephemeral
        // 断线由 events() 自己判断：手机深睡时 ping 会停，单靠超时会反复误判断线
        ev.timeoutIntervalForRequest = 7 * 24 * 3600
        ev.timeoutIntervalForResource = 7 * 24 * 3600
        eventSession = URLSession(configuration: ev)
    }

    deinit {
        session.invalidateAndCancel()
        eventSession.invalidateAndCancel()
    }

    // MARK: - 配对

    public static func pair(endpoint: PhoneEndpoint, code: String, clientName: String) async throws -> PairResult {
        var comps = URLComponents(url: endpoint.baseURL.appendingPathComponent("api/pair"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "client", value: clientName)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try JSONDecoder().decode(PairResult.self, from: data)
        case 403: throw PhoneError.badPairingCode
        case let code: throw PhoneError.http(code)
        }
    }

    /// 不带令牌问一下这个地址上是哪台手机；对不上（或根本不是 ColorLink）就返回 nil。
    /// 用来在发令牌之前确认身份，避免把令牌发给同一 IP 上的别的设备（换了网络、连了热点时会遇到）。
    public static func identify(_ endpoint: PhoneEndpoint, timeout: TimeInterval = 2) async -> String? {
        struct ID: Decodable { let deviceId: String }
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("api/id"))
        req.timeoutInterval = timeout
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(ID.self, from: data))?.deviceId
    }

    // MARK: - 普通接口

    func url(_ path: String, _ query: [String: String] = [:], withToken: Bool = false) -> URL {
        var comps = URLComponents(url: endpoint.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if withToken { items.append(URLQueryItem(name: "t", value: token)) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url!
    }

    func request(_ url: URL, timeout: TimeInterval? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let timeout { r.timeoutInterval = timeout }
        return r
    }

    private func get(_ path: String, _ query: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> Data {
        let (data, resp) = try await session.data(for: request(url(path, query), timeout: timeout))
        try Self.check(resp)
        return data
    }

    static func check(_ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw PhoneError.unauthorized }
        guard (200..<300).contains(code) else { throw PhoneError.http(code) }
    }

    public func info(timeout: TimeInterval = 5) async throws -> DeviceInfo {
        try JSONDecoder().decode(DeviceInfo.self, from: await get("api/info", timeout: timeout))
    }

    /// 手机端的日志文件（导出诊断日志用）
    public func logs() async throws -> String {
        String(decoding: try await get("api/logs", timeout: 10), as: UTF8.self)
    }

    public func media(kind: MediaKind, offset: Int, limit: Int = 200) async throws -> MediaPage {
        let data = try await get("api/media", ["kind": kind.rawValue, "offset": "\(offset)", "limit": "\(limit)"])
        return try JSONDecoder().decode(MediaPage.self, from: data)
    }

    public func thumbnail(_ item: MediaItem, size: Int = 256) async throws -> Data {
        try await get("api/thumb", ["kind": item.kind.rawValue, "id": "\(item.id)", "v": "\(item.modified)", "size": "\(size)"])
    }

    /// 带令牌的原文件地址，给 AVPlayer 这类没法加请求头的地方用。
    public func fileURL(_ item: MediaItem) -> URL {
        url("api/file", ["kind": item.kind.rawValue, "id": "\(item.id)"], withToken: true)
    }

    public struct TrashResult: Decodable, Sendable {
        public let trashed: Int
        /// 手机没有「媒体管理」权限时要用户在手机上点一下确认
        public let pending: Bool
    }

    /// 移到手机的「最近删除」（可以在手机上恢复）
    public func trash(_ items: [MediaItem]) async throws -> TrashResult {
        var req = request(url("api/trash"), timeout: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["items": items.map { ["kind": $0.kind.rawValue, "id": $0.id] }])
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(TrashResult.self, from: data)
    }

    /// 取手机分享过来的文件，存进 dir，重名时自动加序号
    public func download(_ file: SharedFile, to dir: URL) async throws -> URL {
        let req = request(url("api/shared", ["id": file.id]), timeout: 120)
        let (tmp, resp) = try await session.download(for: req)
        try Self.check(resp)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Self.uniqueURL(in: dir, name: file.name)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// 下载到指定目录，重名时自动加序号。
    public func download(_ item: MediaItem, to dir: URL) async throws -> URL {
        let req = request(url("api/file", ["kind": item.kind.rawValue, "id": "\(item.id)"]), timeout: 60)
        let (tmp, resp) = try await session.download(for: req)
        try Self.check(resp)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Self.uniqueURL(in: dir, name: item.name)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// 把文件发到手机。图片存进手机相册的 Pictures/ColorLink，其他文件存进 Download/ColorLink。
    @discardableResult
    /// batch：一次发送的多个文件共用一个批次号，手机收完最后一个（index == count - 1）才提示「已收到 N 个文件」
    public func upload(file: URL, name: String? = nil, batch: (id: String, index: Int, count: Int)? = nil) async throws -> MediaItem? {
        let fileName = name ?? file.lastPathComponent
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var query = ["name": fileName, "mime": mime]
        if let batch {
            query["batch"] = batch.id
            query["index"] = "\(batch.index)"
            query["count"] = "\(batch.count)"
        }
        var req = request(url("api/upload", query), timeout: 120)
        req.httpMethod = "POST"
        let (data, resp) = try await session.upload(for: req, fromFile: file)
        try Self.check(resp)
        return try? JSONDecoder().decode(MediaItem.self, from: data)
    }

    public func rawRequest(_ item: MediaItem, range: String) async throws -> (Data, HTTPURLResponse) {
        var req = request(url("api/file", ["kind": item.kind.rawValue, "id": "\(item.id)"]))
        req.setValue(range, forHTTPHeaderField: "Range")
        let (data, resp) = try await session.data(for: req)
        return (data, resp as! HTTPURLResponse)
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - 事件流

    /// 订阅手机事件（SSE）。连接断开时以错误结束，由调用方负责重连。
    ///
    /// 手机每 20 秒发一次 ping，但手机深睡时 CPU 停着，ping 会停上几分钟，连接其实还在。
    /// 所以流里安静超过 45 秒时，另开一个请求问一下手机：请求本身会把手机叫醒，
    /// 答上了就继续等（醒来后 ping 马上会到）；答不上、或答上了流里仍然没有动静，才判定断线。
    public func events() -> AsyncThrowingStream<PhoneEvent, Error> {
        let req = request(url("api/events", ["name": clientName]))
        let session = eventSession
        let lastActivity = ActivityClock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(for: req)
                    try Self.check(resp)
                    var name = "message"
                    for try await line in bytes.lines {
                        lastActivity.touch()
                        if line.hasPrefix(":") { continue } // ping
                        if line.hasPrefix("event:") {
                            name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            // 协议约定每个事件只有一行 data，所以读到 data 就可以直接派发，
                            // 不必依赖空行（AsyncLineSequence 不保证交出空行）
                            let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                            continuation.yield(Self.decode(name, payload))
                            name = "message"
                        }
                    }
                    continuation.finish(throwing: PhoneError.streamEnded)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watchdog = Task { [weak self] in
                var probedAt: Date?
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, !Task.isCancelled else { return }
                    let idle = Date().timeIntervalSince(lastActivity.last)
                    if idle < 45 { probedAt = nil; continue }
                    if let probedAt, Date().timeIntervalSince(probedAt) > 60 {
                        // 手机答得上，事件流却一直没动静：流已经断了（比如手机进程重启过）
                        continuation.finish(throwing: URLError(.timedOut))
                        return
                    }
                    guard probedAt == nil else { continue }
                    do {
                        _ = try await self.info(timeout: 10)
                        probedAt = Date()
                    } catch {
                        continuation.finish(throwing: URLError(.timedOut))
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                watchdog.cancel()
            }
        }
    }

    static func decode(_ name: String, _ data: Data) -> PhoneEvent {
        let d = JSONDecoder()
        switch name {
        case "hello":
            if let v = try? d.decode(DeviceInfo.self, from: data) { return .hello(v) }
        case "screenshot":
            if let v = try? d.decode(MediaItem.self, from: data) { return .screenshot(v) }
        case "media":
            if let v = try? d.decode(MediaItem.self, from: data) { return .media(v) }
        case "notification":
            if let v = try? d.decode(PhoneNotification.self, from: data) { return .notification(v) }
        case "clipboard":
            struct T: Decodable { let text: String }
            if let v = try? d.decode(T.self, from: data) { return .clipboard(v.text) }
        case "shared":
            struct T: Decodable { let items: [SharedFile] }
            if let v = try? d.decode(T.self, from: data) { return .shared(v.items) }
        default:
            break
        }
        return .unknown(name)
    }
}

/// 事件流最后一次收到数据的时间，读流的任务和看门的任务共用
private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var last: Date { lock.withLock { value } }
    func touch() { lock.withLock { value = Date() } }
}
