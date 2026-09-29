import Foundation

/// Downloads one file to a directory, reporting progress.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationDirectory: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var savedFile: URL?
    private var saveError: Error?

    init(destinationDirectory: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destinationDirectory = destinationDirectory
        self.onProgress = onProgress
    }

    func download(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("Upnext/1.0", forHTTPHeaderField: "User-Agent")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so move it now.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            saveError = URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Server responded with HTTP \(http.statusCode)",
            ])
            return
        }
        let name = Self.sanitizedFileName(
            downloadTask.response?.suggestedFilename
                ?? downloadTask.originalRequest?.url?.lastPathComponent
                ?? "download")
        let target = destinationDirectory.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            savedFile = target
        } catch {
            saveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let error = error ?? saveError {
            continuation?.resume(throwing: error)
        } else if let savedFile {
            continuation?.resume(returning: savedFile)
        } else {
            continuation?.resume(throwing: URLError(.cannotCreateFile))
        }
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "download" + cleaned : cleaned
    }
}
