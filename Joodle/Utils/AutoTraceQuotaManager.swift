//
//  AutoTraceQuotaManager.swift
//  Joodle
//
//  Daily auto-trace allowance for free users. Pro users are unlimited and never
//  consult this. A free user gets `dailyFreeLimit` traces per calendar day; the
//  count lives in iCloud KVS (with a local mirror) so it survives a reinstall
//  and can't be reset by deleting the app. On each read the stored day is rolled
//  over to zero once it isn't today, and the cloud/local counts are reconciled
//  to the most restrictive value so toggling iCloud off can't grant extra traces.
//

import Foundation
import Observation

@MainActor
@Observable
final class AutoTraceQuotaManager {
  static let shared = AutoTraceQuotaManager()

  /// Auto-traces a free user may run per calendar day.
  static let dailyFreeLimit = 1

  private let cloudStore = NSUbiquitousKeyValueStore.default
  private let defaults = UserDefaults.standard

  private enum Key {
    /// Start-of-day epoch (seconds) the stored count belongs to.
    static let day = "auto_trace_quota_day"
    /// Traces consumed on that day.
    static let used = "auto_trace_quota_used"
  }

  /// Traces the free user has consumed today. Recomputed on init, on external
  /// iCloud changes, and whenever the app calls `refresh()`.
  private(set) var usedToday: Int = 0

  private init() {
    cloudStore.synchronize()
    refresh()

    NotificationCenter.default.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: cloudStore,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  /// Start of the current calendar day, as an epoch second — the key the stored
  /// count is stamped against so a new day resets the allowance.
  private static var startOfToday: Double {
    Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
  }

  /// Traces still available today for a free user.
  var remaining: Int {
    max(0, Self.dailyFreeLimit - usedToday)
  }

  /// Re-reads the stored count, rolling over to zero if it belongs to an earlier
  /// day, and taking the higher of the cloud and local counts for today.
  func refresh() {
    let today = Self.startOfToday
    var used = 0
    if cloudStore.double(forKey: Key.day) == today {
      used = max(used, Int(cloudStore.double(forKey: Key.used)))
    }
    if defaults.double(forKey: Key.day) == today {
      used = max(used, defaults.integer(forKey: Key.used))
    }
    if used != usedToday {
      usedToday = used
    }
  }

  /// Records one consumed trace against today's allowance, writing through to
  /// both iCloud KVS and the local mirror.
  func consume() {
    refresh()
    let today = Self.startOfToday
    usedToday += 1

    cloudStore.set(today, forKey: Key.day)
    cloudStore.set(Double(usedToday), forKey: Key.used)
    cloudStore.synchronize()

    defaults.set(today, forKey: Key.day)
    defaults.set(usedToday, forKey: Key.used)
  }

  #if DEBUG
  /// Clears today's usage — for QA of the free-tier limit flow.
  func resetForDebug() {
    cloudStore.removeObject(forKey: Key.day)
    cloudStore.removeObject(forKey: Key.used)
    cloudStore.synchronize()
    defaults.removeObject(forKey: Key.day)
    defaults.removeObject(forKey: Key.used)
    usedToday = 0
  }
  #endif
}
