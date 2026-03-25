// Sources/PulseKit/Examples/ExampleUsage.swift
//  PulseKit
//
//  Created by Pulse

// This file demonstrates how PulseKit is used in real-world applications.
// Examples progress from basic to advanced.


import Foundation
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 1. Basic Setup
// ─────────────────────────────────────────────────────────────────────────────

func example_BasicSetup() {
    let client = PulseClient(
        configuration: PulseConfiguration.Builder(
            baseURL: URL(string: "https://api.yourapp.com/v2")!
        )
        .timeout(30)
        .header("X-Client-Version", "3.0.0")
        .header("Accept-Language", Locale.current.language.languageCode?.identifier ?? "en")
        .plugin(LoggerPlugin(level: .standard))
        .plugin(RetryPlugin(maxAttempts: 3))
        .logLevel(.info)
        .build()
    )
    _ = client  // retain
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 2. Defining Models
// ─────────────────────────────────────────────────────────────────────────────

struct User: Codable, Identifiable {
    let id: Int
    let name: String
    let email: String
    let avatarUrl: String?
    let createdAt: Date
}

struct PaginatedResponse<T: Decodable>: Decodable {
    let items: [T]
    let totalCount: Int
    let page: Int
    let hasNextPage: Bool
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 3. Declarative API Definition (Recommended Pattern)
// ─────────────────────────────────────────────────────────────────────────────

/// Define the entire API surface in one place — no scattered URL strings.
enum UserEndpoint {
    static let list   = APIEndpoint(.get,    "/users",          cache: .fetchAndStore(ttl: 120))
    static let detail = APIEndpoint(.get,    "/users/{id}")
    static let create = APIEndpoint(.post,   "/users",          retry: .none)
    static let update = APIEndpoint(.patch,  "/users/{id}",     retry: .none)
    static let delete = APIEndpoint(.delete, "/users/{id}",     retry: .none)
    static let avatar = APIEndpoint(.post,   "/users/{id}/avatar")
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 4. Repository / Service Layer (MVVM-friendly)
// ─────────────────────────────────────────────────────────────────────────────

protocol UserRepositoryProtocol {
    func fetchUsers(page: Int) async throws -> PaginatedResponse<User>
    func fetchUser(id: Int) async throws -> User
    func createUser(name: String, email: String) async throws -> User
    func deleteUser(id: Int) async throws
}

final class UserRepository: UserRepositoryProtocol {
    private let client: PulseClient

    init(client: PulseClient) {
        self.client = client
    }

    func fetchUsers(page: Int) async throws -> PaginatedResponse<User> {
        let request = UserEndpoint.list.buildRequest(
            baseURL: client.baseURL,
            queryParams: ["page": String(page), "limit": "20"]
        )
        return try await client.send(request)
    }

    func fetchUser(id: Int) async throws -> User {
        let request = UserEndpoint.detail.buildRequest(
            baseURL: client.baseURL,
            pathParams: ["id": String(id)]
        )
        return try await client.send(request)
    }

    struct CreateUserBody: Encodable, Sendable {
        let name: String
        let email: String
    }

    func createUser(name: String, email: String) async throws -> User {
        let request = UserEndpoint.create.buildRequest(
            baseURL: client.baseURL,
            body: .json(CreateUserBody(name: name, email: email))
        )
        return try await client.send(request)
    }

    func deleteUser(id: Int) async throws {
        let request = UserEndpoint.delete.buildRequest(
            baseURL: client.baseURL,
            pathParams: ["id": String(id)]
        )
        _ = try await client.sendRaw(request)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 5. Fluent DSL Style
// ─────────────────────────────────────────────────────────────────────────────

func example_FluentDSL(client: PulseClient) async throws {
    let request = PulseRequest.build(baseURL: client.baseURL)
        .GET("/feed")
        .query("category", "tech")
        .query("page", "1")
        .header("X-Priority", "high")
        .cache(.staleWhileRevalidate(ttl: 60))
        .tag("feed-tech")
        .offlineEligible()
        .make()

    let _: PaginatedResponse<User> = try await client.send(request)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 6. Combine Integration (UIKit / Legacy)
// ─────────────────────────────────────────────────────────────────────────────

final class UserListViewModel {
    private var cancellables = Set<AnyCancellable>()
    private let client: PulseClient

    init(client: PulseClient) { self.client = client }

    func loadUsers(onResult: @escaping ([User]) -> Void) {
        let request = UserEndpoint.list.buildRequest(baseURL: client.baseURL)
        client.publisher(for: request)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        print("Error:", error.localizedDescription)
                    }
                },
                receiveValue: { (response: PaginatedResponse<User>) in
                    onResult(response.items)
                }
            )
            .store(in: &cancellables)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 7. Authentication Plugin Setup
// ─────────────────────────────────────────────────────────────────────────────

final class AppTokenProvider: TokenProvider {
    private var accessToken: String = ""
    private var refreshTokenStr: String = ""

    func validToken() async throws -> String {
        // Check expiry, return cached or refresh
        guard !accessToken.isEmpty else { return try await refreshToken() }
        return accessToken
    }

    func refreshToken() async throws -> String {
        // Call your auth endpoint
        // let tokens = try await authService.refresh(refreshTokenStr)
        // accessToken = tokens.accessToken
        // return accessToken
        return "refreshed_token"
    }
}

func example_AuthenticatedClient() -> PulseClient {
    let tokenProvider = AppTokenProvider()
    return PulseClient(
        configuration: PulseConfiguration.Builder(
            baseURL: URL(string: "https://secure-api.yourapp.com")!
        )
        .plugin(AuthPlugin(tokenProvider: tokenProvider))
        .plugin(LoggerPlugin(level: .minimal, redactedHeaderKeys: ["authorization"]))
        .plugin(RetryPlugin())
        .build()
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 8. Offline-First Flow
// ─────────────────────────────────────────────────────────────────────────────

func example_OfflineFirst(client: PulseClient) async {
    // Mark requests as offline-eligible so they queue when offline
    let syncRequest = PulseRequest.build(baseURL: client.baseURL)
        .POST("/events")
        .offlineEligible(true)
        .tag("analytics-event")          // dedup tag
        .make()

    do {
        _ = try await client.sendRaw(syncRequest)
    } catch PulseError.offline {
        print("Request queued — will retry when online")
    } catch {
        print("Error:", error.localizedDescription)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 9. File Upload with Progress
// ─────────────────────────────────────────────────────────────────────────────

func example_Upload(client: PulseClient, imageData: Data, userId: Int) async throws {
    var form = MultipartFormData()
    form.append(.file(imageData, name: "avatar", fileName: "photo.jpg", mimeType: "image/jpeg"))
    let (body, boundary) = try form.encode()

    let request = PulseRequest.build(baseURL: client.baseURL)
        .POST("/users/\(userId)/avatar")
        .header("Content-Type", "multipart/form-data; boundary=\(boundary)")
        .make()

    let response = try await client.upload(request, data: body) { progress in
        print(String(format: "Upload: %.0f%%", progress * 100))
    }
    print("Upload complete, status:", response.statusCode)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 10. GraphQL Usage
// ─────────────────────────────────────────────────────────────────────────────

struct UserQueryData: Decodable {
    struct UserNode: Decodable {
        let id: String
        let name: String
        let email: String
    }
    let user: UserNode
}

func example_GraphQL(pulseClient: PulseClient) async throws {
    let gql = GraphQLClient(base: pulseClient, endpoint: "/graphql")

    let data: UserQueryData = try await gql.execute(
        .query("""
            query GetUser($id: ID!) {
              user(id: $id) {
                id
                name
                email
              }
            }
        """, variables: ["id": .string("42")])
    )
    print("User:", data.user.name)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 11. WebSocket Usage
// ─────────────────────────────────────────────────────────────────────────────

func example_WebSocket() async {
    let ws = PulseWebSocket(
        url: URL(string: "wss://realtime.yourapp.com/channel/updates")!,
        configuration: PulseWebSocket.Configuration(
            pingInterval: 20,
            reconnectPolicy: .automatic(
                maxAttempts: 5,
                backoff: .exponentialJitter(base: 1, multiplier: 2, maxDelay: 30)
            )
        )
    )

    try? await ws.connect()

    for await event in ws.events {
        switch event {
        case .message(.text(let text)):
            print("Received:", text)
        case .disconnected(let code, let reason):
            print("Disconnected \(code.rawValue):", reason ?? "no reason")
            return
        case .error(let error):
            print("WS error:", error)
        default:
            break
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 12. Caching Setup
// ─────────────────────────────────────────────────────────────────────────────

func example_CachedClient() -> PulseClient {
    PulseClient(
        configuration: PulseConfiguration.Builder(
            baseURL: URL(string: "https://api.yourapp.com")!
        )
        .plugin(LoggerPlugin())
        .build(),
        cache: InMemoryCacheStorage(capacity: 150)  // or DiskCacheStorage()
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 13. Certificate Pinning (Fintech / HIPAA)
// ─────────────────────────────────────────────────────────────────────────────

func example_PinnedClient() -> PulseClient {
    PulseClient(
        configuration: PulseConfiguration.Builder(
            baseURL: URL(string: "https://api.yourbank.com")!
        )
        .pinCertificates(hashes: [
            "BBBBBBB/1111111111111111111111111111111111111=",  // leaf cert hash
            "CCCCCCC/2222222222222222222222222222222222222="   // intermediate
        ])
        .build()
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 14. Custom Plugin Example
// ─────────────────────────────────────────────────────────────────────────────

/// Injects a per-request trace ID for distributed tracing (Datadog / Jaeger).
final class TracingPlugin: PulsePlugin {
    let identifier = "com.myapp.tracing"

    func adapt(_ request: PulseRequest) async throws -> PulseRequest {
        let traceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32)
        return request.adding(headers: [
            "X-Trace-ID": String(traceID),
            "X-Span-ID":  String(UUID().uuidString.prefix(16))
        ])
    }
}

/// Validates that all responses carry a required `X-Request-ID` header.
final class ResponseValidationPlugin: PulsePlugin {
    let identifier = "com.myapp.validation"

    func process(response: PulseResponse, for request: PulseRequest) async throws -> InterceptorDecision {
        guard response.headers["x-request-id"] != nil else {
            throw PulseError.pluginRejected(
                identifier: identifier,
                reason: "Missing required X-Request-ID header"
            )
        }
        return .proceed
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: 15. Metrics Observation
// ─────────────────────────────────────────────────────────────────────────────

func example_Metrics(client: PulseClient, metricsPlugin: MetricsPlugin) async {
    let snapshot = await metricsPlugin.snapshot()
    for (endpoint, metrics) in snapshot.sorted(by: { $0.value.requestCount > $1.value.requestCount }) {
        print("""
        \(endpoint)
          Requests : \(metrics.requestCount)
          Avg Lat  : \(String(format: "%.0f", metrics.averageLatencyMs))ms
          Error %  : \(String(format: "%.1f", metrics.errorRate * 100))%
          Avg Size : \(String(format: "%.0f", metrics.averageByteCount)) bytes
        """)
    }
}
