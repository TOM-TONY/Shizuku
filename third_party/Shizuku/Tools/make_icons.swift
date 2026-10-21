// Shizuku のアイコンを描き出す（App アイコンと、入力メニューのテンプレートアイコン）
//
//   swift Tools/make_icons.swift Shizuku
//
// - Assets.xcassets/AppIcon.appiconset/{16,32,64,128,256,512,1024}.png
// - main.tiff / main@2x.tiff（日本語: 雫）、en.tiff / en@2x.tiff（英字: A）
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Shizuku")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// 雫の形（y は上向き）。円の中心 `center`・半径 `r`、先端は中心から `tip * r` 上
func dropPath(center: CGPoint, r: CGFloat, tip: CGFloat = 1.8) -> CGPath {
    let path = CGMutablePath()
    let top = CGPoint(x: center.x, y: center.y + tip * r)
    let alpha = acos(1 / tip)  // 先端からの接点の、真上からの角度
    let right = CGPoint(x: center.x + r * sin(alpha), y: center.y + r * cos(alpha))
    let left = CGPoint(x: center.x - r * sin(alpha), y: center.y + r * cos(alpha))
    // 先端から接点までを少し外へふくらませる
    func bulge(_ from: CGPoint, _ to: CGPoint, _ side: CGFloat) -> CGPoint {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let dx = to.x - from.x, dy = to.y - from.y
        let len = hypot(dx, dy)
        return CGPoint(x: mid.x + side * dy / len * r * 0.1, y: mid.y - side * dx / len * r * 0.1)
    }
    path.move(to: top)
    path.addQuadCurve(to: right, control: bulge(top, right, -1))
    path.addArc(center: center, radius: r, startAngle: .pi / 2 - alpha, endAngle: .pi / 2 + alpha, clockwise: true)
    path.addQuadCurve(to: top, control: bulge(left, top, -1))
    path.closeSubpath()
    return path
}

/// `canvas` の座標で描いたものを `width`x`height` ピクセルに描き出す。`pointSize` は画像の論理サイズ
func bitmap(width: Int, height: Int, canvas: NSSize, pointSize: NSSize, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: width, height: height))
    cg.scaleBy(x: CGFloat(width) / canvas.width, y: CGFloat(height) / canvas.height)
    draw(cg)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    rep.size = pointSize
    return rep
}

// MARK: - App アイコン（1024 の格子: 824 角の角丸四角形を中央に）

func drawAppIcon(_ cg: CGContext) {
    let s: CGFloat = 1024
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // 台の影
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x0B2A4A, 0.28))
    cg.addPath(platePath)
    cg.setFillColor(color(0xFFFFFF))
    cg.fillPath()
    cg.restoreGState()

    // 台: 上は白に近い水色、下は少し深い水色
    cg.saveGState()
    cg.addPath(platePath)
    cg.clip()
    let plateGradient = CGGradient(colorsSpace: space, colors: [color(0xF7FBFF), color(0xD3E8FA)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(plateGradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])

    // 水面の波紋
    let rippleCenter = CGPoint(x: s / 2, y: 262)
    for (index, scale) in [CGFloat(1.0), 1.55, 2.15].enumerated() {
        let rect = CGRect(x: rippleCenter.x - 150 * scale, y: rippleCenter.y - 34 * scale, width: 300 * scale, height: 68 * scale)
        cg.addEllipse(in: rect)
        cg.setStrokeColor(color(0x3E8EDB, 0.30 - CGFloat(index) * 0.08))
        cg.setLineWidth(10 - CGFloat(index) * 2)
        cg.strokePath()
    }
    cg.restoreGState()

    // 雫
    let drop = dropPath(center: CGPoint(x: s / 2, y: 452), r: 178, tip: 1.95)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: color(0x0F4C9A, 0.35))
    cg.addPath(drop)
    cg.setFillColor(color(0x2A7DE1))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(drop)
    cg.clip()
    let dropGradient = CGGradient(
        colorsSpace: space,
        colors: [color(0x8FD3FF), color(0x3B95F0), color(0x1458C4)] as CFArray,
        locations: [0, 0.5, 1]
    )!
    cg.drawLinearGradient(dropGradient, start: CGPoint(x: 400, y: 800), end: CGPoint(x: 620, y: 280), options: [])
    // 内側の照り返し（下の縁を明るく）
    let glow = CGGradient(colorsSpace: space, colors: [color(0xB8E6FF, 0.55), color(0xB8E6FF, 0)] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 560, y: 300), startRadius: 0, endCenter: CGPoint(x: 560, y: 300), endRadius: 150, options: [])
    cg.restoreGState()

    // ハイライト
    cg.saveGState()
    let highlight = CGMutablePath()
    highlight.addEllipse(in: CGRect(x: -34, y: -78, width: 68, height: 156))
    var transform = CGAffineTransform(translationX: 432, y: 520).rotated(by: 0.42)
    cg.addPath(highlight.copy(using: &transform)!)
    cg.setFillColor(color(0xFFFFFF, 0.78))
    cg.fillPath()
    cg.addEllipse(in: CGRect(x: 470, y: 642, width: 30, height: 30))
    cg.setFillColor(color(0xFFFFFF, 0.6))
    cg.fillPath()
    cg.restoreGState()
}

let iconDirectory = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = bitmap(
        width: size, height: size,
        canvas: NSSize(width: 1024, height: 1024), pointSize: NSSize(width: size, height: size),
        draw: drawAppIcon
    )
    try! rep.representation(using: .png, properties: [:])!.write(to: iconDirectory.appendingPathComponent("\(size).png"))
}

// MARK: - 入力メニューのアイコン（22x16 pt、黒一色のテンプレート）

func drawJapaneseModeIcon(_ cg: CGContext) {
    cg.addPath(dropPath(center: CGPoint(x: 11, y: 5.6), r: 4.6, tip: 1.95))
    cg.setFillColor(color(0x000000))
    cg.fillPath()
}

func drawEnglishModeIcon(_ cg: CGContext) {
    let base = NSFont.systemFont(ofSize: 15, weight: .bold)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 15) ?? base
    let text = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: NSColor.black])
    let bounds = text.boundingRect(with: NSSize(width: 22, height: 16), options: [.usesDeviceMetrics])
    text.draw(at: NSPoint(x: (22 - bounds.width) / 2 - bounds.minX, y: (16 - bounds.height) / 2 - bounds.minY))
}

for (name, draw) in [("main", drawJapaneseModeIcon), ("en", drawEnglishModeIcon)] {
    for scale in [1, 2] {
        let rep = bitmap(
            width: 22 * scale, height: 16 * scale,
            canvas: NSSize(width: 22, height: 16), pointSize: NSSize(width: 22, height: 16),
            draw: draw
        )
        let file = scale == 1 ? "\(name).tiff" : "\(name)@2x.tiff"
        try! rep.tiffRepresentation!.write(to: root.appendingPathComponent(file))
    }
}
print("ok")
