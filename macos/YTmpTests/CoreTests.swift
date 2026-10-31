import Foundation
import Testing

@testable import YTmp

// MARK: - Helpers

/// A throwaway directory removed when the value goes away.
private final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ytmp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A stand-in for yt-dlp: a shell script that prints what the real one would.
private func fakeYTDLP(in dir: TempDir, _ body: String, executable: Bool = true) throws -> ToolPaths {
    let script = dir.url.appendingPathComponent("yt-dlp")
    try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: script.path)
    return ToolPaths(ytdlp: script, ffmpeg: nil)
}

private func request(_ format: DownloadFormat = .mp3, dir: String = "/tmp/out") -> DownloadRequest {
    DownloadRequest(url: "https://youtu.be/abc", format: format, outputDir: dir, browser: nil)
}

private func collect(_ session: DownloadSession) async -> [JobEvent] {
    var events: [JobEvent] = []
    for await event in session.events { events.append(event) }
    return events
}

// MARK: - Parsing

@Suite struct ParserTests {
    @Test func percent() {
        #expect(YTDLPParser.parsePercent("  50.7%") == 50.7)
        #expect(YTDLPParser.parsePercent("100%") == 100)
        #expect(YTDLPParser.parsePercent("N/A") == nil)
    }

    @Test func stdoutLines() {
        #expect(YTDLPParser.parseStdout(#"@@J@@{"status":"metadata","title":"Tune ✓","duration":12.5,"filename":"/o/Tune.mp4"}"#)
            == .metadata(title: "Tune ✓", filename: "/o/Tune.mp4"))
        #expect(YTDLPParser.parseStdout(#"@@J@@{"status":"metadata","title":null,"duration":null,"filename":"x"}"#)
            == .metadata(title: nil, filename: "x"))
        #expect(YTDLPParser.parseStdout(#"@@J@@{"status":"finished","filepath":"/o/Tune.mp3"}"#) == .finished(filepath: "/o/Tune.mp3"))
        #expect(YTDLPParser.parseStdout(#"@@D@@{"pct":"  12.5%","speed":" 1.2MiB/s","eta":"00:09 "}"#)
            == .downloading(progress: 12.5, speed: "1.2MiB/s", eta: "00:09"))
        #expect(YTDLPParser.parseStdout(#"@@D@@{"pct":"Unknown","speed":"Unknown","eta":"Unknown"}"#) == .downloading(progress: 0, speed: "Unknown", eta: "Unknown"))
    }

    @Test func ignoresNoiseAndMalformedLines() {
        #expect(YTDLPParser.parseStdout("[youtube] Extracting URL") == nil)
        #expect(YTDLPParser.parseStdout("@@J@@{not json") == nil)
        #expect(YTDLPParser.parseStdout(#"@@J@@{"status":"finished","filepath":""}"#) == nil)
        #expect(YTDLPParser.parseStdout(#"@@J@@{"status":"unknown"}"#) == nil)
        #expect(YTDLPParser.parseStdout("") == nil)
    }

    @Test func stderrLines() {
        #expect(YTDLPParser.parseStderr("@@P@@ExtractAudio") == .processing("ExtractAudio"))
        #expect(YTDLPParser.parseStderr("@@P@@") == nil)
        #expect(YTDLPParser.parseStderr("ERROR: [youtube] abc: Video unavailable") == .error("ERROR: [youtube] abc: Video unavailable"))
        #expect(YTDLPParser.parseStderr("WARNING: nothing") == nil)
    }

    @Test func failureMessageIsTheLastError() {
        #expect(YTDLPParser.failureMessage(from: "ERROR: first\nERROR: [youtube] abc: Private video\n") == "[youtube] abc: Private video")
        #expect(YTDLPParser.failureMessage(from: "") == nil)
        #expect(YTDLPParser.failureMessage(from: "ERROR:\n") == nil)
    }
}

