import Darwin
import Foundation

// The fixed-size header is checkpointed while recording, so recovery never requires an in-memory recording.
final class CaptureFile {
    let sessionID: UUID
    let partialURL: URL
    private let finalURL: URL
    private var handle: FileHandle?
    private(set) var sampleCount: Int64 = 0
    private var checkpointTime = ContinuousClock.now

    init(sessionID: UUID, directory: URL) throws {
        guard directory.isFileURL else { throw AudioCaptureFailure(.storageFailed) }
        self.sessionID = sessionID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        partialURL = directory.appendingPathComponent(sessionID.uuidString + ".partial.wav")
        finalURL = directory.appendingPathComponent(sessionID.uuidString + ".wav")
        let fd = open(partialURL.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AudioCaptureFailure(.storageFailed) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle!.write(contentsOf: Self.header(samples: 0)); try handle!.synchronize(); try Self.syncDirectory(directory) }
        catch { try? handle?.close(); handle = nil; try? FileManager.default.removeItem(at: partialURL); throw error }
    }

    func append(_ samples: [Float]) throws {
        guard let handle, sampleCount + Int64(samples.count) <= Int64((UInt32.max - 36) / 4) else {
            throw AudioCaptureFailure(.storageFailed, recoveryURL: partialURL)
        }
        try samples.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        sampleCount += Int64(samples.count)
        if checkpointTime.duration(to: .now) >= .seconds(1) { try checkpoint(); checkpointTime = .now }
    }

    func checkpoint() throws {
        guard let handle else { return }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(samples: sampleCount))
        try handle.truncate(atOffset: UInt64(44 + sampleCount * 4))
        try handle.seekToEnd()
        try handle.synchronize()
    }

    func finish(preRoll: Int) throws -> CapturedAudio {
        try checkpoint()
        try handle?.close(); handle = nil
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        do { try Self.syncDirectory(finalURL.deletingLastPathComponent()) }
        catch { throw AudioCaptureFailure(.storageFailed, recoveryURL: finalURL) }
        return CapturedAudio(sessionID: sessionID, fileURL: finalURL, sampleCount: sampleCount, preRollSampleCount: preRoll)
    }

    func cancel() throws {
        try handle?.close(); handle = nil
        if FileManager.default.fileExists(atPath: partialURL.path) { try FileManager.default.removeItem(at: partialURL); try Self.syncDirectory(partialURL.deletingLastPathComponent()) }
    }

    func preserve() {
        try? checkpoint()
        try? handle?.close(); handle = nil
    }

    static func recover(in directory: URL) throws -> [URL] {
        guard directory.isFileURL else { throw AudioCaptureFailure(.storageFailed) }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var recovered: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) where url.lastPathComponent.hasSuffix(".partial.wav") {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let fd = open(url.path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { throw AudioCaptureFailure(.storageFailed, recoveryURL: url) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                let header = try handle.read(upToCount: 44) ?? Data()
                let expected = Self.header(samples: 0)
                guard header.count == 44,
                      header[0..<4] == expected[0..<4], header[8..<40] == expected[8..<40] else {
                    try handle.close(); continue
                }
                let bytes = try handle.seekToEnd()
                guard bytes >= 44, bytes - 44 <= UInt64(UInt32.max - 36) else { try handle.close(); continue }
                let samples = Int64((bytes - 44) / 4)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Self.header(samples: samples))
                try handle.truncate(atOffset: UInt64(44 + samples * 4))
                try handle.synchronize(); try handle.close()
                let final = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".partial.wav", with: ".wav"))
                try FileManager.default.moveItem(at: url, to: final)
                recovered.append(final)
            } catch { try? handle.close(); throw AudioCaptureFailure(.storageFailed, recoveryURL: url) }
        }
        if !recovered.isEmpty { try syncDirectory(directory) }
        return recovered
    }

    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw AudioCaptureFailure(.storageFailed) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw AudioCaptureFailure(.storageFailed) }
    }

    private static func header(samples: Int64) -> Data {
        var bytes = Data()
        func ascii(_ string: String) { bytes.append(contentsOf: string.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + UInt32(samples * 4)); ascii("WAVEfmt "); u32(16)
        u16(3); u16(1); u32(16_000); u32(64_000); u16(4); u16(32)
        ascii("data"); u32(UInt32(samples * 4))
        return bytes
    }
}
