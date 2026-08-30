//
//  ChangelogViewModel.swift
//  Joodle
//
//  Created by Claude on 2025.
//

import Foundation
import SwiftUI

/// ViewModel for managing changelog data and state
@MainActor
final class ChangelogViewModel: ObservableObject {

    // MARK: - Published Properties

    /// List of changelog index entries (lightweight, without full markdown)
    @Published private(set) var changelogIndex: [ChangelogIndexEntry] = []

    /// Full changelog entries with markdown content (loaded on demand)
    @Published private(set) var loadedEntries: [String: ChangelogEntry] = [:]

    /// Loading state for the index
    @Published private(set) var isLoadingIndex = false

    /// Loading state for individual changelog details
    @Published private(set) var loadingVersions: Set<String> = []

    /// Error state
    @Published var error: ChangelogServiceError?

    /// Whether an error alert should be shown
    @Published var showError = false

    // MARK: - Private Properties

    private let service = RemoteChangelogService.shared
    private let bundledData = ChangelogData.self

    // MARK: - Initialization

    init() {
        // Load bundled data as initial fallback
        loadBundledDataAsFallback()
    }

    // MARK: - Public Methods

    /// Fetch the changelog index from remote API
    func fetchChangelogIndex(forceRefresh: Bool = false) async {
        guard !isLoadingIndex else { return }

        isLoadingIndex = true
        error = nil

        do {
            let index = try await service.fetchChangelogIndex(forceRefresh: forceRefresh)
            changelogIndex = index
        } catch let serviceError as ChangelogServiceError {
            error = serviceError
            showError = true
            // Fall back to cached data if available
            await loadCachedIndexAsFallback()
        } catch {
            self.error = .networkError(error)
            showError = true
            await loadCachedIndexAsFallback()
        }

        isLoadingIndex = false
    }

    /// Fetch the full markdown content for a specific version
    func fetchChangelogDetail(for version: String, forceRefresh: Bool = false) async -> ChangelogEntry? {
        // Return cached entry if available
        if !forceRefresh, let cached = loadedEntries[version] {
            return cached
        }

        guard !loadingVersions.contains(version) else { return nil }

        loadingVersions.insert(version)

        defer {
            loadingVersions.remove(version)
        }

        // Find the index entry for metadata
        guard let indexEntry = changelogIndex.first(where: { $0.version == version }) else {
            // Try bundled fallback
            return bundledData.entry(for: version)
        }

        do {
            let markdown = try await service.fetchChangelogDetail(version: version, forceRefresh: forceRefresh)

            if let entry = await service.convertToChangelogEntry(indexEntry, markdown: markdown) {
                loadedEntries[version] = entry
                return entry
            }
        } catch {
            print("⚠️ Failed to fetch changelog detail for \(version): \(error)")
            // Fall back to bundled data
            if let bundled = bundledData.entry(for: version) {
                return bundled
            }
        }

        return nil
    }

    /// Get a changelog entry, loading from cache or fetching if needed
    func getEntry(for version: String) -> ChangelogEntry? {
        // Check memory cache first
        if let cached = loadedEntries[version] {
            return cached
        }

        // Check bundled fallback
        return bundledData.entry(for: version)
    }

    /// Check if a version's detail is currently loading
    func isLoading(version: String) -> Bool {
        loadingVersions.contains(version)
    }

    /// Refresh all data (clears cache and fetches fresh data)
    func clearCacheAndRefresh() async {
        // Clear the remote service's caches
        await service.clearCaches()

        // Clear local loaded entries cache
        loadedEntries.removeAll()

        // Fetch fresh data
        await fetchChangelogIndex(forceRefresh: true)
    }

    /// Get the latest changelog entry
    var latestEntry: ChangelogIndexEntry? {
        changelogIndex.first
    }

    /// The index entry covering the running app's release, if the server has one
    private var currentReleaseIndexEntry: ChangelogIndexEntry? {
        changelogIndex.first {
            VersionComparator.isSameRelease($0.version, AppEnvironment.fullVersionString)
        }
    }

    /// Check if there's a changelog for the current app version
    func hasChangelogForCurrentVersion() -> Bool {
        currentReleaseIndexEntry != nil ||
        bundledData.entry(for: AppEnvironment.fullVersionString) != nil
    }

    /// Get changelog for current app version
    func getCurrentVersionChangelog() async -> ChangelogEntry? {
        guard let version = currentReleaseIndexEntry?.version else {
            return bundledData.entry(for: AppEnvironment.fullVersionString)
        }
        return await fetchChangelogDetail(for: version)
    }

    // MARK: - Private Methods

    /// Load bundled changelog data as initial fallback
    private func loadBundledDataAsFallback() {
        // Convert bundled entries to index entries for consistent display
        let bundledEntries = bundledData.entries

        // Create index entries from bundled data
        let indexEntries = bundledEntries.map { entry in
            ChangelogIndexEntry(
                version: entry.version,
                date: formatDate(entry.date),
                headerImageURLs: entry.headerImageURLs.isEmpty ? nil : entry.headerImageURLs.map(\.absoluteString)
            )
        }

        // Also store full entries in loaded cache
        for entry in bundledEntries {
            loadedEntries[entry.version] = entry
        }

        // Only use bundled if we don't have remote data
        if changelogIndex.isEmpty {
            changelogIndex = indexEntries
        }
    }

    /// Load cached index as fallback when network fails
    private func loadCachedIndexAsFallback() async {
        if let cached = await service.getCachedIndex() {
            changelogIndex = cached
        } else {
            // Fall back to bundled data
            loadBundledDataAsFallback()
        }
    }

    /// Format a Date to the expected string format
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Convenience Extensions

extension ChangelogViewModel {
    /// Create a changelog entry from an index entry (for preview/list purposes)
    func createPlaceholderEntry(from indexEntry: ChangelogIndexEntry) -> ChangelogEntry? {
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
            markdownContent: "" // Empty until loaded
        )
    }
}
