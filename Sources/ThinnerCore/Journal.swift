import Foundation
import CommonCrypto

/// A durable, versioned manifest that records every file change in an operation
/// and survives crashes. The journal is persisted before any file is swapped,
/// and on restart any uncommitted entry is resolved by hash.
///
/// States per entry:
///   `.ready`     — backup and temp exist, swap has not happened
///   `.replaced`  — rename(2) succeeded; the original path now holds the thinned file
///   `.committed` — codesign verified; the operation completed successfully
///   `.recoveryFailed` — restore was attempted but did not verify
///
/// The journal never deletes backups. Commit only marks the entry; cleanup is
/// the user's choice.
struct Journal: Codable, Sendable {
    static let schemaVersion = 1
    static let fileName = "journal.json"

    var schemaVersion: Int = Journal.schemaVersion
    var operationID: String
    var bundlePath: String
    var bundleIdentifier: String?
    var startedAt: String
    var state: OperationState = .inProgress
    var entries: [Entry] = []
    /// The app's identity when the operation started, recorded before the
    /// first swap. Restore and recovery refuse a journal without it, or one
    /// whose identity differs from the app on disk. Encoded under
    /// `AppIdentity.journalKey`.
    var appIdentity: AppIdentity? = nil
    /// Every file the operation set out to thin, recorded before the first
    /// backup. Entries are added only as the writer reaches each file, so
    /// without this a crash between files would leave a journal whose every
    /// entry is swapped although later files were never processed. Recovery
    /// commits only when each planned file has an entry; nil (a journal from
    /// before this field) cannot prove that, so it rolls back.
    var plannedFiles: [String]? = nil

    enum OperationState: String, Codable, Sendable {
        case inProgress
        case committed
        case rolledBack
        case recoveryFailed
    }

    struct Entry: Codable, Sendable {
        let relativePath: String
        let originalHash: String
        let thinnedHash: String?
        let arm64SliceHash: String
        let backupPath: String
        let tempPath: String?
        let originalSize: UInt64
        let thinnedSize: UInt64?
        var state: EntryState
    }

    enum EntryState: String, Codable, Sendable {
        case ready
        case replaced
        case committed
        case restored
        case recoveryFailed
    }
}

/// The staging area for one thinning operation: a directory outside the bundle,
/// on the same volume, holding backups, temp files, and the journal.
///
/// Layout:
///   <staging>/journal.json        — the durable manifest
///   <staging>/backups/<relative>   — clonefile backups of originals
///   <staging>/temps/<relative>     — lipo output before swap
struct StagingArea {
    let root: URL
    let backupsDir: URL
    let tempsDir: URL
    let journalPath: URL

    /// Creates a staging directory next to the bundle, on the same volume.
    /// The directory name includes the operation ID for uniqueness.
    init(bundlePath: URL, operationID: String, requiredBytes: UInt64) throws(Problem) {
        let parent = bundlePath.deletingLastPathComponent()
        let name = ".thinner-\(operationID)"
        root = parent.appending(path: name)
        backupsDir = root.appending(path: "backups")
        tempsDir = root.appending(path: "temps")
        journalPath = root.appending(path: Journal.fileName)

        // Verify same volume, APFS, and free space.
        var bundleStat = statfs()
        var parentStat = statfs()
        guard statfs(bundlePath.path, &bundleStat) == 0,
              statfs(parent.path, &parentStat) == 0 else {
            throw Problem("cannot stat volume: \(errnoDescription())")
        }
        let bundleDev = withUnsafeBytes(of: bundleStat.f_fsid) { Data($0) }
        let parentDev = withUnsafeBytes(of: parentStat.f_fsid) { Data($0) }
        guard bundleDev == parentDev else {
            throw Problem("staging directory must be on the same volume as the bundle")
        }
        
        let fsTypeName = withUnsafeBytes(of: bundleStat.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        guard fsTypeName == "apfs" else {
            throw Problem("volume is not APFS (\(fsTypeName)); clonefile backups require APFS")
        }
        
        let freeBytes = UInt64(bundleStat.f_bavail) * UInt64(bundleStat.f_bsize)
        let reserve: UInt64 = 2 * 1024 * 1024 * 1024 // 2 GiB
        let totalRequired = requiredBytes + reserve
        guard freeBytes >= totalRequired else {
            throw Problem("insufficient free space: need \(totalRequired) bytes, have \(freeBytes)")
        }

        do {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tempsDir, withIntermediateDirectories: true)
        } catch {
            throw Problem("cannot create staging directory: \(error.localizedDescription)")
        }
    }
    
    /// Initializes from an existing staging root directory (used for recovery).
    init(existingRoot: URL) {
        self.root = existingRoot
        self.backupsDir = root.appending(path: "backups")
        self.tempsDir = root.appending(path: "temps")
        self.journalPath = root.appending(path: Journal.fileName)
    }

    func backupPath(for relativePath: String) throws(Problem) -> URL {
        let url = backupsDir.appending(path: relativePath)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw Problem("cannot create backup directory: \(error.localizedDescription)")
        }
        return url
    }

    func tempPath(for relativePath: String) throws(Problem) -> URL {
        let url = tempsDir.appending(path: relativePath)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw Problem("cannot create temp directory: \(error.localizedDescription)")
        }
        return url
    }
}

/// Reading and writing the journal with F_FULLFSYNC durability.
extension Journal {
    /// Writes the journal to disk with F_FULLFSYNC. Call this before any swap
    /// and after each state change.
    func persist(to path: URL, flushDirectory: (String) -> String? = syncDirectory) throws(Problem) {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(self)
        } catch {
            throw Problem("cannot encode journal: \(error.localizedDescription)")
        }

        try durablyWrite(data, to: path, flushDirectory: flushDirectory)
    }

    /// Loads a journal from disk. Returns nil if no journal exists.
    static func load(from path: URL) throws(Problem) -> Journal? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw Problem("cannot read journal: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Journal.self, from: data)
        } catch {
            throw Problem("cannot decode journal: \(error.localizedDescription)")
        }
    }
}
