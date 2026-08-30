//
//  RemoteChangelogService.swift
//  Joodle
//
//  Created by Claude on 2025.
//

import Foundation

// MARK: - API Response Models

/// Response from the changelog index endpoint
struct ChangelogIndexResponse: Codable {
    let changelogs: [ChangelogIndexEntry]
}

/// Lightweight changelog entry for the index (without full markdown content)
struct ChangelogIndexEntry: Codable, Identifiable {
    let version: String
    let date: String
    let headerImageURLs: [String]?

    private enum CodingKeys: String, CodingKey {
        case version
        case date
        case headerImageURLs = "headerImageURL"
    }

    var displayVersion: String {
        guard let v = versionComponents else { return version }
        return "\(v.major).\(v.minor)"
    }

    var id: String { version }

    /// Parse the date string into a Date object
    var parsedDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }

    /// Parse version components. The build is absent from 2.11 onward.
    var versionComponents: (major: Int, minor: Int, build: Int?)? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1], parts.count > 2 ? parts[2] : nil)
    }
}

/// Response from the individual changelog endpoint
struct ChangelogDetailResponse: Codable {
    let version: String
    let date: String
    let headerImageURLs: [String]?
    let markdown: String

    private enum CodingKeys: String, CodingKey {
        case version
        case date
        case headerImageURLs = "headerImageURL"
        case markdown
    }
}

// MARK: - Service Errors

enum ChangelogServiceError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case notFound
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid API URL")
        case .networkError(let error):
            return String(localized: "Network error: \(error.localizedDescription)")
        case .decodingError(let error):
            return String(localized: "Failed to parse response: \(error.localizedDescription)")
        case .notFound:
            return String(localized: "Changelog not found")
        case .serverError(let code):
            return String(localized: "Server error: \(code, format: .number.grouping(.never))")
        }
    }
}

// MARK: - Remote Changelog Service

