import AppKit
import Quartz

/// A temporary Quick Look session. Releasing Space invalidates even an unfinished download.
@MainActor
final class HoldPreview: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = HoldPreview()
    private(set) var active = false
    private var item: PreviewItem?
    private var transitionImage: NSImage?
    private var sourceFrame = NSRect.zero
    private var beganAt = ProcessInfo.processInfo.systemUptime
    private var request = UUID()
    private var loading: Task<Void, Never>?
    private var keyMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private weak var sourceWindow: NSWindow?
    private weak var panel: QLPreviewPanel?

    func begin(initialURL: URL?, title: String, transitionImage: NSImage?, sourceFrame: NSRect,
               original: @escaping @MainActor () async throws -> URL, onError: @escaping (String) -> Void) {
        guard !active else { return }
        active = true
        beganAt = ProcessInfo.processInfo.systemUptime
        item = nil
        self.transitionImage = transitionImage
        self.sourceFrame = sourceFrame
        sourceWindow = NSApp.keyWindow
        let id = UUID()
        request = id
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.active else { return event }
            if event.keyCode == 49 {
                if event.type == .keyUp { self.end() }
                return nil // Ignore key-repeat while held, including after Quick Look takes focus.
            }
            if event.keyCode == 53 { self.end(); return nil }
            return event
        }
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(restoreFocus: false) }
        }
        // Show the cached original or thumbnail before starting any network work.
        if let initialURL { present(initialURL, title: title) }
        guard active else { return }
        loading = Task {
            do {
                let url = try await original()
                guard !Task.isCancelled, active, request == id else { return }
                if item?.previewItemURL != url { present(url, title: title) }
            } catch {
                guard !Task.isCancelled, active, request == id else { return }
                // A missing/offline original should not dismiss an already visible thumbnail.
                if item == nil { end() }
                onError(error.localizedDescription)
            }
        }
    }

    private func present(_ url: URL, title: String) {
        item = PreviewItem(url: url, title: title)
        if let panel, panel.isVisible {
            panel.reloadData()
            return
        }
        guard let preview = QLPreviewPanel.shared() else { end(); return }
        preview.makeKeyAndOrderFront(nil)
        preview.updateController()
        guard panel === preview else {
            AppLog.write("快速预览未取得窗口控制权")
            end()
            return
        }
        preview.reloadData()
        AppLog.write("快速预览已显示：\(Int((ProcessInfo.processInfo.systemUptime - beganAt) * 1000)) ms")
    }

    func end(restoreFocus: Bool = true) {
        guard active else { return }
        active = false
        request = UUID()
        loading?.cancel()
        loading = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
        panel?.close()
        AppLog.write("快速预览已收起")
        // Retain the transition image and item until the native closing animation finishes.
        if restoreFocus { sourceWindow?.makeKey() }
        sourceWindow = nil
    }

    func takeControl(_ panel: QLPreviewPanel) {
        self.panel = panel
        panel.dataSource = self
        panel.delegate = self
    }

    func relinquishControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        self.panel = nil
        end(restoreFocus: false)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { item == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { item }
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        AppLog.write("快速预览缩放动画：\(Int(sourceFrame.width)) × \(Int(sourceFrame.height))")
        return sourceFrame
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        if let transitionImage { contentRect?.pointee = NSRect(origin: .zero, size: transitionImage.size) }
        return transitionImage
    }

    func windowWillClose(_ notification: Notification) { end() }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}
