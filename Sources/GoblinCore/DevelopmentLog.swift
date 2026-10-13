import CryptoKit
import Foundation
import os
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct DevelopmentBuildIdentity: Encodable, Sendable {
    public let app = GoblinMetadata.name
    public let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? GoblinMetadata.version
    public let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "package"
    public let sourceRevision = GoblinBuildStamp.revision
    public let sourceModified = GoblinBuildStamp.dirty
    public let builtAt = GoblinBuildStamp.builtAt
    public let buildID = GoblinBuildStamp.id
    #if DEBUG
    public let configuration = "debug"
    #else
    public let configuration = "release"
    #endif
    public init() {}
}

public enum DevelopmentSeverity: String { case info, warning, error }
public enum DevelopmentEventName: String {
    case appStarted, shutdownRequested, appStopped, failure, recovered, timings
    case permissionSnapshot, permissionRetry, secureInputChanged, hotkeyStarting, hotkeyReady, hotkeyStopped, hotkeyBegin, hotkeyFinish, hotkeyCancel
    case processingStarted, processingFinished, rewriteStarted, rewriteFinished, insertionStarted, insertionFinished
    case previewRequested, devicesEnumerated, deviceEnumerationFailed, deviceSelection, deviceResolved, deviceFallback, inputFormat
    case tapInstalling, tapInstalled, engineStarting, engineStarted, firstBuffer, configurationChanged
    case previewFailed, previewStopping, previewStopped
}
public enum DevelopmentReason: String {
    case user, restart, selectionChanged, viewClosed, permissionLost, configurationChanged, startFailed, shutdown
    case manualRetry, settingsReturn
    case permissionMissing, invalidFormat, deviceUnavailable, systemDefault, savedDevice
}

/// Device UIDs never leave this type. Tokens correlate devices only within one launch.
public struct DevelopmentDeviceID {
    fileprivate let token: String
}

public struct DevelopmentDetails {
    public var reason: DevelopmentReason?
    public var selectedDevice: DevelopmentDeviceID?
    public var resolvedDevice: DevelopmentDeviceID?
    public var deviceCount: Int?
    public var channelCount: UInt32?
    public var sampleRate: Double?
    public var osStatus: Int32?
    public var engineRunning: Bool?
    public var microphone: DiagnosticPermissionStatus?
    public var accessibility: DiagnosticPermissionStatus?
    public var inputMonitoring: DiagnosticPermissionStatus?
    public var secureInput: Bool?
    public var failure: DiagnosticFailure?
    public var succeeded: Bool?
    public var timings: DictationTimings?
    public var underlyingError: Error?
    public init(reason: DevelopmentReason? = nil) { self.reason = reason }

    fileprivate var fields: [String: Any] {
        var fields: [String: Any] = [:]
        fields["reason"] = reason?.rawValue
        fields["selectedDevice"] = selectedDevice?.token
        fields["resolvedDevice"] = resolvedDevice?.token
        fields["deviceCount"] = deviceCount
        fields["channelCount"] = channelCount
        if let sampleRate, sampleRate.isFinite { fields["sampleRate"] = sampleRate }
        fields["osStatus"] = osStatus
        fields["engineRunning"] = engineRunning
        fields["microphone"] = microphone?.rawValue
        fields["accessibility"] = accessibility?.rawValue
        fields["inputMonitoring"] = inputMonitoring?.rawValue
        fields["secureInput"] = secureInput
        fields["failure"] = failure?.message
        fields["succeeded"] = succeeded
        fields["timings"] = timings.map(DiagnosticsReport.timingLines)
        if let underlyingError {
            var error = underlyingError as NSError
            var codes: [[String: Any]] = []
            for _ in 0..<3 {
                let allowed = [NSOSStatusErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain, "com.apple.coreaudio.avfaudio", "AVFoundationErrorDomain"]
                codes.append(["domain": allowed.contains(error.domain) ? error.domain : "other", "code": error.code])
                guard let next = error.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
                error = next
            }
            fields["errors"] = codes
        }
        return fields
    }
}