@Suite struct ArgumentTests {
    @Test func mp3() {
        let args = YTDLPArguments.build(for: request(.mp3), ffmpeg: nil)
        #expect(args.first == "https://youtu.be/abc")
        #expect(args.contains("-x"))
        #expect(args.joined(separator: " ").contains("--audio-format mp3 --audio-quality 320K"))
        #expect(!args.contains("--merge-output-format"))
        #expect(!args.contains("--ffmpeg-location"))
        #expect(!args.contains("--cookies-from-browser"))
    }

    @Test func mp4WithFfmpegAndBrowser() {
        var req = request(.mp4)
        req.browser = " chrome "
        let args = YTDLPArguments.build(for: req, ffmpeg: URL(fileURLWithPath: "/opt/ffmpeg"))
        #expect(args.joined(separator: " ").contains("--merge-output-format mp4"))
        #expect(args.joined(separator: " ").contains("--ffmpeg-location /opt/ffmpeg"))
        #expect(args.joined(separator: " ").contains("--cookies-from-browser chrome"))
        #expect(!args.contains("-x"))
    }

    @Test func outputTemplateTrimsTrailingSlash() {
        let args = YTDLPArguments.build(for: request(dir: "/tmp/out//"), ffmpeg: nil)
        #expect(args[args.firstIndex(of: "-o")! + 1] == "/tmp/out/%(title)s.%(ext)s")
    }

    @Test func urlIsPassedAsOneArgument() {
        var req = request()
        req.url = "https://x.test/a b; rm -rf ~"
        #expect(YTDLPArguments.build(for: req, ffmpeg: nil).first == "https://x.test/a b; rm -rf ~")
    }
}

@Suite struct URLInputTests {
    @Test func normalizes() {
        #expect(URLInput.normalize("https://youtu.be/seJ83vfHoIU") == "https://youtu.be/seJ83vfHoIU")
        #expect(URLInput.normalize("  youtu.be/seJ83vfHoIU \n") == "https://youtu.be/seJ83vfHoIU")
        #expect(URLInput.normalize("www.youtube.com/watch?v=abc") == "https://www.youtube.com/watch?v=abc")
        #expect(URLInput.normalize("music.youtube.com/watch?v=abc") == "https://music.youtube.com/watch?v=abc")
        #expect(URLInput.normalize("HTTP://example.com/x") != nil)
    }

    @Test func rejects() {
        #expect(URLInput.normalize("") == nil)
        #expect(URLInput.normalize("   ") == nil)
        #expect(URLInput.normalize("hello world") == nil)
        #expect(URLInput.normalize("ftp://example.com/x") == nil)
        #expect(URLInput.normalize("file:///etc/passwd") == nil)
        #expect(URLInput.normalize("https://") == nil)
    }
}

@Suite struct PartialsTests {
    @Test func removesOnlyPartialsOfThatFile() throws {
        let dir = try TempDir()
        let names = ["Song.mp4", "Song.mp4.part", "Song.f137.mp4.part", "Song.mp4.ytdl", "Song.temp.mp4", "Other.mp4.part", "Other.mp4"]
        for name in names { FileManager.default.createFile(atPath: dir.url.appendingPathComponent(name).path, contents: Data()) }
        Partials.remove(forFilename: dir.url.appendingPathComponent("Song.mp4").path)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.url.path))
        #expect(left == ["Song.mp4", "Other.mp4.part", "Other.mp4"])
    }
}

// MARK: - Job

