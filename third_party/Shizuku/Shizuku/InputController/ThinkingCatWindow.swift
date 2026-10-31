import Cocoa

/// llm-ime: 手を止めている間に続きを考えているとき、カーソルの右に出す小さな印。
/// 猫の肉球がふみふみと潰れ（ぷにぷに）、横でしずくが 3 つ順に跳ねる（Shizuku の「しずく」）。
/// 文書には何も入れず、マウス操作も受け取らない。「視差効果を減らす」がオンなら動かさない
final class ThinkingCatWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class PawView: NSView {
        private let paw = CALayer()
        private var drops: [CAShapeLayer] = []
        private(set) var size: CGFloat = 0

        override var isFlipped: Bool { false }

        override init(frame: NSRect) {
            super.init(frame: frame)
            self.wantsLayer = true
            self.layer?.addSublayer(self.paw)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// 肉球の大きさ s で並べ直す（肉球は左、しずくは右に並ぶ。ビューの大きさは width(for:)・height(for:)）
        func layout(size s: CGFloat, scale: CGFloat) {
            guard s != self.size else { return }
            self.size = s
            self.paw.sublayers?.forEach { $0.removeFromSuperlayer() }
            self.drops.forEach { $0.removeFromSuperlayer() }
            self.drops = []

            // 潰れるときは下の端を支点にする（机に押しつけるように）
            self.paw.anchorPoint = CGPoint(x: 0.5, y: 0.08)
            self.paw.bounds = CGRect(x: 0, y: 0, width: s, height: s)
            self.paw.position = CGPoint(x: s * 0.08 + s / 2, y: s * 0.12 + s * 0.08)
            self.paw.contentsScale = scale

            let palm = CAShapeLayer()
            palm.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s * 0.96), transform: nil)
            palm.fillColor = CGColor(red: 1, green: 0.99, blue: 0.97, alpha: 1)
            palm.strokeColor = CGColor(gray: 0, alpha: 0.11)
            palm.lineWidth = max(1, s / 22)
            palm.shadowColor = CGColor(gray: 0, alpha: 1)
            palm.shadowOpacity = 0.14
            palm.shadowRadius = s / 14
            palm.shadowOffset = CGSize(width: 0, height: -s / 28)
            self.paw.addSublayer(palm)

            let bean = CGColor(red: 0.98, green: 0.62, blue: 0.71, alpha: 1)
            let beans = CGMutablePath()
            // 大きい肉球（下が少し広いおにぎり形を、楕円 2 つで作る）
            beans.addEllipse(in: CGRect(x: s * 0.27, y: s * 0.13, width: s * 0.46, height: s * 0.36))
            beans.addEllipse(in: CGRect(x: s * 0.33, y: s * 0.26, width: s * 0.34, height: s * 0.3))
            // 指の肉球 4 つ（外側の 2 つは少し低く）
            for (x, y) in [(0.13, 0.5), (0.31, 0.65), (0.53, 0.65), (0.71, 0.5)] {
                beans.addEllipse(in: CGRect(x: s * x, y: s * y, width: s * 0.16, height: s * 0.2))
            }
            let pads = CAShapeLayer()
            pads.path = beans
            pads.fillColor = bean
            self.paw.addSublayer(pads)

