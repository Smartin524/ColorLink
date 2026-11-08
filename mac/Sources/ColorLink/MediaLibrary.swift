import ColorLinkCore
import Foundation

/// 手机相册在本机的完整副本（每种类型一份列表，存在「应用程序支持/ColorLink/手机 ID/lists」）。
///
/// 打开相册直接显示本地这份，再和手机核对。旧照片基本不会变，所以核对时只取最新的一页：
/// - 媒体库「代数」没变：什么都不做；
/// - 只多了新照片：取到和本地第一项接上为止，把新的接到前面；
/// - 有删除或别的变化（总数对不上）：在后台把整个列表重新拉一遍（一万多张约几秒）。
@MainActor
final class MediaLibrary: ObservableObject {
    struct Snapshot: Codable, Sendable {
        var metadataVersion: Int?
        var generation: Int64?
        var total: Int
        var items: [MediaItem]
        /// 第一次同步还没拉完时为 false
        var complete: Bool
    }

    let deviceId: String
    @Published private(set) var lists: [MediaKind: Snapshot] = [:]
    @Published private(set) var syncing: Set<MediaKind> = []
    private var running: [MediaKind: Task<Void, Never>] = [:]

    // Separate from raw snapshots so EXIF recovery cannot break incremental comparisons.
    private var captureDates: [String: Int64] = [:]
    private var checkedHeaders = Set<String>()
    private var captureDatesFile: URL { AppDirs.library(deviceId).appendingPathComponent("capture-dates-v1.json") }

    func displayItems(_ snapshot: Snapshot?) -> [MediaItem] {
        (snapshot?.items ?? []).map { $0.recoveringCaptureDate(captureDates[$0.cacheKey]) }
    }