@MainActor @Suite struct JobTests {
    @Test func foldsEventsIntoState() {
        let job = Job(url: "https://youtu.be/abc", format: .mp3)
        job.apply(.starting)
        #expect(job.status == .starting && job.state == .running)
        job.apply(.metadata(title: "Song", filename: "/o/Song.webm"))
        #expect(job.title == "Song" && job.progress == 0)
        job.apply(.downloading(progress: 42.4, speed: "1MiB/s", eta: "00:03"))
        #expect(job.progress == 42.4 && job.detail == "42% · 1MiB/s · ETA 00:03")
        job.apply(.processing("ExtractAudio"))
        #expect(job.status == .processing && job.progress == 100 && job.detail == "ExtractAudio")
        job.apply(.finished(filepath: "/o/Song.mp3"))
        job.apply(.finished(filepath: "/o/Song2.mp3"))
        #expect(job.count == 2 && job.filepath == "/o/Song2.mp3")
        job.apply(.complete)
        #expect(job.state == .done && job.detail.isEmpty)
    }

    @Test func failureAndCancel() {
        let failed = Job(url: "u", format: .mp4)
        failed.apply(.failed(.reported("Private video")))
        #expect(failed.state == .error && failed.failure == .reported("Private video"))
        failed.reset()
        #expect(failed.state == .running && failed.failure == nil && failed.log.isEmpty)

        let cancelled = Job(url: "u", format: .mp4)
        cancelled.apply(.cancelled)
        #expect(cancelled.state == .cancelled)
    }

    @Test func recordRoundTrip() throws {
        let job = Job(url: "https://youtu.be/abc", format: .mp4)
        job.apply(.metadata(title: "T", filename: nil))
        job.apply(.finished(filepath: "/o/T.mp4"))
        job.apply(.complete)
        let data = try JSONEncoder().encode(job.record)
        let restored = Job(record: try JSONDecoder().decode(JobRecord.self, from: data))
        #expect(restored.id == job.id && restored.title == "T" && restored.state == .done && restored.filepath == "/o/T.mp4")
        #expect(restored.status == .finished && restored.progress == 100)
    }
}

// MARK: - Session against a fake yt-dlp

@Suite struct SessionTests {
    @Test func successfulDownload() async throws {
        let dir = try TempDir()
        let tools = try fakeYTDLP(
            in: dir,
            """
            echo '@@J@@{"status":"metadata","title":"Song","duration":10,"filename":"/o/Song.webm"}'
            echo '@@D@@{"pct":" 50.0%","speed":"1MiB/s","eta":"00:01"}'
            echo '@@P@@ExtractAudio' >&2
            echo '[download] noise'
            echo '@@J@@{"status":"finished","filepath":"/o/Song.mp3"}'
            """)
        let events = await collect(DownloadSession(request: request(), tools: tools))
        // stdout and stderr are separate pipes, so only the order within each is guaranteed.
        let withoutProcessing = events.filter { $0 != .processing("ExtractAudio") }
        let expected: [JobEvent] = [
            .starting,
            .metadata(title: "Song", filename: "/o/Song.webm"),
            .downloading(progress: 50, speed: "1MiB/s", eta: "00:01"),
            .finished(filepath: "/o/Song.mp3"),
            .complete,
        ]
        #expect(withoutProcessing == expected)
        #expect(events.contains(.processing("ExtractAudio")))
    }

    @Test func reportsYtDlpError() async throws {
        let dir = try TempDir()
        let tools = try fakeYTDLP(in: dir, "echo 'ERROR: [youtube] abc: Video unavailable' >&2\nexit 1")
        let events = await collect(DownloadSession(request: request(), tools: tools))
        #expect(events == [.starting, .failed(.reported("[youtube] abc: Video unavailable"))])
    }

    @Test func failureWithoutMessage() async throws {
        let dir = try TempDir()
        let tools = try fakeYTDLP(in: dir, "exit 3")
        #expect(await collect(DownloadSession(request: request(), tools: tools)) == [.starting, .failed(.downloadFailed)])
    }

    @Test func nonzeroExitAfterFinishedCountsAsComplete() async throws {
        let dir = try TempDir()
        let tools = try fakeYTDLP(
            in: dir,
            """
            echo '@@J@@{"status":"finished","filepath":"/o/One.mp3"}'
            echo 'ERROR: second item failed' >&2
            exit 1
            """)
        let events = await collect(DownloadSession(request: request(), tools: tools))
        #expect(events == [.starting, .finished(filepath: "/o/One.mp3"), .complete])
    }

