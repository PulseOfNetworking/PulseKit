# ⚡ PulseKit

> A next-generation **Smart Networking Engine** for iOS — built on Swift Concurrency, designed for scale.

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![iOS](https://img.shields.io/badge/iOS-15.0+-blue.svg)](https://developer.apple.com/ios/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

PulseKit is not just another HTTP wrapper. It is a **complete networking infrastructure** designed for production apps at scale — OTT platforms, fintech, IoT, and beyond.

---

## ✨ Why PulseKit?

| Feature | URLSession | Alamofire | **PulseKit** |
|---|---|---|---|
| async/await native | ✓ | ✓ | ✓ |
| Plugin / Middleware | ✗ | Partial | ✅ Full |
| Offline-First Queue | ✗ | ✗ | ✅ |
| Circuit Breaker | ✗ | ✗ | ✅ |
| Declarative DSL | ✗ | ✗ | ✅ |
| GraphQL Support | ✗ | ✗ | ✅ |
| WebSocket + Reconnect | ✗ | ✗ | ✅ |
| Debug Panel (SwiftUI) | ✗ | ✗ | ✅ |
| SSL Pinning | Manual | ✓ | ✅ SPKI |
| LRU Cache | ✗ | ✗ | ✅ |
| Metrics / Observability | ✗ | ✗ | ✅ |

---

## 📦 Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/PulseOfNetworking/PulseKit.git", from: "1.0.1")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "PulseKit", package: "PulseKit"),
        .product(name: "PulseKitUI", package: "PulseKit"),  // optional debug panel
    ])
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

---

## 🚀 Quick Start

```swift
import PulseKit

// 1. Configure once at app startup
let client = PulseClient(
    configuration: PulseConfiguration.Builder(
        baseURL: URL(string: "https://api.yourapp.com/v2")!
    )
    .timeout(30)
    .header("X-Client-Version", "3.0.0")
    .plugin(LoggerPlugin(level: .standard))
    .plugin(RetryPlugin(maxAttempts: 3))
    .plugin(AuthPlugin(tokenProvider: MyTokenProvider()))
    .build()
)

// 2. Define your API surface declaratively
enum UserAPI {
    static let list   = APIEndpoint(.get,  "/users", cache: .fetchAndStore(ttl: 120))
    static let detail = APIEndpoint(.get,  "/users/{id}")
    static let create = APIEndpoint(.post, "/users")
}

// 3. Send requests — typed, clean, concise
let users: PaginatedResponse<User> = try await client.send(
    UserAPI.list.buildRequest(baseURL: client.baseURL, queryParams: ["page": "1"])
)

let user: User = try await client.send(
    UserAPI.detail.buildRequest(baseURL: client.baseURL, pathParams: ["id": "42"])
)
```

---

## 🏛️ Architecture

```
PulseKit/
├── Sources/
│   ├── PulseKit/
│   │   ├── Core/               # PulseClient, PulseRequest, PulseResponse, PulseError
│   │   ├── Protocols/          # NetworkClientProtocol, PulsePlugin, CacheStorage…
│   │   ├── Networking/         # RequestBuilder, JSONResponseDecoder, SSLPinningDelegate
│   │   ├── Plugins/            # LoggerPlugin, RetryPlugin, AuthPlugin, MetricsPlugin
│   │   ├── Offline/            # NetworkMonitor, OfflineQueue
│   │   ├── Storage/            # InMemoryCacheStorage, DiskCacheStorage
│   │   ├── Observability/      # NetworkEvent, ObservabilityCoordinator
│   │   ├── DSL/                # APIEndpoint, @APIRequest, RequestDSL (fluent builder)
│   │   ├── GraphQL/            # GraphQLClient, GraphQLOperation
│   │   └── WebSocket/          # PulseWebSocket
│   └── PulseKitUI/
│       └── DebugPanel/         # NetworkDebugView (SwiftUI, dev-only)
└── Tests/
    └── PulseKitTests/
```

