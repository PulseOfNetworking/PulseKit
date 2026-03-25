// Sources/PulseKit/Core/PulseError.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - PulseError

/// Structured error hierarchy for every failure mode PulseKit can encounter.
/// Conforming to `LocalizedError` ensures human-readable messages in UI layers.
public enum PulseError: LocalizedError, Sendable {

    // MARK: Request Errors
    /// The constructed URL was malformed.
    case invalidURL(String)
    /// The request body could not be serialised.
    case encodingFailed(any Error)

    // MARK: Transport Errors
    /// URLSession or the OS reported a network-level failure.
    case transportError(any Error)
    /// The server returned a non-2xx status.
    case httpError(statusCode: Int, data: Data, response: HTTPURLResponse)
    /// The response body was empty when a body was expected.
    case emptyResponse
    /// The request or response exceeded the configured timeout.
    case timeout

    // MARK: Decoding Errors
    /// The response body could not be decoded into the expected type.
    case decodingFailed(any Error)

    // MARK: Auth Errors
    /// Token refresh was attempted but failed.
    case authenticationFailed(reason: String)
    /// SSL certificate pinning check failed.
    case sslPinningFailed

    // MARK: Offline / Queue Errors
    /// Device is offline and the request is not eligible for offline queuing.
    case offline
    /// The request exceeded its offline TTL and was purged from the queue.
    case offlineTTLExpired
    /// The offline queue is full.
    case offlineQueueFull

    // MARK: Plugin / Middleware Errors
    /// A plugin rejected or transformed the request/response into a failure.
    case pluginRejected(identifier: String, reason: String)

    // MARK: Cancellation
    /// The in-flight request was explicitly cancelled.
    case cancelled

    // MARK: Unknown
    case unknown(any Error)

    // MARK: LocalizedError

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .encodingFailed(let error):
            return "Request encoding failed: \(error.localizedDescription)"
        case .transportError(let error):
            return "Network transport error: \(error.localizedDescription)"
        case .httpError(let code, _, _):
            return "HTTP error \(code): \(HTTPURLResponse.localizedString(forStatusCode: code))"
        case .emptyResponse:
            return "The server returned an empty response."
        case .timeout:
            return "The request timed out."
        case .decodingFailed(let error):
            return "Response decoding failed: \(error.localizedDescription)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .sslPinningFailed:
            return "SSL certificate pinning validation failed."
        case .offline:
            return "No network connection available."
        case .offlineTTLExpired:
            return "The queued request expired before it could be sent."
        case .offlineQueueFull:
            return "The offline request queue is at capacity."
        case .pluginRejected(let id, let reason):
            return "Plugin '\(id)' rejected the operation: \(reason)"
        case .cancelled:
            return "The request was cancelled."
        case .unknown(let error):
            return "An unexpected error occurred: \(error.localizedDescription)"
        }
    }

    /// Convenience: cast any thrown error into a ``PulseError``.
    public static func wrap(_ error: any Error) -> PulseError {
        if let pulseError = error as? PulseError { return pulseError }
        if (error as NSError).code == NSURLErrorCancelled { return .cancelled }
        if (error as NSError).code == NSURLErrorTimedOut { return .timeout }
        if (error as NSError).domain == NSURLErrorDomain { return .transportError(error) }
        return .unknown(error)
    }
}
