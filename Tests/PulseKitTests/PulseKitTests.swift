// Tests/PulseKitTests/PulseKitTests.swift

import XCTest
@testable import PulseKit

// MARK: - Shared Test Helpers

/// A concrete ``TokenProvider`` that returns a hardcoded token.
struct MockTokenProvider: TokenProvider {
    var token: String
    var refreshCount = 0

    func validToken() async throws -> String { token }
    mutating func refreshToken() async throws -> String {
        refreshCount += 1
        return token + "_refreshed"
    }
}

/// Builds a minimal ``PulseConfiguration`` pointing at localhost.
func makeConfig(plugins: [any PulsePlugin] = []) -> PulseConfiguration {
    PulseConfiguration.Builder(baseURL: URL(string: "https://api.test.com")!)
        .plugins(plugins)
        .build()
}

extension PulseConfiguration.Builder {
    @discardableResult
    func plugins(_ list: [any PulsePlugin]) -> PulseConfiguration.Builder {
        var b = self
        list.forEach { b = b.plugin($0) }
        return b
    }
}

// MARK: - PulseRequest Tests

final class PulseRequestTests: XCTestCase {

    let base = URL(string: "https://api.test.com")!

    func test_resolvedURL_noParams() throws {
        let req = PulseRequest(baseURL: base, path: "/users")
        let url = try req.resolvedURL()
        XCTAssertEqual(url.absoluteString, "https://api.test.com/users")
    }

    func test_resolvedURL_withQueryParams() throws {
        let req = PulseRequest(baseURL: base, path: "/users", queryParameters: ["page": "2", "limit": "10"])
        let url = try req.resolvedURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(items["page"], "2")
        XCTAssertEqual(items["limit"], "10")
    }

    func test_addingHeaders_doesNotMutateOriginal() {
        let req = PulseRequest(baseURL: base, path: "/users")
        let mutated = req.adding(headers: ["X-Trace": "abc"])
        XCTAssertNil(req.headers["X-Trace"])
        XCTAssertEqual(mutated.headers["X-Trace"], "abc")
    }

    func test_addingQueryParams_mergesCorrectly() {
        let req = PulseRequest(baseURL: base, path: "/items", queryParameters: ["page": "1"])
        let updated = req.adding(queryParameters: ["limit": "20"])
        XCTAssertEqual(updated.queryParameters["page"], "1")
        XCTAssertEqual(updated.queryParameters["limit"], "20")
    }
}

// MARK: - BackoffStrategy Tests

final class BackoffStrategyTests: XCTestCase {

    func test_immediate_alwaysZero() {
        XCTAssertEqual(BackoffStrategy.immediate.delay(for: 0), 0)
        XCTAssertEqual(BackoffStrategy.immediate.delay(for: 10), 0)
    }

    func test_constant_alwaysSameValue() {
        let strategy = BackoffStrategy.constant(5.0)
        XCTAssertEqual(strategy.delay(for: 0), 5.0)
        XCTAssertEqual(strategy.delay(for: 99), 5.0)
    }

    func test_exponential_growsCorrectly() {
        let strategy = BackoffStrategy.exponential(base: 1.0, multiplier: 2.0, maxDelay: 60)
        XCTAssertEqual(strategy.delay(for: 0), 1.0)   // 1 * 2^0
        XCTAssertEqual(strategy.delay(for: 1), 2.0)   // 1 * 2^1
        XCTAssertEqual(strategy.delay(for: 2), 4.0)   // 1 * 2^2
        XCTAssertEqual(strategy.delay(for: 3), 8.0)   // 1 * 2^3
    }

    func test_exponential_respectsMaxDelay() {
        let strategy = BackoffStrategy.exponential(base: 1.0, multiplier: 2.0, maxDelay: 10)
        XCTAssertLessThanOrEqual(strategy.delay(for: 10), 10)
    }

    func test_exponentialJitter_withinRange() {
        let strategy = BackoffStrategy.exponentialJitter(base: 1.0, multiplier: 2.0, maxDelay: 30)
        for attempt in 0..<5 {
            let delay = strategy.delay(for: attempt)
            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(delay, 30)
        }
    }
}

// MARK: - RetryPolicy Tests

final class RetryPolicyTests: XCTestCase {

