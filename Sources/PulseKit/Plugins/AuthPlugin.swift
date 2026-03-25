// Sources/PulseKit/Plugins/AuthPlugin.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - AuthPlugin

/// Injects a bearer token into every outgoing request and handles
/// token refresh transparently on 401 responses.
///
/// ```swift
/// let auth = AuthPlugin(tokenProvider: MyTokenProvider())
/// ```
///
/// The plugin prevents thundering-herd token refresh by serialising
/// concurrent refresh requests through an actor.
public final class AuthPlugin: PulsePlugin, @unchecked Sendable {

    public let identifier = "com.pulsekit.auth"

    private let tokenProvider: any TokenProvider
    private let headerName: String
    private let tokenScheme: String
    private let refresher = TokenRefreshCoordinator()

    /// - Parameters:
    ///   - tokenProvider: Provides and refreshes tokens.
    ///   - headerName: The header key (default `"Authorization"`).
    ///   - tokenScheme: Prefix for the token value (default `"Bearer"`).
    public init(
        tokenProvider: any TokenProvider,
        headerName: String = "Authorization",
        tokenScheme: String = "Bearer"
    ) {
        self.tokenProvider = tokenProvider
        self.headerName = headerName
        self.tokenScheme = tokenScheme
    }

    // MARK: - RequestInterceptor

    public func adapt(_ request: PulseRequest) async throws -> PulseRequest {
        let token = try await tokenProvider.validToken()
        return request.adding(headers: [headerName: "\(tokenScheme) \(token)"])
    }

    // MARK: - ResponseInterceptor

    public func process(response: PulseResponse, for request: PulseRequest) async throws -> InterceptorDecision {
        guard response.statusCode == 401 else { return .proceed }

        // Already retried once — don't loop infinitely
        if request.userInfo["pulse.auth.didRefresh"] as? Bool == true {
            throw PulseError.authenticationFailed(reason: "Token refresh did not resolve 401")
        }

        // Serialise concurrent refreshes — only one inflight refresh at a time
        let newToken = try await refresher.refresh(using: tokenProvider)

        // Rebuild the request with the fresh token
        var retryRequest = request
        retryRequest.headers[headerName] = "\(tokenScheme) \(newToken)"
        retryRequest.userInfo["pulse.auth.didRefresh"] = true
        return .substitute(
            PulseResponse(
                request: retryRequest,
                data: response.data,
                urlResponse: response.urlResponse
            )
        )
    }
}

// MARK: - TokenRefreshCoordinator (actor)

/// Ensures only a single token refresh is in-flight at any given time.
/// Subsequent callers wait for the ongoing refresh and share its result.
private actor TokenRefreshCoordinator {

    private var refreshTask: Task<String, Error>?

    func refresh(using provider: any TokenProvider) async throws -> String {
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task<String, Error> {
            defer { self.refreshTask = nil }
            return try await provider.refreshToken()
        }
        refreshTask = task
        return try await task.value
    }
}

// MARK: - RequestSigning

/// Attaches HMAC-SHA256 request signatures for fintech/IoT APIs.
public final class RequestSigningPlugin: PulsePlugin, @unchecked Sendable {

    public let identifier = "com.pulsekit.signing"

    private let secretKey: String
    private let signatureHeaderName: String

    public init(secretKey: String, signatureHeaderName: String = "X-Signature") {
        self.secretKey = secretKey
        self.signatureHeaderName = signatureHeaderName
    }

    public func adapt(_ request: PulseRequest) async throws -> PulseRequest {
        let url = (try? request.resolvedURL().absoluteString) ?? request.path
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let payload = "\(request.method.rawValue)\(url)\(timestamp)"
        let signature = hmacSHA256(message: payload, key: secretKey)
        return request.adding(headers: [
            signatureHeaderName: signature,
            "X-Timestamp": timestamp
        ])
    }

    private func hmacSHA256(message: String, key: String) -> String {
        // Production: use CryptoKit's HMAC<SHA256>
        // Stub for illustration (replace with real CryptoKit implementation)
        return Data(message.utf8).base64EncodedString()
    }
}
