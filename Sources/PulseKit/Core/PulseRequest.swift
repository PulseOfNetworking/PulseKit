// Sources/PulseKit/Core/PulseRequest.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - HTTP Method

/// Strongly-typed HTTP verbs.
public enum HTTPMethod: String, Sendable {
    case get     = "GET"
    case post    = "POST"
    case put     = "PUT"
    case patch   = "PATCH"
    case delete  = "DELETE"
    case head    = "HEAD"
    case options = "OPTIONS"
}

// MARK: - Request Body

/// Supported body encoding strategies.
public enum RequestBody: Sendable {
    /// Encode parameters as `application/json`.
    case json(Encodable & Sendable)
    /// Encode parameters as `application/x-www-form-urlencoded`.
    case formURL([String: String])
    /// Raw data with a custom content type.
    case raw(Data, contentType: String)
    /// Multipart form data (file uploads).
    case multipart(MultipartFormData)
}

// MARK: - Cache Policy

/// Per-request caching behaviour.
public enum PulseCachePolicy: Sendable {
    /// Never cache or return cached responses.
    case noCache
    /// Return cached if available, else fetch.
    case returnCacheElseFetch
    /// Fetch fresh data, but update the cache.
    case fetchAndStore(ttl: TimeInterval)
    /// Return cache immediately, then fetch in background.
    case staleWhileRevalidate(ttl: TimeInterval)
}

// MARK: - Retry Policy

/// Per-request retry configuration.
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let backoffStrategy: BackoffStrategy
    public let retryableStatusCodes: Set<Int>

    public init(
        maxAttempts: Int = 3,
        backoffStrategy: BackoffStrategy = .exponential(base: 1.0, multiplier: 2.0, maxDelay: 30.0),
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    ) {
        self.maxAttempts = maxAttempts
        self.backoffStrategy = backoffStrategy
        self.retryableStatusCodes = retryableStatusCodes
    }

    /// A sensible no-retry policy.
    public static let none = RetryPolicy(maxAttempts: 0)
}

// MARK: - Backoff Strategy

public enum BackoffStrategy: Sendable {
    /// Retry immediately with no delay.
    case immediate
    /// Fixed delay between retries.
    case constant(TimeInterval)
    /// Delay grows as `base * multiplier^attempt`, capped at `maxDelay`.
    case exponential(base: Double, multiplier: Double, maxDelay: Double)
    /// Exponential backoff with random jitter to prevent thundering herd.
    case exponentialJitter(base: Double, multiplier: Double, maxDelay: Double)

    /// Compute the delay (in seconds) for a given attempt index (0-based).
    public func delay(for attempt: Int) -> TimeInterval {
        switch self {
        case .immediate:
            return 0
        case .constant(let interval):
            return interval
        case .exponential(let base, let multiplier, let maxDelay):
            return min(base * pow(multiplier, Double(attempt)), maxDelay)
        case .exponentialJitter(let base, let multiplier, let maxDelay):
            let computed = base * pow(multiplier, Double(attempt))
            let jitter = Double.random(in: 0...(computed * 0.3))
            return min(computed + jitter, maxDelay)
        }
    }
}

// MARK: - PulseRequest

/// The single model describing every network operation in PulseKit.
/// Intentionally immutable — mutations produce new instances (copy-on-write friendly).
public struct PulseRequest: Sendable {

    // MARK: Identity

    /// Optional stable tag for offline queue deduplication and observability.
    public var tag: String?

    // MARK: Endpoint

    public var baseURL: URL
    public var path: String
    public var method: HTTPMethod

    // MARK: Parameters

    /// URL query parameters appended to the request URL.
    public var queryParameters: [String: String]

    /// HTTP headers (merged with client-level defaults; request-level wins).
    public var headers: [String: String]

    /// Encoded body payload.
    public var body: RequestBody?

    // MARK: Behaviour

    public var cachePolicy: PulseCachePolicy
    public var retryPolicy: RetryPolicy
    public var timeout: TimeInterval

    /// Seconds before the request is dropped from the offline queue.
    public var offlineTTL: TimeInterval

    /// Whether this request should be queued when the device is offline.
    public var isOfflineEligible: Bool

    // MARK: Metadata

    /// Arbitrary context bag — useful for passing data between plugins.
    public var userInfo: [String: any Sendable & Hashable]

    // MARK: Init

    public init(
        baseURL: URL,
        path: String,
        method: HTTPMethod = .get,
        queryParameters: [String: String] = [:],
        headers: [String: String] = [:],
        body: RequestBody? = nil,
        cachePolicy: PulseCachePolicy = .noCache,
        retryPolicy: RetryPolicy = RetryPolicy(),
        timeout: TimeInterval = 30,
        offlineTTL: TimeInterval = 86400,
        isOfflineEligible: Bool = false,
        tag: String? = nil,
        userInfo: [String: any Sendable & Hashable] = [:]
    ) {
        self.baseURL = baseURL
        self.path = path
        self.method = method
        self.queryParameters = queryParameters
        self.headers = headers
        self.body = body
        self.cachePolicy = cachePolicy
        self.retryPolicy = retryPolicy
        self.timeout = timeout
        self.offlineTTL = offlineTTL
        self.isOfflineEligible = isOfflineEligible
        self.tag = tag
        self.userInfo = userInfo
    }

    // MARK: Computed

    /// The fully-resolved URL including query parameters.
    public func resolvedURL() throws -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true) else {
            throw PulseError.invalidURL(baseURL.absoluteString + path)
        }
        if !queryParameters.isEmpty {
            components.queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw PulseError.invalidURL(components.string ?? "unknown")
        }
        return url
    }

    // MARK: Builder Convenience

    /// Return a copy with additional headers merged in (request headers win on conflict).
    public func adding(headers: [String: String]) -> PulseRequest {
        var copy = self
        copy.headers.merge(headers) { _, new in new }
        return copy
    }

    /// Return a copy with additional query parameters.
    public func adding(queryParameters: [String: String]) -> PulseRequest {
        var copy = self
        copy.queryParameters.merge(queryParameters) { _, new in new }
        return copy
    }
}

