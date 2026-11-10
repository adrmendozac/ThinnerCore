import Foundation
import Testing
@testable import ThinnerCore

@Suite struct UpdatePlannerTests {
    private func version(_ build: String = "2", team: String = "TEAM", requirement: String = "vendor requirement",
                         id: String = "example.fixture", seal: String = "seal") -> UpdatePlanner.Version {
        .init(app: AppIdentity(bundleIdentifier: id, bundleVersion: build, shortVersion: build,
                              codeResourcesHash: seal),
              signing: .init(teamID: team, designatedRequirement: requirement))
    }

    private func observation(_ value: UpdatePlanner.Version? = nil, token: String = "quiet",
                             signature: Bool = true, processes: UpdatePlanner.ProcessState = .idle,
                             recovery: UpdatePlanner.RecoveryState = .clear, complete: Bool = true,
                             skip: String? = nil, eligible: Int = 1) -> UpdatePlanner.Observation {
        .init(version: value ?? version(), changeToken: token, signatureVerified: signature,
              processes: processes, recovery: recovery, scanComplete: complete,
              skipReason: skip, eligibleFiles: eligible)
    }

    private func settled(_ value: UpdatePlanner.Observation) -> UpdatePlanner.Decision {
        var planner = UpdatePlanner(baseline: version("1"), settlingInterval: 10)
        _ = planner.observe(value, at: 0)
        return planner.observe(value, at: 10)
    }

    @Test func updateMustStayQuietBeforeFreshPreflight() {
        var planner = UpdatePlanner(baseline: version("1"), settlingInterval: 10)
        #expect(planner.observe(observation(), at: 0) == .waiting)
        #expect(planner.observe(observation(), at: 9) == .waiting)
        #expect(planner.observe(observation(token: "changed"), at: 10) == .waiting)
        #expect(planner.observe(observation(token: "changed"), at: 19) == .waiting)
        #expect(planner.observe(observation(token: "changed"), at: 20) == .readyForPreflight)
        planner.invalidate()
        #expect(planner.observe(observation(token: "changed"), at: 30) == .waiting)
    }

    @Test func relaunchAndUpdaterRestartTheQuietPeriod() {
        for state in [UpdatePlanner.ProcessState.appRunning, .updaterRunning, .unknown] {
            var planner = UpdatePlanner(baseline: version("1"), settlingInterval: 10)
            _ = planner.observe(observation(), at: 0)
            #expect(planner.observe(observation(processes: state), at: 10) != .readyForPreflight)
            #expect(planner.observe(observation(), at: 20) == .waiting)
            #expect(planner.observe(observation(), at: 30) == .readyForPreflight)
        }
    }

    @Test func recoveryAlwaysBlocksEvenForPreviouslyHandledVersions() {
        #expect(settled(observation(recovery: .pending)) == .recoveryRequired)
        #expect(settled(observation(recovery: .failed)) == .recoveryFailed)
        #expect(settled(observation(recovery: .unknown)) == .recoveryUnknown)
        var planner = UpdatePlanner(baseline: version("1"))
        planner.record(version(), outcome: .committed)
        #expect(planner.observe(observation(recovery: .pending), at: 0) == .recoveryRequired)
    }

    @Test func alteredOrUnverifiedIdentityCannotQualifyAsAnUpdate() {
        #expect(settled(observation(signature: false)) == .invalidSignature)
        #expect(settled(observation(version(team: "OTHER"))) == .signingIdentityChanged)
        #expect(settled(observation(version(requirement: "other requirement"))) == .signingIdentityChanged)
        #expect(settled(observation(version(team: ""))) == .missingIdentity)
        #expect(settled(observation(version(id: "other.app"))) == .bundleIdentityChanged)
        #expect(settled(observation(version("1", seal: "changed"))) == .versionUnchanged)
    }

    @Test func freshScanPolicyAndNativeOnlyUpdatesAreRespected() {
        #expect(settled(observation(complete: false)) == .scanIncomplete)
        #expect(settled(observation(skip: "excluded")) == .skipped("excluded"))
        #expect(settled(observation(skip: "notOnAllowList")) == .skipped("notOnAllowList"))
        #expect(settled(observation(eligible: 0)) == .nothingToThin)
    }

    @Test func terminalOutcomesSurviveEncodingAndPreventVersionRetries() throws {
        for outcome in [UpdatePlanner.Outcome.committed, .rolledBack, .nothingToThin] {
            var planner = UpdatePlanner(baseline: version("1"), settlingInterval: 10)
            planner.record(version(), outcome: outcome)
            let data = try JSONEncoder().encode(planner.completed)
            let restored = try JSONDecoder().decode([UpdatePlanner.CompletedVersion].self, from: data)
            var restarted = UpdatePlanner(baseline: version("1"), settlingInterval: 10, completed: restored)
            let rebuilt = observation(version(seal: "rebuilt"))
            _ = restarted.observe(rebuilt, at: 0)
            #expect(restarted.observe(rebuilt, at: 10) == .alreadyHandled)
            _ = restarted.observe(observation(version("3")), at: 20)
            #expect(restarted.observe(observation(version("3")), at: 30) == .readyForPreflight)
        }
    }

    @Test func invalidClockAndSettingsFailClosed() {
        var planner = UpdatePlanner(baseline: version("1"), settlingInterval: -1)
        #expect(planner.settlingInterval == 30)
        #expect(planner.observe(observation(), at: .nan) == .waiting)
        _ = planner.observe(observation(), at: 100)
        #expect(planner.observe(observation(), at: 90) == .waiting)
        #expect(planner.observe(observation(), at: 119) == .waiting)
        #expect(planner.observe(observation(), at: 120) == .readyForPreflight)
    }
}
