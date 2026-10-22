import ColorLinkCore
import SwiftUI
import UniformTypeIdentifiers

/// 状态栏面板，只有两块：顶部的连接状态，下面的照片区（最近三张，悬停：上半下载、下半复制）。
/// 拖文件时整个面板都是放置区，松手就发给手机。
/// 不常用的开关和操作收在右上角「⋯」菜单里。
struct PanelView: View {
    let close: () -> Void
    @EnvironmentObject var link: LinkController
    @EnvironmentObject var ui: PanelState

    var body: some View {
        let dropping = ui.dropMode || ui.dropTargeted || link.transfer != nil
        VStack(alignment: .leading, spacing: 8) {
            header
            if link.isConnected {
                PhotoStrip()
            }
        }
        .padding(12)
        .opacity(dropping ? 0.2 : 1)
        .overlay { if dropping { dropOverlay } }
        .animation(.easeOut(duration: 0.15), value: dropping)
        .animation(.easeOut(duration: 0.15), value: ui.dropTargeted)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .image], isTargeted: $ui.dropTargeted) { providers in
            // 松手的这一刻拖拽剪贴板里就是这次拖的东西，先同步读出文件
            let files = DragContent.files(NSPasteboard(name: .drag))
            Task {
                let urls = files.isEmpty ? await DragContent.imageFiles(from: providers) : files
                AppLog.write("拖入 \(providers.count) 项：\(files.isEmpty ? "图片数据 \(urls.count) 张" : "文件 \(files.count) 个")")
                await link.send(urls)
            }
            return true
        }
        .frame(width: 256)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        // 玻璃的高光和阴影会画到形状外面，留一圈透明边距，不然会被窗口边缘裁掉
        .padding(FloatingPanel.margin)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 拖拽时盖满整个面板的提示；松手即发送
    private var dropOverlay: some View {
        let target = ui.dropTargeted
        return VStack(spacing: 4) {
            Image(systemName: link.transfer == nil ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 24))
                .symbolEffect(.pulse, isActive: link.transfer != nil)
            Text(link.transfer ?? (target ? "松手发送到手机" : "拖到这里，发送到手机"))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(target ? Color.accentColor : .primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(target ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(target ? Color.accentColor : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .padding(6)
        .allowsHitTesting(false)
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
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 22, height: 22)
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
                .font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 22)
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
        toggle("开机自启", LoginItem.enabled) { LoginItem.set($0) }
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

/// 照片区：最近三张照片
struct PhotoStrip: View {
    @EnvironmentObject var link: LinkController

    var body: some View {
        HStack(spacing: 6) {
            ForEach(link.recent) { RecentThumb(item: $0) }
            if link.recent.isEmpty {
                Color.clear.frame(maxWidth: .infinity, minHeight: 72)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.primary.opacity(0.04)))
    }
}

/// 已经下载到这台 Mac 的照片：左上角一个小对勾
struct DownloadedMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.45))
            .shadow(color: .black.opacity(0.3), radius: 1)
            .padding(4)
            .help("已下载到这台 Mac")
    }
}

/// 一张最近照片：悬停时上半是“下载”（存到「图片/ColorLink」），下半是“复制”（原图放进剪贴板）
struct RecentThumb: View {
    let item: MediaItem
    @EnvironmentObject var link: LinkController
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var state: ActionState = .idle

    enum ActionState: Equatable { case idle, working, done(String), failed }

    var body: some View {
        Color.gray.opacity(0.15)
            .frame(width: 72, height: 72)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .overlay(alignment: .topLeading) {
                if link.isDownloaded(item) { DownloadedMark(size: 12) }
            }
            .overlay {
                switch state {
                case .idle where hovering:
                    VStack(spacing: 0) {
                        half("下载", "arrow.down.circle") { await link.saveToPictures(item) ? "已存" : nil }
                        Rectangle().fill(.white.opacity(0.25)).frame(height: 0.5)
                        half("复制", "doc.on.doc") { await link.copyToClipboard(item) ? "已复制" : nil }
                    }
                case .idle: EmptyView()
                case .working: badge(nil, nil)
                case .done(let text): badge(text, "checkmark.circle.fill")
                case .failed: badge("失败", "xmark.circle.fill")
                }
            }
            // 外框 22、内边距 12 + 5，缩略图圆角取 8，和外框保持同心
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
            .help(item.name)
            .task(id: item.cacheKey) {
                guard let c = link.client, let cache = link.thumbs else { return }
                if let d = await cache.data(for: item, client: c) { image = NSImage(data: d) }
            }
    }

    /// 半边按钮：悬停的那半边颜色更深，提示点下去是哪个
    private func half(_ text: String, _ icon: String, action: @escaping () async -> String?) -> some View {
        HalfButton(text: text, icon: icon) {
            Task {
                state = .working
                state = await action().map { .done($0) } ?? .failed
                try? await Task.sleep(for: .seconds(1.2))
                state = .idle
            }
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

private struct HalfButton: View {
    let text: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.caption)
                Text(text).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(hovering ? 0.55 : 0.35))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

