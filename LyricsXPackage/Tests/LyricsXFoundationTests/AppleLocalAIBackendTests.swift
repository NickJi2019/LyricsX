import Foundation
import Testing
@testable import LyricsXFoundation

@Suite
struct AppleLocalAIBackendTests {
    @Test
    func appleLocalProviderNeedsNoRemoteConnectionConfiguration() {
        let local = AIProviderConfiguration.appleLocal
        #expect(local.backend == .appleLocal)
        if case .openAICompatible = local {
            Issue.record("Apple local configuration unexpectedly carries a remote connection")
        }
    }

    @Test
    func selectingAppleLocalKeepsTheExistingRemoteSnapshotIntact() {
        let connection = AIConnectionSnapshot(
            endpoint: URL(string: "https://example.invalid/v1/chat/completions")!,
            model: "previously-configured-model"
        )
        let oldRequest = AIProviderConfiguration.openAICompatible(connection)
        var selection = oldRequest
        selection = .appleLocal
        #expect(selection.backend == .appleLocal)
        #expect(oldRequest.backend == .openAICompatible)
        if case .openAICompatible(let retained) = oldRequest {
            #expect(retained == connection)
            #expect(retained.model == "previously-configured-model")
        } else {
            Issue.record("Selecting local changed an immutable remote request snapshot")
        }
    }

    @Test
    func localTranslationBusinessOptionsStayIndependentOfConnectionFields() throws {
        let request = try AILyricsTranslationPolicy.configuration(
            provider: .appleLocal,
            targetLanguage: "ja",
            prompt: "Preserve the original tone when translating into $targetLanguage."
        )
        #expect(request.provider.backend == .appleLocal)
        #expect(request.targetLanguage == "ja")
        #expect(request.prompt == "Preserve the original tone when translating into $targetLanguage.")
    }

