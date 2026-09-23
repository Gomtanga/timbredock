import AppKit
import Darwin
import Foundation
import LowEndSupport
import OSLog

struct SourceFormatSnapshot: Sendable {
    let activePlayers: [SourcePlayer]
    let formats: [SourceAudioFormat]

    var format: SourceAudioFormat? {
        SourceFormatSelectionPolicy.select(formats: formats)
    }

    var indicatorText: String {
        if let format {
            return format.indicatorText
        }
        if Set(formats.map(\.player)).count > 1 {
            return L10n.format("runtime.source.multiple", formats.map { $0.player.displayName }.joined(separator: " + "))
        }
        guard !activePlayers.isEmpty else {
            return L10n.string("runtime.source.waiting")
        }
        return "Source \(activePlayers.map(\.displayName).joined(separator: " + ")): unknown"
    }
}

/// Process identity is separate from AppKit so lifecycle checks can exercise
/// the real poll/cache/file-reader path against a temporary log only.
struct SourcePlayerProcess: Sendable {
    let processIdentifier: Int32
    let launchDate: Date?
}

struct SourceFormatTrackerEnvironment: Sendable {
    var runningApplication: @Sendable (SourcePlayer) -> SourcePlayerProcess? = { player in
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first else { return nil }
        return SourcePlayerProcess(processIdentifier: app.processIdentifier, launchDate: app.launchDate)
    }
    var now: @Sendable () -> Date = { Date() }
    var tidalPlayerLogURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TIDAL/player.log")
    // Offline checks disable filesystem watchers, Unified Log and AppleScript;
    // ordinary file reads still use FileHandle/fstat on their injected temp URL.
    var allowsSystemObservations = true
}

