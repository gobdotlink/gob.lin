import AppKit
import CoreAudio
import Foundation

/// Small typed readers over the Core Audio object property API.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type,
                          qualifier: [UInt8]? = nil) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        let status: OSStatus
        if var qualifier {
            status = AudioObjectGetPropertyData(object, &address, UInt32(qualifier.count), &qualifier, &size, pointer)
        } else {
            status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }
}

/// One Core Audio client process, as the HAL reports it.
public struct AudioProcess: Sendable, Hashable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public static func all() -> [AudioProcess] {
        CoreAudioProperty.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { id in
            AudioProcess(
                objectID: id,
                pid: CoreAudioProperty.scalar(id, kAudioProcessPropertyPID, as: pid_t.self) ?? -1,
                bundleID: CoreAudioProperty.string(id, kAudioProcessPropertyBundleID),
                isRunningInput: (CoreAudioProperty.scalar(id, kAudioProcessPropertyIsRunningInput, as: UInt32.self) ?? 0) != 0,
                isRunningOutput: (CoreAudioProperty.scalar(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0)
        }
    }

    public static func objectID(forPID pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var address = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// A call app we know how to recognise. Browsers only count as a meeting when a meeting window is open.
public struct CallApp: Sendable, Hashable {
    public enum Kind: String, Sendable { case native, browser }
    public let name: String
    public let bundleIDs: [String]
    public let kind: Kind
    /// How much of the app's Accessibility tree a recording may read.
    public let scope: AccessibilityScope
    /// How long the app must hold the mic before it counts as a likely meeting, unless a call window shows sooner.
    public let minimumMicTime: TimeInterval
    /// Whether gob.lin knows this app's mute phrases. Without them mute stays unknown, so no mic
    /// line is ever left out because some other text happened to match.
    public let readsCallState: Bool

    public init(name: String, bundleIDs: [String], kind: Kind, scope: AccessibilityScope, minimumMicTime: TimeInterval = 2,
                readsCallState: Bool = false) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.kind = kind
        self.scope = scope
        self.minimumMicTime = minimumMicTime
        self.readsCallState = readsCallState
    }

    /// Zoom's windows are all the call, so the whole app is read. Browsers have only their meeting pages read.
    /// Slack is read only in its huddle or mini window, never its main window, and waits 20 s so a clip or the
    /// settings mic test isn't offered. Teams, FaceTime, Webex and Discord aren't read at all: their main windows
    /// hold chats or recent callers, and gob.lin knows none of their mute phrases yet, so reading them
    /// would expose that and gain nothing. Their window shapes are still logged at debug level.
    public static let known: [CallApp] = [
        CallApp(name: "Zoom", bundleIDs: ["us.zoom.xos"], kind: .native, scope: .wholeApp, readsCallState: true),
        CallApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"], kind: .native, scope: .nothing),
        CallApp(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"], kind: .native, scope: .callWindows(.slackHuddle),
                minimumMicTime: 20),
        CallApp(name: "FaceTime", bundleIDs: ["com.apple.FaceTime"], kind: .native, scope: .nothing),
        CallApp(name: "Webex", bundleIDs: ["Cisco-Systems.Spark", "com.webex.meetingmanager"], kind: .native, scope: .nothing),
        CallApp(name: "Discord", bundleIDs: ["com.hnc.Discord"], kind: .native, scope: .nothing),
        CallApp(name: "Google Chrome", bundleIDs: ["com.google.Chrome"], kind: .browser, scope: .meetingPages, readsCallState: true),
        CallApp(name: "Arc", bundleIDs: ["company.thebrowser.Browser"], kind: .browser, scope: .meetingPages, readsCallState: true),
        CallApp(name: "Dia", bundleIDs: ["company.thebrowser.dia"], kind: .browser, scope: .meetingPages, readsCallState: true),
        CallApp(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"], kind: .browser, scope: .meetingPages, readsCallState: true),
        CallApp(name: "Brave", bundleIDs: ["com.brave.Browser"], kind: .browser, scope: .meetingPages, readsCallState: true),
        CallApp(name: "Helium", bundleIDs: ["net.imput.helium"], kind: .browser, scope: .meetingPages, readsCallState: true),
        CallApp(name: "Firefox", bundleIDs: ["org.mozilla.firefox"], kind: .browser, scope: .meetingPages, readsCallState: true),
        CallApp(name: "Safari", bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"], kind: .browser, scope: .meetingPages,
                readsCallState: true),
    ]

    public static func matching(bundleID: String) -> CallApp? {
        known.first { app in app.bundleIDs.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") } }
    }
}

/// Audio processes grouped under the app a person would recognise (Chrome, not its audio helper).
public struct AudioClientApp: Sendable, Hashable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let pid: pid_t?
    public let processes: [AudioProcess]
    public let callApp: CallApp?
    public var isUsingMicrophone: Bool { processes.contains(where: \.isRunningInput) }
    public var isPlayingAudio: Bool { processes.contains(where: \.isRunningOutput) }

    public init(bundleID: String, name: String, pid: pid_t?, processes: [AudioProcess], callApp: CallApp?) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
        self.processes = processes
        self.callApp = callApp
    }

    /// An app from `NSWorkspace`, read on the main actor and handed to `current(running:)`.
    public struct Running: Sendable {
        public let bundleID: String
        public let name: String?
        public let pid: pid_t
    }

    /// The running apps with a bundle ID, from `NSWorkspace`, which belongs to the main actor.
    @MainActor public static func running() -> [Running] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { Running(bundleID: $0, name: app.localizedName, pid: app.processIdentifier) }
        }
    }