    @Test
    func localTranslationValidatesLanguageWithoutDemandingEndpointOrModel() throws {
        let request = try AILyricsTranslationPolicy.configuration(
            provider: .appleLocal, targetLanguage: "zh_hant", prompt: "Synthetic prompt"
        )
        #expect(request.targetLanguage == "zh-Hant")
        #expect(throws: AILyricsTranslationError.invalidTargetLanguage) {
            try AILyricsTranslationPolicy.configuration(
                provider: .appleLocal, targetLanguage: "not a language", prompt: "Synthetic prompt"
            )
        }
    }

    @Test
    func localAndRemoteRequestsKeepSeparateProviderIdentities() throws {
        let connection = try AIConnectionPolicy.configuration(endpoint: "https://example.invalid/v1", model: "remote")
        let local = try AILyricsTranslationPolicy.configuration(provider: .appleLocal, targetLanguage: "ja", prompt: "Synthetic")
        let remote = try AILyricsTranslationPolicy.configuration(
            provider: .openAICompatible(connection), targetLanguage: "ja", prompt: "Synthetic"
        )
        #expect(local.provider.backend == .appleLocal)
        #expect(remote.provider.backend == .openAICompatible)
        if case .openAICompatible(let actual) = remote.provider {
            #expect(actual == connection)
        } else {
            Issue.record("Remote provider lost its endpoint and model")
        }
    }

    @Test
    func oldRemoteTranslationConfigurationStillUsesItsOriginalFields() throws {
        let request = try AILyricsTranslationPolicy.configuration(
            endpoint: "https://example.invalid/v1", model: "legacy-remote-model",
            targetLanguage: "ja", prompt: "Original translation prompt"
        )
        #expect(request.endpoint.absoluteString == "https://example.invalid/v1/chat/completions")
        #expect(request.model == "legacy-remote-model")
        #expect(request.targetLanguage == "ja")
        #expect(request.prompt == "Original translation prompt")
    }

    @Test(arguments: [String?](arrayLiteral: nil, "", "unknown-future-backend"))
    func appleLocalBackendPreservesRemoteDefaultForOldOrUnknownSettings(_ stored: String?) {
        #expect(AIBackend.resolve(stored) == .openAICompatible)
    }

    @Test(arguments: AIBackend.allCases)
    func appleLocalBackendSelectionRoundTripsWithoutChangingOtherSettings(_ backend: AIBackend) {
        #expect(AIBackend.resolve(backend.rawValue) == backend)
    }

    @Test
    func appleLocalCanBeConfiguredEvenWhenPreviousRemoteFieldsWereIncomplete() throws {
        let previousRemote = AIConnectionSnapshot(endpoint: URL(string: "http://example.invalid")!, model: "")
        let local = try AILyricsTranslationPolicy.configuration(provider: .appleLocal, targetLanguage: "ja", prompt: "Synthetic")
        #expect(local.provider == .appleLocal)
        #expect(previousRemote.model.isEmpty)
        #expect(previousRemote.endpoint.absoluteString == "http://example.invalid")
        #expect(throws: AIConnectionError.insecureEndpoint) {
            try AIConnectionPolicy.configuration(endpoint: previousRemote.endpoint.absoluteString, model: "valid-model")
        }
    }

    @Test
    func appleLocalStillRejectsEmptyOrOversizedBusinessConfiguration() {
        #expect(throws: AILyricsTranslationError.missingTargetLanguage) {
            try AILyricsTranslationPolicy.configuration(provider: .appleLocal, targetLanguage: " ", prompt: "Synthetic")
        }
        #expect(throws: AILyricsTranslationError.configurationTooLarge) {
            try AILyricsTranslationPolicy.configuration(provider: .appleLocal, targetLanguage: "ja", prompt: String(repeating: "X", count: 32_769))
        }
    }

    @Test
    func localOutputSchemaDescribesArbitraryBusinessFieldsWithoutTranslationCoupling() {
        let fields = [AIOutputProperty(name: "ok", schema: .boolean),
                      AIOutputProperty(name: "count", schema: .integer),
                      AIOutputProperty(name: "detail", schema: .string, description: "Synthetic detail", isOptional: true)]
        let schema = AIOutputSchema.object(name: "SyntheticBusinessResult", properties: fields)
        if case .object(let name, let properties) = schema {
            #expect(name == "SyntheticBusinessResult")
            #expect(properties == fields)
            #expect(properties[0].isOptional == false)
            #expect(properties[2].isOptional)
            #expect(properties[2].description == "Synthetic detail")
        } else {
            Issue.record("An object schema lost its business-owned fields")
        }
    }

    @Test
    func localOutputArraySchemaKeepsNestedShapeAndBounds() {
        let row = AIOutputSchema.object(name: "SyntheticRow", properties: [
            .init(name: "number", schema: .integer), .init(name: "value", schema: .string),
        ])
        let schema = AIOutputSchema.array(element: row, minimumCount: 1, maximumCount: 4)
        if case .array(let element, let minimum, let maximum) = schema {
            #expect(element == row)
            #expect(minimum == 1)
            #expect(maximum == 4)
        } else {
            Issue.record("An array schema lost its nested shape")
        }
        #expect(AIOutputSchema.string != .integer)
        #expect(AIOutputSchema.integer != .boolean)
    }

    @Test
    func localOutputSchemaSnapshotDoesNotMutateRemoteConnectionOrBusinessOptions() throws {
        let remote = AIConnectionSnapshot(endpoint: URL(string: "https://example.invalid/v1/chat/completions")!, model: "unchanged")
        let request = try AILyricsTranslationPolicy.configuration(provider: .appleLocal, targetLanguage: "ja", prompt: "Unchanged prompt")
        let original = AIOutputSchema.object(name: "First", properties: [.init(name: "value", schema: .string)])
        var edited = original
        edited = .object(name: "Second", properties: [.init(name: "ok", schema: .boolean)])
        #expect(edited != original)
        #expect(remote.model == "unchanged")
        #expect(request.provider == .appleLocal)
        #expect(request.targetLanguage == "ja")
        #expect(request.prompt == "Unchanged prompt")
    }
}
