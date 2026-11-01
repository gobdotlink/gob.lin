import AppKit
import Combine
import GoblinCore

enum UpdateFailure: Error, LocalizedError {
    case authentication, noReleases, http(Int), invalidRelease, invalidArchive, signature, incompatible
    case notPackaged, notInstalled, busy, command, checksum

    var errorDescription: String? {
        switch self {
        case .authentication: "GitHub access is unavailable. Sign in with gh or save a token with Contents read access to akalikin/gob.lin."
        case .noReleases: "No release found. If you have repository access, no release may have been published yet."
        case .http(let status): "GitHub returned HTTP \(status). Try again later."
        case .invalidRelease: "The release is missing its versioned gob.lin ZIP."
        case .invalidArchive: "The update archive is invalid. The installed app has not changed."
        case .signature: "The update does not match this app’s signing identity. Install a trusted release manually when changing certificates."
        case .incompatible: "This release requires a newer macOS version or a different Mac architecture."
        case .notPackaged: "Run a certificate-signed copy of gob.lin to install updates."
        case .notInstalled: "I can’t update myself from this folder. Move gob.lin to Applications, open it from there, and try again."
        case .busy: "Finish dictation, retry unsaved history, and restore any recovery clipboard before updating."
        case .command: "The update could not be prepared. The installed app has not changed."
        case .checksum: "The update download failed its integrity check. Try again."
        }
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let id: Int
        let name: String
        let size: Int64
        let digest: String?
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    var version: ReleaseVersion? { ReleaseVersion(tag_name) }
    var archive: Asset? {
        guard !draft, !prerelease, let version else { return nil }
        return assets.first { $0.name == "gob.lin-\(version).zip" && $0.size > 0 && $0.size <= 250_000_000 }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate, available(String), downloading, installing, failed(String)
    }
    static let repository = "akalikin/gob.lin"
    // ponytail: same preferences compromise as RewriteKeyStore; move back to Keychain with the certificate.
    private static let tokenKey = "updateGitHubToken"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var ghAuthenticated = false
    var canInstall: () -> Bool = { false }
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var release: GitHubRelease?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? GoblinMetadata.version
    }
    var isBusy: Bool { phase == .checking || phase == .downloading || phase == .installing }
    var availableVersion: String? { release?.version?.description }
    var status: String {
        switch phase {
        case .idle: "Checks GitHub Releases at launch and every hour."
        case .checking: "Checking for updates…"
        case .upToDate: "You’re up to date · v\(currentVersion)"
        case .available(let version): "v\(version) is available."
        case .downloading: "Downloading and verifying update…"
        case .installing: "Restarting to install update…"
        case .failed(let message): message
        }
    }

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; task?.cancel() }

    func saveToken(_ value: String) {
        guard !isBusy else { return }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { UserDefaults.standard.removeObject(forKey: Self.tokenKey) }
        else { UserDefaults.standard.set(token, forKey: Self.tokenKey) }
        check()
    }

    func check() {
        guard !isBusy else { return }
        phase = .checking
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await credentials()
                let latest = try await latestRelease(token: token)
                try Task.checkCancellation()
                guard let version = latest.version, latest.archive != nil,
                      let current = ReleaseVersion(currentVersion) else { throw UpdateFailure.invalidRelease }
                release = version > current ? latest : nil
                phase = release == nil ? .upToDate : .available(version.description)
            } catch is CancellationError { phase = .idle }
            catch { phase = .failed(message(error)) }
        }
    }

    func install() {
        guard !isBusy, let release, let asset = release.archive, let version = release.version else { return }
        guard canInstall() else { phase = .failed(UpdateFailure.busy.localizedDescription); return }
        phase = .downloading
        task = Task { [weak self] in
            guard let self else { return }
            var staging: URL?
            var handedOff = false
            defer { if !handedOff, let staging { try? FileManager.default.removeItem(at: staging) } }
            do {
                let token = try await credentials()
                let bundle = Bundle.main.bundleURL
                staging = try UpdateInstaller.stagingDirectory(for: bundle)
                let request = request(path: "releases/assets/\(asset.id)", token: token, accept: "application/octet-stream")
                let session = URLSession(configuration: .ephemeral, delegate: UpdateRedirects(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (download, response) = try await session.download(for: request)
                defer { try? FileManager.default.removeItem(at: download) }
                try validate(response, authenticated: token != nil)
                let archive = staging!.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: download, to: archive)
                let directory = staging!
                let requirement = try UpdateInstaller.currentRequirement()
                try await Task.detached {
                    try UpdateInstaller.prepare(archive: archive, in: directory, asset: asset,
                                                version: version, requirement: requirement)
                }.value
                try Task.checkCancellation()
                guard canInstall() else { throw UpdateFailure.busy }
                try UpdateInstaller.launchHelper(in: directory, replacing: bundle)
                handedOff = true
                phase = .installing
                Self.requestTermination()
            } catch is CancellationError { phase = .idle }
            catch { phase = .failed(message(error)) }
        }
    }

    static func requestTermination() {
        // AppKit enters a nested event loop while awaiting async shutdown. Enter
        // termination from a run-loop callback, outside both the Swift task and
        // the main dispatch queue, so shutdown can use the main actor's queue.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    private func credentials() async throws -> String? {
        let token = await Task.detached { () -> String? in
            for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
                if let data = try? UpdateInstaller.run(path, ["auth", "token", "--hostname", "github.com"]),
                   let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return nil
        }.value
        try Task.checkCancellation()
        ghAuthenticated = token != nil
        return token ?? UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    private func request(path: String, token: String?, accept: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/\(path)")!)
        request.timeoutInterval = 60
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("gob.lin/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func latestRelease(token: String?) async throws -> GitHubRelease {
        let session = URLSession(configuration: .ephemeral, delegate: UpdateRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(path: "releases/latest", token: token, accept: "application/vnd.github+json"))
        try validate(response, authenticated: token != nil)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func validate(_ response: URLResponse, authenticated: Bool) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw authenticated ? UpdateFailure.noReleases : UpdateFailure.authentication }
        if code == 401 || code == 403 { throw UpdateFailure.authentication }
        guard code == 200 else { throw UpdateFailure.http(code) }
    }

    private func message(_ error: Error) -> String {
        if error is URLError { return "Could not reach GitHub. Check your connection and try again." }
        if let error = error as? UpdateFailure { return error.localizedDescription }
        return "The update could not be completed. The installed app has not changed. Try again."
    }
}

/// Asset requests redirect to signed storage URLs; credentials must stay on api.github.com.
final class UpdateRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard request.url?.scheme == "https" else { return nil }
        var request = request
        if request.url?.host != "api.github.com" { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        return request
    }
}
