public enum AutomaticGenerationGate {
    /// 予約時ではなく、非同期の生成を始める瞬間のマイク状態を見る。
    /// 生成しないときも呼び出し側は通常の候補の再計算へ進める。
    @MainActor
    public static func generate<Value>(microphoneActive: () -> Bool, _ body: @MainActor () async -> Value?) async -> Value? {
        guard !microphoneActive() else { return nil }
        return await body()
    }

    /// 同じキー要求の再送でも古い灰色を返さない。変換・訂正・明示操作の結果は保つ。
    public static func response(_ cached: ConverterServerResponse, microphoneActive: Bool) -> ConverterServerResponse {
        guard microphoneActive else { return cached }
        var response = cached
        response.snapshot.nextTextCompletion = nil
        return response
    }
}
