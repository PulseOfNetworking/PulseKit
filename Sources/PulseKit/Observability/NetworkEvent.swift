// Sources/PulseKit/Observability/NetworkEvent.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - NetworkEvent

/// Structured events emitted by ``PulseClient`` throughout the request lifecycle.
/// Consumed by ``MetricsSink`` implementations and the SwiftUI debug panel.
public enum NetworkEvent: Sendable {

    // MARK: Request Lifecycle
    case requestSent(PulseRequest)
    case requestQueued(PulseRequest)
    case requestCancelled(PulseRequest)
    case requestRetrying(PulseRequest, attempt: Int, delay: TimeInterval)

    // MARK: Response Lifecycle
    case responseReceived(PulseResponse)
    case requestFailed(PulseRequest, error: PulseError)

    // MARK: Cache
    case cacheHit(PulseRequest)
    case cacheMiss(PulseRequest)
    case cacheStored(PulseRequest, ttl: TimeInterval)
    case cacheEvicted(key: String)

    // MARK: Auth
    case tokenRefreshed
    case authenticationError(PulseError)

    // MARK: Connectivity
    case connectivityChanged(isConnected: Bool, connectionType: ConnectionType)

    // MARK: Queue
    case offlineQueueFlushed(requestCount: Int, successCount: Int)

    // MARK: Computed

    public var timestamp: Date { Date() }

    public var label: String {
        switch self {
        case .requestSent(let r):        return "→ \(r.method.rawValue) \(r.path)"
        case .requestQueued(let r):      return "⏱ QUEUED \(r.path)"
        case .requestCancelled(let r):   return "✕ CANCELLED \(r.path)"
        case .requestRetrying(let r, let n, _): return "↩ RETRY #\(n) \(r.path)"
        case .responseReceived(let r):
            return "\(r.isSuccess ? "✓" : "✗") \(r.statusCode) \(r.request.path) (\(Int(r.latency * 1000))ms)"
        case .requestFailed(let r, _):   return "✗ FAILED \(r.path)"
        case .cacheHit(let r):           return "⚡ CACHE HIT \(r.path)"
        case .cacheMiss(let r):          return "○ CACHE MISS \(r.path)"
        case .cacheStored(let r, _):     return "💾 CACHED \(r.path)"
        case .cacheEvicted(let k):       return "🗑 EVICTED \(k)"
        case .tokenRefreshed:            return "🔑 TOKEN REFRESHED"
        case .authenticationError:       return "🔒 AUTH ERROR"
        case .connectivityChanged(let c, _): return c ? "📶 ONLINE" : "📴 OFFLINE"
        case .offlineQueueFlushed(let t, let s): return "📤 QUEUE FLUSHED \(s)/\(t) sent"
        }
    }
}

// MARK: - ObservabilityCoordinator

/// Fans out ``NetworkEvent``s to all registered ``MetricsSink``s
/// and to the in-memory log buffer read by the debug panel.
public final class ObservabilityCoordinator: Sendable {

    private let sinks: [any MetricsSink]
    private let logLevel: LogLevel
    private let buffer: EventBuffer

    public init(sinks: [any MetricsSink], logLevel: LogLevel) {
        self.sinks = sinks
        self.logLevel = logLevel
        self.buffer = EventBuffer()
    }

    public func record(_ event: NetworkEvent) async {
        // Write to in-memory ring buffer (for debug panel)
        await buffer.append(event)

        // Fan out to external sinks
        await withTaskGroup(of: Void.self) { group in
            for sink in sinks {
                group.addTask { await sink.record(event) }
            }
        }
    }

    /// Returns the most recent `limit` events (newest first).
    public func recentEvents(limit: Int = 100) async -> [NetworkEvent] {
        await buffer.recentEvents(limit: limit)
    }
}

// MARK: - EventBuffer (actor)

/// Thread-safe ring buffer for the most recent network events.
actor EventBuffer {
    private var events: [NetworkEvent] = []
    private let maxCapacity = 500

    func append(_ event: NetworkEvent) {
        events.append(event)
        if events.count > maxCapacity {
            events.removeFirst(events.count - maxCapacity)
        }
    }

    func recentEvents(limit: Int) -> [NetworkEvent] {
        Array(events.suffix(limit).reversed())
    }

    func clear() {
        events.removeAll()
    }
}

// MARK: - ConsoleSink

/// Ships events to stdout. Useful for CI/testing pipelines.
public struct ConsoleSink: MetricsSink, Sendable {
    public init() {}
    public func record(_ event: NetworkEvent) async {
        print("[PulseKit] \(event.label)")
    }
}
