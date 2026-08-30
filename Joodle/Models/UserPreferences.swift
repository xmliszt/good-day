//
//  UserPreferences.swift
//  Joodle
//
//  Created by Li Yuxuan on 11/8/25.
//

import Foundation
import Observation
import SwiftUI

enum Pref {
  // MARK: - Step 1: Register Pref key here.
  static let defaultViewMode = Key(key: "default_view_mode", default: ViewMode.now)
  static let preferredColorScheme = Key<ColorScheme?>(key: "preferred_color_scheme", default: nil)
  static let enableHaptic = Key(key: "enable_haptic", default: true)
  static let isCloudSyncEnabled = Key(key: "is_cloud_sync_enabled", default: true)
  static let accentColor = Key(key: "accent_color", default: ThemeColor.defaultColor)
  static let isDailyReminderEnabled = Key(key: "is_daily_reminder_enabled", default: false)
  // Default to 9:00 AM - stored as seconds from midnight
  static let dailyReminderTimeSeconds = Key(key: "daily_reminder_time_seconds", default: 9 * 3600)
  // Start of week: "sunday" or "monday"
  static let startOfWeek = Key(key: "start_of_week", default: "sunday")

  // Which side the camera zoom slider appears on
  static let cameraZoomSliderHandedness = Key(key: "camera_zoom_slider_handedness", default: SliderHandedness.right)

  // Auto trace (Pro): master toggle, plus the detail level a single tap traces at.
  static let isAutoTraceEnabled = Key(key: "is_auto_trace_enabled", default: false)
  static let autoTraceDefaultDetail = Key(key: "auto_trace_default_detail", default: AutoTraceDetail.default.rawValue)

  // Experimental features
  static let enableTimeBackdrop = Key(key: "enable_time_backdrop", default: false)
  static let enableWigglyStrokes = Key(key: "enable_wiggly_strokes", default: false)

  // Announcements
  static let announcementsEnabled = Key(key: "announcements_enabled", default: true)
  static let announcementPromoEnabled = Key(key: "announcement_promo_enabled", default: true)
  static let announcementCommunityEnabled = Key(key: "announcement_community_enabled", default: true)
  static let announcementTipsEnabled = Key(key: "announcement_tips_enabled", default: true)

  // Notes prompt after doodling
  static let promptForNotesAfterDoodling = Key(key: "prompt_for_notes_after_doodling", default: true)

  // Share card watermark preference
  static let shareCardWatermarkEnabled = Key(key: "share_card_watermark_enabled", default: true)

  // Save captured reference photo to the user's Photos album. The single source
  // of truth for the feature: ON means "the user wants saving — ensure Photos
  // add-only access (prompt lazily on the next capture if undetermined)"; OFF
  // means "the user does not want saving" (a deliberate choice, including a
  // denied permission prompt). The add-only permission is resolved at capture
  // time, never proactively. Default ON.
  static let saveCapturedPhotoToAlbum = Key(key: "save_captured_photo_to_album", default: true)

  // One-time marker: this build force-enabled save-to-album for everyone (see
  // `forceSaveToAlbumOnIfNeeded()`). Guards the force-on so it runs exactly once
  // and never overrides a choice the user makes afterwards.
  static let didForceSaveToAlbumOn = Key(key: "did_force_save_to_album_on", default: false)

  // App language override (empty string = system default)
  static let appLanguage = Key(key: "app_language", default: "")

  // Add new preferences here - just specify the default!
  // static let newSetting = Key(default: "defaultValue")

  struct Key<T> {
    let key: String
    let defaultValue: T

    init(key: String, default defaultValue: T) {
      self.key = key
      self.defaultValue = defaultValue
    }
  }

  // Auto-generated list of all keys for reset
  // MARK: - Step 2: Add your key here
  static let allKeys = [
    defaultViewMode.key,
    preferredColorScheme.key,
    enableHaptic.key,
    isCloudSyncEnabled.key,
    accentColor.key,
    isDailyReminderEnabled.key,
    dailyReminderTimeSeconds.key,
    startOfWeek.key,
    cameraZoomSliderHandedness.key,
    isAutoTraceEnabled.key,
    autoTraceDefaultDetail.key,
    enableTimeBackdrop.key,
    enableWigglyStrokes.key,
    announcementsEnabled.key,
    announcementPromoEnabled.key,
    announcementCommunityEnabled.key,
    announcementTipsEnabled.key,
    promptForNotesAfterDoodling.key,
    shareCardWatermarkEnabled.key,
    saveCapturedPhotoToAlbum.key,
    didForceSaveToAlbumOn.key,
    appLanguage.key,
  ]
}

