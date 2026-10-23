import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio

    public var title: String {
        switch self {
        case .image: "照片"
        case .video: "视频"
        case .audio: "音频"
        }
    }
}

public struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let kind: MediaKind
    public let name: String
    public let mime: String
    public let size: Int64
    /// 修改时间（秒）。和 id 一起唯一确定一张缩略图。
    public let modified: Int64
    /// 加入相册的时间（秒），用来按日期分组
    public let added: Int64?
    public let width: Int?
    public let height: Int?
    /// 毫秒
    public let duration: Int64?

    public var cacheKey: String { "\(kind.rawValue)_\(id)_\(modified)" }
}

public struct MediaPage: Codable, Sendable {
    public let total: Int
    /// 手机媒体库的「代数」：有任何增删改就会变（旧版手机 / 模拟手机没有）
    public let generation: Int64?
    public let items: [MediaItem]
}

public struct PairResult: Codable, Sendable {
    public let token: String
    public let deviceId: String
    public let name: String
}

public struct DeviceInfo: Codable, Sendable {
    public let deviceId: String
    public let name: String
    public let model: String
    public let android: String
    public let battery: Int?
    public let charging: Bool?
}

public struct PhoneNotification: Codable, Sendable {
    public let key: String
    public let pkg: String
    public let app: String
    public let title: String
    public let text: String
    public let time: Int64
}

public enum PhoneEvent: Sendable {
    case hello(DeviceInfo)
    case screenshot(MediaItem)
    /// 手机上多了一张新照片（不是截图）
    case media(MediaItem)
    case notification(PhoneNotification)
    case clipboard(String)
    /// 手机上从分享菜单「发送到 Mac」的文件
    case shared([SharedFile])
    case unknown(String)
}

/// 手机分享过来、等 Mac 去取的文件（GET /api/shared?id=）
public struct SharedFile: Codable, Sendable {
    public let id: String
    public let name: String
    public let mime: String
    public let size: Int64
}

public enum PhoneError: Error, LocalizedError {
    case http(Int)
    case unauthorized
    case badPairingCode
    case badAddress(String)
    case streamEnded
    case timeout

    public var errorDescription: String? {
        switch self {
        case .http(let code): "手机返回错误 \(code)"
        case .unauthorized: "配对已失效，请重新配对"
        case .badPairingCode: "配对码不对"
        case .badAddress(let s): "地址格式不对：\(s)"
        case .streamEnded: "连接被手机关闭"
        case .timeout: "连接超时"
        }
    }
}
