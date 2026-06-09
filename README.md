# YT-mp — YouTube → MP3/MP4 (desktop)

Nativní **desktopová** aplikace (Tauri + Rust) pro stahování a převod YouTube
videí do **MP3 (320k)** nebo **MP4**. Běží lokálně na počítači uživatele,
takže stahuje **z jeho IP** — žádný YouTube „Sign in to confirm you're not a
bot" (ten řeší jen datacentrové IP) a žádný server k provozování.

Přibalené `yt-dlp` a `ffmpeg` jako sidecar binárky → aplikace je
**samostatná**, nevyžaduje Python, Homebrew ani nic dalšího.

```
desktop/
├── src/
│   └── index.html          # frontend (UI, i18n, motivy) — bez build stepu
├── scripts/
│   └── fetch-binaries.sh   # stáhne yt-dlp + ffmpeg do src-tauri/binaries/
└── src-tauri/
    ├── tauri.conf.json     # konfigurace okna, bundle, externalBin (sidecary)
    ├── build.rs            # zpřístupní cílový triple za běhu
    ├── capabilities/       # oprávnění (dialog, opener)
    ├── icons/              # ikony aplikace
    ├── binaries/           # yt-dlp/ffmpeg (gitignored, viz fetch-binaries.sh)
    └── src/
        ├── main.rs         # Tauri builder + command start_job
        └── downloader.rs   # orchestrace yt-dlp (tagované JSON přes templates)
```

## Jak to funguje

```
              invoke("start_job")                  yt-dlp (sidecar)
  Frontend ──────────────────────►  Rust  ──────────────────────────►  YouTube
  (webview)                      (tokio::process)   --print / --progress-template
       ▲                                                    │  (tagovaný JSON)
       └──────────  event "ytmp:progress"  ◄────────────────┘
```

`yt-dlp` je donucen vypisovat rovnou JSON (`--print` + `--progress-template`),
který Rust přečte, převede na jednotný kontrakt a přepošle do frontendu jako
Tauri událost. Argumenty se předávají jako pole → odolnost vůči command
injection. ffmpeg se předává přes `--ffmpeg-location` (přibalený sidecar).

## Vývoj

Předpoklady: [Rust](https://rustup.rs), Node (jen pro Tauri CLI),
`cargo install tauri-cli --version "^2.0"`.

```bash
cd desktop
./scripts/fetch-binaries.sh        # jednorázově stáhne yt-dlp + ffmpeg
cargo tauri dev                    # spustí aplikaci v dev režimu (hot-reload UI)
```

## Build (.dmg)

```bash
cd desktop
cargo tauri build                  # -> src-tauri/target/release/bundle/dmg/YT-mp_*.dmg
```

Aplikace je **arm64** (Apple Silicon). Pro Intel Macy je potřeba build s
`TARGET=x86_64-apple-darwin` (a stáhnout odpovídající binárky).

### Podpis

Build je **ad-hoc podepsaný** (Tauri to dělá automaticky) — na vlastním Macu
běží bez problémů. Při distribuci ostatním (stažení .dmg) macOS Gatekeeper
zobrazí varování → pravým tlačítkem → *Otevřít* napoprvé. Pro čistou instalaci
bez varování je potřeba Apple Developer ID a notarizace.

## Funkce

- MP3 (audio 320k) / MP4 (video), video i playlist
- Výběr cílové složky (pamatuje si poslední), tlačítka *Otevřít soubor* /
  *Ukázat ve složce*
- Živý progress (rychlost, ETA, %) přes Tauri události
- **Nastavení**: motiv (světlý/tmavý/systém), velikost písma, jazyk (cs/en)
- Vše se ukládá lokálně (localStorage)

## Poznámka k použití

Stahuj pouze obsah, ke kterému máš práva. Respektuj
[podmínky YouTube](https://www.youtube.com/t/terms) a autorská práva.
