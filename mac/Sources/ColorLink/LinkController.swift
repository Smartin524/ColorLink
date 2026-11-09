import AppKit
import Foundation
import ColorLinkCore
import UniformTypeIdentifiers

/// 连接状态机：找手机 → 连接 → 订阅事件 → 断了就退避重连。整个过程无需人工干预。
@MainActor
final class LinkController: ObservableObject {
    enum State: Equatable {
        case searching
        case needsPairing(String)
        case connecting(String)
        case connected(String)
        case retrying(String, String)
        /// Mac 锁屏或睡眠中，主动断开，解锁后再连
        case paused
    }

    @Published private(set) var state: State = .searching {
        didSet { if state != oldValue { AppLog.write("状态：\(self.state)") } }
    }
    @Published private(set) var discovered: [DiscoveredPhone] = []
    /// 手机在线、但上面的 ColorLink 没在运行（端口拒绝连接超过 5 分钟）
    @Published private(set) var phoneAppDown = false
    private var refusedSince: Date?
    @Published private(set) var client: PhoneClient?
    @Published private(set) var device: PairedPhone?
    @Published private(set) var info: DeviceInfo?
    /// 手机的免打扰档位；nil：没连上，或手机没开通知使用权（按钮不可用）
    @Published private(set) var dnd: DndMode?
    @Published private(set) var thumbs: ThumbnailCache?
    /// 手机相册在本机的完整副本
    @Published private(set) var library: MediaLibrary?
    /// 连上后核对列表的任务；核对完才决定要不要补缩略图
    private var syncTask: Task<Void, Never>?
    /// 后台补缩略图的任务；只在手机充电时存在
    private var prefetchTask: Task<Void, Never>?
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
    /// 同步手机通知（手机端转发会响的通知，微信除外）
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
    /// Mac 锁屏 / 睡眠时不连手机：没人用，手机却要一直挂着连接和前台服务。两个标志任一为真就暂停
    private var asleep = false
    private var locked = false
    @Published private(set) var paused = false

    nonisolated static let demo = CommandLine.arguments.contains("--demo")

