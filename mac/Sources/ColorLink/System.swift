import AppKit
import CoreBluetooth
import UserNotifications

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

    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, image: URL? = nil, id: String = UUID().uuidString) {
        guard available else {
            print("[通知] \(title)：\(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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
