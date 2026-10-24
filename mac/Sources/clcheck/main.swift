// 命令行联调：在没有手机的情况下，对着 mock/mock_phone.py 走一遍 Mac 端的完整流程。
//
//   swift run clcheck --code 123456            # 通过 mDNS 找手机
//   swift run clcheck --host 127.0.0.1 --code 123456
//
// 加 --trigger 会让模拟手机“截一张图”，验证截图 → 剪贴板这条链路。
// 加 --doze（模拟手机也要加 --doze）验证手机深睡、ping 停发时事件流不会被误判断线，约 2 分半。

import AppKit
import Foundation
import ColorLinkCore

setlinebuf(stdout)

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func step(_ s: String) { print("\n▶ \(s)") }
func ok(_ s: String) { print("  ✓ \(s)") }
func fail(_ s: String) -> Never {
    print("  ✗ \(s)")
    exit(1)
}

func ms(since t: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(t) * 1000) }

let code = arg("--code") ?? "123456"
let trigger = CommandLine.arguments.contains("--trigger")
let doze = CommandLine.arguments.contains("--doze")

// ① 发现
var endpoint: PhoneEndpoint
if let h = arg("--host") {
    endpoint = try PhoneEndpoint(parsing: h)
    step("使用指定地址 \(endpoint)")
} else {
    step("通过 mDNS 查找 \(PhoneBrowser.serviceType)")
    let t = Date()
    let browser = PhoneBrowser()
    let found: DiscoveredPhone = try await withCheckedThrowingContinuation { cont in
        let once = NSLock()
        var done = false
        browser.onChange = { phones in
            guard let p = phones.first else { return }
            once.lock(); defer { once.unlock() }
            if !done { done = true; cont.resume(returning: p) }
        }
        browser.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            once.lock(); defer { once.unlock() }
            if !done { done = true; cont.resume(throwing: PhoneError.timeout) }
        }
    }
    browser.stop()
    ok("发现「\(found.name)」id=\(found.deviceId ?? "?")（\(ms(since: t))）")
    endpoint = try await PhoneBrowser.resolve(found.endpoint)
    ok("解析为 \(endpoint)")
}

// ② 未授权访问应被拒绝
step("未配对时访问应返回 401")
do {
    _ = try await PhoneClient(endpoint: endpoint, token: "wrong").info()
    fail("没有被拒绝")
} catch PhoneError.unauthorized {
    ok("被拒绝")
}

// ③ 配对
step("配对（错误的码应失败，正确的码应成功）")
do {
    _ = try await PhoneClient.pair(endpoint: endpoint, code: "000000", clientName: "clcheck")
    fail("错误配对码居然成功了")
} catch PhoneError.badPairingCode {
    ok("错误配对码被拒绝")
}
let pr = try await PhoneClient.pair(endpoint: endpoint, code: code, clientName: "clcheck")
ok("配对成功：\(pr.name)")
let client = PhoneClient(endpoint: endpoint, token: pr.token)

let info = try await client.info()
ok("设备信息：\(info.model) / Android \(info.android) / 电量 \(info.battery.map { "\($0)%" } ?? "?")")

// ④ 媒体列表
step("媒体列表")
var images: [MediaItem] = []
for kind in MediaKind.allCases {
    let t = Date()
    let page = try await client.media(kind: kind, offset: 0, limit: 100)
    ok("\(kind.title)：共 \(page.total) 个，首页 \(page.items.count) 个（\(ms(since: t))）")
    if kind == .image { images = page.items }
}
guard let first = images.first else { fail("没有照片，无法继续") }

// ⑤ 缩略图：冷缓存 vs 热缓存
step("缩略图（并发拉取 \(min(images.count, 40)) 张）")
let cache = ThumbnailCache(deviceId: "clcheck-\(pr.deviceId)")
await cache.clearDisk()
let batch = Array(images.prefix(40))

func fetchAll(_ cache: ThumbnailCache) async -> (Int, Int) {
    await withTaskGroup(of: Int?.self) { g in
        for item in batch { g.addTask { await cache.data(for: item, client: client)?.count } }
        var n = 0, bytes = 0
        for await r in g { if let r { n += 1; bytes += r } }
        return (n, bytes)
    }
}

var t = Date()
let (n1, b1) = await fetchAll(cache)
ok("从手机拉取：\(n1) 张，\(b1 / 1024) KB（\(ms(since: t))）")
t = Date()
let (n2, _) = await fetchAll(ThumbnailCache(deviceId: "clcheck-\(pr.deviceId)")) // 新实例 = 只剩磁盘缓存
ok("读磁盘缓存：\(n2) 张（\(ms(since: t))）")

