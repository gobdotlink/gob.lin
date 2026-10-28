import Foundation

/// How a microphone reaches the Mac, as CoreAudio reports it.
public enum MicrophoneKind: String, Codable, Sendable {
    case builtIn, usb, bluetooth, iPhone, virtual, other

    /// A short caption for lists; empty when the transport says nothing a person would recognise.
    public var caption: String {
        switch self {
        case .builtIn: "Built-in"
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .iPhone: "iPhone"
        case .virtual: "Virtual"
        case .other: ""
        }
    }
}

/// A connected microphone, as far as choosing one is concerned.
public struct MicrophoneFacts: Equatable, Sendable {
    public var uid: String
    public var name: String
    /// Product name and USB IDs: the same on every port, unlike some UIDs.
    public var model: String?
    public var kind: MicrophoneKind
    /// A built-in microphone the closed lid has cut off: it lists, but records only silence.
    public var silencedByLid: Bool

    public init(uid: String, name: String, model: String? = nil, kind: MicrophoneKind = .other, silencedByLid: Bool = false) {
        self.uid = uid; self.name = name; self.model = model; self.kind = kind; self.silencedByLid = silencedByLid
    }
}

/// The microphone a recording would open, and the entry that chose it.
public struct MicrophoneChoice: Equatable, Sendable {
    public let uid: String
    public let position: Int
    public let viaSystemDefault: Bool
}

