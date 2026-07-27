//
//  AppChrome.swift
//  Joodle
//
//  Window-level appearance that a single screen needs to bend.
//

import SwiftUI

/// Lets one screen commit the window to a color scheme, overriding the user's
/// appearance preference for as long as it is on screen.
///
/// This has to be read at the scene root: `preferredColorScheme` is a
/// preference, and the value the root writes replaces anything a pushed screen
/// asks for. A screen can force its own *content* dark with
/// `environment(\.colorScheme, …)`, but system chrome — most visibly the status
/// bar glyphs — only follows the root, which is what this carries.
@MainActor
final class AppChrome: ObservableObject {
  static let shared = AppChrome()

  /// Non-nil while a screen is forcing a scheme; nil hands the window back to
  /// the user's preference.
  @Published var forcedColorScheme: ColorScheme?

  private init() {}
}

extension View {
  /// Forces the window's color scheme while this view is on screen, restoring
  /// the user's preference when it goes away.
  func forcedWindowColorScheme(_ scheme: ColorScheme) -> some View {
    onAppear { AppChrome.shared.forcedColorScheme = scheme }
      .onDisappear { AppChrome.shared.forcedColorScheme = nil }
  }
}
