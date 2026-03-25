// Sources/PulseKit/Core/PulseClient.swift
//  PulseKit
//
//  Created by Pulse

import Foundation
import Combine

// MARK: - PulseClient

/// The central networking engine. Thread-safe, actor-isolated state management.
/// All public methods can be called from any Swift concurrency context.
///
/// ## Quick Start
/// ```swift
/// let client = PulseClient(configuration:
///     PulseConfiguration.Builder(baseURL: URL(string: "https://api.example.com")!)
///         .plugin(LoggerPlugin())
///         .plugin(RetryPlugin())
///         .build()
/// )
///
/// let users: [User] = try await client.send(
///     PulseRequest(baseURL: client.baseURL, path: "/users")
/// )
/// ```
public final class PulseClient: NetworkClientProtocol, @unchecked Sendable {

    // MARK: Properties

    public let configuration: PulseConfiguration

    /// Expose baseURL for downstream builders.
    public var baseURL: URL { configuration.baseURL }

    private let session: URLSession
    private let sessionDelegate: PulseSessionDelegate
    private let requestBuilder: RequestBuilder
    private let offlineQueue: OfflineQueue?
    private let networkMonitor: NetworkMonitor
    private let observability: ObservabilityCoordinator
    private let cache: (any CacheStorage)?

    // MARK: Init

    public init(configuration: PulseConfiguration, cache: (any CacheStorage)? = nil) {
        self.configuration = configuration
        self.cache = cache

        // Build session with optional SSL pinning delegate
        let delegate = PulseSessionDelegate(pinnedHashes: configuration.pinnedCertificateHashes)
        self.sessionDelegate = delegate
        self.session = URLSession(
            configuration: configuration.urlSessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )

        self.requestBuilder = RequestBuilder(encoder: configuration.encoder)
        self.observability = ObservabilityCoordinator(
            sinks: configuration.metricsSinks,
            logLevel: configuration.logLevel
        )

        self.networkMonitor = NetworkMonitor()

        if configuration.isOfflineQueueEnabled {
            self.offlineQueue = OfflineQueue(
                capacity: configuration.offlineQueueCapacity,
                networkMonitor: networkMonitor
            )
        } else {
            self.offlineQueue = nil
        }

        // Wire offline queue to flush on connectivity restore
        Task { [weak self] in
            await self?.startOfflineQueueFlushing()
        }
    }

    // MARK: - NetworkClientProtocol

    public func send<T: Decodable>(_ request: PulseRequest) async throws -> T {
        let response = try await execute(request)
        return try configuration.decoder.decode(T.self, from: response.data)
    }

    public func sendRaw(_ request: PulseRequest) async throws -> PulseResponse {
        try await execute(request)
    }

