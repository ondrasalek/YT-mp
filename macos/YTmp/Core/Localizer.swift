import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case cs, en
    var id: String { rawValue }
    var displayName: String { self == .cs ? "Čeština" : "English" }
}

/// The UI strings of the Tauri build (desktop/src/index.html), Czech and English. Czech is the fallback.
struct Strings: Sendable {
    let language: AppLanguage

    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        let template = Self.table[language]?[key] ?? Self.table[.cs]?[key] ?? key
        return arguments.isEmpty ? template : String(format: template, arguments: arguments)
    }

    func failure(_ failure: JobFailure) -> String {
        switch failure {
        case .toolMissing: self("errToolMissing")
        case .spawnFailed(let reason): self("errSpawn", reason)
        case .downloadFailed: self("errFailed")
        case .reported(let message): message
        }
    }

    static let table: [AppLanguage: [String: String]] = [
        .cs: [
            "settingsTitle": "Nastavení",
            "theme": "Motiv", "themeSystem": "Systém", "themeLight": "Světlý", "themeDark": "Tmavý",
            "fontsize": "Velikost písma", "fsSmall": "Malá", "fsMedium": "Střední", "fsLarge": "Velká",
            "language": "Jazyk",
            "urlPlaceholder": "Např. https://youtu.be/seJ83vfHoIU",
            "paste": "Vložit ze schránky",
            "changeFolder": "Změnit cílovou složku…",
            "convert": "Stáhnout",
            "queue": "Fronta", "clearFinished": "Vyčistit hotové",
            "emptyTitle": "Zatím nic ke stažení",
            "emptyText": "Vlož odkaz na video nebo playlist, případně ho sem přetáhni.",
            "rights": "Stahuj jen obsah, ke kterému máš práva.",
            "disclaimer": "Stahuj pouze obsah, ke kterému máš práva. Respektuj podmínky YouTube a autorská práva. Soubory se ukládají do zvolené složky na tvém počítači.",
            "terms": "Podmínky YouTube",
            "openFile": "Otevřít", "reveal": "Ve složce", "cancel": "Zrušit", "cancelling": "Ruším…", "remove": "Odebrat", "retry": "Znovu", "log": "Podrobnosti",
            "enqueuing": "Zařazuji…",
            "st_starting": "Spouštím…", "st_metadata": "Příprava", "st_downloading": "Stahuji",
            "st_processing": "Zpracování", "st_finished": "Hotovo", "st_complete": "Hotovo", "st_error": "Chyba", "st_cancelled": "Zrušeno",
            "items": "položek",
            "idle": "Připraveno", "busy": "Probíhá: %d",
            "invalidUrl": "Zadej platný odkaz (http/https).",
            "pasteFail": "Schránka neobsahuje text.",
            "noFolder": "Není zvolená cílová složka.",
            "errToolMissing": "Přibalený yt-dlp nebyl nalezen.",
            "errSpawn": "Nelze spustit yt-dlp: %@",
            "errFailed": "Stahování selhalo.",
            "chooseFolder": "Vybrat složku",
        ],
        .en: [
            "settingsTitle": "Settings",
            "theme": "Theme", "themeSystem": "System", "themeLight": "Light", "themeDark": "Dark",
            "fontsize": "Font size", "fsSmall": "Small", "fsMedium": "Medium", "fsLarge": "Large",
            "language": "Language",
            "urlPlaceholder": "e.g. https://youtu.be/seJ83vfHoIU",
            "paste": "Paste from clipboard",
            "changeFolder": "Change destination folder…",
            "convert": "Download",
            "queue": "Queue", "clearFinished": "Clear finished",
            "emptyTitle": "Nothing downloaded yet",
            "emptyText": "Paste a video or playlist link, or drop it here.",
            "rights": "Only download content you have the rights to.",
            "disclaimer": "Only download content you have the rights to. Respect the YouTube Terms and copyright. Files are saved to the chosen folder on your computer.",
            "terms": "YouTube Terms",
            "openFile": "Open", "reveal": "Show in folder", "cancel": "Cancel", "cancelling": "Cancelling…", "remove": "Remove", "retry": "Retry", "log": "Details",
            "enqueuing": "Queuing…",
            "st_starting": "Starting…", "st_metadata": "Preparing", "st_downloading": "Downloading",
            "st_processing": "Processing", "st_finished": "Done", "st_complete": "Done", "st_error": "Error", "st_cancelled": "Cancelled",
            "items": "items",
            "idle": "Ready", "busy": "Running: %d",
            "invalidUrl": "Enter a valid link (http/https).",
            "pasteFail": "The clipboard has no text.",
            "noFolder": "No destination folder chosen.",
            "errToolMissing": "The bundled yt-dlp was not found.",
            "errSpawn": "Could not start yt-dlp: %@",
            "errFailed": "The download failed.",
            "chooseFolder": "Choose Folder",
        ],
    ]
}