    func test_nonePolicy_hasZeroAttempts() {
        XCTAssertEqual(RetryPolicy.none.maxAttempts, 0)
    }

    func test_defaultPolicy_retriesOnExpectedCodes() {
        let policy = RetryPolicy()
        XCTAssertTrue(policy.retryableStatusCodes.contains(500))
        XCTAssertTrue(policy.retryableStatusCodes.contains(429))
        XCTAssertFalse(policy.retryableStatusCodes.contains(404))
    }
}

// MARK: - PulseError Tests

final class PulseErrorTests: XCTestCase {

    func test_wrap_returnsSameError_ifAlreadyPulseError() {
        let original = PulseError.timeout
        let wrapped = PulseError.wrap(original)
        if case .timeout = wrapped { } else {
            XCTFail("Expected .timeout, got \(wrapped)")
        }
    }

    func test_wrap_returnsCancelled_forNSURLCancelled() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let wrapped = PulseError.wrap(error)
        if case .cancelled = wrapped { } else {
            XCTFail("Expected .cancelled, got \(wrapped)")
        }
    }

    func test_wrap_returnsTimeout_forNSURLTimedOut() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let wrapped = PulseError.wrap(error)
        if case .timeout = wrapped { } else {
            XCTFail("Expected .timeout, got \(wrapped)")
        }
    }

    func test_wrap_returnsTransport_forGenericURLError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let wrapped = PulseError.wrap(error)
        if case .transportError = wrapped { } else {
            XCTFail("Expected .transportError, got \(wrapped)")
        }
    }

    func test_httpError_hasCorrectDescription() {
        let response = HTTPURLResponse(url: URL(string: "https://x.com")!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        let error = PulseError.httpError(statusCode: 404, data: Data(), response: response)
        XCTAssertTrue(error.localizedDescription.contains("404"))
    }
}

// MARK: - JSONResponseDecoder Tests

final class JSONResponseDecoderTests: XCTestCase {

    struct User: Decodable, Equatable {
        let id: Int
        let firstName: String
    }

    func test_decodesSnakeCase() throws {
        let json = #"{"id":1,"first_name":"Alice"}"#.data(using: .utf8)!
        let decoder = JSONResponseDecoder()
        let user = try decoder.decode(User.self, from: json)
        XCTAssertEqual(user.firstName, "Alice")
    }

    func test_throwsDecodingFailed_onBadJSON() {
        let data = "not json".data(using: .utf8)!
        let decoder = JSONResponseDecoder()
        XCTAssertThrowsError(try decoder.decode(User.self, from: data)) { error in
            if case PulseError.decodingFailed = error { } else {
                XCTFail("Expected PulseError.decodingFailed, got \(error)")
            }
        }
    }
}

// MARK: - InMemoryCacheStorage Tests

final class InMemoryCacheStorageTests: XCTestCase {

    func test_storeAndRetrieve_returnsSameData() async {
        let cache = InMemoryCacheStorage(capacity: 10)
        let response = CachedResponse(data: Data("hello".utf8), statusCode: 200, headers: [:], ttl: 60)
        await cache.store(response, for: "key1")
        let retrieved = await cache.retrieve(for: "key1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.data, response.data)
    }

    func test_retrieve_returnsNil_forExpiredEntry() async {
        let cache = InMemoryCacheStorage(capacity: 10)
        let response = CachedResponse(data: Data("x".utf8), statusCode: 200, headers: [:], ttl: -1)
        await cache.store(response, for: "key1")
        let retrieved = await cache.retrieve(for: "key1")
        XCTAssertNil(retrieved)
    }

    func test_evict_removesEntry() async {
        let cache = InMemoryCacheStorage(capacity: 10)
        let response = CachedResponse(data: Data("x".utf8), statusCode: 200, headers: [:], ttl: 60)
        await cache.store(response, for: "key1")
        await cache.evict(for: "key1")
        let result = await cache.retrieve(for: "key1")
        XCTAssertNil(result)
    }

    func test_lruEviction_removesLeastRecentlyUsed() async {
        let cache = InMemoryCacheStorage(capacity: 2)
        let r1 = CachedResponse(data: Data("1".utf8), statusCode: 200, headers: [:], ttl: 60)
        let r2 = CachedResponse(data: Data("2".utf8), statusCode: 200, headers: [:], ttl: 60)
        let r3 = CachedResponse(data: Data("3".utf8), statusCode: 200, headers: [:], ttl: 60)

        await cache.store(r1, for: "k1")
        await cache.store(r2, for: "k2")
        // Touch k1 to make k2 the LRU
        _ = await cache.retrieve(for: "k1")
        // Store r3 — k2 should be evicted
        await cache.store(r3, for: "k3")

        XCTAssertNotNil(await cache.retrieve(for: "k1"))
        XCTAssertNil(await cache.retrieve(for: "k2"))
        XCTAssertNotNil(await cache.retrieve(for: "k3"))
    }

    func test_purge_clearsAllEntries() async {
        let cache = InMemoryCacheStorage(capacity: 10)
        let r = CachedResponse(data: Data("x".utf8), statusCode: 200, headers: [:], ttl: 60)
        await cache.store(r, for: "k1")
        await cache.store(r, for: "k2")
        await cache.purge()
        XCTAssertEqual(await cache.count, 0)
    }
}

// MARK: - OfflineQueue Tests

final class OfflineQueueTests: XCTestCase {

