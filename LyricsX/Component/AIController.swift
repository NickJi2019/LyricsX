import Foundation
import LyricsXFoundation

/// One chat invocation. No feature state, hidden retries or global task handle.
protocol AICompleting {
    func completeOnce(
        configuration: AIConnectionSnapshot,
        messages: [OpenAICompatibleChatRequest.Message],
        apiKey: String,
        maxTokens: Int
    ) async throws -> String
}

/// Provider-neutral entry point. Local calls never require a remote credential.
protocol AIProviderCompleting {
    func completeOnce(configuration: AIProviderConfiguration,
                      messages: [OpenAICompatibleChatRequest.Message],
                      apiKey: String?, maxTokens: Int) async throws -> String
    func completeOnce(configuration: AIProviderConfiguration,
                      messages: [OpenAICompatibleChatRequest.Message],
                      responseSchema: AIOutputSchema?,
                      apiKey: String?, maxTokens: Int) async throws -> String
}

extension AIProviderCompleting {
    /// Existing adapters keep the previous method; structured implementations
    /// override this requirement, without downcasts that could drop the schema.
    func completeOnce(configuration: AIProviderConfiguration,
                      messages: [OpenAICompatibleChatRequest.Message],
                      responseSchema: AIOutputSchema?,
                      apiKey: String?, maxTokens: Int) async throws -> String {
        try await completeOnce(configuration: configuration, messages: messages, apiKey: apiKey, maxTokens: maxTokens)
    }
}

enum AIServiceError: Error, Equatable {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case requestTooLarge
}

/// Shared routing and transport only; feature schemas and task budgets belong
/// to the caller. Every native invocation and HTTP invocation owns its session.
final class AIController: AICompleting, AIProviderCompleting {
    static let shared = AIController()
    private let localClient: any AIProviderCompleting

    init(localClient: any AIProviderCompleting = AppleLocalAIClient()) {
        self.localClient = localClient
    }

    func completeOnce(configuration: AIProviderConfiguration,
                      messages: [OpenAICompatibleChatRequest.Message],
                      apiKey: String? = nil, maxTokens: Int = OpenAICompatibleChatRequest.defaultMaxTokens) async throws -> String {
        try await completeOnce(configuration: configuration, messages: messages,
                               responseSchema: nil, apiKey: apiKey, maxTokens: maxTokens)
    }

    func completeOnce(configuration: AIProviderConfiguration,
                      messages: [OpenAICompatibleChatRequest.Message],
                      responseSchema: AIOutputSchema?,
                      apiKey: String? = nil, maxTokens: Int = OpenAICompatibleChatRequest.defaultMaxTokens) async throws -> String {
        try Task.checkCancellation()
        switch configuration {
        case .appleLocal:
            return try await localClient.completeOnce(configuration: .appleLocal, messages: messages,
                responseSchema: responseSchema, apiKey: nil, maxTokens: maxTokens)
        case .openAICompatible(let connection):
            guard let apiKey else { throw AIServiceError.invalidRequest }
            return try await completeOnce(configuration: connection, messages: messages, apiKey: apiKey, maxTokens: maxTokens)
        }
    }

    func testConnection(configuration: AIProviderConfiguration, apiKey: String? = nil) async throws {
        let content = try await completeOnce(configuration: configuration, messages: [
            .init(role: "system", content: "Return one JSON object and nothing else: {\"ok\":true}."),
            .init(role: "user", content: "Connection test."),
        ], responseSchema: .object(name: "ConnectionProbe", properties: [
            .init(name: "ok", schema: .boolean),
        ]), apiKey: apiKey, maxTokens: 512)
        struct Probe: Decodable { let ok: Bool }
        guard let data = content.data(using: .utf8),
              let probe = try? JSONDecoder().decode(Probe.self, from: data), probe.ok else {
            throw AIServiceError.invalidResponse
        }
    }

    private static let maximumRequestBytes = 2_097_152
    private static let maximumResponseBytes = 2_097_152

    private final class BoundedResponseLoader: NSObject, URLSessionDataDelegate {
        private let configuration: URLSessionConfiguration
        private let maximumResponseBytes: Int
        private let lock = NSLock()

        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var response: URLResponse?
        private var data = Data()
        private var isFinished = false

        init(configuration: URLSessionConfiguration, maximumResponseBytes: Int) {
            self.configuration = configuration
            self.maximumResponseBytes = maximumResponseBytes
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    guard !isFinished else {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    self.continuation = continuation
                    let session = URLSession(
                        configuration: configuration,
                        delegate: self,
                        delegateQueue: nil
                    )
                    let task = session.dataTask(with: request)
                    self.session = session
                    self.task = task
                    let isAlreadyCancelled = Task.isCancelled
                    lock.unlock()

                    if isAlreadyCancelled {
                        cancel()
                    } else {
                        task.resume()
                    }
                }
            }, onCancel: { [weak self] in
                self?.cancel()
            })
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // The request carries a bearer credential. Require the user to configure
            // the final endpoint instead of risking forwarding it through a redirect.
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            if response.expectedContentLength > Int64(maximumResponseBytes) {
                completionHandler(.cancel)
                finish(.failure(AIServiceError.responseTooLarge))
                return
            }

