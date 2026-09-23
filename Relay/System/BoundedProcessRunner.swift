import Foundation

struct ProcessResult: Sendable {
    let stdout: Data
    let terminationStatus: Int32
}

enum BoundedProcessError: Error, Equatable {
    case launchFailed
    case timedOut
    case outputTooLarge
}

/// Runs a child process with three hard bounds: stderr is discarded (never an unread pipe that
/// can wedge the child), stdout is drained concurrently and capped at `maxOutputBytes`, and the
/// whole call is bounded by `timeout` (the child is terminated on expiry).
///
/// `async`: callers suspend instead of blocking a Swift Concurrency cooperative-pool thread while
/// the child runs. A synchronous `throws` implementation (as test fakes use) still satisfies it.
protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) async throws -> ProcessResult
}

struct BoundedProcessRunner: ProcessRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let completion = ProcessCompletion()
        let child = ChildProcess(process)
        process.terminationHandler = { finished in
            completion.processExited(status: finished.terminationStatus)
        }

        return try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)

            do {
                try process.run()
            } catch {
                completion.fail(BoundedProcessError.launchFailed)
                return
            }

            // Drain stdout on a dedicated thread: `availableData` blocks until data or EOF. A
            // `Thread` rather than `DispatchQueue.global()`, so many concurrent runs never
            // exhaust GCD's worker-thread limit (about 64) and stall each other's drains.
            let handle = stdoutPipe.fileHandleForReading
            let drain = Thread {
                var accumulated = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    accumulated.append(chunk)
                    if accumulated.count > maxOutputBytes {
                        if completion.fail(BoundedProcessError.outputTooLarge) { child.terminate() }
                        return
                    }
                }
                completion.stdoutFinished(accumulated)
            }
            drain.name = "BoundedProcessRunner.drain"
            drain.start()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if completion.fail(BoundedProcessError.timedOut) { child.terminate() }
            }
        }
    }
}

/// Lets the `@Sendable` drain/timeout closures terminate the child without capturing `Process`
/// itself across isolation domains.
private final class ChildProcess: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { process.terminate() }
}

/// Resumes the run's continuation exactly once: with the result once BOTH stdout has hit EOF and
/// the child has exited, or with the first failure (launch, overflow, timeout). Later signals are
/// ignored.
private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var stdout: Data?
    private var status: Int32?

    func install(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Returns `true` if this call resumed the continuation (the run had not finished yet).
    @discardableResult
    func fail(_ error: Error) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<ProcessResult, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(throwing: error)
        return pending != nil
    }

    func stdoutFinished(_ data: Data) {
        lock.withLock { stdout = data }
        resumeIfComplete()
    }

    func processExited(status: Int32) {
        lock.withLock { self.status = status }
        resumeIfComplete()
    }

    private func resumeIfComplete() {
        let ready = lock.withLock { () -> (CheckedContinuation<ProcessResult, Error>, ProcessResult)? in
            guard let continuation, let stdout, let status else { return nil }
            self.continuation = nil
            return (continuation, ProcessResult(stdout: stdout, terminationStatus: status))
        }
        if let (continuation, result) = ready {
            continuation.resume(returning: result)
        }
    }
}
