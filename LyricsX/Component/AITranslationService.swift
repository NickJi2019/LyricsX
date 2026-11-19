import Foundation
import LyricsXFoundation

enum OpenAICompatibleLyricsTranslatorError: Error {
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    /// The track used up its requests before every line was answered.
    case requestLimitReached
}

struct AILyricsTranslationResult {
    /// Line index → translated text, for every line the endpoint answered.
    /// Returned as data rather than as a merged `Lyrics` so the caller applies
    /// it to the lyrics on screen when the answer lands, instead of replacing
    /// them with a snapshot taken before the request went out.
    let translations: [Int: String]
    /// Lines that never came back: dropped for size, or unanswered after every retry.
    let failedLineCount: Int
    /// Why lines failed, as the last of them ended: what their final request
    /// came back with, or `requestLimitReached`. Nil when every line came back.
    let failure: Error?
}

final class OpenAICompatibleLyricsTranslator {
    private static let maximumAttempts = 3
    /// The requests one track may make, per batch: enough to retry a batch
    /// twice or split it once, and the bound on what an endpoint that keeps
    /// answering with something unusable can cost. Unbounded, splitting and
    /// retrying one such batch of 24 lines came to about 95 requests.
    private static let requestsPerBatch = 3

    /// The requests a track has left, shared by its batches and by the halves
    /// a batch is split into.
    private final class RequestBudget {
        var remainingRequests: Int

        init(remainingRequests: Int) {
            self.remainingRequests = remainingRequests
        }
    }
    /// Enough for a one-line answer plus whatever a reasoning model spends
    /// before it: the probe now has to come back as parseable JSON with the
    /// translation in it, so a cap tight enough to truncate would report a
    /// working endpoint as broken.
    private static let connectionTestMaxTokens = 512
    private static let connectionTestLineIndex = 0
    private static let connectionTestLineText = "Connection test."

    // This schema belongs to translation, not to the shared controller or native adapter.
    private static let responseSchema: AIOutputSchema = .object(name: "LyricTranslationResponse", properties: [
        .init(name: "translations", schema: .array(element: .object(name: "LyricTranslation", properties: [
            .init(name: "index", schema: .integer),
            .init(name: "text", schema: .string),
        ]))),
    ])

    private let aiClient: any AICompleting
    private let providerClient: any AIProviderCompleting

    init(aiClient: any AICompleting = AIController.shared,
         providerClient: any AIProviderCompleting = AIController.shared) {
        self.aiClient = aiClient
        self.providerClient = providerClient
    }

    func translate(
        lyrics: Lyrics,
        configuration: AILyricsTranslationConfiguration,
        apiKey: String
    ) async throws -> AILyricsTranslationResult {
        try await translate(lyrics: lyrics, configuration: AIProviderTranslationConfiguration(
            provider: .openAICompatible(.init(endpoint: configuration.endpoint, model: configuration.model)),
            targetLanguage: configuration.targetLanguage, prompt: configuration.prompt
        ), apiKey: apiKey)
    }

    func translate(
        lyrics: Lyrics,
        configuration: AIProviderTranslationConfiguration,
        apiKey: String? = nil
    ) async throws -> AILyricsTranslationResult {
        let sourceLines = AILyricsTranslationPolicy.translationInputLines(
            lyrics: lyrics,
            targetLanguage: configuration.targetLanguage
        )
        guard !sourceLines.isEmpty else {
            return AILyricsTranslationResult(translations: [:], failedLineCount: 0, failure: nil)
        }

        let batches = try AILyricsTranslationBatchPolicy.batches(sourceLines)
        let sourceLanguage = lyrics.metadata.language
        let budget = RequestBudget(remainingRequests: batches.count * Self.requestsPerBatch)
        var translations: [Int: String] = [:]
        // The policy drops any line too large to batch on its own. Those never
        // reach a request, so nothing further down would report them — without
        // this they would be silently missing from the failure count too.
        var failedLineCount = sourceLines.count - batches.reduce(0) { $0 + $1.count }
        var failure: Error? = failedLineCount > 0 ? AILyricsTranslationError.lyricsTooLarge : nil
        for batch in batches {
            try Task.checkCancellation()
            let result = try await translateBatch(
                batch,
                configuration: configuration,
                sourceLanguage: sourceLanguage,
                apiKey: apiKey,
                budget: budget
            )
            translations.merge(result.translations) { _, new in new }
            failedLineCount += result.failedIndices.count
            failure = result.failure ?? failure
        }
        return AILyricsTranslationResult(
            translations: translations,
            failedLineCount: failedLineCount,
            failure: failure
        )
    }

