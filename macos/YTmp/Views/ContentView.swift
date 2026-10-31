import SwiftUI

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The "font size" preference as a factor applied by `uiFont`.
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

private struct UIFontModifier: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let monospaced: Bool

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: monospaced ? .monospaced : .default))
    }
}

extension View {
    func uiFont(_ size: CGFloat, weight: Font.Weight = .regular, monospaced: Bool = false) -> some View {
        modifier(UIFontModifier(size: size, weight: weight, monospaced: monospaced))
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var urlFocused: Bool
    @State private var dropTargeted = false

    var body: some View {
        let t = app.strings
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    composer(t)
                    queue(t)
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            statusBar(t)
        }
        .frame(minWidth: 560, minHeight: 520)
        .dropDestination(for: String.self) { texts, _ in
            app.handleDrop(texts)
            return !texts.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay(alignment: .bottom) { toast }
        .environment(\.uiScale, app.fontSize.scale)
        .preferredColorScheme(app.theme.colorScheme)
        .onChange(of: app.focusURLRequest) { urlFocused = true }
        .onAppear { urlFocused = true }
    }

    // MARK: Composer

    private func composer(_ t: Strings) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("", text: Bindable(app).urlText, prompt: Text(t("urlPlaceholder")))
                    .textFieldStyle(.plain)
                    .uiFont(14.5)
                    .focused($urlFocused)
                    .onSubmit { app.submit() }
                    .padding(.vertical, 10)
                Button { app.pasteFromClipboard() } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help(t("paste"))
            }
            .padding(.horizontal, 12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(urlFocused ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: urlFocused ? 2 : 1))

            HStack(spacing: 10) {
                Picker("Format", selection: Bindable(app).format) {
                    Label("MP4", systemImage: "film").tag(DownloadFormat.mp4)
                    Label("MP3", systemImage: "music.note").tag(DownloadFormat.mp3)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()

                Button { app.chooseFolder() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text(app.outputDir).lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .uiFont(12.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(t("changeFolder"))

                Button { app.submit() } label: { Label(t("convert"), systemImage: "arrow.down.to.line") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(dropTargeted ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: dropTargeted ? 2 : 1))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }

    // MARK: Queue

    private func queue(_ t: Strings) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(t("queue").uppercased()).uiFont(12, weight: .semibold).tracking(0.7).foregroundStyle(.secondary)
                Spacer()
                if app.hasFinished {
                    Button(t("clearFinished")) { app.clearFinished() }.buttonStyle(.link).uiFont(12)
                }
            }
            .padding(.horizontal, 2)

            if app.jobs.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line").font(.title2).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 8)
                    Text(t("emptyTitle")).uiFont(14.5, weight: .semibold)
                    Text(t("emptyText")).uiFont(12.5).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 38).padding(.horizontal, 20)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            } else {
                ForEach(app.jobs) { job in
                    JobRow(job: job).transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy, value: app.jobs.map(\.id))
    }

    private func statusBar(_ t: Strings) -> some View {
        HStack {
            Circle().fill(app.runningCount > 0 ? Color.accentColor : Color.secondary).frame(width: 7, height: 7)
            Text(app.runningCount > 0 ? t("busy", app.runningCount) : t("idle"))
            Spacer()
            Text(t("rights"))
        }
        .uiFont(11.5)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var toast: some View {
        if let message = app.toast {
            Text(message)
                .uiFont(12.5, weight: .medium)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator))
                .shadow(radius: 8, y: 3)
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
