import Core
import Darwin
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import os

private enum ConverterServerXPC {
    static let machServiceName = "dev.tomonari.inputmethod.Shizuku.ConverterServer"
}

@objc protocol ConverterServerXPCProtocol {
    func openSession(with reply: @escaping @Sendable (String) -> Void)
    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void)
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void)
}

final class ConverterServer: NSObject, ConverterServerXPCProtocol, @unchecked Sendable {
    private static let learningDataCommitDelay: TimeInterval = 2

    private var sessions: [String: ConverterSession] = [:]
    let kanaKanjiConverter = KanaKanjiConverter.withDefaultDictionary()
    private let learningDataCommitScheduler = DebouncedActionScheduler()
    private var inputPrepared = false

    @MainActor
    func prepareInputResources() {
        let started = ProcessInfo.processInfo.systemUptime
        // The client's one-shot startup synchronization can expire while the model
        // is compiling. Dictionary initialization must not depend on that request.
        var dictionaryPrepared = false
        do {
            _ = try handle(.synchronizeUserDictionary(forceExport: false))
            dictionaryPrepared = true
        } catch { }
        inputPrepared = dictionaryPrepared && kanaKanjiConverter.prepareZenzaiModel(at:
            SegmentsManager.conversionModelURL(resourcesDirectoryURL: Self.appResourcesDirectoryURL()))
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        Logger(subsystem: "dev.tomonari.inputmethod.Shizuku", category: "startup")
            .notice("phase=input_resources ready=\(self.inputPrepared) dictionary=\(dictionaryPrepared) milliseconds=\(milliseconds)")
    }