    @Test func missingTool() async {
        #expect(await collect(DownloadSession(request: request(), tools: ToolPaths(ytdlp: nil, ffmpeg: nil))) == [.failed(.toolMissing)])
    }

    @Test func unlaunchableTool() async throws {
        let dir = try TempDir()
        let tools = try fakeYTDLP(in: dir, "exit 0", executable: false)
        let events = await collect(DownloadSession(request: request(), tools: tools))
        #expect(events.first == .starting)
        guard case .failed(.spawnFailed)? = events.last else {
            Issue.record("expected spawnFailed, got \(events)")
            return
        }
    }

    @Test func handlesLongOutputAndPartialLastLine() async throws {
        let dir = try TempDir()
        let tools = try fakeYTDLP(
            in: dir,
            """
            i=0
            while [ $i -lt 500 ]; do echo '@@D@@{"pct":"'$i'%","speed":"s","eta":"e"}'; i=$((i+1)); done
            printf '@@J@@{"status":"finished","filepath":"/o/last.mp3"}'
            """)
        let events = await collect(DownloadSession(request: request(), tools: tools))
        let expectedCount = 503  // starting, 500 progress lines, the unterminated last line, complete
        #expect(events.count == expectedCount)
        #expect(events[500] == .downloading(progress: 499, speed: "s", eta: "e"))
        #expect(events.contains(.finished(filepath: "/o/last.mp3")))
        #expect(events.last == .complete)
    }

    @Test func cancelStopsTheProcessAndRemovesPartials() async throws {
        let dir = try TempDir()
        let out = try TempDir()
        let file = out.url.appendingPathComponent("Song.mp4").path
        let tools = try fakeYTDLP(
            in: dir,
            """
            touch '\(file).part'
            echo '@@J@@{"status":"metadata","title":"Song","duration":1,"filename":"\(file)"}'
            sleep 30
            """)
        let session = DownloadSession(request: request(), tools: tools)
        var events: [JobEvent] = []
        for await event in session.events {
            events.append(event)
            if case .metadata = event { session.cancel() }
        }
        #expect(events.last == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: file + ".part"))
    }

    @Test func realBundledYtDlpStarts() throws {
        guard let ytdlp = ToolPaths.locate().ytdlp else { return }  // binaries are optional locally
        let process = Process()
        process.executableURL = ytdlp
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let version = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(process.terminationStatus == 0)
        #expect(!version.isEmpty)
    }
}

// MARK: - App model

@MainActor @Suite struct AppModelTests {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "ytmp-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func waitUntilIdle(_ model: AppModel) async {
        for _ in 0..<200 where model.runningCount > 0 { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func downloadFlowAndHistory() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try TempDir()
        let tools = try fakeYTDLP(
            in: dir,
            """
            echo '@@J@@{"status":"metadata","title":"Song","duration":1,"filename":"/o/Song.webm"}'
            echo '@@J@@{"status":"finished","filepath":"/o/Song.mp3"}'
            """)
        let model = AppModel(defaults: defaults, tools: tools, downloadsDirectory: dir.url.path)
        model.format = .mp3
        model.outputDir = dir.url.path  // a chosen folder is remembered; the default one is not stored
        model.urlText = "youtu.be/abc"
        model.submit()
        #expect(model.urlText.isEmpty)
        #expect(model.jobs.count == 1)
        await waitUntilIdle(model)

        let job = try #require(model.jobs.first)
        #expect(job.url == "https://youtu.be/abc")
        #expect(job.state == .done && job.title == "Song" && job.filepath == "/o/Song.mp3" && job.count == 1)

        // A new model on the same defaults restores the finished job, the format and the folder.
        let restored = AppModel(defaults: defaults, tools: tools)
        #expect(restored.jobs.map(\.title) == ["Song"])
        #expect(restored.format == .mp3 && restored.outputDir == dir.url.path)

        model.clearFinished()
        #expect(model.jobs.isEmpty)
        #expect(AppModel(defaults: defaults, tools: tools).jobs.isEmpty)
    }