// ⑥ Range
step("Range 请求（视频拖动进度条靠它）")
let (data, resp) = try await client.rawRequest(first, range: "bytes=0-99")
guard resp.statusCode == 206, data.count == 100 else { fail("期望 206 + 100 字节，实际 \(resp.statusCode) + \(data.count)") }
ok("206 Partial Content，\(resp.value(forHTTPHeaderField: "Content-Range") ?? "")")

t = Date()
let file = try await client.download(first, to: FileManager.default.temporaryDirectory.appendingPathComponent("clcheck"))
let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
ok("下载原图 \(first.name)：\(size / 1024) KB（\(ms(since: t))）")

// ⑦ 发送文件到手机
step("发送图片到手机（拖到状态栏面板时走的就是这条路）")
let sample = FileManager.default.temporaryDirectory.appendingPathComponent("ColorLink 测试图.png")
let gen = Process()
gen.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
gen.arguments = ["-s", "format", "png", "-Z", "800", "/System/Library/Desktop Pictures/Sonoma.heic", "--out", sample.path]
gen.standardOutput = FileHandle.nullDevice
try gen.run()
gen.waitUntilExit()
let sampleSize = (try? FileManager.default.attributesOfItem(atPath: sample.path)[.size] as? Int) ?? 0
t = Date()
let uploaded = try await client.upload(file: sample)
ok("上传 \(sample.lastPathComponent)（\(sampleSize / 1024) KB）用时 \(ms(since: t))，手机返回 \(uploaded?.name ?? "（非图片）")")
let newest = try await client.media(kind: .image, offset: 0, limit: 3)
guard newest.items.first?.name == uploaded?.name else { fail("上传的图片没有出现在「最近照片」第一位") }
ok("「最近照片」第一张就是刚发过去的图片")

// ⑧ 短信验证码识别
step("短信验证码识别")
let samples: [(String, String?)] = [
    ("【招商银行】您的验证码为 482913，5分钟内有效，请勿泄露。", "482913"),
    ("【淘宝】验证码：7731，用于身份验证，10分钟内有效。", "7731"),
    ("您正在支付1000元，动态码 835120，切勿告知他人。", "835120"),
    ("G-583201 is your Google verification code.", "583201"),
    ("Your Uber code is 4821. Never share this code.", "4821"),
    ("【京东】校验码 Ab3k9Q，请于5分钟内输入。", "Ab3k9Q"),
    ("您尾号6789的卡于10月22日消费128.00元。", nil),
    ("明天下午3点开会，会议室 2048。", nil),
]
for (text, expected) in samples {
    let got = VerificationCode.extract(from: text)
    guard got == expected else { fail("「\(text)」应识别为 \(expected ?? "无")，实际 \(got ?? "无")") }
}
ok("\(samples.count) 条样例全部识别正确（含 3 条干扰数字和 2 条非验证码短信）")

// ⑨ 拖拽内容判断（只拖文件夹时不弹面板）
step("拖拽内容判断")
let pb = NSPasteboard(name: NSPasteboard.Name("colorlink.test.\(UUID().uuidString)"))
func dragging(_ urls: [URL]) -> Bool {
    pb.clearContents()
    pb.writeObjects(urls as [NSURL])
    return DragContent.hasSendableContent(pb)
}
let folder = FileManager.default.temporaryDirectory
let appBundle = URL(fileURLWithPath: "/System/Applications/Calculator.app")
let cases: [(String, [URL], Bool)] = [
    ("只拖一个文件夹", [folder], false),
    ("只拖一个 .app", [appBundle], false),
    ("拖一个文件", [sample], true),
    ("文件夹和文件一起拖", [folder, sample], true),
]
for (name, urls, expected) in cases {
    guard dragging(urls) == expected else { fail("\(name)：应\(expected ? "" : "不")弹面板") }
}
pb.clearContents()
pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
guard DragContent.hasSendableContent(pb) else { fail("只有图片数据（浏览器拖图）时应弹面板") }
ok("\(cases.count + 1) 种情况全部正确：文件夹 / .app 不弹，文件、混合、纯图片数据会弹")