    private func translateBatch(
        _ lines: [AILyricsTranslationInputLine],
        configuration: AIProviderTranslationConfiguration,
        sourceLanguage: String?,
        apiKey: String?,
        budget: RequestBudget
    ) async throws -> (translations: [Int: String], failedIndices: [Int], failure: Error?) {
        var remaining = lines
        var translations: [Int: String] = [:]
        var lastFailure: Error?

        for attempt in 0 ..< Self.maximumAttempts where !remaining.isEmpty {
            try Task.checkCancellation()
            guard budget.remainingRequests > 0 else {
                return (
                    translations,
                    remaining.map(\.index),
                    OpenAICompatibleLyricsTranslatorError.requestLimitReached
                )
            }
            budget.remainingRequests -= 1
            do {
                let messages = try translationMessages(configuration: configuration,
                    sourceLanguage: sourceLanguage, sourceLines: remaining)
                let content = try await complete(messages: messages, configuration: configuration,
                    apiKey: apiKey, maxTokens: OpenAICompatibleChatRequest.defaultMaxTokens)
                let parsed = try AILyricsTranslationPolicy.parsedTranslations(
                    response: content,
                    expectedLines: remaining
                )
                translations.merge(parsed.translations) { _, new in new }
                remaining = remaining.filter { parsed.missingIndices.contains($0.index) }
                // An answer that left lines out did not translate them.
                lastFailure = remaining.isEmpty ? nil : AILyricsTranslationError.invalidResponse
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastFailure = error
                if shouldSplit(error), remaining.count > 1 {
                    let midpoint = remaining.count / 2
                    let first = try await translateBatch(
                        Array(remaining[..<midpoint]),
                        configuration: configuration,
                        sourceLanguage: sourceLanguage,
                        apiKey: apiKey,
                        budget: budget
                    )
                    let second = try await translateBatch(
                        Array(remaining[midpoint...]),
                        configuration: configuration,
                        sourceLanguage: sourceLanguage,
                        apiKey: apiKey,
                        budget: budget
                    )
                    return (
                        translations
                            .merging(first.translations) { _, new in new }
                            .merging(second.translations) { _, new in new },
                        first.failedIndices + second.failedIndices,
                        second.failure ?? first.failure
                    )
                }

                guard attempt + 1 < Self.maximumAttempts, shouldRetry(error) else {
                    return (translations, remaining.map(\.index), error)
                }
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 1_000_000_000))
            }
        }

        return (translations, remaining.map(\.index), lastFailure)
    }

    private func shouldSplit(_ error: Error) -> Bool {
        if let error = error as? OpenAICompatibleLyricsTranslatorError {
            switch error {
            case .responseTooLarge, .httpStatus(413):
                return true
            case .invalidResponse, .httpStatus(_), .requestLimitReached:
                return false
            }
        }
        guard let error = error as? AILyricsTranslationError else { return false }
        return error == .invalidResponse || error == .lyricsTooLarge
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let error = error as? OpenAICompatibleLyricsTranslatorError {
            switch error {
            case .httpStatus(let status):
                return status == 429 || (500 ..< 600).contains(status)
            case .invalidResponse, .responseTooLarge, .requestLimitReached:
                return false
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if let error = error as? AILyricsTranslationError {
            return error == .invalidResponse
        }
        return false
    }

    /// Sends the same request shape the translator sends, with the small token
    /// cap below so a "Save and Test" stays cheap, and requires a usable
    /// translation back for the one line it asked about.
    ///
    /// Settling for a non-empty body is not enough: an endpoint that ignores
    /// `response_format: json_object` answers with prose, passes that check,
    /// and then fails every real request behind a green "Connection succeeded."
    func testConnection(configuration: AILyricsTranslationConfiguration, apiKey: String) async throws {
        try await testConnection(configuration: AIProviderTranslationConfiguration(
            provider: .openAICompatible(.init(endpoint: configuration.endpoint, model: configuration.model)),
            targetLanguage: configuration.targetLanguage, prompt: configuration.prompt
        ), apiKey: apiKey)
    }

    func testConnection(configuration: AIProviderTranslationConfiguration, apiKey: String? = nil) async throws {
        let probeLine = AILyricsTranslationInputLine(index: Self.connectionTestLineIndex, text: Self.connectionTestLineText)
        let messages = try translationMessages(configuration: configuration, sourceLanguage: nil, sourceLines: [probeLine])
        let content: String
        do {
            content = try await complete(messages: messages, configuration: configuration,
                                         apiKey: apiKey, maxTokens: Self.connectionTestMaxTokens)
        } catch AILyricsTranslationError.invalidResponse {
            throw OpenAICompatibleLyricsTranslatorError.invalidResponse
        }
        let parsed = try AILyricsTranslationPolicy.parsedTranslations(response: content, expectedLines: [probeLine])
        guard !parsed.missingIndices.contains(probeLine.index) else {
            throw OpenAICompatibleLyricsTranslatorError.invalidResponse
        }
    }

    private func translationMessages(configuration: AIProviderTranslationConfiguration,
                                     sourceLanguage: String?, sourceLines: [AILyricsTranslationInputLine]) throws
        -> [OpenAICompatibleChatRequest.Message] {
        [
            .init(role: "system", content: AILyricsTranslationPolicy.systemPrompt),
            .init(role: "user", content: try AILyricsTranslationPolicy.userMessage(
                prompt: configuration.prompt, sourceLanguage: sourceLanguage,
                targetLanguage: configuration.targetLanguage, sourceLines: sourceLines)),
        ]
    }

    private func complete(
        messages: [OpenAICompatibleChatRequest.Message],
        configuration: AIProviderTranslationConfiguration,
        apiKey: String?, maxTokens: Int
    ) async throws -> String {
        do {
            switch configuration.provider {
            case .openAICompatible(let connection):
                guard let apiKey else { throw AIServiceError.invalidRequest }
                return try await aiClient.completeOnce(configuration: connection, messages: messages,
                                                        apiKey: apiKey, maxTokens: maxTokens)
            case .appleLocal:
                return try await providerClient.completeOnce(configuration: .appleLocal, messages: messages,
                    responseSchema: Self.responseSchema, apiKey: nil, maxTokens: maxTokens)
            }
        } catch AppleLocalAIError.contextWindowExceeded {
            // Context overflow is the one native error the existing bounded
            // batch splitter can recover from. Other native errors are terminal.
            throw AILyricsTranslationError.lyricsTooLarge
        } catch let error as AIServiceError {
            switch error {
            case .httpStatus(let status): throw OpenAICompatibleLyricsTranslatorError.httpStatus(status)
            case .responseTooLarge: throw OpenAICompatibleLyricsTranslatorError.responseTooLarge
            case .requestTooLarge: throw AILyricsTranslationError.lyricsTooLarge
            case .invalidRequest, .invalidResponse: throw OpenAICompatibleLyricsTranslatorError.invalidResponse
            }
        } catch let error as AIConnectionError {
            switch error {
            case .invalidEndpoint: throw AILyricsTranslationError.invalidEndpoint
            case .insecureEndpoint: throw AILyricsTranslationError.insecureEndpoint
            case .missingModel: throw AILyricsTranslationError.missingModel
            case .configurationTooLarge: throw AILyricsTranslationError.configurationTooLarge
            case .invalidResponse: throw AILyricsTranslationError.invalidResponse
            }
        }
    }

}

extension OpenAICompatibleLyricsTranslator {
    /// Says what failed, for the Lab pane's status line, after a connection
    /// test or a translation. One generic sentence sent the user hunting
    /// through three settings when the endpoint had answered 401.
    static func failureDescription(for error: Error) -> String {
        if error is AppleLocalAIError { return AIController.failureDescription(for: error) }
        let noTranslationDescription = NSLocalizedString(
            "The endpoint did not answer with a translation. It may not support JSON mode.",
            comment: "Status shown when the AI translation endpoint gives a well-formed HTTP answer that is not a translation."
        )
        if let error = error as? OpenAICompatibleLyricsTranslatorError {
            switch error {
            case .httpStatus(let status):
                return String(
                    format: NSLocalizedString(
                        "The endpoint answered HTTP %d.",
                        comment: "Status shown when the AI translation endpoint test gets a non-2xx answer; %d is the HTTP status code."
                    ),
                    status
                )
            case .responseTooLarge:
                return NSLocalizedString(
                    "The endpoint's answer was too large to read.",
                    comment: "Status shown when the AI translation endpoint test gets an oversized answer."
                )
            case .invalidResponse:
                return noTranslationDescription
            case .requestLimitReached:
                return NSLocalizedString(
                    "Stopped after too many requests for this song.",
                    comment: "Status shown when AI translation used up the requests one song may make before every line was answered."
                )
            }
        }
        if let error = error as? AILyricsTranslationError {
            switch error {
            case .invalidResponse:
                return noTranslationDescription
            case .lyricsTooLarge:
                return NSLocalizedString(
                    "A lyric line is too long to send.",
                    comment: "Status shown when a lyric line is too long for an AI translation request."
                )
            case .invalidEndpoint,
                 .insecureEndpoint,
                 .missingModel,
                 .missingTargetLanguage,
                 .invalidTargetLanguage,
                 .configurationTooLarge:
                return NSLocalizedString(
                    "AI translation settings are incomplete or invalid.",
                    comment: "Status for AI lyric translation when its configuration is invalid."
                )
            }
        }
        if let error = error as? URLError {
            return String(
                format: NSLocalizedString(
                    "The request failed: %@",
                    comment: "Status shown when the AI translation endpoint test fails at the network layer; %@ is the system's description."
                ),
                error.localizedDescription
            )
        }
        return error.localizedDescription
    }
}