**Request Pipeline:**
```
Request → Plugin.adapt (×N)
        → Cache Check
        → Network Check → [offline: queue]
        → HTTP (with retry loop)
        → Plugin.process (×N, reversed)
        → Cache Store
        → Decode → Response
```

---

## 🔌 Plugin System

Plugins are the soul of PulseKit's extensibility. Drop them in without touching core code.

```swift
public protocol PulsePlugin: RequestInterceptor, ResponseInterceptor {
    var identifier: String { get }
}
```

### Built-in Plugins

| Plugin | Purpose |
|---|---|
| `LoggerPlugin` | Structured request/response logging via `os.Logger` |
| `RetryPlugin` | Exponential backoff + circuit breaker |
| `AuthPlugin` | Token injection + transparent refresh on 401 |
| `MetricsPlugin` | Per-endpoint latency, error rate, throughput |
| `RequestSigningPlugin` | HMAC-SHA256 request signatures |

### Writing a Custom Plugin

```swift
final class TracingPlugin: PulsePlugin {
    let identifier = "com.myapp.tracing"

    func adapt(_ request: PulseRequest) async throws -> PulseRequest {
        return request.adding(headers: [
            "X-Trace-ID": UUID().uuidString
        ])
    }
}

// Attach via configuration
.plugin(TracingPlugin())
```

---

## 🌐 Offline-First

```swift
// Mark a request as offline-eligible
let request = PulseRequest.build(baseURL: client.baseURL)
    .POST("/events/track")
    .offlineEligible(true)
    .tag("analytics")         // deduplicated by tag
    .make()

do {
    _ = try await client.sendRaw(request)
} catch PulseError.offline {
    // ✅ Automatically queued — will retry when connectivity returns
}
```

PulseKit uses `NWPathMonitor` to detect connectivity. When the network returns, the `OfflineQueue` flushes automatically with TTL-based expiry and tag-based deduplication.

---

## ♻️ Smart Retry

```swift
// Per-request retry policy
let request = PulseRequest(
    baseURL: base, path: "/critical-data",
    retryPolicy: RetryPolicy(
        maxAttempts: 5,
        backoffStrategy: .exponentialJitter(base: 1.0, multiplier: 2.0, maxDelay: 30),
        retryableStatusCodes: [429, 500, 502, 503, 504]
    )
)

// Global circuit breaker via RetryPlugin
.plugin(RetryPlugin(
    circuitBreakerThreshold: 10,    // open after 10 consecutive failures
    circuitBreakerResetInterval: 60 // re-probe after 60s
))
```

---

## 🔒 Security

### SSL Certificate Pinning (SPKI)

```swift
.pinCertificates(hashes: [
    "ABC123.../your-leaf-cert-sha256-base64==",
    "DEF456.../your-intermediate-sha256-base64=="
])
```

Generate hashes:
```bash
openssl s_client -connect api.yourapp.com:443 < /dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | base64
```

### Token Auto-Refresh

```swift
final class MyTokenProvider: TokenProvider {
    func validToken() async throws -> String { /* return cached or refresh */ }
    func refreshToken() async throws -> String { /* call /auth/refresh */ }
}

.plugin(AuthPlugin(tokenProvider: MyTokenProvider()))
// PulseKit auto-retries on 401, serialises concurrent refresh calls
```

---

## 💾 Caching

```swift
// In-memory LRU (fast, ephemeral)
let client = PulseClient(configuration: config, cache: InMemoryCacheStorage(capacity: 150))

// Disk cache (persistent across launches)
let client = PulseClient(configuration: config, cache: DiskCacheStorage())

// Per-request cache policy
APIEndpoint(.get, "/feed", cache: .staleWhileRevalidate(ttl: 60))
APIEndpoint(.get, "/config", cache: .fetchAndStore(ttl: 3600))
```

---

## 📡 GraphQL

