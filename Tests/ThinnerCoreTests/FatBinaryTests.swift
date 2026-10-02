import Foundation
import Testing
import ThinnerCore

// MARK: - Synthetic headers

@Suite struct FatBinaryParseTests {
    @Test(arguments: [false, true])
    func parsesStandardLayout(fat64: Bool) throws {
        let binary = try #require(FatBinary.parse(fatHeader(fat64: fat64, standardEntries), fileSize: standardFileSize).fat)
        #expect(binary.is64 == fat64)
        #expect(binary.slices.map(\.arch) == [.x86_64, .arm64])
        #expect(binary.slices.map(\.offset) == [4096, 16384])
        #expect(binary.slices.map(\.size) == [8000, 10000])
        #expect(binary.slices.map(\.align) == [12, 14])
    }

    struct NotFatCase: CustomTestStringConvertible, Sendable {
        let name: String
        let bytes: [UInt8]
        var testDescription: String { name }
    }

    static let notFatCases: [NotFatCase] = [
        .init(name: "shorter than a fat header", bytes: [0xCA, 0xFE, 0xBA, 0xBE]),
        .init(name: "thin Mach-O", bytes: [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]),
        .init(name: "no slices", bytes: fatHeader(count: 0, [])),
        .init(name: "more slices than the bound", bytes: fatHeader(count: FatBinary.maxSlices + 1, [])),
        // Java class 52 (Java 8): minor 0x0000, major 0x0034 read as nfat_arch.
        .init(name: "Java class header", bytes: [0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34]),
    ]

    @Test(arguments: notFatCases)
    func rejectsNonFat(_ fixture: NotFatCase) {
        #expect(FatBinary.parse(fixture.bytes, fileSize: 1 << 20) == .notFat)
    }

    struct MalformedCase: CustomTestStringConvertible, Sendable {
        let name: String
        let bytes: [UInt8]
        let fileSize: UInt64
        let problem: String
        var testDescription: String { name }
    }

    static let malformedCases: [MalformedCase] = [
        .init(name: "header shorter than nfat_arch declares",
              bytes: fatHeader(count: 2, [.x86_64()]), fileSize: standardFileSize,
              problem: "header is truncated"),
        .init(name: "file smaller than its header",
              bytes: fatHeader(standardEntries), fileSize: 20,
              problem: "header is truncated"),
        .init(name: "alignment out of range",
              bytes: fatHeader([.x86_64(), .arm64(offset: 1 << 17, align: 17)]), fileSize: 1 << 18,
              problem: "alignment 2^17 is out of range"),
        .init(name: "empty slice",
              bytes: fatHeader([.x86_64(), .arm64(size: 0)]), fileSize: standardFileSize,
              problem: "is empty"),
        .init(name: "slice inside the header",
              bytes: fatHeader([.x86_64(offset: 0, align: 0), .arm64()]), fileSize: standardFileSize,
              problem: "overlaps the fat header"),
        .init(name: "misaligned slice",
              bytes: fatHeader([.x86_64(), .arm64(offset: 16385)]), fileSize: standardFileSize + 1,
              problem: "is not aligned to 2^14"),
        .init(name: "slice past end of file",
              bytes: fatHeader(standardEntries), fileSize: standardFileSize - 1,
              problem: "extends past the end of the file"),
        .init(name: "offset past end of file",
              bytes: fatHeader(fat64: true, [.x86_64(), .arm64(offset: 1 << 40)]), fileSize: standardFileSize,
              problem: "extends past the end of the file"),
        // offset + size would overflow UInt64; the parser must not trap.
        .init(name: "size overflows",
              bytes: fatHeader(fat64: true, [.x86_64(), .arm64(size: .max)]), fileSize: standardFileSize,
              problem: "extends past the end of the file"),
        .init(name: "overlapping slices",
              bytes: fatHeader([.x86_64(size: 20000), .arm64()]), fileSize: standardFileSize,
              problem: "overlap"),
        .init(name: "duplicate architecture",
              bytes: fatHeader([.arm64(), .arm64(offset: 32768)]), fileSize: 32768 + 10000,
              problem: "an architecture appears twice"),
    ]

    @Test(arguments: malformedCases)
    func rejectsMalformed(_ fixture: MalformedCase) {
        let result = FatBinary.parse(fixture.bytes, fileSize: fixture.fileSize)
        guard case let .malformed(problem) = result else {
            Issue.record("expected .malformed, got \(result)")
            return
        }
        #expect(problem.contains(fixture.problem), "\(problem)")
    }

    @Test func maxHeaderLengthHoldsLargestAcceptedHeader() {
        #expect(FatBinary.maxHeaderLength == 8 + 32 * Int(FatBinary.maxSlices))
    }
}

// MARK: - Architecture decoding

