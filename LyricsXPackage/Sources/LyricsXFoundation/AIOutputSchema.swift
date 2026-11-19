import Foundation

/// Provider-neutral output shape. Features own the property names and business
/// contract; adapters translate this description into their native constraints.
public indirect enum AIOutputSchema: Equatable, Sendable {
    case string
    case integer
    case boolean
    case array(element: AIOutputSchema, minimumCount: Int? = nil, maximumCount: Int? = nil)
    case object(name: String, properties: [AIOutputProperty])
}

public struct AIOutputProperty: Equatable, Sendable {
    public let name: String
    public let schema: AIOutputSchema
    public let description: String?
    public let isOptional: Bool

    public init(name: String, schema: AIOutputSchema, description: String? = nil, isOptional: Bool = false) {
        self.name = name
        self.schema = schema
        self.description = description
        self.isOptional = isOptional
    }
}