    let monitor = NetworkMonitor()

    func test_enqueue_storesPendingRequest() async throws {
        let queue = OfflineQueue(capacity: 10, networkMonitor: monitor)
        let request = PulseRequest(baseURL: URL(string: "https://x.com")!, path: "/test")
        try await queue.enqueue(request)
        let pending = await queue.pendingRequests
        XCTAssertEqual(pending.count, 1)
    }

    func test_enqueue_throwsWhenFull() async {
        let queue = OfflineQueue(capacity: 1, networkMonitor: monitor)
        let request = PulseRequest(baseURL: URL(string: "https://x.com")!, path: "/test")
        try? await queue.enqueue(request)
        do {
            try await queue.enqueue(request)
            XCTFail("Expected offlineQueueFull")
        } catch PulseError.offlineQueueFull {
            // Expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_deduplicateByTag_keepsLatest() async throws {
        let queue = OfflineQueue(capacity: 10, networkMonitor: monitor)
        var r1 = PulseRequest(baseURL: URL(string: "https://x.com")!, path: "/sync")
        r1.tag = "sync"
        var r2 = r1
        r2.tag = "sync"

        try await queue.enqueue(r1)
        try await queue.enqueue(r2)
        await queue.deduplicateByTag()

        let pending = await queue.pendingRequests
        XCTAssertEqual(pending.count, 1)
    }
}

// MARK: - LoggerPlugin Tests

final class LoggerPluginTests: XCTestCase {

    func test_adapt_returnsSameRequest() async throws {
        let plugin = LoggerPlugin(level: .verbose)
        let request = PulseRequest(baseURL: URL(string: "https://api.test.com")!, path: "/test")
        let result = try await plugin.adapt(request)
        XCTAssertEqual(result.path, request.path)
    }

    func test_process_returnsProceed() async throws {
        let plugin = LoggerPlugin(level: .standard)
        let request = PulseRequest(baseURL: URL(string: "https://api.test.com")!, path: "/test")
        let urlResponse = HTTPURLResponse(
            url: URL(string: "https://api.test.com/test")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        let response = PulseResponse(request: request, data: Data(), urlResponse: urlResponse)
        let decision = try await plugin.process(response: response, for: request)
        if case .proceed = decision { } else {
            XCTFail("Expected .proceed")
        }
    }
}

// MARK: - DSL / RequestDSL Tests

final class RequestDSLTests: XCTestCase {

    let base = URL(string: "https://api.test.com")!

    func test_fluentBuilder_setsAllFields() {
        let request = PulseRequest.build(baseURL: base)
            .GET("/users")
            .query("page", "2")
            .header("Accept", "application/json")
            .timeout(45)
            .tag("user-list")
            .make()

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.path, "/users")
        XCTAssertEqual(request.queryParameters["page"], "2")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertEqual(request.timeout, 45)
        XCTAssertEqual(request.tag, "user-list")
    }

