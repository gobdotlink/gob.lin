import CryptoKit
import Foundation
import Synchronization

enum ModelAssetDownloadError: Error, LocalizedError {
    case response(Int), invalidRange, invalidSize(expected: Int64, actual: Int64), invalidDigest
    var errorDescription: String? {
        switch self {
        case .response(let status): "Model download failed (HTTP \(status)). Check your connection and retry."
        case .invalidRange: "The model server returned an invalid download range. Retry the download."
        case .invalidSize(let expected, let actual): "The model download had an unexpected size (expected \(expected) bytes, received \(actual)). Retry the download."
        case .invalidDigest: "The downloaded model failed its published checksum. Retry the download."
        }
    }
}

enum ModelAssetDownload {
    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func download(_ asset: SpeechModelAsset, to destination: URL, configuration: URLSessionConfiguration,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        let partial = destination.appendingPathExtension("partial")
        guard (try? partial.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw SpeechModelStoreError.invalidDirectory
        }
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let size = fileSize(partial) ?? 0
            if size > asset.size { try FileManager.default.removeItem(at: partial) }
            if asset.size == 0, !FileManager.default.fileExists(atPath: partial.path) { try Data().write(to: partial) }
            if size != asset.size, asset.size > 0 {
                do {
                    try await ModelFileTransfer(asset: asset, partial: partial, configuration: configuration, progress: progress).run()
                } catch {
                    try Task.checkCancellation()
                    let retryable: Bool
                    switch error {
                    case ModelAssetDownloadError.response(let status): retryable = status == 408 || status == 429 || status >= 500
                    case ModelAssetDownloadError.invalidRange, ModelAssetDownloadError.invalidSize:
                        try? FileManager.default.removeItem(at: partial)
                        retryable = true
                    case is URLError: retryable = true
                    default: retryable = false
                    }
                    guard retryable, attempt < 3 else { throw error }
                    try await Task.sleep(for: .seconds(1 << attempt))
                    continue
                }
            }
            let actual = fileSize(partial) ?? -1
            guard actual == asset.size else { throw ModelAssetDownloadError.invalidSize(expected: asset.size, actual: actual) }
            guard try digest(partial) == asset.sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw ModelAssetDownloadError.invalidDigest
            }
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
            try FileManager.default.moveItem(at: partial, to: destination)
            progress(asset.size)
            return
        }
    }
}

struct ModelDownloadProgressWindow {
    private var started: ContinuousClock.Instant
    private var bytes: Int64 = 0

    init(now: ContinuousClock.Instant = .now) { started = now }

    mutating func record(bytes count: Int64, at now: ContinuousClock.Instant = .now) throws {
        bytes += count
        if started.duration(to: now) >= .seconds(120), bytes < 1_048_576 {
            throw URLError(.timedOut)
        }
        if bytes >= 1_048_576 { started = now; bytes = 0 }
    }
}

/// URLSession delivers ordered chunks off the main thread, without buffering a model in memory.
private final class ModelFileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Void, Error>?
        var cancelled = false
    }
    private let state = Mutex(State())
    private let asset: SpeechModelAsset
    private let partial: URL
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (Int64) -> Void
    // These fields are confined to URLSession's serial delegate queue.
    private var file: FileHandle?
    private var received: Int64 = 0
    private var failure: Error?
    private var lastProgress = ContinuousClock.now
    private var progressWindow = ModelDownloadProgressWindow()

    init(asset: SpeechModelAsset, partial: URL, configuration: URLSessionConfiguration, progress: @escaping @Sendable (Int64) -> Void) {
        self.asset = asset; self.partial = partial; self.configuration = configuration; self.progress = progress
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = self.configuration.copy() as! URLSessionConfiguration
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 86_400
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: asset.url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                received = ModelAssetDownload.fileSize(partial) ?? 0
                if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
                let task = session.dataTask(with: request)
                let cancelled = state.withLock { state in
                    state.continuation = continuation
                    state.task = task
                    return state.cancelled
                }
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            self.state.withLock { state in state.cancelled = true; state.task?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw ModelAssetDownloadError.response(-1) }
            if response.statusCode == 206 {
                let expected = "bytes \(received)-\(asset.size - 1)/\(asset.size)"
                guard response.value(forHTTPHeaderField: "Content-Range") == expected else { throw ModelAssetDownloadError.invalidRange }
            } else if response.statusCode == 200 {
                received = 0
            } else if response.statusCode == 416 {
                throw ModelAssetDownloadError.invalidRange
            } else { throw ModelAssetDownloadError.response(response.statusCode) }
            if response.expectedContentLength >= 0, response.expectedContentLength != asset.size - received {
                throw ModelAssetDownloadError.invalidSize(expected: asset.size - received, actual: response.expectedContentLength)
            }
            if !FileManager.default.fileExists(atPath: partial.path) { try Data().write(to: partial) }
            let file = try FileHandle(forWritingTo: partial)
            self.file = file
            if received == 0 { try file.truncate(atOffset: 0) }
            try file.seek(toOffset: UInt64(received))
            progressWindow = ModelDownloadProgressWindow()
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard received + Int64(data.count) <= asset.size else {
                throw ModelAssetDownloadError.invalidSize(expected: asset.size, actual: received + Int64(data.count))
            }
            try file?.write(contentsOf: data)
            received += Int64(data.count)
            if received < asset.size { try progressWindow.record(bytes: Int64(data.count)) }
            if received == asset.size || lastProgress.duration(to: .now) >= .milliseconds(200) {
                progress(received)
                lastProgress = .now
            }
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close()
        file = nil
        let result: Result<Void, Error>
        if state.withLock({ $0.cancelled }) { result = .failure(CancellationError()) }
        else if let failure = failure ?? error { result = .failure(failure) }
        else if received != asset.size { result = .failure(ModelAssetDownloadError.invalidSize(expected: asset.size, actual: received)) }
        else { result = .success(()) }
        let continuation = state.withLock { state in
            let value = state.continuation
            state.continuation = nil
            state.task = nil
            return value
        }
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
