import Foundation

public enum AIBackend: String, CaseIterable, Sendable {
    case openAICompatible
    case appleLocal

    /// Missing or unknown values preserve the pre-provider remote default.
    public static func resolve(_ stored: String?) -> AIBackend {
        stored.flatMap(AIBackend.init(rawValue:)) ?? .openAICompatible
    }
}

public enum AIProviderConfiguration: Equatable, Sendable {
    case openAICompatible(AIConnectionSnapshot)
    case appleLocal

    public var backend: AIBackend {
        switch self {
        case .openAICompatible: return .openAICompatible
        case .appleLocal: return .appleLocal
        }
    }
}

public struct AIProviderTranslationConfiguration: Equatable, Sendable {
    public let provider: AIProviderConfiguration
    public let targetLanguage: String
    public let prompt: String

    public init(provider: AIProviderConfiguration, targetLanguage: String, prompt: String) {
        self.provider = provider
        self.targetLanguage = targetLanguage
        self.prompt = prompt
    }
}

extension AILyricsTranslationPolicy {
    public static func configuration(
        provider: AIProviderConfiguration,
        targetLanguage: String,
        prompt: String
    ) throws -> AIProviderTranslationConfiguration {
        switch provider {
        case .openAICompatible(let connection):
            let legacy = try configuration(endpoint: connection.endpoint.absoluteString, model: connection.model,
                                           targetLanguage: targetLanguage, prompt: prompt)
            return AIProviderTranslationConfiguration(
                provider: .openAICompatible(.init(endpoint: legacy.endpoint, model: legacy.model)),
                targetLanguage: legacy.targetLanguage, prompt: legacy.prompt
            )
        case .appleLocal:
            let target = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard target.utf8.count <= 128, prompt.utf8.count <= maximumPromptBytes else {
                throw AILyricsTranslationError.configurationTooLarge
            }
            guard !target.isEmpty else { throw AILyricsTranslationError.missingTargetLanguage }
            guard let target = normalizedLanguageIdentifier(target) else { throw AILyricsTranslationError.invalidTargetLanguage }
            return AIProviderTranslationConfiguration(provider: .appleLocal, targetLanguage: target, prompt: prompt)
        }
    }
}
