import ColorLinkCore
import SwiftUI

/// 手机相册：照片 / 视频按日期分组成网格，录音是列表。
struct GalleryView: View {
    @EnvironmentObject var link: LinkController

    @State private var kind: MediaKind = .image
    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var message: String?
    @State private var selection: MediaItem.ID?

    private let pageSize = 200

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: "\(kind.rawValue)-\(link.connectionID)") { await reload() }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Text(countText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 160, alignment: .leading)
            Spacer()
            Picker("", selection: $kind) {
                ForEach(MediaKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            Spacer()
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新")
                .disabled(link.client == nil)
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var countText: String {
        if let message { return message }
        guard total > 0 else { return link.client == nil ? "" : "加载中…" }
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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            ThumbCell(item: item, selected: selection == item.id)
                                .onTapGesture(count: 2) { open(item) }
                                .simultaneousGesture(TapGesture().onEnded { selection = item.id })
                                .contextMenu { menu(for: item) }
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
    }

    private var audioList: some View {
        List(selection: $selection) {
            ForEach(items) { item in
                AudioRow(item: item)
                    .tag(item.id)
                    .contextMenu { menu(for: item) }
                    .onAppear { if item == items.last { Task { await loadMore() } } }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: MediaItem.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) { open(item) }
        }
    }

    @ViewBuilder
    private func menu(for item: MediaItem) -> some View {
        Button("打开") { open(item) }
        if item.kind == .image {
            Button("复制图片") { Task { _ = await link.copyToClipboard(item) } }
        }
        Button("保存到「下载/ColorLink」") { save(item, reveal: false) }
        Button("保存并在 Finder 中显示") { save(item, reveal: true) }
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
            let date = Date(timeIntervalSince1970: TimeInterval(item.added ?? item.modified))
            let key = cal.dateComponents([.year, .month, .day], from: date)
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

    private static func dayTitle(_ item: MediaItem) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.added ?? item.modified))
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
        selection = nil
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
                let url = try await c.download(item, to: AppDirs.caches.appendingPathComponent("open"))
                NSWorkspace.shared.open(url)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func save(_ item: MediaItem, reveal: Bool) {
        guard let c = link.client else { return }
        Task {
            do {
                let url = try await c.download(item, to: AppDirs.downloads)
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                message = error.localizedDescription
            }
        }
    }
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
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
            )
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
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