// MARK: - UserPreferences
@Observable
final class UserPreferences {

  // MARK: - Singleton
  static let shared = UserPreferences()
  private let defaults = UserDefaults.standard

  // MARK: - Helper Methods
  private func get<T>(_ key: Pref.Key<T>) -> T {
    defaults.object(forKey: key.key) as? T ?? key.defaultValue
  }

  private func set<T>(_ key: Pref.Key<T>, _ value: T?) {
    if let value {
      defaults.set(value, forKey: key.key)
    } else {
      defaults.removeObject(forKey: key.key)
    }
  }

  // MARK: - Step 3: Add your property here to be exposed to public
  var defaultViewMode: ViewMode = Pref.defaultViewMode.defaultValue {
    didSet {
      _defaultViewModeWatcher = defaultViewMode
    }
  }
  var preferredColorScheme: ColorScheme? = Pref.preferredColorScheme.defaultValue {
    didSet {
      _preferredColorSchemeWatcher = preferredColorScheme
    }
  }
  var enableHaptic: Bool = Pref.enableHaptic.defaultValue {
    didSet {
      _enableHapticWatcher = enableHaptic
    }
  }
  var isCloudSyncEnabled: Bool = Pref.isCloudSyncEnabled.defaultValue {
    didSet { _isCloudSyncEnabledWatcher = isCloudSyncEnabled }
  }
  var accentColor: ThemeColor = Pref.accentColor.defaultValue {
    didSet {
      _accentColorWatcher = accentColor
      // Notify the app to update the accent color
      NotificationCenter.default.post(name: .didChangeAccentColor, object: nil)
    }
  }
  var isDailyReminderEnabled: Bool = Pref.isDailyReminderEnabled.defaultValue {
    didSet {
      _isDailyReminderEnabledWatcher = isDailyReminderEnabled
    }
  }
  var dailyReminderTimeSeconds: Int = Pref.dailyReminderTimeSeconds.defaultValue {
    didSet {
      _dailyReminderTimeSecondsWatcher = dailyReminderTimeSeconds
    }
  }
  var startOfWeek: String = Pref.startOfWeek.defaultValue {
    didSet {
      _startOfWeekWatcher = startOfWeek
    }
  }
  var cameraZoomSliderHandedness: SliderHandedness = Pref.cameraZoomSliderHandedness.defaultValue {
    didSet {
      _cameraZoomSliderHandednessWatcher = cameraZoomSliderHandedness
    }
  }

  // Auto trace
  var isAutoTraceEnabled: Bool = Pref.isAutoTraceEnabled.defaultValue {
    didSet {
      _isAutoTraceEnabledWatcher = isAutoTraceEnabled
    }
  }
  var autoTraceDefaultDetail: AutoTraceDetail = AutoTraceDetail.default {
    didSet {
      _autoTraceDefaultDetailWatcher = autoTraceDefaultDetail
    }
  }

  // Experimental features
  var enableTimeBackdrop: Bool = Pref.enableTimeBackdrop.defaultValue {
    didSet {
      _enableTimeBackdropWatcher = enableTimeBackdrop
    }
  }
  var enableWigglyStrokes: Bool = Pref.enableWigglyStrokes.defaultValue {
    didSet {
      _enableWigglyStrokesWatcher = enableWigglyStrokes
    }
  }

  // Announcements
  var announcementsEnabled: Bool = Pref.announcementsEnabled.defaultValue {
    didSet {
      _announcementsEnabledWatcher = announcementsEnabled
    }
  }
  var announcementPromoEnabled: Bool = Pref.announcementPromoEnabled.defaultValue {
    didSet {
      _announcementPromoEnabledWatcher = announcementPromoEnabled
    }
  }
  var announcementCommunityEnabled: Bool = Pref.announcementCommunityEnabled.defaultValue {
    didSet {
      _announcementCommunityEnabledWatcher = announcementCommunityEnabled
    }
  }
  var announcementTipsEnabled: Bool = Pref.announcementTipsEnabled.defaultValue {
    didSet {
      _announcementTipsEnabledWatcher = announcementTipsEnabled
    }
  }

  // Notes prompt after doodling
  var promptForNotesAfterDoodling: Bool = Pref.promptForNotesAfterDoodling.defaultValue {
    didSet {
      _promptForNotesAfterDoodlingWatcher = promptForNotesAfterDoodling
    }
  }