/// Low-volume lifecycle events only; call on the main actor, never on an audio callback.
@MainActor
public final class DevelopmentLog {
    public static let maximumFileBytes = 1_048_576
    public static let fileCount = 3
    public let directory: URL
    public let launchID = UUID()
    public let build = DevelopmentBuildIdentity()
    public private(set) var lastError: String?
    private let maximumFileBytes: Int
    private let deviceKey = SymmetricKey(size: .bits256)
    private var sequence = 0
    private let formatter = ISO8601DateFormatter()
    private let fileManager = FileManager.default

    public init(directory: URL? = nil, maximumFileBytes: Int = DevelopmentLog.maximumFileBytes) {
        self.directory = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/gob.lin", isDirectory: true)
        self.maximumFileBytes = max(4096, maximumFileBytes)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func deviceID(_ uid: String) -> DevelopmentDeviceID {
        let digest = HMAC<SHA256>.authenticationCode(for: Data(uid.utf8), using: deviceKey)
        return DevelopmentDeviceID(token: digest.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    @discardableResult
    public func record(_ event: DevelopmentEventName, area: DiagnosticArea, severity: DevelopmentSeverity = .info,
                       operation: UUID? = nil, details: DevelopmentDetails = DevelopmentDetails()) -> Bool {
        sequence += 1
        do {
            let identity = try JSONSerialization.jsonObject(with: JSONEncoder().encode(build))
            var object: [String: Any] = ["timestamp": formatter.string(from: Date()), "sequence": sequence,
                "severity": severity.rawValue, "subsystem": area.rawValue, "event": event.rawValue,
                "launchID": launchID.uuidString, "pid": ProcessInfo.processInfo.processIdentifier,
                "build": identity, "details": details.fields]
            object["operationID"] = operation?.uuidString
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(10)
            guard data.count <= maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let lock = open(directory.appendingPathComponent("events.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(lock) }
            // Serialize file creation, repair, rotation and synced appends across app processes.
            guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let current = fileURL(0)
            if !fileManager.fileExists(atPath: current.path) {
                guard fileManager.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            var handle = try FileHandle(forUpdating: current)
            defer { try? handle.close() }
            var size = try handle.seekToEnd()
            // A killed process may leave an incomplete final JSON line; retain all complete events.
            if size > 0, size <= maximumFileBytes {
                try handle.seek(toOffset: size - 1)
                if try handle.read(upToCount: 1) != Data([10]) {
                    try handle.seek(toOffset: 0)
                    let previous = try handle.readToEnd() ?? Data()
                    size = UInt64(previous.lastIndex(of: 10).map { $0 + 1 } ?? 0)
                    try handle.truncate(atOffset: size)
                }
            }
            if size + UInt64(data.count) > maximumFileBytes {
                try handle.close()
                try rotate()
                guard fileManager.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                handle = try FileHandle(forUpdating: current)
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            // No buffered writer: completed breadcrumbs survive abrupt process termination.
            try handle.synchronize()
            lastError = nil
            return true
        } catch {
            lastError = "Development logs could not be written. Check access and free disk space in ~/Library/Logs/gob.lin."
            Logger(subsystem: GoblinMetadata.bundleIdentifier + ".diagnostics", category: "development-log").error("Development log write failed.")
            return false
        }
    }

    public func recentText() throws -> String {
        var text = ""
        for index in (0..<Self.fileCount).reversed() {
            let url = fileURL(index)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumFileBytes) ?? Data()
            // Never export a torn trailing record.
            if let end = data.lastIndex(of: 10) { text += String(decoding: data[...end], as: UTF8.self) }
        }
        return text
    }

    private func fileURL(_ index: Int) -> URL { directory.appendingPathComponent(index == 0 ? "events.jsonl" : "events.\(index).jsonl") }
    private func rotate() throws {
        for index in stride(from: Self.fileCount - 1, through: 1, by: -1) {
            let source = fileURL(index - 1)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = fileURL(index)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: source, to: destination)
        }
    }
}