final class SourceFormatTracker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.codexaudiolab.lowendcircuit.source-format",
        qos: .utility
    )
    private let onUpdate: @Sendable (SourceFormatSnapshot) -> Void
    private let onObservation: @Sendable (SourceFormatSnapshot) -> Void
    private var timer: DispatchSourceTimer?
    private var lastSnapshotText = ""
    private var cachedFormats: [SourcePlayer: SourceAudioFormat] = [:]
    private let cacheLifetime: TimeInterval = 15
    private lazy var logStore: OSLogStore? = try? OSLogStore.local()
    private let environment: SourceFormatTrackerEnvironment
    private var lastAppleMusicPersistentID: String?
    private var lastAppleMusicState: AppleMusicPlaybackState = .notRunning
    private var acceleratedPollsRemaining: Int = 0
    private var tidalLogSource: DispatchSourceFileSystemObject?
    private var tidalLogRefreshWorkItem: DispatchWorkItem?
    private var tidalLogRearmWorkItem: DispatchWorkItem?
    private var tidalLogCursor = TIDALLogReadCursor()
    private var tidalPlaybackEvidence = TIDALPlaybackEvidenceTracker()
    private var tidalLogRemainder = Data()

    init(onUpdate: @escaping @Sendable (SourceFormatSnapshot) -> Void,
         onObservation: @escaping @Sendable (SourceFormatSnapshot) -> Void = { _ in },
         environment: SourceFormatTrackerEnvironment = SourceFormatTrackerEnvironment()) {
        self.onUpdate = onUpdate
        self.onObservation = onObservation
        self.environment = environment
    }

    func start() {
        queue.async { [weak self] in
            guard let self, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            self.timer = timer
            timer.resume()
            self.installTIDALLogWatcherIfNeeded()
        }
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            cachedFormats.removeAll(keepingCapacity: true)
            lastSnapshotText = ""
            resetTIDALReadState()
            lastAppleMusicPersistentID = nil
            lastAppleMusicState = .notRunning
            acceleratedPollsRemaining = 0
            tidalLogRefreshWorkItem?.cancel()
            tidalLogRefreshWorkItem = nil
            tidalLogRearmWorkItem?.cancel()
            tidalLogRearmWorkItem = nil
            cancelTIDALLogWatcher()
        }
    }

    func pollOnce() -> SourceFormatSnapshot { queue.sync { poll() } }

    @discardableResult
    private func poll(updateAppleMusic: Bool = true) -> SourceFormatSnapshot {
        let activePlayers = SourcePlayer.allCases.filter { environment.runningApplication($0) != nil }
        let now = environment.now()

        if updateAppleMusic {
            installTIDALLogWatcherIfNeeded()
        }

        if updateAppleMusic && activePlayers.contains(.appleMusic) {
            let logEntries = readUnifiedLogEntries(player: .appleMusic)
            let scriptContext = readAppleMusicScriptContext(observedAt: now)
            let resolvedFormat = SourceFormatParser.resolveAppleMusicFormat(
                logEntries: logEntries,
                scriptContext: scriptContext
            )

            if let resolvedFormat {
                let rate = resolvedFormat.sampleRate.map { "\($0 / 1000)kHz" } ?? "nil"
                let depth = resolvedFormat.bitDepth.map { "\($0)-bit" } ?? "no-bit-depth"
                let conf = resolvedFormat.confidence == .detected ? "Detected" : "Inferred"
                print("[AM] \(rate) \(depth) (\(conf))")
            }

            if let resolvedFormat {
                cachedFormats[.appleMusic] = resolvedFormat
            } else {
                cachedFormats.removeValue(forKey: .appleMusic)
            }

            let shouldAccelerate: Bool
            if scriptContext.state != lastAppleMusicState
                && scriptContext.state == .playing {
                shouldAccelerate = true
            } else if scriptContext.state == .playing
                        && scriptContext.persistentID != lastAppleMusicPersistentID {
                shouldAccelerate = true
            } else {
                shouldAccelerate = false
            }

            if shouldAccelerate && acceleratedPollsRemaining == 0 {
                acceleratedPollsRemaining = 4
                timer?.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
            }

            if acceleratedPollsRemaining > 0 {
                acceleratedPollsRemaining -= 1
                if acceleratedPollsRemaining == 0 {
                    timer?.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
                }
            }

            lastAppleMusicState = scriptContext.state
            lastAppleMusicPersistentID = scriptContext.persistentID
        } else if updateAppleMusic {
            cachedFormats.removeValue(forKey: .appleMusic)
            lastAppleMusicState = .notRunning
            lastAppleMusicPersistentID = nil
        }

        if activePlayers.contains(.tidal) {
            switch readTIDALPlayerLog(observedAt: now) {
            case let .format(tidalFormat):
                cachedFormats[.tidal] = tidalFormat
            case .inactive, .stale:
                cachedFormats.removeValue(forKey: .tidal)
            case .unavailable:
                if let tidalFormat = readUnifiedLog(player: .tidal),
                   now.timeIntervalSince(tidalFormat.observedAt) <= cacheLifetime,
                   let launchedAt = environment.runningApplication(.tidal)?.launchDate,
                   tidalFormat.observedAt >= launchedAt {
                    cachedFormats[.tidal] = tidalFormat
                } else {
                    cachedFormats.removeValue(forKey: .tidal)
                }
            }
        } else {
            cachedFormats.removeValue(forKey: .tidal)
            resetTIDALReadState()
        }

        cachedFormats = cachedFormats.filter {
            activePlayers.contains($0.key)
                && now.timeIntervalSince($0.value.observedAt) <= cacheLifetime
        }

        let formats = SourcePlayer.allCases.compactMap { cachedFormats[$0] }
        let snapshot = SourceFormatSnapshot(activePlayers: activePlayers, formats: formats)
        onObservation(snapshot)
        guard snapshot.indicatorText != lastSnapshotText else { return snapshot }
        lastSnapshotText = snapshot.indicatorText
        onUpdate(snapshot)
        return snapshot
    }

    private func installTIDALLogWatcherIfNeeded() {
        guard environment.allowsSystemObservations, tidalLogSource == nil else { return }

        let descriptor = open(environment.tidalPlayerLogURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            if !events.intersection([.rename, .delete, .revoke]).isEmpty {
                self.cancelTIDALLogWatcher()
                self.scheduleTIDALLogWatcherRearm()
                return
            }
            self.scheduleTIDALLogRefresh()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        tidalLogSource = source
        source.resume()
    }

    private func cancelTIDALLogWatcher() {
        tidalLogSource?.setEventHandler {}
        tidalLogSource?.cancel()
        tidalLogSource = nil
    }

    private func scheduleTIDALLogRefresh() {
        tidalLogRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.poll(updateAppleMusic: false)
        }
        tidalLogRefreshWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(80), execute: workItem)
    }

    private func scheduleTIDALLogWatcherRearm() {
        tidalLogRearmWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.installTIDALLogWatcherIfNeeded()
            if self.tidalLogSource != nil {
                self.scheduleTIDALLogRefresh()
            }
        }
        tidalLogRearmWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
    }

    private func readUnifiedLogEntries(player: SourcePlayer) -> [SourceFormatLogEntry] {
        guard environment.allowsSystemObservations else { return [] }
        do {
            guard let store = logStore else {
                return []
            }
            let position = store.position(timeIntervalSinceEnd: -30)
            let predicate: NSPredicate
            switch player {
            case .appleMusic:
                predicate = NSPredicate(
                    format: "(process == %@) AND ((subsystem == %@) OR (subsystem == %@) OR (subsystem == %@))",
                    "Music",
                    "com.apple.coreaudio",
                    "com.apple.Music",
                    "com.apple.coremedia"
                )
            case .tidal:
                predicate = NSPredicate(
                    format: "(process CONTAINS[c] %@) OR (senderImagePath CONTAINS[c] %@)",
                    "TIDAL",
                    "TIDAL"
                )
            }

            let entries = try store.getEntries(at: position, matching: predicate)
                .compactMap { entry -> SourceFormatLogEntry? in
                    guard let log = entry as? OSLogEntryLog else { return nil }
                    return SourceFormatLogEntry(date: log.date, message: log.composedMessage)
                }

            if player == .appleMusic && !entries.isEmpty {
                for entry in entries {
                    let msg = entry.message.lowercased()
                    if msg.contains("hz") || msg.contains("rate") || msg.contains("format") || msg.contains("decoder") || msg.contains("bit") {
                        print("[AM] log candidate: \(entry.message)")
                    }
                }
            }

            return entries
        } catch {
            return []
        }
    }

    private func readUnifiedLog(player: SourcePlayer) -> SourceAudioFormat? {
        let entries = readUnifiedLogEntries(player: player)
        switch player {
        case .appleMusic:
            return SourceFormatParser.parseAppleMusic(entries: entries)
        case .tidal:
            return SourceFormatParser.parseTIDAL(entries: entries)
        }
    }

    private func resetTIDALReadState() {
        tidalLogCursor.reset()
        tidalPlaybackEvidence.reset()
        tidalLogRemainder.removeAll(keepingCapacity: true)
    }

    private func readTIDALPlayerLog(observedAt: Date) -> TIDALPlayerLogResult {
        guard let application = environment.runningApplication(.tidal),
              let handle = try? FileHandle(forReadingFrom: environment.tidalPlayerLogURL) else {
            resetTIDALReadState()
            return .unavailable
        }
        defer { try? handle.close() }

        do {
            // fstat identifies the opened file, avoiding a path/rotation race.
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { return .stale }
            let launchIdentity = application.launchDate?.timeIntervalSince1970 ?? 0
            let sessionID = "\(application.processIdentifier):\(launchIdentity):\(info.st_dev):\(info.st_ino)"
            let fileSize = try handle.seekToEnd()
            switch tidalLogCursor.plan(sessionID: sessionID, fileSize: fileSize) {
            case .newSession:
                tidalPlaybackEvidence.reset()
                tidalLogRemainder.removeAll(keepingCapacity: true)
                return .stale
            case .unchanged:
                return currentTIDALLogSnapshot(observedAt: observedAt)
            case .read(let offset):
                // Losing a large interval also loses reliable lifecycle order.
                // Reestablish fresh evidence instead of guessing from a tail.
                guard fileSize - offset <= 256 * 1_024 else {
                    tidalLogCursor.didRead(through: fileSize)
                    tidalPlaybackEvidence.reset()
                    tidalLogRemainder.removeAll(keepingCapacity: true)
                    return .stale
                }
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: Int(fileSize - offset)) ?? Data()
                tidalLogCursor.didRead(through: offset + UInt64(data.count))
                tidalLogRemainder.append(data)
                if let lastNewline = tidalLogRemainder.lastIndex(of: 0x0A) {
                    let complete = tidalLogRemainder[...lastNewline]
                    let text = String(decoding: complete, as: UTF8.self)
                    let entries = text.split(separator: "\n").map {
                        SourceFormatLogEntry(date: observedAt, message: String($0))
                    }
                    tidalPlaybackEvidence.ingest(entries)
                    tidalLogRemainder.removeSubrange(...lastNewline)
                }
                if tidalLogRemainder.count > 256 * 1_024 {
                    tidalLogRemainder.removeAll(keepingCapacity: true)
                    tidalPlaybackEvidence.reset()
                }
                return currentTIDALLogSnapshot(observedAt: observedAt)
            }
        } catch {
            // A present but unreadable log is not permission to revive an
            // unrelated old Unified Log record for the same player.
            return .stale
        }
    }

    private func currentTIDALLogSnapshot(observedAt: Date) -> TIDALPlayerLogResult {
        switch tidalPlaybackEvidence.snapshot(observedAt: observedAt) {
        case .unavailable: return .stale
        case let result: return result
        }
    }

    private func readAppleMusicScriptContext(observedAt: Date) -> AppleMusicPlaybackContext {
        guard environment.allowsSystemObservations else {
            return AppleMusicPlaybackContext(state: .notRunning, persistentID: nil, sampleRate: nil, observedAt: observedAt)
        }
        let source = """
        tell application "Music"
            set currentState to player state as string
            if currentState is not "playing" then
                return currentState & "|missing value|0"
            end if
            try
                set trackID to persistent ID of current track
                set trackRate to sample rate of current track
                return currentState & "|" & trackID & "|" & (trackRate as string)
            on error
                return currentState & "|unknown|0"
            end try
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return AppleMusicPlaybackContext(
                state: .notRunning, persistentID: nil, sampleRate: nil, observedAt: observedAt
            )
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error).stringValue
        guard error == nil, let result else {
            if let error {
                let number = error["AppleScriptErrorNumber"] as? Int ?? 0
                let message = error["AppleScriptErrorMessage"] as? String ?? "unknown"
                print("[AM] AppleScript error \(number): \(message)")
            }
            return AppleMusicPlaybackContext(
                state: .notRunning, persistentID: nil, sampleRate: nil, observedAt: observedAt
            )
        }

        let parts = result.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else {
            return AppleMusicPlaybackContext(
                state: .notRunning, persistentID: nil, sampleRate: nil, observedAt: observedAt
            )
        }

        let stateString = String(parts[0]).lowercased()
        let persistentID = String(parts[1])
        let sampleRateValue = Double(parts[2])

        let state: AppleMusicPlaybackState
        switch stateString {
        case "playing":
            state = .playing
        case "paused":
            state = .paused
        case "stopped":
            state = .stopped
        default:
            state = .notRunning
        }

        let sampleRate: Double? = sampleRateValue.flatMap { value in
            value.isFinite && value >= 8_000 ? value : nil
        }

        let resolvedPersistentID: String? = (persistentID == "missing value" || persistentID == "unknown")
            ? nil : persistentID

        return AppleMusicPlaybackContext(
            state: state,
            persistentID: resolvedPersistentID,
            sampleRate: sampleRate,
            observedAt: observedAt
        )
    }

}
