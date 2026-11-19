import Foundation
import LyricsXFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleLocalAIStatus {
    let isAvailable: Bool
    let description: String
    let contextSize: Int?
    let supportedLanguages: [String]
}

enum AppleLocalAIError: Error, Equatable {
    case unsupportedOS
    case unavailable(String)
    case contextWindowExceeded
    case unsupportedLanguage
    case refused
    case invalidResponse
    case generationFailed(String)
}

/// Native on-device adapter only. No credential store, endpoint, HTTP or cloud
/// model is reachable from this type; each call has a separate model session.
final class AppleLocalAIClient: AIProviderCompleting {
    static func status() -> AppleLocalAIStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return AppleLocalAIStatus(isAvailable: true,
                    description: NSLocalizedString("Apple local model is available.", comment: "Local AI available status."),
                    contextSize: model.contextSize,
                    supportedLanguages: model.supportedLanguages.map(\.minimalIdentifier).sorted())
            case .unavailable(let reason):
                return AppleLocalAIStatus(isAvailable: false, description: unavailableDescription(reason),
                                         contextSize: nil, supportedLanguages: [])
            }
        }
        #endif
        return AppleLocalAIStatus(isAvailable: false,
            description: NSLocalizedString("Apple local AI requires macOS 26 or later.", comment: "Local AI OS requirement."),
            contextSize: nil, supportedLanguages: [])
    }

    func completeOnce(configuration: AIProviderConfiguration,
                      messages: [OpenAICompatibleChatRequest.Message],
                      apiKey: String? = nil, maxTokens: Int) async throws -> String {
        try await completeOnce(configuration: configuration, messages: messages,
                               responseSchema: nil, apiKey: apiKey, maxTokens: maxTokens)
    }

    func completeOnce(configuration: AIProviderConfiguration,
                      messages: [OpenAICompatibleChatRequest.Message],
                      responseSchema: AIOutputSchema?,
                      apiKey: String? = nil, maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        guard configuration == .appleLocal, !messages.isEmpty, maxTokens > 0,
              messages.allSatisfy({ ["system", "user", "assistant"].contains($0.role) }) else {
            throw AIServiceError.invalidRequest
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await generate(messages: messages, responseSchema: responseSchema, maxTokens: maxTokens)
        }
        #endif
        throw AppleLocalAIError.unsupportedOS
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func unavailableDescription(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return NSLocalizedString("This Mac does not support the Apple local model.", comment: "Local AI hardware unavailable.")
        case .appleIntelligenceNotEnabled:
            return NSLocalizedString("Enable Apple Intelligence in System Settings to use the local model.", comment: "Local AI disabled.")
        case .modelNotReady:
            return NSLocalizedString("The Apple local model is not ready. Check Apple Intelligence in System Settings.", comment: "Local AI model not ready.")
        @unknown default:
            return NSLocalizedString("The Apple local model is unavailable.", comment: "Local AI unavailable.")
        }
    }

    @available(macOS 26.0, *)
    private func dynamicSchema(_ schema: AIOutputSchema) -> DynamicGenerationSchema {
        switch schema {
        case .string: return DynamicGenerationSchema(type: String.self)
        case .integer: return DynamicGenerationSchema(type: Int.self)
        case .boolean: return DynamicGenerationSchema(type: Bool.self)
        case .array(let element, let minimumCount, let maximumCount):
            return DynamicGenerationSchema(arrayOf: dynamicSchema(element), minimumElements: minimumCount, maximumElements: maximumCount)
        case .object(let name, let properties):
            return DynamicGenerationSchema(name: name, properties: properties.map {
                .init(name: $0.name, description: $0.description, schema: dynamicSchema($0.schema), isOptional: $0.isOptional)
            })
        }
    }

    @available(macOS 26.0, *)
    private func generate(messages: [OpenAICompatibleChatRequest.Message], responseSchema: AIOutputSchema?, maxTokens: Int) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw AppleLocalAIError.unavailable(Self.status().description)
        }
        let instructionText = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
            + "\n\nReturn exactly one valid JSON object. Do not use Markdown fences or text outside that object."
        let prompt = messages.filter { $0.role != "system" }.map {
            $0.role == "user" ? $0.content : "Assistant context:\n" + $0.content
        }.joined(separator: "\n\n")
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIServiceError.invalidRequest }
        // Reserve room for the system instructions, prompt, schema-free JSON
        // and session overhead rather than assuming a fixed device context.
        let context = model.contextSize
        let responseLimit = min(maxTokens, max(1, context / 2))
        do {
            let instructions = Instructions(instructionText)
            let schema = try responseSchema.map { try GenerationSchema(root: dynamicSchema($0), dependencies: []) }
            if #available(macOS 26.4, *) {
                var used = try await model.tokenCount(for: instructions) + model.tokenCount(for: Prompt(prompt))
                if let schema { used += try await model.tokenCount(for: schema) }
                guard used + responseLimit + 64 <= context else { throw AppleLocalAIError.contextWindowExceeded }
            }
            try Task.checkCancellation()
            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(maximumResponseTokens: responseLimit)
            let raw: String
            if let schema {
                // Guided decoding guarantees the requested shape without a
                // business-specific type or string-repair path in this adapter.
                raw = try await session.respond(to: prompt, schema: schema, options: options).content.jsonString
            } else {
                raw = try await session.respond(to: prompt, options: options).content
            }
            try Task.checkCancellation()
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = content.data(using: .utf8), data.count <= 2_097_152,
                  let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
                throw AppleLocalAIError.invalidResponse
            }
            return content
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleLocalAIError {
            throw error
        } catch {
            try Task.checkCancellation()
            if #available(macOS 27.0, *), let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: throw AppleLocalAIError.contextWindowExceeded
                case .unsupportedLanguageOrLocale: throw AppleLocalAIError.unsupportedLanguage
                case .refusal, .guardrailViolation: throw AppleLocalAIError.refused
                default: throw AppleLocalAIError.generationFailed(error.localizedDescription)
                }
            }
            if let error = error as? LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize: throw AppleLocalAIError.contextWindowExceeded
                case .unsupportedLanguageOrLocale: throw AppleLocalAIError.unsupportedLanguage
                case .refusal, .guardrailViolation: throw AppleLocalAIError.refused
                case .assetsUnavailable: throw AppleLocalAIError.unavailable(Self.status().description)
                default: throw AppleLocalAIError.generationFailed(error.localizedDescription)
                }
            }
            throw AppleLocalAIError.generationFailed(error.localizedDescription)
        }
    }
    #endif
}
