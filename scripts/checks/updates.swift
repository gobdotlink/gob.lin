import Foundation
import GoblinCore

@main
struct UpdateChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func rejected(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Unsafe update accepted") }
        catch { }
    }

    static func main() async throws {
        let json = #"{"tag_name":"v1.10.0","draft":false,"prerelease":false,"assets":[{"id":1,"name":"unrelated.zip","size":100},{"id":2,"name":"gob.lin-1.10.0.zip","size":200}]}"#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        require(release.archive?.id == 2, "Select the versioned app archive, not the first ZIP")
        for variant in [json.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true"),
                        json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true"),
                        json.replacingOccurrences(of: "v1.10.0", with: "v1.10.0-beta"),
                        json.replacingOccurrences(of: "\"size\":200", with: "\"size\":999999999") ] {
            let invalid = try JSONDecoder().decode(GitHubRelease.self, from: Data(variant.utf8))
            require(invalid.archive == nil, "Exclude unstable and malformed releases")
        }
        let redirects = UpdateRedirects()
        let url = URL(string: "https://api.github.com/repos/example/example")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        var request = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/archive")!)
        request.setValue("Bearer synthetic-test-token", forHTTPHeaderField: "Authorization")
        let stripped = await redirects.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request)
        require(stripped?.value(forHTTPHeaderField: "Authorization") == nil, "Do not leak auth on asset redirects")
        request.url = URL(string: "http://example.com/archive")!
        let insecure = await redirects.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request)
        require(insecure == nil, "Reject insecure redirects")

        // Optional signed fixture exercises actual code-signing trust, without launching or requesting grants.
        if let path = CommandLine.arguments.dropFirst().first {
            let app = URL(fileURLWithPath: path)
            let requirement = try UpdateInstaller.currentRequirement(at: app)
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))!
            let version = ReleaseVersion(info["CFBundleShortVersionString"] as! String)!
            try UpdateInstaller.verify(app: app, version: version, requirement: requirement)
            rejected { try UpdateInstaller.verify(app: app, version: ReleaseVersion("999.0.0")!, requirement: requirement) }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: work) }
            let copy = work.appendingPathComponent("gob.lin.app")
            try FileManager.default.copyItem(at: app, to: copy)
            let archive = work.appendingPathComponent("app.zip")
            _ = try UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--norsrc", copy.path, archive.path])
            let bytes = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            let asset = GitHubRelease.Asset(id: 1, name: "gob.lin-\(version).zip", size: Int64(bytes), digest: nil)
            let payload = work.appendingPathComponent("staged")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
            try UpdateInstaller.prepare(archive: archive, in: payload, asset: asset, version: version, requirement: requirement)
            let badAsset = GitHubRelease.Asset(id: 1, name: asset.name, size: asset.size, digest: "sha256:" + String(repeating: "0", count: 64))
            rejected { try UpdateInstaller.prepare(archive: archive, in: payload, asset: badAsset, version: version, requirement: requirement) }
            try Data("tampered".utf8).write(to: copy.appendingPathComponent("Contents/Resources/Goblin.icns"))
            rejected { try UpdateInstaller.verify(app: copy, version: version, requirement: requirement) }
            _ = try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", copy.path])
            rejected { _ = try UpdateInstaller.currentRequirement(at: copy) }
            rejected { try UpdateInstaller.verify(app: copy, version: version, requirement: requirement) }
        }
        print("Release selection, credentials redirects, and signature checks passed.")
    }
}
