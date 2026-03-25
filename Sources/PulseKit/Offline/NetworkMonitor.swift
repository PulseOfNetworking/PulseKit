// Sources/PulseKit/Offline/NetworkMonitor.swift
//  PulseKit
//
//  Created by Pulse


import Foundation
import Network

// MARK: - NetworkMonitor

/// Wraps `NWPathMonitor` to provide a reactive connectivity stream
/// and a synchronous `isConnected` property.
public final class NetworkMonitor: @unchecked Sendable {

    // MARK: Properties

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var continuations: [AsyncStream<Bool>.Continuation] = []
    private let lock = NSLock()

    private(set) public var isConnected: Bool = true
    private(set) public var connectionType: ConnectionType = .unknown

    // MARK: Init

    public init(queue: DispatchQueue = DispatchQueue(label: "com.pulsekit.networkmonitor")) {
        self.monitor = NWPathMonitor()
        self.queue = queue
        startMonitoring()
    }

    deinit {
        monitor.cancel()
        lock.withLock {
            continuations.forEach { $0.finish() }
        }
    }

    // MARK: - Reactive API

    /// An `AsyncStream` that emits `true` when connectivity is gained and `false` when lost.
    public var connectivityStream: AsyncStream<Bool> {
        AsyncStream { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
            // Emit current state immediately
            continuation.yield(isConnected)
        }
    }

    // MARK: - Private

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let type = ConnectionType(path: path)

            self.isConnected = connected
            self.connectionType = type

            self.lock.withLock {
                self.continuations.forEach { $0.yield(connected) }
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - ConnectionType

public enum ConnectionType: Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case unknown

    init(path: NWPath) {
        if path.usesInterfaceType(.wifi) {
            self = .wifi
        } else if path.usesInterfaceType(.cellular) {
            self = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            self = .wiredEthernet
        } else if path.usesInterfaceType(.loopback) {
            self = .loopback
        } else {
            self = .unknown
        }
    }
}
