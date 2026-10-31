// Compiled only by test_client_initialization.py; no IME registration or real XPC.
import Cocoa
import Core
import InputMethodKit

final class InitializationClient: NSObject, IMKTextInput {
    var marked = "", inserted = ""
    var markedCalls = 0, insertedCalls = 0, queries = 0, keyboardOverrides = 0
    var inIMKCallback = false, callbackQueries = 0, callbackMutations = 0
    var usesMarkedReplacementRanges = false, ignoresMarkedReplacementRanges = false
    var reportsEmptyMarkedRangeAtCursor = false
    var supportsDocumentAccess = false, ignoresCallbackMutations = false
    var selectionOverride: NSRange?, markedOverride: NSRange?
    var markedReplacementRanges: [NSRange] = [], markedStrings: [String] = []
    var documentView: NSTextView?
    var onQuery: (() -> Void)?
    private func query() {
        self.queries += 1
        if self.inIMKCallback { self.callbackQueries += 1 }
        self.onQuery?()
    }
    func insertText(_ string: Any!, replacementRange: NSRange) {
        if self.inIMKCallback { self.callbackMutations += 1 }
        if self.inIMKCallback && self.ignoresCallbackMutations { return }
        if let documentView {
            documentView.insertText(string as Any, replacementRange: replacementRange)
            self.insertedCalls += 1
            return
        }
        self.inserted += (string as? String ?? (string as? NSAttributedString)?.string ?? "")
        self.marked = ""; self.insertedCalls += 1
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        if self.inIMKCallback { self.callbackMutations += 1 }
        if self.inIMKCallback && self.ignoresCallbackMutations { return }
        self.markedReplacementRanges.append(replacementRange)
        self.markedStrings.append(string as? String ?? (string as? NSAttributedString)?.string ?? "")
        if let documentView {
            documentView.setMarkedText(string as Any, selectedRange: selectionRange, replacementRange: replacementRange)
            self.markedCalls += 1
            return
        }
        if self.usesMarkedReplacementRanges, !self.ignoresMarkedReplacementRanges,
           replacementRange.location != NSNotFound, NSMaxRange(replacementRange) <= self.inserted.utf16.count {
            self.inserted = (self.inserted as NSString).replacingCharacters(in: replacementRange, with: "")
        }
        self.marked = string as? String ?? (string as? NSAttributedString)?.string ?? ""
        self.markedCalls += 1
    }
    func selectedRange() -> NSRange { self.query(); return self.documentView?.selectedRange() ?? self.selectionOverride ?? .init(location: self.inserted.utf16.count + self.marked.utf16.count, length: 0) }
    func markedRange() -> NSRange { self.query(); return self.documentView?.markedRange() ?? self.markedOverride ?? (self.marked.isEmpty ? .init(location: self.reportsEmptyMarkedRangeAtCursor ? self.inserted.utf16.count : NSNotFound, length: 0) : .init(location: self.inserted.utf16.count, length: self.marked.utf16.count)) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { self.query(); return .init(string: "") }
    func length() -> Int { self.query(); return (self.documentView?.string ?? (self.inserted + self.marked)).utf16.count }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { self.query(); return 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        self.query(); lineRect?.pointee = .init(x: 200, y: 200, width: 1, height: 18); return [:]
    }
    func validAttributesForMarkedText() -> [Any]! { self.query(); return [] }
    func overrideKeyboard(withKeyboardNamed name: String!) { self.query(); self.keyboardOverrides += 1 }
    func selectMode(_ modeIdentifier: String!) { self.query() }
    func supportsUnicode() -> Bool { self.query(); return true }
    func bundleIdentifier() -> String! { self.query(); return "dev.tomonari.imk-initialization-test" }
    func windowLevel() -> CGWindowLevel { self.query(); return 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { self.query(); return self.supportsDocumentAccess && property == kTSMDocumentSupportDocumentAccessPropertyTag }
    func uniqueClientIdentifierString() -> String! { self.query(); return "initialization-test" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        self.query(); let text = (self.documentView?.string ?? (self.inserted + self.marked)) as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
        actualRange?.pointee = range; return text.substring(with: range)
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { self.query(); return .init(x: 200, y: 200, width: 1, height: 18) }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String = "condition", line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
        exit(1)
    }
}

private enum ExceptionChainSpy { static var calls = 0 }


@MainActor private func testPastedTextPreservation() -> Int {
    let previousClient = ShizukuInputController.initializationTestClient
    let previousTransport = ConverterServerClient.initializationTestTransport
    defer {
        ShizukuInputController.initializationTestClient = previousClient
        ConverterServerClient.initializationTestTransport = previousTransport
    }
    func drain() {
        let deadline = Date().addingTimeInterval(0.08)
        while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: deadline) }
    }
    var cases = 0
    for (prefix, foreignMark) in [("Ruri v3 30M", true), ("Ruri v3 30M", false), ("前の文😀。\nRuri v3 30M", true)] {
        let client = InitializationClient(), document = NSTextView()
        client.documentView = document
        if foreignMark {
            // A client can retain a composition range belonging to the paste.
            document.setMarkedText(prefix, selectedRange: NSRange(location: prefix.utf16.count, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            document.insertText(prefix, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        ShizukuInputController.initializationTestClient = client
        var step = 0
        var firstContext: String?
        var pendingCommit: (() -> Void)?
        ConverterServerClient.initializationTestTransport = { command, reply in
            let session: ConverterSessionCommand
            switch command {
            case .openSession(_, let value), .session(_, let value): session = value
            default: preconditionFailure("Unexpected global command")
            }
            if case .composition(.commit) = session {
                pendingCommit = { reply(.init(snapshot: .empty)) }
                return
            }
            guard case .handleKeyEvent(let request) = session else { reply(nil); return }
            if step == 0 && request.event.keyCode == 17 { firstContext = request.context.leftSideContext }
            let finished = request.event.keyCode == 36 || request.event.keyCode == 51
            let reading = finished ? "" : ["t", "っt", "って"][min(step, 2)]
            if !finished { step += 1 }
            var snapshot = ConverterSessionSnapshot.empty
            snapshot.markedText = .init(elements: reading.isEmpty ? [] : [.init(content: reading, focus: .unfocused)],
                selectionRange: .init(location: reading.utf16.count, length: 0))
            snapshot.isEmpty = finished
            reply(.init(effects: request.event.keyCode == 36 ? [.insertText("って")] : [],
                        inputState: finished ? .none : .composing, snapshot: snapshot))
        }
        let controller = ShizukuInputController(server: nil, delegate: nil, client: client)!
        controller.activateServer(client); drain()
        func key(_ code: UInt16, _ characters: String) {
            client.inIMKCallback = true
            let handled = controller.handle(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)!, client: client)
            client.inIMKCallback = false
            check(handled)
            drain()
        }
        for (code, characters) in [(UInt16(17), "t"), (17, "t"), (14, "e")] {
            key(code, characters)
            check(document.string.hasPrefix(prefix), "Starting/updating a composition must preserve pasted text")
        }
        check(firstContext == prefix, "Pasted text must remain available as the conversion context")
        key(36, "\r")
        check(document.string == prefix + "って", "Typing after paste must append and commit at the caret")
        cases += 1
        step = 0
        key(17, "t"); key(51, "\u{7f}")
        check(document.string == prefix + "って", "Clearing Shizuku's composition must preserve committed text")
        cases += 1
        // A commit callback can arrive after the application has pasted new text.
        let pasted = "貼り付け😀" + prefix
        document.setMarkedText(pasted, selectedRange: NSRange(location: pasted.utf16.count, length: 0),
                               replacementRange: NSRange(location: 0, length: document.string.utf16.count))
        controller.commitComposition(client); drain()
        check(pendingCommit != nil, "The empty commit regression must exercise a real asynchronous response")
        pendingCommit?(); drain()
        check(document.string == pasted, "An empty commit response must preserve pasted text")
        cases += 1
        check(client.callbackQueries == 0 && client.callbackMutations == 0,
              "Paste handling must not add synchronous proxy calls inside handle")
        controller.deactivateServer(client); drain()
    }
    let selectedClient = InitializationClient(), selectedDocument = NSTextView()
    selectedClient.documentView = selectedDocument
    selectedDocument.string = "前Ruri v3 30M後"
    selectedDocument.setSelectedRange(NSRange(location: 1, length: "Ruri v3 30M".utf16.count))
    ShizukuInputController.initializationTestClient = selectedClient
    let selectedController = ShizukuInputController(server: nil, delegate: nil, client: selectedClient)!
    let implicit = NSRange(location: NSNotFound, length: 0)
    selectedController.setClientMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: implicit, client: selectedClient)
    check(selectedDocument.string == "前Ruri v3 30M後", "An empty snapshot must preserve an application selection")
    selectedController.setClientMarkedText("って", selectionRange: NSRange(location: 2, length: 0), replacementRange: implicit, client: selectedClient)
    selectedController.insertClientText("って", replacementRange: implicit, client: selectedClient)
    check(selectedDocument.string == "前って後", "An intentional selection must still be replaced when typing")
    // Electron clients can report an unknown selection as a 32-bit NSNotFound, or a stale one. Without an
    // application-owned marked range, starting a composition must leave the replacement range implicit.
    let unknown = NSRange(location: Int(Int32.max), length: 0)
    for (selection, marked) in [(unknown, unknown), (NSRange(location: 57, length: 0), unknown), (unknown, NSRange(location: 0, length: 3))] {
        let chromiumClient = InitializationClient()
        chromiumClient.selectionOverride = selection; chromiumClient.markedOverride = marked
        ShizukuInputController.initializationTestClient = chromiumClient
        let chromiumController = ShizukuInputController(server: nil, delegate: nil, client: chromiumClient)!
        chromiumController.setClientMarkedText("k", selectionRange: NSRange(location: 1, length: 0), replacementRange: implicit, client: chromiumClient)
        chromiumController.setClientMarkedText("か", selectionRange: NSRange(location: 1, length: 0), replacementRange: implicit, client: chromiumClient)
        check(chromiumClient.markedReplacementRanges.count == 2 && chromiumClient.markedReplacementRanges.allSatisfy { $0.location == NSNotFound },
              "An unknown or unowned selection must not become an explicit composition start")
    }
    // Chromium applies only the difference between compositions. An insertion before an unchanged tail
    // ("t" -> "っt") must reach the client as a tail replacement followed by an append.
    let tailClient = InitializationClient()
    ShizukuInputController.initializationTestClient = tailClient
    let tailController = ShizukuInputController(server: nil, delegate: nil, client: tailClient)!
    for text in ["t", "っt", "って"] {
        tailController.setClientMarkedText(NSAttributedString(string: text, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
                                           selectionRange: NSRange(location: text.utf16.count, length: 0), replacementRange: implicit, client: tailClient)
    }
    check(tailClient.markedStrings == ["t", "っ", "っt", "って"], "An insertion before the composition tail must be split into end-only updates")
    check(tailClient.markedReplacementRanges.allSatisfy { $0.location == NSNotFound }, "Split composition updates must keep the replacement implicit")
    tailController.insertClientText("って", replacementRange: implicit, client: tailClient)
    tailController.setClientMarkedText("t", selectionRange: NSRange(location: 1, length: 0), replacementRange: implicit, client: tailClient)
    check(tailClient.markedStrings.last == "t" && tailClient.markedStrings.count == 5, "A new composition must not be compared with committed text")
    return cases + 7
}

#if !CLIENT_LIFETIME_TEST && !MENU_VALIDATION_ONLY
@main struct ClientInitializationTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        // Volatile domains override the App Group without writing either preference file.
        let preferences: [String: Any] = [
            Config.LiveConversion.key: false,
            Config.PersonalLearning.key: false,
            Config.PersonalInputModeSwitching.key: false,
            Config.NextTextCompletion.key: false,
            Config.NextTextCompletionIdle.key: false,
            Config.PromptHistory.key: Data("[]".utf8)
        ]
        Config.userDefaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        check(!Config.LiveConversion().value && !Config.PersonalLearning().value && !Config.NextTextCompletion().value)
        let client = InitializationClient()
        ShizukuInputController.initializationTestClient = client
        var transportCalls = 0, keyRequests: [ConverterKeyEventRequest] = []
        var showCandidates = false
        var pendingReply: (() -> Void)?
        var delayReply = false
        var dropReplies = false
        ConverterServerClient.initializationTestTransport = { command, reply in
            #if !INITIALIZATION_MEASURE_ONLY
            check(!client.inIMKCallback, "Server dispatch must not run inside the synchronous key callback")
            #endif
            transportCalls += 1
            let session: ConverterSessionCommand
            switch command {
            case .openSession(_, let c), .session(_, let c): session = c
            default: preconditionFailure("Unexpected global command")
            }
            guard case .handleKeyEvent(let request) = session else {
                reply(nil); return
            }
            keyRequests.append(request)
            if dropReplies { return }
            let enter = request.event.keyCode == 36
            var snapshot = ConverterSessionSnapshot.empty
            snapshot.markedText = .init(elements: enter ? [] : [.init(content: "きょう", focus: .unfocused)], selectionRange: .init(location: enter ? 0 : 3, length: 0))
            snapshot.isEmpty = enter
            if showCandidates && !enter { snapshot.candidateWindow = .composing([.init(text: "今日")], selectionIndex: nil) }
            let response = ConverterServerResponse(effects: enter ? [.insertText("今日")] : [], inputState: enter ? .none : .composing, snapshot: snapshot)
            if delayReply { pendingReply = { reply(response) } } else { reply(response) }
        }
        let initialWindows = NSApp.windows.count
        var becameKey = 0
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { becameKey += 1 }
        }
        var controllers: [ShizukuInputController] = [], initMs: [Double] = []
        for _ in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            let controller = ShizukuInputController(server: nil, delegate: nil, client: client)!
            initMs.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            controllers.append(controller)
        }
        let windowsAfterInit = NSApp.windows.count - initialWindows
        check(transportCalls == 0, "init must not send XPC commands")
        #if !INITIALIZATION_MEASURE_ONLY
        check(initMs.allSatisfy { $0 < 50 }, "Every init, including the first, must be under 50 ms")
        check(windowsAfterInit == 0, "init must not construct any windows")
        check(client.queries == 0 && client.keyboardOverrides == 0, "init must not query the input client")
        #endif
        let controller = controllers[0]
        check(controller.recognizedEvents(client) == 1 << NSEvent.EventType.keyDown.rawValue, "Inherited IMK receiver must recognize keyDown")
        check(controller.responds(to: NSSelectorFromString("handleEvent:client:")), "IMK handleEvent receiver must exist")
        let queryCount = client.queries
        let activationStart = ProcessInfo.processInfo.systemUptime
        controller.activateServer(client)
        let activationMs = (ProcessInfo.processInfo.systemUptime - activationStart) * 1000
        #if !INITIALIZATION_MEASURE_ONLY
        check(activationMs < 50, "Activation must return in under 50 ms")
        check(transportCalls == 0 && client.queries == queryCount && client.keyboardOverrides == 0,
                     "activateServer must return before preference/client setup or XPC")
        check(NSApp.windows.count == initialWindows, "activation/hiding must not create windows")
        #endif
        // First key arrives before deferred activation work. It still carries activation/config.
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], targetClient: InitializationClient? = nil) -> Bool {
            let receiver = targetClient ?? client
            receiver.inIMKCallback = true
            defer { receiver.inIMKCallback = false }
            return controller.handle(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!, client: receiver)
        }
        func drain() {
            let deadline = Date().addingTimeInterval(0.08)
            while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: deadline) }
        }
        #if !INITIALIZATION_MEASURE_ONLY
        // IMK asks for/validates the menu between keys, without a user opening it.
        // A remote getter here may reenter deactivateServer before the reply arrives.
        var reentrantDeactivations = 0
        client.onQuery = { reentrantDeactivations += 1; controller.deactivateServer(client) }
        let menuQueries = client.queries
        let menu = controller.menu()!
        for item in menu.items { _ = controller.validateMenuItem(item) }
        menu.update()
        check(controller.menu() === menu, "Menu must be constructed only once")
        FileHandle.standardOutput.write(Data("menuProxyCalls=\(client.queries - menuQueries) reentrantDeactivations=\(reentrantDeactivations)\n".utf8))
        check(client.queries == menuQueries && reentrantDeactivations == 0,
              "menu construction and validation must not query the remote client")
        client.onQuery = nil
        #endif
        check(key(40, "k"))
        #if !INITIALIZATION_MEASURE_ONLY
        check(client.callbackQueries == 0, "Normal handle must return before any synchronous client query")
        check(transportCalls == 0, "Normal handle must queue dispatch after returning to IMK")
        let queriesBeforeMenu = client.queries
        _ = controller.menu()
        for item in menu.items { _ = controller.validateMenuItem(item) }
        check(client.queries == queriesBeforeMenu, "Menu calls while a key is queued must not query or deactivate the client")
        #endif
        drain()
        check(client.marked == "きょう" && client.markedCalls > 0, "Normal key must set marked text")
        check(keyRequests.first?.activation != nil, "First key must carry activation")
        check(key(36, "\r")); drain()
        check(client.inserted == "今日" && client.insertedCalls == 1, "Enter must insert committed text")
        #if !INITIALIZATION_MEASURE_ONLY
        for (code, chars, modifiers) in [(UInt16(48), "\t", NSEvent.ModifierFlags()), (48, "\t", .control),
                                         (53, "\u{1b}", []), (18, "1", .command)] {
            check(!key(code, chars, modifiers: modifiers), "Unowned keys must pass through")
        }
        check(client.callbackQueries == 0, "Normal typing and unowned Tab/Ctrl+Tab/Esc must not query the client inside handle")
        check(NSApp.windows.count == initialWindows, "Hidden/empty snapshots must not create UI")
        check(client.keyboardOverrides == 1, "Deferred setup must run exactly once")
        // A deactivated field must not run queued setup or apply a late response to the next field.
        delayReply = true
        check(key(40, "k")); drain()
        let markedCalls = client.markedCalls
        controller.deactivateServer(client)
        pendingReply?(); drain()
        check(client.markedCalls == markedCalls, "Stale response must not paint a deactivated client")
        delayReply = false
        controller.activateServer(client)
        controller.deactivateServer(client)
        let overrides = client.keyboardOverrides
        drain()
        check(client.keyboardOverrides == overrides, "Cancelled activation must not query the client")
        controller.activateServer(client); drain()
        check(client.keyboardOverrides == overrides + 1)
        check(NSApp.windows.count == initialWindows)
        // Reserve all rapid keys before the first deferred dispatch. Their order/config survive.
        let firstRapid = keyRequests.count
        for (code, chars) in [(UInt16(40), "k"), (16, "y"), (31, "o"), (32, "u"), (36, "\r")] { check(key(code, chars)) }
        check(keyRequests.count == firstRapid, "Rapid keys must wait until the callback has returned")
        drain()
        check(Array(keyRequests.dropFirst(firstRapid)).map(\.event.keyCode) == [40, 16, 31, 32, 36], "Deferred dispatch must preserve key order")
        // Deactivation between handle and its queued dispatch must cancel the old field's key.
        let beforeCancelledDispatch = keyRequests.count
        check(key(40, "k")); controller.deactivateServer(client); drain()
        check(keyRequests.count == beforeCancelledDispatch, "A queued key must not open a session for a deactivated field")
        controller.activateServer(client); drain()
        let beforeReentrantDispatch = keyRequests.count
        client.onQuery = {
            client.onQuery = nil
            controller.deactivateServer(client)
        }
        check(key(40, "k")); drain()
        check(keyRequests.count == beforeReentrantDispatch, "A reentrant deactivation during a deferred getter must cancel dispatch")
        controller.activateServer(client); drain()
        // Real candidate presentation constructs its panel once; hide paths create no other panels.
        showCandidates = true
        check(key(40, "k")); drain()
        check(NSApp.windows.count == initialWindows + 1, "Only the requested candidate panel must be created")
        check(key(36, "\r")); drain()
        controller.deactivateServer(client)
        check(NSApp.windows.count == initialWindows + 1)
        check(menu.items.contains { $0.title == "前に書いた文を入れる…" })
        check(controller.menu() === menu, "Menu must be constructed only once")
        check(NSApp.windows.count == initialWindows + 1, "Menu must not construct panels")
        check(client.callbackQueries == 0, "Typing and Enter must not synchronously query the client in handle")
        // Borderless assistance panels must remain unable to take the document's focus.
        let activeBeforePanels = NSApp.isActive
        let quotePanel = CompletionPopupWindow(), fragmentsPanel = CompletionPopupWindow(), ghostPanel = GhostTextWindow()
        for panel in [quotePanel, fragmentsPanel, ghostPanel] {
            check(panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeKey && !panel.canBecomeMain)
        }
        quotePanel.show(text: "fixture", lineRect: .init(x: 200, y: 200, width: 1, height: 18), rawLines: true)
        fragmentsPanel.show(text: "fixture", lineRect: .init(x: 220, y: 220, width: 1, height: 18), rawLines: true)
        ghostPanel.show(text: "fixture", at: .init(x: 200, y: 200), lineHeight: 18, fontSize: 13)
        drain()
        check(becameKey == 0 && NSApp.isActive == activeBeforePanels && NSApp.keyWindow == nil,
              "Assistance presentation must not activate a key window or the application")
        quotePanel.hide(); fragmentsPanel.hide(); ghostPanel.hide()
        NotificationCenter.default.removeObserver(observer)
        // Personal-menu validation must also avoid client calls when learning is on.
        var learningPreferences = preferences
        learningPreferences[Config.PersonalLearning.key] = true
        Config.userDefaults.setVolatileDomain(learningPreferences, forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(learningPreferences, forName: UserDefaults.argumentDomain)
        controller.activateServer(client); drain()
        let personalMenuQueries = client.queries
        for _ in 0..<5 {
            _ = controller.menu()
            for item in menu.items { _ = controller.validateMenuItem(item) }
            menu.update()
        }
        check(client.queries == personalMenuQueries, "Learning-on menu validation must only use cached app metadata")
        for (code, chars) in [(UInt16(40), "k"), (16, "y"), (31, "o"), (32, "u"), (36, "\r")] { check(key(code, chars)); drain() }
        check(client.callbackQueries == 0, "Learning-on normal typing must not synchronously query the client")
        check(client.callbackMutations == 0, "Normal input must paint only after the synchronous handle callback returns")
        Config.userDefaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        controller.deactivateServer(client)
        // The real IMK proxy can ignore an empty committed replacement. A suffix
        // containing a surrogate pair must still undo, preserving earlier text.
        let undoClient = InitializationClient()
        undoClient.usesMarkedReplacementRanges = true
        undoClient.reportsEmptyMarkedRangeAtCursor = true
        undoClient.supportsDocumentAccess = true
        let prefix = "前の文。", chunk = "試験😀。"
        undoClient.inserted = prefix + chunk
        undoClient.insertText("", replacementRange: .init(location: prefix.utf16.count, length: chunk.utf16.count))
        check(undoClient.inserted == prefix + chunk, "Control must reproduce an ignored empty replacement")
        check(controller.removeCommittedAssistance(chunk, client: undoClient), "Committed assistance must undo through marked text")
        check(undoClient.inserted == prefix && undoClient.marked.isEmpty, "Undo must preserve the preceding document")
        let unsupportedUndo = InitializationClient()
        unsupportedUndo.usesMarkedReplacementRanges = true
        unsupportedUndo.ignoresMarkedReplacementRanges = true
        unsupportedUndo.inserted = prefix + chunk
        check(!controller.removeCommittedAssistance(chunk, client: unsupportedUndo), "Unsupported replacement must allow normal Backspace")
        check(unsupportedUndo.inserted == prefix + chunk && unsupportedUndo.marked.isEmpty, "Unsupported replacement must leave no duplicate or marked text")
        let changedUndo = InitializationClient()
        changedUndo.usesMarkedReplacementRanges = true
        changedUndo.supportsDocumentAccess = true
        changedUndo.inserted = prefix + "別の文。"
        check(!controller.removeCommittedAssistance(chunk, client: changedUndo), "Changed suffix must not be removed")
        check(changedUndo.markedCalls == 0 && changedUndo.inserted == prefix + "別の文。", "Mismatched suffix must remain untouched")
        let activeUndo = InitializationClient()
        activeUndo.usesMarkedReplacementRanges = true
        activeUndo.supportsDocumentAccess = true
        activeUndo.inserted = prefix; activeUndo.marked = chunk
        check(!controller.removeCommittedAssistance(chunk, client: activeUndo), "An active composition must not be treated as committed assistance")
        check(activeUndo.inserted == prefix && activeUndo.marked == chunk && activeUndo.markedCalls == 0, "Existing marked text must remain untouched")
        // IMK may drop updates sent during handle. Exercise the actual Tab/Shift+Tab/Esc
        // path with that behavior, including Backspace before the deferred paint runs.
        let assistanceClient = InitializationClient()
        assistanceClient.ignoresCallbackMutations = true
        assistanceClient.supportsDocumentAccess = true
        assistanceClient.usesMarkedReplacementRanges = true
        assistanceClient.reportsEmptyMarkedRangeAtCursor = true
        assistanceClient.inserted = prefix
        ShizukuInputController.initializationTestClient = assistanceClient
        controller.activateServer(assistanceClient); drain()
        let firstSentence = "これは十三文字より長い試験用の最初の文です。"
        let secondSentence = "こちらは続きの二番目の文です。"
        controller.initializationTestIdleCompletion(firstSentence + secondSentence, left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        check(assistanceClient.markedCalls == 0, "Tab must not mutate the client inside handle")
        drain()
        check(assistanceClient.marked == firstSentence, "Tab must paint exactly one sentence after handle returns")
        check(key(48, "\t", modifiers: .shift, targetClient: assistanceClient)); drain()
        check(assistanceClient.marked == firstSentence + secondSentence, "Shift+Tab must append all visible remainder")
        check(key(51, "\u{7f}", targetClient: assistanceClient)); drain()
        check(assistanceClient.marked == firstSentence, "BS must undo only the most recently appended chunk")
        check(key(53, "\u{1b}", targetClient: assistanceClient)); drain()
        check(assistanceClient.marked.isEmpty && assistanceClient.inserted == prefix, "Esc must clear the staged chunk and preserve earlier text")
        controller.initializationTestIdleCompletion(firstSentence + secondSentence, left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        check(key(51, "\u{7f}", targetClient: assistanceClient)); drain()
        check(assistanceClient.marked.isEmpty && assistanceClient.inserted == prefix, "Immediate BS must cancel a queued chunk without deleting earlier text")
        assistanceClient.inserted = prefix + chunk
        assistanceClient.inIMKCallback = true
        check(controller.queueCommittedAssistanceUndo(chunk, client: assistanceClient))
        check(assistanceClient.inserted == prefix + chunk, "Committed undo must wait until handle returns")
        assistanceClient.inIMKCallback = false; drain()
        check(assistanceClient.inserted == prefix && assistanceClient.marked.isEmpty, "Deferred committed undo must reach the client")
        controller.initializationTestIdleCompletion(firstSentence, left: prefix)
        check(key(48, "\t", targetClient: assistanceClient)); drain()
        check(key(36, "\r", targetClient: assistanceClient))
        check(assistanceClient.inserted == prefix, "Enter must defer its client commit until handle returns")
        drain()
        check(assistanceClient.inserted == prefix + firstSentence && assistanceClient.marked.isEmpty,
              "Enter must commit the staged sentence exactly once")
        assistanceClient.inserted = prefix
        controller.initializationTestIdleCompletion(firstSentence, left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        controller.deactivateServer(assistanceClient); drain()
        check(assistanceClient.marked.isEmpty && assistanceClient.inserted == prefix, "A queued paint must not cross a field deactivation")
        controller.activateServer(assistanceClient); drain()
        controller.initializationTestIdleCompletion(firstSentence, left: prefix)
        check(key(48, "\t", targetClient: assistanceClient)); drain()
        controller.commitComposition(assistanceClient)
        controller.deactivateServer(assistanceClient); drain()
        check(assistanceClient.marked.isEmpty && assistanceClient.inserted == prefix + firstSentence,
              "Explicit composition commit must complete before deactivation invalidates queued work")
        assistanceClient.inserted = prefix
        controller.activateServer(assistanceClient); drain()
        controller.initializationTestIdleCompletion("短い文。", left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        check(key(51, "\u{7f}", targetClient: assistanceClient)); drain()
        check(assistanceClient.inserted == prefix && assistanceClient.marked.isEmpty,
              "BS before a short insertion executes must cancel it without deleting preceding text")
        assistanceClient.inserted = chunk + prefix + chunk
        check(controller.queueCommittedAssistanceUndo(chunk, client: assistanceClient))
        assistanceClient.selectionOverride = NSRange(location: chunk.utf16.count, length: 0)
        drain()
        check(assistanceClient.inserted == chunk + prefix + chunk && assistanceClient.marked.isEmpty,
              "Deferred undo must not follow the caret to another occurrence of the same text")
        assistanceClient.selectionOverride = nil; assistanceClient.inserted = prefix
        controller.initializationTestIdleCompletion(firstSentence, left: prefix)
        check(key(48, "\t", targetClient: assistanceClient)); drain()
        controller.initializationTestExpirePlacedUndo()
        check(key(51, "\u{7f}", targetClient: assistanceClient))
        check(key(51, "\u{7f}", targetClient: assistanceClient)); drain()
        check(assistanceClient.marked == String(firstSentence.dropLast(2)),
              "Consecutive character Backspaces must accumulate while painting is pending")
        check(key(53, "\u{1b}", targetClient: assistanceClient)); drain()
        controller.initializationTestIdleCompletion(firstSentence, left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        check(key(36, "\r", targetClient: assistanceClient))
        controller.commitComposition(assistanceClient)
        controller.deactivateServer(assistanceClient); drain()
        check(assistanceClient.marked.isEmpty && assistanceClient.inserted == prefix + firstSentence,
              "Explicit composition commit must flush even an accepted insertion that has not painted")
        assistanceClient.inserted = prefix
        controller.activateServer(assistanceClient); drain()
        controller.initializationTestIdleCompletion("短い文。次の文。", left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        check(key(48, "\t", targetClient: assistanceClient)); drain()
        check(assistanceClient.inserted == prefix + "短い文。次の文。" && assistanceClient.marked.isEmpty,
              "Immediate consecutive Tabs must accumulate without losing or duplicating chunks")
        assistanceClient.inserted = prefix
        controller.initializationTestIdleCompletion("短い文。", left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        assistanceClient.selectionOverride = NSRange(location: 0, length: 0)
        controller.commitComposition(assistanceClient); drain()
        check(assistanceClient.inserted == prefix && assistanceClient.marked.isEmpty,
              "An unpainted commit must not follow a moved caret")
        assistanceClient.selectionOverride = nil
        controller.initializationTestIdleCompletion("短い文。", left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        check(key(53, "\u{1b}", targetClient: assistanceClient)); drain()
        check(assistanceClient.inserted == prefix + "短い文。" && assistanceClient.marked.isEmpty,
              "Esc must hide assistance without undoing an immediate committed chunk")
        assistanceClient.inserted = prefix
        controller.initializationTestIdleCompletion("短い文。", left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        assistanceClient.selectionOverride = NSRange(location: 0, length: 1)
        _ = key(36, "\r", targetClient: assistanceClient); drain()
        check(!assistanceClient.inserted.contains("短い文。"),
              "Enter must not rebind a pending completion to newly selected user text")
        assistanceClient.selectionOverride = nil; assistanceClient.inserted = prefix; assistanceClient.marked = ""
        controller.deactivateServer(assistanceClient); controller.activateServer(assistanceClient); drain()
        controller.initializationTestIdleCompletion("短い文。", left: prefix)
        check(key(48, "\t", targetClient: assistanceClient))
        let beforePendingDigit = keyRequests.count
        check(key(18, "1", targetClient: assistanceClient)); drain()
        check(keyRequests.count == beforePendingDigit + 1 && keyRequests.last?.event.keyCode == 18,
              "A digit after immediate acceptance must reach the converter as ordinary input")
        check(assistanceClient.callbackMutations == 0, "Assistance client mutations must all happen after handle returns")
        ShizukuInputController.initializationTestClient = client
        #endif
        #if !INITIALIZATION_MEASURE_ONLY
        let pastedTextCases = testPastedTextPreservation()
        let previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { _ in ExceptionChainSpy.calls += 1 }
        InputTrace.installExceptionHandler()
        check(NSGetUncaughtExceptionHandler() != nil)
        InputTrace.installExceptionHandler() // Repeated setup must not make the handler call itself.
        NSGetUncaughtExceptionHandler()?(NSException(name: .internalInconsistencyException, reason: "TRACE_PRIVATE_SENTINEL", userInfo: nil))
        check(ExceptionChainSpy.calls == 1, "Exception metadata logging must preserve the earlier handler")
        NSSetUncaughtExceptionHandler(previousExceptionHandler)
        controller.commitComposition(client); drain()
        check(InputTrace.State(.unicodeInput("TRACE_PRIVATE_SENTINEL")) == .unicodeInput)
        check(InputTrace.State(.attachDiacritic("TRACE_PRIVATE_SENTINEL")) == .attachDiacritic)
        check(InputTrace.effectBit(.insertText("TRACE_PRIVATE_SENTINEL")) == 1)
        // Legacy diagnostics must not even evaluate a potentially sensitive interpolation.
        var evaluated = false
        func sensitiveMessage() -> String { evaluated = true; return "TRACE_PRIVATE_SENTINEL" }
        controller.appendDebugMessage(sensitiveMessage())
        check(!evaluated)
        check(!controller.handle(nil, client: client))
        let wrongClientKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        check(!controller.handle(wrongClientKey, client: NSObject()))
        let keyUp = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        check(!controller.handle(keyUp, client: client))
        let commandKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        check(!controller.handle(commandKey, client: client))
        // Exercise the production codec and timeout/retry queue against a proxy that cannot use XPC.
        showCandidates = false
        controller.activateServer(client)
        let beforeTimeout = keyRequests.count
        dropReplies = true
        check(key(40, "k"))
        let timeoutDeadline = Date().addingTimeInterval(1.1)
        while Date() < timeoutDeadline { _ = RunLoop.current.run(mode: .default, before: timeoutDeadline) }
        dropReplies = false
        let retryDeadline = Date().addingTimeInterval(0.5)
        while Date() < retryDeadline { _ = RunLoop.current.run(mode: .default, before: retryDeadline) }
        check(keyRequests.count > beforeTimeout + 1, "Timed out key must retry through the fake proxy")
        check(client.marked == "きょう")
        check(key(36, "\r")); drain()
        InitializationXPCProxy.malformedResponse = true
        check(key(40, "k")); drain()
        InitializationXPCProxy.malformedResponse = false
        let recoveryDeadline = Date().addingTimeInterval(0.5)
        while Date() < recoveryDeadline { _ = RunLoop.current.run(mode: .default, before: recoveryDeadline) }
        check(client.marked == "きょう", "Decode failure must retry without changing rendering")
        check(key(36, "\r")); drain()
        controller.deactivateServer(client)
        var privateSnapshot = ConverterSessionSnapshot.empty
        privateSnapshot.markedText = .init(elements: [.init(content: "TRACE_PRIVATE_SENTINEL", focus: .none)], selectionRange: .init(location: 0, length: 0))
        let privateResponse = ConverterServerResponse(effects: [.insertText("TRACE_PRIVATE_SENTINEL")], inputState: .composing, snapshot: privateSnapshot)
        InputTrace.reply(privateResponse, controller: 0, request: 0)
        // A conservative per-key budget: 14 records, including both calls around text mutations,
        // an asynchronous completion, legacy site metadata, and guard diagnostics.
        @inline(never) func loggedKey() {
            let c = UInt64.max
            InputTrace.event(.handle, controller: c, key: 40, state: .composing)
            InputTrace.event(.queued, controller: c, request: 1)
            InputTrace.event(.send, controller: c, request: 1)
            InputTrace.reply(privateResponse, controller: c, request: 1)
            InputTrace.event(.markedCall, controller: c, request: 1, length: 22)
            InputTrace.event(.markedReturn, controller: c, request: 1, length: 22)
            InputTrace.event(.insertCall, controller: c, request: 1, length: 22)
            InputTrace.event(.insertReturn, controller: c, request: 1, length: 22)
            InputTrace.reply(privateResponse, controller: c, request: 1, completion: true)
            InputTrace.event(.legacy, controller: c, number: 1)
            InputTrace.event(.guardReturn, controller: c, reason: .noResponse)
            InputTrace.event(.guardReturn, controller: c, reason: .staleActivation)
            InputTrace.event(.branch, controller: c, reason: .assistanceVerb)
            InputTrace.event(.transport, controller: c, reason: .noData)
        }
        for _ in 0..<20 { loggedKey() }
        var traceTimes: [Double] = []
        for _ in 0..<1000 {
            let start = ProcessInfo.processInfo.systemUptime
            loggedKey()
            traceTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let sorted = traceTimes.sorted()
        let traceTiming: [String: Any] = ["keys": traceTimes.count, "recordsPerKey": 14,
            "meanMs": traceTimes.reduce(0, +) / Double(traceTimes.count), "medianMs": sorted[500], "p95Ms": sorted[949], "maxMs": sorted.last!]
        check(traceTimes.reduce(0, +) / Double(traceTimes.count) < 0.1 && sorted[949] < 0.1, "Logging mean and p95 must stay below 0.1 ms/key")
        #endif
        var output: [String: Any] = ["initializerMs": initMs, "windowsCreatedInInit": windowsAfterInit,
            "transportCallsInInit": 0, "activationMs": activationMs, "keyRequests": keyRequests.count, "markedCalls": client.markedCalls,
            "insertCalls": client.insertedCalls, "testsPassed": true]
        output["processID"] = ProcessInfo.processInfo.processIdentifier
        output["synchronousQueriesInTestedKeyCallbacks"] = client.callbackQueries
        output["synchronousMutationsInTestedKeyCallbacks"] = client.callbackMutations
        #if !INITIALIZATION_MEASURE_ONLY
        output["traceTiming"] = traceTiming
        output["menuReentrantDeactivations"] = reentrantDeactivations
        output["assistanceWindowsBecameKey"] = becameKey
        output["pastedTextCases"] = pastedTextCases
        output["committedUndoCases"] = 4
        output["deferredAssistanceCases"] = 18
        #endif
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
}
#endif