    func openSession(with reply: @escaping @Sendable (String) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let sessionID = UUID().uuidString
                self.createSessionIfNeeded(sessionID)
                reply(sessionID)
            }
        }
    }

    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let session = self.sessions.removeValue(forKey: sessionID)
                if let session {
                    WindowContextService.shared.release(session)
                    self.abandonStall(session: session)
                    session.finishPersonalClosing()
                    session.personal.resetField()
                    PersonalSensing.shared.release(session: session)
                    self.kanaKanjiConverter.removeSession(session.conversionSessionID)
                }
                let removed = session != nil
                reply(removed)
            }
        }
    }

    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void) {
        // A ready response must cross the same executor as conversion, not only the XPC queue.
        DispatchQueue.main.async {
            let ready = message != "input-ready" || self.inputPrepared
            if message == "input-ready" {
                reply(ready ? "ConverterServer: input-ready-v1" : "ConverterServer: input-unavailable")
            } else {
                reply("ConverterServer: \(message)")
            }
        }
    }

    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void) {
        // キー入力の応答はユーザー操作のクリティカルパスなので、システム負荷が高い時も
        // utility/background work より先に実行される優先度で Server actor へ渡す。
        Task(priority: .userInitiated) { @MainActor in
            do {
                let command = try ConverterServerCodec.decodeCommand(from: data)
                let response = try await self.handle(command)
                self.learningDataCommitScheduler.postponeIfScheduled(
                    after: Self.learningDataCommitDelay
                )
                reply(try ConverterServerCodec.encode(response), nil)
            } catch {
                self.learningDataCommitScheduler.postponeIfScheduled(
                    after: Self.learningDataCommitDelay
                )
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    @MainActor
    private func handle(_ command: ConverterServerCommand) async throws -> ConverterServerResponse {
        switch command {
        case .shutdown:
            PersonalLearner.shared.flush()
            Self.scheduleShutdown()
            return ConverterServerResponse(snapshot: .empty)
        case .maintenance(let command):
            return try handle(command)
        case .openSession(let sessionID, let command):
            createSessionIfNeeded(sessionID)
            return try await handle(command, sessionID: sessionID)
        case .session(let sessionID, let command):
            return try await handle(command, sessionID: sessionID)
        }
    }

    @MainActor
    private func createSessionIfNeeded(_ sessionID: String) {
        guard sessions[sessionID] == nil else {
            return
        }
        let conversionSessionID = kanaKanjiConverter.createSession()
        sessions[sessionID] = ConverterSession(
            manager: Self.makeSegmentsManager(kanaKanjiConverter: kanaKanjiConverter),
            conversionSessionID: conversionSessionID
        )
    }

    @MainActor
    private func handle(_ command: ConverterMaintenanceCommand) throws -> ConverterServerResponse {
        switch command {
        case .synchronizeUserDictionary(let forceExport):
            let memoryDirectoryURL = AppGroup.memoryDirectoryURL()
            if forceExport || !CompiledUserDictionaryStore.hasExportedDictionary(memoryDirectoryURL: memoryDirectoryURL) {
                try CompiledUserDictionaryStore.exportCurrentDictionaries(memoryDirectoryURL: memoryDirectoryURL)
            }
            kanaKanjiConverter.updateUserDictionaryURL(
                CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryDirectoryURL),
                forceReload: true
            )
        case .resetLearningData:
            kanaKanjiConverter.resetMemory()
            // llm-ime: 場面学習の記録と覚えた語もまとめて消す
            PersonalLearner.shared.deleteAll()
        }
        return ConverterServerResponse(snapshot: .empty)
    }

    @MainActor
    private func handle(_ command: ConverterSessionCommand, sessionID: String) async throws -> ConverterServerResponse {
        let response = try await executeSessionCommand(command, sessionID: sessionID)
        if PersonalLearner.isRecording, PersonalLearner.shared.hasOfferHistory {
            switch command {
            case .completion(.assistance), .completion(.quotes), .completion(.retained), .completion(.teach), .completion(.undoTeach):
                break // 記録だけの応答で、再送用の入力表示を空にしない。
            case .completion, .composition(.snapshot):
                let session = try getSession(sessionID)
                if var cached = session.lastKeyEventResponse {
                    cached.snapshot = response.snapshot
                    session.lastKeyEventResponse = cached
                }
            default: break
            }
        }
        return response
    }

    @MainActor
    private func executeSessionCommand(_ command: ConverterSessionCommand, sessionID: String) async throws -> ConverterServerResponse {
        let session = try getSession(sessionID)
        switch command {
        case .lifecycle(let command):
            return try withConverterSession(session) {
                handle(command, session: session)
            }
        case .settings(let command):
            return try withConverterSession(session) {
                try handle(command, session: session)
            }
        case .validateWindowContext(let receipt):
            return ConverterServerResponse(handled: await WindowContextService.shared.validate(receipt, session: session), snapshot: .empty)
        case .windowContext(let binding):
            session.setWindowBinding(binding)
            WindowContextService.shared.bind(binding, session: session)
            var response = ConverterServerResponse(snapshot: .empty)
            response.windowContextStatus = WindowContextService.shared.status
            return response
        case .updateConfig(let config):
            return try withConverterSession(session) {
                session.config = config
                return makeResponse(for: session, inputState: .none)
            }
        case .handleKeyEvent(let request):
            return try withConverterSession(session) {
                try handleKeyEvent(sessionID: sessionID, request: request)
            }
        case .composition(let command):
            return try withConverterSession(session) {
                handle(command, session: session)
            }
        case .candidate(let command):
            return try withConverterSession(session) {
                handle(command, session: session)
            }
        case .replaceSuggestion(let command):
            return try await handle(command, session: session)
        case .completion(let command):
            return try await handle(command, session: session)
        case .localLLM(let command):
            return await handle(command, session: session)
        }
    }

    @MainActor
    private func withConverterSession<Result>(
        _ session: ConverterSession,
        operation: () throws -> Result
    ) throws -> Result {
        try kanaKanjiConverter.withSession(session.conversionSessionID, operation: operation)
    }

    @MainActor
    private func handle(
        _ command: ConverterSessionLifecycleCommand,
        session: ConverterSession
    ) -> ConverterServerResponse {
        switch command {
        case .activate:
            session.quoteCandidates = []; session.retentionChecks = session.retentionChecks.filter { Date().timeIntervalSince1970 - $0.value.check.started <= 600 }
            session.beginOfferStop()
            session.personal.skeletonOffer = nil
            session.emptyOfferScene = nil
            session.finishPersonalClosing()
            session.personal.fieldContext.reset()
            session.personal.completionLeft = nil
            self.noteStallEntry(session: session)
            session.manager.activate()
            return makeResponse(for: session, inputState: session.inputState)
        case .deactivate:
            WindowContextService.shared.release(session)
            session.quoteCandidates = []; session.retentionChecks = session.retentionChecks.filter { Date().timeIntervalSince1970 - $0.value.check.started <= 600 }
            session.beginOfferStop()
            session.personal.skeletonOffer = nil
            session.emptyOfferScene = nil
            session.finishPersonalClosing()
            session.personal.fieldContext.reset()
            session.personal.completionLeft = nil
            self.abandonStall(session: session)
            // アプリ切替直後のキー入力を、学習データの同期I/Oで塞がない。
            // 共有Converterはプロセス内に残るため、永続化だけ入力のアイドル時まで遅延できる。
            session.manager.deactivate(flushLearningData: false)
            PersonalSensing.shared.release(session: session)
            scheduleLearningDataCommit()
            session.inputState = .none
            session.clearReplaceSuggestions()
            return makeResponse(for: session, inputState: session.inputState)
        case .synchronizeInputLanguage(let language):
            session.inputLanguage = language
            if language == .english {
                session.manager.stopJapaneseInput()
            }
            return makeResponse(
                for: session,
                inputState: session.inputState
            )
        case .observeInputMode(let bundleID, let language, let switched):
            // llm-ime: 場面に合わせた入力モード（観測を数えるだけ。切り替えるかは IME 本体の設定で決まる）
            PersonalLearner.shared.recordInputMode(app: bundleID, language: language, switched: switched)
            return makeResponse(for: session, inputState: session.inputState)
        case .preferredInputMode(let bundleID):
            if PersonalLearner.isRecording, !PersonalPrivacy.isExcluded(app: bundleID) {
                self.noteStallEntry(session: session)
            }
            var response = makeResponse(for: session, inputState: session.inputState)
            response.inputLanguage = PersonalLearner.shared.preferredInputMode(app: bundleID)
            return response
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterSettingsCommand,
        session: ConverterSession
    ) throws -> ConverterServerResponse {
        switch command {
        case .list(let capabilities):
            return makeResponse(
                for: session,
                inputState: .none,
                settings: Self.makeSettingDescriptors(capabilities: capabilities)
            )
        case .update(let key, let value):
            try Self.updateSetting(key: key, value: value)
            return makeResponse(for: session, inputState: .none)
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterCompositionCommand,
        session: ConverterSession
    ) -> ConverterServerResponse {
        switch command {
        case .snapshot:
            return makeResponse(for: session, inputState: session.inputState)
        case .stopComposition:
            session.beginOfferStop()
            session.personal.skeletonOffer = nil
            session.emptyOfferScene = nil
            self.abandonStall(session: session)
            session.manager.stopComposition()
            session.inputState = .none
            return makeResponse(for: session, inputState: session.inputState)
        case .forgetMemory:
            session.manager.forgetMemory()
            return makeResponse(for: session, inputState: session.inputState)
        case .commit:
            let text = session.manager.commitMarkedText(inputState: session.inputState)
            let effects: [ConverterClientEffect] = text.isEmpty ? [] : [.insertText(text)]
            session.inputState = .none
            return makeResponse(
                for: session,
                inputState: session.inputState,
                effects: effects,
                responseInputState: ConverterInputState.none
            )
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterCandidateCommand,
        session: ConverterSession
    ) -> ConverterServerResponse {
        switch command {
        case .selectCandidate(let index):
            session.manager.requestSelectingRow(index)
            self.observeStallDepth(session: session, depth: session.manager.currentSelectionIndex)
            session.inputState = .selecting
            return makeResponse(for: session, inputState: session.inputState)
        case .submitSelectedCandidate(let context):
            session.setContext(context)
            var effects: [ConverterClientEffect] = []
            submitSelectedCandidate(
                manager: session.manager,
                leftSideContext: session.conversionLeftSideContext(),
                effects: &effects
            )
            let nextInputState: InputState = session.manager.isEmpty ? .none : .previewing
            session.inputState = nextInputState
            return makeResponse(
                for: session,
                inputState: nextInputState,
                effects: effects,
                responseInputState: ConverterInputState(nextInputState)
            )
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterReplaceSuggestionCommand,
        session: ConverterSession
    ) async throws -> ConverterServerResponse {
        switch command {
        case .request(let context):
            session.setContext(context)
            let composingText = session.manager.convertTarget
            try await requestReplaceSuggestion(session: session)
            return try withConverterSession(session) {
                // llm-ime: 生成を待つ間（ローカル LLM では数秒）に入力が進んだ場合は状態を変えない
                guard session.manager.convertTarget == composingText else {
                    return makeResponse(for: session, inputState: session.inputState)
                }
                session.inputState = .replaceSuggestion
                return makeResponse(
                    for: session,
                    inputState: session.inputState,
                    responseInputState: .replaceSuggestion
                )
            }
        case .cancelGenerated:
            return try withConverterSession(session) {
                PersonalLearner.shared.recordReaction(kind: "ai_cancelled", scene: session.personal.scene)
                session.clearReplaceSuggestions(); session.inputState = .composing
                var response = makeResponse(for: session, inputState: .composing)
                let reading = session.manager.convertTarget
                response.snapshot.markedText = .init(elements: [.init(content: reading, focus: .unfocused)], selectionRange: .init(location: reading.utf16.count, length: 0))
                return response
            }
        case .appendFragments(let all):
            return try withConverterSession(session) {
                if session.inputState == .replaceSuggestion, let index = session.replaceSuggestionSelectionIndex {
                    let fragments = magicFragments(session: session)
                    let chosen = all ? fragments : Array(fragments.prefix(1))
                    if !chosen.isEmpty { session.replaceSuggestions[index].text += " " + chosen.joined(separator: " ") }
                }
                return makeResponse(for: session, inputState: session.inputState)
            }
        case .selectReplaceSuggestionCandidate(let index):
            return try withConverterSession(session) {
                PersonalLearner.shared.recordReaction(kind: "ai_cycled", scene: session.personal.scene)
                session.selectReplaceSuggestion(at: index)
                session.inputState = .replaceSuggestion
                return makeResponse(
                    for: session,
                    inputState: session.inputState,
                    responseInputState: .replaceSuggestion
                )
            }
        case .submitSelectedReplaceSuggestion, .submitGenerated:
            return try withConverterSession(session) {
                var effects: [ConverterClientEffect] = []
                let didSubmit = submitSelectedReplaceSuggestion(session: session, effects: &effects)
                let nextInputState: InputState = didSubmit ? .none : .replaceSuggestion
                session.inputState = nextInputState
                let response = makeResponse(
                    for: session,
                    inputState: nextInputState,
                    effects: effects,
                    responseInputState: ConverterInputState(nextInputState)
                )
                return response
            }
        }
    }

    @MainActor
    func magicFragments(session: ConverterSession) -> [String] {
        guard let candidate = session.selectedReplaceSuggestion else { return [] }
        return PersonalFragments.missing(input: session.manager.convertTarget, output: candidate.text, tokens: session.magicTokens)
    }

    private static func scheduleShutdown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            PersonalLearner.shared.flush()
            exit(EXIT_SUCCESS)
        }
    }

    @MainActor
    private func scheduleLearningDataCommit() {
        learningDataCommitScheduler.schedule(after: Self.learningDataCommitDelay) { [weak self] in
            self?.kanaKanjiConverter.commitUpdateLearningData()
        }
    }

    @MainActor
    func getSession(_ sessionID: String) throws -> ConverterSession {
        guard let session = sessions[sessionID] else {
            throw ConverterServerError.unknownSession(sessionID)
        }
        return session
    }

}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    let server = ConverterServer()

    @MainActor
    func prepareInputResources() { server.prepareInputResources() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ConverterServerXPCProtocol.self)
        connection.exportedObject = server
        connection.resume()
        return true
    }
}

if CommandLine.arguments.contains("--window-context-self-test") {
    do { try MainActor.assumeIsolated { try WindowContextSelfTests.run() }; exit(0) }
    catch { print("window_context_native FAIL"); exit(1) }
}
if CommandLine.arguments.contains("--window-context-live-self-test") {
    MainActor.assumeIsolated { WindowContextSelfTests.startLive() }
}
if CommandLine.arguments.contains(WindowContextOperatingSystemTests.flag) || WindowContextTestRuntime.operatingSystemFixture {
    MainActor.assumeIsolated { WindowContextOperatingSystemTests.start() }
}
if CommandLine.arguments.contains(WindowContextTestRuntime.flag) {
    MainActor.assumeIsolated { WindowContextEndToEndTests.start() }
}

// This mode never initializes personalization or registers another service.
if CommandLine.arguments.contains("--wait-ready") {
    exit(ConverterServerReadiness.wait() ? EXIT_SUCCESS : EXIT_FAILURE)
}

// azooKey の名前だった頃の設定とデータを、使い始める前に引き継ぐ
AppGroup.migratePreferencesFromAzooKeyIfNeeded()
AppGroup.migrateDataFromAzooKeyIfNeeded()
AssistanceSettings.migrateIfNeeded()
// llm-ime: 場面学習の記録を裏で開き、覚えた語を読み込んでおく。自己調整を 10 分ごとに見る
// llm-ime: 確かめ用の記録の場所（通しの確かめのときだけ）の準備・後片付け
PersonalLearner.prepareTestStoreIfNeeded()
PersonalLearner.shared.prepare()
MainActor.assumeIsolated {
    // 解析と学習: 前の実行の残り（本人の文章を含む写し）を消し、今の版の値を入れる
    LabController.shared.startup()
    ConverterResourceStatus.start()
    WindowContextService.shared.configure()
    PersonalSensing.shared.configure(scene: nil)
    PersonalEmbeddingService.shared.start()
    PersonalTuningScheduler.shared.start()
}

let listener = NSXPCListener(machServiceName: ConverterServerXPC.machServiceName)
private let delegate = ServiceDelegate()
// Core ML can compile a newly installed ANE model for tens of seconds. Finish that
// work before advertising readiness, so the first key does not hit the 1s client timeout.
MainActor.assumeIsolated { delegate.prepareInputResources() }
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