  // Share card watermark preference
  var shareCardWatermarkEnabled: Bool = Pref.shareCardWatermarkEnabled.defaultValue {
    didSet {
      _shareCardWatermarkEnabledWatcher = shareCardWatermarkEnabled
    }
  }

  // Save captured reference photo to Photos album
  var saveCapturedPhotoToAlbum: Bool = Pref.saveCapturedPhotoToAlbum.defaultValue {
    didSet {
      _saveCapturedPhotoToAlbumWatcher = saveCapturedPhotoToAlbum
    }
  }

  // App language override
  var appLanguage: String = Pref.appLanguage.defaultValue {
    didSet {
      _appLanguageWatcher = appLanguage
      // Only sync AppleLanguages when the user actively changes the language,
      // not during init (which would overwrite a change made via iOS Settings).
      guard !_isInitializing else { return }
      if appLanguage.isEmpty {
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
      } else {
        UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
      }
      NotificationCenter.default.post(name: .didChangeAppLanguage, object: nil)
    }
  }

  /// Suppresses AppleLanguages side-effects during init.
  private var _isInitializing = true

  /// Convenience computed property to get/set daily reminder time as Date
  var dailyReminderTime: Date {
    get {
      let hour = dailyReminderTimeSeconds / 3600
      let minute = (dailyReminderTimeSeconds % 3600) / 60
      var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
      components.hour = hour
      components.minute = minute
      return Calendar.current.date(from: components) ?? Date()
    }
    set {
      let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
      dailyReminderTimeSeconds = (components.hour ?? 9) * 3600 + (components.minute ?? 0) * 60
    }
  }

  // MARK: - Step 4: Add private watchers that update UserDefaults when properties change
  private var _defaultViewModeWatcher: ViewMode {
    get {
      if let rawValue = defaults.string(forKey: Pref.defaultViewMode.key),
         let mode = ViewMode(rawValue: rawValue)
      {
        return mode
      }
      return Pref.defaultViewMode.defaultValue
    }
    set {
      defaults.set(newValue.rawValue, forKey: Pref.defaultViewMode.key)
    }
  }

  private var _preferredColorSchemeWatcher: ColorScheme? {
    get {
      if let rawValue = defaults.string(forKey: Pref.preferredColorScheme.key) {
        return rawValue == "light" ? .light : rawValue == "dark" ? .dark : nil
      }
      return Pref.preferredColorScheme.defaultValue
    }
    set {
      if let scheme = newValue {
        defaults.set(scheme == .light ? "light" : "dark", forKey: Pref.preferredColorScheme.key)
      } else {
        defaults.removeObject(forKey: Pref.preferredColorScheme.key)
      }
    }
  }

  private var _enableHapticWatcher: Bool {
    get { get(Pref.enableHaptic) }
    set { set(Pref.enableHaptic, newValue) }
  }

  private var _isCloudSyncEnabledWatcher: Bool {
    get { get(Pref.isCloudSyncEnabled) }
    set { set(Pref.isCloudSyncEnabled, newValue) }
  }

  private var _accentColorWatcher: ThemeColor {
    get {
      if let rawValue = defaults.string(forKey: Pref.accentColor.key),
         let color = ThemeColor(rawValue: rawValue) {
        return color
      }
      return Pref.accentColor.defaultValue
    }
    set {
      defaults.set(newValue.rawValue, forKey: Pref.accentColor.key)
    }
  }

  private var _isDailyReminderEnabledWatcher: Bool {
    get { get(Pref.isDailyReminderEnabled) }
    set { set(Pref.isDailyReminderEnabled, newValue) }
  }

  private var _dailyReminderTimeSecondsWatcher: Int {
    get { get(Pref.dailyReminderTimeSeconds) }
    set { set(Pref.dailyReminderTimeSeconds, newValue) }
  }

  private var _startOfWeekWatcher: String {
    get { get(Pref.startOfWeek) }
    set { set(Pref.startOfWeek, newValue) }
  }

  private var _cameraZoomSliderHandednessWatcher: SliderHandedness {
    get {
      if let rawValue = defaults.string(forKey: Pref.cameraZoomSliderHandedness.key),
         let handedness = SliderHandedness(rawValue: rawValue)
      {
        return handedness
      }
      return Pref.cameraZoomSliderHandedness.defaultValue
    }
    set {
      defaults.set(newValue.rawValue, forKey: Pref.cameraZoomSliderHandedness.key)
    }
  }

  private var _isAutoTraceEnabledWatcher: Bool {
    get { get(Pref.isAutoTraceEnabled) }
    set { set(Pref.isAutoTraceEnabled, newValue) }
  }

