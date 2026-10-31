import AppKit
import Observation
import SwiftUI

enum ThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum FontSizePreference: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large
    var id: String { rawValue }
    var scale: CGFloat {
        switch self {
        case .small: 0.92
        case .medium: 1
        case .large: 1.14
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private enum Key {
        static let theme = "ytmp.theme"
        static let fontSize = "ytmp.fontsize"
        static let language = "ytmp.lang"
        static let format = "ytmp.format"
        static let outputDir = "ytmp.outDir"
        static let history = "ytmp.history"
    }

    /// Newest first.
    private(set) var jobs: [Job] = []
    var urlText = ""
    var toast: String?
    var focusURLRequest = 0

    var format: DownloadFormat { didSet { defaults.set(format.rawValue, forKey: Key.format) } }
    var outputDir: String { didSet { defaults.set(outputDir, forKey: Key.outputDir) } }
    var theme: ThemePreference { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    var fontSize: FontSizePreference { didSet { defaults.set(fontSize.rawValue, forKey: Key.fontSize) } }
    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored var tools: ToolPaths

    static let historyLimit = 50

    init(defaults: UserDefaults = .standard, tools: ToolPaths = .locate(), downloadsDirectory: String = NSHomeDirectory() + "/Downloads") {
        self.defaults = defaults
        self.tools = tools
        format = defaults.string(forKey: Key.format).flatMap(DownloadFormat.init) ?? .mp4
        outputDir = defaults.string(forKey: Key.outputDir) ?? downloadsDirectory
        theme = defaults.string(forKey: Key.theme).flatMap(ThemePreference.init) ?? .system
        fontSize = defaults.string(forKey: Key.fontSize).flatMap(FontSizePreference.init) ?? .medium
        language = defaults.string(forKey: Key.language).flatMap(AppLanguage.init) ?? .cs
        loadHistory()
    }

    var strings: Strings { Strings(language: language) }
    var runningCount: Int { jobs.filter { $0.state == .running }.count }
    var hasFinished: Bool { jobs.contains { $0.state != .running } }

    // MARK: Queue

    /// Validates the URL field and starts a download for it.
    func submit() {
        guard let url = URLInput.normalize(urlText) else {
            show(strings("invalidUrl"))
            focusURLRequest += 1
            return
        }
        guard !outputDir.isEmpty else {
            show(strings("noFolder"))
            return
        }
        let job = Job(url: url, format: format)
        jobs.insert(job, at: 0)
        urlText = ""
        start(job)
    }

    func start(_ job: Job) {
        job.reset()
        job.detail = strings("enqueuing")
        let session = DownloadSession(
            request: DownloadRequest(url: job.url, format: job.format, outputDir: outputDir, browser: nil), tools: tools)
        job.session = session
        Task { [weak self, job] in
            for await event in session.events {
                job.apply(event)
                if job.state != .running { self?.saveHistory() }
            }
            job.session = nil
        }
    }

    func cancel(_ job: Job) {
        guard job.state == .running, !job.cancelRequested else { return }
        job.cancelRequested = true
        job.session?.cancel()
    }

    func retry(_ job: Job) { start(job) }

    func remove(_ job: Job) {
        jobs.removeAll { $0 === job }
        saveHistory()
    }

    func clearFinished() {
        jobs.removeAll { $0.state != .running }
        saveHistory()
    }

    /// Kills every running download (on quit).
    func cancelAll() {
        for job in jobs where job.state == .running { job.session?.cancel() }
    }

    // MARK: Input

    func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            focusURLRequest += 1
        } else {
            show(strings("pasteFail"))
        }
    }

    /// A link (or text containing one) dropped on the window fills the URL field.
    func handleDrop(_ texts: [String]) {
        for text in texts {
            for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                if let url = URLInput.normalize(String(line)) {
                    urlText = url
                    focusURLRequest += 1
                    return
                }
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = strings("chooseFolder")
        panel.directoryURL = URL(fileURLWithPath: outputDir)
        if panel.runModal() == .OK, let url = panel.url { outputDir = url.path }
    }

    func open(_ job: Job) {
        guard let path = job.filepath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func reveal(_ job: Job) {
        guard let path = job.filepath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: History

    private func saveHistory() {
        let records = jobs.filter { $0.state != .running }.prefix(Self.historyLimit).map(\.record)
        if let data = try? JSONEncoder().encode(Array(records)) { defaults.set(data, forKey: Key.history) }
    }

    private func loadHistory() {
        guard let data = defaults.data(forKey: Key.history),
            let records = try? JSONDecoder().decode([JobRecord].self, from: data)
        else { return }
        jobs = records.map(Job.init(record:))
    }
}