/// Service for fetching changelogs from the remote API
actor RemoteChangelogService {
    static let shared = RemoteChangelogService()

    // MARK: - Configuration

    /// Base URL for the changelog API. Debug builds can be pointed at a local
    /// portfolio dev server — see `AppEnvironment.apiBaseURL`.
    private var baseURL: String { "\(AppEnvironment.apiBaseURL)/api/changelogs/joodle" }
    private var currentLocale: String { LocaleProvider.currentLanguageCode }

    // MARK: - Caching

    private var indexCache: [ChangelogIndexEntry]?
    private var indexCacheTimestamp: Date?
    private var indexCacheLocale: String?
    private var markdownCache: [String: String] = [:] // version -> markdown

    /// Cache duration in seconds (5 minutes)
    private let cacheDuration: TimeInterval = 300

    /// Launch presentation waits on this fetch, so it gets a short leash rather
    /// than the default 60s: past the timeout the bundled notes are used, which
    /// is a far better outcome than a launch that decides what to show a minute
    /// after the user opened the app.
    private let session: URLSession = {
      let configuration = URLSessionConfiguration.default
      configuration.timeoutIntervalForRequest = 5
      configuration.timeoutIntervalForResource = 10
      return URLSession(configuration: configuration)
    }()

    private init() {}

    // MARK: - Public API

    /// Fetch the changelog index (list of all changelogs without full content)
    func fetchChangelogIndex(forceRefresh: Bool = false) async throws -> [ChangelogIndexEntry] {
        // Return cached data if valid and not forcing refresh
        if !forceRefresh,
           let cached = indexCache,
           let timestamp = indexCacheTimestamp,
           indexCacheLocale == currentLocale,
           Date().timeIntervalSince(timestamp) < cacheDuration {
            return cached
        }

        guard let url = localizedURL() else {
            throw ChangelogServiceError.invalidURL
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ChangelogServiceError.networkError(URLError(.badServerResponse))
            }

            guard httpResponse.statusCode == 200 else {
                throw ChangelogServiceError.serverError(httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            let indexResponse = try decoder.decode(ChangelogIndexResponse.self, from: data)

            // Sort by version (newest first)
            let sorted = indexResponse.changelogs.sorted { entry1, entry2 in
                VersionComparator.isGreaterThan(entry1.version, entry2.version)
            }

            // Update cache
            indexCache = sorted
            indexCacheTimestamp = Date()
            indexCacheLocale = currentLocale

            // Persist to disk for offline access
            await persistIndexToDisk(sorted)

            return sorted
        } catch let error as ChangelogServiceError {
            throw error
        } catch let error as DecodingError {
            throw ChangelogServiceError.decodingError(error)
        } catch {
            throw ChangelogServiceError.networkError(error)
        }
    }

    /// Fetch the full markdown content for a specific version
    func fetchChangelogDetail(version: String, forceRefresh: Bool = false) async throws -> String {
        // Return cached markdown if available and not forcing refresh
        let cacheKey = markdownCacheKey(version: version)
        if !forceRefresh, let cached = markdownCache[cacheKey] {
            return cached
        }

        // Try to load from disk cache first
        if !forceRefresh, let diskCached = await loadMarkdownFromDisk(version: version) {
            markdownCache[cacheKey] = diskCached
            return diskCached
        }

        guard let url = localizedURL(pathComponent: version) else {
            throw ChangelogServiceError.invalidURL
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ChangelogServiceError.networkError(URLError(.badServerResponse))
            }

            if httpResponse.statusCode == 404 {
                throw ChangelogServiceError.notFound
            }

            guard httpResponse.statusCode == 200 else {
                throw ChangelogServiceError.serverError(httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            let detailResponse = try decoder.decode(ChangelogDetailResponse.self, from: data)

            // Update cache
            markdownCache[cacheKey] = detailResponse.markdown

            // Persist to disk
            await persistMarkdownToDisk(version: version, markdown: detailResponse.markdown)

            return detailResponse.markdown
        } catch let error as ChangelogServiceError {
            throw error
        } catch let error as DecodingError {
            throw ChangelogServiceError.decodingError(error)
        } catch {
            throw ChangelogServiceError.networkError(error)
        }
    }

    /// Convert a remote index entry to a full ChangelogEntry
    func convertToChangelogEntry(_ indexEntry: ChangelogIndexEntry, markdown: String) -> ChangelogEntry? {
        guard let components = indexEntry.versionComponents,
              let date = indexEntry.parsedDate else {
            return nil
        }

        return ChangelogEntry(
            version: indexEntry.version,
            major: components.major,
            minor: components.minor,
            build: components.build,
            date: date,
            headerImageURLs: (indexEntry.headerImageURLs ?? []).compactMap { URL(string: $0) },
            markdownContent: markdown
        )
    }

    /// Clear all caches (useful for debugging or force refresh)
    func clearCaches() {
        indexCache = nil
        indexCacheTimestamp = nil
        indexCacheLocale = nil
        markdownCache.removeAll()

        // Also clear disk cache
        clearDiskCache()
    }

    /// Clear all cached files from disk
    private func clearDiskCache() {
        guard let cacheDir = cacheDirectory else { return }

        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: cacheDir.path) {
                let contents = try fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    try fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            print("⚠️ Failed to clear changelog disk cache: \(error)")
        }
    }

    /// Get cached index if available (for offline access)
    func getCachedIndex() async -> [ChangelogIndexEntry]? {
        if let cached = indexCache {
            return cached
        }
        return await loadIndexFromDisk()
    }

    // MARK: - Disk Persistence

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Changelogs", isDirectory: true)
    }

    private func ensureCacheDirectoryExists() {
        guard let cacheDir = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func persistIndexToDisk(_ entries: [ChangelogIndexEntry]) async {
        ensureCacheDirectoryExists()
        guard let cacheDir = cacheDirectory else { return }

        let fileURL = cacheDir.appendingPathComponent("index_\(currentLocale).json")

        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL)
        } catch {
            print("⚠️ Failed to persist changelog index: \(error)")
        }
    }

    private func loadIndexFromDisk() async -> [ChangelogIndexEntry]? {
        guard let cacheDir = cacheDirectory else { return nil }

        let fileURL = cacheDir.appendingPathComponent("index_\(currentLocale).json")

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([ChangelogIndexEntry].self, from: data)
        } catch {
            return nil
        }
    }

    private func persistMarkdownToDisk(version: String, markdown: String) async {
        ensureCacheDirectoryExists()
        guard let cacheDir = cacheDirectory else { return }

        let fileURL = cacheDir.appendingPathComponent("\(version)_\(currentLocale).md")

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ Failed to persist changelog markdown: \(error)")
        }
    }

    private func loadMarkdownFromDisk(version: String) async -> String? {
        guard let cacheDir = cacheDirectory else { return nil }

        let fileURL = cacheDir.appendingPathComponent("\(version)_\(currentLocale).md")

        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private func localizedURL(pathComponent: String? = nil) -> URL? {
        guard var components = URLComponents(string: baseURL) else {
            return nil
        }

        if let pathComponent, !pathComponent.isEmpty {
            components.path += "/\(pathComponent)"
        }

        components.queryItems = [
            URLQueryItem(name: "locale", value: currentLocale)
        ]
        return components.url
    }

    private func markdownCacheKey(version: String) -> String {
        "\(version)::\(currentLocale)"
    }

}