  private var _autoTraceDefaultDetailWatcher: AutoTraceDetail {
    get { AutoTraceDetail(rawValue: get(Pref.autoTraceDefaultDetail)) ?? .default }
    set { set(Pref.autoTraceDefaultDetail, newValue.rawValue) }
  }

  private var _enableTimeBackdropWatcher: Bool {
    get { get(Pref.enableTimeBackdrop) }
    set { set(Pref.enableTimeBackdrop, newValue) }
  }

  private var _enableWigglyStrokesWatcher: Bool {
    get { get(Pref.enableWigglyStrokes) }
    set { set(Pref.enableWigglyStrokes, newValue) }
  }

  private var _announcementsEnabledWatcher: Bool {
    get { get(Pref.announcementsEnabled) }
    set { set(Pref.announcementsEnabled, newValue) }
  }

  private var _announcementPromoEnabledWatcher: Bool {
    get { get(Pref.announcementPromoEnabled) }
    set { set(Pref.announcementPromoEnabled, newValue) }
  }

  private var _announcementCommunityEnabledWatcher: Bool {
    get { get(Pref.announcementCommunityEnabled) }
    set { set(Pref.announcementCommunityEnabled, newValue) }
  }

  private var _announcementTipsEnabledWatcher: Bool {
    get { get(Pref.announcementTipsEnabled) }
    set { set(Pref.announcementTipsEnabled, newValue) }
  }

  private var _promptForNotesAfterDoodlingWatcher: Bool {
    get { get(Pref.promptForNotesAfterDoodling) }
    set { set(Pref.promptForNotesAfterDoodling, newValue) }
  }

  private var _shareCardWatermarkEnabledWatcher: Bool {
    get { get(Pref.shareCardWatermarkEnabled) }
    set { set(Pref.shareCardWatermarkEnabled, newValue) }
  }

  private var _saveCapturedPhotoToAlbumWatcher: Bool {
    get { get(Pref.saveCapturedPhotoToAlbum) }
    set { set(Pref.saveCapturedPhotoToAlbum, newValue) }
  }

  private var _appLanguageWatcher: String {
    get {
      defaults.string(forKey: Pref.appLanguage.key) ?? Pref.appLanguage.defaultValue
    }
    set {
      defaults.set(newValue, forKey: Pref.appLanguage.key)
    }
  }

  // MARK: - Step 5: Add your property to load during initialization
  init() {
    // Detect if the user changed the app language via iOS Settings.
    // Must run BEFORE appLanguage is loaded, because the didSet on
    // appLanguage writes AppleLanguages and would overwrite the system change.
    Self.syncSystemLanguageOverrideIfNeeded()

    // Load initial values from UserDefaults
    defaultViewMode = _defaultViewModeWatcher
    preferredColorScheme = _preferredColorSchemeWatcher
    enableHaptic = _enableHapticWatcher
    isCloudSyncEnabled = _isCloudSyncEnabledWatcher
    accentColor = _accentColorWatcher
    isDailyReminderEnabled = _isDailyReminderEnabledWatcher
    dailyReminderTimeSeconds = _dailyReminderTimeSecondsWatcher
    startOfWeek = _startOfWeekWatcher
    cameraZoomSliderHandedness = _cameraZoomSliderHandednessWatcher
    isAutoTraceEnabled = _isAutoTraceEnabledWatcher
    autoTraceDefaultDetail = _autoTraceDefaultDetailWatcher
    enableTimeBackdrop = _enableTimeBackdropWatcher
    enableWigglyStrokes = _enableWigglyStrokesWatcher
    announcementsEnabled = _announcementsEnabledWatcher
    announcementPromoEnabled = _announcementPromoEnabledWatcher
    announcementCommunityEnabled = _announcementCommunityEnabledWatcher
    announcementTipsEnabled = _announcementTipsEnabledWatcher
    promptForNotesAfterDoodling = _promptForNotesAfterDoodlingWatcher
    shareCardWatermarkEnabled = _shareCardWatermarkEnabledWatcher
    saveCapturedPhotoToAlbum = _saveCapturedPhotoToAlbumWatcher
    appLanguage = _appLanguageWatcher

    // Allow subsequent appLanguage changes to sync AppleLanguages normally.
    _isInitializing = false
  }

