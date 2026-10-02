import Foundation

/// How one bundle's resource seal (`_CodeSignature/CodeResources`) covers a
/// path.
enum SealEntry: Equatable {
    /// Nested code, sealed by code directory hash and requirement. The file
    /// carries its own per-slice signature, so removing a slice leaves the
    /// retained slice's signature intact.
    case code
    /// Sealed as data: a hash of the whole file. Any change breaks the seal.
    case data
    case symlink
    case unrecognized

    init(_ value: Any) {
        if value is Data {
            self = .data // version 1 entries are bare SHA-1 hashes
            return
        }
        guard let entry = value as? [String: Any] else {
            self = .unrecognized
            return
        }
        if entry["hash"] != nil || entry["hash2"] != nil {
            self = .data
        } else if entry["cdhash"] is Data, entry["requirement"] is String {
            self = .code
        } else if entry["symlink"] is String {
            self = .symlink
        } else {
            self = .unrecognized
        }
    }
}

/// A parsed `CodeResources`. Paths are relative to the bundle's code root.
struct ResourceSeal {
    /// The version 2 seal that current macOS verifies.
    let files2: [String: SealEntry]
    /// The version 1 seal, kept for old systems. Anything in it is data.
    let files: Set<String>

    /// `CodeResources` of large apps runs to a few megabytes.
    static let sizeLimit = 64 << 20

    init(_ data: Data) throws(Problem) {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        guard let root = plist as? [String: Any] else {
            throw Problem("CodeResources is not a property list dictionary")
        }
        guard let files2 = root["files2"] as? [String: Any] else {
            throw Problem("CodeResources has no version 2 seal (files2)")
        }
        let files: [String: Any]
        switch root["files"] {
        case nil: files = [:]
        case let dictionary as [String: Any]: files = dictionary
        default: throw Problem("CodeResources has an unreadable version 1 seal (files)")
        }
        self.files2 = files2.mapValues(SealEntry.init)
        self.files = Set(files.keys)
    }
}

/// The directory a signed bundle's seal paths are relative to.
struct CodeRoot {
    enum Layout {
        /// `X.app/Contents`, `X.bundle/Contents`, and the like.
        case contents
        /// `X.framework/Versions/<Current>`.
        case frameworkVersion
    }

    /// The bundle directory, relative to the scanned bundle.
    let bundle: [String]
    /// The code root, relative to the scanned bundle.
    let path: [String]
    let layout: Layout

    var sealPath: [String] { path + ["_CodeSignature", "CodeResources"] }

    var infoPlistPath: [String] {
        switch layout {
        case .contents: path + ["Info.plist"]
        case .frameworkVersion: path + ["Resources", "Info.plist"]
        }
    }

    /// Where the main executable named `name` sits, relative to the code root.
    func mainExecutable(_ name: String) -> [String] {
        switch layout {
        case .contents: ["MacOS", name]
        case .frameworkVersion: [name]
        }
    }

    /// The bundle's path for reports; empty for the scanned bundle.
    var name: String { bundle.joined(separator: "/") }
}

/// Resolves files in a signed bundle through every enclosing seal.
///
/// A file may be thinned only if the chain of seals from the scanned bundle
/// down to it accounts for it as code at every level: the innermost bundle
/// either seals it by cdhash (nested code) or names it as its main executable
/// in `Info.plist`, and each bundle above seals the next one by cdhash.
/// Anything else is a skip: a `hash`/`hash2` seal anywhere, a path no seal
/// mentions, and metadata that is missing or cannot be parsed.
///
/// This reads `CodeResources` as advisory input. `codesign --verify` stays the
/// authority on whether the signature is valid; this decides only whether
/// removing a slice could leave a valid signature valid.
struct SealChain {
    private let tree: FileTree
    private var roots: [[String]: Result<CodeRoot, Problem>] = [:]
    private var seals: [[String]: Result<ResourceSeal, Problem>] = [:]
    private var mainExecutables: [[String]: Result<String, Problem>] = [:]

    init(tree: FileTree) {
        self.tree = tree
    }

