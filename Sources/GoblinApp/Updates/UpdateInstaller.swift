import CryptoKit
import Foundation
import GoblinCore
import Security

enum UpdateInstaller {
    static func stagingDirectory(for bundle: URL) throws -> URL {
        let manager = FileManager.default
        guard bundle.pathExtension == "app", !bundle.pathComponents.contains("AppTranslocation"),
              try bundle.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              manager.isWritableFile(atPath: bundle.path),
              manager.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else { throw UpdateFailure.notInstalled }
        let directory = bundle.deletingLastPathComponent().appendingPathComponent(".goblin-update-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    static func currentRequirement(at bundle: URL = Bundle.main.bundleURL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { throw UpdateFailure.notPackaged }
        return text as String
    }

    static func prepare(archive: URL, in directory: URL, asset: GitHubRelease.Asset,
                        version: ReleaseVersion, requirement: String) throws {
        guard let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == asset.size else { throw UpdateFailure.checksum }
        if let digest = asset.digest {
            guard digest.hasPrefix("sha256:"), digest.count == 71 else { throw UpdateFailure.checksum }
            let file = try FileHandle(forReadingFrom: archive)
            defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == "sha256:" + actual else { throw UpdateFailure.checksum }
        }
        // Reject traversal, extra top-level content and links before invoking the system extractor.
        let names = String(decoding: try run("/usr/bin/zipinfo", ["-1", archive.path]), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        guard !names.isEmpty, names.allSatisfy({ name in
            name.hasPrefix("gob.lin.app/") && !name.contains("\\") && !name.contains("\r") &&
            !name.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }) else { throw UpdateFailure.invalidArchive }
        let listing = String(decoding: try run("/usr/bin/zipinfo", ["-l", archive.path]), as: UTF8.self)
        guard !listing.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw UpdateFailure.invalidArchive }
        let payload = directory.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        _ = try run("/usr/bin/ditto", ["-xk", archive.path, payload.path])
        let app = payload.appendingPathComponent("gob.lin.app")
        try verify(app: app, version: version, requirement: requirement)
    }

    static func verify(app: URL, version: ReleaseVersion, requirement text: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw UpdateFailure.signature
        }
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        guard plist?["CFBundleIdentifier"] as? String == GoblinMetadata.bundleIdentifier,
              plist?["CFBundleExecutable"] as? String == "GoblinApp",
              plist?["CFBundleShortVersionString"] as? String == version.description else { throw UpdateFailure.invalidRelease }
        guard let minimum = plist?["LSMinimumSystemVersion"] as? String else { throw UpdateFailure.incompatible }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        guard (1...3).contains(parts.count), parts.count == minimum.split(separator: ".").count,
              parts.allSatisfy({ $0 >= 0 }),
              ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: parts[0],
                minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)) else { throw UpdateFailure.incompatible }
        #if arch(arm64)
        let architecture = NSBundleExecutableArchitectureARM64
        #else
        let architecture = NSBundleExecutableArchitectureX86_64
        #endif
        guard Bundle(url: app)?.executableArchitectures?.contains(NSNumber(value: architecture)) == true else {
            throw UpdateFailure.incompatible
        }
    }

    static func launchHelper(in staging: URL, replacing bundle: URL) throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("Assets/install-update.sh"),
              FileManager.default.fileExists(atPath: source.path) else { throw UpdateFailure.command }
        let helper = staging.appendingPathComponent("install.sh")
        try FileManager.default.copyItem(at: source, to: helper)
        let logs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gob.lin/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), bundle.path, staging.path,
                             logs.appendingPathComponent("update-install.log").path]
        process.currentDirectoryURL = staging
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Called on a worker for blocking utilities; never includes tool stderr or credentials in errors.
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { throw UpdateFailure.command }
        return data
    }
}
