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
    /// 加入当前手机媒体库的时间（秒），用于增量同步，不代表拍摄日期。
    public let added: Int64?
    /// 原始拍摄时间（秒），来自手机的图片 / 视频元数据。
    public private(set) var taken: Int64?

    /// Apply locally recovered EXIF without changing server snapshots used by incremental sync.
    public func recoveringCaptureDate(_ timestamp: Int64?) -> MediaItem {
        guard (taken ?? 0) <= 0, let timestamp, timestamp > 0 else { return self }
        var copy = self
        copy.taken = timestamp
        return copy
    }

    public var capturedDate: Date {
        let candidates: [Int64?] = [taken, modified, added]
        let timestamp: Int64 = candidates.compactMap { $0 }.first(where: { $0 > 0 }) ?? 0
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
    public let width: Int?
    public let height: Int?
    /// 毫秒
    public let duration: Int64?

    public var cacheKey: String { "\(kind.rawValue)_\(id)_\(modified)" }
}

public struct MediaPage: Codable, Sendable {
    /// 协议元数据变化也需要刷新旧列表，即使手机媒体库代数没有改变。
    public let metadataVersion: Int?
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
    /// 电量和充电状态随手机的 power 事件更新
    public var battery: Int?
    public var charging: Bool?
    /// 免打扰档位（见 DndMode）；nil 表示手机没开通知使用权，改不了
    public var dnd: String?
}

/// 手机的免打扰档位，和安卓的中断过滤一一对应
public enum DndMode: String, Codable, Sendable, CaseIterable {
    case all, priority, alarms
    /// 协议里叫 none；Swift 里不叫 none，免得和 Optional.none 混
    case silent = "none"

    public var title: String {
        switch self {
        case .all: "关"
        case .priority: "仅优先"
        case .alarms: "仅闹钟"
        case .silent: "完全静音"
        }
    }

    /// 是否算“开着免打扰”
    public var isOn: Bool { self != .all }
}

public struct PhoneNotification: Codable, Sendable {
    public let key: String
    public let pkg: String
    public let app: String
    /// 来自短信 App；Mac 只在短信里找验证码（旧版手机不带这个字段，按短信处理）
    public let sms: Bool?
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
    /// 手机插上 / 拔掉电源。后台补缩略图只在充电时做，靠它开始和停下，不去问手机
    case power(charging: Bool, battery: Int?)
    /// 免打扰档位变了（手机上手动改的，或 Mac 改完系统回调）
    case dnd(DndMode)
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
