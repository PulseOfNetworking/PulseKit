// Sources/PulseKit/Plugins/RetryPlugin.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - RetryPlugin

/// Intercepts failed responses and instructs the engine to retry with
/// configurable backoff and a per-host circuit-breaker.
///
/// This plugin sits on top of the per-request ``RetryPolicy`` to provide
/// **global** retry behaviours — e.g. a circuit breaker that opens when
/// an endpoint exceeds a failure threshold.
///
/// ```swift
/// .plugin(RetryPlugin(
///     maxAttempts: 4,
///     strategy: .exponentialJitter(base: 1.0, multiplier: 2.0, maxDelay: 30),
///     circuitBreakerThreshold: 5
/// ))
/// ```
public final class RetryPlugin: PulsePlugin, @unchecked Sendable {

    public let identifier = "com.pulsekit.retry"

    // MARK: Circuit Breaker State

    private enum CircuitState {
        case closed          // Normal operation
        case open(until: Date) // Failing — requests short-circuit
        case halfOpen        // Testing if host recovered
    }

    // MARK: Configuration

    private let maxAttempts: Int
    private let strategy: BackoffStrategy
    private let retryableStatusCodes: Set<Int>
    private let retryableErrors: Set<Int>  // NSURLError codes
    private let circuitBreakerThreshold: Int
    private let circuitBreakerResetInterval: TimeInterval

    // MARK: State (protected by an actor)

    private let state = CircuitBreakerState()

    public init(
        maxAttempts: Int = 3,
        strategy: BackoffStrategy = .exponentialJitter(base: 1.0, multiplier: 2.0, maxDelay: 30),
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504],
        retryableURLErrors: Set<Int> = [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost
        ],
        circuitBreakerThreshold: Int = 10,
        circuitBreakerResetInterval: TimeInterval = 60
    ) {
        self.maxAttempts = maxAttempts
        self.strategy = strategy
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableErrors = retryableURLErrors
        self.circuitBreakerThreshold = circuitBreakerThreshold
        self.circuitBreakerResetInterval = circuitBreakerResetInterval
    }

    // MARK: - RequestInterceptor

    public func adapt(_ request: PulseRequest) async throws -> PulseRequest {
        // Check circuit breaker before even sending
        let host = (try? request.resolvedURL().host) ?? request.path
        if await state.isOpen(for: host) {
            throw PulseError.pluginRejected(
                identifier: identifier,
                reason: "Circuit breaker OPEN for host: \(host)"
            )
        }
        return request
    }

    // MARK: - ResponseInterceptor

    public func process(response: PulseResponse, for request: PulseRequest) async throws -> InterceptorDecision {
        let host = (try? request.resolvedURL().host) ?? ""
        let attempt = (request.userInfo["pulse.retry.attempt"] as? Int) ?? 0

        if response.isSuccess {
            await state.recordSuccess(for: host)
            return .proceed
        }

        guard retryableStatusCodes.contains(response.statusCode) else {
            return .proceed  // Non-retryable status — let it propagate
        }

        await state.recordFailure(for: host, threshold: circuitBreakerThreshold, resetAfter: circuitBreakerResetInterval)

        if attempt >= maxAttempts {
            return .proceed  // Exhausted retries
        }

        let delay = strategy.delay(for: attempt)

        // Respect Retry-After header if present
        if let retryAfterStr = response.headers["retry-after"],
           let retryAfter = TimeInterval(retryAfterStr) {
            return .retryAfter(max(delay, retryAfter))
        }

        return .retryAfter(delay)
    }
}

// MARK: - CircuitBreakerState (actor for thread-safety)

private actor CircuitBreakerState {

    private var failureCounts: [String: Int] = [:]
    private var circuitState: [String: Date] = [:]  // host → open-until date

    func isOpen(for host: String) -> Bool {
        guard let openUntil = circuitState[host] else { return false }
        if Date() > openUntil {
            circuitState.removeValue(forKey: host)
            failureCounts[host] = 0
            return false
        }
        return true
    }

    func recordFailure(for host: String, threshold: Int, resetAfter: TimeInterval) {
        let count = (failureCounts[host] ?? 0) + 1
        failureCounts[host] = count
        if count >= threshold {
            circuitState[host] = Date().addingTimeInterval(resetAfter)
        }
    }

    func recordSuccess(for host: String) {
        failureCounts[host] = 0
        circuitState.removeValue(forKey: host)
    }

    func failureCount(for host: String) -> Int {
        failureCounts[host] ?? 0
    }
}