            // しずく 3 つ（「…」の代わり）
            let w = s * 0.28, h = s * 0.4
            for i in 0..<3 {
                let drop = CAShapeLayer()
                drop.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                drop.position = CGPoint(x: s * 1.3 + CGFloat(i) * w * 1.35, y: s * 0.2 + h / 2)
                drop.path = Self.dropPath(width: w, height: h)
                drop.fillColor = CGColor(red: 0.33, green: 0.67, blue: 0.93, alpha: 1)
                drop.contentsScale = scale
                let shine = CAShapeLayer()
                shine.path = CGPath(ellipseIn: CGRect(x: w * 0.24, y: h * 0.22, width: w * 0.22, height: h * 0.18), transform: nil)
                shine.fillColor = CGColor(gray: 1, alpha: 0.75)
                drop.addSublayer(shine)
                self.layer?.addSublayer(drop)
                self.drops.append(drop)
            }
        }

        static func width(for s: CGFloat) -> CGFloat { s * 1.3 + s * 0.28 * (1 + 2 * 1.35) + s * 0.1 }
        static func height(for s: CGFloat) -> CGFloat { s * 1.4 }

        /// 上がとがったしずくの形（下は半円）
        private static func dropPath(width w: CGFloat, height h: CGFloat) -> CGPath {
            let r = w / 2, cx = w / 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: h))
            path.addCurve(to: CGPoint(x: w, y: r), control1: CGPoint(x: cx + r * 0.25, y: h - h * 0.22), control2: CGPoint(x: w, y: r * 1.7))
            path.addArc(center: CGPoint(x: cx, y: r), radius: r, startAngle: 0, endAngle: .pi, clockwise: true)
            path.addCurve(to: CGPoint(x: cx, y: h), control1: CGPoint(x: 0, y: r * 1.7), control2: CGPoint(x: cx - r * 0.25, y: h - h * 0.22))
            path.closeSubpath()
            return path
        }

        func startAnimating() {
            self.stopAnimating()
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let s = self.size
            // ぷにっと潰れて戻る（ふみふみ）
            let squish = CAKeyframeAnimation(keyPath: "transform.scale.y")
            squish.values = [1, 0.84, 1.06, 0.98, 1]
            squish.keyTimes = [0, 0.22, 0.5, 0.72, 1]
            squish.duration = 0.62
            squish.repeatCount = .infinity
            squish.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
            let spread = squish.copy() as! CAKeyframeAnimation
            spread.keyPath = "transform.scale.x"
            spread.values = [1, 1.1, 0.96, 1.01, 1]
            // 左右の手を交互に押すように、少しだけ傾ける
            let knead = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            knead.values = [-0.09, 0.09, -0.09]
            knead.duration = 1.24
            knead.repeatCount = .infinity
            knead.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 2)
            self.paw.add(squish, forKey: "squish")
            self.paw.add(spread, forKey: "spread")
            self.paw.add(knead, forKey: "knead")

            let now = CACurrentMediaTime()
            for (i, drop) in self.drops.enumerated() {
                let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
                hop.values = [0, s * 0.34, 0, 0]
                hop.keyTimes = [0, 0.18, 0.36, 1]
                hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .linear)]
                let glow = CAKeyframeAnimation(keyPath: "opacity")
                glow.values = [0.6, 1, 0.8, 0.6]
                glow.keyTimes = [0, 0.18, 0.36, 1]
                let group = CAAnimationGroup()
                group.animations = [hop, glow]
                group.duration = 1.2
                group.repeatCount = .infinity
                group.beginTime = now + Double(i) * 0.18
                group.fillMode = .backwards
                drop.add(group, forKey: "hop")
            }
        }

        func stopAnimating() {
            self.paw.removeAllAnimations()
            self.drops.forEach { $0.removeAllAnimations() }
        }
    }

    private let pawView = PawView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        self.contentView = self.pawView
    }

    /// 画面座標のカーソル（caretX）と行（lineRect）の右に出す。行の高さに合わせた大きさにする
    func show(caretX: CGFloat, lineRect: NSRect) {
        let s = floor(max(14, min(lineRect.height * 0.86, 26)))
        let width = PawView.width(for: s), height = PawView.height(for: s)
        let scale = NSScreen.screens.first { $0.frame.contains(NSPoint(x: caretX, y: lineRect.midY)) }?.backingScaleFactor ?? 2
        self.pawView.layout(size: s, scale: scale)
        self.setFrame(NSRect(x: caretX + 3, y: lineRect.midY - height * 0.42, width: width, height: height), display: false)
        if !self.isVisible {
            self.alphaValue = 0
            self.orderFront(nil)
            self.pawView.startAnimating()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard self.isVisible else { return }
        self.pawView.stopAnimating()
        self.alphaValue = 1
        self.orderOut(nil)
    }
}
