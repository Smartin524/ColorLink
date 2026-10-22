import AppKit
import ColorLinkCore
import SwiftUI

/// 手机相册：照片 / 视频按日期分组成网格，录音是列表。
///
/// 交互：左键单击弹出操作菜单；⌘ 单击加选 / 取消，⇧ 单击连续选择；⌘A 全选，Esc 取消。
/// 选中多项时点其中一张，菜单作用于全部选中项。右键菜单同样可用。
struct GalleryView: View {
    @EnvironmentObject var link: LinkController

    @State private var kind: MediaKind = .image
    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var message: String?
    @State private var selection = Set<MediaItem.ID>()
    /// ⇧ 连续选择的起点
    @State private var anchor: MediaItem.ID?

    private let pageSize = 200

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("手机相册")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("类型", selection: $kind) {
                        ForEach(MediaKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .help("刷新")
                    .disabled(link.client == nil || loading)
                }
            }
            .task(id: "\(kind.rawValue)-\(link.connectionID)") { await reload() }
    }

    private var subtitle: String {
        if let message { return message }
        if !selection.isEmpty { return "已选 \(selection.count) 项" }
        guard total > 0 else { return link.client == nil ? "手机未连接" : "加载中…" }
        let unit = kind == .image ? "张" : "个"
        return items.count < total ? "\(items.count) / \(total) \(unit)" : "\(total) \(unit)"
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if link.client == nil {
            ContentUnavailableView("手机未连接", systemImage: "iphone.slash",
                                   description: Text("连上以后这里会自动刷新"))
        } else if items.isEmpty {
            if loading || total > 0 {
                ProgressView()
            } else {
                ContentUnavailableView("没有\(kind.title)", systemImage: kind == .audio ? "waveform" : "photo.on.rectangle")
            }
        } else if kind == .audio {
            audioList
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 4)],
                alignment: .leading,
                spacing: 4,
                pinnedViews: [.sectionHeaders]
            ) {
                ForEach(sections, id: \.title) { section in
                    Section {
                        ForEach(section.items) { item in
                            ThumbCell(item: item, selected: selection.contains(item.id))
                                .onTapGesture { click(item) }
                                .contextMenu { contextMenu(for: item) }
                                .onAppear { if item == items.last { Task { await loadMore() } } }
                        }
                    } header: {
                        Text(section.title)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .background(.bar)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            selection.removeAll()
            return .handled
        }
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(items.map(\.id))
            return .handled
        }
    }

    private var audioList: some View {
        // 录音用系统列表自带的多选：单击选中，⌘ / ⇧ 多选，双击播放，右键菜单
        List(selection: $selection) {
            ForEach(items) { item in
                AudioRow(item: item)
                    .tag(item.id)
                    .onAppear { if item == items.last { Task { await loadMore() } } }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: MediaItem.ID.self) { ids in
            menuButtons(for: items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            items.filter { ids.contains($0.id) }.prefix(5).forEach(open)
        }
    }

    // MARK: - 点击与选择

    private func click(_ item: MediaItem) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else if mods.contains(.shift), let a = anchor,
                  let i = items.firstIndex(where: { $0.id == a }),
                  let j = items.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(items[min(i, j)...max(i, j)].map(\.id))
        } else {
            // 普通单击：点在已选中的多项里，菜单作用于全部选中项；否则只选这一张
            if !selection.contains(item.id) { selection = [item.id] }
            anchor = item.id
            showMenu(for: targets(for: item))
        }
    }

    /// 右键、左键菜单作用的对象
    private func targets(for item: MediaItem) -> [MediaItem] {
        selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
    }

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        menuButtons(for: targets(for: item))
    }

    @ViewBuilder
    private func menuButtons(for targets: [MediaItem]) -> some View {
        ForEach(actions(for: targets), id: \.title) { a in
            Button(a.title, action: a.run)
        }
    }

    private struct Action {
        let title: String
        let run: () -> Void
    }

    private func actions(for targets: [MediaItem]) -> [Action] {
        guard !targets.isEmpty else { return [] }
        let n = targets.count
        let suffix = n == 1 ? "" : " \(n) 项"
        var list = [Action(title: n == 1 ? "打开" : "打开\(suffix)") { targets.prefix(10).forEach(open) }]
        list.append(Action(title: n == 1 && targets[0].kind == .image ? "复制图片" : "复制\(suffix)") {
            Task { _ = await link.copyToClipboard(targets) }
        })
        list.append(Action(title: "保存到「下载/ColorLink」") { save(targets, reveal: false) })
        list.append(Action(title: "保存并在 Finder 中显示") { save(targets, reveal: true) })
        return list
    }

    /// 左键菜单：在鼠标位置弹出原生菜单
    private func showMenu(for targets: [MediaItem]) {
        let menu = NSMenu()
        for a in actions(for: targets) {
            menu.addItem(ClosureMenuItem(title: a.title, action: a.run))
            if a.title.hasPrefix("复制") { menu.addItem(.separator()) }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - 按日期分组

    private struct DaySection {
        let title: String
        let items: [MediaItem]
    }

    private var sections: [DaySection] {
        let cal = Calendar.current
        var result: [DaySection] = []
        var currentKey: DateComponents?
        var bucket: [MediaItem] = []
        for item in items {
            let key = cal.dateComponents([.year, .month, .day], from: Self.date(item))
            if key != currentKey, !bucket.isEmpty {
                result.append(DaySection(title: Self.dayTitle(bucket[0]), items: bucket))
                bucket = []
            }
            currentKey = key
            bucket.append(item)
        }
        if !bucket.isEmpty { result.append(DaySection(title: Self.dayTitle(bucket[0]), items: bucket)) }
        return result
    }

    private static func date(_ item: MediaItem) -> Date {
        Date(timeIntervalSince1970: TimeInterval(item.added ?? item.modified))
    }

    private static func dayTitle(_ item: MediaItem) -> String {
        let date = date(item)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = sameYear ? "M月d日 EEEE" : "yyyy年M月d日"
        return f.string(from: date)
    }

    // MARK: - 数据

    private func reload() async {
        items = []
        total = 0
        selection.removeAll()
        anchor = nil
        await loadMore()
    }

    private func loadMore() async {
        guard let c = link.client, !loading, items.isEmpty || items.count < total else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await c.media(kind: kind, offset: items.count, limit: pageSize)
            total = page.total
            items += page.items
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - 操作

    private func open(_ item: MediaItem) {
        guard let c = link.client else { return }
        if item.kind == .video {
            // 视频直接用 Range 请求边下边播
            Windows.shared.openPlayer(c.fileURL(item))
            return
        }
        Task {
            do {
                NSWorkspace.shared.open(try await link.original(item))
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func save(_ targets: [MediaItem], reveal: Bool) {
        guard let c = link.client else { return }
        Task {
            var saved: [URL] = []
            for item in targets {
                do {
                    saved.append(try await c.download(item, to: AppDirs.downloads))
                } catch {
                    message = error.localizedDescription
                }
            }
            if reveal, !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
        }
    }
}

/// 用闭包响应的菜单项
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

struct ThumbCell: View {
    let item: MediaItem
    let selected: Bool
    @EnvironmentObject var link: LinkController
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Color.gray.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                // 悬停时底部渐变显示文件名；视频常显播放图标和时长
                if hovering || item.kind == .video {
                    HStack(spacing: 4) {
                        if item.kind == .video {
                            Image(systemName: "play.fill").font(.caption2)
                            if let d = item.duration { Text(formatDuration(d)).monospacedDigit() }
                        }
                        if hovering {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay {
                if selected { Color.accentColor.opacity(0.18) }
            }
            .overlay(alignment: .topTrailing) {
                // 选中时右上角打勾，和系统「照片」一致
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(item.name)
            .task(id: item.cacheKey) {
                guard let c = link.client, let cache = link.thumbs else { return }
                if let d = await cache.data(for: item, client: c) {
                    withAnimation(.easeIn(duration: 0.15)) { image = NSImage(data: d) }
                }
            }
    }
}

struct AudioRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(dateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = item.duration {
                Text(formatDuration(d)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var dateText: String {
        Date(timeIntervalSince1970: TimeInterval(item.added ?? item.modified))
            .formatted(date: .abbreviated, time: .shortened)
    }
}

func formatDuration(_ ms: Int64) -> String {
    let s = Int(ms / 1000)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
