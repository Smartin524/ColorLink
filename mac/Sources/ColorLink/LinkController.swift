import AppKit
import Foundation
import os
import ColorLinkCore

let log = Logger(subsystem: "com.colorlink.mac", category: "link")

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
        didSet { if state != oldValue { log.info("状态：\(String(describing: self.state), privacy: .public)") } }
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
                log.info("收到手机敲门：\(knock.endpoint.description, privacy: .public)")
                self.knocked[knock.deviceId] = knock.endpoint
                if self.isConnected {
                    // 手机只在没有 Mac 连着（或刚换了网络）时才敲门。我们却显示“已连接”，
                    // 说明这条连接已经断了，只是没收到关闭通知（例如手机突然断 Wi-Fi）。立即断开重连，
                    // 不必干等 90 秒超时。
                    log.info("已连接却收到敲门，判定为假连接，立即重连")
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
                PairedStore.remove(paired.deviceId)
                lastEvent = "手机已取消配对，请重新配对"
            } catch {
                lastEvent = error.localizedDescription
                log.info("连接 \(endpoint.description, privacy: .public) 失败：\(String(describing: error), privacy: .public)")
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
            if let code = VerificationCode.extract(from: n.text) {
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

    /// 下载原图并放进剪贴板。同一张图只下载一次。
    func copyToClipboard(_ item: MediaItem) async -> Bool {
        guard let c = client else { return false }
        let dir = AppDirs.caches.appendingPathComponent("originals")
        let ext = (item.name as NSString).pathExtension
        let cached = dir.appendingPathComponent(item.cacheKey + (ext.isEmpty ? "" : ".\(ext)"))
        do {
            if !FileManager.default.fileExists(atPath: cached.path) {
                let tmp = try await c.download(item, to: dir.appendingPathComponent("tmp"))
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.moveItem(at: tmp, to: cached)
            }
            let ok = Clipboard.copyImage(at: cached)
            lastEvent = ok ? "已复制 \(item.name)" : "复制失败"
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
        for (i, url) in files.enumerated() {
            transfer = files.count == 1 ? "正在发送 \(url.lastPathComponent)…" : "正在发送 \(i + 1)/\(files.count)…"
            do {
                try await c.upload(file: url)
                done += 1
            } catch {
                lastEvent = "发送 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
            }
        }
        transfer = done == files.count ? "已发送到手机 ✓" : "已发送 \(done)/\(files.count)"
        lastEvent = transfer
        await refreshRecent()
        try? await Task.sleep(for: .seconds(1.5))
        transfer = nil
    }
}
