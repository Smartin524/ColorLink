import AppKit
import ColorLinkCore
import SwiftUI

/// 手机相册：照片 / 视频按日期分组成网格，音频是列表。
///
/// 交互：单击选中，双击打开，指针悬停时按住空格快速预览；⌘ 单击加选 / 取消，⇧ 单击连续选择；拖动框选；点空白处、Esc 取消；⌘A 全选。
/// 选中多项时右键点其中一张，菜单作用于全部选中项。
struct GalleryView: View {
    @EnvironmentObject var link: LinkController

    @FocusState private var gridFocused: Bool
    @State private var kind: MediaKind = .image
    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var message: String?
    @State private var selection = Set<MediaItem.ID>()
    /// ⇧ 连续选择的起点
    @State private var anchor: MediaItem.ID?
    /// 框选：各缩略图在网格里的位置、当前选框、开始框选前已有的选择
    /// 位置只在框选时读，放进不触发刷新的盒子：滚动时每帧都会更新，存在 @State 里会让整个相册每帧重算
    @State private var frameStore = FrameStore()
    /// 按日期分好的组，只在列表变化时重算（不在每次刷新界面时重算）
    @State private var sections: [DaySection] = []
    @State private var band: CGRect?
    @State private var bandBase = Set<MediaItem.ID>()

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            .navigationTitle(link.info?.name ?? link.device?.name ?? "手机")
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
                        Task { await sync() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .help("刷新")
                    .disabled(link.client == nil || syncing)
                }
            }
            .task(id: "\(kind.rawValue)-\(link.connectionID)") { await reload() }
            .onDisappear { HoldPreview.shared.end() }
            // 本机副本有变化（核对完、第一次同步边拉边显示）时刷新
            .onReceive(link.$library.compactMap { $0?.$lists }.switchToLatest()) { show($0[kind]) }
    }

    private var subtitle: String {
        if let message { return message }
        if !selection.isEmpty { return "已选 \(selection.count) 项" }
        guard total > 0 else { return link.client == nil ? "手机未连接" : "加载中…" }
        let unit = kind == .image ? "张" : "个"
        if link.client == nil { return "\(total) \(unit) · 手机未连接，显示的是本机保存的" }
        // 第一次同步还在拉
        return items.count < total ? "正在同步 \(items.count) / \(total) \(unit)" : "\(total) \(unit)"
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if link.client == nil && items.isEmpty {
            ContentUnavailableView("手机未连接", systemImage: "iphone.slash",
                                   description: Text("连上以后这里会自动刷新"))
        } else if items.isEmpty {
            if syncing || total > 0 {
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
        GeometryReader { viewport in
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
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: CellFrames.self, value: [item.id: g.frame(in: .named("grid"))])
                                })
                                .onTapGesture(count: 2) {
                                    gridFocused = true
                                    selection = [item.id]
                                    anchor = item.id
                                    open(item)
                                }
                                .simultaneousGesture(TapGesture().onEnded { click(item) })
                                .onHover { inside in
                                    if inside {
                                        frameStore.hoveredID = item.id
                                        gridFocused = true
                                    } else if frameStore.hoveredID == item.id {
                                        frameStore.hoveredID = nil
                                    }
                                }
                                .contextMenu { contextMenu(for: item) }
                        }
                    } header: {
                        // 悬浮的玻璃小胶囊，滚动时吸在顶部（和「照片」App 一样）
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            // 撑满可见区域，这样下方空白也能点、也能从那里开始框选
            .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
            .background(
                // 点空白处取消选择（点在缩略图上的点击由缩略图自己处理）
                Color.clear.contentShape(Rectangle()).onTapGesture {
                    selection.removeAll()
                    anchor = nil
                }
            )
            .overlay(alignment: .topLeading) {
                if let r = band {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
            }
            .background(GridScreenCoordinates(store: frameStore))
            .coordinateSpace(.named("grid"))
            .onPreferenceChange(CellFrames.self) { frameStore.frames = $0 }
            .simultaneousGesture(rubberBand)
        }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(.space, phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            guard let hoveredID = frameStore.hoveredID,
                  frameStore.screenFrame(for: hoveredID).contains(NSEvent.mouseLocation),
                  let item = items.first(where: { $0.id == hoveredID }) else { return .handled }
            HoldPreview.shared.begin(
                initialURL: link.cachedOriginal(item) ?? link.thumbs?.storedURL(item),
                title: item.name,
                transitionImage: ThumbImages.cached(item),
                sourceFrame: frameStore.screenFrame(for: item.id),
                original: previewOriginal(item)
            ) { message = $0 }
            return .handled
        }
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
        // 音频用系统列表自带的多选：单击选中，⌘ / ⇧ 多选，双击播放，右键菜单
        List(selection: $selection) {
            ForEach(items) { item in
                AudioRow(item: item)
                    .tag(item.id)
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

    /// 拖动框选：框到的缩略图都选中；按住 ⌘ / ⇧ 是在原有选择上追加
    private var rubberBand: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("grid"))
            .onChanged { v in
                if band == nil {
                    let mods = NSEvent.modifierFlags
                    bandBase = mods.contains(.command) || mods.contains(.shift) ? selection : []
                }
                let r = CGRect(
                    x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                    width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y)
                )
                band = r
                selection = bandBase.union(frameStore.frames.filter { $0.value.intersects(r) }.map(\.key))
            }
            .onEnded { _ in
                band = nil
            }
    }

    private func click(_ item: MediaItem) {
        gridFocused = true
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else if mods.contains(.shift), let a = anchor,
                  let i = items.firstIndex(where: { $0.id == a }),
                  let j = items.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(items[min(i, j)...max(i, j)].map(\.id))
        } else {
            // 普通单击只选中；菜单留给右键，避免拦截后续双击和键盘操作。
            selection = [item.id]
            anchor = item.id
        }
    }

    /// 右键菜单作用的对象
    /// 按住空格预览时去取原文件。视频动辄几个 GB，只看缩略图（已下载过的原视频照常预览）
    private func previewOriginal(_ item: MediaItem) -> (@MainActor () async throws -> URL)? {
        guard item.kind != .video else { return nil }
        return { try await link.original(item) }
    }

    private func targets(for item: MediaItem) -> [MediaItem] {
        selection.count > 1 && selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item]
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

    /// 菜单只有四项：打开、复制、下载（存到「文稿/Colorlink」，和面板一致）、删除（移到手机的「最近删除」）。
    /// 选了几项看标题栏的「已选 N 项」，菜单里不重复写
    private func actions(for targets: [MediaItem]) -> [Action] {
        guard !targets.isEmpty else { return [] }
        var list = [
            Action(title: "打开") { targets.prefix(10).forEach(open) },
            Action(title: "复制") { Task { _ = await link.copyToClipboard(targets) } },
            Action(title: "下载") { save(targets) },
        ]
        if targets.allSatisfy({ $0.kind != .audio }) {
            list.append(Action(title: "删除") { trash(targets) })
        }
        return list
    }

    // MARK: - 按日期分组

    private struct DaySection {
        let title: String
        let items: [MediaItem]
    }

    private static func group(_ items: [MediaItem]) -> [DaySection] {
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
        item.capturedDate
    }

    private static func dayTitle(_ item: MediaItem) -> String {
        let date = date(item)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        return (sameYear ? sameYearFormat : otherYearFormat).string(from: date)
    }

    private static let sameYearFormat = dayFormatter("M月d日 EEEE")
    private static let otherYearFormat = dayFormatter("yyyy年M月d日")

    private static func dayFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }

    // MARK: - 数据

    private var syncing: Bool { link.library?.syncing.contains(kind) == true }

    /// 切换类型、重新连上时：先显示本机保存的列表（秒开），再在后台和手机核对
    private func reload() async {
        selection.removeAll()
        anchor = nil
        show(link.library?.lists[kind])
        await sync()
    }

    private func sync() async {
        guard let c = link.client, let library = link.library else { return }
        await library.sync(kind, client: c)
    }

    private func show(_ snap: MediaLibrary.Snapshot?) {
        let new = link.library?.displayItems(snap) ?? snap?.items ?? []
        setItems(new, total: snap?.total ?? 0)
    }

    /// 列表只从这里改：顺带重新分组
    private func setItems(_ new: [MediaItem], total: Int) {
        let ordered = kind == .audio ? new : new.sorted {
            $0.capturedDate == $1.capturedDate ? $0.id > $1.id : $0.capturedDate > $1.capturedDate
        }
        guard ordered != items || self.total != total else { return }
        items = ordered
        self.total = total
        sections = kind == .audio ? [] : Self.group(ordered)
    }

    // MARK: - 操作

    private func open(_ item: MediaItem) {
        if item.kind == .image {
            Task {
                do {
                    let url = try await link.original(item)
                    guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                        message = "找不到 macOS 预览"
                        return
                    }
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: preview,
                                                          configuration: NSWorkspace.OpenConfiguration())
                } catch {
                    message = error.localizedDescription
                }
            }
            return
        }
        guard let c = link.client else { return }
        // 下载过的视频直接打开本地文件
        if item.kind == .video, let local = link.localCopy(item) {
            NSWorkspace.shared.open(local)
            return
        }
        if item.kind == .video {
            // 视频直接用 Range 请求边下边播
            Task {
                do {
                    Windows.shared.openPlayer(try await c.playbackURL(item))
                } catch {
                    AppLog.write("播放 \(item.name) 失败：\(error)")
                }
            }
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

    /// 移到手机的「最近删除」，成功后从列表里拿掉
    private func trash(_ targets: [MediaItem]) {
        Task {
            message = await link.trash(targets)
            if message == "已移到手机的「最近删除」" {
                let gone = Set(targets.map(\.id))
                link.library?.remove(gone, kind: kind)
                selection.subtract(gone)
            }
            try? await Task.sleep(for: .seconds(2.5))
            message = nil
        }
    }

    /// 下载到「文稿/Colorlink」；下载过的不重新下
    private func save(_ targets: [MediaItem]) {
        Task {
            var done = 0
            for item in targets {
                do {
                    _ = try await link.download(item, to: AppDirs.downloads)
                    done += 1
                } catch {
                    message = error.localizedDescription
                }
            }
            guard done > 0 else { return }
            message = "已下载到「文稿/Colorlink」"
            try? await Task.sleep(for: .seconds(2))
            message = nil
        }
    }
}

