// Sources/PulseKit/Networking/JSONResponseDecoder.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - JSONResponseDecoder

/// Default ``ResponseDecoder`` backed by `JSONDecoder`.
/// Configured with snake_case → camelCase key conversion and ISO8601 dates.
public struct JSONResponseDecoder: ResponseDecoder, Sendable {

    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder? = nil) {
        if let decoder {
            self.decoder = decoder
        } else {
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            d.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let raw = try container.decode(String.self)
                // Try ISO8601 with fractional seconds first
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: raw) { return date }
                iso.formatOptions = [.withInternetDateTime]
                if let date = iso.date(from: raw) { return date }
                // Fallback: unix timestamp
                if let epoch = Double(raw) { return Date(timeIntervalSince1970: epoch) }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unable to decode date from: \(raw)"
                )
            }
            self.decoder = d
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PulseError.decodingFailed(error)
        }
    }
}
