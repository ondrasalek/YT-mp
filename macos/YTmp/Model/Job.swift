import Foundation
import Observation

enum JobState: String, Codable, Sendable {
    case running, done, error, cancelled
}

/// One entry of the queue. Events from the download session are folded in with `apply`.
@MainActor
@Observable
final class Job: Identifiable {
    let id: String
    let url: String
    let format: DownloadFormat

    var title = ""
    var state: JobState = .running
    var status: JobStatus = .starting
    var progress: Double = 0
    var detail = ""
    var failure: JobFailure?
    var log = ""
    /// Files finished so far (a playlist produces many).
    var count = 0
    var filepath: String?
    var cancelRequested = false
    var showLog = false

    @ObservationIgnored var session: DownloadSession?

    init(id: String = UUID().uuidString, url: String, format: DownloadFormat) {
        self.id = id
        self.url = url
        self.format = format
    }

    init(record: JobRecord) {
        id = record.id
        url = record.url
        format = record.format
        title = record.title
        state = record.state
        status = record.state == .done ? .finished : record.state == .error ? .error : .cancelled
        progress = 100
        failure = record.failure
        count = record.count
        filepath = record.filepath
    }

    var record: JobRecord {
        JobRecord(id: id, url: url, format: format, title: title, state: state, filepath: filepath, failure: failure, count: count)
    }

    /// Back to the start, for a retry.
    func reset() {
        state = .running
        status = .starting
        progress = 0
        detail = ""
        failure = nil
        log = ""
        count = 0
        cancelRequested = false
    }

    func apply(_ event: JobEvent) {
        log += "\(event)\n"
        switch event {
        case .starting:
            status = .starting
        case .metadata(let title, _):
            status = .metadata
            if let title, !title.isEmpty { self.title = title }
            progress = 0
            detail = ""
        case .downloading(let value, let speed, let eta):
            status = .downloading
            progress = value
            detail = [String(format: "%.0f%%", value), speed, eta.isEmpty ? "" : "ETA \(eta)"].filter { !$0.isEmpty }.joined(separator: " · ")
        case .processing(let name):
            status = .processing
            progress = 100
            detail = name
        case .finished(let path):
            status = .finished
            count += 1
            filepath = path
            progress = 100
        case .complete:
            status = .complete
            state = .done
            progress = 100
            detail = ""
        case .failed(let failure):
            status = .error
            state = .error
            self.failure = failure
        case .cancelled:
            status = .cancelled
            state = .cancelled
        }
    }
}

/// What survives a restart (finished jobs only).
struct JobRecord: Codable, Equatable, Sendable {
    var id: String
    var url: String
    var format: DownloadFormat
    var title: String
    var state: JobState
    var filepath: String?
    var failure: JobFailure?
    var count: Int
}
