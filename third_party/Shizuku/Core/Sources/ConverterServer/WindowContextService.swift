import AppKit
import ApplicationServices
import Core
import Foundation

@MainActor
final class WindowContextService {
    static let shared = WindowContextService()
    struct Environment {
        var permissions: @Sendable () -> (ax: Bool, screen: Bool) = {
            (WindowContextReader.accessibilityAllowed(), CGPreflightScreenCaptureAccess())
        }
        var front: () -> (app: String, pid: pid_t)? = {
            guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
            return (id, app.processIdentifier)
        }
        var workspace: NotificationCenter = NSWorkspace.shared.notificationCenter
        var screen: NotificationCenter = DistributedNotificationCenter.default()
        var read: @Sendable (pid_t) -> WindowReadResult? = { WindowContextReader.read(pid: $0) }
        var capture: @Sendable (pid_t, WindowReadResult, WindowCaptureWork, @escaping @Sendable ([WindowReferenceBlock]) -> Void) -> Void = {
            WindowContextReader.capture(pid: $0, result: $1, work: $2, completion: $3)
        }
    }
    // Dedicated-process tests replace OS signals, while exercising the production lifetime path.
    var environment = Environment()
    private(set) var lease = WindowContextLease()
    private var pid: pid_t?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var axObserver: AXObserver?
    private var axElements: [AXUIElement] = []
    private var observing = false
    private var lastAttempt = Date.distantPast
    private var pendingSince = Date.distantPast
    private var working: UUID?
    private var reading: UUID?
    private var captureWork: WindowCaptureWork?
    private var identity: String?
    private var locked = false
    private var activeSession: ConverterSession?
    private var permissions = (ax: false, screen: false)
    private var permissionProbe: (id: UUID, task: Task<(ax: Bool, screen: Bool), Never>)?
    /// 許可の定期確認は 5 秒ごと（毎回 tccd への問い合わせになるため）
    private var lastPermissionCheck = Date.distantPast
    private var message = "オフ"
    /// 最後にキーを処理した時刻。打鍵中は画面を読まない（入力先のアプリ、とくに Electron 製のアプリの描画を重くしないため）
    private var lastKey = Date.distantPast
    static let typingQuietSeconds: TimeInterval = 1.5

    static func excluded(_ app: String) -> Bool {
        PersonalPrivacy.defaultExcludedApps.contains(app)
            || PersonalPrivacy.userExcludedApps(Config.WindowContextExcludedApps().value).contains(app)
            || app.hasPrefix("dev.tomonari.inputmethod.Shizuku")
    }
    var status: WindowContextStatus {
        .init(state: message, accessibility: permissions.ax, screenRecording: permissions.screen,
              app: lease.binding?.app, updatedAt: lease.latest?.capturedAt)
    }

