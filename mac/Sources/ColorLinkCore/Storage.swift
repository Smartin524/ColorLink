import Foundation

public struct PairedPhone: Codable, Hashable, Sendable {
    public var deviceId: String
    public var name: String
    public var token: String
    public var lastEndpoint: PhoneEndpoint?

    public init(deviceId: String, name: String, token: String, lastEndpoint: PhoneEndpoint?) {
        self.deviceId = deviceId
        self.name = name
        self.token = token
        self.lastEndpoint = lastEndpoint
    }
}

/// 已配对的手机。雏形阶段存在 UserDefaults 里，正式版应改存钥匙串。
public enum PairedStore {
    private static let key = "pairedPhones"

    public static func all() -> [PairedPhone] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PairedPhone].self, from: data)) ?? []
    }

    public static func save(_ phone: PairedPhone) {
        var list = all().filter { $0.deviceId != phone.deviceId }
        list.insert(phone, at: 0)
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }

    public static func remove(_ deviceId: String) {
        let list = all().filter { $0.deviceId != deviceId }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
}

public enum AppDirs {
    public static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ColorLink")
    }

    /// 截图、保存的文件放在「下载/ColorLink」，方便在 Finder 里找到。
    /// 「图片/ColorLink」：面板里点“下载”存到这里
    public static var pictures: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("ColorLink")
    }

    public static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("ColorLink")
    }
}

/// 缩略图两级缓存：内存 + 磁盘。同一张图同时被请求多次时只发一次网络请求。
public actor ThumbnailCache {
    private let dir: URL
    private let memory = NSCache<NSString, NSData>()
    private var inflight: [String: Task<Data?, Never>] = [:]

    public init(deviceId: String) {
        dir = AppDirs.caches.appendingPathComponent("thumbs/\(deviceId)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 2000
    }

    public func data(for item: MediaItem, client: PhoneClient) async -> Data? {
        let key = item.cacheKey
        if let d = memory.object(forKey: key as NSString) { return d as Data }
        if let t = inflight[key] { return await t.value }

        let file = dir.appendingPathComponent(key + ".jpg")
        let task = Task.detached(priority: .userInitiated) { () -> Data? in
            if let d = try? Data(contentsOf: file) { return d }
            guard let d = try? await client.thumbnail(item) else { return nil }
            try? d.write(to: file, options: .atomic)
            return d
        }
        inflight[key] = task
        let d = await task.value
        inflight[key] = nil
        if let d { memory.setObject(d as NSData, forKey: key as NSString) }
        return d
    }

    public func clearDisk() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }
}
