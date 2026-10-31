import AppKit
import SwiftUI

/// Stops running downloads when the app quits, so no yt-dlp / ffmpeg process is left behind.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.model?.cancelAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct YTmpApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        Window("YT-mp", id: "main") {
            ContentView().environment(model)
        }
        .defaultSize(width: 760, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Download Folder…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Clear Finished") { model.clearFinished() }.keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}