    @Test func invalidUrlShowsToastAndStartsNothing() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, tools: ToolPaths(ytdlp: nil, ffmpeg: nil), downloadsDirectory: "/tmp")
        model.urlText = "not a link"
        model.submit()
        #expect(model.jobs.isEmpty)
        #expect(model.toast == model.strings("invalidUrl"))
    }

    @Test func retryRunsAgainAfterFailure() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try TempDir()
        let marker = dir.url.appendingPathComponent("ran-once").path
        // Fails the first time, succeeds the second.
        let tools = try fakeYTDLP(
            in: dir,
            """
            if [ -e '\(marker)' ]; then
              echo '@@J@@{"status":"finished","filepath":"/o/A.mp4"}'
            else
              touch '\(marker)'; echo 'ERROR: boom' >&2; exit 1
            fi
            """)
        let model = AppModel(defaults: defaults, tools: tools, downloadsDirectory: dir.url.path)
        model.urlText = "https://youtu.be/abc"
        model.submit()
        await waitUntilIdle(model)
        let job = try #require(model.jobs.first)
        #expect(job.state == .error && job.failure == .reported("boom"))
        model.retry(job)
        await waitUntilIdle(model)
        #expect(job.state == .done && job.failure == nil && job.filepath == "/o/A.mp4")
    }

    @Test func cancelRunningJob() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try TempDir()
        let tools = try fakeYTDLP(in: dir, "sleep 30")
        let model = AppModel(defaults: defaults, tools: tools, downloadsDirectory: dir.url.path)
        model.urlText = "https://youtu.be/abc"
        model.submit()
        let job = try #require(model.jobs.first)
        try await Task.sleep(for: .milliseconds(300))
        model.cancel(job)
        #expect(job.cancelRequested)
        await waitUntilIdle(model)
        #expect(job.state == .cancelled)
    }

    @Test func dropFillsTheUrlField() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, tools: ToolPaths(ytdlp: nil, ffmpeg: nil), downloadsDirectory: "/tmp")
        model.handleDrop(["# comment\nnot a url\nhttps://youtu.be/abc\nhttps://youtu.be/second"])
        #expect(model.urlText == "https://youtu.be/abc")
        model.handleDrop(["nothing useful"])
        #expect(model.urlText == "https://youtu.be/abc")
    }

    @Test func preferencesPersist() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, tools: ToolPaths(ytdlp: nil, ffmpeg: nil), downloadsDirectory: "/tmp")
        #expect(model.theme == .system && model.fontSize == .medium && model.language == .cs && model.format == .mp4)
        model.theme = .dark
        model.fontSize = .large
        model.language = .en
        let again = AppModel(defaults: defaults, tools: ToolPaths(ytdlp: nil, ffmpeg: nil), downloadsDirectory: "/tmp")
        #expect(again.theme == .dark && again.fontSize == .large && again.language == .en)
    }
}

// MARK: - Strings

@Suite struct StringsTests {
    @Test func bothLanguagesHaveTheSameKeys() {
        #expect(Set(Strings.table[.cs]!.keys) == Set(Strings.table[.en]!.keys))
    }

    @Test func formatsArguments() {
        #expect(Strings(language: .en)("busy", 3) == "Running: 3")
        #expect(Strings(language: .cs)("busy", 2) == "Probíhá: 2")
        #expect(Strings(language: .en).failure(.spawnFailed("nope")) == "Could not start yt-dlp: nope")
        #expect(Strings(language: .en).failure(.reported("Private video")) == "Private video")
        #expect(Strings(language: .en)("no-such-key") == "no-such-key")
    }
}
