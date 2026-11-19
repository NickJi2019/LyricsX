import Foundation

/// The connection a particular request uses. Business options (translation
/// language, prompts and lyric lines) deliberately do not belong here.
public struct AIConnectionSnapshot: Equatable, Sendable {
    public let endpoint: URL
    public let model: String

    public init(endpoint: URL, model: String) {
        self.endpoint = endpoint
        self.model = model
    }
}

public enum AIConnectionError: Error, Equatable {
    case invalidEndpoint
    case insecureEndpoint
    case missingModel
    case configurationTooLarge
    case invalidResponse
}

public enum AIConnectionPolicy {
    public static let defaultEndpoint = "https://api.openai.com/v1/chat/completions"
    public static let defaultModel = "gpt-4o-mini"
    private static let maximumEndpointBytes = 4_096
    private static let maximumModelBytes = 256

    public static func configuration(endpoint: String, model: String) throws -> AIConnectionSnapshot {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.utf8.count <= maximumEndpointBytes,
              model.utf8.count <= maximumModelBytes else {
            throw AIConnectionError.configurationTooLarge
        }
        let url = try validatedEndpoint(endpoint)
        guard !model.isEmpty else { throw AIConnectionError.missingModel }
        return AIConnectionSnapshot(endpoint: url, model: model)
    }

    public static func usesMaxCompletionTokens(at endpoint: URL) -> Bool {
        endpoint.host?.lowercased() == "api.openai.com"
    }

    /// A canonical origin used to bind a credential to the server that may receive it.
    /// Paths, queries, fragments, and default ports do not affect the origin.
    public static func endpointOrigin(_ endpoint: URL) -> String? {
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        let unwrappedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let serializedHost = unwrappedHost.contains(":") ? "[\(unwrappedHost)]" : unwrappedHost
        let port = components.port
        let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        if let port, !isDefaultPort {
            return "\(scheme)://\(serializedHost):\(port)"
        }
        return "\(scheme)://\(serializedHost)"
    }

    public static func validatedEndpoint(_ endpoint: String) throws -> URL {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.utf8.count <= maximumEndpointBytes else {
            throw AIConnectionError.configurationTooLarge
        }
        guard let components = URLComponents(string: endpoint),
              let url = components.url,
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw AIConnectionError.invalidEndpoint
        }

        if components.queryItems?.contains(where: {
            isCredentialQueryName($0.name)
        }) == true {
            throw AIConnectionError.invalidEndpoint
        }

        let scheme = components.scheme?.lowercased()
        if scheme != "https" {
            guard scheme == "http",
                  let host = components.host?.lowercased(),
                  isLoopbackHost(host) else {
                throw AIConnectionError.insecureEndpoint
            }
        }
        return appendingChatCompletionsPathIfBase(url)
    }

    /// Completes an endpoint that was given as a base URL.
    ///
    /// Providers document a `base_url`, and copying that out of the docs is the
    /// obvious thing to do: `https://api.deepseek.com` and
    /// `https://api.deepseek.com/v1` are both base URLs, both look finished, and
    /// both answer a request to them with a 404 that says nothing about the
    /// missing path. Nothing on this side can recover from that except the
    /// rewrite itself, so the shapes that are unambiguously a base get the
    /// chat-completions path appended.
    ///
    /// Anything else is left exactly as given. A proxy, or a provider that
    /// answers somewhere of its own choosing, is not ours to correct.
    private static func appendingChatCompletionsPathIfBase(_ url: URL) -> URL {
        let path = url.path
        guard ["", "/", "/v1", "/v1/"].contains(path),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        components.path = base + "/chat/completions"
        return components.url ?? url
    }

    /// Whether `host` names the loopback interface.
    ///
    /// The address decides, not the spelling: `URLComponents.host` keeps an
    /// IPv6 literal in its brackets, so `[::1]` never compares equal to `::1`,
    /// and the same host can also turn up pointlessly bracketed. Comparing
    /// strings gets one of those wrong either way; `[0:0:0:0:0:0:0:1]` and
    /// `[127.0.0.1]` name the same interfaces as their plain spellings.
    private static func isLoopbackHost(_ host: String) -> Bool {
        let literal = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        if literal == "localhost" {
            return true
        }

        var ipv4 = in_addr()
        if literal.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            // 127.0.0.0/8 is reserved for loopback.
            return withUnsafeBytes(of: ipv4) { $0[0] == 127 }
        }

        var ipv6 = in6_addr()
        guard literal.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: ipv6) { [UInt8]($0) }
        // `::1`
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
            return true
        }
        // `::ffff:127.0.0.1` — a v4-mapped loopback reaches the same interface.
        return bytes[0 ..< 10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
            && bytes[12] == 127
    }

    private static func isCredentialQueryName(_ name: String) -> Bool {
        let lowercaseName = name.lowercased()
        let components = lowercaseName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let compactName = components.joined()
        let credentialComponents: Set<Substring> = [
            "auth", "authorization", "bearer", "credential", "key", "password", "passwd", "secret", "sig",
            "signature", "token",
        ]
        let credentialNames: Set<String> = [
            "apikey", "accesstoken", "authtoken", "bearertoken", "clientsecret", "subscriptionkey",
        ]
        return components.contains(where: credentialComponents.contains) || credentialNames.contains(compactName)
    }

}

/// Decode the chat envelope without knowing what business-specific JSON the
/// assistant content contains. Each feature validates that content itself.
public enum AIChatResponsePolicy {
    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    public static func content(from data: Data) throws -> String {
        guard let content = try? JSONDecoder().decode(Response.self, from: data).choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIConnectionError.invalidResponse
        }
        return content
    }
}
