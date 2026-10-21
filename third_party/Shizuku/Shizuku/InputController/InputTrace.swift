import Core
import Foundation
import os

/// Only fixed codes and numeric metadata cross this logging boundary. Never pass user text or errors.
enum InputTrace {
    enum Stage: String {
        case initBegin = "init_begin", initialized = "init", activate, activateReturn = "activate_return", deactivate, deactivateReturn = "deactivate_return", menu, commitComposition, setValue
        case handle, handleReturn = "handle_return", queued, send, response, completionResponse = "completion_response"
        case markedCall = "marked_call", markedReturn = "marked_return"
        case insertCall = "insert_call", insertReturn = "insert_return"
        case branch, guardReturn = "guard", transport, legacy, exception
    }
    enum Reason: String {
        case none, noEvent = "no_event", noClient = "no_client", notKeyDown = "not_key_down"
        case assistanceVerb = "assistance_verb", idleVerb = "idle_verb", customPrompt = "custom_prompt"
        case languagePrompt = "language_prompt", promptVisible = "prompt_visible", backendOff = "backend_off", selectedPrompt = "selected_prompt"
        case routerApplication = "router_application", ownerReleased = "owner_released", staleActivation = "stale_activation"
        case noResponse = "no_response", delayedFallthrough = "delayed_fallthrough", staleCompletion = "stale_completion"
        case noSession = "no_session", reconnectWait = "reconnect_wait", retry, connect, interrupted, invalidated, proxyError = "proxy_error", noProxy = "no_proxy"
        case remoteError = "remote_error", noData = "no_data", encodeError = "encode_error", decodeError = "decode_error", timeout
        case objcUncaught = "objc_uncaught"
    }
    enum State: String {
        case none, attachDiacritic, composing, previewing, selecting, replaceSuggestion, unicodeInput
        init(_ state: InputState) {
            switch state {
            case .none: self = .none
            case .attachDiacritic: self = .attachDiacritic
            case .composing: self = .composing
            case .previewing: self = .previewing
            case .selecting: self = .selecting
            case .replaceSuggestion: self = .replaceSuggestion
            case .unicodeInput: self = .unicodeInput
            }
        }
    }
    private static let logger = Logger(subsystem: "dev.tomonari.inputmethod.Shizuku", category: "input")
    private static let identifiers = OSAllocatedUnfairLock(initialState: UInt64(0))
    static func allocateID() -> UInt64 { self.identifiers.withLock { $0 &+= 1; return $0 } }

    @inline(never) static func event(_ stage: Stage, controller: UInt64, request: UInt64 = 0,
                                   key: Int = -1, modifiers: UInt = 0, state: State = .none,
                                   length: Int = 0, effects: UInt64 = 0, reason: Reason = .none, number: Int = 0) {
        self.logger.notice("stage=\(stage.rawValue, privacy: .public) c=\(controller) r=\(request) key=\(key) modifiers=\(modifiers) state=\(state.rawValue, privacy: .public) length=\(length) effects=\(effects) reason=\(reason.rawValue, privacy: .public) n=\(number)")
    }

    static func requestID(_ command: ConverterSessionCommand) -> UInt64 {
        if case .handleKeyEvent(let request) = command { return request.eventID }
        return 0
    }
    static func requestID(_ command: ConverterServerCommand) -> UInt64 {
        switch command {
        case .openSession(_, let command), .session(_, let command): return self.requestID(command)
        default: return 0
        }
    }
    /// Bits are stable diagnostic codes, independent of enum payloads and Codable descriptions.
    static func effectBit(_ effect: ConverterClientEffect) -> UInt64 {
        switch effect {
        case .insertText: return 1 << 0
        case .switchInputLanguage: return 1 << 1
        case .requestPredictiveSuggestion: return 1 << 2
        case .requestReplaceSuggestion: return 1 << 3
        case .selectNextReplaceSuggestionCandidate: return 1 << 4
        case .selectPreviousReplaceSuggestionCandidate: return 1 << 5
        case .submitReplaceSuggestionCandidate: return 1 << 6
        case .hideReplaceSuggestionWindow: return 1 << 7
        case .showPromptInputWindow: return 1 << 8
        case .transformSelectedText: return 1 << 9
        case .fallthroughToApplication: return 1 << 10
        }
    }
    static func reply(_ response: ConverterServerResponse?, controller: UInt64, request: UInt64, completion: Bool = false) {
        guard let response else {
            self.event(completion ? .completionResponse : .response, controller: controller, request: request, length: -1, reason: .noResponse)
            return
        }
        let length = response.snapshot.markedText.elements.reduce(0) { $0 + $1.content.utf16.count }
        let effects = response.effects.reduce(UInt64(0)) { $0 | self.effectBit($1) }
        self.event(completion ? .completionResponse : .response, controller: controller, request: request,
                   state: State(response.inputState.inputState), length: length, effects: effects, number: response.effects.count)
    }

    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    private static var exceptionHandlerInstalled = false
    static func installExceptionHandler() {
        guard !self.exceptionHandlerInstalled else { return }
        self.exceptionHandlerInstalled = true
        self.previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // The exception reason/name can contain document text. Only log a fixed code.
            InputTrace.event(.exception, controller: 0, reason: .objcUncaught)
            InputTrace.previousExceptionHandler?(exception)
        }
    }
}
