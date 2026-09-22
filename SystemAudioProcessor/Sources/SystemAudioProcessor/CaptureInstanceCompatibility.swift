import AppKit
import Foundation

/// A compatibility check for bundled apps that predate the capture lease.
/// Cooperating versions arbitrate ownership with CaptureSessionLease. This
/// preflight only discovers apps registered with this bundle identifier; an
/// older, unbundled CLI process is outside its discovery scope.
enum CaptureInstanceCompatibility {
    static let bundleIdentifier = "com.codexaudiolab.lowendcircuit.systemaudio"
    static let leaseVersionKey = "LCCaptureLeaseVersion"

    /// Plain values keep classification independent of AppKit and running apps.
    struct Snapshot: Equatable {
        let processIdentifier: pid_t
        let isTerminated: Bool
        let localizedName: String?
        let bundlePath: String?
        let leaseVersion: Int?

        init(processIdentifier: pid_t, isTerminated: Bool,
             localizedName: String? = nil, bundlePath: String? = nil,
             leaseVersion: Int?) {
            self.processIdentifier = processIdentifier
            self.isTerminated = isTerminated
            self.localizedName = localizedName
            self.bundlePath = bundlePath
            self.leaseVersion = leaseVersion
        }
    }

    struct Conflict: Error, LocalizedError, CustomStringConvertible {
        let instances: [Snapshot]

        var description: String {
            let apps = instances.map { instance in
                let name = instance.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = (name?.isEmpty == false ? name : nil) ?? "LowEnd Circuit"
                if let path = instance.bundlePath, !path.isEmpty {
                    return "\(displayName) (PID \(instance.processIdentifier), \(path))"
                }
                return "\(displayName) (PID \(instance.processIdentifier))"
            }.joined(separator: "\n")
            return L10n.format("runtime.capture.incompatible", apps)
        }

        var errorDescription: String? { description }
    }

    /// Missing, Boolean, textual and floating-point values are not a lease
    /// version declaration. Only an integer property-list value is accepted.
    static func leaseVersion(from value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        switch String(cString: number.objCType) {
        case "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q":
            return Int(number.stringValue)
        default:
            return nil
        }
    }

    /// A newer on-disk bundle cannot declare capabilities for an older running
    /// process. Missing timestamp evidence must not turn that process into a
    /// cooperating lease owner. Equality is allowed for filesystem precision.
    static func metadataTimestampsPermitLeaseVersion(
        launchDate: Date?, infoModificationDate: Date?, executableModificationDate: Date?
    ) -> Bool {
        guard let launchDate, let infoModificationDate, let executableModificationDate,
              launchDate.timeIntervalSinceReferenceDate.isFinite,
              infoModificationDate.timeIntervalSinceReferenceDate.isFinite,
              executableModificationDate.timeIntervalSinceReferenceDate.isFinite else { return false }
        return infoModificationDate <= launchDate && executableModificationDate <= launchDate
    }

    private static func modificationDate(of url: URL?) -> Date? {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// A stopped or invalid process is not a competing app. Unknown metadata
    /// remains incompatible while a different process is still running.
    static func incompatibleInstances(in snapshots: [Snapshot],
                                      currentPID: pid_t) -> [Snapshot] {
        snapshots.filter { snapshot in
            snapshot.processIdentifier > 0
                && snapshot.processIdentifier != currentPID
                && !snapshot.isTerminated
                && (snapshot.leaseVersion ?? 0) < 1
        }.sorted { $0.processIdentifier < $1.processIdentifier }
    }

    /// Call on the manager path before creating a tap. This reads app metadata;
    /// it never terminates an app, changes a device or starts capture.
    static func validate() throws {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var snapshots: [Snapshot] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            let pid = app.processIdentifier
            guard pid > 0, pid != currentPID, !app.isTerminated else { continue }
            let bundleURL = app.bundleURL
            let version: Int?
            if let infoURL = bundleURL?.appendingPathComponent("Contents/Info.plist"),
               let data = try? Data(contentsOf: infoURL),
               let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String: Any],
               metadataTimestampsPermitLeaseVersion(launchDate: app.launchDate,
                   infoModificationDate: modificationDate(of: infoURL),
                   executableModificationDate: modificationDate(of: app.executableURL)) {
                version = leaseVersion(from: info[leaseVersionKey])
            } else {
                version = nil
            }
            // A peer can exit while its bundle metadata is being read.
            guard !app.isTerminated else { continue }
            snapshots.append(Snapshot(processIdentifier: pid, isTerminated: false,
                localizedName: app.localizedName, bundlePath: bundleURL?.path,
                leaseVersion: version))
        }
        let incompatible = incompatibleInstances(in: snapshots, currentPID: currentPID)
        if !incompatible.isEmpty { throw Conflict(instances: incompatible) }
    }
}