    func configure() {
        invalidate()
        permissionProbe = nil
        // System-wide AX queries need AppKit initialized even in a headless service.
        if Config.WindowContextEnabled().value, NSApp == nil {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
        permissions = environment.permissions()
        guard Config.WindowContextEnabled().value else { stop(); message = "オフ"; return }
        if permissions.ax && permissions.screen { WindowContextReader.prepareOCR() }
        message = permissions.ax ? "入力先を待っています" : "アクセシビリティの許可が必要です"
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let workspace = environment.workspace
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bind(nil, session: nil) }
            }
            observers.append((workspace, token))
        }
        let distributed = environment.screen
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let token = distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.locked = value; self?.bind(nil, session: nil)
                    if value { NextPromptService.shared.reset() }
                }
            }
            observers.append((distributed, token))
        }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }; observers = []
        removeAXObserver(); pid = nil; lease.bind(nil); activeSession = nil
        NextPromptService.shared.reset()
    }
    private func removeAXObserver() {
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        axObserver = nil; axElements = []; observing = false
    }

    func invalidate() {
        captureWork?.cancel(); captureWork = nil
        removeAXObserver()
        WindowReferenceRetrieval.shared.cancel()
        lease.invalidate(); identity = nil; working = nil; reading = nil
        if let session = activeSession {
            session.windowReference = nil; session.manager.windowReference = nil
            session.windowReferenceGeneration = nil
            session.offers.invalidateGeneration(); session.personal.draftChain.reset()
            session.manager.clearNextTextCompletion(); session.pendingCompletion?.task.cancel(); session.pendingCompletion = nil
            if var response = session.lastKeyEventResponse {
                response.snapshot.nextTextCompletion = nil; response.windowContextReceipt = nil; session.lastKeyEventResponse = response
            }
        }
        NextTextCompletionEngine.shared.discardReferenceContext()
    }

    func bind(_ binding: WindowContextBinding?, session: ConverterSession?) {
        let enabled = Config.WindowContextEnabled().value
        guard enabled, !locked, let binding,
              permissions.ax, !Self.excluded(binding.app), let front = environment.front(),
              front.app == binding.app else {
            if lease.binding != nil { invalidate() }
            lease.bind(nil); activeSession = nil; pid = nil; removeAXObserver()
            message = Config.WindowContextEnabled().value ? "参照していません" : "オフ"
            return
        }
        if lease.binding != binding || pid != front.pid || activeSession !== session {
            invalidate(); lease.bind(binding); activeSession = session; pid = front.pid
            removeAXObserver(); lastAttempt = .distantPast
            pendingSince = Date(); message = "更新待ち"
        }
    }

    func prepare(_ binding: WindowContextBinding?, session: ConverterSession) {
        bind(binding, session: session)
        if session.windowReference?.isFresh(now: Date().timeIntervalSince1970) == false {
            invalidate()
        }
        guard let reference = lease.reference(for: binding, now: Date().timeIntervalSince1970) else {
            session.windowReference = nil; session.manager.windowReference = nil; session.windowReferenceGeneration = nil
            return
        }
        if session.manager.isEmpty || session.windowReference == nil {
            session.windowReference = reference; session.windowReferenceGeneration = lease.generation
            session.manager.windowReference = reference
        }
    }
    /// キーを処理したときに呼ぶ。手を止めるまで、次の読み取りを始めない
    func noteKey() { lastKey = Date() }
    func release(_ session: ConverterSession) { if activeSession === session { bind(nil, session: nil) } }
    func receipt(for session: ConverterSession) -> WindowContextReceipt? {
        guard let binding = session.windowBinding, let reference = session.windowReference,
              let generation = session.windowReferenceGeneration, current(session, generation: generation) else { return nil }
        return .init(binding: binding, generation: generation, expiresAt: reference.capturedAt + 30)
    }
    func validate(_ receipt: WindowContextReceipt, session: ConverterSession) async -> Bool {
        guard await isCurrent(session, generation: receipt.generation, freshPermissions: true) else { return false }
        return receipt.binding == session.windowBinding && Date().timeIntervalSince1970 <= receipt.expiresAt
    }
    func isCurrent(_ session: ConverterSession, generation: UInt64?, freshPermissions: Bool = false) async -> Bool {
        let eventID = session.lastHandledKeyEventID
        guard !Task.isCancelled, current(session, generation: generation) else { return false }
        if generation != nil { await refreshPermissions(fresh: freshPermissions) }
        return !Task.isCancelled && session.lastHandledKeyEventID == eventID && current(session, generation: generation)
    }
    private func current(_ session: ConverterSession, generation: UInt64?) -> Bool {
        guard let generation else { return session.windowReference == nil }
        guard Config.WindowContextEnabled().value, !locked, permissions.ax,
              environment.front()?.pid == pid else { invalidate(); return false }
        guard activeSession === session, lease.generation == generation else { return false }
        guard lease.reference(for: session.windowBinding, now: Date().timeIntervalSince1970) != nil,
              session.windowReference?.isFresh(now: Date().timeIntervalSince1970) == true else { invalidate(); return false }
        return true
    }

    private func refreshPermissions(fresh: Bool = false) async {
        // Adoption must initiate a new probe after any older periodic check finishes.
        if fresh, permissionProbe != nil { await refreshPermissions() }
        let probe: (id: UUID, task: Task<(ax: Bool, screen: Bool), Never>)
        if let permissionProbe { probe = permissionProbe }
        else {
            let check = environment.permissions
            probe = (UUID(), Task.detached(priority: .userInitiated) { check() })
            permissionProbe = probe
        }
        let allowed = await probe.task.value
        guard permissionProbe?.id == probe.id else { return }
        permissionProbe = nil
        if permissions.ax != allowed.ax || permissions.screen != allowed.screen {
            invalidate(); permissions = allowed
            if Config.WindowContextEnabled().value && allowed.ax && allowed.screen { WindowContextReader.prepareOCR() }
        }
    }

    private func changed(boundary: Bool) {
        if boundary { invalidate() }
        pendingSince = Date()
    }
    private struct Observation: @unchecked Sendable {
        var observer: AXObserver
        var elements: [AXUIElement]
    }
    private func installObserver(pid: pid_t, result: WindowReadResult) {
        guard axObserver == nil, !observing else { return }
        observing = true
        let generation = lease.generation
        WindowContextReader.queue.async {
            var observer: AXObserver?
            let code = AXObserverCreate(pid, { _, _, notification, _ in
                let boundary = [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
                                kAXSelectedChildrenChangedNotification, kAXTitleChangedNotification,
                                kAXUIElementDestroyedNotification].contains(notification as String)
                DispatchQueue.main.async { WindowContextService.shared.changed(boundary: boundary) }
            }, &observer)
            var observation: Observation?
            if code == .success, let observer {
                let elements = [AXUIElementCreateApplication(pid), result.window] + result.boundaries
                for element in elements {
                    AXUIElementSetMessagingTimeout(element, 0.01)
                    for name in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
                                 kAXTitleChangedNotification, kAXValueChangedNotification, kAXLayoutChangedNotification,
                                 kAXUIElementDestroyedNotification, kAXSelectedChildrenChangedNotification] {
                        AXObserverAddNotification(observer, element, name as CFString, nil)
                    }
                }
                observation = Observation(observer: observer, elements: elements)
            }
            let installed = observation
            DispatchQueue.main.async {
                guard self.lease.generation == generation, self.pid == pid else { return }
                self.observing = false
                guard let installed else { return }
                self.axObserver = installed.observer; self.axElements = installed.elements
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(installed.observer), .commonModes)
            }
        }
    }

    private func tick() {
        guard Config.WindowContextEnabled().value else { configure(); return }
        if permissionProbe == nil, Date().timeIntervalSince(lastPermissionCheck) >= 5 {
            lastPermissionCheck = Date()
            Task { await self.refreshPermissions() }
        }
        guard !locked, let binding = lease.binding, let pid,
              environment.front()?.pid == pid, !Self.excluded(binding.app) else {
            if lease.binding != nil { bind(nil, session: nil) }; return
        }
        guard permissions.ax else { message = "アクセシビリティの許可が必要です"; return }
        if let latest = lease.latest, !latest.isFresh(now: Date().timeIntervalSince1970) { invalidate() }
        // 打鍵中・入力中の文字があるときは読まない（参考資料は 30 秒まで前の読み取りを使う）
        guard Date().timeIntervalSince(lastKey) >= Self.typingQuietSeconds, activeSession?.manager.isEmpty ?? true else { return }
        guard working == nil, Date().timeIntervalSince(lastAttempt) >= 2,
              Date().timeIntervalSince(pendingSince) >= 0.5 else { return }
        lastAttempt = Date()
        let ticket = UUID(), generation = lease.generation
        let work = WindowCaptureWork()
        captureWork = work
        working = ticket
        reading = ticket
        // AX calls can time out in another process. Retire late results without waiting on them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard self.working == ticket, self.reading == ticket else { return }
            self.invalidate(); self.message = "表示中の文章を取得できません"
        }
        let read = environment.read
        WindowContextReader.queue.async {
            guard !work.cancelled else { return }
            let result = read(pid)
            DispatchQueue.main.async {
                self.accept(result, pid: pid, ticket: ticket, generation: generation, binding: binding)
            }
        }
    }

    private func accept(_ result: WindowReadResult?, pid: pid_t, ticket: UUID, generation: UInt64, binding: WindowContextBinding) {
        guard working == ticket, lease.generation == generation, lease.binding == binding,
              environment.front()?.pid == pid else { return }
        guard working == ticket, lease.generation == generation, permissions.ax, !locked else { return }
        reading = nil
        guard let result else { invalidate(); message = "表示中の文章を取得できません"; return }
        if let identity, identity != result.identity {
            invalidate(); message = "入力先の変更を確認中"; return
        }
        identity = result.identity
        // ターミナル: 欄そのものが画面の全体なので、今の行より前を参考資料にする。OCR はしない
        let terminal = PersonalPrivacy.terminalApps.contains(binding.app)
        let extra = terminal ? result.fieldBefore.map { WindowReference.terminalBlocks(fieldBefore: $0) } ?? [] : []
        if terminal {
            WindowContextReader.queue.async {
                let reference = WindowReference(identity: result.identity, capturedAt: Date().timeIntervalSince1970,
                                                blocks: result.blocks + extra, editing: result.editing, fieldBefore: result.fieldBefore, fieldEmpty: result.fieldEmpty)
                Task { @MainActor in
                    await self.publish(reference, pid: pid, ticket: ticket, generation: generation, binding: binding, complete: true)
                }
            }
            installObserver(pid: pid, result: result)
            return
        }
        if result.needsOCR, !result.blocks.isEmpty {
            // A slow OCR path must not withhold successfully acquired AX text.
            WindowContextReader.queue.async {
                let reference = WindowReference(identity: result.identity, capturedAt: Date().timeIntervalSince1970, blocks: result.blocks,
                                                editing: result.editing, fieldBefore: result.fieldBefore, fieldEmpty: result.fieldEmpty)
                Task { @MainActor in
                    await self.publish(reference, pid: pid, ticket: ticket, generation: generation, binding: binding, complete: false)
                }
            }
        }
        installObserver(pid: pid, result: result)
        // A timeout retires the ticket; delayed capture/OCR callbacks cannot reinstall it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if self.working == ticket { self.captureWork?.cancel(); self.captureWork = nil; self.working = nil }
        }
        guard let work = captureWork else { return }
        let capture = environment.capture
        WindowContextReader.queue.async {
            guard !work.cancelled else { return }
            capture(pid, result, work) { blocks in
                WindowContextReader.queue.async {
                    guard !work.cancelled else { return }
                    let reference = WindowReference(identity: result.identity, capturedAt: Date().timeIntervalSince1970, blocks: blocks,
                                                    editing: result.editing, fieldBefore: result.fieldBefore, fieldEmpty: result.fieldEmpty)
                    Task { @MainActor in
                        await self.publish(reference, pid: pid, ticket: ticket, generation: generation, binding: binding, complete: true)
                    }
                }
            }
        }
    }

    private func publish(_ reference: WindowReference, pid: pid_t, ticket: UUID, generation: UInt64,
                         binding: WindowContextBinding, complete: Bool) async {
        guard working == ticket, lease.generation == generation else { return }
        await refreshPermissions()
        guard working == ticket, lease.generation == generation, lease.binding == binding,
              Config.WindowContextEnabled().value, permissions.ax, !locked, environment.front()?.pid == pid else { return }
        if complete { working = nil; captureWork = nil }
        if lease.install(reference, generation: generation, now: Date().timeIntervalSince1970) {
            NextPromptService.shared.observe(reference, binding: binding, session: activeSession)
        }
        message = reference.blocks.isEmpty ? "参照できる文章がありません" : "表示中の文章を参照しています"
    }
}
