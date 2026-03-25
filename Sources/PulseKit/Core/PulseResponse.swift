// Sources/PulseKit/Core/PulseResponse.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - PulseResponse

/// Encapsulates a raw HTTP response from the network layer.
/// Plugins and callers can inspect this before or instead of decoding.
public struct PulseResponse: Sendable {

    // MARK: Properties

    /// The original request that produced this response.
    public let request: PulseRequest

    /// Raw response body bytes.
    public let data: Data

    /// The underlying `HTTPURLResponse`.
    public let urlResponse: HTTPURLResponse

    /// Wall-clock timestamp when the response was received.
    public let receivedAt: Date

    /// Round-trip latency in seconds.
    public let latency: TimeInterval

    /// True if this response was served from a local cache.
    public let isCached: Bool

    // MARK: Convenience

    /// HTTP status code.
    public var statusCode: Int { urlResponse.statusCode }

    /// True for 2xx status codes.
    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// All response headers (keys are lowercased for case-insensitive access).
    public var headers: [String: String] {
        urlResponse.allHeaderFields.reduce(into: [:]) { result, pair in
            if let key = pair.key as? String {
                result[key.lowercased()] = pair.value as? String
            }
        }
    }

    /// Attempt to decode the body as a UTF-8 string (useful for debugging).
    public var bodyString: String? {
        String(data: data, encoding: .utf8)
    }

    // MARK: Init

    public init(
        request: PulseRequest,
        data: Data,
        urlResponse: HTTPURLResponse,
        receivedAt: Date = Date(),
        latency: TimeInterval = 0,
        isCached: Bool = false
    ) {
        self.request = request
        self.data = data
        self.urlResponse = urlResponse
        self.receivedAt = receivedAt
        self.latency = latency
        self.isCached = isCached
    }
}

// MARK: - CachedResponse

/// A response snapshot stored in the cache layer.
public struct CachedResponse: Codable, Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]
    public let cachedAt: Date
    public let expiresAt: Date

    public var isExpired: Bool { Date() > expiresAt }

    public init(
        data: Data,
        statusCode: Int,
        headers: [String: String],
        ttl: TimeInterval
    ) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.cachedAt = Date()
        self.expiresAt = Date().addingTimeInterval(ttl)
    }
}
