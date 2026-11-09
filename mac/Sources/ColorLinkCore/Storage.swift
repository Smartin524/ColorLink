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

    /// 这台手机在本机长期保存的数据（相册列表、缩略图）。放在「应用程序支持」而不是「缓存」：缓存可能被系统清掉
    public static func library(_ deviceId: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ColorLink/\(deviceId)")
    }

    /// 用户保存的照片、截图和接收文件直接放在「文稿/Colorlink」。
    public static var downloads: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Colorlink", isDirectory: true)
    }
}

/// 缩略图两级缓存：内存 + 磁盘。同一张图同时被请求多次时只发一次网络请求。
public actor ThumbnailCache {
    private let dir: URL
    private let memory = NSCache<NSString, NSData>()
    private var inflight: [String: Task<Data?, Never>] = [:]

    public init(deviceId: String) {
        dir = AppDirs.library(deviceId).appendingPathComponent("thumbs")
        // 旧版存在「缓存」里，搬过来，不用重新下载
        let old = AppDirs.caches.appendingPathComponent("thumbs/\(deviceId)")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 2000
    }

    /// 只读本机保存的（手机没连上时用）
    public nonisolated func stored(_ item: MediaItem) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(item.cacheKey + ".jpg"))
    }

    /// Quick Look can display the existing thumbnail file immediately, without copying it.
    public nonisolated func storedURL(_ item: MediaItem) -> URL? {
        let url = dir.appendingPathComponent(item.cacheKey + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 本机是否已经存了这张缩略图
    public nonisolated func has(_ item: MediaItem) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(item.cacheKey + ".jpg").path)
    }

    /// 后台补齐用：只存到磁盘，不占内存缓存。返回是否成功
    public nonisolated func prefetch(_ item: MediaItem, client: PhoneClient) async -> Bool {
        let file = dir.appendingPathComponent(item.cacheKey + ".jpg")
        if FileManager.default.fileExists(atPath: file.path) { return true }
        guard let d = try? await client.thumbnail(item) else { return false }
        return (try? d.write(to: file, options: .atomic)) != nil
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
