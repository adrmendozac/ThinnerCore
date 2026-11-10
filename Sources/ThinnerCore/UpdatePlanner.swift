import Foundation

/// Read-only decisions for the future update watcher. A ready result requests a
/// fresh preflight; it never authorizes a file change or bypasses the release gate.
/// Keep one planner per app. The watcher must supply freshly verified observations
/// and persist completed versions before this can be used for unattended work.
struct UpdatePlanner: Sendable {
    struct SigningIdentity: Codable, Equatable, Sendable {
        let teamID: String
        let designatedRequirement: String

        var isComplete: Bool {
            !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !designatedRequirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    struct Version: Codable, Equatable, Sendable {
        let app: AppIdentity
        let signing: SigningIdentity
    }

    enum ProcessState: Sendable {
        case idle, appRunning, updaterRunning, unknown
    }

    enum RecoveryState: Sendable {
        case clear, pending, failed, unknown
    }

    struct Observation: Sendable {
        let version: Version
        /// A token that changes with any observed bundle activity, including
        /// changes that leave Info.plist and CodeResources untouched.
        let changeToken: String
        let signatureVerified: Bool
        let processes: ProcessState
        let recovery: RecoveryState
        let scanComplete: Bool
        let skipReason: String?
        let eligibleFiles: Int
    }

    enum Decision: Equatable, Sendable {
        case waiting
        case appRunning
        case updaterRunning
        case processVisibilityUnknown
        case recoveryRequired
        case recoveryFailed
        case recoveryUnknown
        case invalidSignature
        case signingIdentityChanged
        case missingIdentity
        case bundleIdentityChanged
        case versionUnchanged
        case alreadyHandled
        case scanIncomplete
        case skipped(String)
        case nothingToThin
        case readyForPreflight
    }

    enum Outcome: String, Codable, Sendable {
        case committed, nothingToThin, rolledBack
    }

    struct CompletedVersion: Codable, Sendable {
        let version: Version
        let outcome: Outcome
    }

    /// The identity from a previous successful manual thinning operation.
    let baseline: Version
    let settlingInterval: TimeInterval
    private(set) var completed: [CompletedVersion]
    private var lastVersion: Version?
    private var lastToken: String?
    private var quietSince: TimeInterval?
    private var lastObservedAt: TimeInterval?

    init(baseline: Version, settlingInterval: TimeInterval = 30,
         completed: [CompletedVersion] = []) {
        self.baseline = baseline
        // Invalid settings must not silently disable the settling period.
        self.settlingInterval = settlingInterval.isFinite && settlingInterval > 0 ? settlingInterval : 30
        self.completed = completed
    }

    /// Call when a file event arrives or observation fails. A later successful
    /// read must establish a new quiet period, even if the version is unchanged.
    mutating func invalidate() {
        quietSince = nil
        lastToken = nil
        lastVersion = nil
        lastObservedAt = nil
    }

    /// `now` is elapsed time from a monotonic clock, not a wall-clock timestamp.
    mutating func observe(_ observation: Observation, at now: TimeInterval) -> Decision {
        guard now.isFinite else { invalidate(); return .waiting }
        if lastVersion != observation.version || lastToken != observation.changeToken
            || lastObservedAt.map({ now < $0 }) == true || quietSince == nil {
            quietSince = now
        }
        lastVersion = observation.version
        lastToken = observation.changeToken
        lastObservedAt = now

        switch observation.recovery {
        case .pending: quietSince = nil; return .recoveryRequired
        case .failed: quietSince = nil; return .recoveryFailed
        case .unknown: quietSince = nil; return .recoveryUnknown
        case .clear: break
        }
        switch observation.processes {
        case .appRunning: quietSince = nil; return .appRunning
        case .updaterRunning: quietSince = nil; return .updaterRunning
        case .unknown: quietSince = nil; return .processVisibilityUnknown
        case .idle: break
        }
        guard let since = quietSince, now - since >= settlingInterval else { return .waiting }
        guard observation.signatureVerified else { return .invalidSignature }
        let current = observation.version
        guard baseline.signing.isComplete, current.signing.isComplete,
              let oldID = baseline.app.bundleIdentifier, !oldID.isEmpty,
              let newID = current.app.bundleIdentifier, !newID.isEmpty,
              let oldBuild = baseline.app.bundleVersion, !oldBuild.isEmpty,
              let newBuild = current.app.bundleVersion, !newBuild.isEmpty,
              !baseline.app.codeResourcesHash.isEmpty, !current.app.codeResourcesHash.isEmpty
        else { return .missingIdentity }
        guard oldID == newID else { return .bundleIdentityChanged }
        guard baseline.signing == current.signing else { return .signingIdentityChanged }
        guard oldBuild != newBuild || baseline.app.shortVersion != current.app.shortVersion else {
            return .versionUnchanged
        }
        // A rebuilt copy of a version already handled must not create a retry
        // loop just because its resource hash changed.
        if completed.contains(where: {
            $0.version.app.bundleIdentifier == newID
                && $0.version.app.bundleVersion == newBuild
                && $0.version.app.shortVersion == current.app.shortVersion
                && $0.version.signing == current.signing
        }) { return .alreadyHandled }
        guard observation.scanComplete, observation.eligibleFiles >= 0 else { return .scanIncomplete }
        if let reason = observation.skipReason { return .skipped(reason) }
        return observation.eligibleFiles == 0 ? .nothingToThin : .readyForPreflight
    }

    /// Record only a confirmed terminal outcome. Pending recovery and temporary
    /// refusals must stay retryable. Durable storage belongs to the coordinator.
    mutating func record(_ version: Version, outcome: Outcome) {
        completed.append(CompletedVersion(version: version, outcome: outcome))
        invalidate()
    }
}
