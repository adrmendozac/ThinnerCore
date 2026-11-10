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
        /// The app this operation changed is gone or was replaced (an update,
        /// most likely) and holds none of its thinned files, so there is
        /// nothing left to recover. Set only by an explicit recover, never by
        /// a scan. The app is not touched and the backups are kept until the
        /// user releases them; restore still uses them, by hash, if an app
        /// with the recorded identity comes back.
        case superseded
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
///
/// It is built as `.thinner-preparing-<UUID>` and renamed to
/// `.thinner-<UUID>` only once its journal is durable, so every staging
/// directory that discovery sees has a journal. A crash while preparing
/// leaves a directory no operation treats as a backup set, and it holds no
/// backups: they are made only after `activate`.
struct StagingArea {
    let root: URL
    let backupsDir: URL
    let tempsDir: URL
    let journalPath: URL
    /// Where the directory is built before `activate`.
    let preparing: URL

    static let preparingPrefix = ".thinner-preparing-"

    /// Creates a staging directory next to the bundle, on the same volume.
    /// The directory name includes the operation ID for uniqueness.
    init(bundlePath: URL, operationID: String, requiredBytes: UInt64,
         freeSpace: (statfs) -> UInt64 = StagingArea.available) throws(Problem) {
        let parent = bundlePath.deletingLastPathComponent()
        let name = ".thinner-\(operationID)"
        root = parent.appending(path: name)
        backupsDir = root.appending(path: "backups")
        tempsDir = root.appending(path: "temps")
        journalPath = root.appending(path: Journal.fileName)
        preparing = parent.appending(path: Self.preparingPrefix + operationID)

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
        
        let freeBytes = freeSpace(bundleStat)
        let totalRequired = requiredBytes + Self.reserve
        guard freeBytes >= totalRequired else {
            throw Problem("insufficient free space: need \(totalRequired) bytes (the thinned files plus a 2 GiB reserve), have \(freeBytes). Nothing was changed")
        }

        guard mkdir(preparing.path, 0o755) == 0 else {
            throw Problem("cannot create the staging directory beside the app: \(PermissionDiagnostic.describe(errno, path: preparing.path))")
        }
    }

    /// Writes `journal` into the directory being prepared, then moves it into
    /// place as the operation's staging directory and flushes the parent.
    /// `boundary` marks the step for crash tests.
    func activate(with journal: Journal, flushDirectory: (String) -> String? = syncDirectory,
                  boundary: (String) -> Void = { _ in }) throws(Problem) {
        try journal.persist(to: preparing.appending(path: Journal.fileName), flushDirectory: flushDirectory)
        for dir in [backupsDir, tempsDir] {
            let path = preparing.appending(path: dir.lastPathComponent).path
            guard mkdir(path, 0o755) == 0 else {
                throw Problem("cannot create \(path): \(errnoDescription())")
            }
        }
        boundary("staging-prepared")
        guard rename(preparing.path, root.path) == 0 else {
            throw Problem("cannot move \(preparing.path) into place: \(errnoDescription())")
        }
        if let problem = flushDirectory(root.deletingLastPathComponent().path) {
            throw Problem("cannot flush \(root.deletingLastPathComponent().path) to disk: \(problem)")
        }
    }

    /// Removes what an interrupted preparation of an operation on the app
    /// at `real` left behind, owned by `euid`. Only the known layout is
    /// removed, file by file: a directory holding anything else stays.
    static func removeAbandonedPreparations(of real: String, euid: uid_t) {
        let parent = (real as NSString).deletingLastPathComponent
        guard let tree = try? FileTree(URL(filePath: parent)), let entries = try? tree.entries([]) else { return }
        for entry in entries where entry.kind == .directory && entry.name.hasPrefix(preparingPrefix)
            && UUID(uuidString: String(entry.name.dropFirst(preparingPrefix.count))) != nil {
            guard let info = try? tree.status([entry.name]), info.st_uid == euid else { continue }
            guard let data = try? tree.read([entry.name, Journal.fileName], limit: 16 << 20) else {
                // No journal: a crash between creating the directory and
                // writing it. rmdir removes only an empty directory, and only
                // an old one, so a sibling app's preparation that is still
                // running is never touched.
                if Date().timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) > abandonedAge {
                    rmdir(parent + "/" + entry.name)
                }
                continue
            }
            guard let journal = try? JSONDecoder().decode(Journal.self, from: data),
                  journal.entries.isEmpty,
                  RestoreOperation.canonicalBundlePath(journal.bundlePath) == real else { continue }
            let dir = parent + "/" + entry.name
            for name in [Journal.fileName, ".\(Journal.fileName).tmp"] { unlink(dir + "/" + name) }
            for name in ["backups", "temps"] { rmdir(dir + "/" + name) }
            rmdir(dir)
        }
    }
    
    /// How old a preparation directory without a journal must be before it
    /// counts as abandoned.
    static let abandonedAge: TimeInterval = 3600

    /// Free space kept beyond the thinned files, which are new data while
    /// their backups are retained.
    static let reserve: UInt64 = 2 << 30

    /// Bytes available to an unprivileged writer on the volume.
    static func available(_ volume: statfs) -> UInt64 {
        UInt64(volume.f_bavail) * UInt64(volume.f_bsize)
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
