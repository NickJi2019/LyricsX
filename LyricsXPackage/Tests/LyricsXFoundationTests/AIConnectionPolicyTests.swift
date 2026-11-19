import Foundation
import Testing
@testable import LyricsXFoundation

@Test
func sharedAIConnectionIsIndependentOfTranslationOptions() throws {
    let connection = try AIConnectionPolicy.configuration(endpoint: " https://example.com/v1 ", model: " test-model ")
    #expect(connection.endpoint.absoluteString == "https://example.com/v1/chat/completions")
    #expect(connection.model == "test-model")
}

@Test
func sharedAIConnectionKeepsEndpointValidationAndOriginBinding() throws {
    #expect(throws: AIConnectionError.insecureEndpoint) {
        try AIConnectionPolicy.configuration(endpoint: "http://example.com", model: "test")
    }
    #expect(throws: AIConnectionError.invalidEndpoint) {
        try AIConnectionPolicy.configuration(endpoint: "https://example.com/v1?api_key=not-a-real-key", model: "test")
    }
    #expect(throws: AIConnectionError.missingModel) {
        try AIConnectionPolicy.configuration(endpoint: "https://example.com", model: "  ")
    }
    let local = try AIConnectionPolicy.configuration(endpoint: "http://127.0.0.1:12345/v1", model: "local")
    #expect(local.endpoint.absoluteString == "http://127.0.0.1:12345/v1/chat/completions")
    #expect(AIConnectionPolicy.endpointOrigin(URL(string: "https://EXAMPLE.com:443/v1/chat/completions")!) == "https://example.com")
}

@Test
func sharedAIRequestAcceptsNonTranslationMessages() throws {
    let connection = try AIConnectionPolicy.configuration(endpoint: "https://example.com/v1", model: "classify")
    let messages = [OpenAICompatibleChatRequest.Message(role: "system", content: "Return JSON."),
                    .init(role: "user", content: "A generic connection probe, not lyrics.")]
    let request = OpenAICompatibleChatRequest(configuration: connection, messages: messages, maxTokens: 128)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(json["model"] as? String == "classify")
    #expect(json["max_tokens"] as? Int == 128)
    #expect(json["max_completion_tokens"] == nil)
    #expect((json["response_format"] as? [String: String])?["type"] == "json_object")
    #expect((json["messages"] as? [[String: String]]) == messages.map { ["role": $0.role, "content": $0.content] })
}

@Test
func sharedAIRequestKeepsOpenAITokenParameter() throws {
    let connection = try AIConnectionPolicy.configuration(endpoint: "https://api.openai.com/v1", model: "test")
    let request = OpenAICompatibleChatRequest(configuration: connection, messages: [.init(role: "user", content: "JSON")], maxTokens: 64)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(json["max_completion_tokens"] as? Int == 64)
    #expect(json["max_tokens"] == nil)
}

@Test
func sharedAITranslationAdapterKeepsItsWireContract() throws {
    let configuration = try AILyricsTranslationPolicy.configuration(
        endpoint: "https://example.com/v1", model: "test", targetLanguage: "zh-Hans", prompt: "Use $targetLanguage."
    )
    let lines = [AILyricsTranslationInputLine(index: 3, text: "A source line")]
    let oldEntry = try OpenAICompatibleChatRequest(configuration: configuration, sourceLanguage: "en", sourceLines: lines, maxTokens: 256)
    let commonEntry = OpenAICompatibleChatRequest(
        configuration: .init(endpoint: configuration.endpoint, model: configuration.model),
        messages: [.init(role: "system", content: AILyricsTranslationPolicy.systemPrompt),
                   .init(role: "user", content: try AILyricsTranslationPolicy.userMessage(
                       prompt: configuration.prompt, sourceLanguage: "en", targetLanguage: configuration.targetLanguage, sourceLines: lines
                   ))], maxTokens: 256
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try encoder.encode(oldEntry) == encoder.encode(commonEntry))
}
