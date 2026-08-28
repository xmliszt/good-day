import Foundation
import SwiftData

/// Serializes DayEntry objects to JSON and writes them to the iCloud Drive
/// ubiquity container. Shared by the manual "Save to iCloud Drive" action and
/// the BGProcessingTask scheduler.
final class BackupManager {
  static let shared = BackupManager()

  private init() {}

  enum BackupError: Error {
    case ubiquityUnavailable
  }

  struct BackupFile: Identifiable, Hashable {
    let url: URL
    let createdAt: Date
    let sizeBytes: Int64
    var id: URL { url }
  }

  static let ubiquityContainerIdentifier = "iCloud.dev.liyuxuan.joodle"
  static let backupsFolderName = "JoodleBackups"
  static let backupFilePrefix = "Joodle_Data_Backup_"
  static let maxRetainedBackups = 7

  func serializeEntries(_ entries: [DayEntry]) throws -> Data {
    let dtos = entries.map { entry in
      DayEntryDTO(
        body: entry.body,
        createdAt: entry.createdAt,
        dateString: entry.dateString.isEmpty ? nil : entry.dateString,
        drawingData: entry.drawingData,
        drawingThumbnail20: entry.drawingThumbnail20,
        drawingThumbnail200: entry.drawingThumbnail200,
        extraDoodlesData: entry.extraDoodlesData
      )
    }
    return try JSONEncoder().encode(dtos)
  }

  /// Returns the iCloud Drive backups directory, creating it if needed.
  func iCloudBackupsDirectory() throws -> URL {
    let fm = FileManager.default
    guard let ubiq = fm.url(forUbiquityContainerIdentifier: Self.ubiquityContainerIdentifier) else {
      throw BackupError.ubiquityUnavailable
    }
    let dir = ubiq
      .appendingPathComponent("Documents", isDirectory: true)
      .appendingPathComponent(Self.backupsFolderName, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Writes a backup to iCloud Drive and prunes older backups beyond
  /// `maxRetainedBackups`. Returns the new file URL.
  @discardableResult
  func writeBackupToICloudDrive(data: Data) throws -> URL {
    let dir = try iCloudBackupsDirectory()
    let filename = "\(Self.backupFilePrefix)\(Int(Date().timeIntervalSince1970)).json"
    let dest = dir.appendingPathComponent(filename)
    try data.write(to: dest, options: .atomic)
    pruneOldBackups(in: dir)
    return dest
  }

  /// Lists existing iCloud Drive backups, newest first.
  func listICloudBackups() throws -> [BackupFile] {
    let dir = try iCloudBackupsDirectory()
    let fm = FileManager.default
    let urls = try fm.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    )
    return urls
      .filter { $0.lastPathComponent.hasPrefix(Self.backupFilePrefix) }
      .compactMap { url -> BackupFile? in
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate ?? .distantPast
        let size = Int64(values?.fileSize ?? 0)
        return BackupFile(url: url, createdAt: mtime, sizeBytes: size)
      }
      .sorted { $0.createdAt > $1.createdAt }
  }

  func deleteBackup(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }

  /// Restores from a backup, replacing all existing DayEntry records.
  /// Returns the number of entries restored.
  @discardableResult
  func restoreBackup(from url: URL, into container: ModelContainer) throws -> Int {
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
      try? fm.startDownloadingUbiquitousItem(at: url)
    }
    let data = try Data(contentsOf: url)
    let dtos = try JSONDecoder().decode([DayEntryDTO].self, from: data)

    let context = ModelContext(container)
    let existing = try context.fetch(FetchDescriptor<DayEntry>())
    for entry in existing {
      context.delete(entry)
    }

    for dto in dtos {
      let calendarDate = (dto.dateString.flatMap { CalendarDate(dateString: $0) })
        ?? CalendarDate.from(dto.createdAt)
      let entry = DayEntry(body: dto.body, calendarDate: calendarDate, drawingData: dto.drawingData)
      entry.drawingThumbnail20 = dto.drawingThumbnail20
      entry.drawingThumbnail200 = dto.drawingThumbnail200
      entry.extraDoodlesData = dto.extraDoodlesData
      context.insert(entry)
    }

    try context.save()
    return dtos.count
  }

  private func pruneOldBackups(in directory: URL) {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    let backups = urls
      .filter { $0.lastPathComponent.hasPrefix(Self.backupFilePrefix) }
      .map { url -> (URL, Date) in
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return (url, mtime)
      }
      .sorted { $0.1 > $1.1 }

    guard backups.count > Self.maxRetainedBackups else { return }
    for (url, _) in backups.dropFirst(Self.maxRetainedBackups) {
      try? fm.removeItem(at: url)
    }
  }
}
