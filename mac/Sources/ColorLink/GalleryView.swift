import ColorLinkCore
import SwiftUI

struct GalleryView: View {
    @EnvironmentObject var link: LinkController

    @State private var kind: MediaKind = .image
    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var message: String?

    private let pageSize = 200

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $kind) {
                    ForEach(MediaKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("\(items.count) / \(total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(8)
            Divider()

            if link.client == nil {
                ContentUnavailableView("手机未连接", systemImage: "iphone.slash", description: Text("连上以后这里会自动刷新"))
            } else if kind == .audio {
                List(items) { item in
                    AudioRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(item) }
                        .contextMenu { menu(for: item) }
                        .onAppear { if item == items.last { Task { await loadMore() } } }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 3)], spacing: 3) {
                        ForEach(items) { item in
                            ThumbCell(item: item)
                                .onTapGesture(count: 2) { open(item) }
                                .contextMenu { menu(for: item) }
                                .onAppear { if item == items.last { Task { await loadMore() } } }
                        }
                    }
                    .padding(3)
                }
            }
        }
        .task(id: "\(kind.rawValue)-\(link.connectionID)") { await reload() }
    }

    @ViewBuilder
    private func menu(for item: MediaItem) -> some View {
        Button("打开") { open(item) }
        Button("保存到「下载/ColorLink」") { save(item, reveal: true) }
        if item.kind == .image {
            Button("复制图片") { copy(item) }
        }
    }

    // MARK: - 数据

    private func reload() async {
        items = []
        total = 0
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

    private func copy(_ item: MediaItem) {
        guard let c = link.client else { return }
        Task {
            do {
                let url = try await c.download(item, to: AppDirs.caches.appendingPathComponent("open"))
                message = Clipboard.copyImage(at: url) ? "已复制" : "复制失败"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

struct ThumbCell: View {
    let item: MediaItem
    @EnvironmentObject var link: LinkController
    @State private var image: NSImage?

    var body: some View {
        Color.gray.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video, let d = item.duration {
                    Text(formatDuration(d))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .help(item.name)
            .task(id: item.cacheKey) {
                guard let c = link.client, let cache = link.thumbs else { return }
                if let d = await cache.data(for: item, client: c) { image = NSImage(data: d) }
            }
    }
}

struct AudioRow: View {
    let item: MediaItem

    var body: some View {
        HStack {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            Text(item.name).lineLimit(1)
            Spacer()
            if let d = item.duration { Text(formatDuration(d)).monospacedDigit().foregroundStyle(.secondary) }
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

func formatDuration(_ ms: Int64) -> String {
    let s = Int(ms / 1000)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
