// Sources/PulseKit/Networking/RequestBuilder.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - RequestBuilder

/// Responsible for encoding ``RequestBody`` variants into a `URLRequest`.
/// Kept separate from `PulseClient` to honour Single Responsibility.
public final class RequestBuilder: @unchecked Sendable {

    private let encoder: JSONEncoder

    public init(encoder: JSONEncoder) {
        self.encoder = encoder
    }

    /// Mutate `urlRequest` by applying the given body encoding.
    public func apply(body: RequestBody, to request: inout URLRequest) throws {
        switch body {
        case .json(let encodable):
            let data = try encoder.encode(AnyEncodable(encodable))
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        case .formURL(let params):
            var components = URLComponents()
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        case .raw(let data, let contentType):
            request.httpBody = data
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        case .multipart(let formData):
            let (data, boundary) = try formData.encode()
            request.httpBody = data
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
    }
}

// MARK: - Type Erasure for Encodable

/// Allows encoding any `Encodable & Sendable` value without knowing the concrete type at compile time.
private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ base: Encodable) { _encode = base.encode }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

// MARK: - MultipartFormData

/// Builds `multipart/form-data` payloads for file uploads.
public struct MultipartFormData: Sendable {

    /// A single form field — text or binary.
    public struct Part: Sendable {
        public let name: String
        public let data: Data
        public let fileName: String?
        public let mimeType: String?

        public init(name: String, data: Data, fileName: String? = nil, mimeType: String? = nil) {
            self.name = name
            self.data = data
            self.fileName = fileName
            self.mimeType = mimeType
        }

        /// Convenience: create a text field.
        public static func text(_ value: String, name: String) -> Part {
            Part(name: name, data: Data(value.utf8))
        }

        /// Convenience: create a file field.
        public static func file(_ data: Data, name: String, fileName: String, mimeType: String) -> Part {
            Part(name: name, data: data, fileName: fileName, mimeType: mimeType)
        }
    }

    private var parts: [Part] = []

    public init() {}

    public mutating func append(_ part: Part) {
        parts.append(part)
    }

    /// Encode all parts and return (body data, boundary string).
    public func encode() throws -> (Data, String) {
        let boundary = "PulseKit-\(UUID().uuidString)"
        var body = Data()

        for part in parts {
            body.append("--\(boundary)\r\n".utf8Data)

            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let fileName = part.fileName {
                disposition += "; filename=\"\(fileName)\""
            }
            body.append("\(disposition)\r\n".utf8Data)

            if let mimeType = part.mimeType {
                body.append("Content-Type: \(mimeType)\r\n".utf8Data)
            }

            body.append("\r\n".utf8Data)
            body.append(part.data)
            body.append("\r\n".utf8Data)
        }

        body.append("--\(boundary)--\r\n".utf8Data)
        return (body, boundary)
    }
}

// MARK: - String Helper

private extension String {
    var utf8Data: Data { Data(self.utf8) }
}
