import Cocoa
import Core

/// llm-ime: 文章の続き予測を、予測変換の候補のように入力位置の下の小さなウィンドウに表示する。
///
/// 灰色の文字を入力中の文字の後ろに重ねる表示（GhostTextWindow）は、末尾の位置や文字の大きさを返さないアプリで
/// ずれることがある。こちらは候補ウィンドウと同じく、どのアプリでも正しく取れる「入力中の文字の先頭の行」を基準に置く。
/// マウス操作は受け取らない（Tab で入れる）。
final class CompletionPopupWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static let fontSize: CGFloat = 15
    private static let maxTextWidth: CGFloat = 440
    private static let padding = NSSize(width: 10, height: 7)

    private let background = NSVisualEffectView()
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let hintField = NSTextField(labelWithString: "Tab")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        // 候補ウィンドウと同じ背景
        self.background.material = .windowBackground
        self.background.blendingMode = .behindWindow
        self.background.state = .active
        self.background.wantsLayer = true
        self.background.layer?.cornerRadius = 10
        self.background.layer?.masksToBounds = true
        self.contentView = self.background

        self.textField.font = NSFont.systemFont(ofSize: Self.fontSize)
        self.textField.textColor = .labelColor
        self.textField.maximumNumberOfLines = 0
        self.textField.lineBreakMode = .byCharWrapping
        self.textField.cell?.wraps = true
        self.background.addSubview(self.textField)

        self.hintField.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        self.hintField.textColor = .secondaryLabelColor
        self.hintField.alignment = .center
        self.hintField.wantsLayer = true
        self.hintField.layer?.cornerRadius = 4
        self.hintField.layer?.borderWidth = 1
        self.hintField.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        self.background.addSubview(self.hintField)
    }

    /// 改行を ↵ で見せる（改行だけの続きでも何が入るか分かるように）。先頭の改行は 1 行目の頭に、途中の改行は行末に付ける
    static func displayText(_ text: String) -> String {
        var result = ""
        var pendingNewlines = 0
        for ch in text {
            if ch == "\n" {
                pendingNewlines += 1
                continue
            }
            if pendingNewlines > 0 {
                result += String(repeating: "↵", count: pendingNewlines) + (result.isEmpty ? " " : "\n")
                pendingNewlines = 0
            }
            result.append(ch)
        }
        if pendingNewlines > 0 {
            result += String(repeating: "↵", count: pendingNewlines)
        }
        return result
    }

    /// lineRect（画面座標の行。入力中の文字の先頭など）の下に、左端をそろえて出す。画面の下に入らないときや、
    /// avoiding のウィンドウ（候補ウィンドウなど）と重なるときは行の上に出す
    /// hint は右上の印（既定は Tab。画面の参考資料を使ったときは「Tab・画面」など）
    func show(text: String, lineRect: NSRect, avoiding others: [NSWindow] = [], rawLines: Bool = false, attributed: NSAttributedString? = nil,
              hint: String = "Tab") {
        if let attributed { self.textField.attributedStringValue = attributed }
        else { self.textField.stringValue = rawLines ? text : Self.displayText(text) }
        self.hintField.stringValue = hint
        let textSize = self.textField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.maxTextWidth, height: 10_000))
            ?? NSSize(width: Self.maxTextWidth, height: Self.fontSize * 1.4)
        let textWidth = min(ceil(textSize.width), Self.maxTextWidth)
        let textHeight = ceil(textSize.height)
        let hintSize = NSSize(width: max(34, ceil(self.hintField.intrinsicContentSize.width) + 10), height: 18)
        let width = Self.padding.width * 2 + textWidth + 10 + hintSize.width
        let height = Self.padding.height * 2 + max(textHeight, hintSize.height)
        self.textField.frame = NSRect(x: Self.padding.width, y: Self.padding.height, width: textWidth, height: textHeight)
        // Tab の印は 1 行目の高さにそろえる
        let firstLineHeight = Self.fontSize * 1.25
        self.hintField.frame = NSRect(
            x: width - Self.padding.width - hintSize.width,
            y: height - Self.padding.height - firstLineHeight + (firstLineHeight - hintSize.height) / 2,
            width: hintSize.width,
            height: hintSize.height
        )

        let gap: CGFloat = 4
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: lineRect.midX, y: lineRect.midY)) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        var frame = NSRect(x: lineRect.minX - Self.padding.width, y: lineRect.minY - gap - height, width: width, height: height)
        let blocked = others.filter(\.isVisible).map(\.frame)
        if frame.minY < screen.minY || blocked.contains(where: { $0.intersects(frame) }) {
            frame.origin.y = lineRect.maxY + gap
        }
        frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - width))
        frame.origin.y = max(screen.minY, min(frame.origin.y, screen.maxY - height))
        self.setFrame(frame, display: true)
        self.orderFront(nil)
    }

    /// llm-ime: 清書の差分。変えずに残す字はふつうの色、足した字は強調色と下線、消した字は打ち消し線の薄い色
    static func diffText(original: String, revised: String, prefix: String = "") -> NSMutableAttributedString {
        let font = NSFont.systemFont(ofSize: Self.fontSize)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let added: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.controlAccentColor,
                                                    .underlineStyle: NSUnderlineStyle.single.rawValue]
        let removed: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor,
                                                      .strikethroughStyle: NSUnderlineStyle.single.rawValue]
        let result = NSMutableAttributedString(string: prefix, attributes: plain)
        let chars = Array(original)
        var position = 0
        for hunk in TextDiff.hunks(from: original, to: revised) {
            result.append(NSAttributedString(string: String(chars[position..<hunk.originalRange.lowerBound]), attributes: plain))
            if !hunk.originalText.isEmpty { result.append(NSAttributedString(string: hunk.originalText, attributes: removed)) }
            if !hunk.replacement.isEmpty { result.append(NSAttributedString(string: hunk.replacement, attributes: added)) }
            position = hunk.originalRange.upperBound
        }
        result.append(NSAttributedString(string: String(chars[position...]), attributes: plain))
        return result
    }

    func hide() {
        if self.isVisible {
            self.orderOut(nil)
        }
    }
}
