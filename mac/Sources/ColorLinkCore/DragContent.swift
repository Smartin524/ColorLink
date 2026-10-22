import AppKit
import UniformTypeIdentifiers

public enum DragContent {
    /// 拖的东西里有没有能发给手机的：普通文件或图片数据。只拖了文件夹（包括 .app 这类包）就不弹面板，
    /// 因为文件夹不会被发送。
    public static func hasSendableContent(_ pb: NSPasteboard) -> Bool {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            return urls.contains { url in
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return v?.isDirectory != true && v?.isPackage != true
            }
        }
        // 没有文件，只有图片数据（例如从浏览器拖图片）
        let imageTypes: Set<NSPasteboard.PasteboardType> = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
        return (pb.types ?? []).contains(where: imageTypes.contains)
    }

    /// 拖进来的普通文件，按拖的顺序、去掉重复；文件夹和 .app 这类包跳过。
    ///
    /// 直接读系统的拖拽剪贴板：从 Finder 拖的每个文件都在这里，路径准确。
    /// （SwiftUI 交给 onDrop 的 NSItemProvider 会把图片文件当成“图片”而不是“文件”，取不到路径。）
    public static func files(_ pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var seen = Set<String>()
        return urls.filter { url in
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory != true && v?.isPackage != true && seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    /// 没有文件、只有图片数据时（从浏览器、「照片」等处拖图）：每张存成一个临时文件再发。
    /// 尽量保留原格式和原名；每次拖放用单独的临时文件夹，文件名各不相同，不会互相覆盖。
    public static func imageFiles(from providers: [NSItemProvider]) async -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ColorLink-drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .dateSeparator(.omitted).timeSeparator(.omitted))
        var urls: [URL] = []
        for (i, p) in providers.enumerated() {
            guard let (data, ext) = await imageData(p) else { continue }
            let base = p.suggestedName.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Mac 图片 \(stamp)-\(i + 1)"
            var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
                n += 1
            }
            if (try? data.write(to: url)) != nil { urls.append(url) }
        }
        return urls
    }

    /// 原始图片数据和扩展名：优先原格式（JPEG、PNG、HEIC…），实在不行再转成 PNG
    private static func imageData(_ p: NSItemProvider) async -> (Data, String)? {
        let original = p.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: .image) }
        if let type = original, let data = await loadData(p, type), !data.isEmpty {
            return (data, type.preferredFilenameExtension ?? "png")
        }
        guard p.canLoadObject(ofClass: NSImage.self) else { return nil }
        let image: NSImage? = await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in cont.resume(returning: obj as? NSImage) }
        }
        guard let tiff = image?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png")
    }

    private static func loadData(_ p: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { cont in
            _ = p.loadDataRepresentation(for: type) { data, _ in cont.resume(returning: data) }
        }
    }
}
