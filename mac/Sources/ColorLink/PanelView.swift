import ColorLinkCore
import SwiftUI
import UniformTypeIdentifiers

/// 状态栏面板，只有两块：顶部的连接状态，下面的照片区。
/// 照片区显示最近三张照片（点一下复制原图），同时也是拖放区：把文件拖上来就发给手机。
/// 不常用的开关和操作收在右上角「⋯」菜单里。
struct PanelView: View {
    let close: () -> Void
    @EnvironmentObject var link: LinkController
    @EnvironmentObject var ui: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if link.isConnected {
                PhotoStrip()
            }
        }
        .padding(12)
        .frame(width: 256)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        // 玻璃的高光和阴影会画到形状外面，留一圈透明边距，不然会被窗口边缘裁掉
        .padding(FloatingPanel.margin)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: link.isConnected ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                .font(.body)
                .foregroundStyle(link.isConnected ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !ui.dropMode {
                if link.isConnected {
                    Button {
                        close()
                        Windows.shared.showGallery()
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("打开相册")
                }
                moreMenu
            }
        }
    }

    /// 「⋯」：和相册按钮同款的玻璃圆形按钮，点击弹出系统原生菜单
    /// （SwiftUI 的 Menu 会剥掉标签上的玻璃效果，所以不用它）
    private var moreMenu: some View {
        Button(action: showMoreMenu) {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .help("更多")
    }

    private func showMoreMenu() {
        let menu = NSMenu()
        func toggle(_ title: String, _ on: Bool, enabled: Bool = true, _ set: @escaping (Bool) -> Void) {
            let item = ClosureMenuItem(title: title) { set(!on) }
            item.state = on ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        toggle("截图自动复制到剪贴板", link.autoCopyScreenshots) { link.autoCopyScreenshots = $0 }
        toggle("同步短信", link.mirrorNotifications) { link.mirrorNotifications = $0 }
        toggle("短信验证码自动复制", link.autoCopyCodes, enabled: link.mirrorNotifications) { link.autoCopyCodes = $0 }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "配对手机…") { close(); Windows.shared.showPair() })
        if link.device != nil {
            menu.addItem(ClosureMenuItem(title: "取消配对") { link.forget() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "导出诊断日志") { close(); Task { await link.exportDiagnostics() } })
        menu.addItem(ClosureMenuItem(title: "退出 ColorLink") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private var title: String {
        switch link.state {
        case .searching: "正在寻找手机…"
        case .needsPairing(let n): "发现「\(n)」"
        case .connecting(let n): "正在连接「\(n)」"
        case .connected(let n): n
        case .retrying(let n, _): "「\(n)」已断开"
        }
    }

    private var subtitle: String {
        switch link.state {
        case .searching: return "请在手机上打开 ColorLink，并连接同一个 Wi-Fi"
        case .needsPairing: return "尚未配对，点右上角「⋯」→ 配对手机"
        case .connecting: return "马上就好"
        case .connected:
            guard let i = link.info, let b = i.battery else { return "已连接" }
            return "已连接 · \(b)%\(i.charging == true ? " · 充电中" : "")"
        case .retrying: return "自动重连中…"
        }
    }
}

/// 照片区：最近三张照片 + 拖放发送
struct PhotoStrip: View {
    @EnvironmentObject var link: LinkController
    @EnvironmentObject var ui: PanelState

    var body: some View {
        let target = ui.dropTargeted
        HStack(spacing: 6) {
            ForEach(link.recent) { RecentThumb(item: $0) }
            if link.recent.isEmpty {
                Color.clear.frame(maxWidth: .infinity, minHeight: 72)
            }
        }
        .padding(5)
        .opacity(ui.dropMode || target ? 0.35 : 1)
        .overlay {
            // 拖拽时在照片上盖一层提示；松手即发送
            if ui.dropMode || target || link.transfer != nil {
                VStack(spacing: 4) {
                    Image(systemName: link.transfer == nil ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .symbolEffect(.pulse, isActive: link.transfer != nil)
                    Text(link.transfer ?? (target ? "松手发送到手机" : "拖到这里，发送到手机"))
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(target ? Color.accentColor : .primary)
                .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(target ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(target ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
        .animation(.easeOut(duration: 0.15), value: target)
        .onDrop(of: [.fileURL, .image], isTargeted: $ui.dropTargeted) { providers in
            Task { await link.send(await DropFiles.urls(from: providers)) }
            return true
        }
    }
}

/// 一张最近照片：悬停显示“复制”，点一下下载原图并放进剪贴板
struct RecentThumb: View {
    let item: MediaItem
    @EnvironmentObject var link: LinkController
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var state: CopyState = .idle

    enum CopyState { case idle, copying, copied, failed }

    var body: some View {
        Button {
            Task {
                state = .copying
                state = await link.copyToClipboard(item) ? .copied : .failed
                try? await Task.sleep(for: .seconds(1.2))
                state = .idle
            }
        } label: {
            Color.gray.opacity(0.15)
                .frame(width: 72, height: 72)
                .overlay {
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                }
                .overlay {
                    switch state {
                    case .idle where hovering: badge("复制", "doc.on.doc")
                    case .idle: EmptyView()
                    case .copying: badge(nil, nil)
                    case .copied: badge("已复制", "checkmark.circle.fill")
                    case .failed: badge("失败", "xmark.circle.fill")
                    }
                }
                // 外框 22、内边距 12 + 5，缩略图圆角取 8，和外框保持同心
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.name)
        .task(id: item.cacheKey) {
            guard let c = link.client, let cache = link.thumbs else { return }
            if let d = await cache.data(for: item, client: c) { image = NSImage(data: d) }
        }
    }

    private func badge(_ text: String?, _ icon: String?) -> some View {
        VStack(spacing: 2) {
            if let icon { Image(systemName: icon).font(.callout) } else { ProgressView().controlSize(.small) }
            if let text { Text(text).font(.caption2.weight(.semibold)) }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.4))
    }
}

enum DropFiles {
    /// 取出拖进来的文件；从浏览器等地方拖来的只有图片数据，先存成临时 PNG
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            } else if p.canLoadObject(ofClass: NSImage.self),
                      let image = await loadImage(p),
                      let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mac 图片 \(stamp).png")
                if (try? png.write(to: url)) != nil { urls.append(url) }
            }
        }
        return urls
    }

    private static func loadImage(_ p: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in cont.resume(returning: obj as? NSImage) }
        }
    }
}