```swift
let gql = GraphQLClient(base: pulseClient, endpoint: "/graphql")

let data: UserQueryData = try await gql.execute(
    .query("""
        query GetUser($id: ID!) {
          user(id: $id) { id name email }
        }
    """, variables: ["id": .string("42")])
)
```

---

## 🔄 WebSocket

```swift
let ws = PulseWebSocket(
    url: URL(string: "wss://realtime.yourapp.com/ws")!,
    configuration: .init(
        pingInterval: 20,
        reconnectPolicy: .automatic(maxAttempts: 5, backoff: .exponentialJitter(...))
    )
)

try await ws.connect()

for await event in ws.events {
    if case .message(.text(let json)) = event {
        // handle message
    }
}
```

---

## 🧰 Fluent DSL

```swift
let request = PulseRequest.build(baseURL: client.baseURL)
    .GET("/content/feed")
    .query("category", "technology")
    .query("page", "2")
    .header("X-Priority", "high")
    .cache(.staleWhileRevalidate(ttl: 60))
    .retry(RetryPolicy(maxAttempts: 2))
    .timeout(15)
    .tag("content-feed")
    .offlineEligible()
    .make()
```

---

## 📊 Observability

```swift
let metrics = MetricsPlugin()
let client = PulseClient(
    configuration: PulseConfiguration.Builder(baseURL: base)
        .plugin(metrics)
        .metricsSink(ConsoleSink())     // stdout
        .metricsSink(DatadogSink())     // your custom sink
        .build()
)

// Read snapshot at any time
let stats = await metrics.snapshot()
for (endpoint, m) in stats {
    print("\(endpoint): \(Int(m.averageLatencyMs))ms avg, \(m.errorRate * 100)% errors")
}
```

---

## 🖥️ SwiftUI Debug Panel

Add `PulseKitUI` to your target and attach the overlay **only in DEBUG builds**:

```swift
import PulseKitUI

var body: some View {
    ContentView()
    #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            NetworkDebugView(coordinator: pulseClient.observability)
        }
    #endif
}
```

The panel shows:
- Live request/response log with colour-coded status
- Per-endpoint metrics (latency, error rate, throughput)
- Cache hit/miss indicators
- Offline queue status

---

## 🧪 Testing

PulseKit is designed to be testable. Swap `NetworkClientProtocol` for a mock:

```swift
final class MockPulseClient: NetworkClientProtocol {
    var stubbedResponse: Any?

    func send<T: Decodable>(_ request: PulseRequest) async throws -> T {
        guard let response = stubbedResponse as? T else {
            throw PulseError.emptyResponse
        }
        return response
    }
    // ... implement remaining protocol methods
}

// In your test
let mock = MockPulseClient()
mock.stubbedResponse = [User(id: 1, name: "Alice", ...)]
let repo = UserRepository(client: mock)
let users = try await repo.fetchUsers(page: 1)
XCTAssertEqual(users.items.first?.name, "Alice")
```

---

## 📋 Requirements

| Requirement | Version |
|---|---|
| Swift | 5.9+ |
| iOS | 15.0+ |
| macOS | 12.0+ |
| Xcode | 15.0+ |

**Zero dependencies** — PulseKit uses only Apple frameworks: `Foundation`, `Network`, `CryptoKit`, `Combine`, `OSLog`, `SwiftUI`.

---

## 🏗️ Designed For

- **OTT / Streaming** — offline-first, WebSocket, aggressive caching
- **Fintech** — certificate pinning, request signing, zero-trust auth
- **IoT / Edge** — lightweight, resilient retry, offline queue
- **Enterprise** — plugin architecture, custom observability sinks, modular modules

---

## 🤝 Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing-plugin`)
3. Write tests for your changes
4. Run `swift test` — all tests must pass
5. Submit a PR with a clear description

---

## 📄 License

PulseKit is available under the **MIT License**. See [LICENSE](LICENSE) for details.

---

<p align="center">
Built with ❤️ using Swift Concurrency · Zero Dependencies · Production Ready
</p>
