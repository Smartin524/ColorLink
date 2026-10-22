import AppKit

/// ColorLink 链环标志的单色模板图标，给状态栏用（系统会按明暗模式自动着色）。
/// 几何和 tools/make-icons.swift 一致：两个圆角胶囊旋转 45° 扣在一起，交叉处一上一下挖出细缝。
enum BrandIcon {
    private static let capsule = CGSize(width: 440, height: 240)
    private static let left = CGPoint(x: 352, y: 512)
    private static let right = CGPoint(x: 672, y: 512)
    /// 状态栏尺寸很小，线条比彩色版略粗一些更清晰
    private static let stroke: CGFloat = 72
    private static let gap: CGFloat = 30
    private static let crossingRadius: CGFloat = 92

    /// connected=false 时画断开的姿态：两个环解扣、一低一高散开（和手机首页 LinkLogoView 的断开姿态一致，不播动画）
    static func statusImage(connected: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            guard connected else {
                drawApart(ctx, in: rect)
                return true
            }
            // 链环旋转后约占 1024 画布的 76%，再留一点边距
            let content: CGFloat = 860
            let s = rect.width / content
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: content / 2, y: content / 2)
            ctx.rotate(by: -.pi / 4)
            ctx.translateBy(x: -512, y: -512)

            let a = capsulePath(left), b = capsulePath(right)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            // 右环：上方交叉点被左环压住
            layer(ctx, draw: b, cutAlong: a, at: 408)
            // 左环：下方交叉点被右环压住
            layer(ctx, draw: a, cutAlong: b, at: 616)
            ctx.endTransparencyLayer()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = connected ? "ColorLink 已连接" : "ColorLink 未连接"
        return image
    }

    /// 断开姿态（相对标志中心，1024 单位）：左环留在左下转到 -55°，右环留在右上几乎竖直（-100°）
    private static let apartPoses: [(cx: CGFloat, x: CGFloat, y: CGFloat, degrees: CGFloat)] = [
        (352, -185, 100, -55),
        (672, 190, -105, -100),
    ]

    private static func drawApart(_ ctx: CGContext, in rect: CGRect) {
        let rings = apartPoses.map { p -> CGPath in
            var t = CGAffineTransform(translationX: p.x, y: p.y)
                .rotated(by: p.degrees * .pi / 180)
                .translatedBy(x: -p.cx, y: -512)
            return capsulePath(CGPoint(x: p.cx, y: 512)).copy(using: &t)!
        }
        // 环的大小和扣合时一样；散开后外形更大，放不下时才整体缩小，按实际外框居中
        let bounds = rings.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }.insetBy(dx: -stroke / 2, dy: -stroke / 2)
        let s = min(rect.width / 860, rect.width / max(bounds.width, bounds.height))
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -bounds.midX, y: -bounds.midY)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(stroke)
        rings.forEach { ctx.addPath($0) }
        ctx.strokePath()
    }

    private static func layer(_ ctx: CGContext, draw path: CGPath, cutAlong other: CGPath, at y: CGFloat) {
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(stroke)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 512 - crossingRadius, y: y - crossingRadius,
                                  width: crossingRadius * 2, height: crossingRadius * 2))
        ctx.clip()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(stroke + gap * 2)
        ctx.addPath(other)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.endTransparencyLayer()
    }

    private static func capsulePath(_ c: CGPoint) -> CGPath {
        let r = capsule.height / 2
        return CGPath(roundedRect: CGRect(x: c.x - capsule.width / 2, y: c.y - r, width: capsule.width, height: capsule.height),
                      cornerWidth: r, cornerHeight: r, transform: nil)
    }
}
