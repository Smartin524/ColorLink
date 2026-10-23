import AppKit
import CoreBluetooth
import ServiceManagement
import UserNotifications

/// 开机自启（系统设置 → 通用 → 登录项）。第一次运行时默认打开，之后以用户在「⋯」菜单里的选择为准。
@MainActor
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 第一次运行时注册一次；用户之后关掉了就不再自作主张打开
    static func enableOnFirstRun() {
        AppLog.write("开机自启状态：\(enabled ? "已打开" : "未打开")（\(SMAppService.mainApp.status.rawValue)）")
        guard !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        set(true)
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            AppLog.write("开机自启：\(on ? "打开" : "关闭")，状态 \(SMAppService.mainApp.status.rawValue)")
        } catch {
            AppLog.write("开机自启设置失败：\(error)")
        }
        // 被系统拦下、需要用户在「登录项」里允许时，直接把那一页打开
        if on, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

/// 剪贴板。图片同时写 PNG 和 TIFF，微信、文档、Figma 等都能直接粘贴。
enum Clipboard {
    @discardableResult
    static func copyImage(at url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([item])
    }

    static func copyFiles(_ urls: [URL]) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects(urls as [NSURL])
    }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// macOS 原生通知。直接 `swift run`（没有 .app 包）时系统不允许发通知，自动跳过。
enum Notifier {
    private static let delegate = Delegate()

    static var available: Bool { Bundle.main.bundleIdentifier != nil && !LinkController.demo }

    static func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// reveal：点通知时在 Finder 里显示这些文件
    static func post(title: String, body: String, image: URL? = nil, reveal: [URL] = [], id: String = UUID().uuidString) {
        guard available else {
            print("[通知] \(title)：\(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !reveal.isEmpty { content.userInfo = ["reveal": reveal.map(\.path)] }
        if let image {
            // 附件会被系统移走，所以先复制一份
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + image.pathExtension)
            if (try? FileManager.default.copyItem(at: image, to: tmp)) != nil,
               let att = try? UNNotificationAttachment(identifier: "image", url: tmp) {
                content.attachments = [att]
            }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            if let paths = response.notification.request.content.userInfo["reveal"] as? [String] {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
            completionHandler()
        }
    }
}

/// 持续广播一个固定的蓝牙服务 UUID，手机靠近时据此被系统唤醒。数据不走蓝牙。
final class BLEBeacon: NSObject, CBPeripheralManagerDelegate {
    /// 与安卓端 BleWake.SERVICE_UUID 保持一致
    static let serviceUUID = CBUUID(string: "7A1C3F0E-5B2D-4E8A-9C61-3D4F2B8E9A10")

    private var manager: CBPeripheralManager?

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "ColorLink",
        ])
    }
}
