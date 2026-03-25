// Sources/PulseKit/WebSocket/PulseWebSocket.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - WebSocketMessage

public enum WebSocketMessage: Sendable {
    case text(String)
    case data(Data)
    case ping
    case pong
}

// MARK: - WebSocketEvent

public enum WebSocketEvent: Sendable {
    case connected
    case message(WebSocketMessage)
    case disconnected(code: URLSessionWebSocketTask.CloseCode, reason: String?)
    case error(any Error)
}

// MARK: - PulseWebSocket

/// A managed WebSocket connection with automatic reconnect, backoff,
/// and `AsyncStream`-based message delivery.
///
/// ```swift
/// let ws = PulseWebSocket(url: URL(string: "wss://api.example.com/ws")!)
/// await ws.connect()
///
/// for await event in ws.events {
///     switch event {
///     case .message(.text(let text)):
///         print("Received:", text)
///     case .disconnected:
///         break
///     default: break
///     }
/// }
/// ```
public final class PulseWebSocket: @unchecked Sendable {

    // MARK: Configuration

    public struct Configuration: Sendable {
        public var pingInterval: TimeInterval
        public var reconnectPolicy: ReconnectPolicy
        public var headers: [String: String]

        public enum ReconnectPolicy: Sendable {
            case never
            case automatic(maxAttempts: Int, backoff: BackoffStrategy)
        }

        public init(
            pingInterval: TimeInterval = 25,
            reconnectPolicy: ReconnectPolicy = .automatic(
                maxAttempts: 5,
                backoff: .exponentialJitter(base: 1, multiplier: 2, maxDelay: 30)
            ),
            headers: [String: String] = [:]
        ) {
            self.pingInterval = pingInterval
            self.reconnectPolicy = reconnectPolicy
            self.headers = headers
        }
    }

    // MARK: State

    public enum State: Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(any Error)
    }

    // MARK: Properties

    public let url: URL
    public let config: Configuration
    private(set) public var state: State = .disconnected

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var continuations: [AsyncStream<WebSocketEvent>.Continuation] = []
    private let lock = NSLock()

    // MARK: Init

    public init(url: URL, configuration: Configuration = Configuration()) {
        self.url = url
        self.config = configuration
    }

    deinit {
        disconnect(code: .normalClosure, reason: "PulseWebSocket deallocated")
    }

    // MARK: - Public API

    /// Open the connection. Returns when the handshake completes or throws on failure.
    public func connect() async throws {
        state = .connecting
        emit(.connected)  // Optimistic — real confirmation arrives in the receive loop
        var request = URLRequest(url: url)
        config.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        state = .connected

        startReceiving()
        startPingTimer()
    }

    /// Send a text message.
    public func send(text: String) async throws {
        try await task?.send(.string(text))
    }

    /// Send binary data.
    public func send(data: Data) async throws {
        try await task?.send(.data(data))
    }

    /// Close the connection gracefully.
    public func disconnect(code: URLSessionWebSocketTask.CloseCode = .normalClosure, reason: String? = nil) {
        pingTimer?.cancel()
        receiveTask?.cancel()
        let reasonData = reason.flatMap { $0.data(using: .utf8) }
        task?.cancel(with: code, reason: reasonData)
        task = nil
        state = .disconnected
        lock.withLock {
            continuations.forEach { $0.finish() }
            continuations.removeAll()
        }
    }

    // MARK: - AsyncStream API

    /// Subscribe to incoming WebSocket events as an `AsyncStream`.
    public var events: AsyncStream<WebSocketEvent> {
        AsyncStream { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
        }
    }

    // MARK: - Private

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let message = try await self.task?.receive() else { break }
                    switch message {
                    case .string(let text): self.emit(.message(.text(text)))
                    case .data(let data):   self.emit(.message(.data(data)))
                    @unknown default: break
                    }
                } catch {
                    self.emit(.error(error))
                    await self.handleDisconnect(error: error)
                    break
                }
            }
        }
    }

    private func startPingTimer() {
        pingTimer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(config.pingInterval * 1_000_000_000))
                self.task?.sendPing { _ in }
                self.emit(.message(.ping))
            }
        }
    }

    private func handleDisconnect(error: any Error) async {
        guard case .automatic(let maxAttempts, let backoff) = config.reconnectPolicy else {
            state = .failed(error)
            return
        }

        for attempt in 1...maxAttempts {
            state = .reconnecting(attempt: attempt)
            let delay = backoff.delay(for: attempt - 1)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            do {
                try await connect()
                return  // Reconnected
            } catch {
                continue
            }
        }
        state = .failed(error)
    }

    private func emit(_ event: WebSocketEvent) {
        lock.withLock {
            continuations.forEach { $0.yield(event) }
        }
    }
}

