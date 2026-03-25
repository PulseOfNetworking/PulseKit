// Sources/PulseKit/GraphQL/GraphQLClient.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - GraphQLRequest

/// A typed GraphQL operation that conforms to ``RequestBody`` encoding.
public struct GraphQLOperation: Sendable {
    public let query: String
    public let operationName: String?
    public let variables: [String: GraphQLVariable]?

    public init(
        query: String,
        operationName: String? = nil,
        variables: [String: GraphQLVariable]? = nil
    ) {
        self.query = query
        self.operationName = operationName
        self.variables = variables
    }

    // MARK: Convenience constructors

    public static func query(_ gql: String, variables: [String: GraphQLVariable]? = nil) -> GraphQLOperation {
        GraphQLOperation(query: gql, variables: variables)
    }

    public static func mutation(_ gql: String, variables: [String: GraphQLVariable]? = nil) -> GraphQLOperation {
        GraphQLOperation(query: gql, variables: variables)
    }
}

// MARK: - GraphQLVariable

/// Type-erased container for GraphQL variable values.
public enum GraphQLVariable: Encodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v):  try container.encode(v)
        case .int(let v):     try container.encode(v)
        case .double(let v):  try container.encode(v)
        case .bool(let v):    try container.encode(v)
        case .null:           try container.encodeNil()
        }
    }
}

// MARK: - GraphQL Response Envelope

/// Standard GraphQL `{ data, errors }` response envelope.
public struct GraphQLResponse<T: Decodable>: Decodable {
    public let data: T?
    public let errors: [GraphQLError]?

    /// `true` if the response has no errors and contains data.
    public var isSuccess: Bool { errors == nil && data != nil }
}

public struct GraphQLError: Decodable, Sendable {
    public let message: String
    public let locations: [GraphQLLocation]?
    public let path: [String]?
    public let extensions: [String: String]?
}

public struct GraphQLLocation: Decodable, Sendable {
    public let line: Int
    public let column: Int
}

// MARK: - GraphQLClient

/// A thin convenience wrapper over ``PulseClient`` that handles the
/// GraphQL HTTP transport convention (POST to `/graphql`, envelope decoding).
///
/// ```swift
/// let gql = GraphQLClient(base: pulseClient, endpoint: "/graphql")
///
/// let result: UserQueryData = try await gql.execute(
///     .query("""
///         query GetUser($id: ID!) {
///           user(id: $id) { id name email }
///         }
///     """, variables: ["id": .string("42")])
/// )
/// ```
public final class GraphQLClient: @unchecked Sendable {

    private let base: PulseClient
    private let endpoint: String
    private let encoder: JSONEncoder

    public init(base: PulseClient, endpoint: String = "/graphql") {
        self.base = base
        self.endpoint = endpoint
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = enc
    }

    // MARK: - Execute

    /// Execute a GraphQL operation and decode `data` into `T`.
    /// Throws ``GraphQLClientError/graphqlErrors`` if the response contains errors.
    public func execute<T: Decodable>(_ operation: GraphQLOperation) async throws -> T {
        let body = try buildBody(for: operation)
        let request = PulseRequest(
            baseURL: base.baseURL,
            path: endpoint,
            method: .post,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: .raw(body, contentType: "application/json")
        )

        let envelope: GraphQLResponse<T> = try await base.send(request)

        if let errors = envelope.errors, !errors.isEmpty {
            throw GraphQLClientError.graphqlErrors(errors)
        }
        guard let data = envelope.data else {
            throw GraphQLClientError.emptyData
        }
        return data
    }

    // MARK: - Body Construction

    private func buildBody(for operation: GraphQLOperation) throws -> Data {
        struct Payload: Encodable {
            let query: String
            let operationName: String?
            let variables: [String: GraphQLVariable]?
        }
        let payload = Payload(
            query: operation.query,
            operationName: operation.operationName,
            variables: operation.variables
        )
        return try encoder.encode(payload)
    }
}

// MARK: - GraphQLClientError

public enum GraphQLClientError: LocalizedError {
    case graphqlErrors([GraphQLError])
    case emptyData

    public var errorDescription: String? {
        switch self {
        case .graphqlErrors(let errors):
            return "GraphQL errors: " + errors.map(\.message).joined(separator: "; ")
        case .emptyData:
            return "GraphQL response contained no data."
        }
    }
}
