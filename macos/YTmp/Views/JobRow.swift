import SwiftUI

struct JobRow: View {
    @Environment(AppModel.self) private var app
    let job: Job

    private var tint: Color {
        switch job.state {
        case .running: .accentColor
        case .done: .green
        case .error: .red
        case .cancelled: .secondary
        }
    }

    private var badgeSymbol: String {
        switch job.state {
        case .done: "checkmark"
        case .error: "exclamationmark.circle"
        case .cancelled: "minus.circle"
        case .running: job.format == .mp3 ? "music.note" : "film"
        }
    }

    var body: some View {
        let t = app.strings
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: badgeSymbol).font(.system(size: 15, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 36, height: 36).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title.isEmpty ? job.url : job.title).uiFont(13.5, weight: .semibold).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                    meta(t)
                }
                Spacer(minLength: 8)
                actions(t)
            }

            if job.state == .running {
                if job.progress > 0 {
                    ProgressView(value: min(job.progress, 100), total: 100).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if job.state == .error, let failure = job.failure {
                Text(t.failure(failure)).uiFont(12.5).foregroundStyle(.red).textSelection(.enabled).padding(.leading, 48)
            }
            if job.showLog {
                ScrollView {
                    Text(job.log).uiFont(11.5, monospaced: true).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110).padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09)))
    }

    private func meta(_ t: Strings) -> some View {
        let state = job.state == .running ? t("st_\(job.status.rawValue)") : t("st_\(job.state == .done ? "finished" : job.state.rawValue)")
        var parts = [state, job.format.rawValue.uppercased()]
        if job.count > 1 { parts.append("\(job.count) \(t("items"))") }
        if job.state == .running, !job.detail.isEmpty { parts.append(job.detail) }
        return HStack(spacing: 6) {
            Text(parts[0]).fontWeight(.semibold).foregroundStyle(job.state == .done ? Color.green : job.state == .error ? Color.red : Color.secondary)
            Text(parts.dropFirst().joined(separator: " · ")).lineLimit(1)
        }
        .uiFont(12.5)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func actions(_ t: Strings) -> some View {
        HStack(spacing: 6) {
            if job.state == .running {
                Button { app.cancel(job) } label: { Label(t(job.cancelRequested ? "cancelling" : "cancel"), systemImage: "xmark") }
                    .disabled(job.cancelRequested)
                Button { job.showLog.toggle() } label: { Image(systemName: "terminal") }
                    .buttonStyle(.borderless).help(t("log"))
            } else {
                if job.state == .done, job.filepath != nil {
                    Button { app.open(job) } label: { Label(t("openFile"), systemImage: "play.fill") }
                    Button { app.reveal(job) } label: { Label(t("reveal"), systemImage: "folder") }
                }
                if job.state == .error || job.state == .cancelled {
                    Button { app.retry(job) } label: { Label(t("retry"), systemImage: "arrow.counterclockwise") }
                }
                Button { app.remove(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help(t("remove"))
            }
        }
        .controlSize(.small)
    }
}