@Suite struct ArchTests {
    struct DecodeCase: CustomTestStringConvertible, Sendable {
        let cpuType: Int32
        let cpuSubtype: Int32
        let arch: Arch
        var testDescription: String { "\(arch) from subtype 0x\(String(UInt32(bitPattern: cpuSubtype), radix: 16))" }
    }

    static let decodeCases: [DecodeCase] = [
        .init(cpuType: cpuARM64, cpuSubtype: 0, arch: .arm64),
        .init(cpuType: cpuARM64, cpuSubtype: 1, arch: .arm64),
        .init(cpuType: cpuARM64, cpuSubtype: 2, arch: .arm64e),
        // arm64e with the pointer-authentication ABI capability bits set.
        .init(cpuType: cpuARM64, cpuSubtype: Int32(bitPattern: 0x8000_0002), arch: .arm64e),
        .init(cpuType: cpuX86_64, cpuSubtype: 3, arch: .x86_64),
        // x86_64 executables carry CPU_SUBTYPE_LIB64 in the capability byte.
        .init(cpuType: cpuX86_64, cpuSubtype: Int32(bitPattern: 0x8000_0003), arch: .x86_64),
        .init(cpuType: cpuX86_64, cpuSubtype: 8, arch: .x86_64h),
        .init(cpuType: 7, cpuSubtype: 3, arch: .other(cpuType: 7, cpuSubtype: 3)), // i386
        .init(cpuType: cpuARM64, cpuSubtype: 3, arch: .other(cpuType: cpuARM64, cpuSubtype: 3)),
    ]

    @Test(arguments: decodeCases)
    func decodes(_ fixture: DecodeCase) {
        #expect(Arch(cpuType: fixture.cpuType, cpuSubtype: fixture.cpuSubtype) == fixture.arch)
    }

    @Test func onlyIntelSlicesAreIntel() {
        #expect(Arch.x86_64.isIntel)
        #expect(Arch.x86_64h.isIntel)
        #expect(!Arch.arm64.isIntel)
        #expect(!Arch.arm64e.isIntel)
        #expect(!Arch.other(cpuType: 7, cpuSubtype: 3).isIntel)
    }

    @Test func descriptionsMatchLipoNames() {
        #expect([Arch.arm64, .arm64e, .x86_64, .x86_64h].map(\.description) == ["arm64", "arm64e", "x86_64", "x86_64h"])
        #expect(Arch.other(cpuType: 7, cpuSubtype: 3).description == "cputype 0x7 subtype 0x3")
    }
}

// MARK: - Size estimate

@Suite struct FatBinarySizeTests {
    private func standard(fat64: Bool = false) throws -> FatBinary {
        try #require(FatBinary.parse(fatHeader(fat64: fat64, standardEntries), fileSize: standardFileSize).fat)
    }

    @Test func removingNothingReproducesTheLayout() throws {
        #expect(try standard().size(removing: []) == standardFileSize)
        #expect(try standard(fat64: true).size(removing: []) == standardFileSize)
    }

    @Test func removingIntelKeepsArm64AtItsAlignment() throws {
        // One-entry header (28 bytes), then arm64 padded up to 2^14.
        #expect(try standard().size(removing: [.x86_64]) == 16384 + 10000)
    }

    @Test func removingArm64KeepsX86AtItsAlignment() throws {
        #expect(try standard().size(removing: [.arm64]) == 4096 + 8000)
    }

    @Test func removingAbsentArchChangesNothing() throws {
        #expect(try standard().size(removing: [.x86_64h, .arm64e]) == standardFileSize)
    }
}

// MARK: - Real fixtures

@Suite struct FatBinaryFixtureTests {
    struct FatCase: CustomTestStringConvertible, Sendable {
        let path: String
        let archs: Set<Arch>
        let is64: Bool
        var testDescription: String { path }
    }

    static let electronFramework = "bundles/Electron.app/Contents/Frameworks/Electron Framework.framework"

    static let fatCases: [FatCase] = [
        .init(path: "macho/fat-arm64-x86_64", archs: [.arm64, .x86_64], is64: false),
        .init(path: "macho/fat-arm64e-x86_64", archs: [.arm64e, .x86_64], is64: false),
        .init(path: "macho/fat-arm64-x86_64-x86_64h", archs: [.arm64, .x86_64, .x86_64h], is64: false),
        .init(path: "macho/fat64-arm64-x86_64", archs: [.arm64, .x86_64], is64: true),
        .init(path: "bundles/Nested.app/Contents/Frameworks/libintel.dylib", archs: [.x86_64, .x86_64h], is64: false),
        .init(path: "bundles/Nested.app/Contents/Frameworks/libapple.dylib", archs: [.arm64, .arm64e], is64: false),
        .init(path: "\(electronFramework)/Versions/A/Electron Framework", archs: [.arm64, .x86_64], is64: false),
        .init(path: "\(electronFramework)/Versions/A/Libraries/libEGL.dylib", archs: [.arm64, .x86_64], is64: false),
    ]