  /// Reads raw UserDefaults to detect if the user changed the app language
  /// via iOS Settings. If so, clears our in-app override so the system
  /// preference takes effect. This must be called before appLanguage is
  /// loaded, because loading it triggers didSet which writes AppleLanguages.
  private static func syncSystemLanguageOverrideIfNeeded() {
    let defaults = UserDefaults.standard
    let storedOverride = defaults.string(forKey: Pref.appLanguage.key) ?? ""
    guard !storedOverride.isEmpty else { return }

    // AppleLanguages reflects the iOS-resolved language preference.
    // If the user changed the per-app language in iOS Settings, iOS
    // updated this key. Compare with our stored override to detect that.
    guard let systemResolved = defaults.stringArray(forKey: "AppleLanguages")?.first else { return }

    if systemResolved != storedOverride {
      // System language was changed externally — clear our in-app override
      // directly in UserDefaults (not through the property, to avoid side effects).
      defaults.removeObject(forKey: Pref.appLanguage.key)
    }
  }

  // MARK: - Save-to-album

  /// Force-enables save-to-album exactly once for this build, for everyone —
  /// regardless of their previous toggle value or Photos permission. The
  /// permission itself is NOT requested here; it's resolved at the next capture
  /// (ON + undetermined → prompt). Runs once (guarded by `didForceSaveToAlbumOn`)
  /// so any choice the user makes afterwards (including a denied prompt flipping
  /// the toggle back OFF) is never overridden on a later launch. Call on launch.
  func forceSaveToAlbumOnIfNeeded() {
    guard !get(Pref.didForceSaveToAlbumOn) else { return }
    set(Pref.didForceSaveToAlbumOn, true)
    saveCapturedPhotoToAlbum = true
  }

  // MARK: - Reset Method (automatically uses all registered keys!)
  func resetToDefaults() {
    Pref.allKeys.forEach { key in
      defaults.removeObject(forKey: key)
    }
    // Reset all the properties
    // MARK: - Step 6: Add your property here to reset
    defaultViewMode = Pref.defaultViewMode.defaultValue
    preferredColorScheme = Pref.preferredColorScheme.defaultValue
    enableHaptic = Pref.enableHaptic.defaultValue
    isCloudSyncEnabled = Pref.isCloudSyncEnabled.defaultValue
    accentColor = Pref.accentColor.defaultValue
    isDailyReminderEnabled = Pref.isDailyReminderEnabled.defaultValue
    dailyReminderTimeSeconds = Pref.dailyReminderTimeSeconds.defaultValue
    startOfWeek = Pref.startOfWeek.defaultValue
    cameraZoomSliderHandedness = Pref.cameraZoomSliderHandedness.defaultValue
    isAutoTraceEnabled = Pref.isAutoTraceEnabled.defaultValue
    autoTraceDefaultDetail = AutoTraceDetail.default
    enableTimeBackdrop = Pref.enableTimeBackdrop.defaultValue
    enableWigglyStrokes = Pref.enableWigglyStrokes.defaultValue
    announcementsEnabled = Pref.announcementsEnabled.defaultValue
    announcementPromoEnabled = Pref.announcementPromoEnabled.defaultValue
    announcementCommunityEnabled = Pref.announcementCommunityEnabled.defaultValue
    announcementTipsEnabled = Pref.announcementTipsEnabled.defaultValue
    promptForNotesAfterDoodling = Pref.promptForNotesAfterDoodling.defaultValue
    shareCardWatermarkEnabled = Pref.shareCardWatermarkEnabled.defaultValue
    saveCapturedPhotoToAlbum = Pref.saveCapturedPhotoToAlbum.defaultValue
    appLanguage = Pref.appLanguage.defaultValue
    // Clear AppleLanguages override on reset
    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
  }

}

// MARK: - App Language

enum AppLanguage: String, CaseIterable, Identifiable {
  case en
  case zhHans
  case zhHant
  case fr
  case ko
  case ja
  case tr

  var id: String { code }

  var code: String {
    switch self {
    case .en: return "en"
    case .zhHans: return "zh-Hans"
    case .zhHant: return "zh-Hant"
    case .fr: return "fr"
    case .ko: return "ko"
    case .ja: return "ja"
    case .tr: return "tr"
    }
  }

  /// Native display name for each language
  var displayName: String {
    switch self {
    case .en: return "English"
    case .zhHans: return "简体中文"
    case .zhHant: return "繁體中文"
    case .fr: return "Français"
    case .ko: return "한국어"
    case .ja: return "日本語"
    case .tr: return "Türkçe"
    }
  }

  static func from(code: String) -> AppLanguage? {
    allCases.first { $0.code == code }
  }
}

// MARK: - Environment Extension
extension EnvironmentValues {
  @Entry var userPreferences: UserPreferences = UserPreferences.shared
}
