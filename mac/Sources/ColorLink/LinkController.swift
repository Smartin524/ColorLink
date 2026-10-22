import AppKit
import Foundation
import ColorLinkCore

/// 连接状态机：找手机 → 连接 → 订阅事件 → 断了就退避重连。整个过程无需人工干预。
@MainActor
final class LinkController: ObservableObject {
    enum State: Equatable {
        case searching
        case needsPairing(String)
        case connecting(String)
        case connected(String)
        case retrying(String, String)
    }

    @Published private(set) var state: State = .searching {
        didSet { if state != oldValue { AppLog.write("状态：\(self.state)") } }
    }
    @Published private(set) var discovered: [DiscoveredPhone] = []
    @Published private(set) var client: PhoneClient?
    @Published private(set) var device: PairedPhone?
    @Published private(set) var info: DeviceInfo?
    @Published private(set) var thumbs: ThumbnailCache?
    /// 每次连上换一个新值，界面据此刷新列表
    @Published private(set) var connectionID = UUID()
    @Published private(set) var lastEvent: String?
    /// 手机上最新的三张照片，显示在状态栏面板里
    @Published private(set) var recent: [MediaItem] = []
    /// 发送文件到手机的进度提示；nil 表示空闲
    @Published private(set) var transfer: String?
    /// 已经下载到这台 Mac 的照片：「手机 ID/cacheKey」→ 本地路径。下载过的不再重新下，界面上打对勾
    @Published private(set) var downloads: [String: String] = UserDefaults.standard.dictionary(forKey: "downloads") as? [String: String] ?? [:]

    @Published var autoCopyScreenshots: Bool {
        didSet { UserDefaults.standard.set(autoCopyScreenshots, forKey: "autoCopyScreenshots") }
    }
    /// 同步手机短信（手机端只转发短信 App 的通知）
    @Published var mirrorNotifications: Bool {
        didSet { UserDefaults.standard.set(mirrorNotifications, forKey: "mirrorNotifications") }
    }
    /// 短信里识别到验证码就直接复制到剪贴板
    @Published var autoCopyCodes: Bool {
        didSet { UserDefaults.standard.set(autoCopyCodes, forKey: "autoCopyCodes") }
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    private let browser = PhoneBrowser()
    private let beacon = BLEBeacon()
    private let knocks = KnockListener()
    /// 手机敲门时报来的最新地址，优先于 mDNS 和上次的地址
    private var knocked: [String: PhoneEndpoint] = [:]
    private var loop: Task<Void, Never>?
    /// 当前事件流；收到敲门判定为假连接时取消它
    private var streamTask: Task<Void, Error>?
    private var wakeCounter = 0

    init() {
        UserDefaults.standard.register(defaults: ["autoCopyScreenshots": true, "mirrorNotifications": true, "autoCopyCodes": true])
        autoCopyScreenshots = UserDefaults.standard.bool(forKey: "autoCopyScreenshots")
        mirrorNotifications = UserDefaults.standard.bool(forKey: "mirrorNotifications")
        autoCopyCodes = UserDefaults.standard.bool(forKey: "autoCopyCodes")

        browser.onChange = { [weak self] phones in
            Task { @MainActor in
                self?.discovered = phones
                self?.wake()
            }
        }
        browser.start()

        knocks.tokenFor = { id in PairedStore.all().first { $0.deviceId == id }?.token }
        knocks.onKnock = { [weak self] knock in
            Task { @MainActor in
                guard let self else { return }
                AppLog.write("收到手机敲门：\(knock.endpoint)")
                self.knocked[knock.deviceId] = knock.endpoint
                if self.isConnected {
                    // 手机只在没有 Mac 连着（或刚换了网络）时才敲门。我们却显示“已连接”，
                    // 说明这条连接已经断了，只是没收到关闭通知（例如手机突然断 Wi-Fi）。立即断开重连，
                    // 不必干等 90 秒超时。
                    AppLog.write("已连接却收到敲门，判定为假连接，立即重连")
                    self.streamTask?.cancel()
                }
                self.wake()
            }
        }
        knocks.start()
        if Bundle.main.bundleIdentifier != nil {
            // 以 .app 运行时才有 Info.plist 里的蓝牙用途说明，否则系统会直接终止进程
            beacon.start()
        }
        Notifier.setUp()

        // Mac 从睡眠中醒来时立刻重试，不等退避计时
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.wake() }
        }

