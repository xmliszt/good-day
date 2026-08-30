//
//  ChangelogEntry.swift
//  Joodle
//
//  Created by Claude on 2025.
//

import Foundation

/// Represents a single changelog entry for a specific app version
struct ChangelogEntry: Identifiable, Hashable {
    /// Unique identifier (uses version string)
    let id: String

    /// Full version string (e.g., "1.0.55")
    let version: String

    /// Major version number
    let major: Int

    /// Minor version number
    let minor: Int

    /// Build number, for releases published before 2.11 carried it in the version
    let build: Int?

    /// Release date
    let date: Date

    /// Remote image URLs displayed below the header. May contain 0, 1, or many entries.
    let headerImageURLs: [URL]

    /// Markdown formatted changelog content
    let markdownContent: String

    // MARK: - Formatted Display Properties

    /// Formatted version for display: "1.0"
    var displayVersion: String {
        "\(major).\(minor)"
    }

    /// Formatted header line: "DECEMBER 25, 2025 · VERSION 1.0"
    var displayHeader: String {
        let dateFormatter = DateFormatter()
        dateFormatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        let dateString = dateFormatter.string(from: date).uppercased()
        return "\(dateString) · VERSION \(displayVersion)"
    }

    init(
        version: String,
        major: Int,
        minor: Int,
        build: Int? = nil,
        date: Date,
        headerImageURLs: [URL] = [],
        markdownContent: String
    ) {
        self.id = version
        self.version = version
        self.major = major
        self.minor = minor
        self.build = build
        self.date = date
        self.headerImageURLs = headerImageURLs
        self.markdownContent = markdownContent
    }
}
