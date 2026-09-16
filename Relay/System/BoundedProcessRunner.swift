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

/// Runs a child process with three hard bounds: stderr is discarded (never an
/// unread pipe that can wedge the child), stdout is drained concurrently and
/// capped at `maxOutputBytes`, and the whole call is bounded by `timeout`
/// (the child is terminated on expiry).
protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult
}

struct BoundedProcessRunner: ProcessRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw BoundedProcessError.launchFailed }

        let readSemaphore = DispatchSemaphore(value: 0)
        let dataBox = LockedBox<Data>(Data())
        let overflowBox = LockedBox<Bool>(false)
        let readQueue = DispatchQueue(label: "BoundedProcessRunner.stdoutDrain")
        readQueue.async {
            let handle = stdoutPipe.fileHandleForReading
            var accumulated = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                accumulated.append(chunk)
                if accumulated.count > maxOutputBytes {
                    overflowBox.value = true
                    break
                }
            }
            dataBox.value = accumulated
            readSemaphore.signal()
        }

        let deadline = DispatchTime.now() + timeout
        guard readSemaphore.wait(timeout: deadline) == .success else {
            process.terminate()
            throw BoundedProcessError.timedOut
        }
        if overflowBox.value {
            process.terminate()
            throw BoundedProcessError.outputTooLarge
        }

        process.waitUntilExit()
        return ProcessResult(stdout: dataBox.value, terminationStatus: process.terminationStatus)
    }
}

/// Shared NSLock-protected box used to hand values back from a background thread (e.g. the
/// stdout drain thread) across an explicit `DispatchQueue.async` boundary. `T` itself may be
/// `Sendable` (as `Data` and `Bool` are), but this avoids relying on unsynchronized capture.
/// Single shared definition — was previously duplicated in `ProcessInspector` and
/// `HerdrHostOwnershipChecker`.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
