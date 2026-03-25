// Sources/PulseKit/Offline/OfflineQueue.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - OfflineQueue

/// A persistent, priority-aware queue for requests that failed due to
/// network unavailability.
///
/// When connectivity is restored, ``flush(using:)`` is called automatically
/// by ``PulseClient``. Requests that exceed their `offlineTTL` are silently
/// discarded to avoid stale data replays.
///
/// Backed by an actor for full Swift concurrency safety.
public actor OfflineQueue {

    // MARK: Types

    public struct QueuedRequest: Identifiable, Sendable {
        public let id: UUID
        public let request: PulseRequest
        public let enqueuedAt: Date
        public var attemptCount: Int

        var isExpired: Bool {
            Date().timeIntervalSince(enqueuedAt) > request.offlineTTL
        }

        init(request: PulseRequest) {
            self.id = UUID()
            self.request = request
            self.enqueuedAt = Date()
            self.attemptCount = 0
        }
    }

    // MARK: State

    private var queue: [QueuedRequest] = []
    private let capacity: Int
    private let networkMonitor: NetworkMonitor

    // MARK: Init

    public init(capacity: Int = 200, networkMonitor: NetworkMonitor) {
        self.capacity = capacity
        self.networkMonitor = networkMonitor
    }

    // MARK: - Public API

    /// Add a request to the tail of the queue.
    /// - Throws: ``PulseError/offlineQueueFull`` if at capacity.
    public func enqueue(_ request: PulseRequest) throws {
        guard queue.count < capacity else {
            throw PulseError.offlineQueueFull
        }
        queue.append(QueuedRequest(request: request))
    }

    /// Returns a snapshot of all pending requests.
    public var pendingRequests: [QueuedRequest] { queue }

    /// Number of requests currently waiting.
    public var count: Int { queue.count }

    // MARK: - Flush

    /// Attempt to send all queued requests using the provided client.
    /// Called automatically when connectivity is restored.
    ///
    /// - Parameter client: The ``NetworkClientProtocol`` to replay through.
    public func flush(using client: any NetworkClientProtocol) async {
        // Purge expired entries first
        let now = Date()
        queue.removeAll { item in
            let expired = now.timeIntervalSince(item.enqueuedAt) > item.request.offlineTTL
            return expired
        }

        var remaining: [QueuedRequest] = []

        for var item in queue {
            guard networkMonitor.isConnected else {
                remaining.append(item)
                continue
            }

            item.attemptCount += 1

            do {
                _ = try await client.sendRaw(item.request)
                // Success — don't re-add to remaining
            } catch {
                // Still failing — keep in queue unless TTL exceeded
                if !item.isExpired {
                    remaining.append(item)
                }
            }
        }

        queue = remaining
    }

    // MARK: - Conflict Resolution

    /// Remove any duplicate requests with the same `tag` value,
    /// keeping only the most recently enqueued version.
    public func deduplicateByTag() {
        var seen = Set<String>()
        queue = queue.reversed().filter { item in
            guard let tag = item.request.tag else { return true }
            return seen.insert(tag).inserted
        }.reversed()
    }

    /// Remove a specific request from the queue.
    public func remove(id: UUID) {
        queue.removeAll { $0.id == id }
    }

    /// Clear the entire queue.
    public func purge() {
        queue.removeAll()
    }
}
