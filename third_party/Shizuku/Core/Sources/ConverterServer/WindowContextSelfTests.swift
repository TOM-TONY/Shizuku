import AppKit
import ApplicationServices
import Core
import Foundation

enum WindowContextSelfTests {
    private final class FixtureEditor: NSTextView {
        override func keyDown(with event: NSEvent) {}
        override func insertText(_ insertString: Any, replacementRange: NSRange) {}
    }
    private final class FixtureDocument: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); bounds.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 27), .foregroundColor: NSColor.black]
            ("画像の合図は青い鳥です。" as NSString).draw(at: NSPoint(x: 20, y: 35), withAttributes: attributes)
            ("期限は15時です。" as NSString).draw(at: NSPoint(x: 450, y: 35), withAttributes: attributes)
        }
    }
    @MainActor static func startLive() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            do { try runLive(); exit(0) }
            catch { print("window_context_live FAIL reason=\(error)"); exit(1) }
        }
        application.run()
        exit(1)
    }
    private final class Result<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        func set(_ value: T) { lock.withLock { stored = value } }
        var value: T? { lock.withLock { stored } }
    }

    /// Creates and captures only this process's synthetic windows; never prompts for access.
    @MainActor static func runLive() throws {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            print("window_context_live UNVERIFIED permissions_missing=1 no_permissions_requested=1")
            throw Failure.permissions
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let previous = NSWorkspace.shared.frontmostApplication
        var windows: [NSWindow] = []
        defer {
            for window in windows { window.orderOut(nil); window.close() }
            previous?.activate(options: [])
        }
        func makeWindow(title: String, label: String) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 800, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = title
            let text = NSTextField(labelWithString: label)
            text.frame = NSRect(x: 30, y: 355, width: 740, height: 45)
            text.font = .systemFont(ofSize: 28)
            window.contentView?.addSubview(text)
            let page = FixtureDocument(frame: NSRect(x: 0, y: 0, width: 740, height: 110))
            let image = NSImage(data: page.dataWithPDF(inside: page.bounds))
            let picture = NSImageView(frame: NSRect(x: 30, y: 185, width: 740, height: 110))
            picture.image = image; picture.setAccessibilityElement(true); picture.setAccessibilityRole(.image)
            window.contentView?.addSubview(picture)
            let editor = FixtureEditor(frame: NSRect(x: 30, y: 30, width: 740, height: 110))
            editor.string = "編集欄専用の合成下書き"; editor.font = .systemFont(ofSize: 28)
            window.contentView?.addSubview(editor)
            window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
            window.makeFirstResponder(editor)
            windows.append(window)
            return window
        }
        func pump(seconds: Double, until ready: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) } while !ready() && Date() < deadline
            return ready()
        }
        func read() throws -> WindowReadResult {
            let slot = Result<WindowReadResult?>()
            let pid = ProcessInfo.processInfo.processIdentifier
            WindowContextReader.queue.async {
                let result = WindowContextReader.read(pid: pid)
                if result == nil {
                    let app = AXUIElementCreateApplication(pid)
                    var focused: CFTypeRef?, window: CFTypeRef?
                    let a = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
                    let b = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
                    print("window_context_live synthetic_ax_probe focused_error=\(a.rawValue) window_error=\(b.rawValue)")
                }
                slot.set(result)
            }
            guard pump(seconds: 1, until: { slot.value != nil }), let result = slot.value ?? nil else { throw Failure.ax }
            return result
        }
        _ = makeWindow(title: "合成試験 A", label: "原稿の校正をお願いします。")
        _ = pump(seconds: 0.4, until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier })
        let first = try read()
        print("window_context_live synthetic_ax_blocks=\(first.blocks.count) needs_ocr=\(first.needsOCR)")
        guard first.blocks.contains(where: { $0.text.contains("校正") }),
              !first.blocks.contains(where: { $0.text.contains("下書き") }) else { throw Failure.ax }
        let captured = Result<[WindowReferenceBlock]>()
        WindowContextReader.capture(pid: ProcessInfo.processInfo.processIdentifier, result: first, work: WindowCaptureWork(),
                                    diagnostic: { print("window_context_live synthetic_" + $0) }) { captured.set($0) }
        guard pump(seconds: 2, until: { captured.value != nil }), let blocks = captured.value else { throw Failure.capture }
        guard
              blocks.contains(where: { $0.source == .ocr && $0.text.contains("青い鳥") }),
              blocks.contains(where: { $0.source == .ocr && $0.text.contains("15") }),
              blocks.filter({ $0.text.contains("校正") }).count == 1,
              !blocks.contains(where: { $0.text.contains("下書き") }) else { throw Failure.capture }
        _ = makeWindow(title: "合成試験 B", label: "会議の開始は15時です。")
        _ = pump(seconds: 0.2, until: { windows.last?.isKeyWindow == true })
        let second = try read()
        guard first.identity != second.identity, second.blocks.contains(where: { $0.text.contains("15") }),
              !second.blocks.contains(where: { $0.text.contains("校正") }) else { throw Failure.ownership }
        print("window_context_live ax=PASS window_capture_ocr=PASS two_column_pdf=PASS editing_mask=PASS window_identity=PASS personal_records_accessed=0 no_permissions_requested=1")
    }
    @MainActor static func run() throws {
        let width = 1000, height = 500
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
        ("会議の開始は15時です。" as NSString).draw(at: CGPoint(x: 30, y: 390), withAttributes: attrs)
        ("原稿の校正をお願いします。" as NSString).draw(at: CGPoint(x: 30, y: 260), withAttributes: attrs)
        ("編集欄にある本人の下書き" as NSString).draw(at: CGPoint(x: 30, y: 70), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let editing = CGRect(x: 0, y: 330, width: width, height: 170)
        let blocks = try WindowContextReader.ocr(bitmap.cgImage!, frame: frame, editing: editing, known: [], checkDisplays: false)
        guard blocks.contains(where: { $0.text.contains("15") }), blocks.contains(where: { $0.text.contains("校正") }),
              !blocks.contains(where: { $0.text.contains("下書き") }) else { throw Failure.ocr }
        let known = [WindowReferenceBlock(text: "会議の開始は15時です。", rect: CGRect(x: 0, y: 40, width: width, height: 100))]
        let deduplicated = try WindowContextReader.ocr(bitmap.cgImage!, frame: frame, editing: editing, known: known, checkDisplays: false)
        guard !deduplicated.contains(where: { $0.text.contains("15") }) else { throw Failure.duplicate }
        print("window_context_native ocr=PASS editing_mask=PASS duplicate_mask=PASS personal_records_accessed=0")
        print("window_context_native ax_live=UNVERIFIED capture_live=UNVERIFIED no_permissions_requested=1")
    }
    private enum Failure: Error { case ocr, duplicate, permissions, ax, capture, ownership }
}