    @Test(arguments: fatCases)
    func parsesFixture(_ fixture: FatCase) throws {
        let bytes = try Self.bytes(fixture.path)
        let binary = try #require(Self.parse(bytes).fat)
        #expect(Set(binary.slices.map(\.arch)) == fixture.archs)
        #expect(binary.is64 == fixture.is64)
        for slice in binary.slices {
            #expect(FatBinary.checkSliceHeader(Self.sliceBytes(bytes, slice), for: slice) == nil)
        }
    }

    @Test(arguments: ["java/Hello.class", "macho/thin-arm64", "macho/thin-x86_64"])
    func rejectsNonFatFixture(_ path: String) throws {
        #expect(try Self.parse(Self.bytes(path)) == .notFat)
    }

    @Test func sliceHeaderMismatchIsReported() throws {
        let bytes = try Self.bytes("macho/fat-arm64-x86_64")
        let binary = try #require(Self.parse(bytes).fat)
        let arm = try #require(binary.slices.first(where: { $0.arch == .arm64 }))
        let intel = try #require(binary.slices.first(where: { $0.arch == .x86_64 }))

        let armBytes = Self.sliceBytes(bytes, arm)
        #expect(FatBinary.checkSliceHeader(armBytes, for: intel) == "slice x86_64 contains code for a different CPU")
        #expect(FatBinary.checkSliceHeader(Array(bytes.prefix(8)), for: arm) == "slice arm64 is not a Mach-O image")
        #expect(FatBinary.checkSliceHeader(Array(armBytes.prefix(4)), for: arm) == "slice arm64 is truncated")
    }

    @Test func bigEndianMachOHeaderIsRead() throws {
        let bytes = try Self.bytes("macho/fat-arm64-x86_64")
        let binary = try #require(Self.parse(bytes).fat)
        let arm = try #require(binary.slices.first(where: { $0.arch == .arm64 }))
        let header = be32(0xFEED_FACF) + be32(UInt32(bitPattern: cpuARM64))
        #expect(FatBinary.checkSliceHeader(header, for: arm) == nil)
    }

    struct LipoCase: CustomTestStringConvertible, Sendable {
        let path: String
        let remove: Set<Arch>
        var testDescription: String { "\(path) -remove \(remove.map(\.description).sorted())" }
    }

    static let lipoCases: [LipoCase] = [
        .init(path: "macho/fat-arm64-x86_64", remove: [.x86_64]),
        .init(path: "macho/fat-arm64e-x86_64", remove: [.x86_64]),
        .init(path: "macho/fat-arm64-x86_64-x86_64h", remove: [.x86_64, .x86_64h]),
        .init(path: "macho/fat64-arm64-x86_64", remove: [.x86_64]),
        .init(path: "\(electronFramework)/Versions/A/Electron Framework", remove: [.x86_64]),
    ]

    /// The estimate must match what `lipo -remove` actually writes, and lipo
    /// must leave every kept slice byte-for-byte intact: the write path's
    /// slice-hash check depends on it. Runs on a temporary copy's output only.
    @Test(arguments: lipoCases)
    func sizeEstimateMatchesLipo(_ fixture: LipoCase) throws {
        let source = try Fixtures.url(fixture.path)
        let original = try Self.bytes(fixture.path)
        let binary = try #require(Self.parse(original).fat)

        let dir = FileManager.default.temporaryDirectory.appending(path: "thinner-lipo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appending(path: "thinned")

        var arguments = [source.path]
        for arch in fixture.remove.map(\.description).sorted() {
            arguments += ["-remove", arch]
        }
        arguments += ["-output", output.path]
        let lipo = try Shell.run("/usr/bin/lipo", arguments: arguments)
        try #require(lipo.status == 0, "\(lipo.output)")

        let thinned = Array(try Data(contentsOf: output))
        #expect(UInt64(thinned.count) == binary.size(removing: fixture.remove))

        let result = try #require(FatBinary.parse(Array(thinned.prefix(FatBinary.maxHeaderLength)), fileSize: UInt64(thinned.count)).fat)
        let kept = binary.slices.filter { !fixture.remove.contains($0.arch) }
        #expect(result.slices.map(\.arch) == kept.map(\.arch))
        for (before, after) in zip(kept, result.slices) {
            #expect(Self.sliceBytes(thinned, after) == Self.sliceBytes(original, before), "\(before.arch)")
        }
    }

    private static func bytes(_ path: String) throws -> [UInt8] {
        Array(try Data(contentsOf: Fixtures.url(path)))
    }

    private static func parse(_ bytes: [UInt8]) -> FatParseResult {
        FatBinary.parse(Array(bytes.prefix(FatBinary.maxHeaderLength)), fileSize: UInt64(bytes.count))
    }

    private static func sliceBytes(_ bytes: [UInt8], _ slice: FatSlice) -> [UInt8] {
        Array(bytes[Int(slice.offset)..<Int(slice.offset + slice.size)])
    }
}
