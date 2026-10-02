import Foundation
import Testing
import ThinnerCore

// MARK: - Synthetic headers

@Suite struct ArchitectureDecisionTests {
    /// An x86_64 slice large enough to push arm64 past the next 2^14 boundary,
    /// so removing it actually saves space.
    static let bigIntel = Entry.x86_64(size: 20000)
    static let laterARM64 = Entry.arm64(offset: 32768)
    static let bigFileSize: UInt64 = 32768 + 10000

    private func decide(_ entries: [Entry], fileSize: UInt64) -> Decision {
        Decision.architectures(FatBinary.parse(fatHeader(entries), fileSize: fileSize), fileSize: fileSize)
    }

    @Test func arm64PlusIntelIsEligible() {
        // Thinned: one-entry header, arm64 padded to 16384, then 10000 bytes.
        #expect(decide([Self.bigIntel, Self.laterARM64], fileSize: Self.bigFileSize)
            == .eligible(removing: [.x86_64], savedBytes: Self.bigFileSize - (16384 + 10000)))
    }

    @Test func everyIntelSliceIsRemoved() {
        let haswell = Entry(cpuType: cpuX86_64, cpuSubtype: 8, offset: 32768, size: 20000, align: 12)
        let arm = Entry.arm64(offset: 65536)
        #expect(decide([Self.bigIntel, haswell, arm], fileSize: 65536 + 10000)
            == .eligible(removing: [.x86_64, .x86_64h], savedBytes: 65536 - 16384))
    }

    @Test func otherArchitecturesAreKept() {
        let i386 = Entry(cpuType: 7, cpuSubtype: 3, offset: 49152, size: 1000, align: 12)
        let decision = decide([Self.bigIntel, Self.laterARM64, i386], fileSize: 49152 + 1000)
        guard case let .eligible(removing, _) = decision else {
            Issue.record("expected .eligible, got \(decision)")
            return
        }
        #expect(removing == [.x86_64])
    }

    /// The standard small layout: x86_64 ends before arm64's 2^14 boundary, so
    /// arm64 would stay at the same offset and the file would not shrink.
    @Test func paddingThatAbsorbsIntelMeansNoSavings() {
        #expect(decide(standardEntries, fileSize: standardFileSize) == .skip(.noSavings))
    }

    @Test func arm64eAloneIsNotEnough() {
        let arm64e = Entry(cpuType: cpuARM64, cpuSubtype: 2, offset: 32768, size: 10000, align: 14)
        #expect(decide([Self.bigIntel, arm64e], fileSize: Self.bigFileSize) == .skip(.noARM64))
    }

    @Test func intelOnlyIsNeverTouched() {
        let haswell = Entry(cpuType: cpuX86_64, cpuSubtype: 8, offset: 32768, size: 10000, align: 12)
        #expect(decide([Self.bigIntel, haswell], fileSize: Self.bigFileSize) == .skip(.noARM64))
    }

    @Test func noIntelMeansNothingToRemove() {
        let arm64e = Entry(cpuType: cpuARM64, cpuSubtype: 2, offset: 32768, size: 10000, align: 14)
        #expect(decide([.arm64(), arm64e], fileSize: 32768 + 10000) == .skip(.noIntel))
    }

    @Test func singleSliceUniversalHasNothingToRemove() {
        #expect(decide([.arm64()], fileSize: 16384 + 10000) == .skip(.noIntel))
        #expect(decide([.x86_64()], fileSize: 4096 + 8000) == .skip(.noARM64))
    }

    @Test func notFatIsNotUniversal() {
        #expect(Decision.architectures(.notFat, fileSize: 100) == .skip(.notUniversal))
    }

    @Test func malformedPassesItsProblemThrough() {
        #expect(Decision.architectures(.malformed("slices overlap"), fileSize: 100)
            == .skip(.malformed("slices overlap")))
    }

    @Test func reasonsDescribeThemselves() {
        #expect(SkipReason.noARM64.description == "no arm64 slice")
        #expect(SkipReason.malformed("x").description == "malformed universal binary: x")
    }
}

// MARK: - Real fixtures

@Suite struct ArchitectureDecisionFixtureTests {
    enum Expected: Sendable, Equatable {
        case eligible(removing: Set<Arch>)
        case skip(SkipReason)
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let path: String
        let expected: Expected
        var testDescription: String { path }
    }

    static let nested = "bundles/Nested.app/Contents/Frameworks"

    static let cases: [Case] = [
        .init(path: "macho/fat-arm64-x86_64", expected: .eligible(removing: [.x86_64])),
        .init(path: "macho/fat64-arm64-x86_64", expected: .eligible(removing: [.x86_64])),
        .init(path: "macho/fat-arm64-x86_64-x86_64h", expected: .eligible(removing: [.x86_64, .x86_64h])),
        .init(path: "macho/quarantined-fat-arm64-x86_64", expected: .eligible(removing: [.x86_64])),
        .init(path: "macho/fat-arm64e-x86_64", expected: .skip(.noARM64)),
        .init(path: "macho/thin-arm64", expected: .skip(.notUniversal)),
        .init(path: "macho/thin-x86_64", expected: .skip(.notUniversal)),
        .init(path: "java/Hello.class", expected: .skip(.notUniversal)),
        .init(path: "\(nested)/libarm64e.dylib", expected: .skip(.noARM64)),
        .init(path: "\(nested)/libintel.dylib", expected: .skip(.noARM64)),
        .init(path: "\(nested)/libapple.dylib", expected: .skip(.noIntel)),
        .init(path: "\(nested)/libthin.dylib", expected: .skip(.notUniversal)),
    ]

    @Test(arguments: cases)
    func decides(_ fixture: Case) throws {
        let bytes = Array(try Data(contentsOf: Fixtures.url(fixture.path)))
        let fileSize = UInt64(bytes.count)
        let parsed = FatBinary.parse(Array(bytes.prefix(FatBinary.maxHeaderLength)), fileSize: fileSize)
        let decision = Decision.architectures(parsed, fileSize: fileSize)

        switch (decision, fixture.expected) {
        case let (.eligible(removing, saved), .eligible(expected)):
            #expect(removing == expected)
            let binary = try #require(parsed.fat)
            #expect(saved == fileSize - binary.size(removing: expected))
            #expect(saved > 0)
        case let (.skip(reason), .skip(expected)):
            #expect(reason == expected)
        default:
            Issue.record("expected \(fixture.expected), got \(decision)")
        }
    }
}
