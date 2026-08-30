//
//  VersionComparator.swift
//  Joodle
//
//  Shared utility for comparing semantic version strings.
//

import Foundation

/// Utility for comparing semantic version strings (e.g., "1.0.55" vs "1.0.56")
enum VersionComparator {

    /// Compare two version strings
    /// - Parameters:
    ///   - v1: First version string (e.g., "1.0.55")
    ///   - v2: Second version string (e.g., "1.0.56")
    /// - Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
    static func compare(_ v1: String, _ v2: String) -> Int {
        let v1Parts = v1.split(separator: ".").compactMap { Int($0) }
        let v2Parts = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(v1Parts.count, v2Parts.count) {
            let p1 = i < v1Parts.count ? v1Parts[i] : 0
            let p2 = i < v2Parts.count ? v2Parts[i] : 0
            if p1 < p2 { return -1 }
            if p1 > p2 { return 1 }
        }
        return 0
    }

    /// Check if v1 is less than v2
    static func isLessThan(_ v1: String, _ v2: String) -> Bool {
        compare(v1, v2) < 0
    }

    /// Check if v1 is greater than v2
    static func isGreaterThan(_ v1: String, _ v2: String) -> Bool {
        compare(v1, v2) > 0
    }

    /// Check if v1 equals v2
    static func isEqual(_ v1: String, _ v2: String) -> Bool {
        compare(v1, v2) == 0
    }

    /// Check if v1 is less than or equal to v2
    static func isLessThanOrEqual(_ v1: String, _ v2: String) -> Bool {
        compare(v1, v2) <= 0
    }

    /// Check if v1 is greater than or equal to v2
    static func isGreaterThanOrEqual(_ v1: String, _ v2: String) -> Bool {
        compare(v1, v2) >= 0
    }

    // MARK: - Release-level comparison

    /// The `major.minor` release a version belongs to, dropping any build component.
    ///
    /// A changelog is published once per release, so the build is not part of its
    /// identity. Server-side versions are `major.minor` from 2.11 onward and
    /// `major.minor.build` before it; both reduce to the same release here.
    static func release(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Compare the releases that two version strings belong to
    static func compareReleases(_ v1: String, _ v2: String) -> Int {
        compare(release(v1), release(v2))
    }

    /// Check if v1 and v2 belong to the same release
    static func isSameRelease(_ v1: String, _ v2: String) -> Bool {
        compareReleases(v1, v2) == 0
    }

    /// Check if v1's release is older than v2's
    static func isOlderRelease(_ v1: String, _ v2: String) -> Bool {
        compareReleases(v1, v2) < 0
    }

    /// Check if v1's release is the same as or older than v2's
    static func isSameOrOlderRelease(_ v1: String, _ v2: String) -> Bool {
        compareReleases(v1, v2) <= 0
    }
}
