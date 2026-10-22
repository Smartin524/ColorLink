import AppKit

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
}