    init(deviceId: String) {
        self.deviceId = deviceId
        if let data = try? Data(contentsOf: captureDatesFile),
           let dates = try? JSONDecoder().decode([String: Int64].self, from: data) {
            captureDates = dates
        }
        for kind in MediaKind.allCases {
            if let data = try? Data(contentsOf: file(kind)),
               let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                lists[kind] = snap
            }
        }
    }

    private func file(_ kind: MediaKind) -> URL {
        AppDirs.library(deviceId).appendingPathComponent("lists/\(kind.rawValue).json")
    }

    /// 和手机核对一次；同一类型同时只跑一个，后来的等它跑完
    func sync(_ kind: MediaKind, client: PhoneClient) async {
        if let t = running[kind] {
            await t.value
            return
        }
        let t = Task {
            await self.doSync(kind, client)
            if kind == .image { await self.recoverCaptureDates(client) }
        }
        running[kind] = t
        syncing.insert(kind)
        await t.value
        running[kind] = nil
        syncing.remove(kind)
    }

    /// Old Bluetooth imports can retain EXIF even when MediaStore has no DATE_TAKEN.
    private func recoverCaptureDates(_ client: PhoneClient) async {
        let missing = (lists[.image]?.items ?? []).filter {
            ($0.taken ?? 0) <= 0 && captureDates[$0.cacheKey] == nil && !checkedHeaders.contains($0.cacheKey)
        }
        var recovered = 0
        for (index, item) in missing.enumerated() {
            guard !Task.isCancelled else { break }
            do {
                let data = try await client.captureDateHeader(item)
                let timestamp = ImageCaptureDate.read(data)
                checkedHeaders.insert(item.cacheKey)
                if let timestamp {
                    captureDates[item.cacheKey] = timestamp
                    recovered += 1
                } else if Int64(data.count) == item.size {
                    // Only persist a negative result when the whole file was inspected.
                    captureDates[item.cacheKey] = 0
                }
            } catch {
                // Retry next sync after connectivity/permission recovers, rather than timing out per photo.
                break
            }
            if index % 20 == 0 { publishCaptureDates() }
        }
        if !missing.isEmpty { publishCaptureDates() }
        if recovered > 0 { AppLog.write("从原图 EXIF 恢复拍摄日期：\(recovered) 项") }
    }

    private func publishCaptureDates() {
        let current = lists
        lists = current
        do {
            try FileManager.default.createDirectory(at: captureDatesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(captureDates).write(to: captureDatesFile, options: .atomic)
        } catch {
            AppLog.write("保存拍摄日期缓存失败：\(error)")
        }
    }

    /// 在 Mac 上删掉（移到手机的「最近删除」）后，本地列表同步去掉
    func remove(_ ids: Set<MediaItem.ID>, kind: MediaKind) {
        guard var snap = lists[kind] else { return }
        let before = snap.items.count
        snap.items.removeAll { ids.contains($0.id) }
        snap.total -= before - snap.items.count
        set(kind, snap)
    }

    private func doSync(_ kind: MediaKind, _ c: PhoneClient) async {
        do {
            let first = try await c.media(kind: kind, offset: 0, limit: 200)
            if let cached = lists[kind], cached.complete, cached.metadataVersion == first.metadataVersion, cached.total == first.total {
                let sameGeneration = first.generation != nil && first.generation == cached.generation
                // 旧版手机没有代数：第一页完全一样就当没变
                let sameHead = first.generation == nil && Array(cached.items.prefix(first.items.count)) == first.items
                if sameGeneration || sameHead { return }
            }
            if let cached = lists[kind], cached.complete, cached.metadataVersion == first.metadataVersion,
               let merged = await mergeHead(kind, first, cached, c) {
                let added = merged.count - cached.items.count
                set(kind, Snapshot(metadataVersion: first.metadataVersion, generation: first.generation, total: first.total, items: merged, complete: true))
                if added > 0 { AppLog.write("\(kind.title)列表：新增 \(added) 项") }
                return
            }
            try await fullSync(kind, first, c)
        } catch {
            AppLog.write("同步\(kind.title)列表失败：\(error)")
        }
    }

    /// 只多了新照片时：往后取到和本地第一项接上为止（最多 2500 项），把新的接到前面。
    /// 接不上、接上的部分对不上、或总数不符，返回 nil 交给完整同步
    private func mergeHead(_ kind: MediaKind, _ first: MediaPage, _ cached: Snapshot, _ c: PhoneClient) async -> [MediaItem]? {
        guard let anchor = cached.items.first else { return nil }
        var head = first.items
        while !head.contains(where: { $0.id == anchor.id }) {
            guard head.count < first.total, head.count < 2500,
                  let page = try? await c.media(kind: kind, offset: head.count, limit: 500),
                  !page.items.isEmpty else { return nil }
            head += page.items
        }
        guard let i = head.firstIndex(where: { $0.id == anchor.id }) else { return nil }
        let overlap = Array(head[i...])
        guard Array(cached.items.prefix(overlap.count)) == overlap else { return nil }
        let merged = Array(head[..<i]) + cached.items
        return merged.count == first.total ? merged : nil
    }

    /// 整个列表重新拉一遍。第一次同步时边拉边显示
    private func fullSync(_ kind: MediaKind, _ first: MediaPage, _ c: PhoneClient) async throws {
        let progressive = lists[kind]?.complete != true
        var items = first.items
        if progressive { set(kind, Snapshot(metadataVersion: first.metadataVersion, generation: nil, total: first.total, items: items, complete: false), save: false) }
        while items.count < first.total {
            let page = try await c.media(kind: kind, offset: items.count, limit: 500)
            if page.items.isEmpty { break }
            items += page.items
            if progressive { set(kind, Snapshot(metadataVersion: first.metadataVersion, generation: nil, total: first.total, items: items, complete: false), save: false) }
        }
        // 拉的过程中手机上新增了照片，分页会错位出重复，按 ID 去重
        var seen = Set<MediaItem.ID>()
        items = items.filter { seen.insert($0.id).inserted }
        set(kind, Snapshot(metadataVersion: first.metadataVersion, generation: first.generation, total: items.count, items: items, complete: true))
        AppLog.write("\(kind.title)列表完整同步：\(items.count) 项")
    }

    private func set(_ kind: MediaKind, _ snap: Snapshot, save: Bool = true) {
        lists[kind] = snap
        guard save else { return }
        let url = file(kind)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snap).write(to: url, options: .atomic)
        }
    }
}
