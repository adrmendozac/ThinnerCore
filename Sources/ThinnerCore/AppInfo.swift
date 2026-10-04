import Foundation

/// What an app's `Info.plist` and main executable say about it.
struct AppInfo {
    let bundleIdentifier: String?
    let executable: String
    /// `LSArchitecturePriority`, if present.
    let architecturePriority: [String]?

    /// Reads `Contents/Info.plist` without following symlinks.
    init(tree: FileTree) throws(Problem) {
        let data = try tree.read(["Contents", "Info.plist"], limit: 16 << 20)
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        guard let info = plist as? [String: Any] else {
            throw Problem("Info.plist is not a property list dictionary")
        }
        guard let executable = info["CFBundleExecutable"] as? String else {
            throw Problem("Info.plist has no CFBundleExecutable")
        }
        guard !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/") else {
            throw Problem("CFBundleExecutable \"\(executable)\" is not a file name")
        }
        switch info["LSArchitecturePriority"] {
        case nil: architecturePriority = nil
        case let names as [String]: architecturePriority = names
        default: throw Problem("LSArchitecturePriority is not a list of architecture names")
        }
        bundleIdentifier = info["CFBundleIdentifier"] as? String
        self.executable = executable
    }

    /// The slice `LSArchitecturePriority` selects from the main executable's
    /// `slices`: the first listed name the executable contains, not merely
    /// the first listed name. An app listing (arm64e, x86_64) whose
    /// executable has no arm64e slice launches as x86_64 under Rosetta
    /// (Phase 0). Nil when the list is absent or names none of the slices.
    func prioritySelection(from slices: [Arch]) -> Arch? {
        architecturePriority?.lazy.compactMap { name in slices.first { $0.description == name } }.first
    }

    /// The main executable's architectures, read from its own header: every
    /// slice of a universal file, or the one architecture of a thin Mach-O.
    /// The walker records only universal files, so a thin main executable is
    /// otherwise invisible to the app-level checks. Throws if the header
    /// cannot be read or parsed; call only once `scriptOnlyReason` is nil.
    func mainExecutableArchitectures(tree: FileTree) throws(Problem) -> [Arch] {
        let path = ["Contents", "MacOS", executable]
        guard let info = try tree.status(path) else { throw Problem("the main executable \(executable) is missing") }
        let header = [UInt8](try tree.head(path, count: FatBinary.maxHeaderLength))
        switch FatBinary.parse(header, fileSize: UInt64(info.st_size)) {
        case let .fat(binary):
            return binary.slices.map(\.arch)
        case let .malformed(problem):
            throw Problem("the main executable \(executable) has a malformed universal header: \(problem)")
        case .notFat:
            guard header.count >= 12 else { throw Problem("the main executable \(executable) is truncated") }
            switch readBE32(header, 0) {
            case 0xCFFA_EDFE, 0xCEFA_EDFE: // MH_MAGIC_64 / MH_MAGIC, little-endian on disk
                return [Arch(cpuType: Int32(bitPattern: readLE32(header, 4)),
                             cpuSubtype: Int32(bitPattern: readLE32(header, 8)))]
            case 0xFEED_FACF, 0xFEED_FACE:
                return [Arch(cpuType: Int32(bitPattern: readBE32(header, 4)),
                             cpuSubtype: Int32(bitPattern: readBE32(header, 8)))]
            default:
                throw Problem("the main executable \(executable) is not a Mach-O binary")
            }
        }
    }

    /// Why the main executable is not a Mach-O binary, or nil if it is one.
    func scriptOnlyReason(tree: FileTree) throws(Problem) -> String? {
        let head = try tree.head(["Contents", "MacOS", executable], count: 4)
        let magic = head.count == 4 ? head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } : 0
        let machO: Set<UInt32> = [
            FatBinary.magic, FatBinary.magic64,
            0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE,
        ]
        if machO.contains(magic) { return nil }
        return head.starts(with: Data("#!".utf8))
            ? "the main executable \(executable) is a script"
            : "the main executable \(executable) is not a Mach-O binary"
    }
}
