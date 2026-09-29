import Foundation

enum Shell {
    /// Holds data written by one queue and read by another after a DispatchGroup wait.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    struct Failure: LocalizedError {
        var command: String
        var result: Result
        var errorDescription: String? {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) failed (\(result.status))" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }

    /// Runs an executable off the main thread and returns its output.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                    allowFailure: Bool = false) async throws -> Result {
        let result: Result = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe(), err = Pipe(), inPipe = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = inPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let input {
                    inPipe.fileHandleForWriting.write(Data(input.utf8))
                }
                try? inPipe.fileHandleForWriting.close()
                // Read both pipes before waiting so a chatty process can't block on a full pipe.
                let stderrBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    stderrBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                let stderrData = stderrBox.data
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: stdoutData,
                    stderr: String(decoding: stderrData, as: UTF8.self)
                ))
            }
        }
        if result.status != 0 && !allowFailure {
            let name = (executable as NSString).lastPathComponent
            throw Failure(command: ([name] + arguments.prefix(1)).joined(separator: " "), result: result)
        }
        return result
    }
}
