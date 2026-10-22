import AppKit
import AVKit
import SwiftUI

@main
struct ColorLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // 界面全部由 AppKit 管理（状态栏面板、相册窗口等），这里只需要一个空场景
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var link: LinkController!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        link = LinkController()
        Windows.shared.link = link
        statusBar = StatusBarController(link: link)

        // 调试用：带 --show-panel / --show-drop 启动时自动打开面板，方便截图核对界面
        let args = CommandLine.arguments
        if args.contains("--show-panel") || args.contains("--show-drop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [statusBar] in
                statusBar?.show(dropMode: args.contains("--show-drop"))
            }
        }
    }
}

/// 相册、配对、视频播放窗口。用 AppKit 创建，状态栏面板里可以直接打开。
@MainActor
final class Windows {
    static let shared = Windows()
    var link: LinkController!

    private var gallery: NSWindow?
    private var pair: NSWindow?

    func showGallery() {
        gallery = show(gallery, title: "手机相册", size: NSSize(width: 900, height: 640), resizable: true) {
            GalleryView().environmentObject(self.link)
        }
    }

    func showPair() {
        pair = show(pair, title: "配对手机", size: NSSize(width: 420, height: 300), resizable: false) {
            PairView().environmentObject(self.link)
        }
    }

    func closePair() {
        pair?.close()
    }

    func openPlayer(_ url: URL) {
        _ = show(nil, title: "视频", size: NSSize(width: 720, height: 460), resizable: true) {
            VideoPlayer(player: AVPlayer(url: url))
        }
    }

    private func show<V: View>(
        _ existing: NSWindow?, title: String, size: NSSize, resizable: Bool, content: () -> V
    ) -> NSWindow {
        if let w = existing {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return w
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: content())
        if !resizable { w.setContentSize(w.contentViewController!.view.fittingSize) }
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return w
    }
}