    init() {
        UserDefaults.standard.register(defaults: ["autoCopyScreenshots": true, "mirrorNotifications": true, "autoCopyCodes": true])
        // 没连上手机也能翻本机保存的相册
        if let p = PairedStore.all().first {
            thumbs = ThumbnailCache(deviceId: p.deviceId)
            library = MediaLibrary(deviceId: p.deviceId)
        }
        autoCopyScreenshots = UserDefaults.standard.bool(forKey: "autoCopyScreenshots")
        mirrorNotifications = UserDefaults.standard.bool(forKey: "mirrorNotifications")
        autoCopyCodes = UserDefaults.standard.bool(forKey: "autoCopyCodes")

        browser.onChange = { [weak self] phones in
            Task { @MainActor in
                self?.discovered = phones
                self?.wake()
            }
        }
        // 录演示视频用（--demo）：只连指定的模拟手机，不搜索、不广播蓝牙、不发通知，免得弹出系统权限框
        if !Self.demo { browser.start() }

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
        if Bundle.main.bundleIdentifier != nil, !Self.demo {
            // 以 .app 运行时才有 Info.plist 里的蓝牙用途说明，否则系统会直接终止进程
            beacon.start()
        }
        if !Self.demo { Notifier.setUp() }

        // 睡眠前主动断开（否则手机要等 TCP 重传放弃、十几分钟后才知道 Mac 走了）；醒来后看锁屏状态决定要不要连
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAsleep(true) }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAsleep(false) }
        }
        // 锁屏 / 解锁没有公开 API，这两条分布式通知是系统一直在发的
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLocked(true) }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setLocked(false) }
        }

        loop = Task { await run() }
    }

    /// 发现变化、配对完成、Mac 唤醒时调用，打断正在进行的等待。
    func wake() {
        wakeCounter += 1
    }

    // MARK: - 锁屏 / 睡眠

    private func setAsleep(_ v: Bool) {
        asleep = v
        updatePaused()
    }

    private func setLocked(_ v: Bool) {
        locked = v
        updatePaused()
    }

    /// 暂停：断开事件流（手机那边立刻收到关闭，前台服务退掉、蓝牙扫描恢复），停掉蓝牙广播免得手机白白敲门。
    /// 恢复：醒来时锁屏通知可能晚一拍才到，等 1 秒再连，免得连上又断
    private func updatePaused() {
        let p = asleep || locked
        guard p != paused else { return }
        paused = p
        AppLog.write(p ? "Mac \(asleep ? "睡眠" : "锁屏")，断开手机" : "Mac 已解锁，恢复连接")
        beacon.set(advertising: !p)
        if p {
            streamTask?.cancel()
            wake()
        } else {
            Task {
                try? await Task.sleep(for: .seconds(1))
                if !paused { wake() }
            }
        }
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

    /// 找不到手机时看看它本身在不在：手机在线、但 ColorLink 的端口直接拒绝连接，说明手机上的 ColorLink 没在运行
    /// （被系统停了，而且自己没恢复）。被杀后通常几分钟内会自己回来，所以持续 5 分钟以上才提示，每次只发一条通知
    private func checkPhoneApp() async {
        guard let ep = PairedStore.all().first?.lastEndpoint else { return }
        guard await PortProbe.check(host: ep.host, port: ep.port) == .refused else {
            refusedSince = nil
            phoneAppDown = false
            return
        }
        let since = refusedSince ?? Date()
        refusedSince = since
        guard !phoneAppDown, Date().timeIntervalSince(since) >= 5 * 60 else { return }
        phoneAppDown = true
        AppLog.write("手机在线，但 ColorLink 没在运行（\(ep) 拒绝连接已超过 5 分钟）")
        Notifier.post(title: "手机上的 ColorLink 没在运行", body: "可能被系统停掉了，在手机上打开一下 ColorLink 就能恢复")
    }

    private func run() async {
        var backoff = 1.0
        while !Task.isCancelled {
            if paused {
                state = .paused
                await pause(3600) // 解锁 / 醒来时 wake() 会提前结束
                backoff = 1
                continue
            }
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
                    await checkPhoneApp()
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
                // 连接途中锁屏 / 睡眠：那时还没有事件流可断，这里不接着连，回到循环开头进入暂停
                if paused { continue }
                var p = paired
                p.lastEndpoint = endpoint
                p.name = info.name
                PairedStore.save(p)

                if library?.deviceId != p.deviceId {
                    thumbs = ThumbnailCache(deviceId: p.deviceId)
                    library = MediaLibrary(deviceId: p.deviceId)
                }
                self.client = c
                self.device = p
                self.info = info
                dnd = info.dnd.flatMap(DndMode.init(rawValue:))
                connectionID = UUID()
                refusedSince = nil
                phoneAppDown = false
                state = .connected(p.name)
                backoff = 1
                Task { await refreshRecent() }
                if let library { startBackgroundSync(c, library: library) }

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
                // 锁屏 / 睡眠时是自己取消的，不算失败
                if !paused {
                    lastEvent = error.localizedDescription
                    AppLog.write("连接 \(endpoint) 失败：\(error)")
                }
            }

            syncTask?.cancel()
            syncTask = nil
            prefetchTask?.cancel()
            prefetchTask = nil
            if client != nil {
                client = nil
                recent = []
                dnd = nil
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
            dnd = info.dnd.flatMap(DndMode.init(rawValue:))
            updatePrefetch()

        case .dnd(let mode):
            AppLog.write("手机免打扰：\(mode.title)")
            dnd = mode

        case .power(let charging, let battery):
            AppLog.write(charging ? "手机已接上电源" : "手机已拔掉电源")
            info?.charging = charging
            if let battery { info?.battery = battery }
            updatePrefetch()

        case .media:
            Task { await refreshRecent() }

        case .screenshot(let item):
            AppLog.write("收到截图事件 \(item.name)")
            lastEvent = "收到截图 \(item.name)"
            Task { await refreshRecent() }
            guard autoCopyScreenshots else { return }
            Task {
                do {
                    let url = try await c.download(item, to: AppDirs.downloads)
                    if Clipboard.copyImage(at: url) {
                        Notifier.post(title: "截图已复制", body: "", image: url)
                        lastEvent = "截图已复制到剪贴板"
                    }
                } catch {
                    lastEvent = "截图下载失败：\(error.localizedDescription)"
                }
            }

        case .notification(let n):
            guard mirrorNotifications else { return }
            // 只在短信里找验证码：别的 App 的通知里的数字（订单号、金额）不能当验证码复制走。
            // 旧版手机不带 sms 字段，那时只转发短信，按短信处理
            let isSms = n.sms ?? true
            let code = isSms ? VerificationCode.extract(from: n.text) : nil
            // 日志里不记通知内容和验证码
            AppLog.write("收到\(isSms ? "短信" : "通知（\(n.app)）")（\(n.text.count) 字）\(isSms ? "，\(code == nil ? "没有识别出验证码" : "识别出验证码\(autoCopyCodes ? "并已复制" : "")")" : "")")
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
                // 标题：App 名 · 通知标题；短信 App 的名字就是「信息」，和原来的「短信 · 发件人」一个意思
                Notifier.post(title: "\(n.app) · \(n.title)", body: n.text, id: n.key)
            }

        case .shared(let files):
            AppLog.write("收到手机分享的 \(files.count) 个文件")
            Task { await receiveShared(files, client: c) }

        case .clipboard(let text):
            Clipboard.copyText(text)
            Notifier.post(title: "已收到手机发来的文字", body: text)
            lastEvent = "手机文字已复制到剪贴板"

        case .unknown:
            break
        }
    }

    /// 手机分享的所有文件直接存进「文稿/Colorlink」，并放进剪贴板
    private func receiveShared(_ files: [SharedFile], client c: PhoneClient) async {
        var saved: [URL] = []
        for f in files {
            do {
                let dir = AppDirs.downloads
                saved.append(try await c.download(f, to: dir))
            } catch {
                AppLog.write("取分享的文件失败 \(f.name)：\(error)")
            }
        }
        guard !saved.isEmpty else {
            lastEvent = "手机分享的文件没取到"
            return
        }
        let images = saved.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image)) == true }
        // 一张图片放图片数据，哪里都能粘贴；其他情况放文件
        let copied = saved.count == 1 && images.count == 1 ? Clipboard.copyImage(at: saved[0]) : Clipboard.copyFiles(saved)
        let what = saved.count == 1 ? (images.count == 1 ? "图片" : saved[0].lastPathComponent)
            : images.count == saved.count ? "\(saved.count) 张图片" : "\(saved.count) 个文件"
        Notifier.post(
            title: "收到手机分享的\(what)",
            body: (copied ? "已复制，可以直接 ⌘V 粘贴；" : "") + "点按在 Finder 中显示",
            image: images.first,
            reveal: saved
        )
        lastEvent = "收到手机分享的\(what)"
    }

    // MARK: - 最近照片 / 发送到手机

    func refreshRecent() async {
        guard let c = client else { return }
        if let page = try? await c.media(kind: .image, offset: 0, limit: 3) {
            recent = page.items
        }
    }

    /// 打开面板时问一次电量。平时不问：电量和充电状态靠手机推的事件更新，定时问会把深睡的手机叫醒
    func refreshInfo() async {
        guard let c = client, let info = try? await c.info(timeout: 5) else { return }
        self.info = info
        dnd = info.dnd.flatMap(DndMode.init(rawValue:))
        updatePrefetch()
    }

    // MARK: - 免打扰

    /// 面板上的免打扰按钮：关着就开成「仅优先」，开着（不管哪一档）就关。手机改完会回 dnd 事件，这里先按请求的值显示
    func toggleDnd() async {
        guard let c = client, let current = dnd else { return }
        let target: DndMode = current.isOn ? .all : .priority
        do {
            dnd = try await c.setDnd(target)
            lastEvent = target.isOn ? "免打扰已开" : "免打扰已关"
        } catch {
            lastEvent = "免打扰设置失败：\(error.localizedDescription)"
            AppLog.write("免打扰设置失败：\(error)")
        }
    }

    // MARK: - 本机相册副本

    /// 连上后在后台把照片、视频列表和手机核对一遍，核对完再看要不要补缩略图
    private func startBackgroundSync(_ c: PhoneClient, library: MediaLibrary) {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            for kind in [MediaKind.image, .video] { await library.sync(kind, client: c) }
            guard let self, !Task.isCancelled else { return }
            self.syncTask = nil
            self.updatePrefetch()
        }
    }

    /// 本机还没有的缩略图只在手机充电时补：生成缩略图要占手机 CPU，不充电时相册里看到哪张再取哪张。
    /// 开始和停下都由手机推来的充电事件（和 hello）决定，不定时去问手机：每问一次都会把深睡的手机叫醒。
    /// 连上时、充电状态变了时、列表核对完时各调一次，随时可以调
    private func updatePrefetch() {
        guard let c = client, let library, let thumbs, info?.charging == true, syncTask == nil else {
            prefetchTask?.cancel()
            prefetchTask = nil
            return
        }
        guard prefetchTask == nil else { return }
        prefetchTask = Task { [weak self] in
            // 被取消的任务不是当前任务（取消时已经换掉了），别把新任务的记录抹掉
            defer { if !Task.isCancelled { self?.prefetchTask = nil } }
            var announced = false
            // 取不到的（手机上生成不了缩略图的文件）本次连接里不再重试，否则会一直重复请求
            var failed = Set<String>()
            while !Task.isCancelled {
                let missing = [MediaKind.image, .video].flatMap { library.lists[$0]?.items ?? [] }
                    .filter { !failed.contains($0.cacheKey) && !thumbs.has($0) }
                guard !missing.isEmpty else {
                    if announced {
                        AppLog.write("缩略图已全部存到本机" + (failed.isEmpty ? "" : "（\(failed.count) 张手机上生成不了，跳过）"))
                    }
                    return
                }
                if !announced {
                    AppLog.write("手机在充电，后台补齐缩略图：还差 \(missing.count) 张")
                    announced = true
                }
                // 每轮最多 200 张、同时 3 个请求；拔掉电源时任务被取消，一轮做完就停
                var queue = missing.prefix(200).makeIterator()
                let failedNow = await withTaskGroup(of: String?.self) { group in
                    func add(_ item: MediaItem) {
                        group.addTask { await thumbs.prefetch(item, client: c) ? nil : item.cacheKey }
                    }
                    for _ in 0..<3 { if let item = queue.next() { add(item) } }
                    var failed: [String] = []
                    while let result = await group.next() {
                        if let key = result { failed.append(key) }
                        if Task.isCancelled { break }
                        if let item = queue.next() { add(item) }
                    }
                    return failed
                }
                failed.formUnion(failedNow)
            }
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

    func cachedOriginal(_ item: MediaItem) -> URL? {
        if let local = localCopy(item) { return local }
        let url = AppDirs.caches.appendingPathComponent("originals/\(item.cacheKey)/\(item.name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 原图的本地文件（以原文件名保存，复制成文件时名字也对）。下载过就用下载的那份，否则缓存一份，同一张图只下载一次。
    func original(_ item: MediaItem) async throws -> URL {
        if let local = cachedOriginal(item) { return local }
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

    /// 下载原图存到「文稿/Colorlink」
    func saveToPictures(_ item: MediaItem) async -> Bool {
        do {
            let url = try await download(item, to: AppDirs.downloads)
            lastEvent = "已存到 文稿/Colorlink：\(url.lastPathComponent)"
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

    /// 诊断日志直接导出到「文稿/Colorlink」，同批文件使用相同前缀。
    func exportDiagnostics() async {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let dir = AppDirs.downloads
        let prefix = "诊断日志-\(stamp)-\(UUID().uuidString.prefix(8))"
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
                try await c.logs().write(to: dir.appendingPathComponent("\(prefix)-手机.log"), atomically: true, encoding: .utf8)
                summary.append("手机日志：已导出")
            } catch {
                summary.append("手机日志：获取失败（\(error.localizedDescription)）")
            }
        } else {
            summary.append("手机日志：手机未连接，没有导出")
        }
        try? AppLog.dump().write(to: dir.appendingPathComponent("\(prefix)-Mac.log"), atomically: true, encoding: .utf8)
        try? summary.joined(separator: "\n").write(to: dir.appendingPathComponent("\(prefix)-概况.txt"), atomically: true, encoding: .utf8)
        AppLog.write("已导出诊断日志")
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
