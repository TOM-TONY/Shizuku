import AppKit
import ApplicationServices
import Core
import Foundation
import ScreenCaptureKit
import Vision

final class WindowCaptureWork: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var request: VNRequest?
    var cancelled: Bool { lock.withLock { stopped } }
    func attach(_ value: VNRequest) -> Bool { lock.withLock {
        guard !stopped else { return false }
        request = value; return true
    } }
    func cancel() {
        let pending = lock.withLock { stopped = true; return request }
        pending?.cancel()
    }
    func finish() { lock.withLock { request = nil } }
}

struct WindowReadResult: @unchecked Sendable {
    var identity: String
    var window: AXUIElement
    var focused: AXUIElement
    var frame: CGRect
    var editing: CGRect
    var blocks: [WindowReferenceBlock]
    var needsOCR: Bool
    var boundaries: [AXUIElement]
    /// 編集中の欄のカーソルより前。読めなければ nil
    var fieldBefore: String? = nil
}

/// All remote AX work runs on this bounded background queue, never in a key callback.
enum WindowContextReader {
    static let queue = DispatchQueue(label: "Shizuku.window-context.read", qos: .utility)
    static func accessibilityAllowed() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        // Trust can remain cached after revocation. This reads only the focused app's AX handle.
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, 0.025) == .success else { return false }
        var focused: CFTypeRef?
        return AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focused) == .success
    }
    private final class OCRPreparation: @unchecked Sendable {
        let lock = NSLock()
        var started = false
        var ready = false
        func start() {
            guard lock.withLock({ if started { return false }; started = true; return true }) else { return }
            DispatchQueue.global(qos: .utility).async {
                let prepared = autoreleasepool {
                    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 64,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                    NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 256, height: 64).fill()
                    ("参考資料" as NSString).draw(at: CGPoint(x: 10, y: 15), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black
                    ])
                    NSGraphicsContext.restoreGraphicsState()
                    guard let image = bitmap.cgImage else { return false }
                    return (try? WindowContextReader.ocr(image, frame: CGRect(x: 0, y: 0, width: 256, height: 64),
                        editing: .zero, known: [], checkDisplays: false)) != nil
                }
                self.lock.withLock { self.ready = prepared }
            }
        }
    }
    private static let preparation = OCRPreparation()
    static func prepareOCR() { preparation.start() }
    static var isOCRPrepared: Bool { preparation.lock.withLock { preparation.ready } }

    static func visible(_ rect: CGRect) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.contains { CGDisplayBounds($0).contains(rect) }
    }

    static func rect(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, kAXPositionAttribute),
              let sizeValue = value(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        // CF type IDs were checked above; these CF objects have no failable bridge.
        // swiftlint:disable:next force_cast
        let position = positionValue as! AXValue, size = sizeValue as! AXValue
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        let rect = CGRect(origin: point, size: dimensions)
        return rect.width > 0 && rect.height > 0 && rect.minX.isFinite && rect.minY.isFinite ? rect : nil
    }

    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(node, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        // The CF type ID is checked before bridging the remote element.
        // swiftlint:disable:next force_cast
        return (result as! AXUIElement)
    }

    /// 編集中の欄のカーソルより前を、範囲指定で最大 WindowReference.fieldLimit 字だけ読む（全文は求めない）
    static func fieldBefore(_ focused: AXUIElement) -> String? {
        guard let selection = value(focused, kAXSelectedTextRangeAttribute), CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let axSelection = selection as! AXValue
        var range = CFRange()
        guard AXValueGetType(axSelection) == .cfRange, AXValueGetValue(axSelection, .cfRange, &range),
              range.location > 0, range.location != kCFNotFound else { return nil }
        let start = max(0, range.location - WindowReference.fieldLimit)
        var wanted = CFRange(location: start, length: range.location - start)
        guard let parameter = AXValueCreate(.cfRange, &wanted) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(focused, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
              let text = result as? String else { return nil }
        return text
    }

    static func read(pid: pid_t) -> WindowReadResult? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(0.15)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.025)
        guard let window = element(application, kAXFocusedWindowAttribute),
              let focused = element(application, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.025)
        AXUIElementSetMessagingTimeout(focused, 0.025)
        let role = value(focused, kAXRoleAttribute) as? String ?? ""
        let subrole = value(focused, kAXSubroleAttribute) as? String ?? ""
        guard !role.contains("Secure"), !subrole.contains("Secure"),
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) || value(focused, "AXEditable") as? Bool == true,
              let frame = rect(window), let editing = rect(focused), frame.intersects(editing) else { return nil }
        // Hashes stay in process; document names, URLs and field labels are never logged.
        var identity = Hasher()
        identity.combine(pid); identity.combine(CFHash(window)); identity.combine(CFHash(focused))
        identity.combine(value(window, kAXTitleAttribute) as? String ?? "")
        identity.combine(String(describing: value(window, kAXDocumentAttribute) ?? "" as CFString))
        var ancestor: AXUIElement? = focused
        for _ in 0..<8 where Date() < deadline {
            guard let node = ancestor else { break }
            AXUIElementSetMessagingTimeout(node, 0.01)
            if let url = value(node, kAXURLAttribute) { identity.combine(String(describing: url)); break }
            ancestor = element(node, kAXParentAttribute)
        }
        var blocks: [WindowReferenceBlock] = [], visited = 0, uncovered = false
        var boundaries: [AXUIElement] = []
        var pending: [(AXUIElement, CGRect)] = [(window, frame)]
        while let (node, clip) = pending.popLast(), visited < 512, blocks.count < 128, Date() < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(node, 0.01)
            if CFEqual(node, focused) { continue }
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            if ["AXTextField", "AXTextArea", "AXComboBox", "AXButton", "AXMenu", "AXMenuBar", "AXToolbar"].contains(role)
                || role.contains("Secure") { continue }
            if value(node, "AXHidden") as? Bool == true { continue }
            let bounds = rect(node)
            if let bounds, !clip.intersects(bounds) { continue }
            if role == "AXTabGroup" {
                // Inspect only the selected tab; background tab contents are never requested.
                let selected = value(node, kAXSelectedChildrenAttribute) as? [AXUIElement] ?? []
                for tab in selected.prefix(2) {
                    AXUIElementSetMessagingTimeout(tab, 0.01)
                    identity.combine(CFHash(tab)); identity.combine(value(tab, kAXTitleAttribute) as? String ?? "")
                }
                if boundaries.count < 4 { boundaries.append(node) }
            } else if role == "AXWebArea", let url = value(node, kAXURLAttribute) {
                identity.combine(String(describing: url))
                if boundaries.count < 4 { boundaries.append(node) }
            }
            if ["AXStaticText", "AXHeading", "AXLink"].contains(role), let bounds,
               clip.contains(bounds), visible(bounds), !bounds.intersects(editing), let text = value(node, kAXValueAttribute) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.init(text: text, rect: bounds, role: role))
            }
            let children = (value(node, kAXVisibleChildrenAttribute) ?? value(node, kAXChildrenAttribute)) as? [AXUIElement] ?? []
            if let bounds, !bounds.intersects(editing), clip.intersects(bounds),
               role == "AXImage" || role == "AXCanvas" || role == "AXPDF"
                || (role == "AXGroup" && children.isEmpty && bounds.width * bounds.height > frame.width * frame.height * 0.2) {
                uncovered = true
            }
            let childClip = bounds.map { clip.intersection($0) } ?? clip
            pending.append(contentsOf: children.prefix(max(0, 512 - visited)).reversed().map { ($0, childClip) })
        }
        let before = Date() < deadline ? fieldBefore(focused) : nil
        return .init(identity: String(identity.finalize()), window: window, focused: focused, frame: frame, editing: editing, blocks: blocks,
                     needsOCR: uncovered || blocks.isEmpty || !pending.isEmpty, boundaries: boundaries, fieldBefore: before)
    }

    /// Capture only this window. OCR excludes editing and already readable AX text.
    static func ocr(_ image: CGImage, frame: CGRect, editing: CGRect, known: [WindowReferenceBlock], checkDisplays: Bool = true,
                    work: WindowCaptureWork? = nil, recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
                    languages: [String] = ["ja-JP", "en-US"]) throws -> [WindowReferenceBlock] {
        let request = VNRecognizeTextRequest()
        guard work?.attach(request) != false else { return [] }
        defer { work?.finish() }
        request.recognitionLevel = recognitionLevel
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
            let box = observation.boundingBox
            let bounds = CGRect(x: frame.minX + box.minX * frame.width,
                                y: frame.minY + (1 - box.maxY) * frame.height,
                                width: box.width * frame.width, height: box.height * frame.height)
            guard !checkDisplays || visible(bounds), !bounds.intersects(editing), !known.contains(where: { $0.rect.intersects(bounds) }) else { return nil }
            return .init(text: candidate.string, rect: bounds, source: .ocr)
        }
    }

    static func capture(pid: pid_t, result: WindowReadResult, work: WindowCaptureWork,
                        recognitionLevel: VNRequestTextRecognitionLevel = .accurate, languages: [String] = ["ja-JP", "en-US"],
                        diagnostic: (@Sendable (String) -> Void)? = nil,
                        completion: @escaping @Sendable ([WindowReferenceBlock]) -> Void) {
        guard !work.cancelled else { return }
        guard result.needsOCR, CGPreflightScreenCaptureAccess() else { completion(result.blocks); return }
        let started = Date()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            guard !work.cancelled else { return }
            let matches = content?.windows.filter { window in
                window.owningApplication?.processID == pid && window.isOnScreen
                    // AX includes the window border; ScreenCaptureKit can return its inset content frame.
                    && abs(window.frame.minX - result.frame.minX) <= 12 && abs(window.frame.minY - result.frame.minY) <= 12
                    && abs(window.frame.width - result.frame.width) <= 24 && abs(window.frame.height - result.frame.height) <= 24
            } ?? []
            diagnostic?("capture_matches=\(matches.count) error=\((error as NSError?)?.code ?? 0) ax_frame=\(result.frame) owned_frames=\(content?.windows.filter { $0.owningApplication?.processID == pid }.map(\.frame) ?? [])")
            guard matches.count == 1, let window = matches.first, Date().timeIntervalSince(started) < 1 else {
                completion(result.blocks); return
            }
            let captureFrame = window.frame
            let configuration = SCStreamConfiguration()
            configuration.width = Int(captureFrame.width * 2)
            configuration.height = Int(captureFrame.height * 2)
            configuration.scalesToFit = true
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) { image, error in
                guard !work.cancelled else { return }
                diagnostic?("capture_image=\(image != nil) error=\((error as NSError?)?.code ?? 0)")
                guard let image, Date().timeIntervalSince(started) < 1 else { completion(result.blocks); return }
                queue.async {
                    guard !work.cancelled else { return }
                    let extra: [WindowReferenceBlock]
                    do {
                        extra = try ocr(image, frame: captureFrame, editing: result.editing.insetBy(dx: -12, dy: -12),
                                        known: result.blocks, work: work, recognitionLevel: recognitionLevel, languages: languages)
                    } catch {
                        let failure = error as NSError
                        diagnostic?("capture_ocr_error=\(failure.domain):\(failure.code)")
                        extra = []
                    }
                    diagnostic?("capture_ocr_blocks=\(extra.count) within_deadline=\(Date().timeIntervalSince(started) <= 1)")
                    completion(Date().timeIntervalSince(started) <= 1 ? result.blocks + extra : result.blocks)
                }
            }
        }
    }
}
