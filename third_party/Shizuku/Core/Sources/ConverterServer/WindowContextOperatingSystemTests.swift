import AppKit
import ApplicationServices
import Core
import Darwin
import Foundation

/// Runs only in a disposable macOS guest, using native permissions and distributed OS notifications.
@MainActor enum WindowContextOperatingSystemTests {
    static let flag = "--window-context-real-os-test"
    private enum Failure: Error { case check(String) }
    private static func require(_ condition: Bool, _ label: String) throws {
        if !condition { throw Failure.check(label) }
    }
    static func virtualGuest() -> Bool {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }
    static func start() -> Never {
        guard virtualGuest() else { exit(2) }
        if WindowContextTestRuntime.operatingSystemFixture {
            do { try prepareStorage() } catch { exit(2) }
        }
        guard WindowContextTestRuntime.root != nil else { exit(2) }
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try Harness().show() }
            catch { print("os_test_start_failed"); exit(1) }
        }
        NSApplication.shared.run(); exit(1)
    }
    private static func prepareStorage() throws {
        let files = FileManager.default
        let root = files.homeDirectoryForCurrentUser.appendingPathComponent("WindowContextOSLab", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in ["tmp", "personal", "cache"] {
            try files.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent(".synthetic-window-test"))
        setenv("LLM_IME_WINDOW_TEST_ROOT", root.path, 1)
        setenv("LLM_IME_PERSONAL_DIR", root.appendingPathComponent("personal").path, 1)
        setenv("LLM_IME_WINDOW_TEST_RESOURCES", Bundle.main.resourceURL!.path, 1)
        setenv("TMPDIR", root.appendingPathComponent("tmp").path + "/", 1)
        setenv("XDG_CACHE_HOME", root.appendingPathComponent("cache").path, 1)
        let reset = URL(fileURLWithPath: "/Volumes/My Shared Files/Results/.reset-stale-fixture-permissions")
        if files.fileExists(atPath: reset.path) {
            for permission in ["Accessibility", "ScreenCapture"] {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", permission, "dev.tomonari.xpcprobe.window-os"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                try require(process.terminationStatus == 0, "reset-stale-fixture-permission")
            }
            try files.removeItem(at: reset)
        }
    }
    @MainActor private final class Transport {
        let delegate = ServiceDelegate(), listener = NSXPCListener.anonymous()
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
                proxy.handleCommand(data) { response, _ in
                    do {
                        guard let response else { throw Failure.check("xpc-empty") }
                        continuation.resume(returning: try ConverterServerCodec.decodeResponse(from: response))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
    @MainActor private final class Harness: NSObject {
        static var retained: Harness?
        let service = WindowContextService.shared
        let window = NSWindow(contentRect: NSRect(x: 90, y: 110, width: 1000, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let editor = NSTextView(frame: NSRect(x: 25, y: 155, width: 940, height: 100))
        let status = NSTextField(labelWithString: "権限を許可してから取得確認を実行")
        let transport = Transport(), sessionID = UUID().uuidString
        let app = "dev.tomonari.xpcprobe.window-os"
        let documentID = "dev.tomonari.xpcprobe.window-os.document"
        var document: NSRunningApplication?
        var binding: WindowContextBinding!
        var eventID: UInt64 = 0
        var running = false
        var observations: [NSObjectProtocol] = []
        var lockEvents = 0, unlockEvents = 0
        var records: [[String: Any]] = []
        var results: URL!
        var session: ConverterSession { get throws { try transport.delegate.server.getSession(sessionID) } }
        func show() throws {
            Self.retained = self
            results = URL(fileURLWithPath: "/Volumes/My Shared Files/Results", isDirectory: true)
            try require(FileManager.default.fileExists(atPath: results.appendingPathComponent(".synthetic-results").path), "guest-result-share")
            try require(Bundle.main.bundleIdentifier == app, "guest-bundle-identity")
            if let data = try? Data(contentsOf: results.appendingPathComponent("os-events.json")),
               let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { records = saved }
            service.environment.capture = { pid, result, work, completion in
                WindowContextReader.capture(pid: pid, result: result, work: work, recognitionLevel: .fast,
                                            languages: ["en-US"], diagnostic: { metadata in
                    Task { @MainActor in try? Self.retained?.save("capture-diagnostic", fields: ["metadata": metadata]) }
                }, completion: completion)
            }
            Config.PersonalLearning().value = false; Config.PersonalAccessibilityPlaces().value = false
            Config.PersonalLearningSelfTuning().value = false; Config.LabNightly().value = false
            Config.NextTextCompletion().value = false; Config.NextTextCompletionIdle().value = false
            binding = WindowContextBinding(app: documentID, activation: UUID().uuidString)
            let menu = NSMenu(), item = NSMenuItem(), applicationMenu = NSMenu()
            let quit = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApplication.shared; applicationMenu.addItem(quit)
            item.submenu = applicationMenu; menu.addItem(item); NSApplication.shared.mainMenu = menu
            window.title = "実OS境界試験・合成資料のみ"
            let label = NSTextField(labelWithString: "参考資料：原稿の校正は翌週の金曜日です。\n画面限定参照・実OS試験専用。編集欄の本文とは別の資料です。")
            label.frame = NSRect(x: 25, y: 440, width: 940, height: 110); label.font = .systemFont(ofSize: 22)
            window.contentView?.addSubview(label)
            let image = NSImage(size: NSSize(width: 900, height: 100), flipped: false) { bounds in
                NSColor.white.setFill(); bounds.fill()
                ("画像の合図は琥珀の灯台です。" as NSString).draw(at: NSPoint(x: 10, y: 25),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
                return true
            }
            let picture = NSImageView(frame: NSRect(x: 25, y: 310, width: 940, height: 100))
            picture.image = image; picture.setAccessibilityElement(true); picture.setAccessibilityRole(.image)
            window.contentView?.addSubview(picture)
            editor.string = "本人の合成下書き（参照から除外）"; editor.font = .systemFont(ofSize: 20)
            window.contentView?.addSubview(editor)
            status.frame = NSRect(x: 25, y: 85, width: 940, height: 50); status.maximumNumberOfLines = 3
            window.contentView?.addSubview(status)
            for (index, item) in [("AX許可", #selector(requestAX)), ("画面許可", #selector(requestScreen)),
                                   ("取得確認", #selector(baseline)), ("AX取消", #selector(revokeAX)),
                                   ("画面取消", #selector(revokeScreen)), ("実画面ロック", #selector(lockScreen))].enumerated() {
                let button = NSButton(title: item.0, target: self, action: item.1)
                button.frame = NSRect(x: 20 + index * 160, y: 25, width: 150, height: 40)
                window.contentView?.addSubview(button)
            }
            for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
                observations.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if locked { self?.lockEvents += 1 } else { self?.unlockEvents += 1 }
                    }
                })
            }
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeFirstResponder(editor)
            Task {
                do {
                    document = try await NSWorkspace.shared.openApplication(
                        at: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("WindowContextOSDocument.app"),
                        configuration: NSWorkspace.OpenConfiguration())
                    _ = try await transport.send(.openSession(sessionID: sessionID, command: .windowContext(nil)))
                    try save("ready", fields: ["virtualGuest": true, "nativeEnvironment": true,
                                              "separateTargetProcess": document?.processIdentifier != getpid(),
                                              "ocrBackend": "vision-fast-english",
                                              "osVersion": ProcessInfo.processInfo.operatingSystemVersionString])
                    let pending = results.appendingPathComponent("screen-revocation-restart.json")
                    if FileManager.default.fileExists(atPath: pending.path) {
                        perform { try await self.verifyScreenAfterRestart(pending) }
                    }
                } catch { report(error) }
            }
        }
        @objc func requestAX() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        @objc func requestScreen() {
            Task.detached { _ = CGRequestScreenCaptureAccess() }
        }
        func perform(_ body: @escaping @MainActor () async throws -> Void) {
            guard !running else { return }; running = true; status.stringValue = "検証中"
            Task {
                defer { running = false }
                do { try await body(); status.stringValue = "完了。結果はResultsに保存" }
                catch { report(error) }
            }
        }
        func report(_ error: Error) {
            status.stringValue = "失敗：\(error)"
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.025)
            var focused: CFTypeRef?
            let liveAX = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focused)
            try? save("failure", fields: ["reason": String(describing: error), "ax": AXIsProcessTrusted(),
                "liveAXError": liveAX.rawValue,
                "screen": CGPreflightScreenCaptureAccess(), "state": service.status.state,
                "bound": service.lease.binding != nil, "reference": service.lease.latest != nil,
                "frontMatches": NSWorkspace.shared.frontmostApplication?.processIdentifier == document?.processIdentifier,
                "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, "processID": getpid(),
                "frontApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unavailable"])
        }
        func wait(_ seconds: Double, label: String = "deadline", _ condition: () -> Bool) async throws {
            let end = Date().addingTimeInterval(seconds)
            while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(25)) }
            try require(condition(), label)
        }
        func command(_ value: ConverterSessionCommand) async throws -> ConverterServerResponse {
            try await transport.send(.session(sessionID: sessionID, command: value))
        }
        func key() async throws -> ConverterServerResponse {
            eventID += 1
            return try await command(.handleKeyEvent(.init(eventID: eventID,
                event: .init(modifierFlags: [], characters: "こ", charactersIgnoringModifiers: "こ", keyCode: 0),
                inputStyle: .direct, liveConversionEnabled: true, enableDebugWindow: false, enableSuggestion: false,
                enablePredictiveTyping: false, enableTypoCorrection: false,
                context: .init(windowBinding: binding), scene: .init(bundleID: documentID, documentLength: 0, startedEmpty: true))))
        }
        func acquire(ocr: Bool) async throws -> WindowContextReceipt {
            guard let document, !document.isTerminated else { throw Failure.check("document-process") }
            document.activate(options: [])
            try await wait(5, label: "foreground-process") {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == document.processIdentifier
            }
            try await Task.sleep(for: .milliseconds(500))
            Config.WindowContextEnabled().value = true; service.configure()
            _ = try await command(.composition(.stopComposition))
            _ = try await command(.windowContext(binding))
            try await wait(10, label: "ax-reference") { service.lease.latest?.blocks.contains(where: { $0.text.contains("画面限定参照") }) == true }
            try save("ax-acquired", fields: ["screen": CGPreflightScreenCaptureAccess(), "generation": service.lease.generation])
            if ocr {
                try await wait(100, label: "ocr-reference") { service.lease.latest?.blocks.contains(where: { $0.source == .ocr && $0.text.contains("AMBER") }) == true }
            }
            _ = try await key()
            let value = try session
            try require(value.windowReference?.blocks.contains(where: { $0.text.contains("下書き") }) == false, "editor-excluded")
            guard let receipt = service.receipt(for: value) else { throw Failure.check("reference-receipt") }
            _ = value.offers.chooseEmpty(.init(.idle, text: "合成の参照付き提案"), skeleton: nil, now: 1, temporal: false)
            value.lastKeyEventResponse?.snapshot.nextTextCompletion = "合成の参照付き提案"
            return receipt
        }
        func verifyBoundary(_ receipt: WindowContextReceipt) async throws {
            let response = try await command(.validateWindowContext(receipt))
            let value = try session
            try require(!response.handled && value.windowReference == nil && value.manager.windowReference == nil, "receipt-rejected")
            try require(service.lease.latest == nil && service.lease.generation != receipt.generation, "lease-cleared")
            try require(value.offers.current == nil && value.pendingCompletion == nil && value.lastKeyEventResponse?.snapshot.nextTextCompletion == nil, "proposal-cleared")
            _ = try await command(.composition(.stopComposition))
            let fallback = try await key()
            try require(fallback.handled && !fallback.snapshot.convertTarget.isEmpty && fallback.windowContextReceipt == nil, "ordinary-input")
            _ = try await command(.composition(.stopComposition))
        }
        @objc func baseline() { perform {
            _ = try await self.acquire(ocr: CGPreflightScreenCaptureAccess())
            try self.save("capture", fields: ["ax": AXIsProcessTrusted(), "screen": CGPreflightScreenCaptureAccess(),
                "ocr": self.service.lease.latest?.blocks.contains(where: { $0.source == .ocr }) == true,
                "editorExcluded": true, "realAnonymousXPC": true])
        } }
        @objc func revokeAX() { revoke("Accessibility") }
        @objc func revokeScreen() { revoke("ScreenCapture") }
        func revoke(_ permission: String) { perform {
            let receipt = try await self.acquire(ocr: permission == "ScreenCapture")
            let acknowledgment = self.results.appendingPathComponent(".revoked-" + permission)
            if FileManager.default.fileExists(atPath: acknowledgment.path) { try FileManager.default.removeItem(at: acknowledgment) }
            try self.save("revoking", fields: ["permission": permission, "generation": receipt.generation,
                                               "method": "system-settings-toggle"])
            self.status.stringValue = "VMの設定画面で当アプリの許可をオフにしてください"
            try await self.wait(300, label: "settings-toggle-acknowledged") {
                FileManager.default.fileExists(atPath: acknowledgment.path)
            }
            if permission == "ScreenCapture", CGPreflightScreenCaptureAccess() {
                // macOS can defer this revocation until process exit, as its settings dialog states.
                // Keep only the receipt (no reference text) to check rejection in the next process.
                try await self.verifyBoundary(receipt)
                let pending = self.results.appendingPathComponent("screen-revocation-restart.json")
                try JSONEncoder().encode(receipt).write(to: pending, options: .atomic)
                try self.save("revocation-awaiting-restart", fields: ["permission": permission,
                    "settingsOffAcknowledged": true, "effectiveScreenPermission": true,
                    "receiptRejected": true, "cachesCleared": true, "ordinaryInput": true])
                return
            }
            try await self.wait(180, label: "native-permission-revoked") {
                permission == "Accessibility" ? !WindowContextReader.accessibilityAllowed() : !CGPreflightScreenCaptureAccess()
            }
            try await self.wait(3) { self.service.lease.latest == nil }
            try await self.verifyBoundary(receipt)
            try self.save("revocation-boundary", fields: ["permission": permission, "receiptRejected": true,
                "cachesCleared": true, "ordinaryInput": true, "settingsOffAcknowledged": true])
            try await self.wait(180, label: "input-window-after-revocation") {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == self.document?.processIdentifier
            }
            _ = try await self.command(.windowContext(self.binding))
            _ = try await self.key()
            try await Task.sleep(for: .milliseconds(2500))
            if permission == "Accessibility" {
                try require(self.service.lease.latest == nil && (try self.session).windowReference == nil, "revoked-must-not-reacquire")
            } else {
                try require(self.service.lease.latest?.blocks.contains(where: { $0.source == .ocr }) != true,
                            "revoked-screen-must-not-reacquire-ocr")
                try require((try self.session).windowReference?.blocks.contains(where: { $0.source == .ocr }) != true,
                            "revoked-screen-session-must-not-use-ocr")
            }
            try self.save("revoked", fields: ["permission": permission, "ax": AXIsProcessTrusted(),
                "screen": CGPreflightScreenCaptureAccess(), "receiptRejected": true, "cachesCleared": true,
                "ordinaryInput": true, "method": "system-settings-toggle",
                "liveAXAllowed": WindowContextReader.accessibilityAllowed(),
                "reacquisitionBlocked": permission == "Accessibility", "ocrReacquisitionBlocked": true])
        } }
        func verifyScreenAfterRestart(_ pending: URL) async throws {
            try require(!CGPreflightScreenCaptureAccess(), "native-screen-revoked-after-restart")
            let old = try JSONDecoder().decode(WindowContextReceipt.self, from: Data(contentsOf: pending))
            let response = try await command(.validateWindowContext(old))
            try require(!response.handled && (try session).windowReference == nil, "old-process-receipt-rejected")
            _ = try await acquire(ocr: false)
            try await Task.sleep(for: .milliseconds(2500))
            guard let reference = service.lease.latest else { throw Failure.check("ax-fallback-after-screen-revoke") }
            try require(reference.blocks.contains(where: { $0.source == .accessibility }), "ax-fallback")
            try require(!reference.blocks.contains(where: { $0.source == .ocr }), "no-ocr-after-screen-revoke")
            _ = try await command(.composition(.stopComposition))
            let fallback = try await key()
            try require(fallback.handled && !fallback.snapshot.convertTarget.isEmpty, "ordinary-input-after-restart")
            try save("revoked", fields: ["permission": "ScreenCapture", "screen": false,
                "liveAXAllowed": WindowContextReader.accessibilityAllowed(), "axFallback": true,
                "ocrReacquisitionBlocked": true, "oldProcessReceiptRejected": true,
                "ordinaryInput": true, "method": "system-settings-toggle-restart"])
            try FileManager.default.removeItem(at: pending)
        }
        @objc func lockScreen() { perform {
            let receipt = try await self.acquire(ocr: CGPreflightScreenCaptureAccess())
            let before = self.lockEvents, unlocks = self.unlockEvents
            try self.save("locking", fields: ["generation": receipt.generation])
            try require(virtualGuest() && AXIsProcessTrusted(), "guest-key-posting-only")
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: down)!
                event.flags = [.maskCommand, .maskControl]; event.post(tap: .cghidEventTap)
            }
            try await self.wait(15) { self.lockEvents > before }
            try await self.verifyBoundary(receipt)
            try self.save("locked", fields: ["nativeLockNotifications": self.lockEvents - before,
                "receiptRejected": true, "cachesCleared": true, "ordinaryInput": true])
            try await self.wait(300) { self.unlockEvents > unlocks }
            let value = try self.session
            try require(value.windowReference == nil, "unlock-must-not-restore")
            let old = try await self.command(.validateWindowContext(receipt))
            try require(!old.handled, "old-receipt-after-unlock")
            try self.save("unlock-observed", fields: ["nativeUnlockNotifications": self.unlockEvents - unlocks,
                "oldReceiptRejected": true, "oldReferenceAbsent": true])
            // Reacquisition starts when the synthetic input window is selected again after login.
            try await self.wait(180, label: "input-window-after-unlock") {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == self.document?.processIdentifier
            }
            try await Task.sleep(for: .milliseconds(500))
            _ = try await self.acquire(ocr: false)
            try self.save("unlocked", fields: ["nativeUnlockNotifications": self.unlockEvents - unlocks,
                "oldReceiptRejected": true, "newReferenceAcquired": true])
        } }
        func save(_ stage: String, fields: [String: Any]) throws {
            var item = fields; item["stage"] = stage; item["time"] = Date().timeIntervalSince1970
            records.append(item)
            let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: results.appendingPathComponent("os-events.json"), options: .atomic)
        }
    }
}
