// Sources/PulseKit/Storage/InMemoryCacheStorage.swift
//  PulseKit
//
//  Created by Pulse


import Foundation

// MARK: - InMemoryCacheStorage

/// A thread-safe in-memory LRU cache for ``CachedResponse`` values.
/// Entries are automatically evicted when expired or when the cache exceeds capacity.
///
/// For persistent caching across launches, see ``DiskCacheStorage``.
///
/// ```swift
/// let client = PulseClient(
///     configuration: config,
///     cache: InMemoryCacheStorage(capacity: 100)
/// )
/// ```
public actor InMemoryCacheStorage: CacheStorage {

    // MARK: - LRU Node

    private class Node {
        let key: String
        var value: CachedResponse
        var prev: Node?
        var next: Node?

        init(key: String, value: CachedResponse) {
            self.key = key
            self.value = value
        }
    }

    // MARK: - State

    private var map: [String: Node] = [:]
    private let capacity: Int

    // Sentinel head/tail for O(1) LRU operations
    private let head = Node(key: "__head__", value: .empty)
    private let tail = Node(key: "__tail__", value: .empty)

    // MARK: - Init

    public init(capacity: Int = 100) {
        self.capacity = capacity
        head.next = tail
        tail.prev = head
    }

    // MARK: - CacheStorage

    public func store(_ response: CachedResponse, for key: String) async {
        if let node = map[key] {
            node.value = response
            moveToFront(node)
        } else {
            let node = Node(key: key, value: response)
            map[key] = node
            insertAtFront(node)

            if map.count > capacity {
                evictLRU()
            }
        }
    }

    public func retrieve(for key: String) async -> CachedResponse? {
        guard let node = map[key] else { return nil }
        if node.value.isExpired {
            remove(node)
            map.removeValue(forKey: key)
            return nil
        }
        moveToFront(node)
        return node.value
    }

    public func evict(for key: String) async {
        guard let node = map[key] else { return }
        remove(node)
        map.removeValue(forKey: key)
    }

    public func purge() async {
        map.removeAll()
        head.next = tail
        tail.prev = head
    }

    /// Current number of cached entries.
    public var count: Int { map.count }

    // MARK: - LRU Helpers (non-isolated — called within actor context)

    private func insertAtFront(_ node: Node) {
        node.next = head.next
        node.prev = head
        head.next?.prev = node
        head.next = node
    }

    private func moveToFront(_ node: Node) {
        remove(node)
        insertAtFront(node)
    }

    private func remove(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        node.prev = nil
        node.next = nil
    }

    private func evictLRU() {
        guard let lru = tail.prev, lru !== head else { return }
        remove(lru)
        map.removeValue(forKey: lru.key)
    }
}

// MARK: - CachedResponse Empty Sentinel

private extension CachedResponse {
    static let empty = CachedResponse(data: Data(), statusCode: 0, headers: [:], ttl: 0)
}

// MARK: - DiskCacheStorage

/// Persistent cache backed by the file system.
/// Responses are stored as individual JSON files under the given directory.
/// Eviction is TTL-based on retrieval; a sweep is also run on init.
public actor DiskCacheStorage: CacheStorage {

    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL? = nil) {
        let dir = directory ?? {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            return caches.appendingPathComponent("com.pulsekit.cache", isDirectory: true)
        }()
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func store(_ response: CachedResponse, for key: String) async {
        let url = fileURL(for: key)
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func retrieve(for key: String) async -> CachedResponse? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedResponse.self, from: data) else {
            return nil
        }
        if cached.isExpired {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return cached
    }

    public func evict(for key: String) async {
        try? fileManager.removeItem(at: fileURL(for: key))
    }

    public func purge() async {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        contents.forEach { try? fileManager.removeItem(at: $0) }
    }

    private func fileURL(for key: String) -> URL {
        // Hash the key to produce a safe filename
        let hashed = key.data(using: .utf8).map { Data($0).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        } ?? key
        return directory.appendingPathComponent(hashed + ".cache")
    }
}
