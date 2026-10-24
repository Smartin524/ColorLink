// ColorLink 图标：两个圆角胶囊斜扣在一起（链环）。上方交叉处蓝环压青环，下方反过来，形成真正的穿插。
//
//   swift tools/make-icons.swift
//
// 生成：
//   design/icon/ColorLink-日间-1024.png、ColorLink-暗色-1024.png   预览 / 设计稿
//   mac/Resources/AppIcon.icon/Assets/Link.png                     macOS 图标的链环图层（底色在 icon.json）
//   android/app/src/main/res/drawable-*dpi/ic_launcher_foreground.png  自适应图标前景（透明）
//
// 造型参数都在 Logo 里，Mac 状态栏（BrandIcon.swift）、通知栏（ic_link.xml）和手机首页动画（LinkLogoView.kt）用的是同一组几何。
import AppKit

enum Logo {
    // 1024 画布里的几何（旋转前）
    static let center = CGPoint(x: 512, y: 512)
    static let angle: CGFloat = -45 * .pi / 180
    static let capsule = CGSize(width: 440, height: 240)
    static let left = CGPoint(x: 352, y: 512)
    static let right = CGPoint(x: 672, y: 512)
    static let stroke: CGFloat = 56
    static let gap: CGFloat = 22 // 交叉处的细缝
    /// 旋转后链环占画布的大致比例（用于缩放）
    static let extent: CGFloat = 0.74

    static let blue = [NSColor(hex: 0x2EAEFC), NSColor(hex: 0x006DFF), NSColor(hex: 0x0042CB)]
    static let cyan = [NSColor(hex: 0x6FEFFA), NSColor(hex: 0x00CEF0), NSColor(hex: 0x00A6E2)]

    static func capsulePath(_ c: CGPoint) -> CGPath {
        let r = capsule.height / 2
        let rect = CGRect(x: c.x - capsule.width / 2, y: c.y - r, width: capsule.width, height: capsule.height)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// 在 ctx 里画链环；ctx 已经缩放到 1024 坐标系（y 向下）
    static func draw(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        ctx.translateBy(x: -center.x, y: -center.y)

        let a = capsulePath(left), b = capsulePath(right)
        // 两条圆弧的交叉点：x = 512，上方 y ≈ 408，下方 y ≈ 616（圆心距 120、半径 120，夹角 60°）。
        // 每个环单独一层，只在自己“被压住”的那个交叉点挖空，再叠起来：不重画，就没有接缝
        let top = crossing(y: 408), bottom = crossing(y: 616)

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // 青环：上方交叉点被蓝环压住
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        strokeGradient(ctx, b, cyan)
        cut(ctx, a, clip: top)
        ctx.endTransparencyLayer()
        // 蓝环：下方交叉点被青环压住
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        strokeGradient(ctx, a, blue)
        cut(ctx, b, clip: bottom)
        ctx.endTransparencyLayer()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static let crossingRadius: CGFloat = 92

    static func crossing(y: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: 512 - crossingRadius, y: y - crossingRadius,
                                 width: crossingRadius * 2, height: crossingRadius * 2), transform: nil)
    }

    static func cut(_ ctx: CGContext, _ path: CGPath, clip: CGPath) {
        clipped(ctx, clip) {
            ctx.setBlendMode(.clear)
            ctx.addPath(path)
            ctx.setLineWidth(stroke + gap * 2)
            ctx.strokePath()
            ctx.setBlendMode(.normal)
        }
    }

    static func clipped(_ ctx: CGContext, _ region: CGPath, _ body: () -> Void) {
        ctx.saveGState()
        ctx.addPath(region)
        ctx.clip()
        body()
        ctx.restoreGState()
    }

    static func strokeGradient(_ ctx: CGContext, _ path: CGPath, _ colors: [NSColor]) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(stroke)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let box = path.boundingBox.insetBy(dx: -stroke, dy: -stroke)
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY), options: [])
        ctx.restoreGState()
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 画一张 px×px 的图；logoScale 是链环相对 1024 画布的缩放
func render(px: Int, background: ((CGContext, CGFloat) -> Void)?, logoScale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ns
    let ctx = ns.cgContext
    let side = CGFloat(px)
    // 翻转成 y 向下，和设计坐标一致
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)
    background?(ctx, side)
    ctx.translateBy(x: side / 2, y: side / 2)
    ctx.scaleBy(x: side / 1024 * logoScale, y: side / 1024 * logoScale)
    ctx.translateBy(x: -512, y: -512)
    Logo.draw(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func roundedBackground(top: UInt32, bottom: UInt32) -> (CGContext, CGFloat) -> Void {
    { ctx, side in
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil))
        ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [NSColor(hex: top).cgColor, NSColor(hex: bottom).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: side), options: [])
        ctx.restoreGState()
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func write(_ data: Data, _ path: String) {
    let url = root.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
    print("已生成 \(path)")
}

// 设计稿（铺满的圆角方形）：日间白底、暗色灰黑渐变（与「跳过」「看打车进度」一致）
write(render(px: 1024, background: roundedBackground(top: 0xFFFFFF, bottom: 0xF1F4F8), logoScale: 0.86),
      "design/icon/ColorLink-日间-1024.png")
write(render(px: 1024, background: roundedBackground(top: 0x383839, bottom: 0x121213), logoScale: 0.86),
      "design/icon/ColorLink-暗色-1024.png")

// macOS 26 图标（Icon Composer 格式，build-app.sh 用 actool 编译）的链环图层：透明底，链环外框占 1024 画布约 68%。
// 底色在 AppIcon.icon/icon.json 里按日间 / 暗色分别设置，系统据此切换，也能自动生成「着色」「透明」样式
write(render(px: 1024, background: nil, logoScale: 0.77 / Logo.extent), "mac/Resources/AppIcon.icon/Assets/Link.png")

// 安卓自适应图标前景：108dp 画布，桌面只露出中间约 72dp。链环外框占画布约 50%、可见区域约 74%，
// 和系统图标的图形一样饱满；斜着的两端刚好落在 66dp 的圆形安全区以内，圆形遮罩的桌面也不会削到
let densities = ["mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432]
for (name, px) in densities {
    write(render(px: px, background: nil, logoScale: 0.56 / Logo.extent),
          "android/app/src/main/res/drawable-\(name)/ic_launcher_foreground.png")
}
