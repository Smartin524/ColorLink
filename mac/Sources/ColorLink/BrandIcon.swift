import AppKit

/// ColorLink 的双丝带标志（来自 design/icon/前景.svg），画成状态栏用的单色模板图标。
/// 状态栏图标必须是单色的，系统会按明暗模式自动着色；两条丝带用不同的不透明度区分，保留交叠的感觉。
enum BrandIcon {
    // 前景.svg 里的两条路径（1024 画布），外层有 translate(512 510) scale(1.16) translate(-512 -510)
    private static let rightRibbon = "M408 222 H615 C644 222 670 238 686 266 L802 466 C819 495 819 524 802 554 L686 754 C670 782 644 798 615 798 H408 C437 798 465 782 481 754 L593 558 C610 529 610 494 593 465 L512 325 L545 267 C561 239 588 222 615 222 Z"
    private static let leftRibbon = "M408 222 C378 222 352 238 336 266 L222 465 C206 494 206 525 222 554 L336 754 C352 782 378 798 408 798 C438 798 465 782 481 754 L512 696 L431 556 C415 528 415 496 431 467 L545 267 C562 238 588 222 615 222 Z"

    /// connected=false 时整体变淡，表示没连上
    static func statusImage(connected: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // 丝带放大后约占 676×668（x 176～848、y 176～844），四周再留些边距，和系统状态栏图标的视觉大小一致
            let content: CGFloat = 780
            let s = rect.width / content
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -(512 - content / 2), y: -(510 - content / 2))
            ctx.translateBy(x: 512, y: 510)
            ctx.scaleBy(x: 1.16, y: 1.16)
            ctx.translateBy(x: -512, y: -510)
            // 两条丝带都用实色；在左丝带边缘切一道细缝表现穿插，不用半透明（半亮半暗看着不协调）
            ctx.setAlpha(connected ? 1 : 0.4) // 断开时整体变淡
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.black.setFill()
            path(rightRibbon).fill()
            let gap = path(leftRibbon)
            gap.lineWidth = 46
            ctx.setBlendMode(.clear)
            gap.stroke()
            ctx.setBlendMode(.normal)
            path(leftRibbon).fill()
            ctx.endTransparencyLayer()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = connected ? "ColorLink 已连接" : "ColorLink 未连接"
        return image
    }

    /// 只支持这两条路径用到的绝对坐标命令：M、L、H、C、Z
    private static func path(_ d: String) -> NSBezierPath {
        let p = NSBezierPath()
        // SVG 里命令字母和数字可以连写（如 "M408"），按“字母或数字”逐个拆出来
        let regex = try! NSRegularExpression(pattern: "[MLHCZ]|-?[0-9]*\\.?[0-9]+")
        let ns = d as NSString
        var tokens = regex.matches(in: d, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }[...]
        var current = NSPoint.zero
        func num() -> CGFloat { CGFloat(Double(tokens.popFirst() ?? "0") ?? 0) }
        while let t = tokens.popFirst() {
            switch t {
            case "M": current = NSPoint(x: num(), y: num()); p.move(to: current)
            case "L": current = NSPoint(x: num(), y: num()); p.line(to: current)
            case "H": current = NSPoint(x: num(), y: current.y); p.line(to: current)
            case "C":
                let c1 = NSPoint(x: num(), y: num()), c2 = NSPoint(x: num(), y: num())
                current = NSPoint(x: num(), y: num())
                p.curve(to: current, controlPoint1: c1, controlPoint2: c2)
            case "Z": p.close()
            default: break
            }
        }
        return p
    }
}
