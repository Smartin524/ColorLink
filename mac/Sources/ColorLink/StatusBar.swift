import AppKit
import ColorLinkCore
import Combine
import SwiftUI

/// 面板的界面状态
@MainActor
final class PanelState: ObservableObject {
    /// 拖拽模式：用户正在拖文件，面板自动弹出，只显示投放区
    @Published var dropMode = false
    /// 文件正悬停在投放区上
    @Published var dropTargeted = false
}

/// 状态栏图标 + 下拉面板。
///
/// 没用 SwiftUI 的 MenuBarExtra：它的面板没法由程序主动弹出，而“拖文件时自动弹出”需要这个能力。
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let link: LinkController
    private let ui = PanelState()
    private var panel: FloatingPanel!
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    /// 鼠标按下时拖拽剪贴板的计数；拖动中计数变了，说明有拖拽会话开始了
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var dragEndTimer: Timer?

    init(link: LinkController) {
        self.link = link
        super.init()

        panel = FloatingPanel(rootView: PanelView(close: { [weak self] in self?.hide() })
            .environmentObject(link)
            .environmentObject(ui))

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.toolTip = "ColorLink"
        }
        link.$state.combineLatest(link.$transfer)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateIcon() }
            .store(in: &cancellables)
        // 内容变了（例如最近照片加载出来）就重新计算面板大小
        link.objectWillChange.merge(with: ui.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.panel.fitToContent(anchor: self?.anchorRect) }
            .store(in: &cancellables)

        installMonitors()
        updateIcon()
    }

    private func updateIcon() {
        if link.transfer != nil {
            // 正在发文件时临时换成上传箭头
            item.button?.image = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: "正在发送")
        } else {
            item.button?.image = BrandIcon.statusImage(connected: link.isConnected)
        }
    }

    // MARK: - 显示 / 隐藏

    @objc private func togglePanel() {
        if panel.isVisible && !ui.dropMode {
            hide()
        } else {
            show(dropMode: false)
        }
    }

    private var anchorRect: NSRect? { item.button?.window?.frame }

    func show(dropMode: Bool) {
        ui.dropMode = dropMode
        panel.fitToContent(anchor: anchorRect)
        panel.orderFrontRegardless()
        if !dropMode {
            panel.makeKey()
            Task { await link.refreshRecent() }
            Task { await link.refreshInfo() }
        }
    }

    func hide() {
        dragEndTimer?.invalidate()
        panel.orderOut(nil)
        ui.dropMode = false
        ui.dropTargeted = false
    }

    // MARK: - 拖拽检测

    private func installMonitors() {
        let down: (NSEvent) -> Void = { [weak self] _ in
            self?.dragBaseline = NSPasteboard(name: .drag).changeCount
        }
        let outsideClick: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            down(event)
            // 点到别的 App 就收起（拖拽模式由拖拽结束负责收起）
            if self.panel.isVisible, !self.ui.dropMode,
               !(self.anchorRect?.contains(NSEvent.mouseLocation) ?? false) {
                self.hide()
            }
        }
        let dragged: (NSEvent) -> Void = { [weak self] _ in self?.checkDragStarted() }

        // 全局监听只读取鼠标事件，不需要辅助功能权限
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: outsideClick) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: dragged) { monitors.append(m) }
        // 从本 App 自己的窗口（例如相册）往外拖时，事件不走全局监听
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { down($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged, handler: { dragged($0); return $0 }) { monitors.append(m) }
    }

    private func checkDragStarted() {
        guard !ui.dropMode, link.isConnected else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragBaseline else { return }
        dragBaseline = pb.changeCount
        guard DragContent.hasSendableContent(pb) else { return }
        AppLog.write("检测到拖拽文件，弹出面板")
        show(dropMode: true)
        // 鼠标松开（拖拽结束）时收起；正在发送就等发完
        dragEndTimer?.invalidate()
        dragEndTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                guard NSEvent.pressedMouseButtons & 1 == 0, self.link.transfer == nil else { return }
                timer.invalidate()
                self.hide()
            }
        }
    }
}

/// 不抢焦点的浮动面板，挂在状态栏图标下方
final class FloatingPanel: NSPanel {
    /// 内容四周的透明边距（PanelView 里也用到）
    static let margin: CGFloat = 16
    private let hosting: NSHostingView<AnyView>

    init<V: View>(rootView: V) {
        hosting = NSHostingView(rootView: AnyView(rootView))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // 阴影由液态玻璃自己画；窗口阴影是矩形的，会和圆角打架
        hidesOnDeactivate = false
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    /// 按内容调整大小，并放在锚点（状态栏图标）正下方
    func fitToContent(anchor: NSRect?) {
        let size = hosting.fittingSize
        var frame = NSRect(origin: self.frame.origin, size: size)
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let m = Self.margin
            frame.origin.x = min(max(anchor.midX - size.width / 2, visible.minX - m + 8), visible.maxX - size.width + m - 8)
            frame.origin.y = anchor.minY - size.height + m - 6
        }
        setFrame(frame, display: true)
    }
}
