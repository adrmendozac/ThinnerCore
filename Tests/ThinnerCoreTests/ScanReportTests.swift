import Foundation
import Testing
import ThinnerCore

@Suite struct ScanReportTests {
    private func fixtureReport(excludes: [URL] = [], options: ScanOptions? = nil) throws -> ScanReport {
        let root = try Fixtures.root()
        let result = AppScanner.scan(root, options: options ?? hermeticOptions(excludes: excludes))
        return ScanReport(root: root, excludes: excludes, result: result)
    }

    @Test func jsonRoundTripsAndCarriesTheSchemaVersion() throws {
        let report = try fixtureReport()
        let json = try report.json()
        let decoded = try JSONDecoder().decode(ScanReport.self, from: Data(json.utf8))
        #expect(decoded == report)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.dryRun)
        #expect(decoded.complete)
    }

    @Test func totalsAreTheSumOfTheApps() throws {
        let report = try fixtureReport()
        #expect(report.totals.apps == report.apps.count)
        #expect(report.totals.universalFiles == report.apps.reduce(0) { $0 + $1.universalFiles })
        #expect(report.totals.eligibleFiles == report.apps.reduce(0) { $0 + $1.eligibleFiles })
        #expect(report.totals.removableBytes == report.apps.reduce(0) { $0 + $1.removableBytes })
        for app in report.apps {
            #expect(app.universalFiles == app.files.count)
            #expect(app.eligibleFiles == app.files.count(where: \.eligible))
            #expect(app.removableBytes == app.files.reduce(0) { $0 + $1.savedBytes })
        }
    }

    @Test func outputIsDeterministic() throws {
        // Same inputs, including the (throwaway) preferences path the report names.
        let options = hermeticOptions()
        #expect(try fixtureReport(options: options).json() == fixtureReport(options: options).json())
    }

    @Test func filesCarryCodesAndRemovedSlices() throws {
        let report = try fixtureReport()
        let signed = try #require(report.apps.first { $0.path == "bundles/Signed.app" })
        let node = try #require(signed.files.first { $0.path == "Contents/Resources/addon.node" })
        #expect(!node.eligible)
        #expect(node.skip?.code == "sealedAsData")
        #expect(node.removing == nil)
        #expect(node.savedBytes == 0)

        let main = try #require(signed.files.first { $0.path == "Contents/MacOS/Signed" })
        #expect(main.eligible)
        #expect(main.removing == ["x86_64"])
        #expect(main.skip == nil)
    }

    @Test func skippedAppHasReasonAndZeroCounts() throws {
        let excluded = try Fixtures.url("bundles/Nested.app")
        let report = try fixtureReport(excludes: [excluded])
        let nested = try #require(report.apps.first { $0.path == "bundles/Nested.app" })
        #expect(nested.skip?.code == "excluded")
        #expect(nested.skip?.detail == "excluded by the user (\(excluded.path))")
        #expect(nested.eligibleFiles == 0)
        #expect(report.totals.skippedApps == 1)
    }

    /// The human report prints the same totals the JSON carries.
    @Test func textReportShowsTheJSONTotals() throws {
        let report = try fixtureReport()
        let text = TextReport.render(report)
        let totals = report.totals
        #expect(text.contains("Total: \(totals.apps) apps · \(totals.universalFiles) universal files · \(totals.eligibleFiles) eligible"))
        #expect(text.contains("dry run: nothing on disk was changed"))
        #expect(!text.contains("Incomplete scan"))
        for app in report.apps {
            #expect(text.contains("\(app.universalFiles) universal · \(app.eligibleFiles) eligible"))
        }
    }

    @Test func reasonCodesAreDistinct() {
        let fileCodes = [SkipReason.notUniversal, .malformed(""), .noARM64, .noIntel, .noSavings, .hardLinked,
                         .sealedAsData(by: ""), .unsealed(""), .signatureMetadata("")].map(\.code)
        let appCodes = [AppSkipReason.protectedLocation(""), .excluded(""), .containsExclusion(""), .bundleMetadata(""),
                        .scriptOnly(""), .rosettaFlagged(user: ""), .rosettaInconclusive(""),
                        .intelArchitecturePriority([]), .signatureInvalid("")].map(\.code)
        #expect(Set(fileCodes).count == fileCodes.count)
        #expect(Set(appCodes).count == appCodes.count)
    }
}
