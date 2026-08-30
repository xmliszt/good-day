//
//  AppEnvironment.swift
//  Joodle
//
//  Utility for detecting app environment (Debug, TestFlight, Production)
//

import Foundation
import StoreKit

/// Utility for detecting the current app environment
enum AppEnvironment {
    case debug
    case testFlight
    case appStore

    // MARK: - Production Simulation

    /// When true, the app behaves as if it's running in production (App Store)
    /// This is only effective in non-production environments (Debug/TestFlight)
    static var simulateProductionEnvironment: Bool = false

    /// The current app environment (considering simulation)
    static var current: AppEnvironment {
        if simulateProductionEnvironment && isActuallyNonProduction {
            return .appStore
        }
        return actualEnvironment
    }

    /// The actual app environment (ignoring simulation)
    static var actualEnvironment: AppEnvironment {
        #if DEBUG
        return .debug
        #else
        if isTestFlight {
            return .testFlight
        } else {
            return .appStore
        }
        #endif
    }

    /// Whether the app is actually running in a non-production environment (ignoring simulation)
    static var isActuallyNonProduction: Bool {
        #if DEBUG
        return true
        #else
        return isTestFlight
        #endif
    }

    /// Whether the app is running in TestFlight
    static var isTestFlight: Bool {
        _isTestFlightCached
    }

    /// Cached TestFlight status (updated at startup via initialize())
    private static var _isTestFlightCached: Bool = false

    /// Initialize the environment detection - call this at app launch
    static func initialize() {
        Task {
            await updateTestFlightStatus()
        }
    }

    /// Updates the TestFlight status using appropriate API for the iOS version
    private static func updateTestFlightStatus() async {
        if #available(iOS 18.0, *) {
            // Use modern StoreKit API for iOS 18+
            do {
                let verification = try await AppTransaction.shared
                if case .verified(let transaction) = verification {
                    let environment = transaction.environment
                    _isTestFlightCached = (environment == .xcode || environment == .sandbox)
                }
            } catch {
                // Fallback: assume not TestFlight if we can't verify
                print("AppEnvironment: Failed to verify app transaction: \(error)")
                _isTestFlightCached = false
            }
        } else {
            // Legacy method for iOS < 18
            if let receiptURL = Bundle.main.appStoreReceiptURL {
                _isTestFlightCached = receiptURL.lastPathComponent == "sandboxReceipt"
            } else {
                _isTestFlightCached = false
            }
        }
    }

    /// Whether the app is running in production (App Store) - considers simulation
    static var isAppStore: Bool {
        if simulateProductionEnvironment && isActuallyNonProduction {
            return true
        }
        #if DEBUG
        return false
        #else
        return !isTestFlight
        #endif
    }

    /// Whether the app is running in debug mode - considers simulation
    static var isDebug: Bool {
        if simulateProductionEnvironment {
            return false
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Whether we're currently simulating production in a non-production environment
    static var isSimulatingProduction: Bool {
        simulateProductionEnvironment && isActuallyNonProduction
    }

    /// Human-readable description of the current environment
    static var displayName: String {
        switch current {
        case .debug:
            return String(localized: "Debug")
        case .testFlight:
            return String(localized: "TestFlight")
        case .appStore:
            return String(localized: "App Store")
        }
    }

    /// App version string (e.g., "1.0.0")
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// Build number string (e.g., "42")
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// Full version string (e.g., "1.0.42")
    static var fullVersionString: String {
        "\(appVersion).\(buildNumber)"
    }

    static var fullVersionDisplayString: String {
        "\(appVersion) (\(buildNumber))"
    }

    /// Bundle identifier
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    // MARK: - Content API

    /// Origin serving the Joodle content APIs.
    ///
    /// Debug builds honour a `JOODLE_API_BASE_URL` environment variable so the app can
    /// run against a local portfolio dev server — the shared scheme sets it. Release
    /// builds always use production; the override cannot be compiled in.
    static var apiBaseURL: String {
        #if DEBUG
        let override = ProcessInfo.processInfo.environment["JOODLE_API_BASE_URL"] ?? ""
        if !override.isEmpty {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        #endif
        return "https://liyuxuan.dev"
    }

    // MARK: - Feedback URLs

    /// The App Store ID for the app (update this with your actual App Store ID)
    private static let appStoreID = "6756204776"

    /// URL to open TestFlight for submitting feedback
    static var testFlightFeedbackURL: URL? {
        // This URL scheme opens TestFlight app directly
        // The beta-app path opens the current app's TestFlight page
        URL(string: "itms-beta://")
    }

    /// URL to open App Store for writing a review
    static var appStoreReviewURL: URL? {
        URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }

    /// The appropriate feedback URL based on current environment
    static var feedbackURL: URL? {
        switch current {
        case .debug, .testFlight:
            return testFlightFeedbackURL
        case .appStore:
            return appStoreReviewURL
        }
    }

    /// The label text for the feedback button
    static var feedbackButtonTitle: LocalizedStringResource {
        switch current {
        case .debug, .testFlight:
            return "Submit Testing Feedback"
        case .appStore:
            return "Write a Review"
        }
    }

    /// The icon name for the feedback button
    static var feedbackButtonIcon: String {
        switch current {
        case .debug, .testFlight:
            return "bubble.left.and.exclamationmark.bubble.right.fill"
        case .appStore:
            return "star.fill"
        }
    }
}
