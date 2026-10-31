import Foundation

/// Where the bundled helper tools are. Environment overrides (`YTMP_YT_DLP`, `YTMP_FFMPEG`) win, then the
/// app bundle's `Resources/bin` (put there by scripts/bundle-tools.sh).
struct ToolPaths: Sendable {
    var ytdlp: URL?
    var ffmpeg: URL?

    private final class BundleAnchor {}

    static func locate(bundle: Bundle = Bundle(for: BundleAnchor.self), environment: [String: String] = ProcessInfo.processInfo.environment) -> ToolPaths {
        func find(_ name: String, variable: String) -> URL? {
            if let override = environment[variable], FileManager.default.isExecutableFile(atPath: override) {
                return URL(fileURLWithPath: override)
            }
            let bundled = bundle.resourceURL?.appendingPathComponent("bin/\(name)")
            if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
            return nil
        }
        return ToolPaths(ytdlp: find("yt-dlp", variable: "YTMP_YT_DLP"), ffmpeg: find("ffmpeg", variable: "YTMP_FFMPEG"))
    }
}

/// One running yt-dlp process. `events` yields the job's progress in order and finishes after the last event
/// (`complete`, `failed` or `cancelled`).
final class DownloadSession: @unchecked Sendable {
    let events: AsyncStream<JobEvent>

    private let continuation: AsyncStream<JobEvent>.Continuation
    private let process = Process()
    /// Serial queue: every line, the exit and the finish decision run here, so state needs no further locking.
    private let queue = DispatchQueue(label: "com.slks.ytmp.session")
    private let lock = NSLock()
    private var cancelRequested = false

    // Touched only on `queue`.
    private var sawFinished = false
    private var currentFile: String?
    private var errorText = ""
    private var terminated = false
    private var exitStatus: Int32 = 0
    private var stdoutClosed = false
    private var stderrClosed = false
    private var done = false

    init(request: DownloadRequest, tools: ToolPaths) {
        (events, continuation) = AsyncStream.makeStream(of: JobEvent.self, bufferingPolicy: .unbounded)
        guard let ytdlp = tools.ytdlp else {
            continuation.yield(.failed(.toolMissing))
            continuation.finish()
            done = true
            return
        }
        continuation.yield(.starting)

        process.executableURL = ytdlp
        process.arguments = YTDLPArguments.build(for: request, ffmpeg: tools.ffmpeg)
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        attach(stdout.fileHandleForReading, onLine: { [self] in handleStdout($0) }, onClosed: { [self] in stdoutClosed = true })
        attach(stderr.fileHandleForReading, onLine: { [self] in handleStderr($0) }, onClosed: { [self] in stderrClosed = true })
        process.terminationHandler = { [self] process in
            queue.async { [self] in
                terminated = true
                exitStatus = process.terminationStatus
                finishIfReady()
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            done = true
            continuation.yield(.failed(.spawnFailed(error.localizedDescription)))
            continuation.finish()
        }
    }

    /// Stops the download. yt-dlp's children (ffmpeg) are killed first so nothing keeps writing.
    func cancel() {
        lock.lock()
        let first = !cancelRequested
        cancelRequested = true
        lock.unlock()
        guard first, process.isRunning else {
            queue.async { [self] in finishIfReady() }
            return
        }
        let pid = process.processIdentifier
        // Off the caller's thread (usually the main one): pkill is quick, but it is still a process launch.
        DispatchQueue.global().async { [self] in
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killer.arguments = ["-KILL", "-P", String(pid)]
            try? killer.run()
            killer.waitUntilExit()
            kill(pid, SIGKILL)
            queue.async { [self] in finishIfReady() }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    // MARK: Reading

    /// Splits a pipe into lines on `queue`; `onClosed` runs after the last one.
    private func attach(_ handle: FileHandle, onLine: @escaping @Sendable (String) -> Void, onClosed: @escaping @Sendable () -> Void) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { [queue] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                let rest = buffer.flush()
                queue.async {
                    if let rest { onLine(rest) }
                    onClosed()
                    self.finishIfReady()
                }
                return
            }
            let lines = buffer.append(data)
            if !lines.isEmpty { queue.async { lines.forEach(onLine) } }
        }
    }

    private func handleStdout(_ line: String) {
        guard let event = YTDLPParser.parseStdout(line) else { return }
        switch event {
        case .finished: sawFinished = true
        case .metadata(_, let filename): currentFile = filename
        default: break
        }
        continuation.yield(event)
    }

    private func handleStderr(_ line: String) {
        switch YTDLPParser.parseStderr(line) {
        case .processing(let name): continuation.yield(.processing(name))
        case .error(let text): errorText += text + "\n"
        case nil: break
        }
    }

    // MARK: Finishing

    /// Decides the outcome once yt-dlp has exited and both pipes are drained (after a cancel the pipes may stay
    /// open because an orphaned ffmpeg holds them, so the exit alone is enough).
    private func finishIfReady() {
        guard !done, terminated else { return }
        let cancelled = isCancelled
        guard cancelled || (stdoutClosed && stderrClosed) else { return }
        done = true
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil

        if cancelled {
            if let currentFile { Partials.remove(forFilename: currentFile) }
            continuation.yield(.cancelled)
        } else if exitStatus != 0, !sawFinished {
            let message = YTDLPParser.failureMessage(from: errorText)
            continuation.yield(.failed(message.map(JobFailure.reported) ?? .downloadFailed))
        } else {
            continuation.yield(.complete)
        }
        continuation.finish()
    }
}

/// Collects bytes from a pipe and hands back complete lines.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
            data = Data(data[data.index(after: newline)...])
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        defer { data = Data() }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
}