        loop = Task { await run() }
    }

    /// 发现变化、配对完成、Mac 唤醒时调用，打断正在进行的等待。
    func wake() {
        wakeCounter += 1
    }

    // MARK: - 配对

    func pair(phone: DiscoveredPhone?, manualAddress: String, code: String) async throws {
        let endpoint: PhoneEndpoint
        if let phone {
            endpoint = try await PhoneBrowser.resolve(phone.endpoint)
        } else {
            endpoint = try PhoneEndpoint(parsing: manualAddress)
        }
        let clientName = Host.current().localizedName ?? "Mac"
        let r = try await PhoneClient.pair(endpoint: endpoint, code: code, clientName: clientName)
        PairedStore.save(PairedPhone(deviceId: r.deviceId, name: r.name, token: r.token, lastEndpoint: endpoint))
        wake()
    }

    func forget() {
        if let device { PairedStore.remove(device.deviceId) }
        wake()
    }

    // MARK: - 主循环

    private func run() async {
        var backoff = 1.0
        while !Task.isCancelled {
            guard let (paired, endpoint) = await target() else {
                let pairedIDs = Set(PairedStore.all().map(\.deviceId))
                if let unpaired = discovered.first(where: { !pairedIDs.contains($0.deviceId ?? "") }) {
                    state = .needsPairing(unpaired.name)
                } else {
                    state = .searching
                }
                if pairedIDs.isEmpty {
                    await pause(30)
                } else {
                    // 配过对但暂时找不到：按退避间隔继续探测上次的地址和网关
                    await pause(backoff)
                    backoff = min(backoff * 2, 15)
                }
                continue
            }

            state = .connecting(paired.name)
            let c = PhoneClient(endpoint: endpoint, token: paired.token)
            do {
                let info = try await c.info(timeout: 4)
                var p = paired
                p.lastEndpoint = endpoint
                p.name = info.name
                PairedStore.save(p)

                if thumbs == nil || device?.deviceId != p.deviceId {
                    thumbs = ThumbnailCache(deviceId: p.deviceId)
                }
                self.client = c
                self.device = p
                self.info = info
                connectionID = UUID()
                state = .connected(p.name)
                backoff = 1
                Task { await refreshRecent() }

                let stream = Task {
                    for try await event in c.events() {
                        self.handle(event, client: c)
                    }
                }
                streamTask = stream
                try await stream.value
                streamTask = nil
            } catch PhoneError.unauthorized {
                // 手机上点了「取消所有电脑的配对」
                AppLog.write("手机返回 401，已取消配对")
                PairedStore.remove(paired.deviceId)
                lastEvent = "手机已取消配对，请重新配对"
            } catch {
                lastEvent = error.localizedDescription
                AppLog.write("连接 \(endpoint) 失败：\(error)")
            }

            if client != nil {
                client = nil
                recent = []
            }
            state = .retrying(paired.name, lastEvent ?? "")
            if !knocked.isEmpty { continue } // 手机刚敲过门，不用等
            await pause(backoff)
            backoff = min(backoff * 2, 15)
        }
    }

    /// 选一个要连的手机：手机敲门报来的地址 > mDNS 刚发现的地址 > 上次成功的地址 / 网关。
    private func target() async -> (PairedPhone, PhoneEndpoint)? {
        let paired = PairedStore.all()
        for p in paired {
            // 敲门包带签名，已经验证过身份
            if let ep = knocked.removeValue(forKey: p.deviceId) { return (p, ep) }
        }
        for p in paired {
            if let d = discovered.first(where: { $0.deviceId == p.deviceId }),
               let ep = try? await PhoneBrowser.resolve(d.endpoint) {
                return (p, ep)
            }
        }
        // 没有敲门也没有 mDNS：试上次的地址，以及网关（Mac 连着手机热点时，网关就是手机）。
        // 先不带令牌核对设备 ID，对上了才连
        let gateway = PhoneBrowser.defaultGateway()
        for p in paired {
            var candidates: [PhoneEndpoint] = []
            if let ep = p.lastEndpoint { candidates.append(ep) }
            if let gw = gateway {
                let ep = PhoneEndpoint(host: gw, port: p.lastEndpoint?.port ?? 8765)
                if !candidates.contains(ep) { candidates.append(ep) }
            }
            for ep in candidates where await PhoneClient.identify(ep) == p.deviceId {
                return (p, ep)
            }
        }
        return nil
    }

    /// 等待指定秒数，期间若有 wake() 则提前返回。
    private func pause(_ seconds: Double) async {
        let start = wakeCounter
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, wakeCounter == start, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - 事件

    private func handle(_ event: PhoneEvent, client c: PhoneClient) {
        switch event {
        case .hello(let info):
            self.info = info

        case .media:
            Task { await refreshRecent() }

        case .screenshot(let item):
            AppLog.write("收到截图事件 \(item.name)")
            lastEvent = "收到截图 \(item.name)"
            Task { await refreshRecent() }
            guard autoCopyScreenshots else { return }
            Task {
                do {
                    let url = try await c.download(item, to: AppDirs.downloads.appendingPathComponent("截图"))
                    if Clipboard.copyImage(at: url) {
                        Notifier.post(title: "截图已复制", body: "可以直接 ⌘V 粘贴", image: url)
                        lastEvent = "截图已复制到剪贴板"
                    }
                } catch {
                    lastEvent = "截图下载失败：\(error.localizedDescription)"
                }
            }

        case .notification(let n):
            guard mirrorNotifications else { return }
            // 手机只发短信过来；识别到验证码就直接复制，通知里把验证码放在标题最显眼的位置
            let code = VerificationCode.extract(from: n.text)
            // 日志里不记短信内容和验证码
            AppLog.write("收到短信（\(n.text.count) 字），\(code == nil ? "没有识别出验证码" : "识别出验证码\(autoCopyCodes ? "并已复制" : "")")")
            if let code {
                if autoCopyCodes {
                    Clipboard.copyText(code)
                    lastEvent = "验证码 \(code) 已复制"
                }
                Notifier.post(
                    title: "验证码 \(code)\(autoCopyCodes ? "（已复制）" : "")",
                    body: "\(n.title)：\(n.text)",
                    id: n.key
                )
            } else {
                Notifier.post(title: "短信 · \(n.title)", body: n.text, id: n.key)
            }

        case .clipboard(let text):
            Clipboard.copyText(text)
            Notifier.post(title: "已收到手机发来的文字", body: text)
            lastEvent = "手机文字已复制到剪贴板"

        case .unknown:
            break
        }
    }

    // MARK: - 最近照片 / 发送到手机

    func refreshRecent() async {
        guard let c = client else { return }
        if let page = try? await c.media(kind: .image, offset: 0, limit: 3) {
            recent = page.items
        }
    }

    // MARK: - 相册列表缓存

    /// 每种类型上次的列表：内存里一份，磁盘上存前 1000 项（重开 App 也能秒开相册）
    private struct CachedList: Codable {
        let total: Int
        let items: [MediaItem]
    }

    private var lists: [MediaKind: CachedList] = [:]
    private var listsDevice: String?

    private func listFile(_ kind: MediaKind) -> URL? {
        guard let id = device?.deviceId else { return nil }
        return AppDirs.caches.appendingPathComponent("lists/\(id)-\(kind.rawValue).json")
    }

    func cachedList(_ kind: MediaKind) -> (total: Int, items: [MediaItem])? {
        if listsDevice != device?.deviceId {
            lists = [:]
            listsDevice = device?.deviceId
        }
        if lists[kind] == nil, let file = listFile(kind), let data = try? Data(contentsOf: file) {
            lists[kind] = try? JSONDecoder().decode(CachedList.self, from: data)
        }
        return lists[kind].map { ($0.total, $0.items) }
    }

    func storeList(_ kind: MediaKind, total: Int, items: [MediaItem]) {
        lists[kind] = CachedList(total: total, items: items)
        listsDevice = device?.deviceId
        guard let file = listFile(kind) else { return }
        let snapshot = CachedList(total: total, items: Array(items.prefix(1000)))
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        }
    }

    // MARK: - 已下载

    private func downloadKey(_ item: MediaItem) -> String { "\(device?.deviceId ?? "")/\(item.cacheKey)" }

    /// 这张照片下载到本机的文件；文件被删了就当没下载过
    func localCopy(_ item: MediaItem) -> URL? {
        guard let path = downloads[downloadKey(item)] else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func isDownloaded(_ item: MediaItem) -> Bool { localCopy(item) != nil }

    /// 下载到 dir；已经下载过（不管在哪个文件夹）就直接返回那份，不重新下载
    func download(_ item: MediaItem, to dir: URL) async throws -> URL {
        if let local = localCopy(item) { return local }
        guard let c = client else { throw PhoneError.streamEnded }
        let url = try await c.download(item, to: dir)
        downloads[downloadKey(item)] = url.path
        UserDefaults.standard.set(downloads, forKey: "downloads")
        return url
    }

    // MARK: - 删除

    /// 把手机上的照片 / 视频移到「最近删除」。返回给界面显示的一句话
    func trash(_ items: [MediaItem]) async -> String {
        guard let c = client else { return "手机未连接" }
        do {
            let r = try await c.trash(items)
            AppLog.write("删除手机上的 \(items.count) 项：已移走 \(r.trashed)，等待手机确认 \(r.pending)")
            await refreshRecent()
            return r.pending ? "请在手机上确认删除" : "已移到手机的「最近删除」"
        } catch {
            return "删除失败：\(error.localizedDescription)"
        }
    }

    /// 原图的本地文件（以原文件名保存，复制成文件时名字也对）。下载过就用下载的那份，否则缓存一份，同一张图只下载一次。
    func original(_ item: MediaItem) async throws -> URL {
        if let local = localCopy(item) { return local }
        guard let c = client else { throw PhoneError.streamEnded }
        let dir = AppDirs.caches.appendingPathComponent("originals/\(item.cacheKey)")
        let cached = dir.appendingPathComponent(item.name)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let tmp = try await c.download(item, to: AppDirs.caches.appendingPathComponent("originals/tmp"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: tmp, to: cached)
        return cached
    }

    /// 下载原图存到「图片/ColorLink」
    func saveToPictures(_ item: MediaItem) async -> Bool {
        do {
            let url = try await download(item, to: AppDirs.pictures)
            lastEvent = "已存到 图片/ColorLink：\(url.lastPathComponent)"
            return true
        } catch {
            lastEvent = "下载失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 下载原图并放进剪贴板
    func copyToClipboard(_ item: MediaItem) async -> Bool {
        await copyToClipboard([item])
    }

    /// 一张图片：放图片数据，哪里都能粘贴；多项：放文件，粘贴到 Finder、微信等会是多个文件
    func copyToClipboard(_ items: [MediaItem]) async -> Bool {
        do {
            var urls: [URL] = []
            for item in items { urls.append(try await original(item)) }
            let ok = urls.count == 1 && items[0].kind == .image ? Clipboard.copyImage(at: urls[0]) : Clipboard.copyFiles(urls)
            lastEvent = ok ? "已复制 \(items.count == 1 ? items[0].name : "\(items.count) 项")" : "复制失败"
            return ok
        } catch {
            lastEvent = "下载失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 把拖进来的文件发给手机。文件夹会被跳过。
    func send(_ urls: [URL]) async {
        guard let c = client else {
            transfer = "手机未连接"
            try? await Task.sleep(for: .seconds(1.5))
            transfer = nil
            return
        }
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        guard !files.isEmpty else { return }
        var done = 0
        let batch = UUID().uuidString
        for (i, url) in files.enumerated() {
            transfer = files.count == 1 ? "正在发送 \(url.lastPathComponent)…" : "正在发送 \(i + 1)/\(files.count)…"
            do {
                try await c.upload(file: url, batch: (batch, i, files.count))
                done += 1
            } catch {
                lastEvent = "发送 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
                AppLog.write("发送文件失败：\(error)")
            }
        }
        transfer = done == files.count ? "已发送到手机 ✓" : "已发送 \(done)/\(files.count)"
        AppLog.write("发送文件到手机：成功 \(done)/\(files.count)")
        lastEvent = transfer
        await refreshRecent()
        try? await Task.sleep(for: .seconds(1.5))
        transfer = nil
    }

    // MARK: - 诊断日志

    /// 把 Mac 和手机的日志一起导出到「下载/ColorLink/诊断日志-时间」，并在 Finder 里打开
    func exportDiagnostics() async {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let dir = AppDirs.downloads.appendingPathComponent("诊断日志-\(stamp)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var summary = [
            "导出时间：\(Date())",
            "macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "状态：\(state)",
            "手机：\(device?.name ?? "未配对") \(client?.endpoint.description ?? "")",
            "手机信息：\(info.map { "\($0.model) / Android \($0.android) / 电量 \($0.battery ?? -1)%" } ?? "无")",
            "设置：截图自动复制=\(autoCopyScreenshots) 同步短信=\(mirrorNotifications) 验证码自动复制=\(autoCopyCodes)",
        ]
        if let c = client {
            do {
                try await c.logs().write(to: dir.appendingPathComponent("手机.log"), atomically: true, encoding: .utf8)
                summary.append("手机日志：已导出")
            } catch {
                summary.append("手机日志：获取失败（\(error.localizedDescription)）")
            }
        } else {
            summary.append("手机日志：手机未连接，没有导出")
        }
        try? AppLog.dump().write(to: dir.appendingPathComponent("Mac.log"), atomically: true, encoding: .utf8)
        try? summary.joined(separator: "\n").write(to: dir.appendingPathComponent("概况.txt"), atomically: true, encoding: .utf8)
        AppLog.write("已导出诊断日志")
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
