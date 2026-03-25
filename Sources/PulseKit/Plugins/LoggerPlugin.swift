// Sources/PulseKit/Plugins/LoggerPlugin.swift
//  PulseKit
//
//  Created by Pulse


import Foundation
import OSLog

// MARK: - LoggerPlugin

/// Prints structured request/response logs to the system console via `os.Logger`.
///
/// Attach to a ``PulseClient`` via configuration:
/// ```swift
/// .plugin(LoggerPlugin(level: .verbose))
/// ```
public final class LoggerPlugin: PulsePlugin, @unchecked Sendable {

    public let identifier = "com.pulsekit.logger"

    public enum OutputLevel: Int, Sendable {
        /// No output.
        case none
        /// Only print errors and status codes.
        case minimal
        /// Print URL, method, status code, latency.
        case standard
        /// Print everything including headers and body.
        case verbose
    }

    private let level: OutputLevel
    private let redactedHeaderKeys: Set<String>
    private let logger: Logger

    public init(
        level: OutputLevel = .standard,
        redactedHeaderKeys: Set<String> = ["authorization", "x-api-key", "cookie"]
    ) {
        self.level = level
        self.redactedHeaderKeys = Set(redactedHeaderKeys.map { $0.lowercased() })
        self.logger = Logger(subsystem: "com.pulsekit", category: "network")
    }

    // MARK: - Request Adaptation

    public func adapt(_ request: PulseRequest) async throws -> PulseRequest {
        guard level != .none else { return request }

        let url = (try? request.resolvedURL().absoluteString) ?? request.path
        let tag = request.tag.map { " [\($0)]" } ?? ""

        switch level {
        case .none:
            break
        case .minimal:
            logger.info("→ \(request.method.rawValue) \(url)\(tag)")
        case .standard:
            logger.info("""
            ┌─── PulseKit Request\(tag)
            │ \(request.method.rawValue) \(url)
            └───
            """)
        case .verbose:
            let headers = formatHeaders(request.headers)
            let body = formatBody(request.body)
            logger.info("""
            ┌─── PulseKit Request\(tag)
            │ \(request.method.rawValue) \(url)
            │ Headers:
            \(headers)
            │ Body: \(body)
            └───
            """)
        }

        return request
    }

    // MARK: - Response Processing

    public func process(response: PulseResponse, for request: PulseRequest) async throws -> InterceptorDecision {
        guard level != .none else { return .proceed }

        let url = (try? request.resolvedURL().absoluteString) ?? request.path
        let tag = request.tag.map { " [\($0)]" } ?? ""
        let status = response.statusCode
        let latency = String(format: "%.0fms", response.latency * 1000)
        let cached = response.isCached ? " [CACHE]" : ""
        let statusIcon = response.isSuccess ? "✓" : "✗"

        switch level {
        case .none:
            break
        case .minimal:
            let logMsg = "\(statusIcon) \(status) \(request.method.rawValue) \(url) \(latency)\(cached)\(tag)"
            if response.isSuccess {
                logger.info("\(logMsg)")
            } else {
                logger.error("\(logMsg)")
            }
        case .standard:
            let logMsg = """
            ┌─── PulseKit Response\(tag)
            │ \(statusIcon) \(status) \(request.method.rawValue) \(url)
            │ Latency: \(latency)\(cached)
            └───
            """
            if response.isSuccess {
                logger.info("\(logMsg)")
            } else {
                logger.error("\(logMsg)")
            }
        case .verbose:
            let headers = formatHeaders(response.headers)
            let bodyStr = response.bodyString.map { truncate($0, to: 2000) } ?? "<empty>"
            let logMsg = """
            ┌─── PulseKit Response\(tag)
            │ \(statusIcon) \(status) \(request.method.rawValue) \(url)
            │ Latency: \(latency)\(cached)
            │ Headers:
            \(headers)
            │ Body:
            │   \(bodyStr)
            └───
            """
            if response.isSuccess {
                logger.info("\(logMsg)")
            } else {
                logger.error("\(logMsg)")
            }
        }

        return .proceed
    }

    // MARK: - Formatting Helpers

    private func formatHeaders(_ headers: [String: String]) -> String {
        headers.map { key, value in
            let displayValue = redactedHeaderKeys.contains(key.lowercased()) ? "<redacted>" : value
            return "│   \(key): \(displayValue)"
        }.sorted().joined(separator: "\n")
    }

    private func formatBody(_ body: RequestBody?) -> String {
        guard let body else { return "<none>" }
        switch body {
        case .json:   return "<JSON>"
        case .formURL: return "<form-urlencoded>"
        case .raw(let data, let ct): return "<raw \(ct), \(data.count) bytes>"
        case .multipart: return "<multipart>"
        }
    }

    private func truncate(_ string: String, to maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        return String(string.prefix(maxLength)) + "… (\(string.count - maxLength) chars truncated)"
    }
}