            lock.lock()
            let shouldContinue = !isFinished
            if shouldContinue {
                self.response = response
            }
            lock.unlock()
            completionHandler(shouldContinue ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive newData: Data) {
            lock.lock()
            let exceedsLimit = !isFinished && newData.count > maximumResponseBytes - data.count
            if !isFinished, !exceedsLimit {
                data.append(newData)
            }
            lock.unlock()

            if exceedsLimit {
                dataTask.cancel()
                finish(.failure(AIServiceError.responseTooLarge))
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            if let error {
                finish(.failure(error))
                return
            }

            lock.lock()
            let response = self.response
            let data = self.data
            lock.unlock()
            guard let response else {
                finish(.failure(AIServiceError.invalidResponse))
                return
            }
            finish(.success((data, response)))
        }

        private func cancel() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<(Data, URLResponse), Error>) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            let continuation = self.continuation
            let session = self.session
            self.continuation = nil
            self.session = nil
            task = nil
            lock.unlock()

            switch result {
            case .success:
                session?.finishTasksAndInvalidate()
            case .failure:
                session?.invalidateAndCancel()
            }
            continuation?.resume(with: result)
        }
    }

    func completeOnce(
        configuration: AIConnectionSnapshot,
        messages: [OpenAICompatibleChatRequest.Message],
        apiKey: String,
        maxTokens: Int = OpenAICompatibleChatRequest.defaultMaxTokens
    ) async throws -> String {
        try Task.checkCancellation()
        let validated = try AIConnectionPolicy.configuration(
            endpoint: configuration.endpoint.absoluteString,
            model: configuration.model
        )
        guard !messages.isEmpty, maxTokens > 0 else { throw AIServiceError.invalidRequest }
        let apiKey = try AICredentialStore.validatedAPIKey(apiKey)
        let payload = OpenAICompatibleChatRequest(configuration: validated, messages: messages, maxTokens: maxTokens)
        var request = URLRequest(url: validated.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body = try JSONEncoder().encode(payload)
        guard body.count <= Self.maximumRequestBytes else { throw AIServiceError.requestTooLarge }
        request.httpBody = body

        let session = URLSessionConfiguration.ephemeral
        session.requestCachePolicy = .reloadIgnoringLocalCacheData
        session.timeoutIntervalForRequest = 90
        session.timeoutIntervalForResource = 120
        let (data, response) = try await BoundedResponseLoader(
            configuration: session,
            maximumResponseBytes: Self.maximumResponseBytes
        ).data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw AIServiceError.invalidResponse }
        guard 200 ..< 300 ~= response.statusCode else { throw AIServiceError.httpStatus(response.statusCode) }
        // Keep an invalid transport response distinct from an invalid chat
        // envelope. Features may recover differently (translation splits a
        // malformed envelope, but never retries a non-HTTP response).
        return try AIChatResponsePolicy.content(from: data)
    }

    /// Tests the common JSON-mode chat contract, independently of translation.
    func testConnection(configuration: AIConnectionSnapshot, apiKey: String) async throws {
        let content = try await completeOnce(
            configuration: configuration,
            messages: [
                .init(role: "system", content: "Return one JSON object and nothing else: {\"ok\":true}."),
                .init(role: "user", content: "Connection test."),
            ],
            apiKey: apiKey,
            maxTokens: 512
        )
        struct Probe: Decodable { let ok: Bool }
        guard let data = content.data(using: .utf8),
              let probe = try? JSONDecoder().decode(Probe.self, from: data), probe.ok else {
            throw AIServiceError.invalidResponse
        }
    }

    static func failureDescription(for error: Error) -> String {
        if let error = error as? AppleLocalAIError {
            switch error {
            case .unsupportedOS: return NSLocalizedString("Apple local AI requires macOS 26 or later.", comment: "Local AI OS requirement.")
            case .unavailable(let reason): return reason
            case .contextWindowExceeded: return NSLocalizedString("The request exceeded the Apple local model's context window.", comment: "Local AI context error.")
            case .unsupportedLanguage: return NSLocalizedString("The Apple local model does not support this language or locale.", comment: "Local AI language error.")
            case .refused: return NSLocalizedString("The Apple local model declined this request.", comment: "Local AI refusal.")
            case .invalidResponse: return NSLocalizedString("The Apple local model did not return a valid JSON object.", comment: "Local AI JSON error.")
            case .generationFailed(let reason): return reason
            }
        }
        if let error = error as? AIServiceError {
            switch error {
            case .httpStatus(let status):
                return String(format: NSLocalizedString("The AI endpoint answered HTTP %d.", comment: "Shared AI connection HTTP error."), status)
            case .responseTooLarge:
                return NSLocalizedString("The AI endpoint's answer was too large to read.", comment: "Shared AI response size error.")
            case .requestTooLarge:
                return NSLocalizedString("The AI request was too large to send.", comment: "Shared AI request size error.")
            case .invalidRequest:
                return NSLocalizedString("The AI request settings are invalid.", comment: "Shared AI request validation error.")
            case .invalidResponse:
                return NSLocalizedString("The AI endpoint did not return a valid JSON-mode chat response.", comment: "Shared AI response validation error.")
            }
        }
        if let error = error as? AIConnectionError {
            switch error {
            case .missingModel: return NSLocalizedString("Enter an AI model name.", comment: "Shared AI model validation error.")
            case .invalidEndpoint, .insecureEndpoint, .configurationTooLarge:
                return NSLocalizedString("The AI connection settings are incomplete or invalid.", comment: "Shared AI connection validation error.")
            case .invalidResponse:
                return NSLocalizedString("The AI endpoint did not return a valid JSON-mode chat response.", comment: "Shared AI response validation error.")
            }
        }
        if let error = error as? AICredentialError {
            if error.isTransient {
                return NSLocalizedString("The keychain is temporarily unavailable; the AI connection can be tested later.", comment: "Shared AI temporary credential error.")
            }
            return NSLocalizedString("The saved API key could not be read or is invalid. Check the AI service settings.", comment: "Shared AI credential validation error.")
        }
        return error.localizedDescription
    }
}
