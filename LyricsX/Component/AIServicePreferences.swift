import Foundation
import GenericID
import LyricsXFoundation

extension UserDefaults {
    /// No stored choice means the existing remote provider; do not migrate or
    /// auto-select a local model merely because this Mac supports one.
    var aiBackend: AIBackend {
        get { AIBackend.resolve(self[.aiBackend]) }
        set { self[.aiBackend] = newValue.rawValue }
    }

    var aiProviderConfiguration: AIProviderConfiguration {
        get throws {
            switch aiBackend {
            case .openAICompatible: return .openAICompatible(try aiConnectionConfiguration)
            case .appleLocal: return .appleLocal
            }
        }
    }
    /// Legacy endpoint/model keys remain the backing store, not a migration.
    var aiConnectionConfiguration: AIConnectionSnapshot {
        get throws {
            try AIConnectionPolicy.configuration(
                endpoint: self[.aiLyricsTranslationEndpoint],
                model: self[.aiLyricsTranslationModel]
            )
        }
    }
}

extension AIController {
    /// Capture once for a job; changing preferences does not mutate that job's
    /// already captured endpoint or model.
    var configuration: AIConnectionSnapshot {
        get throws { try defaults.aiConnectionConfiguration }
    }
}

extension AIController {
    var providerConfiguration: AIProviderConfiguration {
        get throws { try defaults.aiProviderConfiguration }
    }
}
