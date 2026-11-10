import Foundation
import Testing
@testable import ThinnerCore

@Suite struct RestoreReportTests {
    @Test func outcomesKeepTheirExitCodesAndDetails() throws {
        let cases: [(RestoreResult.Outcome, MutationReport.Outcome)] = [
            (.restored, .committed), (.nothingToRestore("already original"), .nothingToDo),
            (.refused("changed app"), .refused), (.pending("quit app and retry"), .recoveryPending),
            (.recoveryFailed("verification failed"), .recoveryFailed)
        ]
        for (outcome, expected) in cases {
            var result = RestoreResult(outcome)
            result.restored = ["Contents/MacOS/example"]
            result.alreadyOriginal = ["Contents/Frameworks/example"]
            result.backupLocations = ["/fixture/.thinner-example"]
            result.notes = ["Keep backups\n\u{1B}[31m"]
            let report = MutationCommands.restoreReport(URL(filePath: "/fixture/Example.app"), result)
            #expect(report.command == "restore")
            #expect(report.exitCode == outcome.exitCode)
            #expect(report.apps.first?.outcome == expected)
            let decoded = try JSONDecoder().decode(MutationReport.self, from: Data(report.json().utf8))
            #expect(decoded == report)
            let details = try #require(decoded.apps.first?.restore)
            #expect(details.restored == result.restored)
            #expect(details.alreadyOriginal == result.alreadyOriginal)
            #expect(details.backupLocations == result.backupLocations)
            #expect(details.notes == result.notes)
            #expect(report.text.contains("Restored: Contents/MacOS/example"))
            #expect(report.text.contains("Already original: Contents/Frameworks/example"))
            #expect(report.text.contains("Backups retained: /fixture/.thinner-example"))
            #expect(report.text.contains("Note: Keep backups"))
            #expect(!report.text.contains("\u{1B}"))
        }
    }

    @Test func existingReportsDecodeWithoutRestoreDetails() throws {
        let json = #"{"schemaVersion":1,"command":"apply","apps":[{"path":"/fixture","outcome":"committed","reason":"done"}],"problems":[]}"#
        let report = try JSONDecoder().decode(MutationReport.self, from: Data(json.utf8))
        #expect(report.apps.first?.restore == nil)
        #expect(report.text == "/fixture: committed — done")
    }
}
