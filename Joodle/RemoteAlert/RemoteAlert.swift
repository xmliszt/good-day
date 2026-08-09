//
//  RemoteAlert.swift
//  Joodle
//
//  Created by Claude on 2025.
//

import Foundation
import SwiftUI

// MARK: - API Response

/// Response wrapper from the remote alert API endpoint
struct RemoteAlertResponse: Codable {
    let alert: RemoteAlert?
}

// MARK: - Remote Alert Model

/// A remote alert that can be displayed to users without an app update
struct RemoteAlert: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let primaryButton: AlertButton
    let secondaryButton: AlertButton?
    let imageURL: String?
    let type: AnnouncementType

    /// Locales this alert targets. nil or empty means show to all locales.
    /// When non-empty, only devices whose resolved locale code is in this list see the alert.
    let locales: [String]?

    init(
        id: String,
        title: String,
        message: String,
        primaryButton: AlertButton,
        secondaryButton: AlertButton? = nil,
        imageURL: String? = nil,
        type: AnnouncementType,
        locales: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.primaryButton = primaryButton
        self.secondaryButton = secondaryButton
        self.imageURL = imageURL
        self.type = type
        self.locales = locales
    }

    // MARK: - Announcement Type

    /// The type of announcement, used to filter based on user preferences
    enum AnnouncementType: String, Codable, CaseIterable, Identifiable {
        case promo       // Promotional content, sales, etc.
        case community   // Social media, community events
        case tips        // App tips, feature highlights, tutorials

        var id: String { rawValue }

        var displayName: LocalizedStringResource {
            switch self {
            case .promo: return "Promotions"
            case .community: return "Community"
            case .tips: return "Tips & Tutorials"
            }
        }

        var description: LocalizedStringResource {
            switch self {
            case .promo: return "Special offers and promotions"
            case .community: return "Events and community updates"
            case .tips: return "App tips and tutorials"
            }
        }

        var iconName: String {
            switch self {
            case .promo: return "tag.fill"
            case .community: return "person.2.fill"
            case .tips: return "lightbulb.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .promo: return .orange
            case .community: return .purple
            case .tips: return .yellow
            }
        }
    }

    // MARK: - Alert Button

    struct AlertButton: Codable, Equatable {
        let text: String
        let url: String?  // nil means just dismiss

        /// Whether this button has an associated action URL
        var hasAction: Bool {
            url != nil && !url!.isEmpty
        }
    }
}

// MARK: - Equatable

extension RemoteAlert {
    static func == (lhs: RemoteAlert, rhs: RemoteAlert) -> Bool {
        lhs.id == rhs.id
    }
}
