// Sources/PulseKit/Core/PulseConfiguration.swift
//  PulseKit
//
//  Created by Pulse

import Foundation

// MARK: - PulseConfiguration

/// Immutable configuration snapshot applied when constructing a ``PulseClient``.
/// Use ``PulseConfiguration/Builder`` for a fluent construction experience.
public struct PulseConfiguration: Sendable {

    // MARK: Networking

    public let baseURL: URL
    public let defaultTimeout: TimeInterval
    public let defaultHeaders: [String: String]

    // MARK: URLSession

    public let urlSessionConfiguration: URLSessionConfiguration

    // MARK: Decoding

    public let decoder: any ResponseDecoder
    public let encoder: JSONEncoder

    // MARK: Plugins

    /// Ordered list of plugins. Request adapters run in order, response
    /// interceptors run in reverse — mirroring a middleware stack.
    public let plugins: [any PulsePlugin]

    // MARK: Observability

    public let metricsSinks: [any MetricsSink]
    public let logLevel: LogLevel

    // MARK: Offline

    public let offlineQueueCapacity: Int
    public let isOfflineQueueEnabled: Bool

    // MARK: Security

    /// SHA-256 public-key hashes for certificate pinning. Pass an empty set
    /// to disable pinning (default). Non-empty sets enforce strict pinning.
    public let pinnedCertificateHashes: Set<String>

    // MARK: Init (direct — prefer Builder)

    public init(
        baseURL: URL,
        defaultTimeout: TimeInterval = 30,
        defaultHeaders: [String: String] = [:],
        urlSessionConfiguration: URLSessionConfiguration = .default,
        decoder: any ResponseDecoder = JSONResponseDecoder(),
        encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.keyEncodingStrategy = .convertToSnakeCase
            return e
        }(),
        plugins: [any PulsePlugin] = [],
        metricsSinks: [any MetricsSink] = [],
        logLevel: LogLevel = .info,
        offlineQueueCapacity: Int = 200,
        isOfflineQueueEnabled: Bool = true,
        pinnedCertificateHashes: Set<String> = []
    ) {
        self.baseURL = baseURL
        self.defaultTimeout = defaultTimeout
        self.defaultHeaders = defaultHeaders
        self.urlSessionConfiguration = urlSessionConfiguration
        self.decoder = decoder
        self.encoder = encoder
        self.plugins = plugins
        self.metricsSinks = metricsSinks
        self.logLevel = logLevel
        self.offlineQueueCapacity = offlineQueueCapacity
        self.isOfflineQueueEnabled = isOfflineQueueEnabled
        self.pinnedCertificateHashes = pinnedCertificateHashes
    }

    // MARK: - Builder

    @resultBuilder
    public struct PluginBuilder {
        public static func buildBlock(_ plugins: any PulsePlugin...) -> [any PulsePlugin] { plugins }
    }

    /// Fluent builder for constructing ``PulseConfiguration``.
    ///
    /// ```swift
    /// let config = PulseConfiguration.Builder(baseURL: baseURL)
    ///     .timeout(45)
    ///     .header("X-Client-Version", "2.1.0")
    ///     .plugin(LoggerPlugin())
    ///     .plugin(RetryPlugin())
    ///     .logLevel(.verbose)
    ///     .build()
    /// ```
    public class Builder {
        private var baseURL: URL
        private var timeout: TimeInterval = 30
        private var headers: [String: String] = [:]
        private var sessionConfig: URLSessionConfiguration = .default
        private var decoder: any ResponseDecoder = JSONResponseDecoder()
        private var encoder: JSONEncoder = JSONEncoder()
        private var plugins: [any PulsePlugin] = []
        private var sinks: [any MetricsSink] = []
        private var logLevel: LogLevel = .info
        private var queueCapacity: Int = 200
        private var offlineEnabled: Bool = true
        private var pinnedHashes: Set<String> = []

        public init(baseURL: URL) {
            self.baseURL = baseURL
        }

        @discardableResult public func timeout(_ value: TimeInterval) -> Builder {
            timeout = value; return self
        }

        @discardableResult public func header(_ key: String, _ value: String) -> Builder {
            headers[key] = value; return self
        }

        @discardableResult public func headers(_ dict: [String: String]) -> Builder {
            dict.forEach { headers[$0.key] = $0.value }; return self
        }

        @discardableResult public func sessionConfiguration(_ config: URLSessionConfiguration) -> Builder {
            sessionConfig = config; return self
        }

        @discardableResult public func decoder(_ d: any ResponseDecoder) -> Builder {
            decoder = d; return self
        }

        @discardableResult public func plugin(_ p: any PulsePlugin) -> Builder {
            plugins.append(p); return self
        }

        @discardableResult public func metricsSink(_ s: any MetricsSink) -> Builder {
            sinks.append(s); return self
        }

        @discardableResult public func logLevel(_ level: LogLevel) -> Builder {
            logLevel = level; return self
        }

        @discardableResult public func offlineQueue(enabled: Bool, capacity: Int = 200) -> Builder {
            offlineEnabled = enabled; queueCapacity = capacity; return self
        }

        @discardableResult public func pinCertificates(hashes: Set<String>) -> Builder {
            pinnedHashes = hashes; return self
        }

        public func build() -> PulseConfiguration {
            PulseConfiguration(
                baseURL: baseURL,
                defaultTimeout: timeout,
                defaultHeaders: headers,
                urlSessionConfiguration: sessionConfig,
                decoder: decoder,
                encoder: encoder,
                plugins: plugins,
                metricsSinks: sinks,
                logLevel: logLevel,
                offlineQueueCapacity: queueCapacity,
                isOfflineQueueEnabled: offlineEnabled,
                pinnedCertificateHashes: pinnedHashes
            )
        }
    }
}

// MARK: - Log Level

public enum LogLevel: Int, Comparable, Sendable {
    case none    = 0
    case error   = 1
    case warning = 2
    case info    = 3
    case debug   = 4
    case verbose = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
