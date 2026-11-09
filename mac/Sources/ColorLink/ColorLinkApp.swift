import AppKit
import AVKit
import Quartz
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
        AppLog.write("ColorLink 启动")
        link = LinkController()
        Windows.shared.link = link
        statusBar = StatusBarController(link: link)
        if !LinkController.demo { LoginItem.enableOnFirstRun() }

        // 调试用：带 --show-panel / --show-drop / --show-gallery 启动时自动打开对应界面，方便截图核对
        let args = CommandLine.arguments
        if args.contains("--show-gallery") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Windows.shared.showGallery() }
        }
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
        gallery = show(gallery, title: "手机相册", size: NSSize(width: 960, height: 680), resizable: true,
                       minSize: NSSize(width: 720, height: 520), autosave: "ColorLinkGallery") {
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
        _ existing: NSWindow?, title: String, size: NSSize, resizable: Bool,
        minSize: NSSize? = nil, autosave: String? = nil, content: () -> V
    ) -> NSWindow {
        if let w = existing {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return w
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable {
            // 内容铺到标题栏下面，工具栏和红绿灯浮在内容上（macOS 26 液态玻璃的标准窗口形态）
            style.formUnion([.resizable, .fullSizeContentView])
        }
        let w = PreviewWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: content())
        // 可调大小的窗口不要让 SwiftUI 按内容的最小尺寸去压窗口（相册曾因此缩成一条）
        if resizable { host.sizingOptions = [] }
        // 让 SwiftUI 的 .toolbar / .navigationSubtitle 变成原生窗口工具栏和副标题
        host.sceneBridgingOptions = [.toolbars, .title]
        w.toolbarStyle = .unified
        w.contentViewController = host
        if resizable {
            w.setContentSize(size)
            if let minSize { w.contentMinSize = minSize }
        } else {
            w.setContentSize(host.view.fittingSize)
        }
        w.center()
        if let autosave { w.setFrameAutosaveName(autosave) } // 记住上次的大小和位置
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return w
    }
}

/// The gallery window supplies Quick Look control through the responder chain.
@MainActor
private final class PreviewWindow: NSWindow {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        HoldPreview.shared.active
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        HoldPreview.shared.takeControl(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        HoldPreview.shared.relinquishControl(panel)
    }

}