/// 存缩略图位置的盒子（引用类型，改它不会触发界面刷新）
private final class FrameStore: @unchecked Sendable {
    var frames: [MediaItem.ID: CGRect] = [:]
    var hoveredID: MediaItem.ID?
    weak var coordinateView: NSView?

    @MainActor
    func screenFrame(for id: MediaItem.ID) -> NSRect {
        guard let rect = frames[id], let view = coordinateView, let window = view.window else { return .zero }
        let visible = rect.intersection(view.visibleRect)
        guard !visible.isNull, !visible.isEmpty else { return .zero }
        return window.convertToScreen(view.convert(visible, to: nil))
    }
}

/// Matches the grid's top-left coordinate space, including scrolling, without intercepting input.
private struct GridScreenCoordinates: NSViewRepresentable {
    let store: FrameStore
    func makeNSView(context: Context) -> CoordinateView {
        let view = CoordinateView()
        store.coordinateView = view
        return view
    }
    func updateNSView(_ nsView: CoordinateView, context: Context) {}

    final class CoordinateView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 解码好的缩略图：在后台线程解码（不卡滚动），按像素算内存，最多约 150 MB
enum ThumbImages {
    private static let memo: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 150 << 20
        return c
    }()

    static func cached(_ item: MediaItem) -> NSImage? { memo.object(forKey: item.cacheKey as NSString) }