    public func publisher<T: Decodable>(for request: PulseRequest) -> AnyPublisher<T, PulseError> {
        Future<T, PulseError> { [weak self] promise in
            guard let self else {
                promise(.failure(.cancelled))
                return
            }
            Task {
                do {
                    let result: T = try await self.send(request)
                    promise(.success(result))
                } catch {
                    promise(.failure(PulseError.wrap(error)))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    public func upload(
        _ request: PulseRequest,
        data: Data,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> PulseResponse {
        var uploadRequest = request
        uploadRequest.body = .raw(data, contentType: request.headers["content-type"] ?? "application/octet-stream")
        return try await execute(uploadRequest)
    }

    public func download(
        _ request: PulseRequest,
        destination: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let urlRequest = try await buildURLRequest(from: request)
        let startTime = Date()

        let (tempURL, response) = try await session.download(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PulseError.emptyResponse
        }

        let latency = Date().timeIntervalSince(startTime)
        let pulseResponse = PulseResponse(
            request: request,
            data: Data(),
            urlResponse: httpResponse,
            latency: latency
        )

        await observability.record(.responseReceived(pulseResponse))

        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    // MARK: - Core Execution Pipeline

    /// The heart of PulseKit: plugin adaptation → cache check → HTTP → retry → plugin response processing.
    private func execute(_ request: PulseRequest) async throws -> PulseResponse {
        // 1. Apply plugin request adaptations (in plugin-order)
        var adapted = try await applyRequestAdaptations(to: request)

        // 2. Merge default configuration headers
        adapted = mergeDefaults(into: adapted)

        // 3. Check cache (honour policy)
        if let cached = await checkCache(for: adapted) {
            await observability.record(.cacheHit(adapted))
            return cached
        }

        // 4. Check network — offline handling
        if !networkMonitor.isConnected {
            if adapted.isOfflineEligible, let queue = offlineQueue {
                try await queue.enqueue(adapted)
                await observability.record(.requestQueued(adapted))
                throw PulseError.offline
            }
            throw PulseError.offline
        }

        // 5. Execute with retry loop
        let response = try await executeWithRetry(adapted)

        // 6. Store in cache if needed
        await storeInCache(response: response, for: adapted)

        // 7. Apply plugin response processing
        return try await applyResponseProcessing(response: response, request: adapted)
    }

    // MARK: - Retry Loop

    private func executeWithRetry(_ request: PulseRequest) async throws -> PulseResponse {
        var attempt = 0
        let policy = request.retryPolicy

        while true {
            do {
                let response = try await performHTTPRequest(request)
                if !response.isSuccess && policy.retryableStatusCodes.contains(response.statusCode) {
                    if attempt < policy.maxAttempts {
                        let delay = policy.backoffStrategy.delay(for: attempt)
                        await observability.record(.requestRetrying(request, attempt: attempt + 1, delay: delay))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        attempt += 1
                        continue
                    }
                    throw PulseError.httpError(
                        statusCode: response.statusCode,
                        data: response.data,
                        response: response.urlResponse
                    )
                }
                return response
            } catch let error as PulseError {
                // Don't retry non-retryable errors
                switch error {
                case .cancelled, .offline, .sslPinningFailed, .authenticationFailed:
                    throw error
                default:
                    if attempt < policy.maxAttempts {
                        let delay = policy.backoffStrategy.delay(for: attempt)
                        await observability.record(.requestRetrying(request, attempt: attempt + 1, delay: delay))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        attempt += 1
                        continue
                    }
                    throw error
                }
            } catch {
                throw PulseError.wrap(error)
            }
        }
    }

    // MARK: - HTTP Execution

    private func performHTTPRequest(_ request: PulseRequest) async throws -> PulseResponse {
        let urlRequest = try await buildURLRequest(from: request)
        let startTime = Date()

        await observability.record(.requestSent(request))

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PulseError.emptyResponse
            }

            let latency = Date().timeIntervalSince(startTime)
            let pulseResponse = PulseResponse(
                request: request,
                data: data,
                urlResponse: httpResponse,
                receivedAt: Date(),
                latency: latency
            )

            await observability.record(.responseReceived(pulseResponse))
            return pulseResponse

        } catch let urlError as URLError {
            await observability.record(.requestFailed(request, error: PulseError.wrap(urlError)))
            throw PulseError.wrap(urlError)
        }
    }

    // MARK: - URLRequest Construction

    private func buildURLRequest(from request: PulseRequest) async throws -> URLRequest {
        let url = try request.resolvedURL()
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue

        // Apply headers
        request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }

        // Encode body
        if let body = request.body {
            try requestBuilder.apply(body: body, to: &urlRequest)
        }

        return urlRequest
    }

    // MARK: - Plugin Pipeline

    private func applyRequestAdaptations(to request: PulseRequest) async throws -> PulseRequest {
        var adapted = request
        for plugin in configuration.plugins {
            adapted = try await plugin.adapt(adapted)
        }
        return adapted
    }

    private func applyResponseProcessing(
        response: PulseResponse,
        request: PulseRequest
    ) async throws -> PulseResponse {
        var current = response
        // Process in reverse plugin order (inner → outer)
        for plugin in configuration.plugins.reversed() {
            let decision = try await plugin.process(response: current, for: request)
            switch decision {
            case .proceed:
                continue
            case .retry:
                return try await execute(request)
            case .retryAfter(let delay):
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await execute(request)
            case .substitute(let newResponse):
                current = newResponse
            }
        }
        return current
    }

    // MARK: - Default Merging

    private func mergeDefaults(into request: PulseRequest) -> PulseRequest {
        var merged = request
        // Default headers don't override request-level headers
        let combined = configuration.defaultHeaders.merging(request.headers) { _, explicit in explicit }
        merged.headers = combined
        return merged
    }

    // MARK: - Cache Helpers

    private func checkCache(for request: PulseRequest) async -> PulseResponse? {
        guard let cache else { return nil }
        switch request.cachePolicy {
        case .noCache:
            return nil
        case .returnCacheElseFetch, .staleWhileRevalidate, .fetchAndStore:
            let key = cacheKey(for: request)
            guard let cached = await cache.retrieve(for: key), !cached.isExpired else { return nil }
            // Reconstruct a synthetic HTTPURLResponse
            guard let url = try? request.resolvedURL(),
                  let httpResponse = HTTPURLResponse(
                    url: url,
                    statusCode: cached.statusCode,
                    httpVersion: nil,
                    headerFields: cached.headers
                  ) else { return nil }
            return PulseResponse(
                request: request,
                data: cached.data,
                urlResponse: httpResponse,
                isCached: true
            )
        }
    }

    private func storeInCache(response: PulseResponse, for request: PulseRequest) async {
        guard let cache else { return }
        switch request.cachePolicy {
        case .fetchAndStore(let ttl), .staleWhileRevalidate(let ttl):
            let key = cacheKey(for: request)
            let cached = CachedResponse(
                data: response.data,
                statusCode: response.statusCode,
                headers: response.headers,
                ttl: ttl
            )
            await cache.store(cached, for: key)
        default:
            break
        }
    }

    private func cacheKey(for request: PulseRequest) -> String {
        let url = (try? request.resolvedURL().absoluteString) ?? request.path
        return "\(request.method.rawValue):\(url)"
    }

    // MARK: - Offline Queue Flushing

    private func startOfflineQueueFlushing() async {
        guard let queue = offlineQueue else { return }
        for await isConnected in networkMonitor.connectivityStream {
            if isConnected {
                await queue.flush(using: self)
            }
        }
    }
}