    /// Nil if the seal chain covers `relativePath` as code; otherwise why not.
    mutating func check(_ relativePath: String) -> SkipReason? {
        let path = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var bundle: [String] = []
        while true {
            let root: CodeRoot
            switch codeRoot(of: bundle) {
            case let .success(found): root = found
            case let .failure(problem): return .signatureMetadata(problem.description)
            }

            guard path.count > root.path.count, path.starts(with: root.path) else {
                if root.layout == .frameworkVersion, path.starts(with: bundle + ["Versions"]) {
                    return .unsealed("in a version of \(describe(root)) other than Versions/Current")
                }
                return .unsealed("outside the code of \(describe(root))")
            }
            let relative = Array(path.dropFirst(root.path.count))

            let seal: ResourceSeal
            switch resourceSeal(of: root) {
            case let .success(found): seal = found
            case let .failure(problem): return .signatureMetadata(problem.description)
            }

            let key = relative.joined(separator: "/")
            if seal.files.contains(key) { return .sealedAsData(by: root.name) }
            switch seal.files2[key] {
            case .code: return nil
            case .data: return .sealedAsData(by: root.name)
            case .symlink, .unrecognized:
                return .signatureMetadata("\(describe(root)) seals \(key) with an unrecognized entry")
            case nil: break
            }

            let main = mainExecutable(of: root)
            if case let .success(name) = main, relative == root.mainExecutable(name) {
                return nil
            }

            // Otherwise the file must lie inside nested code the seal covers.
            guard let nested = (1..<relative.count).reversed().first(where: {
                seal.files2[relative.prefix($0).joined(separator: "/")] != nil
            }) else {
                if case let .failure(problem) = main {
                    return .signatureMetadata("cannot confirm the main executable of \(describe(root)): \(problem)")
                }
                return .unsealed("\(describe(root)) does not seal \(key)")
            }
            let nestedKey = relative.prefix(nested).joined(separator: "/")
            guard seal.files2[nestedKey] == .code else {
                return .signatureMetadata("\(describe(root)) seals \(nestedKey) as something other than code")
            }
            bundle = root.path + relative.prefix(nested)
        }
    }

    private func describe(_ root: CodeRoot) -> String {
        root.bundle.isEmpty ? "the bundle" : root.name
    }

    private mutating func codeRoot(of bundle: [String]) -> Result<CodeRoot, Problem> {
        if let cached = roots[bundle] { return cached }
        let result = Result { () throws(Problem) in try findCodeRoot(of: bundle) }
        roots[bundle] = result
        return result
    }

    private func findCodeRoot(of bundle: [String]) throws(Problem) -> CodeRoot {
        let name = bundle.isEmpty ? "the bundle" : bundle.joined(separator: "/")
        if try tree.kind(bundle + ["Contents"]) == .directory {
            return CodeRoot(bundle: bundle, path: bundle + ["Contents"], layout: .contents)
        }
        guard try tree.kind(bundle + ["Versions"]) == .directory else {
            throw Problem("\(name) has neither Contents nor Versions")
        }
        let current = bundle + ["Versions", "Current"]
        guard try tree.kind(current) == .symlink else {
            throw Problem("\(name) has no Versions/Current symlink")
        }
        // Current must name a sibling version directory, nothing further.
        let version = try tree.readLink(current)
        let versionPath = bundle + ["Versions", version]
        guard !version.isEmpty, version != ".", version != "..", !version.contains("/"),
              try tree.kind(versionPath) == .directory
        else {
            throw Problem("\(name)/Versions/Current does not name a version directory")
        }
        return CodeRoot(bundle: bundle, path: versionPath, layout: .frameworkVersion)
    }

    private mutating func resourceSeal(of root: CodeRoot) -> Result<ResourceSeal, Problem> {
        if let cached = seals[root.path] { return cached }
        let result = Result { () throws(Problem) in
            do {
                return try ResourceSeal(tree.read(root.sealPath, limit: ResourceSeal.sizeLimit))
            } catch {
                throw Problem("\(describe(root)): \(error)")
            }
        }
        seals[root.path] = result
        return result
    }

    /// The main executable's name from `CFBundleExecutable`, validated as a
    /// single path component.
    private mutating func mainExecutable(of root: CodeRoot) -> Result<String, Problem> {
        if let cached = mainExecutables[root.path] { return cached }
        let result = Result { () throws(Problem) in
            let data = try tree.read(root.infoPlistPath, limit: 16 << 20)
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            guard let info = plist as? [String: Any] else {
                throw Problem("Info.plist is not a property list dictionary")
            }
            guard let name = info["CFBundleExecutable"] as? String else {
                throw Problem("Info.plist has no CFBundleExecutable")
            }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw Problem("CFBundleExecutable \"\(name)\" is not a file name")
            }
            return name
        }
        mainExecutables[root.path] = result
        return result
    }
}
