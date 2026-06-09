# Build pro Windows (.exe / .msi)

Aplikace je cross-platform (Tauri). Na Windows PC se z tohoto repa vyrobí
nativní instalátor: **NSIS `.exe`** a/nebo **`.msi`**. Build musí proběhnout
**na Windows** (Tauri nedělá cross-compile macOS → Windows).

## 1. Předpoklady (jednorázově)

1. **Rust** + MSVC toolchain — https://rustup.rs
   (výchozí `stable-x86_64-pc-windows-msvc` je správně).
2. **Microsoft C++ Build Tools** — Visual Studio Build Tools s komponentou
   „Desktop development with C++“ (kvůli linkeru).
   https://visualstudio.microsoft.com/visual-cpp-build-tools/
3. **WebView2 Runtime** — na Windows 11 je předinstalovaný; instalátor si ho
   jinak sám stáhne (Tauri `downloadBootstrapper`).
4. **Tauri CLI**:
   ```powershell
   cargo install tauri-cli --version "^2.0"
   ```
   (Node.js není potřeba — frontend je statické HTML bez build stepu.)

## 2. Příprava binárek

V adresáři `desktop/` stáhni Windows verze `yt-dlp.exe` + `ffmpeg.exe`:

```powershell
cd desktop
powershell -ExecutionPolicy Bypass -File scripts\fetch-binaries.ps1
```

Skript je uloží jako:
```
src-tauri\binaries\yt-dlp-x86_64-pc-windows-msvc.exe
src-tauri\binaries\ffmpeg-x86_64-pc-windows-msvc.exe
```
(Tyto názvy vyžaduje Tauri `externalBin` — nepřejmenovávat.)

## 3. Build

```powershell
cd desktop
cargo tauri build
```

Výstup:
```
src-tauri\target\release\bundle\nsis\YT-mp_0.4.0_x64-setup.exe   # instalátor (NSIS)
src-tauri\target\release\bundle\msi\YT-mp_0.4.0_x64_en-US.msi    # instalátor (MSI)
```

## 4. Podpis (volitelné)

Build je **nepodepsaný** → Windows SmartScreen napoprvé zobrazí
„Windows protected your PC“ → *More info* → *Run anyway*. Pro čistou
instalaci bez varování je potřeba **code-signing certifikát** (OV/EV) a
podepsat `.exe`/`.msi` (např. `signtool`), případně nastavit podpis v
`tauri.conf.json` → `bundle.windows.certificateThumbprint`.

## Poznámky

- Build je **x64**. Pro ARM Windows by byl potřeba `aarch64-pc-windows-msvc`
  toolchain + odpovídající binárky.
- `cargo tauri dev` funguje na Windows stejně jako na macOS (hot-reload UI).
- Nativní menu „Settings…“ je macOS specialita; na Windows otevři nastavení
  ozubeným kolečkem (⚙) v okně.
