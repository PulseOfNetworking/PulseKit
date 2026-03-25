// Sources/PulseKit/DSL/APIRequest.swift

import Foundation
import Combine

// MARK: - APIEndpoint

/// A composable description of a single API endpoint, used as the
/// foundation of PulseKit's declarative DSL.
///
/// Define your API surface as a struct of ``APIEndpoint`` values:
/// ```swift
/// struct UserAPI {
///     static let list   = APIEndpoint(.get,  "/users")
///     static let detail = APIEndpoint(.get,  "/users/{id}")
///     static let create = APIEndpoint(.post, "/users")
///     static let delete = APIEndpoint(.delete, "/users/{id}")
/// }
/// ```
public struct APIEndpoint: Sendable {
    public let method: HTTPMethod
    public let path: String
    public let defaultHeaders: [String: String]
    public let cachePolicy: PulseCachePolicy
    public let retryPolicy: RetryPolicy
    public let isOfflineEligible: Bool

    public init(
        _ method: HTTPMethod,
        _ path: String,
        headers: [String: String] = [:],
        cache: PulseCachePolicy = .noCache,
        retry: RetryPolicy = RetryPolicy(),
        offlineEligible: Bool = false
    ) {
        self.method = method
        self.path = path
        self.defaultHeaders = headers
        self.cachePolicy = cache
        self.retryPolicy = retry
        self.isOfflineEligible = offlineEligible
    }

    /// Resolve path template parameters. e.g. `/users/{id}` + `["id": "42"]` → `/users/42`
    public func resolvingPath(with params: [String: String]) -> String {
        params.reduce(path) { result, pair in
            result.replacingOccurrences(of: "{\(pair.key)}", with: pair.value)
        }
    }

    /// Build a ``PulseRequest`` from this endpoint definition.
    public func buildRequest(
        baseURL: URL,
        pathParams: [String: String] = [:],
        queryParams: [String: String] = [:],
        body: RequestBody? = nil
    ) -> PulseRequest {
        PulseRequest(
            baseURL: baseURL,
            path: resolvingPath(with: pathParams),
            method: method,
            queryParameters: queryParams,
            headers: defaultHeaders,
            body: body,
            cachePolicy: cachePolicy,
            retryPolicy: retryPolicy,
            isOfflineEligible: isOfflineEligible
        )
    }
}

// MARK: - @APIRequest Property Wrapper

/// A property wrapper that binds an ``APIEndpoint`` to a ``PulseClient``
/// and exposes async-send and Combine publisher APIs.
///
/// ```swift
/// struct UserService {
///     @APIRequest(.get, "/users")
///     var listUsers: RequestHandle<[User]>
///
///     @APIRequest(.post, "/users")
///     var createUser: RequestHandle<User>
/// }
///
/// // Usage
/// let users = try await service.$listUsers.send(using: client)
/// ```
@propertyWrapper
// @unchecked Sendable is safe here: APIRequest stores only a RequestHandle<Response>,
// which itself stores only an APIEndpoint (Sendable). No value of type Response is ever
// stored, so no Sendable requirement on Response is needed or appropriate.
public struct APIRequest<Response: Decodable>: @unchecked Sendable {

    public let wrappedValue: RequestHandle<Response>

    public init(
        _ method: HTTPMethod,
        _ path: String,
        headers: [String: String] = [:],
        cache: PulseCachePolicy = .noCache,
        retry: RetryPolicy = RetryPolicy()
    ) {
        let endpoint = APIEndpoint(method, path, headers: headers, cache: cache, retry: retry)
        self.wrappedValue = RequestHandle(endpoint: endpoint)
    }

    public var projectedValue: RequestHandle<Response> { wrappedValue }
}

// MARK: - RequestHandle

/// The runtime handle vended by ``APIRequest``.
/// Executes requests lazily — no network call is made until `send` is called.
///
/// `@unchecked Sendable` is safe: the only stored property is `endpoint: APIEndpoint`
/// which is fully `Sendable`. No value of `Response` is ever retained by this struct —
/// `Response` only appears as the return type of `send(...)`, so placing a `Sendable`
/// constraint on it here would incorrectly block `@MainActor`-isolated models.
public struct RequestHandle<Response: Decodable>: @unchecked Sendable {

    public let endpoint: APIEndpoint

    public init(endpoint: APIEndpoint) {
        self.endpoint = endpoint
    }

    // MARK: Async/Await

