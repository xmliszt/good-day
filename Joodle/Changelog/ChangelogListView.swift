//
//  ChangelogListView.swift
//  Joodle
//
//  Created by Claude on 2025.
//

import SwiftUI

/// A list view showing all past changelogs, accessible from Settings
struct ChangelogListView: View {
    @StateObject private var viewModel = ChangelogViewModel()

    /// Check if the current app version is outdated compared to the latest changelog
    private var isAppOutdated: Bool {
        guard let latestVersion = viewModel.latestEntry?.version else {
            return false
        }
        let currentVersion = AppEnvironment.fullVersionString
        return VersionComparator.isOlderRelease(currentVersion, latestVersion)
    }

    /// The latest available version string for display
    private var latestVersionDisplay: String? {
        viewModel.latestEntry?.displayVersion
    }

    var body: some View {
        Group {
            if viewModel.isLoadingIndex && viewModel.changelogIndex.isEmpty {
                // Initial loading state
                ProgressView("Loading changelogs...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.changelogIndex.isEmpty {
                // Empty state
                ContentUnavailableView(
                    "No Changelogs",
                    systemImage: "doc.text",
                    description: Text("Check back later for updates.")
                )
            } else {
                // Changelog list
                List {
                    // Update available banner
                    if isAppOutdated {
                        Section {
                            UpdateAvailableBanner(latestVersion: latestVersionDisplay)
                        }
                    }

                    Section {
                        ForEach(viewModel.changelogIndex) { indexEntry in
                            NavigationLink {
                                ChangelogDetailLoadingView(
                                    indexEntry: indexEntry,
                                    viewModel: viewModel
                                )
                                .navigationTitle("Version \(indexEntry.displayVersion)")
                                .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                ChangelogRowView(
                                    indexEntry: indexEntry,
                                    isCurrentVersion: VersionComparator.isSameRelease(
                                        indexEntry.version,
                                        AppEnvironment.fullVersionString
                                    )
                                )
                            }
                        }
                    }
                }
                .refreshable {
                    await viewModel.clearCacheAndRefresh()
                }
            }
        }
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
        .postHogScreenView("Changelog")
        .task {
            await viewModel.fetchChangelogIndex()
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
            Button("Retry") {
                Task {
                    await viewModel.fetchChangelogIndex(forceRefresh: true)
                }
            }
        } message: {
            Text(viewModel.error?.localizedDescription ?? "An unknown error occurred")
        }
    }
}

// MARK: - Update Available Banner

private struct UpdateAvailableBanner: View {
    let latestVersion: String?

    private let appStoreURL = URL(string: "https://apps.apple.com/sg/app/joodle-journaling-with-doodle/id6756204776")!

    var body: some View {
        Button {
            UIApplication.shared.open(appStoreURL)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.appTitle2())
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Download New Version")
                        .font(.appHeadline())
                        .foregroundStyle(.white)

                    if let version = latestVersion {
                        Text("Version \(version) is now available")
                            .font(.appSubheadline())
                            .foregroundStyle(.white.opacity(0.9))
                    } else {
                        Text("A new version is available")
                            .font(.appSubheadline())
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.appBody(weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [.appAccent, .appAccent.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowBackground(Color.clear)
    }
}

// MARK: - Changelog Row View

private struct ChangelogRowView: View {
    let indexEntry: ChangelogIndexEntry
    let isCurrentVersion: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Version \(indexEntry.displayVersion)")
                    .font(.appHeadline())

                if let date = indexEntry.parsedDate {
                  Text(date, style: .date)
                        .font(.appSubheadline())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            Spacer()

            // Show "Current" badge if this is the running app version
            if isCurrentVersion {
                Text("Current")
                    .font(.appCaption())
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.appAccent.opacity(0.2))
                    .foregroundStyle(.appAccent)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Changelog Detail Loading View

/// Wrapper view that handles loading the full changelog detail
private struct ChangelogDetailLoadingView: View {
    let indexEntry: ChangelogIndexEntry
    @ObservedObject var viewModel: ChangelogViewModel

    @State private var entry: ChangelogEntry?
    @State private var isLoading = true
    @State private var loadError: Error?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let entry = entry {
                ChangelogDetailView(entry: entry)
            } else if loadError != nil {
                ContentUnavailableView(
                    "Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Could not load changelog content.")
                )
            } else {
                ContentUnavailableView(
                    "Not Found",
                    systemImage: "doc.text",
                    description: Text("Changelog content is unavailable.")
                )
            }
        }
        .task {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        isLoading = true
        loadError = nil

        // First check if we already have the full entry cached
        if let cached = viewModel.loadedEntries[indexEntry.version] {
            entry = cached
            isLoading = false
            return
        }

        // Fetch from remote
      entry = await viewModel.fetchChangelogDetail(for: indexEntry.version)

        isLoading = false
    }
}

#Preview {
    NavigationStack {
        ChangelogListView()
    }
}