    /// Groups audio helpers under their host app. Processes without a bundle ID stay separate.
    @MainActor public static func current(excludingPID excluded: pid_t = ProcessInfo.processInfo.processIdentifier) -> [AudioClientApp] {
        current(running: running(), excludingPID: excluded)
    }

    /// The same from a list of running apps read earlier; it asks the HAL, so it can run on any thread.
    public static func current(running: [Running],
                               excludingPID excluded: pid_t = ProcessInfo.processInfo.processIdentifier) -> [AudioClientApp] {
        let processes = AudioProcess.all().filter { $0.pid != excluded && $0.pid > 0 }
        return group(processes, running: running, parentPID: parentPID)
    }

    static func group(_ processes: [AudioProcess], running: [Running], parentPID: (pid_t) -> pid_t?) -> [AudioClientApp] {
        let known = Set(running.map(\.bundleID) + processes.compactMap(\.bundleID))
        let apps = Dictionary(running.map { ($0.pid, $0.bundleID) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: [AudioProcess]] = [:]
        for process in processes {
            let bundleID = hostBundleID(for: process, known: known, apps: apps, parentPID: parentPID)
            groups[bundleID, default: []].append(process)
        }
        return groups.map { key, processes in
            let host = running.first { $0.bundleID == key }
            let callApp = CallApp.matching(bundleID: key)
            let name = callApp?.name ?? host?.name ?? processName(processes.first?.pid) ?? key
            return AudioClientApp(bundleID: key, name: name, pid: host?.pid ?? processes.first?.pid,
                                  processes: processes, callApp: callApp)
        }.sorted { ($0.callApp != nil ? 0 : 1, $0.name) < ($1.callApp != nil ? 0 : 1, $1.name) }
    }

    /// The shortest known bundle ID that prefixes this one (`com.google.Chrome` for
    /// `com.google.Chrome.helper.Renderer`); else the running app that launched it, for helpers named after another
    /// app (Dia's are `company.thebrowser.browser.helper`); else the ID with any `.helper…` tail removed.
    private static func hostBundleID(for process: AudioProcess, known: Set<String>, apps: [pid_t: String],
                                     parentPID: (pid_t) -> pid_t?) -> String {
        guard let bundleID = process.bundleID else { return "pid:\(process.pid)" }
        if bundleID == "com.apple.WebKit.GPU" { return "com.apple.Safari" }
        let hosts = known.filter { ($0 == bundleID || bundleID.hasPrefix($0 + ".")) && $0.split(separator: ".").count >= 3 }
        let prefixed = hosts.min(by: { $0.count < $1.count }).flatMap { $0 == bundleID ? nil : $0 }
        if let prefixed, apps.values.contains(prefixed) { return prefixed }
        if let parent = parentPID(process.pid), let host = apps[parent], host != bundleID {
            return host
        }
        if let prefixed { return prefixed }
        if let range = bundleID.range(of: ".helper") { return String(bundleID[..<range.lowerBound]) }
        return bundleID
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(exactly: info.pbsi_ppid)
    }

    private static func processName(_ pid: pid_t?) -> String? {
        guard let pid else { return nil }
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
