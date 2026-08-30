//
//  ChangelogManager.swift
//  Joodle
//
//  Created by Claude on 2025.
//

import Foundation

/// Manages changelog display state and determines when to show "What's New" modals
@MainActor
final class ChangelogManager: ObservableObject {
    static let shared = ChangelogManager()

    // MARK: - Published Properties

    /// The changelog entry to display (if any)
    @Published private(set) var changelogToShow: ChangelogEntry?

    /// Whether the changelog modal should be presented
    @Published var shouldShowChangelog = false

    /// Loading state for fetching remote changelog
    @Published private(set) var isLoading = false

    // MARK: - Private Properties

    private let defaults = UserDefaults.standard
    private let lastSeenVersionKey = "changelog_last_seen_version"
    private let remoteService = RemoteChangelogService.shared

    private init() {}

    // MARK: - User Defaults

    /// Last version whose changelog was displayed
    var lastSeenVersion: String? {
        get { defaults.string(forKey: lastSeenVersionKey) }
        set { defaults.set(newValue, forKey: lastSeenVersionKey) }
    }

    // MARK: - Public Methods

    /// Whether this launch owes the user a changelog at all.
    ///
    /// Only reads flags — no network — so a presenter can reserve its place
    /// before spending a fetch on *which* notes to show. Whether content is
    /// actually available is a separate question, answered by
    /// `checkAndPrepareChangelog()`.
    var isChangelogDue: Bool {
        guard defaults.bool(forKey: "hasCompletedOnboarding") else { return false }
        return !hasSeenChangelog(for: AppEnvironment.fullVersionString)
    }

    /// Check and prepare changelog for display if needed
    /// Call this on app launch after onboarding is complete
    func checkAndPrepareChangelog() async {
        let currentVersion = AppEnvironment.fullVersionString
        let hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")

        print("📋 [Changelog Debug]")
        print("   Current app version: '\(currentVersion)'")
        print("   Has completed onboarding: \(hasCompletedOnboarding)")
        print("   Last seen version: \(lastSeenVersion ?? "nil")")

        // Don't show during first launch (onboarding handles that)
        guard hasCompletedOnboarding else {
            print("   ❌ Skipping: Onboarding not completed")
            return
        }

        // Check if we've already seen this version
        if hasSeenChangelog(for: currentVersion) {
            print("   ❌ Skipping: Already seen changelog for \(currentVersion)")
            return
        }

        // Try to fetch remote changelog first
        isLoading = true

        if let entry = await fetchChangelogForVersion(currentVersion) {
            changelogToShow = entry
            shouldShowChangelog = true
            print("   ✅ Showing changelog for version \(currentVersion)")
        } else {
            print("   ❌ No changelog available for version \(currentVersion)")
        }

        isLoading = false
    }

    /// Fetch changelog for a specific version (remote first, then bundled fallback)
    func fetchChangelogForVersion(_ version: String) async -> ChangelogEntry? {
        // Try remote first
        do {
            // Fetch index to get metadata
            let index = try await remoteService.fetchChangelogIndex()

            guard let indexEntry = index.first(where: {
                VersionComparator.isSameRelease($0.version, version)
            }) else {
                print("   ⚠️ Version \(version) not found in remote index, trying bundled...")
                return ChangelogData.entry(for: version)
            }

            // Fetch full markdown content, keyed by the index's own version so the
            // request works whether or not the server still carries a build number
            let markdown = try await remoteService.fetchChangelogDetail(version: indexEntry.version)

            if let entry = await remoteService.convertToChangelogEntry(indexEntry, markdown: markdown) {
                return entry
            }
        } catch {
            print("   ⚠️ Failed to fetch remote changelog: \(error.localizedDescription)")
        }

        // Fall back to bundled data
        return ChangelogData.entry(for: version)
    }

    /// Mark current version's changelog as seen
    func markCurrentVersionAsSeen() {
        lastSeenVersion = AppEnvironment.fullVersionString
        shouldShowChangelog = false
        changelogToShow = nil
        print("📋 Marked changelog as seen for version: \(AppEnvironment.fullVersionString)")
    }

    /// Check if a specific version's changelog has been seen
    func hasSeenChangelog(for version: String) -> Bool {
        // Compared per release, so a rebuild of the same release doesn't re-present a
        // changelog the user has already read
        guard let lastSeen = lastSeenVersion else { return false }
        return VersionComparator.isSameOrOlderRelease(version, lastSeen)
    }

    /// Dismiss the changelog without marking as seen (user can see it again)
    func dismissChangelog() {
        shouldShowChangelog = false
    }

    /// Reset changelog state for testing
    func resetChangelogState() {
        lastSeenVersion = nil
        changelogToShow = nil
        shouldShowChangelog = false
    }

    /// Force a specific version as last seen for testing
    func setLastSeenVersion(_ version: String?) {
        lastSeenVersion = version
    }

    // MARK: - Legacy Support

    /// Check if we should show changelog (synchronous, uses bundled data only)
    /// Use `checkAndPrepareChangelog()` for async remote support
    var shouldShowChangelogSync: Bool {
        let currentVersion = AppEnvironment.fullVersionString
        let hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")

        guard hasCompletedOnboarding else { return false }
        guard ChangelogData.entry(for: currentVersion) != nil else { return false }
        guard lastSeenVersion != nil else { return true }

        return !hasSeenChangelog(for: currentVersion)
    }

    /// Get the changelog entry to display synchronously (bundled data only)
    var changelogToShowSync: ChangelogEntry? {
        guard shouldShowChangelogSync else { return nil }
        return ChangelogData.entry(for: AppEnvironment.fullVersionString)
    }

}