/// Microphones in the order a person wants them. Entries above the System Default line are tried in
/// order; the line itself means "whatever macOS has selected"; entries below it are used only when
/// picked. Absent microphones keep their place, so a choice is never lost while a device is away.
public struct MicrophoneRanking: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        /// Empty for the System Default line.
        public var uid: String
        public var name: String
        public var model: String?
        public var kind: MicrophoneKind?
        public var id: String { uid }
        public var isSystemDefault: Bool { uid.isEmpty }

        public static let systemDefault = Entry(uid: "", name: "System Default")

        public init(uid: String, name: String, model: String? = nil, kind: MicrophoneKind? = nil) {
            self.uid = uid; self.name = name; self.model = model; self.kind = kind
        }

        init(_ device: MicrophoneFacts) { self.init(uid: device.uid, name: device.name, model: device.model, kind: device.kind) }
    }

    public static let preferenceKey = "audio.microphoneRanking"
    /// The single microphone earlier versions saved; empty meant the system default.
    public static let legacyPreferenceKey = "audio.inputDeviceUID"

    public private(set) var entries: [Entry]
    /// The index of the System Default line.
    public var line: Int { entries.firstIndex { $0.isSystemDefault } ?? entries.count }

    public init(entries: [Entry] = [.systemDefault]) {
        self.entries = entries
        if !entries.contains(where: \.isSystemDefault) { self.entries.append(.systemDefault) }
    }

    /// The saved ranking, or nil before the first one is saved.
    public static func load(defaults: UserDefaults) -> MicrophoneRanking? {
        guard let data = defaults.data(forKey: preferenceKey),
              let saved = try? JSONDecoder().decode(MicrophoneRanking.self, from: data) else { return nil }
        return MicrophoneRanking(entries: saved.entries)
    }

    /// What a launch starts from before any device is listed: the earlier single choice, then the line.
    public static func migrating(defaults: UserDefaults) -> MicrophoneRanking {
        let uid = defaults.string(forKey: legacyPreferenceKey) ?? ""
        guard !uid.isEmpty else { return MicrophoneRanking() }
        return MicrophoneRanking(entries: [Entry(uid: uid, name: legacyName(uid)), .systemDefault])
    }

    public func save(defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.preferenceKey) }
    }

    /// Whether the first listing should put the built-in microphone above the line. Not for someone who
    /// had explicitly gone back to following macOS: that choice carries over as it was.
    public static func laptopFirst(defaults: UserDefaults) -> Bool { defaults.string(forKey: legacyPreferenceKey) != "" }

    /// The first time devices are listed: the built-in microphone goes just above the line, so a headset
    /// macOS switches to on connect doesn't take dictation with it. Everything else waits below the line.
    public mutating func seed(_ connected: [MicrophoneFacts], laptopFirst: Bool = true) {
        if laptopFirst, let builtIn = connected.first(where: { $0.kind == .builtIn }), !entries.contains(where: { $0.uid == builtIn.uid }) {
            entries.insert(Entry(builtIn), at: line)
        }
        for device in connected where !entries.contains(where: { $0.uid == device.uid }) { entries.append(Entry(device)) }
    }

    /// Brings entries up to date with what is connected and returns microphones seen for the first time.
    /// A microphone moved to another USB port gets a new UID; it keeps its place when exactly one absent
    /// entry and exactly one new device share its model and name. Virtual devices go below the line unasked.
    public mutating func reconcile(_ connected: [MicrophoneFacts]) -> [MicrophoneFacts] {
        let known = Set(entries.map(\.uid)), present = Set(connected.map(\.uid))
        let unknown = connected.filter { !known.contains($0.uid) }
        var fresh: [MicrophoneFacts] = []
        for device in connected {
            if let index = entries.firstIndex(where: { $0.uid == device.uid }) {
                let entry = Entry(device)
                if entries[index] != entry { entries[index] = entry }
                continue
            }
            let sameProduct = { (model: String?, name: String) in model != nil && model == device.model && name == device.name }
            let absent = entries.indices.filter { !entries[$0].isSystemDefault && !present.contains(entries[$0].uid) && sameProduct(entries[$0].model, entries[$0].name) }
            if absent.count == 1, unknown.filter({ sameProduct($0.model, $0.name) }).count == 1 {
                entries[absent[0]] = Entry(device)
            } else if device.kind == .virtual {
                entries.append(Entry(device))
            } else {
                fresh.append(device)
            }
        }
        return fresh
    }

    /// The microphone to open now. Above the line, the first one connected and able to hear wins; then
    /// the system default. When neither can hear, macOS's own choice still opens, so the silence warning
    /// can say why; nothing below the line is used unless picked.
    public func resolve(connected: [MicrophoneFacts], systemDefault: String?) -> MicrophoneChoice? {
        let defaultDevice = connected.first { $0.uid == systemDefault }
        for (position, entry) in entries.enumerated() {
            if entry.isSystemDefault {
                guard let defaultDevice else { break }
                return MicrophoneChoice(uid: defaultDevice.uid, position: position, viaSystemDefault: true)
            }
            if let device = connected.first(where: { $0.uid == entry.uid }), !device.silencedByLid {
                return MicrophoneChoice(uid: device.uid, position: position, viaSystemDefault: false)
            }
        }
        return nil
    }

    /// Picking puts a microphone just above the highest-ranked one that can hear now, so favourites
    /// that are away keep their place and win again when they return. The empty UID picks the line.
    public mutating func pick(_ uid: String, connected: [MicrophoneFacts]) {
        guard let entry = entries.first(where: { $0.uid == uid }) ?? connected.first(where: { $0.uid == uid }).map(Entry.init) else { return }
        entries.removeAll { $0.uid == uid }
        let usable = entries.firstIndex { entry in
            entry.isSystemDefault || connected.contains { $0.uid == entry.uid && !$0.silencedByLid }
        }
        entries.insert(entry, at: usable ?? 0)
    }

    /// A new microphone waits below the line, used only when picked, so it's asked about once.
    public mutating func remember(_ device: MicrophoneFacts) {
        guard !entries.contains(where: { $0.uid == device.uid }) else { return }
        entries.append(Entry(device))
    }

    /// The same contract as SwiftUI's `move(fromOffsets:toOffset:)`.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        var rest = entries.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: min(rest.count, destination - source.count { $0 < destination }))
        entries = rest
    }

    public mutating func forget(_ uid: String) {
        entries.removeAll { $0.uid == uid && !$0.isSystemDefault }
    }

    /// Earlier versions kept only a UID. USB UIDs carry the product name third, which beats a blank row
    /// until the device connects and reports its own name.
    private static func legacyName(_ uid: String) -> String {
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        if parts.first == "AppleUSBAudioEngine", parts.count > 2, !parts[2].isEmpty { return String(parts[2]) }
        return "Saved Microphone"
    }
}
