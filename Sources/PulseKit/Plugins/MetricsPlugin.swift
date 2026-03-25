// Sources/PulseKit/Plugins/MetricsPlugin.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - MetricsPlugin

/// Tracks per-endpoint latency, error rate, and request volume.
/// Publishes aggregated snapshots accessible via ``MetricsPlugin/snapshot``.
///
/// Wire up a ``MetricsSink`` to forward events to your analytics backend.
public final class MetricsPlugin: PulsePlugin, @unchecked Sendable {

    public let identifier = "com.pulsekit.metrics"

    private let store = MetricsStore()

    // MARK: - RequestInterceptor (timestamp injection)

    public func adapt(_ request: PulseRequest) async throws -> PulseRequest {
        var tagged = request
        tagged.userInfo["pulse.metrics.startTime"] = Date().timeIntervalSinceReferenceDate as AnyHashable
        return tagged
    }

    // MARK: - ResponseInterceptor

    public func process(response: PulseResponse, for request: PulseRequest) async throws -> InterceptorDecision {
        let key = endpointKey(for: request)
        await store.record(
            endpoint: key,
            latency: response.latency,
            statusCode: response.statusCode,
            byteCount: response.data.count
        )
        return .proceed
    }

    // MARK: - Public Access

    /// Returns a copy of all collected metrics, keyed by endpoint.
    public func snapshot() async -> [String: EndpointMetrics] {
        await store.snapshot()
    }

    /// Reset all collected metrics.
    public func reset() async {
        await store.reset()
    }

    // MARK: - Helpers

    private func endpointKey(for request: PulseRequest) -> String {
        "\(request.method.rawValue) \(request.path)"
    }
}

// MARK: - EndpointMetrics

public struct EndpointMetrics: Sendable {
    public let endpoint: String
    public var requestCount: Int
    public var errorCount: Int
    public var totalLatency: Double   // seconds
    public var totalBytes: Int
    public var statusCodeCounts: [Int: Int]
    public var lastUpdated: Date

    /// Mean latency in milliseconds across all recorded requests.
    public var averageLatencyMs: Double {
        guard requestCount > 0 else { return 0 }
        return (totalLatency / Double(requestCount)) * 1000
    }

    /// Error rate from 0.0 to 1.0.
    public var errorRate: Double {
        guard requestCount > 0 else { return 0 }
        return Double(errorCount) / Double(requestCount)
    }

    /// Average response body size in bytes.
    public var averageByteCount: Double {
        guard requestCount > 0 else { return 0 }
        return Double(totalBytes) / Double(requestCount)
    }

    init(endpoint: String) {
        self.endpoint = endpoint
        self.requestCount = 0
        self.errorCount = 0
        self.totalLatency = 0
        self.totalBytes = 0
        self.statusCodeCounts = [:]
        self.lastUpdated = Date()
    }
}

// MARK: - MetricsStore (actor)

private actor MetricsStore {
    private var metrics: [String: EndpointMetrics] = [:]

    func record(endpoint: String, latency: TimeInterval, statusCode: Int, byteCount: Int) {
        var entry = metrics[endpoint] ?? EndpointMetrics(endpoint: endpoint)
        entry.requestCount += 1
        entry.totalLatency += latency
        entry.totalBytes += byteCount
        entry.statusCodeCounts[statusCode, default: 0] += 1
        entry.lastUpdated = Date()
        if !(200..<300).contains(statusCode) {
            entry.errorCount += 1
        }
        metrics[endpoint] = entry
    }

    func snapshot() -> [String: EndpointMetrics] { metrics }
    func reset() { metrics.removeAll() }
}
