import Cocoa
import Core
import InputMethodKit
import os

@objc(ShizukuInputController)
class ShizukuInputController: IMKInputController, NSMenuItemValidation {
    /// hide/visibility checks must not construct AppKit objects during IMK activation.
    private final class DeferredUI<Value> {
        private(set) var loaded: Value?
        func value(_ make: () -> Value) -> Value {
            if let loaded { return loaded }
            let value = make()
            self.loaded = value
            return value
        }
    }
    private struct CandidatePanel<Controller> {
        let controller: Controller
        let window: NSWindow
    }

    private var inputTraceID: UInt64 = 0
    private var inputTraceRequestID: UInt64 = 0
    let converterServerClient = ConverterServerClient()
    private var currentConverterView: ConverterSessionSnapshot?
    private var hasClientMarkedText = false
    private(set) var inputState: InputState = .none
    private var inputLanguage: InputLanguage = .japanese
    private var pendingKeyEventCount = 0
    private var nextKeyEventID: UInt64 = 0
    private var activationGeneration: UInt64 = 0
    private var pendingConverterServerActivation: ConverterSessionActivation?
    var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }
    /// llm-ime: `cursorRectForWindows()` 参照
    private var cachedCursorRect: NSRect?
    /// llm-ime: 続き予測を入力中の文字の後ろに薄い灰色で表示するウィンドウと、そのアプリでの文字の大きさ（推定）
    private let ghostUI = DeferredUI<GhostTextWindow>()
    private var ghostTextWindow: GhostTextWindow { self.ghostUI.value { GhostTextWindow() } }
    /// llm-ime: 続き予測を予測変換の候補のように別ウィンドウで出す（既定。灰色の文字はアプリによって位置がずれるため）
    private let completionUI = DeferredUI<CompletionPopupWindow>()
    private var completionPopupWindow: CompletionPopupWindow { self.completionUI.value { CompletionPopupWindow() } }
    /// 灰色の補完の配置の記録（位置の数値だけ。文章は記録しない）
    static let ghostLog = Logger(subsystem: "dev.tomonari.inputmethod.Shizuku", category: "ghost")
    /// キー入力の処理時点の、入力中の文字の先頭の位置（行）・末尾の位置（アプリが返す場合）・文字の大きさ・入力中の文字
    private struct GhostAnchor {
        var startRect: NSRect
        var endX: CGFloat?
        var fontSize: CGFloat
        var markedText: String
    }
    private var ghostAnchor: GhostAnchor?
    private var ghostFontSize: CGFloat?
    /// 直前に確定した文字列と、確定前の入力の先頭の位置（確定後にカーソルが進んだ量から文字の大きさを推定する）
    private var lastCommitForGhost: (text: String, startRect: NSRect)?
    /// llm-ime: 何も入力していない状態で少し待つと出す続き予測。Tab で入れる前に、カーソルより前の文章が
    /// 予測したときと同じか確かめる（マウスでカーソルを動かした場合などに、違う場所へ入れないため）
    private struct IdleCompletion {
        /// 表示中の続き（1 文ずつ伸びる。改行・段落の区切りを含みうる）
        var text: String
        var leftContext: String
        var caretX: CGFloat
        var lineRect: NSRect
        var fontSize: CGFloat
        /// 2 行目以降を置く行頭の位置（推定）
        var lineStartX: CGFloat
        /// 折り返す右端（nil なら折り返さない）
        var rightEdge: CGFloat?
        var referenceReceipt: WindowContextReceipt? = nil
    }
    private var idleCompletion: IdleCompletion?
    private struct PlacedAssistance {
        var text: String
        var remaining: String
        var lastChunk: String
        var time: Date
        var anchor: IdleCompletion
        var commitPending = false
        var continueAfterCommit = true
    }
    private var placedAssistance: PlacedAssistance?
    private var assistanceUndo: (text: String, time: Date)?
    private var placedPresentationVersion: UInt64 = 0
    private var placedPresentationPending = false
    private var placedPendingCaret = 0
    private var placedPendingSelection: NSRange?
    private var placedPendingDocumentLength = 0
    private var dismissedAssistance: Set<String> = []
    private var failedMarkedApps: Set<String> = []
    private var tabTracker = AssistanceVerbs.TabTracker()
    private var observingPassedTab = false
    private var magicInline = false
    private var magicFallbackReading: String?
    private var magicMarkingFailed = false
    private let magicFragmentsUI = DeferredUI<CompletionPopupWindow>()
    private var magicFragmentsWindow: CompletionPopupWindow { self.magicFragmentsUI.value { CompletionPopupWindow() } }
    private var visibleMagicFragments: [String] = []
    private let quoteChoicesUI = DeferredUI<CompletionPopupWindow>()
    private var quoteChoicesWindow: CompletionPopupWindow { self.quoteChoicesUI.value { CompletionPopupWindow() } }
    private var quoteChoices: [String] = []
    private var quoteChoiceIndex = 0
    private var quoteRequestGeneration: UInt64 = 0
    /// llm-ime: 直前の文の清書。三択の 3 番目と、設定でオンにしたときの文末の自動表示
    private let cleanUpUI = DeferredUI<CompletionPopupWindow>()
    private var cleanUpWindow: CompletionPopupWindow { self.cleanUpUI.value { CompletionPopupWindow() } }
    private var cleanUpChoice: (original: String, text: String)?
    private var cleanUpPending = false
    private var cleanUpGeneration: UInt64 = 0
    private var cleanUpUndo: (original: String, text: String, time: Date)?
    private var cleanUpWorkItem: DispatchWorkItem?
    private var cleanUpUsedReference = false
    /// llm-ime: 短い確定が指す画面の選択肢。次のキーで消える
    private let windowHintUI = DeferredUI<CompletionPopupWindow>()
    private var windowHintWindow: CompletionPopupWindow { self.windowHintUI.value { CompletionPopupWindow() } }
    private var windowHintGeneration: UInt64 = 0
    private var retentionWorkItems: [String: DispatchWorkItem] = [:]
    /// Tab で入れた続き予測の位置（文書の中の UTF-16 の位置）と文字列。少し後にカーソルが末尾にあるか確かめる
    private var pendingCaretCheck: (start: Int, text: String)?
    private var idleCompletionWorkItem: DispatchWorkItem?
    /// llm-ime: 空の欄の書き出し（骨組みの先出し）を確かめる予約と、押したキーの数（予約の後にキーを押したら出さない）
    private var skeletonWorkItem: DispatchWorkItem?
    private var keyDownCount: UInt64 = 0
    /// キー入力・確定のたびに進める。古い要求の結果を表示しないため
    private var idleGeneration: UInt64 = 0
    /// 入力を始めたときにアプリに尋ねた、今の行（改行から次の改行まで）の先頭の文字の位置（行頭の位置として最も確か）
    private var observedLineStartX: CGFloat?
    /// 今の行が折り返していたときに観測した、アプリが折り返す右端
    private var observedRightEdge: CGFloat?
    /// 入力先のアプリ（ウィンドウを探すのに使う）
    private var ghostClientBundleID: String?
    /// 1 回の補完で続けて予測する文の数の上限
    private static let draftMaxSentences = 3
    /// 直近のキーイベントで取得した、入力中の文字より前の文章
    private var lastLeftContext: String = ""
    private var lastRightContext: String = ""
    /// 確定後、この秒数だけ何も入力しなければ続きを予測する（Tab で入れた後は待たずに次を予測する）
    private static let idleCompletionDelay: TimeInterval = 3.0
    /// llm-ime: 場面学習の自己調整で決めた待ち時間（Server がキーイベントの応答で返す。なければ既定）
    private var tunedIdleCompletionDelay: TimeInterval?
    /// llm-ime: 場面に合わせた入力モード。入力欄に入ってから最初に文字を打つまでを見る
    private struct InputModeTracking {
        var bundleID: String
        var languageAtActivation: InputLanguage
        /// 英数・かなのキーやメニューで、自分で切り替えた
        var userSwitched = false
        /// 設定がオンで、入った時点で切り替えた先
        var autoSwitched: InputLanguage?
        /// 最初に文字を打った（観測を送った）
        var done = false
        var activatedAt = Date()
    }
    private var inputModeTracking: InputModeTracking?
    /// llm-ime: 場面学習のメタ情報。handle の中で既に問い合わせている値（文書の長さ・フォント）を覚えておき、新しい問い合わせは増やさない
    private var lastDocumentLength: Int?
    private var lastFontIsFixedPitch: Bool?
    /// この欄で、空の状態から書き始めたか（アクティブになるたびに戻す）
    private var fieldStartedEmpty = false
    /// llm-ime: 最後のキーで取った左文脈が、空と分かっていた（"" 。取れなかった nil とは分ける）
    private var lastLeftContextKnownEmpty = false
    /// 確定の直後からアプリに渡したバックスペースの数（次のキーイベントで Server に送る）
    private var countingBackspacesAfterCommit = false
    private var backspacesAfterCommit = 0

    lazy var appMenu = NSMenu(title: "Shizuku")
    lazy var liveConversionToggleMenuItem = NSMenuItem()
    /// llm-ime: 放置で続きを自動生成（何も入力していないときの続き予測）のオン・オフ
    lazy var idleCompletionToggleMenuItem = NSMenuItem()
    lazy var transformSelectedTextMenuItem = NSMenuItem()
    lazy var quoteMenuItem = NSMenuItem()
    lazy var teachMenuItem = NSMenuItem()
    lazy var windowExcludeMenuItem = NSMenuItem()
    lazy var undoTeachMenuItem = NSMenuItem()
    var teachingUndoReceipt: (token: String, until: Date)?

    private let candidatesUI = DeferredUI<CandidatePanel<CandidatesViewController>>()
    private var candidatesPanel: CandidatePanel<CandidatesViewController> {
        self.candidatesUI.value {
            let controller = CandidatesViewController()
            controller.delegate = self
            return CandidatePanel(controller: controller, window: Self.makeCandidateWindow(contentViewController: controller))
        }
    }
    private var candidatesWindow: NSWindow { self.candidatesPanel.window }
    private var candidatesViewController: CandidatesViewController { self.candidatesPanel.controller }

    private let predictionUI = DeferredUI<CandidatePanel<PredictionCandidatesViewController>>()
    private var predictionPanel: CandidatePanel<PredictionCandidatesViewController> {
        self.predictionUI.value {
            let controller = PredictionCandidatesViewController()
            return CandidatePanel(controller: controller, window: Self.makeCandidateWindow(contentViewController: controller))
        }
    }
    private var predictionWindow: NSWindow { self.predictionPanel.window }
    private var predictionViewController: PredictionCandidatesViewController { self.predictionPanel.controller }
    private var lastPredictionCandidates: [String] = []
    private var lastPredictionUpdateTime: TimeInterval = 0
    private var predictionHideWorkItem: DispatchWorkItem?

    private let replaceSuggestionsUI = DeferredUI<CandidatePanel<ReplaceSuggestionsViewController>>()
    private var replaceSuggestionsPanel: CandidatePanel<ReplaceSuggestionsViewController> {
        self.replaceSuggestionsUI.value {
            let controller = ReplaceSuggestionsViewController()
            controller.delegate = self
            return CandidatePanel(controller: controller, window: Self.makeCandidateWindow(contentViewController: controller))
        }
    }
    private var replaceSuggestionWindow: NSWindow { self.replaceSuggestionsPanel.window }
    private var replaceSuggestionsViewController: ReplaceSuggestionsViewController { self.replaceSuggestionsPanel.controller }

    lazy var promptInputWindow = PromptInputWindow()
    var isPromptWindowVisible: Bool = false
    private var activationSetupPending = false
    private var activationSetupWorkItem: DispatchWorkItem?

    // ダブルタップ検出用
    private var lastKey: (time: TimeInterval, code: UInt16) = (0, 0)
    private static let doubleTapInterval: TimeInterval = 0.5
    private static let candidateWindowInitialSize = CGSize(width: 400, height: 1000)

    // ピン留めプロンプトのキャッシュ（パフォーマンス向上のため）
    private var pinnedPromptsCache: [PromptHistoryItem] = []

    // Existing ad-hoc messages can contain text or remote error descriptions. Do not evaluate them.
    func appendDebugMessage(_ message: @autoclosure () -> String, line: Int = #line) {
        InputTrace.event(.legacy, controller: self.inputTraceID, request: self.inputTraceRequestID, number: line)
    }

    private func traceGuard(_ reason: InputTrace.Reason, request: UInt64 = 0, line: Int = #line) {
        InputTrace.event(.guardReturn, controller: self.inputTraceID, request: request, state: InputTrace.State(self.inputState), reason: reason, number: line)
    }

    func setClientMarkedText(_ text: Any, selectionRange: NSRange, replacementRange: NSRange, client: IMKTextInput) {
        let length = (text as? NSAttributedString)?.length ?? (text as? String)?.utf16.count ?? 0
        // Empty snapshots must not clear a selection or composition left by the application.
        guard length > 0 || self.hasClientMarkedText || replacementRange.location != NSNotFound else { return }
        let generation = self.activationGeneration
        // A paste can leave an application-owned marked range. Start our composition at
        // the current selection instead of implicitly replacing that unrelated range.
        let range = length > 0 && !self.hasClientMarkedText && replacementRange.location == NSNotFound
            ? client.selectedRange() : replacementRange
        guard self.activationGeneration == generation else { return }
        InputTrace.event(.markedCall, controller: self.inputTraceID, request: self.inputTraceRequestID, length: length)
        client.setMarkedText(text, selectionRange: selectionRange, replacementRange: range)
        if self.activationGeneration == generation { self.hasClientMarkedText = length > 0 }
        InputTrace.event(.markedReturn, controller: self.inputTraceID, request: self.inputTraceRequestID, length: length)
    }

    func insertClientText(_ text: String, replacementRange: NSRange, client: IMKTextInput) {
        let length = text.utf16.count
        InputTrace.event(.insertCall, controller: self.inputTraceID, request: self.inputTraceRequestID, length: length)
        self.hasClientMarkedText = false
        client.insertText(text, replacementRange: replacementRange)
        InputTrace.event(.insertReturn, controller: self.inputTraceID, request: self.inputTraceRequestID, length: length)
    }

    private static func makeCandidateWindow(contentViewController: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.borderless]
        window.level = .popUpMenu

        // Chromium 系アプリの deadlock 回避のため、初期化時に client への
        // 問い合わせを行わない（Chromium issue 503787240）。
        // ウィンドウは直後に orderOut されるため origin はユーザーから不可視であり、
        // 最初の候補表示時に refreshCandidateWindow() で正しい位置に再配置される。
        var frame = NSRect.zero
        frame.size = candidateWindowInitialSize
        window.setFrame(frame, display: true)
        window.setIsVisible(false)
        window.orderOut(nil)
        return window
    }

    // MARK: - ダブルタップ検出
    private func checkAndUpdateDoubleTap(keyCode: UInt16) -> Bool {
        let now = Date().timeIntervalSince1970
        let isDouble = (self.lastKey.code == keyCode) && (now - self.lastKey.time < Self.doubleTapInterval)
        self.lastKey = (time: now, code: keyCode)
        return isDouble
    }

    /// ピン留めプロンプトのキャッシュを更新
    func reloadPinnedPromptsCache() {
        guard let data = Config.data(forKey: Config.PromptHistory.key),
              let history = try? JSONDecoder().decode([PromptHistoryItem].self, from: data) else {
            self.pinnedPromptsCache = []
            return
        }
        self.pinnedPromptsCache = history.filter { $0.isPinned }
    }

    // MARK: - カスタムプロンプトショートカット検出
    private func checkCustomPromptShortcut(event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return nil
        }

        let key = characters.lowercased()
        let eventModifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)

        // 修飾キーがない場合は早期リターン（通常の入力）
        if eventModifiers.isEmpty {
            return nil
        }

        // キャッシュからショートカット付きのピン留めプロンプトを検索
        if let matched = self.pinnedPromptsCache.first(where: { item in
            guard let itemShortcut = item.shortcut else {
                return false
            }
            return itemShortcut.key == key && itemShortcut.modifiers == eventModifiers
        }) {
            return matched.prompt
        }

        return nil
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        let traceID = InputTrace.allocateID()
        InputTrace.event(.initBegin, controller: traceID)
        super.init(server: server, delegate: delegate, client: inputClient)
        MainActor.assumeIsolated {
            self.setupMenu()
            self.inputTraceID = traceID
            self.converterServerClient.inputTraceID = self.inputTraceID
            InputTrace.event(.initialized, controller: self.inputTraceID)
            self.converterServerClient.onLog = { [weak self] message in
                self?.appendDebugMessage(message)
            }
        }
    }

    @MainActor
    override func activateServer(_ sender: Any!) {
        InputTrace.event(.activate, controller: self.inputTraceID, state: InputTrace.State(self.inputState))
        defer { InputTrace.event(.activateReturn, controller: self.inputTraceID) }
        super.activateServer(sender)
        self.hasClientMarkedText = false
        self.placedAssistance = nil; self.assistanceUndo = nil
        self.placedPresentationVersion &+= 1; self.placedPresentationPending = false
        self.dismissedAssistance.removeAll(); self.tabTracker.reset(); self.observingPassedTab = false
        self.quoteChoicesUI.loaded?.hide(); self.quoteChoices = []; self.quoteRequestGeneration &+= 1
        self.resetCleanUp()
        self.magicInline = false; self.magicFallbackReading = nil; self.magicMarkingFailed = false; self.magicFragmentsUI.loaded?.hide(); self.visibleMagicFragments = []
        self.cachedCursorRect = nil
        self.idleCompletionWorkItem?.cancel()
        self.idleCompletion = nil
        self.hideCompletionDisplay()
        self.observedLineStartX = nil
        self.observedRightEdge = nil
        self.ghostClientBundleID = nil
        self.fieldStartedEmpty = false
        self.countingBackspacesAfterCommit = false
        self.backspacesAfterCommit = 0
        self.activationGeneration &+= 1
        self.pendingConverterServerActivation = nil
        self.activationSetupWorkItem?.cancel()
        self.activationSetupPending = true
        let generation = self.activationGeneration
        // IMK must finish activateServerWithReply before App Group and input-client work.
        let setup = DispatchWorkItem { [weak self] in
            guard let self else {
                InputTrace.event(.guardReturn, controller: 0, reason: .ownerReleased); return
            }
            guard self.activationGeneration == generation else { self.traceGuard(.staleActivation); return }
            self.finishActivationSetup()
        }
        self.activationSetupWorkItem = setup
        DispatchQueue.main.async(execute: setup)
        // Chromium 系アプリで JS コンパイル中に activate された場合、
        // client.attributes(forCharacterIndex:) の同期呼び出しが deadlock を
        // 引き起こすため呼び出さない（Chromium issue 503787240）。
        // refreshCandidateWindow / refreshPredictionWindow は composing/selecting 状態で
        // client.attributes(...) を呼ぶ経路があるため、activate 中は使わずウィンドウを
        // 明示的に閉じる。
        self.candidatesUI.loaded?.controller.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.candidatesUI.loaded?.window.setIsVisible(false)
        self.candidatesUI.loaded?.window.orderOut(nil)
        self.candidatesUI.loaded?.controller.hide()
        self.hidePredictionWindow()
    }

    /// Runs after the IMK callback returns, before dispatching the first queued key.
    @MainActor private func finishActivationSetup() {
        guard self.activationSetupPending else { return }
        self.activationSetupPending = false
        self.activationSetupWorkItem?.cancel()
        self.activationSetupWorkItem = nil
        let client = self.client()
        self.ghostClientBundleID = client?.bundleIdentifier()
        self.reloadPinnedPromptsCache()
        self.pendingConverterServerActivation = ConverterSessionActivation(
            config: self.converterServerSessionConfig,
            inputLanguage: self.inputLanguage
        )
        client?.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        if Config.WindowContextEnabled().value, let binding = self.windowContextBinding {
            self.converterServerClient.sendUnordered({ _ in .windowContext(binding) }) { _ in }
        }
        self.startInputModeTracking()
        self.scheduleSkeleton()
    }

    @MainActor
    override func deactivateServer(_ sender: Any!) {
        InputTrace.event(.deactivate, controller: self.inputTraceID, state: InputTrace.State(self.inputState))
        defer { InputTrace.event(.deactivateReturn, controller: self.inputTraceID) }
        self.activationSetupWorkItem?.cancel()
        self.activationSetupWorkItem = nil
        self.activationSetupPending = false
        self.placedAssistance = nil; self.assistanceUndo = nil
        self.placedPresentationVersion &+= 1; self.placedPresentationPending = false
        self.dismissedAssistance.removeAll(); self.tabTracker.reset(); self.observingPassedTab = false
        self.quoteChoicesUI.loaded?.hide(); self.quoteChoices = []; self.quoteRequestGeneration &+= 1
        self.resetCleanUp()
        self.magicInline = false; self.magicFallbackReading = nil; self.magicMarkingFailed = false; self.magicFragmentsUI.loaded?.hide(); self.visibleMagicFragments = []
        self.cachedCursorRect = nil
        self.activationGeneration &+= 1
        self.pendingConverterServerActivation = nil
        self.converterServerClient.sendIfSessionOpen({ _ in .lifecycle(.deactivate) }, completion: { _ in })
        self.currentConverterView = nil
        self.hasClientMarkedText = false
        self.inputState = .none
        self.candidatesUI.loaded?.window.orderOut(nil)
        self.predictionUI.loaded?.window.orderOut(nil)
        self.replaceSuggestionsUI.loaded?.window.orderOut(nil)
        self.hideCompletionDisplay()
        self.idleCompletionWorkItem?.cancel()
        self.skeletonWorkItem?.cancel()
        self.idleCompletion = nil
        self.candidatesUI.loaded?.controller.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        super.deactivateServer(sender)
    }

    @MainActor
    override func commitComposition(_ sender: Any!) {
        InputTrace.event(.commitComposition, controller: self.inputTraceID, state: InputTrace.State(self.inputState))
        if self.placedAssistance != nil, let client = sender as? IMKTextInput {
            self.commitPlacedAssistance(client: client, afterKeyCallback: false)
            return
        }
        let activationGeneration = self.activationGeneration
        let traceID = self.inputTraceID
        self.converterServerClient.sendIfSessionOpen({ _ in .composition(.commit) }, completion: { [weak self] response in
            Task { @MainActor in
                guard let self else { InputTrace.event(.guardReturn, controller: traceID, reason: .ownerReleased); return }
                guard self.activationGeneration == activationGeneration else { self.traceGuard(.staleActivation); return }
                guard let response else { self.traceGuard(.noResponse); return }
                self.apply(response)
            }
        })
    }

    // MARK: - setValue: 状態同期のみ
    @MainActor
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        InputTrace.event(.setValue, controller: self.inputTraceID, state: InputTrace.State(self.inputState), number: tag)
        defer {
            super.setValue(value, forTag: tag, client: sender)
        }

        if let value = value as? NSString {
            if !self.activationSetupPending {
                self.client()?.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
            }
            let englishMode = value == "com.apple.inputmethod.Roman"

            // llm-ime: 場面に合わせた入力モード。入力欄に入ってから文字を打つ前に、自分でモードを切り替えた
            // （入った直後 0.5 秒はシステムが前のモードを戻す通知なので数えない）
            if var tracking = self.inputModeTracking, !tracking.done, Date().timeIntervalSince(tracking.activatedAt) > 0.5 {
                let language: InputLanguage = englishMode ? .english : .japanese
                if tracking.autoSwitched != language, language != self.inputLanguage {
                    tracking.userSwitched = true
                    self.inputModeTracking = tracking
                }
            }
            if englishMode {
                // 英語モードへの切り替え通知（実際の処理はhandleで行う）
                // メニューバーやshortcut経由の切り替えに対応する。
                // composing中でも英数キーMarkedTextを保ったまま英語入力へ移る。
                if self.inputLanguage == .japanese {
                    self.inputLanguage = .english
                    if !self.activationSetupPending {
                        self.converterServerClient.send(
                            { _ in .lifecycle(.synchronizeInputLanguage(.english)) },
                            completion: { _ in }
                        )
                    }
                    self.refreshCandidateWindow()
                    self.refreshPredictionWindow()
                }
            } else {
                // 日本語モードへの切り替え
                if self.inputLanguage == .english {
                    self.inputLanguage = .japanese
                    if !self.activationSetupPending {
                        self.converterServerClient.send(
                            { _ in .lifecycle(.synchronizeInputLanguage(.japanese)) },
                            completion: { _ in }
                        )
                    }
                }
            }
        }
    }

    override func menu() -> NSMenu! {
        // IMK calls this between keys. Build in init; never mutate items or query the client here.
        InputTrace.event(.menu, controller: self.inputTraceID)
        return self.appMenu
    }

    // swiftlint:disable:next cyclomatic_complexity
    @MainActor override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        defer { InputTrace.event(.handleReturn, controller: self.inputTraceID, state: InputTrace.State(self.inputState)) }
        InputTrace.event(.handle, controller: self.inputTraceID,
                         key: event?.type == .keyDown ? Int(event.keyCode) : -1,
                         modifiers: event?.modifierFlags.rawValue ?? 0, state: InputTrace.State(self.inputState))
        guard let event else { self.traceGuard(.noEvent); return false }
        guard let client = sender as? IMKTextInput else { self.traceGuard(.noClient); return false }
        guard event.type == .keyDown else { self.traceGuard(.notKeyDown); return false }
        if let consumed = self.handleAssistanceVerb(event: event, client: client) {
            InputTrace.event(.branch, controller: self.inputTraceID, reason: .assistanceVerb, number: consumed ? 1 : 0)
            return consumed
        }
        // llm-ime: 空の欄の書き出しは、キーを押したら出さない。何も入力していない状態の Enter（送信）の後は、欄が空になっていれば出す
        self.keyDownCount &+= 1
        self.skeletonWorkItem?.cancel()
        if event.keyCode == 36, self.inputState == .none,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            self.scheduleSkeleton()
        }

        // llm-ime: 場面に合わせた入力モード。入力欄に入ってから最初に文字を打ったときのモードを送る
        self.observeInputMode(event: event)

        // llm-ime: 場面学習。確定の直後にアプリで消した回数を数える（外れの手がかり）。ほかのキーで数えるのをやめる
        if self.countingBackspacesAfterCommit, self.inputState == .none, self.pendingKeyEventCount == 0 {
            if event.keyCode == 51, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                self.backspacesAfterCommit += 1
            } else {
                self.countingBackspacesAfterCommit = false
            }
        }

        // llm-ime: 何も入力していない状態の続き予測（灰色）。Tab なら確かめてから入れ、ほかのキーなら消す
        if let consumed = self.handleIdleCompletionKey(event: event, client: client) {
            InputTrace.event(.branch, controller: self.inputTraceID, reason: .idleVerb, number: consumed ? 1 : 0)
            return consumed
        }

        // カスタムプロンプトショートカットのチェック
        if let matchedPrompt = checkCustomPromptShortcut(event: event) {
            InputTrace.event(.branch, controller: self.inputTraceID, reason: .customPrompt, number: 1)
            let aiBackendEnabled = Config.AIBackendPreference().value != .off
            if aiBackendEnabled && !self.isPromptWindowVisible {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: matchedPrompt) {
                        return true
                    }
                }
            }
            // ショートカットがマッチした場合はイベントを消費して他のハンドラに渡さない
            return true
        }

        let userAction = UserAction.getUserAction(eventCore: event.keyEventCore, inputLanguage: inputLanguage)

        // 英数キー（keyCode 102）の処理
        if event.keyCode == 102 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 102)

            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "english") {
                        InputTrace.event(.branch, controller: self.inputTraceID, reason: .languagePrompt, number: 1)
                        return true
                    }
                }
            }
        }

        // かなキー（keyCode 104）の処理（ダブルタップで日本語への翻訳）
        if event.keyCode == 104 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 104)
            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "japanese") {
                        InputTrace.event(.branch, controller: self.inputTraceID, reason: .languagePrompt, number: 1)
                        return true
                    }
                }
            }
        }

        // Check if AI backend is enabled
        let aiBackendEnabled = Config.AIBackendPreference().value != .off

        // Handle suggest action with selected text check (prevent recursive calls)
        if case .suggest = userAction {
            // Prevent recursive window calls
            if self.isPromptWindowVisible {
                self.traceGuard(.promptVisible)
                self.appendDebugMessage("Suggest action ignored: prompt window already visible")
                return true
            }

            let selectedRange = client.selectedRange()
            self.appendDebugMessage("Suggest action detected. Selected range: \(selectedRange)")
            if selectedRange.length > 0 {
                guard aiBackendEnabled else {
                    self.traceGuard(.backendOff)
                    self.appendDebugMessage("Suggest action ignored: AI backend is off")
                    return false
                }
                InputTrace.event(.branch, controller: self.inputTraceID, reason: .selectedPrompt, number: 1)
                self.appendDebugMessage("Selected text found, showing prompt input window")
                // There is selected text, show prompt input window
                self.showPromptInputWindow()
                return true
            } else {
                self.appendDebugMessage("No selected text, using normal suggest behavior")
            }
        }

        var coreEvent = event.keyEventCore
        let all = event.keyCode == 48 && event.modifierFlags.intersection([.shift, .command, .control, .option]) == .shift && self.assistanceHelpVisible
        if all { coreEvent.modifierFlags.remove(.shift) }
        return self.handleKeyEventWithConverterServer(
            event: coreEvent,
            enableSuggestion: aiBackendEnabled,
            optionDirectInputText: event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.option)),
            assistanceAll: all
        )
    }

    @MainActor
    private func handleKeyEventWithConverterServer(
        event: KeyEventCore,
        enableSuggestion: Bool,
        optionDirectInputText: String? = nil,
        assistanceAll: Bool = false
    ) -> Bool {
        let disposition = ConverterClientEventRouter.disposition(
            event: event,
            context: .init(
                acknowledgedInputState: ConverterInputState(self.inputState),
                acknowledgedInputLanguage: self.inputLanguage,
                hasPendingKeyEvents: self.pendingKeyEventCount > 0,
                liveConversionEnabled: Config.LiveConversion().value,
                enableDebugWindow: Config.DebugWindow().value,
                enableSuggestion: enableSuggestion,
                typeBackSlash: Config.TypeBackSlash().value
            )
        )
        guard disposition == .sendToServer else {
            self.traceGuard(.routerApplication)
            return false
        }
        // Return IMK's handle reply before querying the remote text input client.
        // Reserve ownership now so a rapid following key cannot fall through while
        // the context query and Server dispatch are still queued on the main thread.
        self.pendingKeyEventCount += 1
        self.nextKeyEventID &+= 1
        let eventID = self.nextKeyEventID
        let generation = self.activationGeneration
        let acceptingAssistance = event.keyCode == 48 && self.assistanceHelpVisible
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.activationGeneration == generation else {
                self.pendingKeyEventCount = max(0, self.pendingKeyEventCount - 1)
                self.traceGuard(.staleActivation, request: eventID)
                return
            }
            self.finishActivationSetup()
            guard self.activationGeneration == generation else {
                self.pendingKeyEventCount = max(0, self.pendingKeyEventCount - 1)
                self.traceGuard(.staleActivation, request: eventID)
                return
            }
            self.dispatchKeyEventToConverterServer(event: event, eventID: eventID,
                enableSuggestion: enableSuggestion, optionDirectInputText: optionDirectInputText,
                assistanceAll: assistanceAll, acceptingAssistance: acceptingAssistance)
        }
        return true
    }

    @MainActor private func dispatchKeyEventToConverterServer(
        event: KeyEventCore, eventID: UInt64, enableSuggestion: Bool,
        optionDirectInputText: String?, assistanceAll: Bool, acceptingAssistance: Bool
    ) {
        let generation = self.activationGeneration
        // 入力中の文字より前の文章を先に取得する（行の先頭で入力を始めたかの判定に使う）
        let textContext = self.currentConverterTextContext()
        self.lastLeftContext = textContext.leftSideContext ?? ""
        self.lastRightContext = textContext.rightSideContext ?? ""
        self.lastLeftContextKnownEmpty = textContext.leftSideContext == ""
        if event.keyCode == 49 {
            // 変換（スペース）のときに前の文章が届いているかの記録（文字数だけ）
            Self.ghostLog.notice("space: left context \(textContext.leftSideContext?.count ?? -1) characters")
        }
        if let client = self.client() {
            self.updateCachedCursorRect(client: client)
        }
        // A remote getter can reenter IMK. Never send the old field's key afterward.
        guard self.activationGeneration == generation else {
            self.pendingKeyEventCount = max(0, self.pendingKeyEventCount - 1)
            self.traceGuard(.staleActivation, request: eventID)
            return
        }
        // 前の入力に対する続き予測は、次の予測が届くまで消しておく
        self.hideCompletionDisplay()

        let scene = self.makeSceneObservation()
        let request = ConverterKeyEventRequest(
            eventID: eventID,
            event: event,
            inputStyle: self.inputStyle,
            liveConversionEnabled: Config.LiveConversion().value,
            enableDebugWindow: Config.DebugWindow().value,
            enableSuggestion: enableSuggestion,
            enablePredictiveTyping: Config.DebugPredictiveTyping().value,
            enableTypoCorrection: Config.DebugTypoCorrection().value,
            enableOptionDirectFullWidthInput: Config.OptionDirectFullWidthInput().value,
            typeBackSlash: Config.TypeBackSlash().value,
            optionDirectInputText: optionDirectInputText,
            context: textContext,
            activation: self.pendingConverterServerActivation,
            scene: scene
        )
        self.pendingConverterServerActivation = nil
        let activationGeneration = self.activationGeneration
        let traceID = self.inputTraceID
        InputTrace.event(.queued, controller: traceID, request: request.eventID)
        self.converterServerClient.sendKeyEvent(request) { [weak self] response in
            InputTrace.reply(response, controller: traceID, request: request.eventID)
            Task { @MainActor in
                guard let self else {
                    InputTrace.event(.guardReturn, controller: traceID, request: request.eventID, reason: .ownerReleased)
                    return
                }
                self.pendingKeyEventCount = max(0, self.pendingKeyEventCount - 1)
                guard self.activationGeneration == activationGeneration else {
                    self.traceGuard(.staleActivation, request: request.eventID)
                    return
                }
                guard let response else {
                    self.traceGuard(.noResponse, request: request.eventID)
                    self.appendDebugMessage("ConverterServer dropped key event \(request.eventID)")
                    return
                }
                if !response.handled {
                    self.traceGuard(.delayedFallthrough, request: request.eventID)
                    // `handle` は既に同期的に consume 済み。未応答イベントがある場合は
                    // application へ後からイベントを戻せないため、ここでは漏らさない。
                    self.appendDebugMessage("Consumed delayed fallthrough event \(request.eventID)")
                }
                self.apply(response, requestID: request.eventID)
                self.tunedIdleCompletionDelay = response.idleCompletionDelay
                // 入力が止まったときの変換の見直し（入力中の候補の表示）と続き予測を待って反映する
                if response.inputState.inputState == .composing {
                    self.awaitNextTextCompletion(afterKeyEventID: request.eventID)
                }
                // llm-ime: 確定して何も入力していない状態になったら、少し待って続きを予測する
                let committed = response.effects.compactMap { effect -> String? in
                    if case .insertText(let text) = effect {
                        return text
                    }
                    return nil
                }.joined()
                if acceptingAssistance, !committed.isEmpty {
                    self.assistanceUndo = (committed, Date())
                    self.recordAssistanceVerb(assistanceAll ? "verb_tab_all" : "verb_tab_one", count: committed.count)
                }
                if !acceptingAssistance, response.inputState.inputState == .none, let last = committed.last,
                   "。！？!?".contains(last), let anchor = self.ghostAnchor {
                    self.scheduleCleanUp(leftContext: self.lastLeftContext + committed, lineRect: anchor.startRect)
                }
                if !acceptingAssistance, response.inputState.inputState == .none, !committed.isEmpty,
                   committed.count <= ShortReplyHint.maximumInput, Config.WindowContextEnabled().value,
                   ShortReplyHint.option(in: committed) != nil, let anchor = self.ghostAnchor {
                    self.requestWindowHint(committed, lineRect: anchor.startRect)
                }
                if Self.isIdleCompletionEnabled, response.inputState.inputState == .none, !committed.isEmpty,
                   let anchor = self.ghostAnchor {
                    self.scheduleIdleCompletion(
                        leftContext: self.lastLeftContext + committed,
                        caretX: anchor.startRect.minX + GhostTextWindow.width(of: committed, fontSize: anchor.fontSize),
                        lineRect: anchor.startRect,
                        fontSize: anchor.fontSize
                    )
                }
            }
        }
    }

    /// Menu callbacks must never ask the active application's synchronous proxy.
    var canUsePersonalMenu: Bool {
        guard PersonalLearner.isRecording, let app = self.ghostClientBundleID else { return false }
        return !PersonalPrivacy.isExcluded(app: app)
    }

    /// llm-ime: キーイベントの処理後に Server が始めた続き予測を待ち、終わった時点でまだ次のキーを
    /// 送っていなければ予測ウィンドウに反映する。
    @MainActor
    private func awaitNextTextCompletion(afterKeyEventID eventID: UInt64) {
        let activationGeneration = self.activationGeneration
        let traceID = self.inputTraceID
        self.converterServerClient.sendUnordered({ _ in .completion(.await(afterKeyEventID: eventID)) }) { [weak self] response in
            InputTrace.reply(response, controller: traceID, request: eventID, completion: true)
            Task { @MainActor in
                guard let self else {
                    InputTrace.event(.guardReturn, controller: traceID, request: eventID, reason: .ownerReleased); return
                }
                guard let response else { self.traceGuard(.noResponse, request: eventID); return }
                guard self.activationGeneration == activationGeneration,
                      self.nextKeyEventID == eventID,
                      self.pendingKeyEventCount == 0 else {
                    self.traceGuard(.staleCompletion, request: eventID); return
                }
                self.apply(response, requestID: eventID)
            }
        }
    }

    @MainActor
    func requestPredictiveSuggestionWithConverterServer(client: IMKTextInput) -> Bool {
        self.handleKeyEventWithConverterServer(
            event: KeyEventCore(
                modifierFlags: [.control],
                characters: "s",
                charactersIgnoringModifiers: "s",
                keyCode: 1
            ),
            enableSuggestion: Config.AIBackendPreference().value != .off
        )
    }

    @MainActor
    private func apply(_ response: ConverterServerResponse, requestID: UInt64 = 0) {
        let previousRequestID = self.inputTraceRequestID
        self.inputTraceRequestID = requestID
        defer { self.inputTraceRequestID = previousRequestID }
        if let inputLanguage = response.inputLanguage {
            self.inputLanguage = inputLanguage
        }
        // 応答を反映する前の入力中の文字（確定する文字列の方が長いときに使う。下の .insertText を参照）
        let previousMarkedText = (self.inputState == .composing || self.inputState == .replaceSuggestion) ? self.currentMarkedText().elements.map(\.content).joined() : ""
        self.inputState = response.inputState.inputState
        self.visibleMagicFragments = response.magicFragments ?? []
        if self.inputState != .replaceSuggestion {
            self.magicInline = false; self.magicFallbackReading = nil; self.magicMarkingFailed = false
        }
        self.currentConverterView = response.snapshot
        if let client = self.client() {
            for effect in response.effects {
                self.apply(effect, client: client, previousMarkedText: previousMarkedText)
            }
        } else { self.traceGuard(.noClient, request: requestID) }
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        self.refreshReplaceSuggestionWindow()
        self.refreshGhostText()
        self.refreshMagicFragments()
        if let token = response.assistanceReceipt { self.scheduleRetentionCheck(token) }
    }

    @MainActor
    // swiftlint:disable:next cyclomatic_complexity
    private func apply(_ effect: ConverterClientEffect, client: IMKTextInput, previousMarkedText: String = "") {
        switch effect {
        case .insertText(let text):
            // llm-ime: 入力中の文字より長い文字列（続き予測・予測候補）を確定するとき、Chromium 系のアプリ（Claude のアプリなど）は
            // カーソルを元の入力中の文字の長さの位置に残すことがある（「今日」に「今日は、」を確定すると「今日|は、」）。
            // 先に入力中の文字を確定する文字列に置き換えてから確定する（アプリから見ると、入力中の文字をそのまま確定したことになる）
            if !previousMarkedText.isEmpty, text.count > previousMarkedText.count {
                let length = (text as NSString).length
                self.setClientMarkedText(text, selectionRange: NSRange(location: length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0), client: client)
                Self.ghostLog.notice("commit longer than marked text: marked=\(previousMarkedText.count) commit=\(text.count)")
            }
            self.insertClientText(text, replacementRange: NSRange(location: NSNotFound, length: 0), client: client)
            // llm-ime: 場面学習。確定の直後のバックスペースを数え始める
            self.countingBackspacesAfterCommit = true
            self.backspacesAfterCommit = 0
            // llm-ime: 確定後のカーソルの進み具合から、灰色の続き予測の文字の大きさを推定する
            if let start = self.ghostAnchor?.startRect, start.height > 0 {
                self.lastCommitForGhost = (text, start)
            }
        case .switchInputLanguage(let language):
            self.switchInputLanguage(language, client: client)
        case .requestPredictiveSuggestion:
            self.requestReplaceSuggestion()
        case .requestReplaceSuggestion:
            self.requestReplaceSuggestion()
        case .selectNextReplaceSuggestionCandidate:
            self.selectReplaceSuggestionCandidate(offset: 1)
        case .selectPreviousReplaceSuggestionCandidate:
            self.selectReplaceSuggestionCandidate(offset: -1)
        case .submitReplaceSuggestionCandidate:
            self.submitSelectedSuggestionCandidate()
        case .hideReplaceSuggestionWindow:
            self.replaceSuggestionsUI.loaded?.window.setIsVisible(false)
            self.replaceSuggestionsUI.loaded?.window.orderOut(nil)
        case .showPromptInputWindow:
            self.showPromptInputWindow()
        case .transformSelectedText(let selectedText, let prompt):
            self.transformSelectedText(selectedText: selectedText, prompt: prompt)
        case .fallthroughToApplication:
            break
        }
    }

    private var inputStyle: ConverterInputStyle {
        switch Config.InputStyle().value {
        case .default:
            .defaultRomanToKana
        case .defaultAZIK:
            .defaultAZIK
        case .defaultKanaUS:
            .defaultKanaUS
        case .defaultKanaJIS:
            .defaultKanaJIS
        case .custom:
            .tableName(CustomInputTableStore.tableName)
        }
    }

    private var converterServerSessionConfig: ConverterSessionConfig {
        ConverterSessionConfig(
            aiBackendPreference: Config.AIBackendPreference().value,
            openAIModelName: Config.OpenAiModelName().value,
            openAIEndpoint: Config.OpenAiApiEndpoint().value,
            openAIAPIKey: .init(Config.OpenAiApiKey().value),
            includeContextInAITransform: Config.IncludeContextInAITransform().value
        )
    }

    @MainActor
    private func syncConverterServerSessionConfig() {
        let config = self.converterServerSessionConfig
        self.converterServerClient.send(
            { _ in .updateConfig(config) },
            completion: { _ in }
        )
    }

    @MainActor func switchInputLanguage(_ language: InputLanguage, client: IMKTextInput) {
        self.inputLanguage = language
        client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        switch language {
        case .english:
            client.selectMode("dev.tomonari.inputmethod.Shizuku.Roman")
        case .japanese:
            client.selectMode("dev.tomonari.inputmethod.Shizuku.Japanese")
        }
    }

    @MainActor
    private func discardConverterServerComposition() {
        self.currentConverterView = nil
        self.converterServerClient.sendIfSessionOpen(
            { _ in .composition(.stopComposition) },
            completion: { _ in }
        )
    }

    func refreshCandidateWindow() {
        if let currentConverterView {
            self.refreshCandidateWindow(currentConverterView.candidateWindow)
            return
        }
        self.candidatesUI.loaded?.window.setIsVisible(false)
        self.candidatesUI.loaded?.window.orderOut(nil)
        self.candidatesUI.loaded?.controller.hide()
    }

    private func refreshCandidateWindow(_ candidateWindow: ConverterCandidateWindow) {
        switch candidateWindow {
        case .selecting(let candidates, let selectionIndex):
            let rect = self.cursorRectForWindows()
            self.candidatesViewController.showCandidateIndex = true
            self.candidatesViewController.updateCandidatePresentations(
                candidates,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .composing(let candidates, let selectionIndex):
            let rect = self.cursorRectForWindows()
            self.candidatesViewController.showCandidateIndex = false
            self.candidatesViewController.updateCandidatePresentations(
                candidates,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .hidden:
            self.candidatesUI.loaded?.window.setIsVisible(false)
            self.candidatesUI.loaded?.window.orderOut(nil)
            self.candidatesUI.loaded?.controller.hide()
        }
    }

    @MainActor private func refreshReplaceSuggestionWindow() {
        guard self.inputState == .replaceSuggestion, !self.magicInline, !(self.quoteChoicesUI.loaded?.isVisible == true),
              let currentConverterView,
              !currentConverterView.replaceSuggestionCandidates.isEmpty else {
            self.replaceSuggestionsUI.loaded?.controller.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
            self.replaceSuggestionsUI.loaded?.window.setIsVisible(false)
            self.replaceSuggestionsUI.loaded?.window.orderOut(nil)
            return
        }
        self.replaceSuggestionsViewController.updateCandidatePresentations(
            currentConverterView.replaceSuggestionCandidates,
            selectionIndex: currentConverterView.replaceSuggestionSelectionIndex,
            cursorLocation: self.getCursorLocation()
        )
        self.replaceSuggestionWindow.setIsVisible(true)
        self.replaceSuggestionWindow.makeKeyAndOrderFront(nil)
    }

    @MainActor private func selectReplaceSuggestionCandidate(offset: Int) {
        guard let view = self.currentConverterView,
              !view.replaceSuggestionCandidates.isEmpty else {
            return
        }
        let count = view.replaceSuggestionCandidates.count
        let current = view.replaceSuggestionSelectionIndex ?? (offset > 0 ? -1 : 0)
        let next = (current + offset + count) % count
        self.converterServerClient.sendIfSessionOpen(
            { _ in .replaceSuggestion(.selectReplaceSuggestionCandidate(index: next)) },
            completion: { [weak self] response in
                Task { @MainActor in
                    guard let self, let response else {
                        return
                    }
                    self.apply(response)
                }
            }
        )
    }

    @MainActor private func showReplaceSuggestionError(message: String) {
        self.appendDebugMessage("APIリクエストエラー: \(message)")
        let alert = NSAlert()
        alert.messageText = "変換に失敗しました"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func refreshPredictionWindow() {
        if (self.quoteChoicesUI.loaded?.isVisible == true) { self.hidePredictionWindow(); return }
        guard self.inputState == .composing else {
            self.hidePredictionWindow()
            return
        }

        guard let predictions = self.currentConverterView?.predictionCandidates else {
            self.hidePredictionWindow()
            return
        }
        if predictions.isEmpty {
            let now = Date().timeIntervalSince1970
            let elapsed = now - self.lastPredictionUpdateTime
            if elapsed < 1.0, !self.lastPredictionCandidates.isEmpty {
                self.showCachedPredictionWindow()
                self.schedulePredictionHide(after: max(0, 1.0 - elapsed))
                return
            }
            self.hidePredictionWindow()
            return
        }

        self.predictionHideWorkItem?.cancel()
        let candidates = predictions.map { ConverterCandidatePresentation(text: $0.displayText) }

        self.lastPredictionCandidates = predictions.map(\.displayText)
        self.lastPredictionUpdateTime = Date().timeIntervalSince1970

        let rect = self.cursorRectForWindows()
        self.predictionViewController.updateCandidatePresentations(
            candidates,
            selectionIndex: nil,
            cursorLocation: rect.origin
        )

        if Config.LiveConversion().value {
            self.predictionWindow.orderFront(nil)
            return
        }

        if (self.candidatesUI.loaded?.window.isVisible == true) {
            self.positionPredictionWindowRightOfCandidateWindow()
        }
        self.predictionWindow.orderFront(nil)
    }

    private func positionPredictionWindowRightOfCandidateWindow(gap: CGFloat = 8) {
        // アンカーである候補ウィンドウの中心が乗っているスクリーンを基準にする。
        // predictionWindow.screen / candidatesWindow.screen はマルチディスプレイ遷移直後に
        // 古いディスプレイを返すことがあるため、frame の中心点で能動的に判定する。
        let anchorFrame = self.candidatesWindow.frame
        let anchorCenter = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let screen = ScreenLookup.screen(containing: anchorCenter, fallbackWindow: self.candidatesWindow) else {
            return
        }

        let frame = WindowPositioning.frameRightOfAnchor(
            currentFrame: WindowPositioning.Rect(self.predictionWindow.frame),
            anchorFrame: WindowPositioning.Rect(anchorFrame),
            screenRect: WindowPositioning.Rect(screen.visibleFrame),
            gap: Double(gap)
        )
        self.predictionWindow.setFrame(frame.cgRect, display: true)
    }

    private func showCachedPredictionWindow() {
        let candidates = self.lastPredictionCandidates.map { ConverterCandidatePresentation(text: $0) }
        guard !candidates.isEmpty else {
            return
        }
        let rect = self.cursorRectForWindows()
        self.predictionViewController.updateCandidatePresentations(
            candidates,
            selectionIndex: nil,
            cursorLocation: rect.origin
        )
        self.predictionWindow.orderFront(nil)
    }

    private func schedulePredictionHide(after delay: TimeInterval) {
        self.predictionHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let now = Date().timeIntervalSince1970
            if now - self.lastPredictionUpdateTime >= 1.0 {
                self.hidePredictionWindow()
            }
        }
        self.predictionHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hidePredictionWindow() {
        self.predictionUI.loaded?.window.setIsVisible(false)
        self.predictionUI.loaded?.window.orderOut(nil)
        self.lastPredictionCandidates = []
        self.lastPredictionUpdateTime = 0
        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
    }

    var retryCount = 0
    let maxRetries = 3

    @MainActor func handleSuggestionError(_ error: Error, cursorPosition: CGPoint) {
        let errorMessage = "エラーが発生しました: \(error.localizedDescription)"
        self.appendDebugMessage(errorMessage)
    }

    func getCursorLocation() -> CGPoint {
        let rect = self.cursorRectForWindows()
        self.appendDebugMessage("カーソル位置取得: \(rect.origin)")
        return rect.origin
    }

    /// llm-ime: 候補・予測ウィンドウの配置に使う、marked text 先頭の矩形。
    ///
    /// ConverterServer の応答は非同期に届くため、その反映中に `client.attributes(...)` を
    /// 同期呼び出しすると、アプリ側が次のキーで `handle` を同期呼び出ししている最中と重なり、
    /// 互いを待って IMK がタイムアウト（約3秒）する。その間のキーは失われ、アプリが
    /// delete などを自分で処理して入力中の文字を確定してしまうことがある。
    /// アプリが IME を待っている `handle` の中で位置を取得しておき、応答反映時はそれを使う。
    func cursorRectForWindows() -> NSRect {
        if let cachedCursorRect {
            return cachedCursorRect
        }
        var rect: NSRect = .zero
        self.client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    /// `handle` の中（アプリが IME の応答を同期的に待っている間）でだけ呼ぶ。
    func updateCachedCursorRect(client: IMKTextInput) {
        var rect: NSRect = .zero
        let attributes = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.cachedCursorRect = rect
        // llm-ime: 場面学習。入力位置の文字が等幅フォントか（コード・コメントの手がかり）
        self.lastFontIsFixedPitch = (attributes?[NSAttributedString.Key.font] as? NSFont ?? attributes?["NSFont"] as? NSFont)?.isFixedPitch
        // llm-ime: 続き予測を入力中の文字の後ろに置くため、位置と、そのアプリでの文字の大きさを記録しておく
        // （予測は非同期に届くので、その時点ではアプリに位置を問い合わせない）。入力中の文字の先頭（index 0）の
        // 位置はどのアプリも返すが、末尾の位置は返さないアプリがある（Chromium 系は 0 の矩形を返す）
        guard rect.height > 0 else {
            self.ghostAnchor = nil
            return
        }
        let marked = self.currentMarkedText().elements.map(\.content).joined()
        // 確定後にカーソルが進んだ量と確定した文字列から、文字の大きさを推定する（どのアプリでも使える）
        if marked.isEmpty, let commit = self.lastCommitForGhost {
            if abs(rect.minY - commit.startRect.minY) < rect.height / 2 {
                self.updateGhostFontSize(actualWidth: rect.minX - commit.startRect.minX, text: commit.text, lineHeight: rect.height)
            }
            self.lastCommitForGhost = nil
        }
        var endX: CGFloat?
        let length = (marked as NSString).length
        if length > 0 {
            var endRect: NSRect = .zero
            client.attributes(forCharacterIndex: length, lineHeightRectangle: &endRect)
            if endRect.height > 0, abs(endRect.minY - rect.minY) < rect.height / 2, endRect.minX > rect.minX {
                endX = endRect.minX
            }
            // 末尾の位置を返さないアプリ（Chromium 系）は、文書全体での位置で尋ねても有効な値を返さなかった
            if let endX {
                self.updateGhostFontSize(actualWidth: endX - rect.minX, text: marked, lineHeight: rect.height)
            }
        }
        // 入力を始めるときに、今の行の先頭の位置などを尋ねておく（入力中は変わらない）
        if marked.isEmpty, Config.NextTextCompletion().value {
            self.ghostClientBundleID = client.bundleIdentifier()
            self.observeCurrentLine(client: client, caretRect: rect)
        }
        let fontSize = self.ghostFontSize ?? min(max(rect.height * 0.78, 10), 40)
        self.ghostAnchor = GhostAnchor(startRect: rect, endX: endX, fontSize: fontSize, markedText: marked)
    }

    /// 今の行（改行から次の改行まで）のカーソルより前の部分の位置をアプリに尋ね、行頭の位置・折り返す右端・文字の大きさを
    /// 記録する。NSTextView 系（TextEdit など）は正確な値を返す。返さないアプリ（カーソルの位置を返すものなど）や、
    /// 行の先頭がわからないとき（前の文章が長すぎる）は記録しない（ウィンドウの枠からの推定を使う）
    private func observeCurrentLine(client: IMKTextInput, caretRect: NSRect) {
        self.observedLineStartX = nil
        self.observedRightEdge = nil
        let left = self.lastLeftContext
        let caretIndex = client.selectedRange().location
        guard caretIndex != NSNotFound else {
            return
        }
        let line: Substring
        if let newline = left.lastIndex(where: \.isNewline) {
            line = left[left.index(after: newline)...]
        } else if left.utf16.count == caretIndex {
            line = left[...]
        } else {
            return
        }
        let lineStart = caretIndex - line.utf16.count
        guard lineStart >= 0 else {
            return
        }
        if line.isEmpty {
            self.observedLineStartX = caretRect.minX
            return
        }
        // 範囲の最初の見た目の行の矩形が返る（折り返していれば、actual はその行に収まった部分だけになる）
        var actual = NSRange(location: NSNotFound, length: 0)
        let rect = client.firstRect(forCharacterRange: NSRange(location: lineStart, length: line.utf16.count), actualRange: &actual)
        let charWidth = self.ghostFontSize ?? caretRect.height * 0.6
        // 縦の位置はアプリによって 1 行ずれて返る（TextEdit）ので、横の位置と actual だけで判断する。
        // 返った値が画面上にないもの（初期化されていない値を返すアプリがある）は使わない
        let onScreen = rect.minX.isFinite && rect.maxX.isFinite && rect.height >= 4 && rect.width >= 0
            && NSScreen.screens.contains { $0.frame.minX - 1 <= rect.minX && rect.maxX <= $0.frame.maxX + 1 }
        // 折り返していれば actual は最初の見た目の行の部分だけになる（actual を返さないアプリは、範囲の右端がカーソルより
        // 1 文字以上右にあれば折り返しとみなす）
        let wrapped = actual.location != NSNotFound
            ? actual.length < line.utf16.count
            : rect.maxX > caretRect.minX + charWidth
        // 折り返していなければ、行頭はカーソルより少なくとも半文字ぶん左にあり、範囲の右端はカーソルの位置にある
        // （カーソルの位置を返すアプリを除く）
        guard onScreen, actual.location == NSNotFound || actual.location == lineStart,
              wrapped || (rect.minX <= caretRect.minX - charWidth * 0.5 && abs(rect.maxX - caretRect.minX) <= charWidth) else {
            Self.ghostLog.notice("line query rejected: rect=\(NSStringFromRect(rect), privacy: .public) caret=\(NSStringFromRect(caretRect), privacy: .public) actual=\(actual.location),\(actual.length)")
            return
        }
        self.observedLineStartX = rect.minX
        if wrapped {
            // 最初の見た目の行の右端の文字の後ろ。次の文字は入らなかったので、右端はここから 1 文字分以内にある
            self.observedRightEdge = rect.maxX + charWidth * 0.5
        } else if line.count >= 4 {
            // 行全体の幅から、このアプリでの文字の大きさを推定する（確定後の移動量からの推定より文字数が多く正確）
            self.updateGhostFontSize(actualWidth: rect.width, text: String(line), lineHeight: caretRect.height)
        }
        Self.ghostLog.notice("line: rect=\(NSStringFromRect(rect), privacy: .public) caret=\(NSStringFromRect(caretRect), privacy: .public) wrapped=\(wrapped) font=\(self.ghostFontSize.map { "\($0)" } ?? "nil", privacy: .public)")
    }

    /// 実際の幅と、その文字列のシステムフォント 1pt での幅から文字の大きさを推定する。
    /// 行の高さのおよそ 0.5〜1 倍に収まらない値は、位置の値があてにならないとみなして使わない
    private func updateGhostFontSize(actualWidth: CGFloat, text: String, lineHeight: CGFloat) {
        let measured = GhostTextWindow.width(of: text, fontSize: 1)
        guard measured > 0, actualWidth > 0 else {
            return
        }
        let size = actualWidth / measured
        if (8...72).contains(size), (lineHeight * 0.5...lineHeight * 1.05).contains(size) {
            self.ghostFontSize = size
        } else {
            Self.ghostLog.notice("font size rejected: size=\(size) lineHeight=\(lineHeight)")
        }
    }

    // MARK: - 何も入力していない状態の続き予測（llm-ime）

    /// カーソルを含む前面のアプリのウィンドウの枠（AppKit の画面座標）。システムのウィンドウ一覧から得る
    /// （位置と大きさだけを使い、内容は読まないので特別な許可は要らない）
    private func clientWindowFrame(containing point: NSPoint, clientOnly: Bool = false) -> NSRect? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else {
            Self.ghostLog.notice("window list unavailable")
            return nil
        }
        var pids = Set(self.ghostClientBundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) } ?? [])
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            pids.insert(front)
        }
        // 入力先のアプリがわかっていれば、そのウィンドウだけから選ぶ（カーソルの推定位置が少しはみ出しても見つかるように、
        // 左右に余裕を持たせる）。わからなければカーソルを含む最前面の普通のウィンドウ
        var candidates: [(frame: NSRect, isClient: Bool)] = []
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 100, bounds.height >= 40 else {
                continue
            }
            // CGWindow の座標は左上原点（下向き）なので、AppKit の画面座標（左下原点）に直す
            let frame = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            let isClient = (info[kCGWindowOwnerPID as String] as? Int).map { pids.contains(pid_t($0)) } ?? false
            candidates.append((frame, isClient))
        }
        let clientFrames = candidates.filter(\.isClient).map(\.frame)
        if let frame = clientFrames.first(where: { $0.contains(point) }) ?? clientFrames.first(where: { $0.insetBy(dx: -40, dy: 0).contains(point) }) {
            return frame
        }
        // clientOnly なら、入力先のアプリのウィンドウが見つからなければ nil（ほかのアプリのウィンドウで代用しない）
        let fallback = clientFrames.isEmpty && !clientOnly ? candidates.first { $0.frame.contains(point) }?.frame : nil
        Self.ghostLog.notice("client window not found: point=\(NSStringFromPoint(point), privacy: .public) pids=\(pids.map(String.init).joined(separator: ","), privacy: .public) fallback=\(fallback.map(NSStringFromRect) ?? "nil", privacy: .public)")
        return fallback
    }

    /// 灰色の補完の行頭（2 行目以降を置く位置）と、折り返す右端を決める。
    /// 行頭は 1) 入力を始めたときにアプリに尋ねた今の行の先頭の位置 2) カーソルからその行の文字の幅を引いた推定
    /// （ウィンドウ内に収まるときだけ） 3) ウィンドウの左端 の順。右端はウィンドウの右端から左側と同じ余白を引いた位置。
    /// 折り返し幅が 10 文字分未満になるときはウィンドウの左端から折り返し、それでも狭ければ折り返さない
    private func ghostLayout(caret: NSPoint, currentLine: String, fontSize: CGFloat) -> (lineStartX: CGFloat, rightEdge: CGFloat?) {
        let frame = self.clientWindowFrame(containing: caret)
        let screen = NSScreen.screens.first { $0.frame.contains(caret) }?.visibleFrame
        let leftBound = (frame ?? screen).map { $0.minX + 4 } ?? 0
        func edge(lineStartX: CGFloat) -> CGFloat? {
            if let frame {
                return frame.maxX - max(8, min(lineStartX - frame.minX, 60))
            }
            return screen.map { $0.maxX - 8 }
        }
        var lineStartX: CGFloat
        // アプリが返した位置は、ウィンドウの端ぎりぎり（余白なし）でも使う
        if let observed = self.observedLineStartX, observed >= (frame?.minX ?? leftBound) - 2, observed <= caret.x {
            lineStartX = observed
        } else {
            lineStartX = caret.x - GhostTextWindow.width(of: currentLine, fontSize: fontSize)
            if lineStartX < leftBound || lineStartX > caret.x {
                lineStartX = leftBound
            }
        }
        var rightEdge = edge(lineStartX: lineStartX)
        // 今の行が折り返していれば、アプリが実際に折り返した位置を使う
        if let observed = self.observedRightEdge, observed > lineStartX + fontSize * 10, observed <= (frame?.maxX ?? .infinity) {
            rightEdge = observed
        }
        if let right = rightEdge, right - lineStartX < fontSize * 10 {
            lineStartX = leftBound
            rightEdge = edge(lineStartX: lineStartX)
            if let right = rightEdge, right - lineStartX < fontSize * 10 {
                rightEdge = nil
            }
        }
        Self.ghostLog.notice("layout: caret=\(NSStringFromPoint(caret), privacy: .public) frame=\(frame.map(NSStringFromRect) ?? "nil", privacy: .public) observed=\(self.observedLineStartX.map { "\($0)" } ?? "nil", privacy: .public) lineStart=\(lineStartX) right=\(rightEdge.map { "\($0)" } ?? "nil", privacy: .public) font=\(fontSize)")
        return (lineStartX, rightEdge)
    }

    /// 確定後に何も入力せず idleCompletionDelay 秒たったら、カーソルより前の文章の続きを 1 文ずつ予測して灰色で出す
    /// （文章を書き進める補完。改行・段落の区切りも含む）
    @MainActor
    private func scheduleIdleCompletion(leftContext: String, caretX: CGFloat, lineRect: NSRect, fontSize: CGFloat, delay: TimeInterval? = nil) {
        self.idleCompletionWorkItem?.cancel()
        self.idleGeneration &+= 1
        guard lineRect.height > 0 else {
            return
        }
        let currentLine = leftContext.components(separatedBy: "\n").last ?? ""
        let layout = self.ghostLayout(caret: NSPoint(x: caretX, y: lineRect.midY), currentLine: currentLine, fontSize: fontSize)
        let base = IdleCompletion(
            text: "", leftContext: leftContext, caretX: caretX, lineRect: lineRect, fontSize: fontSize,
            lineStartX: layout.lineStartX, rightEdge: layout.rightEdge
        )
        let generation = self.idleGeneration
        let item = DispatchWorkItem { [weak self] in
            // メインキューで実行される
            MainActor.assumeIsolated {
                guard let self, self.idleGeneration == generation, self.inputState == .none, self.pendingKeyEventCount == 0 else {
                    return
                }
                self.fixCaretAfterCompletionInsertion()
                self.requestDraftSentence(base, round: 0, generation: generation)
            }
        }
        self.idleCompletionWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? self.tunedIdleCompletionDelay ?? Self.idleCompletionDelay), execute: item)
    }

    /// 続きを 1 文予測して表示に足し、上限まで続けて次の文を予測する
    @MainActor
    private func requestDraftSentence(_ current: IdleCompletion, round: Int, generation: UInt64) {
        let activationGeneration = self.activationGeneration
        let context = current.leftContext + current.text
        self.converterServerClient.sendUnordered({ _ in .completion(.draft(leftContext: context)) }) { [weak self] response in
            Task { @MainActor in
                guard let self, self.idleGeneration == generation, self.activationGeneration == activationGeneration,
                      self.inputState == .none, self.placedAssistance == nil,
                      let sentence = response?.snapshot.nextTextCompletion, !sentence.isEmpty else {
                    return
                }
                var next = current
                if let old = current.referenceReceipt {
                    guard let receipt = response?.windowContextReceipt, receipt.binding == old.binding,
                          receipt.generation == old.generation else {
                        self.cancelIdleCompletion(); return
                    }
                }
                next.referenceReceipt = response?.windowContextReceipt ?? current.referenceReceipt
                if let old = current.referenceReceipt, let expires = next.referenceReceipt?.expiresAt {
                    next.referenceReceipt?.expiresAt = min(old.expiresAt, expires)
                }
                next.text += sentence

                guard !self.dismissedAssistance.contains(AssistanceVerbs.fingerprint(next.text)) else { return }
                self.idleCompletion = next
                if Config.NextTextCompletionInlineGhost().value {
                    self.ghostTextWindow.show(
                        text: next.text, caretX: next.caretX, lineRect: next.lineRect, lineStartX: next.lineStartX,
                        fontSize: next.fontSize, rightEdge: next.rightEdge
                    )
                } else {
                    // カーソルの行の下に出す（左端は、確定した文字の先頭か、Tab で入れた後のカーソル）
                    self.completionPopupWindow.show(text: next.text, lineRect: next.lineRect, avoiding: self.otherIMEWindows,
                                                    hint: response?.windowReferenceUsed == true ? "Tab・画面" : "Tab")
                }
                // 段落が変わったら、そこで止める
                if round + 1 < Self.draftMaxSentences, !sentence.contains("\n\n"), next.text.count < 240 {
                    self.requestDraftSentence(next, round: round + 1, generation: generation)
                }
            }
        }
    }

    /// 何も入力していない状態の続き予測が出ているときのキー処理。Tab なら、カーソルより前の文章が予測したときと
    /// 同じことを確かめてから入れて true を返す（違えば Tab をアプリに渡すため false）。ほかのキーは予測を消して nil
    @MainActor
    private func handleIdleCompletionKey(event: NSEvent, client: IMKTextInput) -> Bool? {
        self.idleCompletionWorkItem?.cancel()
        self.idleGeneration &+= 1
        if self.pendingCaretCheck != nil { self.fixCaretAfterCompletionInsertion() }
        guard let idle = self.idleCompletion else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        self.idleCompletion = nil
        self.hideCompletionDisplay()
        guard event.keyCode == 48, modifiers.isEmpty || modifiers == .shift, self.inputState == .none else { return nil }
        let markedRange = client.markedRange()
        guard markedRange.location == NSNotFound || markedRange.length == 0, client.selectedRange().length == 0 else { return false }
        if idle.leftContext.isEmpty {
            guard client.length() == 0 else { return false }
        } else {
            let left = self.getLeftSideContext(maxCount: 40) ?? ""
            let n = min(20, left.count, idle.leftContext.count)
            guard n > 0, left.suffix(n) == idle.leftContext.suffix(n) else { return false }
        }
        if let receipt = idle.referenceReceipt {
            guard Config.WindowContextEnabled().value, receipt.expiresAt >= Date().timeIntervalSince1970,
                  receipt.binding == self.windowContextBinding else { return true }
            let activation = self.activationGeneration
            let generation = self.idleGeneration
            let selection = client.selectedRange(), length = client.length()
            let all = modifiers == .shift
            self.pendingKeyEventCount += 1
            self.converterServerClient.send({ _ in .validateWindowContext(receipt) }) { [weak self] response in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingKeyEventCount = max(0, self.pendingKeyEventCount - 1)
                    guard self.activationGeneration == activation, self.idleGeneration == generation,
                          Config.WindowContextEnabled().value, receipt.expiresAt >= Date().timeIntervalSince1970,
                          receipt.binding == self.windowContextBinding,
                          client.selectedRange() == selection, client.length() == length else { return }
                    if response?.handled == true {
                        _ = self.placeIdleCompletion(idle, all: all, client: client, immediate: true)
                    }
                    // A rejected adoption must not insert stale text or move to another field.
                }
            }
            return true
        }
        return self.placeIdleCompletion(idle, all: modifiers == .shift, client: client)
    }

    @MainActor private func placeIdleCompletion(_ idle: IdleCompletion, all: Bool, client: IMKTextInput, immediate: Bool = false) -> Bool {
        let chunk = AssistanceVerbs.chunk(idle.text, all: all)
        guard !chunk.text.isEmpty else { return false }
        self.recordAssistanceVerb(all ? "verb_tab_all" : "verb_tab_one", count: chunk.text.count)
        self.placedAssistance = .init(text: chunk.text, remaining: chunk.remaining, lastChunk: chunk.text, time: Date(), anchor: idle)
        if immediate {
            self.commitPlacedAssistance(client: client, afterKeyCallback: false)
        } else if AssistanceVerbs.shouldStage(chunk.text, app: self.ghostClientBundleID, failedApps: self.failedMarkedApps) {
            self.showPlacedAssistance(client: client)
        } else {
            self.commitPlacedAssistance(client: client)
        }
        return true
    }

    private var assistanceHelpVisible: Bool {
        (self.ghostUI.loaded?.isVisible == true) || (self.completionUI.loaded?.isVisible == true) || (self.predictionUI.loaded?.window.isVisible == true)
    }

    @MainActor private func assistanceSceneKey() -> String? {
        self.assistanceSceneKey(left: self.lastLeftContext, right: self.lastRightContext)
    }
    @MainActor private func assistanceSceneKey(left: String?, right: String?) -> String? {
        let before = left ?? "", after = right ?? ""
        if before.isEmpty, after.isEmpty, self.lastDocumentLength == 0 { self.fieldStartedEmpty = true }
        let observation = ConverterSceneObservation(bundleID: self.ghostClientBundleID, previousBundleID: nil,
            documentLength: self.lastDocumentLength, startedEmpty: self.fieldStartedEmpty,
            monospaced: self.lastFontIsFixedPitch, backspacesAfterCommit: 0)
        guard var scene = PersonalScene.classify(observation: observation, leftContext: before, rightContext: after) else { return nil }
        if Config.PersonalLearning().value,
           let shape = PersonalMarkup.shape(left: before, right: after, monospaced: observation.monospaced == true) {
            scene.shape = shape; scene.reply = false
        }
        return scene.baseKey
    }

    @MainActor private func recordAssistanceVerb(_ event: String, hash: String? = nil, count: Int? = nil, scene: String? = nil) {
        let key = scene ?? self.assistanceSceneKey()
        self.converterServerClient.send({ _ in .completion(.assistance(event: event, scene: key, hash: hash, count: count)) }, completion: { _ in })
    }

    /// true/falseを返したときだけ、ここがイベントの持ち主になる。
    @MainActor private func handleAssistanceVerb(event: NSEvent, client: IMKTextInput) -> Bool? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if self.observingPassedTab {
            self.observingPassedTab = false
            let context = self.currentConverterTextContext()
            if PersonalLearner.isRecording, let scene = self.assistanceSceneKey(left: context.leftSideContext, right: context.rightSideContext),
               self.tabTracker.observe(scene: scene, left: context.leftSideContext) {
                self.recordAssistanceVerb("tab_owner", scene: scene)
            } else { self.tabTracker.reset() }
        }
        if (self.windowHintUI.loaded?.isVisible == true) { self.windowHintUI.loaded?.hide(); self.windowHintGeneration &+= 1 }
        if (self.cleanUpUI.loaded?.isVisible == true) {
            if let choice = self.cleanUpChoice, event.keyCode == 53, modifiers.isEmpty {
                self.dismissAssistance(choice.text); self.resetCleanUp(); return true
            }
            if self.cleanUpChoice != nil, event.keyCode == 48, modifiers.isEmpty {
                self.cleanUpUI.loaded?.hide(); return self.acceptCleanUp(client: client)
            }
            self.cleanUpUI.loaded?.hide()
        }
        if (self.quoteChoicesUI.loaded?.isVisible == true) {
            if event.keyCode == 53, modifiers.isEmpty {
                if !self.quoteChoices.isEmpty { self.dismissAssistance(self.quoteChoices[self.quoteChoiceIndex]) }
                else { self.recordAssistanceVerb("verb_esc") }
                self.quoteChoicesUI.loaded?.hide(); return true
            }
            if event.keyCode == 48, modifiers == .control {
                if !self.quoteChoices.isEmpty { self.quoteChoiceIndex = (self.quoteChoiceIndex + 1) % self.quoteChoices.count }
                self.showQuoteChoices(); self.recordAssistanceVerb("verb_summon"); return true
            }
            if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
                if self.quoteChoices.isEmpty { self.quoteChoicesUI.loaded?.hide(); return false }
                self.acceptQuoteChoice()
                self.recordAssistanceVerb(modifiers == .shift ? "verb_tab_all" : "verb_tab_one")
                return true
            }
            if modifiers.isEmpty, let number = event.characters.flatMap(Int.init), (1...3).contains(number) {
                if number == 1 { self.acceptQuoteChoice() }
                if number == 3, self.cleanUpChoice != nil { self.quoteChoicesUI.loaded?.hide(); _ = self.acceptCleanUp(client: client) }
                return true // ②穴埋めは今回空欄。
            }
            self.quoteChoicesUI.loaded?.hide()
        }
        if event.keyCode == 48, modifiers == .control {
            // Only Shizuku's own marked/visible assistance grants ownership of Ctrl+Tab.
            let marked = self.placedAssistance != nil || self.inputState != .none
            guard AssistanceVerbs.canSummon(helpVisible: self.assistanceHelpVisible, marked: marked) else {
                self.quoteRequestGeneration &+= 1
                return false
            }
            self.summonQuoteChoices(nil); return true
        }
        if self.inputState == .replaceSuggestion, self.magicInline {
            if event.keyCode == 49, modifiers.isEmpty { self.selectReplaceSuggestionCandidate(offset: 1); return true }
            if event.keyCode == 36, modifiers.isEmpty { self.sendMagicCommand(.submitGenerated); return true }
            if event.keyCode == 53, modifiers.isEmpty { self.sendMagicCommand(.cancelGenerated); return true }
            if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
                if (self.magicFragmentsUI.loaded?.isVisible == true) && !self.visibleMagicFragments.isEmpty {
                    self.sendMagicCommand(.appendFragments(all: modifiers == .shift))
                } else { self.sendMagicCommand(.submitGenerated) }
                return true
            }
            if modifiers.isEmpty, let number = event.characters.flatMap(Int.init), (1...3).contains(number),
               let count = self.currentConverterView?.replaceSuggestionCandidates.count, number <= count {
                self.converterServerClient.send({ _ in .replaceSuggestion(.selectReplaceSuggestionCandidate(index: number - 1)) }) { [weak self] _ in
                    Task { @MainActor in self?.sendMagicCommand(.submitGenerated) }
                }
                return true
            }
        }
        if var placed = self.placedAssistance {
            if self.placedPresentationPending,
               client.selectedRange() != self.placedPendingSelection || client.length() != self.placedPendingDocumentLength {
                self.placedAssistance = nil; self.placedPresentationVersion &+= 1
                self.placedPresentationPending = false; self.hideCompletionDisplay()
                return nil
            }
            if event.keyCode == 53, modifiers.isEmpty {
                if placed.commitPending {
                    if !placed.remaining.isEmpty { self.dismissAssistance(placed.remaining) }
                    placed.remaining = ""; placed.continueAfterCommit = false
                    self.placedAssistance = placed
                    self.cancelIdleCompletion(); self.hideCompletionDisplay()
                    return true
                }
                self.dismissAssistance(placed.text + placed.remaining)
                self.placedAssistance = nil
                self.placedPresentationVersion &+= 1; self.placedPresentationPending = false
                self.clearAssistanceMarkAfterCallback(client: client)
                self.hideCompletionDisplay()
                return true
            }
            if event.keyCode == 51, modifiers.isEmpty {
                if self.placedPresentationPending {
                    guard client.selectedRange() == self.placedPendingSelection,
                          client.length() == self.placedPendingDocumentLength else {
                        self.placedAssistance = nil; self.placedPresentationVersion &+= 1
                        self.placedPresentationPending = false
                        return false
                    }
                    if AssistanceVerbs.canUndo(chunk: placed.lastChunk, left: placed.text, elapsed: Date().timeIntervalSince(placed.time)) {
                        let length = placed.lastChunk.count
                        placed.text = String(placed.text.dropLast(length))
                        self.recordAssistanceVerb("verb_undo", count: length)
                    } else if let edited = AssistanceVerbs.backspace(placed.text, caret: self.placedPendingCaret, selectionLength: 0) {
                        placed.text = edited.text; self.placedPendingCaret = edited.caret
                    } else { return false }
                    placed.lastChunk = ""
                    self.placedPendingCaret = min(self.placedPendingCaret, placed.text.utf16.count)
                    self.placedAssistance = placed.text.isEmpty ? nil : placed
                    if placed.text.isEmpty {
                        self.placedPresentationVersion &+= 1; self.placedPresentationPending = false
                        self.clearAssistanceMarkAfterCallback(client: client)
                        self.hideCompletionDisplay()
                    } else { self.showPlacedAssistance(client: client, selectionOffset: self.placedPendingCaret) }
                    return true
                }
                let range = client.markedRange()
                let selection = client.selectedRange()
                var actual = NSRange()
                if range.location != NSNotFound, client.string(from: range, actualRange: &actual) == placed.text {
                    let atEnd = selection.length == 0 && selection.location == NSMaxRange(range)
                    if atEnd, AssistanceVerbs.canUndo(chunk: placed.lastChunk, left: placed.text, elapsed: Date().timeIntervalSince(placed.time)) {
                    placed.text = String(placed.text.dropLast(placed.lastChunk.count))
                    self.recordAssistanceVerb("verb_undo", count: placed.lastChunk.count)
                    placed.lastChunk = ""; self.placedAssistance = placed
                    if placed.text.isEmpty {
                        self.placedAssistance = nil
                        self.placedPresentationVersion &+= 1; self.placedPresentationPending = false
                        self.clearAssistanceMarkAfterCallback(client: client)
                        self.hideCompletionDisplay()
                    } else { self.showPlacedAssistance(client: client) }
                    return true
                    }
                    if selection.location >= range.location,
                       let edited = AssistanceVerbs.backspace(placed.text, caret: selection.location - range.location, selectionLength: selection.length) {
                        placed.text = edited.text; placed.lastChunk = ""
                        self.placedAssistance = placed
                        self.showPlacedAssistance(client: client, selectionOffset: edited.caret)
                        return true
                    }
                    return false
                }
                self.placedAssistance = nil
                return false
            }
            if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift, !placed.remaining.isEmpty {
                let chunk = AssistanceVerbs.chunk(placed.remaining, all: modifiers == .shift)
                placed.text += chunk.text; placed.remaining = chunk.remaining; placed.lastChunk = chunk.text; placed.time = Date()
                self.placedAssistance = placed
                self.recordAssistanceVerb(modifiers == .shift ? "verb_tab_all" : "verb_tab_one", count: chunk.text.count)
                self.showPlacedAssistance(client: client)
                return true
            }
            if !placed.commitPending, modifiers.isEmpty, let value = event.characters.flatMap(Int.init),
               AssistanceVerbs.choice(number: value, count: 1, marked: true, choicesVisible: false) != nil {
                self.commitPlacedAssistance(client: client)
                return true
            }
            self.commitPlacedAssistance(client: client)
            if event.keyCode == 36, modifiers.isEmpty { return true }
        }
        if event.keyCode == 51, modifiers.isEmpty, self.inputState == .none, let undo = self.assistanceUndo,
           client.selectedRange().length == 0,
           AssistanceVerbs.canUndo(chunk: undo.text, left: self.getLeftSideContext(maxCount: 2000), elapsed: Date().timeIntervalSince(undo.time)) {
            self.assistanceUndo = nil
            if self.queueCommittedAssistanceUndo(undo.text, client: client) { return true }
        }
        if event.keyCode != 51 { self.assistanceUndo = nil }
        if event.keyCode == 51, modifiers.isEmpty, self.inputState == .none, let undo = self.cleanUpUndo,
           client.selectedRange().length == 0, Date().timeIntervalSince(undo.time) <= 2 {
            self.cleanUpUndo = nil
            if self.queueCommittedReplacement(undo.text, with: undo.original, client: client, event: "cleanup_undone") { return true }
        }
        if event.keyCode != 51 { self.cleanUpUndo = nil }
        if event.keyCode == 53, modifiers.isEmpty, self.inputState == .composing, self.assistanceHelpVisible {
            if let text = self.currentConverterView?.nextTextCompletion ?? self.currentConverterView?.predictionCandidates.first?.displayText {
                self.dismissAssistance(text)
            }
            self.hideCompletionDisplay()
            return nil // 読みを取り消す本来のazooKeyの経路へ渡す。
        }
        if event.keyCode == 53, modifiers.isEmpty, self.inputState == .none {
            guard self.assistanceHelpVisible else { return false }
            if let text = self.idleCompletion?.text ?? self.currentConverterView?.nextTextCompletion { self.dismissAssistance(text) }
            else { self.recordAssistanceVerb("verb_esc") }
            self.cancelIdleCompletion(); self.hidePredictionWindow(); return true
        }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift, !self.assistanceHelpVisible,
           self.inputState != .selecting, self.inputState != .replaceSuggestion {
            self.quoteRequestGeneration &+= 1
            if self.inputState == .none, self.pendingKeyEventCount == 0, PersonalLearner.isRecording {
                let context = self.currentConverterTextContext()
                if let scene = self.assistanceSceneKey(left: context.leftSideContext, right: context.rightSideContext) {
                    self.tabTracker.passed(scene: scene, left: context.leftSideContext); self.observingPassedTab = true
                }
            }
            return false
        }
        return nil
    }

    @MainActor func enqueueAssistanceClientAction(_ action: @escaping (ShizukuInputController) -> Void) {
        let generation = self.activationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activationGeneration == generation else { return }
            action(self)
        }
    }

    @MainActor private func clearAssistanceMarkAfterCallback(client: IMKTextInput) {
        self.enqueueAssistanceClientAction { owner in
            owner.setClientMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0), client: client)
        }
    }

    @MainActor func queueCommittedAssistanceUndo(_ text: String, client: IMKTextInput) -> Bool {
        guard let expected = self.committedAssistanceContext(text, client: client) else { return false }
        self.enqueueAssistanceClientAction { owner in
            guard let current = owner.committedAssistanceContext(text, client: client),
                  current.range == expected.range, current.documentLength == expected.documentLength else { return }
            guard owner.removeCommittedAssistance(text, client: client) else { return }
            owner.countingBackspacesAfterCommit = false; owner.backspacesAfterCommit = 0
            owner.cancelIdleCompletion(); owner.recordAssistanceVerb("verb_undo", count: text.count)
        }
        return true
    }

    @MainActor private func committedAssistanceContext(_ text: String, client: IMKTextInput) -> (range: NSRange, documentLength: Int)? {
        guard client.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag)) else { return nil }
        let length = (text as NSString).length
        let selection = client.selectedRange(), documentLength = client.length(), marked = client.markedRange()
        guard length > 0, selection.location != NSNotFound, selection.length == 0,
              selection.location >= length, documentLength != NSNotFound, documentLength >= selection.location,
              marked.location == NSNotFound || marked.length == 0 else { return nil }
        let range = NSRange(location: selection.location - length, length: length)
        var actual = NSRange(location: NSNotFound, length: 0)
        guard client.string(from: range, actualRange: &actual) == text, actual == range else { return nil }
        return (range, documentLength)
    }

    /// Re-mark only the verified suffix, then clear that marked range outside handle.
    /// Clients without document access fall back to the original Backspace path.
    @MainActor func removeCommittedAssistance(_ text: String, client: IMKTextInput) -> Bool {
        guard let context = self.committedAssistanceContext(text, client: client) else { return false }
        let range = context.range, documentLength = context.documentLength, length = range.length
        self.setClientMarkedText(text, selectionRange: NSRange(location: length, length: 0), replacementRange: range, client: client)
        self.setClientMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0), client: client)
        return client.length() == documentLength - length
    }

    @MainActor private func dismissAssistance(_ text: String) {
        let hash = AssistanceVerbs.fingerprint(text)
        self.dismissedAssistance.insert(hash)
        self.recordAssistanceVerb("verb_esc", hash: hash)
        self.idleGeneration &+= 1; self.idleCompletionWorkItem?.cancel(); self.skeletonWorkItem?.cancel()
    }

    @MainActor private func showPlacedAssistance(client: IMKTextInput, selectionOffset: Int? = nil) {
        if self.placedAssistance?.commitPending == true {
            self.commitPlacedAssistance(client: client)
            return
        }
        self.placedPresentationVersion &+= 1
        let version = self.placedPresentationVersion
        if !self.placedPresentationPending {
            self.placedPendingSelection = client.selectedRange()
            self.placedPendingDocumentLength = client.length()
        }
        self.placedPresentationPending = true
        self.placedPendingCaret = selectionOffset ?? (self.placedAssistance?.text.utf16.count ?? 0)
        self.enqueueAssistanceClientAction { owner in
            guard owner.placedPresentationVersion == version, owner.placedAssistance != nil else { return }
            guard client.selectedRange() == owner.placedPendingSelection,
                  client.length() == owner.placedPendingDocumentLength else {
                owner.placedAssistance = nil; owner.placedPresentationPending = false
                owner.hideCompletionDisplay(); return
            }
            owner.placedPresentationPending = false
            owner.applyPlacedAssistance(client: client, selectionOffset: selectionOffset)
        }
    }

    @MainActor private func applyPlacedAssistance(client: IMKTextInput, selectionOffset: Int? = nil) {
        guard let placed = self.placedAssistance else { return }
        guard !placed.text.isEmpty else {
            self.placedAssistance = nil
            self.setClientMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0), client: client)
            self.hideCompletionDisplay()
            return
        }
        let attributes = self.mark(forStyle: kTSMHiliteSelectedConvertedText, at: NSRange(location: NSNotFound, length: 0)) as? [NSAttributedString.Key: Any] ?? [:]
        self.setClientMarkedText(NSAttributedString(string: placed.text, attributes: attributes), selectionRange: NSRange(location: selectionOffset ?? (placed.text as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0), client: client)
        let range = client.markedRange()
        if range.location == NSNotFound || range.length == 0 {
            if let app = self.ghostClientBundleID { self.failedMarkedApps.insert(app) }
            self.placedAssistance = nil
            if self.getLeftSideContext(maxCount: 2000)?.hasSuffix(placed.text) == true {
                self.noteAssistanceInserted(placed.text)
                self.continueVisibleAssistance(placed.remaining, from: placed.anchor, accepted: placed.text)
            } else {
                // 反映の遅いアプリに同じ本文を二重に挿入しない。次の明示Tabで文脈を確認して即確定する。
                var retry = placed.anchor; retry.text = placed.text + placed.remaining
                self.idleCompletion = retry
                self.completionPopupWindow.show(text: retry.text, lineRect: retry.lineRect, avoiding: self.otherIMEWindows)
            }
            return
        }
        if !placed.remaining.isEmpty {
            self.completionPopupWindow.show(text: placed.remaining, lineRect: placed.anchor.lineRect, avoiding: self.otherIMEWindows)
        } else { self.hideCompletionDisplay() }
    }

    @MainActor private func commitPlacedAssistance(client: IMKTextInput, afterKeyCallback: Bool = true) {
        if afterKeyCallback {
            guard self.placedAssistance != nil else { return }
            self.placedAssistance?.commitPending = true
            self.placedPresentationVersion &+= 1
            let version = self.placedPresentationVersion
            if !self.placedPresentationPending {
                self.placedPendingSelection = client.selectedRange()
                self.placedPendingDocumentLength = client.length()
            }
            self.placedPresentationPending = true
            self.placedPendingCaret = self.placedAssistance?.text.utf16.count ?? 0
            self.enqueueAssistanceClientAction { owner in
                guard owner.placedPresentationVersion == version else { return }
                guard client.selectedRange() == owner.placedPendingSelection,
                      client.length() == owner.placedPendingDocumentLength else {
                    owner.placedAssistance = nil; owner.placedPresentationPending = false
                    owner.hideCompletionDisplay(); return
                }
                owner.finishPlacedAssistanceCommit(client: client)
            }
        } else { self.finishPlacedAssistanceCommit(client: client) }
    }

    @MainActor private func finishPlacedAssistanceCommit(client: IMKTextInput) {
        guard let placed = self.placedAssistance else { return }
        if self.placedPresentationPending,
           client.selectedRange() != self.placedPendingSelection || client.length() != self.placedPendingDocumentLength {
            self.placedAssistance = nil; self.placedPresentationVersion &+= 1
            self.placedPresentationPending = false; self.hideCompletionDisplay()
            return
        }
        self.placedAssistance = nil
        self.placedPresentationVersion &+= 1; self.placedPresentationPending = false
        self.insertAssistanceAfterCallback(placed.text, client: client)
        self.assistanceUndo = placed.lastChunk.isEmpty ? nil : (placed.lastChunk, Date())
        if placed.continueAfterCommit {
            self.continueVisibleAssistance(placed.remaining, from: placed.anchor, accepted: placed.text)
        }
    }

    @MainActor private func insertAssistanceAfterCallback(_ text: String, client: IMKTextInput) {
        let marked = client.markedRange()
        let start = marked.location == NSNotFound ? client.selectedRange().location : marked.location
        self.insertClientText(text, replacementRange: NSRange(location: NSNotFound, length: 0), client: client)
        if start != NSNotFound { self.pendingCaretCheck = (start, text) }
        self.noteAssistanceInserted(text)
    }

    @MainActor private func noteAssistanceInserted(_ text: String) {
        self.assistanceUndo = (text, Date())
        self.converterServerClient.send({ _ in .completion(.idleAccepted(text: text)) }, completion: { _ in })
        if Config.PersonalLearning().value { self.countingBackspacesAfterCommit = true; self.backspacesAfterCommit = 0 }
    }

    @MainActor private func continueVisibleAssistance(_ remaining: String, from idle: IdleCompletion, accepted: String) {
        if !remaining.isEmpty {
            var next = idle; next.text = remaining; next.leftContext += accepted
            self.idleCompletion = next
            self.completionPopupWindow.show(text: remaining, lineRect: next.lineRect, avoiding: self.otherIMEWindows)
        } else {
            self.scheduleIdleCompletion(leftContext: idle.leftContext + accepted, caretX: idle.caretX,
                                        lineRect: idle.lineRect, fontSize: idle.fontSize, delay: 0.2)
        }
    }

    /// 今のアプリを、ウィンドウ文脈の参照から外す（設定の除外アプリに足す。戻すときは設定から）
    @MainActor @objc func excludeWindowContextForApp(_ sender: Any) {
        guard let app = self.ghostClientBundleID else { return }
        let config = Config.WindowContextExcludedApps()
        var apps = PersonalPrivacy.userExcludedApps(config.value)
        guard apps.insert(app).inserted else { return }
        config.value = apps.sorted().joined(separator: "\n")
        self.cancelIdleCompletion(); self.hideCompletionDisplay()
    }

    /// Menu validation reads only this cached value; it never asks the client.
    var canExcludeWindowContext: Bool { self.ghostClientBundleID != nil }

    // MARK: - 直前の文の清書（llm-ime）

    @MainActor private func resetCleanUp() {
        self.windowHintUI.loaded?.hide(); self.windowHintGeneration &+= 1
        self.cleanUpUI.loaded?.hide(); self.cleanUpChoice = nil; self.cleanUpPending = false
        self.cleanUpGeneration &+= 1; self.cleanUpUndo = nil; self.cleanUpWorkItem?.cancel(); self.cleanUpWorkItem = nil
    }

    /// 直前の 1 文の清書を Server に頼む（順序付きキューを通さない）。頼んだら true。
    /// 結果が届いた時点で次のキーを打っていなければ cleanUpChoice に入れて onResult を呼ぶ
    @MainActor @discardableResult
    private func requestCleanUp(left: String, automatic: Bool, onResult: @escaping @MainActor () -> Void) -> Bool {
        guard let target = CleanUp.lastSentence(left) else { return false }
        self.cleanUpGeneration &+= 1
        let generation = self.cleanUpGeneration, activation = self.activationGeneration, keys = self.keyDownCount
        self.converterServerClient.sendUnordered({ _ in
            .localLLM(.cleanUp(text: target.sentence, before: target.before, automatic: automatic))
        }) { [weak self] response in
            Task { @MainActor in
                guard let self, self.cleanUpGeneration == generation, self.activationGeneration == activation else { return }
                self.cleanUpPending = false
                guard self.keyDownCount == keys, let text = response?.localLLMResult?.text, !text.isEmpty,
                      !self.dismissedAssistance.contains(AssistanceVerbs.fingerprint(text)) else { onResult(); return }
                self.cleanUpChoice = (target.sentence, text)
                self.cleanUpUsedReference = response?.localLLMResult?.usedWindowReference == true
                onResult()
            }
        }
        return true
    }

    /// 文末で確定したあと、放置と同じ待ち時間で手が止まっていたら、清書を 1 件だけ出す（設定でオンにしたときだけ）
    @MainActor private func scheduleCleanUp(leftContext: String, lineRect: NSRect) {
        self.cleanUpWorkItem?.cancel()
        guard Config.CleanUpAutoOffer().value, Config.PersonalLearning().value, lineRect.height > 0,
              let app = self.ghostClientBundleID, !PersonalPrivacy.isExcluded(app: app) else { return }
        let keys = self.keyDownCount, activation = self.activationGeneration
        // 待っている間にローカル LLM を読み込んでおく（読み込み済みなら何もしない）
        self.converterServerClient.sendUnordered({ _ in .localLLM(.preload) }) { _ in }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.keyDownCount == keys, self.activationGeneration == activation, self.inputState == .none,
                      !(self.quoteChoicesUI.loaded?.isVisible == true) else { return }
                self.requestCleanUp(left: leftContext, automatic: true) { [weak self] in
                    guard let self, let choice = self.cleanUpChoice, self.keyDownCount == keys, self.inputState == .none,
                          !(self.quoteChoicesUI.loaded?.isVisible == true) else { return }
                    // 直す＞生成: 放置の続きより先に出す
                    self.cancelIdleCompletion(); self.hideCompletionDisplay(); self.hidePredictionWindow()
                    self.cleanUpWindow.show(text: "", lineRect: lineRect, avoiding: self.otherIMEWindows,
                                            attributed: CompletionPopupWindow.diffText(original: choice.original, revised: choice.text, prefix: "清書: "),
                                            hint: self.cleanUpUsedReference ? "Tab・画面" : "Tab")
                    self.recordAssistanceVerb("cleanup_shown", hash: AssistanceVerbs.fingerprint(choice.text), count: 1)
                }
            }
        }
        self.cleanUpWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (self.tunedIdleCompletionDelay ?? Self.idleCompletionDelay), execute: item)
    }

    /// AI への指示の場面の短い確定が指す画面の選択肢を、薄い案内として出す（入力は書き換えない）
    @MainActor private func requestWindowHint(_ text: String, lineRect: NSRect) {
        self.windowHintGeneration &+= 1
        let generation = self.windowHintGeneration, activation = self.activationGeneration, keys = self.keyDownCount
        self.converterServerClient.sendUnordered({ _ in .completion(.windowHint(text: text)) }) { [weak self] response in
            Task { @MainActor in
                guard let self, self.windowHintGeneration == generation, self.activationGeneration == activation,
                      self.keyDownCount == keys, let hint = response?.windowHint, !hint.isEmpty else { return }
                self.windowHintWindow.show(text: "→ " + hint, lineRect: lineRect, avoiding: self.otherIMEWindows, hint: "画面")
            }
        }
    }

    /// 清書を入れる。カーソルの直前が元の文のままのときだけ置き換え、2 秒以内の BS で元に戻せるようにする
    @MainActor private func acceptCleanUp(client: IMKTextInput) -> Bool {
        guard let choice = self.cleanUpChoice else { return false }
        self.cleanUpChoice = nil
        return self.queueCommittedReplacement(choice.original, with: choice.text, client: client, event: "cleanup_accepted") { owner in
            owner.cleanUpUndo = (choice.original, choice.text, Date())
        }
    }

    /// カーソルの直前にある text を照合してから replacement に置き換える（handle の外で行う）。照合できなければ false
    @MainActor private func queueCommittedReplacement(_ text: String, with replacement: String, client: IMKTextInput, event: String,
                                                      then: ((ShizukuInputController) -> Void)? = nil) -> Bool {
        guard let expected = self.committedAssistanceContext(text, client: client) else { return false }
        self.enqueueAssistanceClientAction { owner in
            guard let current = owner.committedAssistanceContext(text, client: client),
                  current.range == expected.range, current.documentLength == expected.documentLength else { return }
            owner.insertClientText(replacement, replacementRange: current.range, client: client)
            owner.cancelIdleCompletion()
            owner.recordAssistanceVerb(event, hash: AssistanceVerbs.fingerprint(replacement), count: replacement.count)
            then?(owner)
        }
        return true
    }

    @MainActor @objc func summonQuoteChoices(_ sender: Any?) {
        guard let client = self.client(), Config.PersonalLearning().value else { return }
        let context = self.currentConverterTextContext()
        guard let observation = self.makeSceneObservation() else { return }
        self.quoteRequestGeneration &+= 1
        let generation = self.quoteRequestGeneration, activation = self.activationGeneration, keys = self.keyDownCount
        self.cancelIdleCompletion()
        self.hidePredictionWindow()
        self.recordAssistanceVerb("verb_summon")
        self.converterServerClient.send({ _ in .completion(.quotes(scene: observation, left: context.leftSideContext ?? "", right: context.rightSideContext)) }) { [weak self] response in
            Task { @MainActor in
                guard let self, self.quoteRequestGeneration == generation, self.activationGeneration == activation, self.keyDownCount == keys,
                      let candidates = response?.quoteCandidates else { return }
                self.quoteChoices = candidates.filter { !self.dismissedAssistance.contains(AssistanceVerbs.fingerprint($0)) }
                self.quoteChoiceIndex = 0
                self.showQuoteChoices()
            }
        }
        self.cleanUpChoice = nil; self.cleanUpUI.loaded?.hide()
        self.cleanUpPending = self.requestCleanUp(left: context.leftSideContext ?? "", automatic: false) { [weak self] in
            guard let self, self.quoteRequestGeneration == generation, self.quoteChoicesUI.loaded?.isVisible == true else { return }
            self.showQuoteChoices()
        }
        _ = client
    }

    @MainActor private func showQuoteChoices() {
        var rect = self.cachedCursorRect ?? self.ghostAnchor?.startRect ?? .zero
        if rect.height <= 0, let client = self.client() { client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect) }
        if rect.height <= 0 || !rect.minX.isFinite || !rect.minY.isFinite {
            let point = NSEvent.mouseLocation; rect = NSRect(x: point.x, y: point.y, width: 1, height: 18)
        }
        let first = self.quoteChoices.isEmpty ? "前に書いた文はまだありません" : "前に書いた: " + self.quoteChoices[self.quoteChoiceIndex]
        let third = self.cleanUpChoice == nil ? (self.cleanUpPending ? "清書（整えています…）" : "清書（整える所はありません）") : ""
        let text = "1  \(first)\n2  穴埋め（今回は空欄）\n3  \(third)\nCtrl+Tab: 次案　Tab/1: 入れる　3: 清書を入れる　Esc: 閉じる"
        var attributed: NSAttributedString?
        if let choice = self.cleanUpChoice {
            let font = NSFont.systemFont(ofSize: 15)
            let lines = NSMutableAttributedString(string: "1  \(first)\n2  穴埋め（今回は空欄）\n", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            lines.append(CompletionPopupWindow.diffText(original: choice.original, revised: choice.text,
                                                        prefix: self.cleanUpUsedReference ? "3  清書（画面を参考）: " : "3  清書: "))
            lines.append(NSAttributedString(string: "\nCtrl+Tab: 次案　Tab/1: 入れる　3: 清書を入れる　Esc: 閉じる", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            attributed = lines
        }
        self.hideCompletionDisplay()
        self.magicFragmentsUI.loaded?.hide(); self.hideReplaceSuggestionCandidateView()
        self.quoteChoicesWindow.show(text: text, lineRect: rect, avoiding: self.otherIMEWindows, rawLines: true, attributed: attributed)
        if !self.quoteChoices.isEmpty {
            self.recordAssistanceVerb("quote_shown", hash: AssistanceVerbs.fingerprint(self.quoteChoices[self.quoteChoiceIndex]), count: 1)
        }
    }

    @MainActor private func acceptQuoteChoice() {
        guard !self.quoteChoices.isEmpty else { return }
        let text = self.quoteChoices[self.quoteChoiceIndex]
        let generation = self.activationGeneration
        self.quoteChoicesUI.loaded?.hide()
        self.converterServerClient.send({ _ in .completion(.acceptQuote(text: text)) }) { [weak self] response in
            Task { @MainActor in
                guard let self, self.activationGeneration == generation, let response, response.handled,
                      response.effects.contains(where: { if case .insertText = $0 { return true }; return false }) else { return }
                self.placedAssistance = nil
                self.apply(response)
                self.assistanceUndo = (text, Date())
            }
        }
    }

    @MainActor @objc func teachSelection(_ sender: Any?) {
        guard PersonalLearner.isRecording, let client = self.client(),
              !PersonalPrivacy.isExcluded(app: client.bundleIdentifier() ?? "") else { return }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.length > 0, selection.length <= 4800 else { return }
        var actual = NSRange()
        guard let text = client.string(from: selection, actualRange: &actual), actual == selection,
              let observation = self.makeSceneObservation(), !text.isEmpty else { return }
        let context = self.currentConverterTextContext()
        self.converterServerClient.send({ _ in .completion(.teach(text: text, scene: observation, left: context.leftSideContext ?? "", right: context.rightSideContext)) }) { [weak self] response in
            Task { @MainActor in
                guard let self, let result = response?.teachingResult else { return }
                self.teachingUndoReceipt = result.token.map { ($0, Date().addingTimeInterval(10)) }
                self.undoTeachMenuItem.title = "手本を取り消す（10秒以内・\(result.count)文）"
            }
        }
    }

    @MainActor @objc func undoTaughtSelection(_ sender: Any?) {
        guard let undo = self.teachingUndoReceipt, Date() <= undo.until else { return }
        self.teachingUndoReceipt = nil
        self.converterServerClient.send({ _ in .completion(.undoTeach(token: undo.token)) }) { _ in }
    }

    @MainActor private func scheduleRetentionCheck(_ token: String) {
        guard self.retentionWorkItems[token] == nil else { return }
        let generation = self.activationGeneration
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retentionWorkItems[token] = nil
                guard self.activationGeneration == generation, let client = self.client() else {
                    self.converterServerClient.sendUnordered({ _ in .completion(.retained(token: token, left: nil, complete: false)) }, completion: { _ in })
                    return
                }
                let left = self.getLeftSideContext(maxCount: 2000)
                let selection = client.selectedRange(), length = client.length()
                let complete = length > 0 && selection.length == 0 && selection.location == length
                    && selection.location == (left.map { ($0 as NSString).length } ?? -1)
                self.converterServerClient.sendUnordered({ _ in .completion(.retained(token: token, left: left, complete: complete)) }, completion: { _ in })
            }
        }
        self.retentionWorkItems[token] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: item)
    }

    /// llm-ime: Tab で入れた続き予測のあと、カーソルが入れた文字列の途中に残っていたら末尾へ送る。
    ///
    /// Chromium 系のアプリ（Claude のアプリなど）の入力欄に改行を含む文字列を入れると、カーソルが改行の数だけ手前に残る
    /// （「今日|は、」「開催されまし|た。」）。そのアプリは位置を数えるとき改行（段落の区切り）を 2 文字に数えるため、
    /// 文書の中の位置からは末尾かどうか判断できない（カーソルの位置も「入れ始め＋文字数」と同じに見える）。
    /// そこで、カーソルの直後の「改行の数」だけの文字が、入れた文字列の最後の文字と同じかを確かめ、同じなら
    /// その部分を同じ文字列で置き換えて、カーソルを置き換えた文字の後ろ（＝入れた文字列の末尾）に移す。
    /// アプリへの反映を待つため、Tab の少し後（次の予測を始める直前、またはその前に来た次のキーの handle の中）に呼ぶ
    private func fixCaretAfterCompletionInsertion() {
        guard let check = self.pendingCaretCheck, let client = self.client() else {
            return
        }
        self.pendingCaretCheck = nil
        let newlines = check.text.reduce(0) { $0 + ($1.isNewline ? 1 : 0) }
        let selection = client.selectedRange()
        Self.ghostLog.notice("caret check: start=\(check.start) length=\((check.text as NSString).length) newlines=\(newlines) selection=\(selection.location),\(selection.length)")
        guard newlines > 0, selection.location != NSNotFound, selection.length == 0 else {
            return
        }
        // 最後の行（最後の改行の後ろ）の中に収まる場合だけ扱う
        let lastLine = check.text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let text = check.text as NSString
        guard (lastLine as NSString).length >= newlines else {
            return
        }
        let suffix = text.substring(from: text.length - newlines)
        var actual = NSRange()
        guard let after = client.string(from: NSRange(location: selection.location, length: newlines), actualRange: &actual),
              after == suffix else {
            // カーソルは末尾にある（直後は入れた文字列の続きではない）
            return
        }
        self.insertClientText(suffix, replacementRange: NSRange(location: selection.location, length: newlines), client: client)
        Self.ghostLog.notice("caret fix: re-inserted the last \(newlines) units after the caret to move it to the end")
    }

    /// llm-ime: 空の欄の書き出し（文の骨組みの先出し）。入力欄に入った・何も入力していない状態で Enter（送信）を押した後、
    /// 待ち時間が過ぎてもキーを押しておらず、入力中の文字も続き予測もなく、欄が空なら、その場面のいつもの書き出しを Server に尋ねて
    /// 灰色で出す（Tab で入れる）。場面学習と「放置で続きを自動生成」がオンのときだけ。出すかどうか（記録が足りるか）は Server が決める
    @MainActor private func scheduleSkeleton() {
        self.skeletonWorkItem?.cancel()
        guard Config.PersonalLearning().value, Self.isIdleCompletionEnabled else {
            return
        }
        let generation = self.activationGeneration
        let keys = self.keyDownCount
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activationGeneration == generation, self.keyDownCount == keys, self.inputState == .none,
                      self.pendingKeyEventCount == 0, self.idleCompletion == nil, Self.isIdleCompletionEnabled, Config.PersonalLearning().value,
                      let client = self.client(), client.length() == 0 else {
                    return
                }
                // 欄の長さをいつも 0 と返すアプリがあるので、カーソルの前が空と分かり、欄の最初の 1 文字もないときだけ空とみなす
                var actual = NSRange()
                guard client.string(from: NSRange(location: 0, length: 0), actualRange: &actual) == "",
                      (client.string(from: NSRange(location: 0, length: 1), actualRange: &actual) ?? "").isEmpty else {
                    return
                }
                var rect: NSRect = .zero
                client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
                // 空の欄では、初期化されていない・0 の矩形を返すアプリがある。画面の中で、入力先のアプリのウィンドウの中にあるときだけ出す
                let caret = NSPoint(x: rect.minX, y: rect.midY)
                guard PersonalOpening.isUsableAnchor(
                    rect, screens: NSScreen.screens.map(\.frame), clientWindow: self.clientWindowFrame(containing: caret, clientOnly: true)
                ) else {
                    Self.ghostLog.notice("skeleton: caret rect rejected: \(NSStringFromRect(rect), privacy: .public)")
                    return
                }
                let observation = ConverterSceneObservation(
                    bundleID: self.ghostClientBundleID,
                    previousBundleID: ApplicationActivationTracker.shared.previousApplication(before: self.ghostClientBundleID),
                    documentLength: 0,
                    startedEmpty: true,
                    monospaced: self.lastFontIsFixedPitch,
                    backspacesAfterCommit: 0
                )
                self.converterServerClient.sendUnordered({ _ in .completion(.skeleton(scene: observation)) }) { [weak self] response in
                    Task { @MainActor in
                        guard let self, self.activationGeneration == generation, self.keyDownCount == keys, self.inputState == .none,
                              self.idleCompletion == nil, let text = response?.snapshot.nextTextCompletion, !text.isEmpty else {
                            return
                        }
                        guard !self.dismissedAssistance.contains(AssistanceVerbs.fingerprint(text)) else { return }
                        // 空の欄では文字の大きさが分からないので、行の高さから見積もる
                        let fontSize = max(10, min(rect.height / 1.25, 28))
                        let layout = self.ghostLayout(caret: NSPoint(x: rect.minX, y: rect.midY), currentLine: "", fontSize: fontSize)
                        let skeleton = IdleCompletion(
                            text: text, leftContext: "", caretX: rect.minX, lineRect: rect, fontSize: fontSize,
                            lineStartX: layout.lineStartX, rightEdge: layout.rightEdge
                        )
                        self.idleCompletion = skeleton
                        if Config.NextTextCompletionInlineGhost().value {
                            self.ghostTextWindow.show(
                                text: skeleton.text, caretX: skeleton.caretX, lineRect: skeleton.lineRect, lineStartX: skeleton.lineStartX,
                                fontSize: skeleton.fontSize, rightEdge: skeleton.rightEdge
                            )
                        } else {
                            self.completionPopupWindow.show(text: skeleton.text, lineRect: skeleton.lineRect, avoiding: self.otherIMEWindows)
                        }
                    }
                }
            }
        }
        self.skeletonWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (self.tunedIdleCompletionDelay ?? Self.idleCompletionDelay), execute: item)
    }

    /// llm-ime: 放置で続きを自動生成するか（続き予測と、その中の「放置で自動生成」の両方がオン）
    static var isIdleCompletionEnabled: Bool {
        Config.NextTextCompletion().value && Config.NextTextCompletionIdle().value
    }

    /// 放置で続きを自動生成をオフにしたときに、待っている予測と表示中の続きを消す
    func cancelIdleCompletion() {
        self.idleCompletionWorkItem?.cancel()
        self.idleGeneration &+= 1
        self.idleCompletion = nil
        self.hideCompletionDisplay()
    }

    /// llm-ime: 続き予測の表示（別ウィンドウ・灰色の文字の両方）を消す
    private func hideCompletionDisplay() {
        self.ghostUI.loaded?.hide()
        self.completionUI.loaded?.hide()
    }

    /// 続き予測のウィンドウが重ならないようにする、IME のほかのウィンドウ
    private var otherIMEWindows: [NSWindow] {
        [self.candidatesUI.loaded?.window, self.predictionUI.loaded?.window, self.replaceSuggestionsUI.loaded?.window].compactMap { $0 }
    }

    /// llm-ime: 続き予測で Tab を押すと確定される全文（snapshot.nextTextCompletion）を表示する。
    /// 既定は入力中の文字の下の別ウィンドウ、設定で入力中の文字の右に薄い灰色で重ねる表示
    func refreshGhostText() {
        if (self.quoteChoicesUI.loaded?.isVisible == true) { self.hideCompletionDisplay(); return }
        guard self.inputState == .composing,
              let suggestion = self.currentConverterView?.nextTextCompletion, !suggestion.isEmpty,
              !self.dismissedAssistance.contains(AssistanceVerbs.fingerprint(suggestion)),
              let anchor = self.ghostAnchor else {
            // 何も入力していない状態の続き予測を表示中なら消さない
            if self.idleCompletion == nil {
                self.hideCompletionDisplay()
            }
            return
        }
        guard Config.NextTextCompletionInlineGhost().value else {
            // 入力中の文字の先頭の行の下に出す（予測変換の候補と同じ基準。どのアプリでも位置が正しく取れる）
            self.completionPopupWindow.show(text: suggestion, lineRect: anchor.startRect, avoiding: self.otherIMEWindows)
            return
        }
        let marked = self.currentMarkedText().elements.map(\.content).joined()
        let x: CGFloat
        if let endX = anchor.endX {
            // キー入力の処理時点の末尾から、その後に増えた分（通常 1 文字）だけ右にずらす
            x = endX + GhostTextWindow.width(of: marked, fontSize: anchor.fontSize)
                - GhostTextWindow.width(of: anchor.markedText, fontSize: anchor.fontSize)
        } else {
            // 末尾の位置を返さないアプリでは、先頭から入力中の文字の幅だけ右
            x = anchor.startRect.minX + GhostTextWindow.width(of: marked, fontSize: anchor.fontSize)
        }
        // 入力中の文字の続きではなく「確定すると何になるか」の表示なので、少し間を空ける
        let ghostX = x + anchor.fontSize * 0.4
        let currentLine = (self.lastLeftContext.components(separatedBy: "\n").last ?? "") + marked
        let layout = self.ghostLayout(caret: NSPoint(x: ghostX, y: anchor.startRect.midY), currentLine: currentLine, fontSize: anchor.fontSize)
        self.ghostTextWindow.show(
            text: suggestion,
            caretX: ghostX,
            lineRect: anchor.startRect,
            lineStartX: layout.lineStartX,
            fontSize: anchor.fontSize,
            rightEdge: layout.rightEdge
        )
    }

    func refreshMarkedText() {
        if self.inputState == .replaceSuggestion && self.magicMarkingFailed { return }
        let highlight = self.mark(
            forStyle: kTSMHiliteSelectedConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let underline = self.mark(
            forStyle: kTSMHiliteConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let text = NSMutableAttributedString(string: "")
        let currentMarkedText = self.currentMarkedText()
        for part in currentMarkedText.elements where !part.content.isEmpty {
            let attributes: [NSAttributedString.Key: Any]? = switch part.focus {
            case .focused: highlight
            case .unfocused: underline
            case .none: [:]
            }
            text.append(
                NSAttributedString(
                    string: part.content,
                    attributes: attributes
                )
            )
        }
        guard let client = self.client() else { self.traceGuard(.noClient, request: self.inputTraceRequestID); return }
        self.setClientMarkedText(
            text,
            selectionRange: currentMarkedText.selectionRange.nsRange,
            replacementRange: NSRange(location: NSNotFound, length: 0), client: client
        )
    }

    private func currentMarkedText() -> ConverterMarkedText {
        if self.inputState == .replaceSuggestion, !self.magicInline, let reading = self.magicFallbackReading {
            return .init(elements: [.init(content: reading, focus: .unfocused)], selectionRange: .init(location: reading.utf16.count, length: 0))
        }
        if let currentConverterView {
            return currentConverterView.markedText
        }
        return ConverterSessionSnapshot.empty.markedText
    }
}

extension ShizukuInputController: CandidatesViewControllerDelegate {
    func candidateSubmitted() {
        Task { @MainActor in
            guard self.currentConverterView != nil else {
                return
            }
            self.converterServerClient.sendIfSessionOpen(
                { _ in .candidate(.submitSelectedCandidate(context: self.currentConverterTextContext())) },
                completion: { [weak self] response in
                    Task { @MainActor in
                        guard let self, let response else {
                            return
                        }
                        self.apply(response)
                    }
                }
            )
        }
    }

    func candidateSelectionChanged(_ row: Int) {
        Task { @MainActor in
            guard self.currentConverterView != nil else {
                return
            }
            self.converterServerClient.sendIfSessionOpen(
                { _ in .candidate(.selectCandidate(index: row)) },
                completion: { [weak self] response in
                    Task { @MainActor in
                        guard let self, let response else {
                            return
                        }
                        self.apply(response)
                    }
                }
            )
        }
    }
}

extension ShizukuInputController {
    private var windowContextBinding: WindowContextBinding? {
        guard let app = self.ghostClientBundleID else { return nil }
        return .init(app: app, activation: "\(self.inputTraceID):\(self.activationGeneration)")
    }

    private func currentConverterTextContext() -> ConverterTextContext {
        ConverterTextContext(
            leftSideContext: self.getLeftSideContext(maxCount: ConverterTextContext.leftTransportCharacterLimit, alignStart: true),
            rightSideContext: self.getRightSideContext(),
            windowBinding: self.windowContextBinding
        )
    }

    /// alignStart: 先頭の位置を 256 文字単位にそろえる（打鍵ごとに先頭がずれないように。長さは maxCount-255〜maxCount）
    ///
    /// llm-ime: Chromium 系のアプリ（Claude のアプリなど）はカーソルの前後 100 文字ほどしか手元に持たず、それより広い範囲を
    /// 頼むと nil を返す。そのまま文脈なしで変換すると「申請」が「新生」になるため、取れなければ範囲を狭めて取り直す
    /// （変換に使うのは直前の 40 文字。続き予測は取れた分だけで予測する）
    func getLeftSideContext(maxCount: Int = ConverterTextContext.transportCharacterLimit, alignStart: Bool = false) -> String? {
        let endIndex = self.contextRange().location
        guard endIndex != NSNotFound else {
            return nil
        }
        var counts = [maxCount]
        for fallback in [100, 40] where fallback < maxCount {
            counts.append(fallback)
        }
        for (attempt, count) in counts.enumerated() {
            var start = max(endIndex - count, 0)
            if alignStart, attempt == 0, start > 0 {
                start = min(endIndex, (start + 255) / 256 * 256)
            }
            let leftRange = NSRange(location: start, length: endIndex - start)
            var actual = NSRange()
            if let leftSideContext = self.client().string(from: leftRange, actualRange: &actual) {
                if attempt > 0 {
                    Self.ghostLog.notice("left context: fell back to \(count) characters (\(leftSideContext.count) received)")
                }
                return leftSideContext
            }
            if start == 0 {
                break
            }
        }
        Self.ghostLog.notice("left context: not available (caret=\(endIndex))")
        return nil
    }

    func getRightSideContext(maxCount: Int = ConverterTextContext.transportCharacterLimit) -> String? {
        let range = self.contextRange()
        let startIndex = range.location + range.length
        let documentLength = self.client().length()
        // llm-ime: 場面学習（欄の形）に使う。ここで既に尋ねている値を覚えておく
        self.lastDocumentLength = documentLength
        guard startIndex < documentLength else {
            return nil
        }
        let rightRange = NSRange(location: startIndex, length: min(documentLength - startIndex, maxCount))
        var actual = NSRange()
        let rightSideContext = self.client().string(from: rightRange, actualRange: &actual)
        self.appendDebugMessage("\(#function): rightSideContext=\(rightSideContext ?? "nil")")
        return rightSideContext
    }

    /// llm-ime: 場面に合わせた入力モード。入力欄に入ったら、そのアプリでいつも使うモードを Server に尋ね、
    /// 設定「入力欄に合わせて英数・かなを切り替える」がオンで、まだ何も打っていなければ、そのモードにする
    /// （判断は PersonalInputMode.switchTarget だけで行い、設定がオフなら決して切り替えない）
    @MainActor private func startInputModeTracking() {
        guard Config.PersonalLearning().value, let bundleID = self.ghostClientBundleID else {
            self.inputModeTracking = nil
            return
        }
        self.inputModeTracking = InputModeTracking(bundleID: bundleID, languageAtActivation: self.inputLanguage)
        guard Config.PersonalInputModeSwitching().value else {
            return
        }
        let generation = self.activationGeneration
        self.converterServerClient.send({ _ in .lifecycle(.preferredInputMode(bundleID: bundleID)) }) { [weak self] response in
            Task { @MainActor in
                guard let self, self.activationGeneration == generation, var tracking = self.inputModeTracking,
                      let target = PersonalInputMode.switchTarget(
                        enabled: Config.PersonalInputModeSwitching().value,
                        preferred: response?.inputLanguage,
                        current: self.inputLanguage,
                        typedSinceActivation: tracking.done || tracking.userSwitched
                      ),
                      let client = self.client() else {
                    return
                }
                tracking.autoSwitched = target
                self.inputModeTracking = tracking
                self.switchInputLanguage(target, client: client)
                // 最初のキーと一緒に送る開始の情報も、切り替えた先のモードにする
                self.pendingConverterServerActivation?.inputLanguage = target
                self.converterServerClient.send({ _ in .lifecycle(.synchronizeInputLanguage(target)) }, completion: { _ in })
            }
        }
    }

    /// 最初に文字を打ったときのモードと、その前に自分で切り替えたかを送る（入力欄に入るたびに 1 回）
    @MainActor private func observeInputMode(event: NSEvent) {
        guard var tracking = self.inputModeTracking, !tracking.done else {
            return
        }
        // 英数（102）・かな（104）のキーで今と違うモードにした
        if event.keyCode == 102 || event.keyCode == 104 {
            if (event.keyCode == 102 ? InputLanguage.english : .japanese) != self.inputLanguage {
                tracking.userSwitched = true
                self.inputModeTracking = tracking
            }
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, let character = event.characters?.first,
              character.isLetter || character.isNumber || character.isPunctuation else {
            return
        }
        tracking.done = true
        self.inputModeTracking = tracking
        let bundleID = tracking.bundleID
        let language = self.inputLanguage
        let switched = tracking.userSwitched
        // このキーのイベントを Server に送った後に送る（最初のキーを待たせない）
        DispatchQueue.main.async { [weak self] in
            self?.converterServerClient.send(
                { _ in .lifecycle(.observeInputMode(bundleID: bundleID, language: language, switched: switched)) }, completion: { _ in }
            )
        }
    }

    /// llm-ime: 場面学習のメタ情報（学習がオフなら nil。nil なら Server は記録も学習の反映もしない）。
    /// handle の中で既に問い合わせた値だけを使う（新しい同期の問い合わせは Chromium 系でデッドロックの原因になる）
    @MainActor func makeSceneObservation() -> ConverterSceneObservation? {
        guard Config.PersonalLearning().value else {
            return ConverterSceneObservation(bundleID: self.ghostClientBundleID, previousBundleID: nil,
                documentLength: nil, startedEmpty: false, monospaced: nil, backspacesAfterCommit: 0)
        }
        let documentLength = self.lastDocumentLength.flatMap { $0 >= 0 && $0 != NSNotFound ? $0 : nil }
        // 入力を始めるときに欄が空なら、この欄では新しく書き始めた（送信して空になったチャット欄も）。
        // 欄の長さをいつも 0 と返すアプリがあるので、左文脈も空と分かるときだけ
        if self.inputState == .none, documentLength == 0, self.lastLeftContextKnownEmpty {
            self.fieldStartedEmpty = true
        }
        defer {
            self.backspacesAfterCommit = 0
        }
        return ConverterSceneObservation(
            bundleID: self.ghostClientBundleID,
            previousBundleID: ApplicationActivationTracker.shared.previousApplication(before: self.ghostClientBundleID),
            documentLength: documentLength,
            startedEmpty: self.fieldStartedEmpty,
            monospaced: self.lastFontIsFixedPitch,
            backspacesAfterCommit: self.backspacesAfterCommit
        )
    }

    private func contextRange() -> NSRange {
        let markedRange = self.client().markedRange()
        if self.hasClientMarkedText, markedRange.location != NSNotFound {
            return markedRange
        }
        let selectedRange = self.client().selectedRange()
        if selectedRange.location != NSNotFound {
            return selectedRange
        }
        return NSRange(location: 0, length: 0)
    }
}

extension ShizukuInputController: ReplaceSuggestionsViewControllerDelegate {
    @MainActor func replaceSuggestionSelectionChanged(_ row: Int) {
        guard self.currentConverterView?.replaceSuggestionSelectionIndex != row else {
            return
        }
        self.converterServerClient.sendIfSessionOpen(
            { _ in .replaceSuggestion(.selectReplaceSuggestionCandidate(index: row)) },
            completion: { [weak self] response in
                Task { @MainActor in
                    guard let self, let response else {
                        return
                    }
                    self.apply(response)
                }
            }
        )
    }

    func replaceSuggestionSubmitted() {
        Task { @MainActor in
            self.submitSelectedSuggestionCandidate()
        }
    }
}

// Suggest Candidate
extension ShizukuInputController {
    // MARK: - Replace Suggestion Request Handling
    @MainActor func requestReplaceSuggestion() {
        self.appendDebugMessage("requestReplaceSuggestion: 開始")

        // リクエスト開始時に前回の候補をクリアし、ウィンドウを非表示にする
        self.replaceSuggestionsUI.loaded?.controller.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.replaceSuggestionsUI.loaded?.window.setIsVisible(false)
        self.replaceSuggestionsUI.loaded?.window.orderOut(nil)

        guard let currentConverterView, !currentConverterView.isEmpty else {
            self.appendDebugMessage("requestReplaceSuggestion: skipped because converter server composition is empty")
            return
        }
        // llm-ime: 生成に 1 秒以上かかる（ローカル LLM・Foundation Models）ため、タイムアウト 1 秒の
        // 順序付きキューではなく、キューを通さずに送る。設定（AI の種類）の同期が届いてから送る
        let config = self.converterServerSessionConfig
        let context = self.currentConverterTextContext()
        self.converterServerClient.send({ _ in .updateConfig(config) }) { [weak self] _ in
            Task { @MainActor in
                guard let owner = self else { return }
                owner.converterServerClient.sendUnordered(
                    { _ in .replaceSuggestion(.request(context: context)) },
                    completion: { [weak controller = owner] response in
                        Task { @MainActor in
                            guard let controller else {
                                return
                            }
                            guard let response else {
                                NSLog("Shizuku: ConverterServerから候補を取得できませんでした")
                                return
                            }
                            guard controller.currentConverterView?.convertTarget == response.snapshot.convertTarget else {
                                controller.appendDebugMessage("候補ウィンドウ更新をスキップ: composition changed")
                                return
                            }
                            controller.magicFallbackReading = controller.currentConverterView?.convertTarget
                            controller.magicInline = AssistanceVerbs.shouldStage(String(repeating: "x", count: 13), app: controller.client()?.bundleIdentifier(), failedApps: controller.failedMarkedApps)
                            controller.magicMarkingFailed = false
                            controller.currentConverterView = response.snapshot
                            controller.inputState = response.inputState.inputState
                            controller.visibleMagicFragments = response.magicFragments ?? []
                            controller.refreshMarkedText()
                            if controller.magicInline, let client = controller.client(), client.markedRange().location == NSNotFound || client.markedRange().length == 0 {
                                if let app = client.bundleIdentifier() { controller.failedMarkedApps.insert(app) }
                                controller.magicInline = false; controller.magicMarkingFailed = true
                            }
                            controller.refreshReplaceSuggestionWindow()
                            controller.refreshMagicFragments()
                        }
                    }
                )
            }
        }
        self.appendDebugMessage("requestReplaceSuggestion: 終了")
    }

    @MainActor private func sendMagicCommand(_ command: ConverterReplaceSuggestionCommand) {
        let generation = self.activationGeneration
        self.converterServerClient.send({ _ in .replaceSuggestion(command) }) { [weak self] response in
            Task { @MainActor in
                guard let self, generation == self.activationGeneration, let response else { return }
                self.apply(response)
            }
        }
    }

    @MainActor private func refreshMagicFragments() {
        guard self.magicInline, self.inputState == .replaceSuggestion, !(self.quoteChoicesUI.loaded?.isVisible == true),
              !self.visibleMagicFragments.isEmpty else { self.magicFragmentsUI.loaded?.hide(); return }
        var rect = self.cachedCursorRect ?? .zero
        if rect.height <= 0, let client = self.client() { client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect) }
        if rect.height <= 0 { let point = NSEvent.mouseLocation; rect = .init(x: point.x, y: point.y, width: 1, height: 18) }
        self.magicFragmentsWindow.show(text: "入っていない断片: " + self.visibleMagicFragments.joined(separator: "、") + "\nTab: 足す", lineRect: rect, avoiding: self.otherIMEWindows, rawLines: true)
    }

    // MARK: - Window Management
    @MainActor func hideReplaceSuggestionCandidateView() {
        self.replaceSuggestionsUI.loaded?.window.setIsVisible(false)
        self.replaceSuggestionsUI.loaded?.window.orderOut(nil)
    }

    @MainActor func submitSelectedSuggestionCandidate() {
        self.converterServerClient.sendIfSessionOpen(
            { _ in .replaceSuggestion(.submitGenerated) },
            completion: { [weak self] response in
                Task { @MainActor in
                    guard let self, let response else {
                        return
                    }
                    self.apply(response)
                }
            }
        )
    }

    @MainActor private func finishReplaceSuggestionComposition() {
        if self.currentConverterView != nil {
            self.discardConverterServerComposition()
        }
        self.inputState = .none
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        self.refreshReplaceSuggestionWindow()
        self.refreshGhostText()
    }

    // MARK: - Helper Methods
    private func retrySuggestionRequestIfNeeded(cursorPosition: CGPoint) {
        if retryCount < maxRetries {
            retryCount += 1
            self.appendDebugMessage("再試行中... (\(retryCount)回目)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestReplaceSuggestion()
            }
        } else {
            self.appendDebugMessage("再試行上限に達しました。")
            retryCount = 0
        }
    }

}
