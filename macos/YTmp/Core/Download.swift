import Foundation

// Port of desktop/src-tauri/src/downloader.rs: the bundled yt-dlp is made to print machine-readable lines
// (`--print` / `--progress-template`), each tagged so it can be told apart from yt-dlp's own output:
//
//   stdout  @@J@@{json}   metadata (before_dl) and finished (after_move)
//   stdout  @@D@@{json}   download progress (percent / speed / eta strings)
//   stderr  @@P@@name     postprocessor started
//   stderr  ERROR: …      failures

enum DownloadFormat: String, Codable, CaseIterable, Sendable {
    case mp3, mp4
}

struct DownloadRequest: Equatable, Sendable {
    var url: String
    var format: DownloadFormat
    var outputDir: String
    /// Browser name for `--cookies-from-browser` (Safari, chrome, …); nil for none.
    var browser: String?
}

enum JobStatus: String, Codable, Sendable {
    case starting, metadata, downloading, processing, finished, complete, error, cancelled
}

/// Why a job failed; the UI turns these into localized text.
enum JobFailure: Equatable, Codable, Sendable {
    case toolMissing
    case spawnFailed(String)
    case downloadFailed
    /// yt-dlp's own `ERROR:` message, verbatim.
    case reported(String)
}

enum JobEvent: Equatable, Sendable {
    case starting
    case metadata(title: String?, filename: String?)
    case downloading(progress: Double, speed: String, eta: String)
    case processing(String)
    case finished(filepath: String)
    case complete
    case failed(JobFailure)
    case cancelled
}

enum OutputTags {
    static let json = "@@J@@"
    static let download = "@@D@@"
    static let postprocess = "@@P@@"
}

enum YTDLPParser {
    /// "  50.7%" -> 50.7
    static func parsePercent(_ text: String) -> Double? {
        Double(text.filter { $0.isASCII && ($0.isNumber || $0 == ".") })
    }

    /// One stdout line -> an event (nil for anything untagged or malformed).
    static func parseStdout(_ line: String) -> JobEvent? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if let rest = text.stripPrefix(OutputTags.json) {
            guard let object = jsonObject(rest), let status = object["status"] as? String else { return nil }
            switch status {
            case "metadata":
                return .metadata(title: object["title"] as? String, filename: object["filename"] as? String)
            case "finished":
                guard let path = object["filepath"] as? String, !path.isEmpty else { return nil }
                return .finished(filepath: path)
            default:
                return nil
            }
        }
        if let rest = text.stripPrefix(OutputTags.download) {
            guard let object = jsonObject(rest) else { return nil }
            let progress = (object["pct"] as? String).flatMap(parsePercent) ?? 0
            let speed = (object["speed"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let eta = (object["eta"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return .downloading(progress: progress, speed: speed, eta: eta)
        }
        return nil
    }

    enum StderrLine: Equatable {
        case processing(String)
        case error(String)
    }

    /// One stderr line -> postprocessing progress or an `ERROR:` message (nil for the rest).
    static func parseStderr(_ line: String) -> StderrLine? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if let name = text.stripPrefix(OutputTags.postprocess) {
            return name.isEmpty ? nil : .processing(name)
        }
        if text.contains("ERROR:") { return .error(text) }
        return nil
    }

    /// The last `ERROR:` line, without its prefix.
    static func failureMessage(from errors: String) -> String? {
        let last = errors.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).last
        guard let last else { return nil }
        var message = String(last).trimmingCharacters(in: .whitespaces)
        if let range = message.range(of: "ERROR:") { message = String(message[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
        return message.isEmpty ? nil : message
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum YTDLPArguments {
    /// The full argument list; passed as an array, so nothing is ever interpreted by a shell.
    static func build(for request: DownloadRequest, ffmpeg: URL?) -> [String] {
        let outputTemplate = request.outputDir.trimmingTrailingSlashes() + "/%(title)s.%(ext)s"
        var args = [
            request.url,
            "-o", outputTemplate,
            "--no-color", "--newline", "--no-warnings", "--progress",
            "--progress-template",
            "download:\(OutputTags.download){\"pct\":\"%(progress._percent_str)s\",\"speed\":\"%(progress._speed_str)s\",\"eta\":\"%(progress._eta_str)s\"}",
            "--progress-template", "postprocess:\(OutputTags.postprocess)%(progress.postprocessor)s",
            "--print",
            "before_dl:\(OutputTags.json){\"status\":\"metadata\",\"title\":%(title)j,\"duration\":%(duration)j,\"filename\":%(filename)j}",
            "--print", "after_move:\(OutputTags.json){\"status\":\"finished\",\"filepath\":%(filepath)j}",
        ]
        if let ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
        switch request.format {
        case .mp3:
            args += ["-x", "--audio-format", "mp3", "--audio-quality", "320K"]
        case .mp4:
            args += ["-f", "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b", "--merge-output-format", "mp4"]
        }
        if let browser = request.browser?.trimmingCharacters(in: .whitespaces), !browser.isEmpty {
            args += ["--cookies-from-browser", browser]
        }
        return args
    }
}

enum URLInput {
    /// Accepts pasted text: adds https:// to bare YouTube hosts and returns nil unless the result is an http(s) URL.
    static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let hasScheme = text.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
        if !hasScheme,
            text.range(of: "^(www\\.|youtu\\.be|youtube\\.com|m\\.youtube\\.com|music\\.youtube\\.com)", options: [.regularExpression, .caseInsensitive]) != nil
        {
            text = "https://" + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host(), !host.isEmpty
        else { return nil }
        return url.absoluteString
    }
}

enum Partials {
    /// Removes what a cancelled download leaves behind: `<name>*.part`, `*.ytdl`, `*.temp` (including partial
    /// streams such as `<name>.f137.mp4.part`).
    static func remove(forFilename filename: String) {
        let path = URL(fileURLWithPath: filename)
        let directory = path.deletingLastPathComponent()
        let stem = path.deletingPathExtension().lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(stem) {
            let partial = name.hasSuffix(".part") || name.hasSuffix(".ytdl") || name.hasSuffix(".temp")
                || name.contains(".temp.") || name.contains(".part-Frag")
            if partial { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
    }
}

extension String {
    fileprivate func stripPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    fileprivate func trimmingTrailingSlashes() -> String {
        var text = self
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