    /// Send the request and decode the response.
    /// - Parameters:
    ///   - client: The ``NetworkClientProtocol`` to use.
    ///   - pathParams: Template variables for the URL path.
    ///   - queryParams: URL query string parameters.
    ///   - body: Optional encoded request body.
    public func send(
        using client: any NetworkClientProtocol & HasBaseURL,
        pathParams: [String: String] = [:],
        queryParams: [String: String] = [:],
        body: RequestBody? = nil
    ) async throws -> Response {
        let request = endpoint.buildRequest(
            baseURL: client.baseURL,
            pathParams: pathParams,
            queryParams: queryParams,
            body: body
        )
        return try await client.send(request)
    }

    // MARK: Combine

    /// Returns a Combine publisher for this endpoint.
    public func publisher(
        using client: any NetworkClientProtocol & HasBaseURL & CombineClient,
        pathParams: [String: String] = [:],
        queryParams: [String: String] = [:]
    ) -> AnyPublisher<Response, PulseError> {
        let request = endpoint.buildRequest(
            baseURL: client.baseURL,
            pathParams: pathParams,
            queryParams: queryParams
        )
        return client.publisher(for: request)
    }
}

// MARK: - Protocol Refinements (for RequestHandle constraints)

/// Exposes `baseURL` on the client without importing PulseClient directly.
public protocol HasBaseURL {
    var baseURL: URL { get }
}

/// Marks a client as supporting Combine publishers.
public protocol CombineClient {
    func publisher<T: Decodable>(for request: PulseRequest) -> AnyPublisher<T, PulseError>
}

// Retroactive conformance for PulseClient
extension PulseClient: HasBaseURL {}
extension PulseClient: CombineClient {}

// MARK: - RequestBuilder DSL (Fluent)

/// Fluent chain-style request construction:
/// ```swift
/// let request = PulseRequest.build(baseURL: base)
///     .GET("/users")
///     .query("page", "1")
///     .header("Accept-Language", "en")
///     .cache(.returnCacheElseFetch)
///     .make()
/// ```
public class RequestDSL {

    private var baseURL: URL
    private var path: String = "/"
    private var method: HTTPMethod = .get
    private var queryParams: [String: String] = [:]
    private var headers: [String: String] = [:]
    private var body: RequestBody?
    private var cachePolicy: PulseCachePolicy = .noCache
    private var retryPolicy: RetryPolicy = RetryPolicy()
    private var timeout: TimeInterval = 30
    private var tag: String?
    private var offlineEligible: Bool = false

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    @discardableResult public func GET(_ path: String) -> RequestDSL {
        method = .get; self.path = path; return self
    }
    @discardableResult public func POST(_ path: String) -> RequestDSL {
        method = .post; self.path = path; return self
    }
    @discardableResult public func PUT(_ path: String) -> RequestDSL {
        method = .put; self.path = path; return self
    }
    @discardableResult public func PATCH(_ path: String) -> RequestDSL {
        method = .patch; self.path = path; return self
    }
    @discardableResult public func DELETE(_ path: String) -> RequestDSL {
        method = .delete; self.path = path; return self
    }

    @discardableResult public func query(_ key: String, _ value: String) -> RequestDSL {
        queryParams[key] = value; return self
    }
    @discardableResult public func queries(_ dict: [String: String]) -> RequestDSL {
        dict.forEach { queryParams[$0.key] = $0.value }; return self
    }

    @discardableResult public func header(_ key: String, _ value: String) -> RequestDSL {
        headers[key] = value; return self
    }

    @discardableResult public func body(_ b: RequestBody) -> RequestDSL {
        body = b; return self
    }

    @discardableResult public func cache(_ policy: PulseCachePolicy) -> RequestDSL {
        cachePolicy = policy; return self
    }

    @discardableResult public func retry(_ policy: RetryPolicy) -> RequestDSL {
        retryPolicy = policy; return self
    }

    @discardableResult public func timeout(_ t: TimeInterval) -> RequestDSL {
        timeout = t; return self
    }

    @discardableResult public func tag(_ t: String) -> RequestDSL {
        tag = t; return self
    }

    @discardableResult public func offlineEligible(_ flag: Bool = true) -> RequestDSL {
        offlineEligible = flag; return self
    }

    /// Finalise and return an immutable ``PulseRequest``.
    public func make() -> PulseRequest {
        PulseRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            queryParameters: queryParams,
            headers: headers,
            body: body,
            cachePolicy: cachePolicy,
            retryPolicy: retryPolicy,
            timeout: timeout,
            isOfflineEligible: offlineEligible,
            tag: tag
        )
    }
}

// MARK: - PulseRequest Entry Point

public extension PulseRequest {
    /// Begin fluent construction for the given base URL.
    static func build(baseURL: URL) -> RequestDSL {
        RequestDSL(baseURL: baseURL)
    }
}
