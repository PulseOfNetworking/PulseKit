// Sources/PulseKit/Protocols/NetworkClientProtocol.swift
//  PulseKit
//
//  Created by Pulse

// PulseKit — Smart Networking Engine for iOS
// © 2024 PulseKit Contributors. MIT License.

import Foundation
import Combine

// MARK: - Primary Network Client Contract

/// The central contract every PulseKit client must conform to.
/// Provides async/await, Combine publisher, and callback-based access.
public protocol NetworkClientProtocol: AnyObject, Sendable {

    /// Execute a typed request and decode the response body.
    /// - Parameter request: A ``PulseRequest`` describing the endpoint.
    /// - Returns: A decoded value of type `T`.
    func send<T: Decodable>(_ request: PulseRequest) async throws -> T

    /// Execute a request and return a raw ``PulseResponse`` for manual inspection.
    func sendRaw(_ request: PulseRequest) async throws -> PulseResponse

    /// Reactive wrapper returning a Combine publisher.
    func publisher<T: Decodable>(for request: PulseRequest) -> AnyPublisher<T, PulseError>

    /// Fire-and-forget upload with progress reporting.
    func upload(
        _ request: PulseRequest,
        data: Data,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> PulseResponse

    /// Streaming download with progress.
    func download(
        _ request: PulseRequest,
        destination: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> URL
}

// MARK: - Request Interceptor

/// Allows plugins to inspect and mutate requests before they are sent.
public protocol RequestInterceptor: Sendable {
    /// Called before the request is dispatched.
    /// - Parameter request: The mutable request to be adapted.
    /// - Returns: The (possibly modified) ``PulseRequest``.
    func adapt(_ request: PulseRequest) async throws -> PulseRequest
}

// MARK: - Response Interceptor

/// Allows plugins to inspect responses and optionally trigger retries.
public protocol ResponseInterceptor: Sendable {
    /// Called after every response (success or failure).
    /// - Parameters:
    ///   - response: The raw ``PulseResponse``.
    ///   - request: The originating request.
    /// - Returns: A ``InterceptorDecision`` instructing the engine how to proceed.
    func process(
        response: PulseResponse,
        for request: PulseRequest
    ) async throws -> InterceptorDecision
}

// MARK: - Interceptor Decision

/// Outcome returned by a ``ResponseInterceptor``.
public enum InterceptorDecision: Sendable {
    /// Pass the response up the chain unmodified.
    case proceed
    /// Retry the original request (e.g. after a token refresh).
    case retry
    /// Retry with an explicit backoff duration (seconds).
    case retryAfter(TimeInterval)
    /// Short-circuit and substitute a new response.
    case substitute(PulseResponse)
}

// MARK: - Plugin Contract

/// A plugin bundles both request and response interception logic.
/// Drop-in plugins follow open/closed principle — attach without touching core code.
public protocol PulsePlugin: RequestInterceptor, ResponseInterceptor, Sendable {
    /// Human-readable identifier for logging and debug dashboards.
    var identifier: String { get }
}

// MARK: - Default Implementations

public extension PulsePlugin {
    /// Default: pass requests through unchanged.
    func adapt(_ request: PulseRequest) async throws -> PulseRequest { request }

    /// Default: proceed without modification.
    func process(response: PulseResponse, for request: PulseRequest) async throws -> InterceptorDecision {
        .proceed
    }
}

// MARK: - Response Decoder

/// Abstraction over JSON/XML/Protobuf decoding strategies.
public protocol ResponseDecoder: Sendable {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

// MARK: - Token Provider

/// Adopted by authentication plugins that supply bearer tokens.
public protocol TokenProvider: Sendable {
    /// Returns the current valid access token, refreshing if necessary.
    func validToken() async throws -> String
    /// Called when the server returns 401, signalling the token is stale.
    func refreshToken() async throws -> String
}

// MARK: - Cache Storage

/// Backend-agnostic contract for response caching.
public protocol CacheStorage: Sendable {
    func store(_ response: CachedResponse, for key: String) async
    func retrieve(for key: String) async -> CachedResponse?
    func evict(for key: String) async
    func purge() async
}

// MARK: - Metrics Sink

/// Receives observability events from the engine.
public protocol MetricsSink: Sendable {
    func record(_ event: NetworkEvent) async
}