    static func decode(_ data: Data, for item: MediaItem) async -> NSImage? {
        let key = item.cacheKey
        let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        memo.setObject(image, forKey: key as NSString, cost: cg.width * cg.height * 4)
        return image
    }
}

/// 缩略图在网格坐标系里的位置，框选时用来判断框到了哪些
private struct CellFrames: PreferenceKey {
    static var defaultValue: [MediaItem.ID: CGRect] = [:]
    static func reduce(value: inout [MediaItem.ID: CGRect], nextValue: () -> [MediaItem.ID: CGRect]) {
        value.merge(nextValue()) { $1 }
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
                if let image = image ?? ThumbImages.cached(item) {
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
            .overlay(alignment: .topLeading) {
                if link.isDownloaded(item) { DownloadedMark(size: 15) }
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
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(item.name)
            .task(id: item.cacheKey) {
                // 滚回来的格子直接用内存里解码好的图，不闪、不重新解码
                if ThumbImages.cached(item) != nil { return }
                guard let cache = link.thumbs else { return }
                let data = if let c = link.client { await cache.data(for: item, client: c) } else { cache.stored(item) }
                guard let data, let decoded = await ThumbImages.decode(data, for: item) else { return }
                withAnimation(.easeIn(duration: 0.15)) { image = decoded }
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
        item.capturedDate
            .formatted(date: .abbreviated, time: .shortened)
    }
}

func formatDuration(_ ms: Int64) -> String {
    let s = Int(ms / 1000)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
