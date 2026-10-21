import Core
import Foundation
import LocalLLM

// MARK: - 直前の文の清書（llm-ime）
//
// Ctrl+Tab の三択の「言い換え」から呼ぶ（明示）か、設定でオンにしたときだけ文末で手を止めたときに 1 件出す（自動）。
// 内容の出所は本人の打った文なので、形だけを整える。数字を足した・長さが大きく変わった・差がない結果は出さない（CleanUp.accept）。
// 退けた清書（Esc）は場面の記憶に入り、同じ・近い案は同じ場面で出さない。生成は ConverterServer の外のキー処理を待たせない。

extension ConverterServer {
    /// LLM の経路で使う画面の参考資料。返信先と、query に関連する部分。参照がなければ空
    @MainActor
    func llmWindowReference(session: ConverterSession, query: String) async -> String {
        WindowContextService.shared.prepare(session.windowBinding, session: session)
        let generation = session.windowReferenceGeneration
        guard session.windowReference != nil, await WindowContextService.shared.isCurrent(session, generation: generation) else { return "" }
        return await WindowReferenceRetrieval.shared.referenceText(reference: session.windowReference, query: query)
    }

    @MainActor
    func cleanUp(text: String, before: String, automatic: Bool, session: ConverterSession) async -> ConverterLocalLLMResult {
        let scene = session.personal.scene
        let app = scene?.app ?? session.activeAppID
        session.cleanUpOffer = nil
        guard !text.isEmpty, text.count <= CleanUp.maximumLength, !PersonalPrivacy.looksSecret(text),
              !PersonalPrivacy.isExcluded(app: app ?? "") else { return .init(text: "") }
        if automatic {
            guard PersonalLearner.isEnabled, AssistanceSettings.permits(.cleanup, app: app),
                  self.automaticOfferAllowed(.cleanup, session: session, scene: scene) else { return .init(text: "") }
        } else {
            guard AssistanceSettings.permits(.cleanup, app: app, automatic: false) else { return .init(text: "") }
        }
        let aiDirected = scene?.aiDirected ?? false
        let reference = await self.llmWindowReference(session: session, query: before + text)
        do {
            let output = try await LocalLLMEngine.shared.respond(
                system: LocalLLMPrompts.transformSystem,
                user: LocalLLMPrompts.transformUserPrompt(text: text, instruction: LocalLLMPrompts.cleanUpInstruction(aiDirected: aiDirected),
                                                          before: String(before.suffix(ConverterSession.replaceSuggestionContextLength)), after: "",
                                                          reference: reference),
                modelDirectory: Self.localLLMModelDirectory,
                maxTokens: max(128, text.count * 3),
                thinking: false, usageFeature: "cleanup"
            )
            let normalized = PersonalLearner.shared.normalizedGeneratedText(output, scene: scene, route: .transform)
            guard let accepted = CleanUp.accept(original: text, result: normalized),
                  WindowReferenceGeneration.permits(accepted, draft: before + text, reference: reference),
                  !self.isDismissed(accepted, session: session, scene: scene) else { return .init(text: "") }
            if let scene { session.cleanUpOffer = (text, accepted, scene, !reference.isEmpty) }
            var result = ConverterLocalLLMResult(text: accepted)
            result.usedWindowReference = !reference.isEmpty
            return result
        } catch {
            return automatic ? .init(text: "") : .init(error: error.localizedDescription)
        }
    }

    /// AI への指示の場面で、短い確定が指す画面の選択肢の行
    @MainActor
    func windowHint(text: String, session: ConverterSession) async -> String? {
        guard let scene = session.personal.scene, scene.aiDirected, ShortReplyHint.option(in: text) != nil else { return nil }
        WindowContextService.shared.prepare(session.windowBinding, session: session)
        let generation = session.windowReferenceGeneration
        guard let reference = session.windowReference, await WindowContextService.shared.isCurrent(session, generation: generation) else { return nil }
        return ShortReplyHint.resolve(text, reference: reference)
    }
}