    func test_fluentBuilder_chainedMethods() {
        let request = PulseRequest.build(baseURL: base)
            .POST("/orders")
            .query("draft", "true")
            .query("source", "mobile")
            .make()

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.queryParameters.count, 2)
    }
}

// MARK: - APIEndpoint Tests

final class APIEndpointTests: XCTestCase {

    func test_resolvingPath_replacesTemplateVariables() {
        let endpoint = APIEndpoint(.get, "/users/{id}/posts/{postId}")
        let resolved = endpoint.resolvingPath(with: ["id": "42", "postId": "7"])
        XCTAssertEqual(resolved, "/users/42/posts/7")
    }

    func test_resolvingPath_leavesUnknownVariables() {
        let endpoint = APIEndpoint(.get, "/users/{id}")
        let resolved = endpoint.resolvingPath(with: [:])
        XCTAssertEqual(resolved, "/users/{id}")
    }

    func test_buildRequest_setsCorrectMethod() {
        let base = URL(string: "https://api.test.com")!
        let endpoint = APIEndpoint(.delete, "/items/{id}")
        let request = endpoint.buildRequest(baseURL: base, pathParams: ["id": "1"])
        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.path, "/items/1")
    }
}

// MARK: - GraphQL Tests

final class GraphQLTests: XCTestCase {

    func test_graphqlVariable_encodesCorrectly() throws {
        struct Wrapper: Encodable {
            let v: GraphQLVariable
        }
        let encoder = JSONEncoder()
        let stringData = try encoder.encode(Wrapper(v: .string("hello")))
        let parsed = try JSONSerialization.jsonObject(with: stringData) as? [String: Any]
        XCTAssertEqual(parsed?["v"] as? String, "hello")
    }

    func test_graphqlOperation_constructors() {
        let query = GraphQLOperation.query("{ users { id } }", variables: ["limit": .int(10)])
        XCTAssertNil(query.operationName)
        XCTAssertNotNil(query.variables)

        let mutation = GraphQLOperation.mutation("mutation CreateUser($name: String!) { ... }")
        XCTAssertNil(mutation.variables)
    }
}

// MARK: - MultipartFormData Tests

final class MultipartFormDataTests: XCTestCase {

    func test_multipart_encodesTextPart() throws {
        var form = MultipartFormData()
        form.append(.text("John", name: "name"))
        let (data, boundary) = try form.encode()
        let body = String(data: data, encoding: .utf8)!
        XCTAssertTrue(body.contains("name=\"name\""))
        XCTAssertTrue(body.contains("John"))
        XCTAssertTrue(body.contains(boundary))
    }

    func test_multipart_encodesFilePart() throws {
        var form = MultipartFormData()
        let imageData = Data(repeating: 0xFF, count: 100)
        form.append(.file(imageData, name: "avatar", fileName: "photo.jpg", mimeType: "image/jpeg"))
        let (data, _) = try form.encode()
        let body = String(data: data, encoding: .latin1)!
        XCTAssertTrue(body.contains("filename=\"photo.jpg\""))
        XCTAssertTrue(body.contains("image/jpeg"))
    }
}

// MARK: - PulseConfiguration Builder Tests

final class PulseConfigurationBuilderTests: XCTestCase {

    func test_builder_setsBaseURL() {
        let base = URL(string: "https://app.test.com")!
        let config = PulseConfiguration.Builder(baseURL: base).build()
        XCTAssertEqual(config.baseURL, base)
    }

    func test_builder_defaultHeaders_mergesCorrectly() {
        let config = PulseConfiguration.Builder(baseURL: URL(string: "https://x.com")!)
            .header("X-Client", "iOS")
            .header("Accept", "application/json")
            .build()
        XCTAssertEqual(config.defaultHeaders["X-Client"], "iOS")
        XCTAssertEqual(config.defaultHeaders["Accept"], "application/json")
    }

    func test_builder_pluginsArePreserved() {
        let logger = LoggerPlugin()
        let retry = RetryPlugin()
        let config = PulseConfiguration.Builder(baseURL: URL(string: "https://x.com")!)
            .plugin(logger)
            .plugin(retry)
            .build()
        XCTAssertEqual(config.plugins.count, 2)
        XCTAssertEqual(config.plugins[0].identifier, "com.pulsekit.logger")
        XCTAssertEqual(config.plugins[1].identifier, "com.pulsekit.retry")
    }
}
