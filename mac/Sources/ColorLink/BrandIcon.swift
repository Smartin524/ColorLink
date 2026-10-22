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

    /// connected=false 时整体变淡，表示没连上
    static func statusImage(connected: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // 链环旋转后约占 1024 画布的 76%，再留一点边距
            let content: CGFloat = 860
            let s = rect.width / content
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: content / 2, y: content / 2)
            ctx.rotate(by: -.pi / 4)
            ctx.translateBy(x: -512, y: -512)

            let a = capsulePath(left), b = capsulePath(right)
            ctx.setAlpha(connected ? 1 : 0.4)
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
