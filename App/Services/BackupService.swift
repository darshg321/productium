import Foundation
import ProductiumCore

/// v1.3 H: the daily backup file in a folder outside the app (iCloud Drive or another app's folder), so it survives an
/// uninstall. The folder's bookmark is kept in the Keychain, which iOS usually keeps after an uninstall, so a reinstall
/// can find the backups again before onboarding (H2).
@MainActor
enum BackupService {
    static let bookmarkKey = "backup.folder"

    enum Failure: LocalizedError {
        case noFolder, unreachable
        var errorDescription: String? {
            switch self {
            case .noFolder: return "No backup folder picked."
            case .unreachable: return "The backup folder isn't reachable. Pick it again in Settings → Backup."
            }
        }
    }

    static var bookmark: Data? {
        get { Keychain.get(bookmarkKey).flatMap { Data(base64Encoded: $0) } }
        set { Keychain.set(newValue?.base64EncodedString(), for: bookmarkKey) }
    }

    static var hasFolder: Bool { bookmark != nil }

    /// Without a picked folder the backups go to Files → On My iPhone → Productium → Backups. That survives a bad
    /// update or a broken state, but not deleting the app; a folder in iCloud Drive survives that too.
    static let defaultFolderName = "Backups"
    static var defaultFolder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(defaultFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Keeps the folder picked in Settings or onboarding. Returns its name.
    @discardableResult
    static func choose(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return url.lastPathComponent
    }

    static func forget() { bookmark = nil }

    /// The folder, with access started (call `stopAccessingSecurityScopedResource` when done). No folder picked: the
    /// app's own Backups folder.
    static func open() throws -> URL {
        guard let data = bookmark else { return defaultFolder }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw Failure.unreachable
        }
        guard url.startAccessingSecurityScopedResource() else { throw Failure.unreachable }
        // (stopAccessing on the default folder is a harmless no-op.)
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { bookmark = fresh }
        return url
    }

    /// Writes today's file and deletes all but the newest `BackupFiles.keep`. Returns the file's name.
    static func write(_ data: Data, now: Date, calendar: Calendar) throws -> String {
        let dir = try open()
        defer { dir.stopAccessingSecurityScopedResource() }
        let name = BackupFiles.name(for: now, calendar: calendar)
        var coordinated: NSError?
        var failed: Error?
        NSFileCoordinator().coordinate(writingItemAt: dir.appendingPathComponent(name), options: .forReplacing, error: &coordinated) { url in
            do { try data.write(to: url, options: .atomic) } catch { failed = error }
        }
        if let e = coordinated ?? failed { throw e }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for old in BackupFiles.toDelete(names) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
        return name
    }

    /// The newest backup in the folder (H2: offered before onboarding on a fresh install).
    static func newest() -> ExportBundle? {
        guard let dir = try? open() else { return nil }
        defer { dir.stopAccessingSecurityScopedResource() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in BackupFiles.ours(names) {
            var coordinated: NSError?
            var data: Data?
            NSFileCoordinator().coordinate(readingItemAt: dir.appendingPathComponent(name), options: [], error: &coordinated) { url in
                data = try? Data(contentsOf: url)
            }
            if let data, let b = try? ExportBundle.read(data) { return b }
        }
        return nil
    }
}

extension AppModel {
    /// H1: once a day (background refresh, and on launch if the last is over 24 h old), when a folder is picked.
    func backupIfDue(force: Bool = false) async {
        // v1.6 G2: one write at a time; taps while it writes are the same backup.
        guard !backingUp, state.onboarded, force || BackupFiles.isDue(last: state.backup.lastWrite, now: Date()) else { return }
        backingUp = true
        defer { backingUp = false }
        do {
            let data = try await backupData()
            let name = try BackupService.write(data, now: Date(), calendar: cal)
            lastBackupBytes = data.count
            state.backup.lastWrite = Date()
            state.backup.lastFile = name
            state.backup.lastError = nil
            log(.storage, "backup_written", ["file": name, "bytes": "\(data.count)"])
        } catch {
            state.backup.lastError = error.localizedDescription
            state.backup.lastErrorAt = Date()
            log(.storage, "backup_failed", level: .error, ["error": "\(error)"])
        }
        save()
    }

    /// Settings → Backup and onboarding: the folder the daily file goes to.
    func chooseBackupFolder(_ url: URL) {
        do {
            state.backup.folderName = try BackupService.choose(url)
            state.backup.lastError = nil
            log(.storage, "backup_folder", ["name": state.backup.folderName ?? ""])
            Task { await backupIfDue(force: true) }
        } catch {
            state.backup.lastError = error.localizedDescription
            state.backup.lastErrorAt = Date()
        }
        save()
    }

    /// H2: a fresh install that can still reach the old backup folder.
    func backupToOffer() -> RestorePreview? {
        guard !state.onboarded, BackupService.hasFolder, let b = BackupService.newest() else { return nil }
        return RestorePreview(exportedAt: b.exportedAt, summary: BackupFiles.offer(b, now: Date(), calendar: cal), bundle: b)
    }
}