// ⑨-2 一次拖很多张：每个文件都在、只出现一次、顺序不变（曾经同一秒内的图片互相覆盖，导致重复和漏发）
step("一次拖 24 张图片 + 1 个文件夹")
let batchDir = FileManager.default.temporaryDirectory.appendingPathComponent("clcheck-drag-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
let photos = try (1...24).map { i -> URL in
    let url = batchDir.appendingPathComponent(String(format: "%02d_风景.jpg", i))
    try Data("photo \(i)".utf8).write(to: url)
    return url
}
pb.clearContents()
pb.writeObjects((photos + [batchDir, photos[3]]) as [NSURL])
let picked = DragContent.files(pb)
guard picked.map(\.lastPathComponent) == photos.map(\.lastPathComponent) else {
    fail("应得到 24 个不重复的文件，实际 \(picked.count) 个：\(picked.map(\.lastPathComponent))")
}
ok("24 个文件全部取到，没有重复，文件夹被跳过")

// 只有图片数据（浏览器拖图）：每张存成不同的文件，内容各不相同
let providers = (1...5).map { i -> NSItemProvider in
    let image = NSImage(size: NSSize(width: 10 * i, height: 10 * i), flipped: false) { r in
        NSColor(calibratedHue: CGFloat(i) / 6, saturation: 1, brightness: 1, alpha: 1).setFill()
        r.fill()
        return true
    }
    return NSItemProvider(object: image)
}
let saved = await DragContent.imageFiles(from: providers)
let contents = Set(saved.compactMap { try? Data(contentsOf: $0) })
guard saved.count == 5, Set(saved.map(\.path)).count == 5, contents.count == 5 else {
    fail("5 张图片数据应存成 5 个不同的文件，实际 \(saved.count) 个、内容不同的 \(contents.count) 个")
}
ok("5 张图片数据存成 5 个不同的文件：\(saved.map(\.lastPathComponent).joined(separator: "、"))")
try? FileManager.default.removeItem(at: batchDir)
saved.first.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
pb.releaseGlobally()

// ⑨-3 判断手机上的 ColorLink 是否在运行（Mac 连不上时用）
step("端口探测")
let probeOpen = await PortProbe.check(host: endpoint.host, port: endpoint.port)
let probeRefused = await PortProbe.check(host: "127.0.0.1", port: 9)
let probeAway = await PortProbe.check(host: "10.255.255.1", port: 8765, timeout: 1.5)
guard probeOpen == .open, probeRefused == .refused, probeAway == .unreachable else {
    fail("应为 通/拒绝/连不到，实际 \(probeOpen)/\(probeRefused)/\(probeAway)")
}
ok("手机端口在听 → 通；在线但没在运行 → 拒绝；不在网络里 → 连不到")

// ⑩ 事件流
step("事件流")
let events = client.events()
var iterator = events.makeAsyncIterator()
guard case .hello? = try await iterator.next() else { fail("没收到 hello") }
ok("收到 hello")

if doze {
    // 模拟手机不发 ping；事件流应在安静 45 秒后问一下手机，把它“叫醒”，之后照常收到 ping
    let stream = client.events()
    let broke = await withTaskGroup(of: String?.self) { g in
        g.addTask {
            do { for try await _ in stream {} ; return "连接被关闭" } catch { return "\(error)" }
        }
        g.addTask { try? await Task.sleep(for: .seconds(150)); return nil }
        let first = await g.next() ?? nil
        g.cancelAll()
        return first
    }
    if let broke { fail("手机深睡时事件流断了：\(broke)") }
    ok("手机深睡 150 秒，事件流没有断")
}

if trigger {
    // 模拟手机的调试接口只接受本机请求，所以固定走 127.0.0.1
    let debugBase = PhoneEndpoint(host: "127.0.0.1", port: endpoint.port).baseURL
    var req = URLRequest(url: debugBase.appendingPathComponent("debug/screenshot"))
    req.httpMethod = "POST"
    let (_, r) = try await URLSession.shared.data(for: req)
    guard (r as? HTTPURLResponse)?.statusCode == 200 else { fail("触发模拟截图失败（--trigger 只能对本机的 mock_phone.py 使用）") }
    t = Date()
    while let ev = try await iterator.next() {
        if case .screenshot(let item) = ev {
            ok("收到截图事件 \(item.name)（\(ms(since: t))）")
            let url = try await client.download(item, to: AppDirs.downloads.appendingPathComponent("截图"))
            guard Clipboard.copy(url) else { fail("写入剪贴板失败") }
            let types = NSPasteboard.general.types ?? []
            ok("已写入剪贴板（\(types.contains(.png) ? "PNG" : "")\(types.contains(.tiff) ? " + TIFF" : "")），从截图到可粘贴共 \(ms(since: t))")
            break
        }
    }
    var nreq = URLRequest(url: debugBase.appendingPathComponent("debug/notify"))
    nreq.httpMethod = "POST"
    _ = try await URLSession.shared.data(for: nreq)
    t = Date()
    while let ev = try await iterator.next() {
        if case .notification(let n) = ev {
            let code = VerificationCode.extract(from: n.text)
            guard code != nil else { fail("短信事件里没识别出验证码：\(n.text)") }
            ok("收到短信事件（\(n.app)），识别出验证码 \(code!)（\(ms(since: t))）")
            break
        }
    }
} else {
    print("  （加 --trigger 可测试截图 → 剪贴板）")
}

print("\n全部通过 ✅")

enum Clipboard {
    static func copy(_ url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
}
