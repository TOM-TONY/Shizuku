import Cocoa

/// llm-ime: 文章の続き予測を、入力中の文字の後ろに薄い灰色で重ねて表示する透明なウィンドウ
/// （VS Code のインライン補完のような見た目）。文書には何も入れないので、アプリが未確定文字を
/// そのまま確定してしまう場合でも予測が混ざらない。マウス操作は受け取らない。
final class GhostTextWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class TextView: NSView {
        /// 各行の文字列と、ビュー内での x 位置（1 行目はカーソル、2 行目以降は行頭）
        var lines: [(text: String, x: CGFloat)] = []
        var lineHeight: CGFloat = 16
        var font = NSFont.systemFont(ofSize: 13)

        override var isFlipped: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: self.font,
                // 補足的な文字と同じ灰色（ダークモードでも読める濃さ）
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            for (i, line) in self.lines.enumerated() {
                let size = (line.text as NSString).size(withAttributes: attributes)
                // 上から i 行目。行の高さの中で縦方向の中央にそろえる
                let top = self.bounds.height - self.lineHeight * CGFloat(i + 1)
                (line.text as NSString).draw(at: NSPoint(x: line.x, y: top + (self.lineHeight - size.height) / 2), withAttributes: attributes)
            }
        }
    }

    private let textView = TextView()

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
        self.contentView = self.textView
    }

    /// システムフォント（日本語はヒラギノで描かれる）での文字列の幅
    static func width(of text: String, fontSize: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
    }

    /// 画面座標で、行の左下 origin・行の高さ lineHeight の位置から text を描く
    func show(text: String, at origin: NSPoint, lineHeight: CGFloat, fontSize: CGFloat) {
        self.show(text: text, caretX: origin.x, lineRect: NSRect(x: origin.x, y: origin.y, width: 1, height: lineHeight),
                  lineStartX: origin.x, fontSize: fontSize)
    }

    /// 行を右端 rightEdge で折り返す（1 行目は firstX から、以降は lineStartX から。1 文字ずつ幅を測る）
    static func wrap(_ text: String, firstX: CGFloat, lineStartX: CGFloat, rightEdge: CGFloat?, fontSize: CGFloat) -> [String] {
        var result: [String] = []
        for (index, paragraph) in text.components(separatedBy: "\n").enumerated() {
            guard let rightEdge else {
                result.append(paragraph)
                continue
            }
            var startX = index == 0 ? firstX : lineStartX
            var line = ""
            for ch in paragraph {
                let candidate = line + String(ch)
                if startX + Self.width(of: candidate, fontSize: fontSize) > rightEdge, !line.isEmpty || startX > lineStartX {
                    result.append(line)
                    line = String(ch)
                    startX = lineStartX
                } else {
                    line = candidate
                }
            }
            result.append(line)
        }
        return result
    }

    /// 改行を含む text を描く。1 行目はカーソル（caretX）から、2 行目以降は行頭（lineStartX）から下の行へ。
    /// rightEdge があれば、そこで折り返す（アプリのウィンドウからはみ出さないように）
    func show(text: String, caretX: CGFloat, lineRect: NSRect, lineStartX: CGFloat, fontSize: CGFloat, rightEdge: CGFloat? = nil) {
        let lines = Self.wrap(text, firstX: caretX, lineStartX: lineStartX, rightEdge: rightEdge, fontSize: fontSize)
        let lineHeight = max(lineRect.height, fontSize * 1.3)
        let starts = lines.indices.map { $0 == 0 ? caretX : lineStartX }
        let minX = starts.min() ?? caretX
        let maxX = zip(lines, starts).map { $1 + Self.width(of: $0, fontSize: fontSize) }.max() ?? caretX
        let height = lineHeight * CGFloat(lines.count)
        self.textView.font = NSFont.systemFont(ofSize: fontSize)
        self.textView.lineHeight = lineHeight
        self.textView.lines = zip(lines, starts).map { ($0, $1 - minX) }
        self.setFrame(
            NSRect(x: minX, y: lineRect.minY - lineHeight * CGFloat(lines.count - 1), width: ceil(maxX - minX) + 2, height: height),
            display: false
        )
        self.textView.needsDisplay = true
        self.orderFront(nil)
    }

    func hide() {
        if self.isVisible {
            self.orderOut(nil)
        }
    }
}
