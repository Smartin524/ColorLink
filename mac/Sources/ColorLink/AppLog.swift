import Foundation
import os

/// 日志：同时写系统日志和 ~/Library/Logs/ColorLink/colorlink.log（超过 1 MB 轮换，最多占 2 MB）。
/// 系统日志的 info 级别默认不保存，事后排查要靠文件。「⋯」菜单里的「导出诊断日志」会把它和手机日志一起导出。
enum AppLog {
    static let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/ColorLink")
    private static let file = dir.appendingPathComponent("colorlink.log")
    private static let queue = DispatchQueue(label: "colorlink.log")
    private static let os = Logger(subsystem: "com.colorlink.mac", category: "link")
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        os.info("\(message, privacy: .public)")
        let line = "\(time.string(from: Date())) \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            if size > 1 << 20 {
                let old = dir.appendingPathComponent("colorlink.1.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: file, to: old)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    /// 旧的在前、新的在后
    static func dump() -> String {
        queue.sync {
            ["colorlink.1.log", "colorlink.log"]
                .compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
                .joined()
        }
    }
}
