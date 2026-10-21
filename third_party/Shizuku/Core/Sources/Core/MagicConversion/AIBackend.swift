import Foundation

// AI Backend selection
public enum AIBackend: String, Codable, CaseIterable, Sendable {
    case foundationModels = "Foundation Models"
    case openAI = "OpenAI API"
    /// llm-ime: ConverterServer 内で動くローカル LLM。IME 本体（サンドボックス内）からは
    /// AIClient ではなく ConverterServer への XPC（`.localLLM`）で使う
    case localLLM = "Local LLM"

    public static var `default`: AIBackend {
        if #available(macOS 26.0, *) {
            let availability = FoundationModelsClientCompat.checkAvailability()
            if availability.isAvailable {
                return .foundationModels
            }
        }
        return .openAI
    }
}

// Unified AI Client that routes to the appropriate backend
public enum AIClient {
    public static func sendRequest(
        _ request: OpenAIRequest,
        backend: AIBackend,
        apiKey: String = "",
        apiEndpoint: String = "",
        logger: ((String) -> Void)? = nil
    ) async throws -> [String] {
        switch backend {
        case .foundationModels:
            return try await FoundationModelsClientCompat.sendRequest(request, logger: logger)
        case .openAI:
            return try await OpenAIClient.sendRequest(request, apiKey: apiKey, apiEndpoint: apiEndpoint, logger: logger)
        case .localLLM:
            throw LocalLLMRoutingError.mustUseConverterServer
        }
    }

    public static func sendTextTransformRequest(
        _ prompt: String,
        backend: AIBackend,
        modelName: String = "",
        apiKey: String = "",
        apiEndpoint: String = "",
        logger: ((String) -> Void)? = nil
    ) async throws -> String {
        switch backend {
        case .foundationModels:
            return try await FoundationModelsClientCompat.sendTextTransformRequest(prompt, logger: logger)
        case .openAI:
            return try await OpenAIClient.sendTextTransformRequest(
                prompt: prompt,
                modelName: modelName,
                apiKey: apiKey,
                apiEndpoint: apiEndpoint
            )
        case .localLLM:
            throw LocalLLMRoutingError.mustUseConverterServer
        }
    }
}

public enum LocalLLMRoutingError: LocalizedError {
    case mustUseConverterServer

    public var errorDescription: String? {
        "ローカル LLM は ConverterServer 経由で使います"
    }
}
