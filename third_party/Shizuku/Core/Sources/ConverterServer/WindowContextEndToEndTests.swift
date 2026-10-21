import AppKit
import ApplicationServices
import Core
import Foundation
import SQLite3

/// A standalone synthetic app with an anonymous XPC listener; no installed service is contacted.
@MainActor enum WindowContextEndToEndTests {
    private enum Failure: Error { case check(String) }
    private static func require(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure.check(label) }
    }
    private static func progress(_ value: String) { print(value); fflush(nil) }
    private final class Editor: NSTextView {
        var expectedTimestamp: TimeInterval?
        var receive: ((NSEvent) -> Void)?
        override func keyDown(with event: NSEvent) {
            guard expectedTimestamp == event.timestamp else { return }
            expectedTimestamp = nil
            let callback = receive; receive = nil; callback?(event)
        }
        override func insertText(_ insertString: Any, replacementRange: NSRange) {}
    }
    private final class Page: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); bounds.fill()
            ("試験の合図は琥珀の灯台です。" as NSString).draw(at: NSPoint(x: 15, y: 30), withAttributes: [
                .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black
            ])
        }
    }
    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var ax = 0, capture = 0, ocr = 0, delayed = 0
        func add(_ key: ReferenceWritableKeyPath<Counts, Int>) { lock.withLock { self[keyPath: key] += 1 } }
        func get(_ key: ReferenceWritableKeyPath<Counts, Int>) -> Int { lock.withLock { self[keyPath: key] } }
    }
    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed: (ax: Bool, screen: Bool)?
        var permissions: (ax: Bool, screen: Bool)? {
            get { lock.withLock { allowed } }
            set { lock.withLock { allowed = newValue } }
        }
        var front = true
    }
    private struct CanaryEmbedder: WindowTextEmbedder {
        static var vector: [Float] { (0..<32).map { Float($0 + 37) / 128 } }
        func embed(_ text: String, asQuery: Bool) -> [Float]? { Self.vector }
    }
    @MainActor private final class Transport {
        let delegate = ServiceDelegate()
        let listener = NSXPCListener.anonymous()
        let connection: NSXPCConnection
        let proxy: any ConverterServerXPCProtocol
        init() {
            listener.delegate = delegate; listener.resume()
            connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: ConverterServerXPCProtocol.self)
            connection.resume()
            guard let remote = connection.remoteObjectProxy as? any ConverterServerXPCProtocol else {
                preconditionFailure("Synthetic XPC interface unavailable")
            }
            proxy = remote
        }
        func send(_ command: ConverterServerCommand) async throws -> ConverterServerResponse {
            let data = try ConverterServerCodec.encode(command)
            return try await withCheckedThrowingContinuation { continuation in
                proxy.handleCommand(data) { data, error in
                    guard let data else { continuation.resume(throwing: Failure.check(error == nil ? "xpc-empty" : "xpc-error")); return }
                    do { continuation.resume(returning: try ConverterServerCodec.decodeResponse(from: data)) }
                    catch { continuation.resume(throwing: Failure.check("xpc-decode")) }
                }
            }
        }
        func close() { connection.invalidate(); listener.invalidate() }
    }
    static func start() -> Never {
        guard WindowContextTestRuntime.root != nil else { exit(1) }
        if CommandLine.arguments.contains("--window-context-cold-start-self-test") {
            do {
                let service = try prepareColdStart()
                Task { @MainActor in
                    do { try await runColdStart(service: service); exit(0) } catch {
                        print("window_context_cold_start FAIL \(error)"); exit(1)
                    }
                }
            } catch { print("window_context_cold_start FAIL \(error)"); exit(1) }
            RunLoop.current.run()
            exit(1)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("window_context_e2e PASS"); exit(0) }
            catch { print("window_context_e2e FAIL \(error)"); exit(1) }
        }
        NSApplication.shared.run()
        exit(1)
    }
    /// Exercises production configuration before any test UI initializes AppKit.
    private static func prepareColdStart() throws -> WindowContextService {
        try require(NSApp == nil, "cold-application-runtime")
        try require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "dev.tomonari.shizuku.reference-setup",
                    "dedicated-synthetic-document-required")
        Config.PersonalLearning().value = false
        Config.WindowContextEnabled().value = false
        let service = WindowContextService.shared
        service.configure()
        try require(NSApp == nil, "disabled-keeps-headless-startup")
        Config.WindowContextEnabled().value = true
        service.configure()
        try require(NSApp != nil && NSApplication.shared.activationPolicy() == .prohibited,
                    "enabled-prepares-background-runtime")
        try require(service.status.accessibility && service.status.screenRecording, "existing-permissions-required")
        return service
    }
    private static func runColdStart(service: WindowContextService) async throws {
        defer { Config.WindowContextEnabled().value = false; service.configure() }
        // Production configures AppKit before entering the run loop and receiving input.
        try await Task.sleep(for: .milliseconds(250))
        let binding = WindowContextBinding(app: "dev.tomonari.shizuku.reference-setup", activation: "synthetic-cold-start")
        let read = service.environment.read
        service.environment.read = { pid in
            let start = Date()
            let result = read(pid)
            print("window_context_cold_start read_ms=\(Date().timeIntervalSince(start) * 1000) result=\(result != nil) blocks=\(result?.blocks.count ?? 0)")
            if result == nil {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.025)
                let window = WindowContextReader.element(app, kAXFocusedWindowAttribute)
                let focused = WindowContextReader.element(app, kAXFocusedUIElementAttribute)
                let role = focused.flatMap { WindowContextReader.value($0, kAXRoleAttribute) as? String } ?? "unknown"
                print("window_context_cold_start trusted=\(AXIsProcessTrusted()) window=\(window != nil) focused=\(focused != nil) role=\(role)")
            }
            return result
        }
        defer { service.environment.read = read }
        service.bind(binding, session: nil)
        do {
            try await wait(seconds: 4) { service.lease.latest != nil }
            print("window_context_cold_start ax_reference=PASS")
            try await wait(seconds: 30) { WindowContextReader.isOCRPrepared }
            try await wait(seconds: 8) {
                service.lease.latest?.blocks.contains(where: { $0.source == .ocr && $0.text.contains("日本語") }) == true
            }
        } catch {
            print("window_context_cold_start state=\(service.status.state) ax=\(service.status.accessibility) screen=\(service.status.screenRecording) bound=\(service.lease.binding != nil) front_matches=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == binding.app) reference_blocks=\(service.lease.latest?.blocks.count ?? 0) ocr_blocks=\(service.lease.latest?.blocks.filter { $0.source == .ocr }.count ?? 0)")
            throw error
        }
        guard let reference = service.lease.latest else {
            print("window_context_cold_start state=\(service.status.state) ax=\(service.status.accessibility) screen=\(service.status.screenRecording) bound=\(service.lease.binding != nil) front_matches=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == binding.app)")
            throw Failure.check("cold-start-reference")
        }
        try require(reference.blocks.contains(where: { $0.source == .accessibility && $0.text.contains("校正") }),
                    "cold-start-ax-reference")
        try require(reference.blocks.contains(where: { $0.source == .ocr && $0.text.contains("日本語") }),
                    "cold-start-japanese-ocr-reference")
        try require(!reference.blocks.contains(where: { $0.text.contains("下書き") }), "editing-field-excluded")
        Config.WindowContextEnabled().value = false; service.configure()
        try require(service.lease.latest == nil, "disable-clears-cold-start-reference")
        print("window_context_cold_start runtime=PASS ax=PASS japanese_ocr=PASS editing_mask=PASS disable_clear=PASS personal_records_accessed=0 no_permissions_requested=1")
    }
    private static func wait(seconds: Double = 4, _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try require(ready(), "wait-timeout")
    }
    private static func audit(root: URL, needles: [Data]) throws -> (files: Int, bytes: UInt64) {
        var files = 0, bytes: UInt64 = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            try require(values.isSymbolicLink != true, "unexpected-isolation-link")
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: file)
            try require(!needles.contains(where: { data.range(of: $0) != nil }), "reference-persisted")
            try require(!["png", "jpg", "jpeg", "pdf", "heic", "tiff"].contains(file.pathExtension), "image-persisted")
            files += 1; bytes += UInt64(data.count)
        }
        return (files, bytes)
    }
    // swiftlint:disable:next cyclomatic_complexity
    private static func run() async throws {
        let root = WindowContextTestRuntime.root!
        try require(PersonalLearner.directoryURL.path.hasPrefix(root.path + "/"), "personal-store-isolation")
        try require(AXIsProcessTrusted() && CGPreflightScreenCaptureAccess(), "existing-permissions-required")
        Config.PersonalLearning().value = false
        Config.PersonalAccessibilityPlaces().value = false
        Config.PersonalLearningSelfTuning().value = false
        Config.LabNightly().value = false
        Config.NextTextCompletion().value = false
        Config.NextTextCompletionIdle().value = false
        let code = Array(UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let marker = "画面限定参照" + stride(from: 0, to: code.count, by: 4).map { String(code[$0..<($0 + 4)]) }.joined(separator: "参")
        let imageMarker = "試験の合図は琥珀の灯台です。"
        let positive = "本人が確定する検査用の文章です。"
        let previous = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 800, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "入力と参照の隔離試験"
        let label = NSTextField(labelWithString: "原稿の校正をお願いします。\n" + marker)
        label.frame = NSRect(x: 25, y: 310, width: 750, height: 100); label.font = .systemFont(ofSize: 21)
        window.contentView?.addSubview(label)
        let page = Page(frame: NSRect(x: 0, y: 0, width: 740, height: 100))
        let picture = NSImageView(frame: NSRect(x: 30, y: 180, width: 740, height: 100))
        picture.image = NSImage(data: page.dataWithPDF(inside: page.bounds))
        picture.setAccessibilityElement(true); picture.setAccessibilityRole(.image)
        window.contentView?.addSubview(picture)
        let editor = Editor(frame: NSRect(x: 30, y: 25, width: 740, height: 110))
        editor.string = "編集欄専用の合成下書き"; editor.font = .systemFont(ofSize: 24)
        window.contentView?.addSubview(editor)
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); window.makeFirstResponder(editor)
        defer {
            let restore = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            window.orderOut(nil); window.close(); if restore { previous?.activate(options: []) }
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        try await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        let transport = Transport()
        defer { transport.close() }
        let service = WindowContextService.shared, signals = Signals(), counts = Counts()
        let app = "dev.tomonari.xpcprobe.window-context"
        let binding = WindowContextBinding(app: app, activation: UUID().uuidString)
        service.environment.workspace = NotificationCenter(); service.environment.screen = NotificationCenter()
        // The process-local adapter selects only the fixture, even if the user changes apps during a long run.
        service.environment.front = { signals.front ? (app, pid) : nil }
        service.environment.permissions = { signals.permissions ?? (AXIsProcessTrusted(), CGPreflightScreenCaptureAccess()) }
        service.environment.read = { pid in counts.add(\.ax); return WindowContextReader.read(pid: pid) }
        service.environment.capture = { pid, result, work, completion in
            counts.add(\.capture)
            WindowContextReader.capture(pid: pid, result: result, work: work,
                                        diagnostic: { print("synthetic_capture " + $0) }) { blocks in
                if blocks.contains(where: { $0.source == .ocr }) { counts.add(\.ocr) }
                completion(blocks)
            }
        }
        let measuredCapture = service.environment.capture
        let id = UUID().uuidString
        _ = try await transport.send(.openSession(sessionID: id, command: .windowContext(nil)))
        let session = try transport.delegate.server.getSession(id)
        transport.delegate.server.prepareInputResources()
        var eventID: UInt64 = 0
        @MainActor func send(_ command: ConverterSessionCommand) async throws -> ConverterServerResponse {
            try await transport.send(.session(sessionID: id, command: command))
        }
        @MainActor func key(_ text: String, code: UInt16 = 0, style: ConverterInputStyle = .direct, left: String? = nil) async throws -> ConverterServerResponse {
            eventID += 1
            let timestamp = ProcessInfo.processInfo.systemUptime
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!
            editor.expectedTimestamp = event.timestamp
            return try await withCheckedThrowingContinuation { continuation in
                editor.receive = { delivered in
                    Task { @MainActor in
                        do {
                            let response = try await send(.handleKeyEvent(.init(eventID: eventID,
                                event: .init(modifierFlags: [], characters: delivered.characters,
                                    charactersIgnoringModifiers: delivered.charactersIgnoringModifiers, keyCode: delivered.keyCode),
                                inputStyle: style, liveConversionEnabled: true, enableDebugWindow: false, enableSuggestion: false,
                                enablePredictiveTyping: true, enableTypoCorrection: true,
                                context: .init(leftSideContext: left, windowBinding: binding), scene: .init(bundleID: app, documentLength: 0, startedEmpty: true))))
                            editor.setMarkedText(response.snapshot.convertTarget,
                                selectedRange: NSRange(location: response.snapshot.convertTarget.utf16.count, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
                            continuation.resume(returning: response)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                if eventID == 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard editor.receive != nil else { return }
                        editor.receive = nil; editor.expectedTimestamp = nil
                        continuation.resume(throwing: Failure.check("appkit-key-delivery"))
                    }
                }
                window.sendEvent(event)
            }
        }
        @MainActor func acquire() async throws {
            Config.WindowContextEnabled().value = true; service.configure()
            _ = try await send(.windowContext(binding))
            do { try await wait(seconds: 5) { service.lease.latest != nil } }
            catch {
                progress("synthetic_acquire state=\(service.status.state) reads=\(counts.get(\.ax)) captures=\(counts.get(\.capture)) ocr=\(counts.get(\.ocr))")
                throw error
            }
            progress("synthetic_reference_ready=1")
            _ = try await key("こ")
            try require(session.windowReference != nil, "reference-installed")
            _ = try await send(.composition(.stopComposition))
        }
        try await acquire()
        try require(session.windowReference?.blocks.contains(where: { $0.text.contains(marker) }) == true, "ax-marker-acquired")
        // Production prepares Vision independently, using a generated generic bitmap.
        let warmStart = ProcessInfo.processInfo.systemUptime
        var warmingKeys: [Double] = []
        for _ in 0..<40 {
            _ = try await send(.composition(.stopComposition))
            let started = ProcessInfo.processInfo.systemUptime
            _ = try await key("こ")
            warmingKeys.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
        _ = try await send(.composition(.stopComposition))
        try await wait(seconds: 60) { WindowContextReader.isOCRPrepared }
        progress("synthetic_vision_warmup_ms=\((ProcessInfo.processInfo.systemUptime - warmStart) * 1000)")
        do {
            try await wait(seconds: 8) { service.lease.latest?.blocks.contains(where: { $0.source == .ocr && $0.text.contains("琥珀") }) == true }
        } catch {
            progress("synthetic_ocr_wait state=\(service.status.state) reads=\(counts.get(\.ax)) captures=\(counts.get(\.capture)) ocr=\(counts.get(\.ocr)) bound=\(service.lease.binding != nil)")
            throw error
        }
        _ = try await key("こ"); _ = try await send(.composition(.stopComposition))
        try require(session.windowReference?.blocks.contains(where: { $0.source == .ocr && $0.text.contains("琥珀") }) == true, "ocr-marker-acquired")
        try require(session.windowReference?.blocks.contains(where: { $0.text.contains("下書き") }) == false, "editor-excluded")
        print("window_context_e2e capture=ax+screen+ocr synthetic_only=1 permissions_requested=0")

        // Immediate request-time checks must reject permission changes before the polling timer fires.
        for kind in ["ax", "screen", "lock", "disabled", "front"] {
            if session.windowReference == nil { try await acquire() }
            guard let receipt = service.receipt(for: session) else { throw Failure.check("receipt-before-transition") }
            _ = session.offers.chooseEmpty(.init(.idle, text: "隔離した参照付き提案"), skeleton: nil, now: 1, temporal: false)
            session.lastKeyEventResponse?.snapshot.nextTextCompletion = "隔離した参照付き提案"
            let oldGeneration = receipt.generation
            switch kind {
            case "ax": signals.permissions = (false, true)
            case "screen": signals.permissions = (true, false)
            case "lock": service.environment.screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
            case "disabled": Config.WindowContextEnabled().value = false
            default: signals.front = false
            }
            let valid = try await send(.validateWindowContext(receipt))
            try require(valid.handled == false && session.windowReference == nil && session.manager.windowReference == nil, "transition-" + kind)
            try require(service.lease.latest == nil && service.lease.generation != oldGeneration && session.pendingCompletion == nil, "cache-" + kind)
            try require(session.offers.current == nil && session.lastKeyEventResponse?.snapshot.nextTextCompletion == nil, "proposal-cache-" + kind)
            let response = try await key("か")
            try require(response.handled && !response.snapshot.convertTarget.isEmpty && session.windowReference == nil, "fallback-" + kind)
            _ = try await send(.composition(.stopComposition))
            signals.permissions = nil; signals.front = true
            service.environment.screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
            try require(session.windowReference == nil, "unlock-must-not-restore-reference")
            print("window_context_e2e transition=\(kind) invalidated=1 receipt_rejected=1 fallback=1")
        }

        try await acquire()
        guard let expiring = service.receipt(for: session) else { throw Failure.check("expiry-positive-control") }
        session.windowReference?.capturedAt -= 31
        let expired = try await send(.validateWindowContext(expiring))
        try require(expired.handled == false && session.windowReference == nil && service.lease.latest == nil, "expiry-invalidates-cache")
        print("window_context_e2e expiry=PASS")

        // An OCR completion held across a boundary cannot repopulate the service.
        for kind in ["screen", "lock", "disabled"] {
            service.environment.capture = { pid, result, work, completion in
                measuredCapture(pid, result, work) { blocks in
                    counts.add(\.delayed)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { completion(blocks) }
                }
            }
            let before = counts.get(\.delayed)
            Config.WindowContextEnabled().value = true; service.configure(); _ = try await send(.windowContext(binding))
            try await wait { counts.get(\.delayed) > before }
            switch kind {
            case "screen": signals.permissions = (true, false)
            case "lock": service.environment.screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
            default: Config.WindowContextEnabled().value = false; service.configure()
            }
            try await Task.sleep(for: .milliseconds(600))
            try require(service.lease.latest == nil && session.windowReference == nil, "delayed-" + kind)
            signals.permissions = nil
            service.environment.screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
            print("window_context_e2e late_capture=\(kind) rejected=1")
        }
        service.environment.capture = measuredCapture

        let liveRead = service.environment.read
        service.environment.read = { pid in
            Thread.sleep(forTimeInterval: 0.25)
            return liveRead(pid)
        }
        Config.WindowContextEnabled().value = true; service.configure(); _ = try await send(.windowContext(binding))
        let readsBeforeTimeout = counts.get(\.ax)
        try await wait { counts.get(\.ax) > readsBeforeTimeout }
        try await Task.sleep(for: .milliseconds(500))
        try require(service.lease.latest == nil, "ax-timeout-late-result")
        _ = try await key("か"); try require(session.windowReference == nil, "ax-timeout-fallback")
        _ = try await send(.composition(.stopComposition))
        service.environment.read = liveRead
        service.environment.capture = { _, result, _, completion in
            counts.add(\.delayed)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.3) { completion(result.blocks) }
        }
        let beforeTimeout = counts.get(\.delayed)
        service.configure(); _ = try await send(.windowContext(binding))
        try await wait { counts.get(\.delayed) > beforeTimeout }
        try await wait { service.lease.latest != nil }
        let axOnlyTime = service.lease.latest?.capturedAt
        try await Task.sleep(for: .milliseconds(1500))
        try require(service.lease.latest?.capturedAt == axOnlyTime, "capture-timeout-late-result")
        _ = try await key("か"); try require(session.windowReference?.blocks.allSatisfy({ $0.source == .accessibility }) == true, "capture-timeout-ax-fallback")
        _ = try await send(.composition(.stopComposition))
        service.environment.capture = measuredCapture
        print("window_context_e2e ax_timeout=PASS capture_timeout=PASS late_callbacks_rejected=1")

        NextTextCompletionEngine.modelDirectoryOverride = ProcessInfo.processInfo.environment["LLM_IME_WINDOW_TEST_COMPLETION"].map { URL(fileURLWithPath: $0) }
        try require(NextTextCompletionEngine.modelDirectoryOverride != nil, "explicit-completion-model")
        NextTextCompletionEngine.shared.preload()
        Config.NextTextCompletion().value = true; Config.NextTextCompletionIdle().value = true
        try await acquire()
        let referenceText = await WindowReferenceRetrieval.shared.text(reference: session.windowReference, query: "原稿の校正")
        try require(referenceText.contains(marker), "reference-retrieval")
        let transientIndex = WindowReferenceIndex(reference: session.windowReference!, modelIdentity: "synthetic-canary-v1", embedder: CanaryEmbedder())
        try require(!transientIndex.retrieve(query: "原稿", modelIdentity: "synthetic-canary-v1", embedder: CanaryEmbedder()).isEmpty, "transient-vector-positive-control")
        _ = try await send(.completion(.draft(leftContext: "原稿の校正について、確認したい点は")))
        _ = try await send(.completion(.idle(leftContext: "原稿の校正について、")))
        let populatedCache = await NextTextCompletionEngine.shared.contextCacheStatistics()
        try require(populatedCache.modelLoaded && populatedCache.tokens > 0, "native-cache-positive-control")
        // Cancellation of a real native generation crosses the same XPC entry as a live proposal.
        let lateGeneration = Task { try await send(.completion(.draft(leftContext: "原稿の校正について、検討した結果は"))) }
        try await Task.sleep(for: .milliseconds(30))
        service.environment.screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
        let lateResponse = try await lateGeneration.value
        try require(lateResponse.snapshot.nextTextCompletion == nil && lateResponse.windowContextReceipt == nil, "late-generation-lock")
        let clearedCache = await NextTextCompletionEngine.shared.contextCacheStatistics()
        try require(clearedCache.modelLoaded && clearedCache.tokens == 0, "native-cache-not-cleared")
        service.environment.screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        print("window_context_e2e native_generation=draft+idle late_generation_rejected=1")

        // Interleave baseline/reference rounds to reduce warm-up and thermal ordering bias.
        var baseline: [Double] = [], referenced: [Double] = []
        var ordered = 0, duplicates = 0
        var capturesDuringKeys = 0, ocrDuringKeys = 0
        var runsDuringReferenceKeys: UInt64 = 0
        var rawRequests = 0, allowedRequests = 0
        let runsBeforeKeys = await NextTextCompletionEngine.shared.contextCacheStatistics().runs
        for enabled in [false, true, true, false] {
            Config.WindowContextEnabled().value = enabled; service.configure()
            if enabled { _ = try await send(.windowContext(binding)); try await wait(seconds: 5) { service.lease.latest != nil } }
            let roundRuns = await NextTextCompletionEngine.shared.contextCacheStatistics().runs
            let captureStart = counts.get(\.capture), ocrStart = counts.get(\.ocr)
            for word in 0..<80 {
                _ = try await send(.composition(.stopComposition))
                let targets = ["k", "こ", "こう", "こうs", "こうせ", "こうせい"]
                for (index, char) in "kousei".enumerated() {
                    let start = ProcessInfo.processInfo.systemUptime
                    let response = try await key(String(char), style: .defaultRomanToKana, left: "原稿の校正について、")
                    let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    try require(response.snapshot.convertTarget == targets[index] && session.lastHandledKeyEventID == eventID, "key-loss-or-order")
                    ordered += 1
                    if session.manager.makeNextTextCompletionRequest() != nil { rawRequests += 1 }
                    if transport.delegate.server.automaticOfferAllowed(.completion, session: session) { allowedRequests += 1 }
                    if word >= 5 { if enabled { referenced.append(ms) } else { baseline.append(ms) } }
                    try await Task.sleep(for: .milliseconds(3))
                }
                if word % 20 == 0, let cached = session.lastKeyEventResponse {
                    let duplicate = try await send(.handleKeyEvent(.init(eventID: eventID,
                        event: .init(modifierFlags: [], characters: "い", charactersIgnoringModifiers: "い", keyCode: 0),
                        inputStyle: .direct, liveConversionEnabled: true, enableDebugWindow: false, enableSuggestion: false,
                        context: .init(windowBinding: binding))))
                    try require(duplicate.snapshot.convertTarget == cached.snapshot.convertTarget, "duplicate-key")
                    duplicates += 1
                }
                if word % 5 == 0 { try await Task.sleep(for: .milliseconds(80)) }
            }
            let completedRuns = await NextTextCompletionEngine.shared.contextCacheStatistics().runs - roundRuns
            progress("synthetic_round reference=\(enabled) runs=\(completedRuns) captures=\(counts.get(\.capture) - captureStart) ocr=\(counts.get(\.ocr) - ocrStart) raw_requests=\(rawRequests) allowed_requests=\(allowedRequests)")
            if enabled {
                capturesDuringKeys += counts.get(\.capture) - captureStart; ocrDuringKeys += counts.get(\.ocr) - ocrStart
                runsDuringReferenceKeys += completedRuns
            }
        }
        let runsDuringKeys = await NextTextCompletionEngine.shared.contextCacheStatistics().runs - runsBeforeKeys
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
        let base = p95(baseline), ref = p95(referenced)
        print("window_context_e2e keys=\(ordered) duplicate_retries=\(duplicates) baseline_p95_ms=\(base) reference_p95_ms=\(ref) delta_ms=\(ref - base)")
        progress("synthetic_concurrency captures=\(capturesDuringKeys) ocr=\(ocrDuringKeys) runs=\(runsDuringKeys) reference_runs=\(runsDuringReferenceKeys)")
        // An image may arrive just before the first key; its OCR still overlaps the measured input loop.
        try require(ocrDuringKeys > 0 && runsDuringReferenceKeys > 0, "concurrent-native-work-not-exercised")
        try require(ref - base <= 5, "input-latency-budget")

        // Exercise actual commit learning with reference acquisition and generation both enabled.
        Config.PersonalLearning().value = true
        PersonalLearner.shared.prepare()
        try await wait(seconds: 8) { FileManager.default.fileExists(atPath: PersonalLearner.directoryURL.appendingPathComponent("personal.sqlite").path) }
        try await acquire()
        _ = try await key(positive)
        _ = try await key("\r", code: 36)
        PersonalLearner.shared.flush()
        let export = root.appendingPathComponent("export.jsonl")
        _ = try PersonalLearner.shared.export(to: export)
        let exported = try String(contentsOf: export, encoding: .utf8)
        try require(exported.contains(positive), "learning-positive-control")
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        let copied = await withCheckedContinuation { continuation in PersonalLearner.shared.snapshot(to: snapshot) { continuation.resume(returning: $0) } }
        try require(copied, "snapshot-positive-control")
        service.invalidate(); Config.WindowContextEnabled().value = false; service.configure()
        let markers = [marker, imageMarker]
        let needles = markers.flatMap { [Data($0.utf8), $0.data(using: .utf16LittleEndian)!, $0.data(using: .utf16BigEndian)!] }
            + [CanaryEmbedder.vector.withUnsafeBytes { Data($0) }]
        let (files, bytes) = try audit(root: root, needles: needles)
        let report: [String: Any] = ["baselineP95Ms": base, "referenceP95Ms": ref, "deltaMs": ref - base,
            "samplesPerCondition": baseline.count, "keysInOrder": ordered, "duplicateRetries": duplicates,
            "keysDuringOCRPreparation": warmingKeys.count, "ocrPreparationKeyMaxMs": warmingKeys.max() ?? 0,
            "capturesDuringKeys": capturesDuringKeys, "ocrDuringKeys": ocrDuringKeys, "nativeCompletionRunsDuringKeys": runsDuringKeys,
            "nativeCompletionRunsDuringReferenceKeys": runsDuringReferenceKeys,
            "axReads": counts.get(\.ax), "captures": counts.get(\.capture), "ocrCompletions": counts.get(\.ocr),
            "filesScanned": files, "bytesScanned": bytes, "referenceMarkersFound": 0, "learningPositiveControl": true,
            "realAnonymousXPC": true, "zenzEnabled": true, "nativeGenerationEnabled": true,
            "appKitWindowDispatchAndMarkedText": true,
            "transientVectorCanary": true,
            "permissionAndLockSignals": "process-local fault injection; system settings unchanged"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print("window_context_e2e persistence=PASS positive_control=1 files=\(files) bytes=\(bytes) reference_markers=0 images=0")
    }
}
