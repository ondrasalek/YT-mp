# YouTube Video Converter to MP3/MP4

Hybridní aplikace: **Rust** orchestrační jádro (fronta úloh, paralelismus, CLI)
nad **Python** workerem (`yt-dlp` + `ffmpeg`).

```
.
├── python_core/        # Media worker (stahování + postprocessing)
│   ├── downloader.py
│   └── requirements.txt
└── rust_backend/       # Orchestrace a CLI
    ├── Cargo.toml
    └── src/
        ├── main.rs       # CLI (clap): subkomandy download / serve
        ├── models.rs     # serde modely (config + progress)
        ├── converter.rs  # tokio subprocess, fronta úloh, JobObserver
        └── api.rs        # axum HTTP API + SSE stream progressu
```

## Architektura

```
            argumenty (bez shellu)             NDJSON na stdout
  Rust  ──────────────────────────►  Python  ──────────────────────►  Rust
 (tokio::process)                  (yt-dlp/ffmpeg)               (serde_json → progress bar)
```

Komunikace probíhá přes proud JSON objektů (jeden na řádek) na stdout. stderr
nese diagnostiku. Argumenty se předávají jako pole → **odolnost vůči command
injection**.

## Předpoklady

- Python 3.10+
- `ffmpeg` v PATH (`brew install ffmpeg` / `apt install ffmpeg`)
- Rust toolchain (`cargo`)

## Instalace Python závislostí (venv)

Moderní distribuce (Homebrew, Debian) mají systémový Python „externally-managed"
(PEP 668), takže `pip install` do něj selže. Použij virtuální prostředí:

```bash
python3 -m venv .venv
./.venv/bin/pip install -r python_core/requirements.txt
```

Rust aplikaci pak nasměruj na tento interpret přes `--python ./.venv/bin/python`
(nebo `--python "$(pwd)/.venv/bin/python"` při běhu z jiného adresáře).

## Sestavení

```bash
cd rust_backend
cargo build --release
```

## Spuštění přes Docker

Nejjednodušší cesta — vše (Rust binárka, Python + yt-dlp, ffmpeg) je v jednom
obrazu, není potřeba nic instalovat lokálně:

```bash
docker compose up --build
# -> Web UI na http://127.0.0.1:8080/
```

Soubory se streamují do prohlížeče uživatele; na serveru leží jen dočasně
v `./data` (per-job, mazáno po 30 min). Volume `./data:/app/data` v compose je
volitelný — hodí se pro přežití restartu nebo inspekci, jinak ho lze smazat.

## Použití — CLI (`download`)

```bash
# Jedno video do MP3 (320 kbps)
./target/release/ytmp download "https://youtu.be/VIDEO_ID" \
  --format mp3 --output ./downloads --python ./.venv/bin/python

# Více URL / playlist paralelně (2 souběžné úlohy)
./target/release/ytmp download URL1 URL2 -f mp4 -o ./downloads -j 2 --python ./.venv/bin/python
```

| Přepínač | Význam | Výchozí |
|----------|--------|---------|
| `URL...` | jedno či více YouTube URL (i playlisty) | — |
| `-f, --format` | `mp3` \| `mp4` | `mp4` |
| `-o, --output` | výstupní adresář | `./downloads` |
| `-j, --concurrency` | max. souběžných úloh | `2` |
| `--python` | cesta k interpretu | autodetekce |
| `--script` | cesta k `downloader.py` | autodetekce |

## Použití — Web UI + HTTP API (`serve`)

```bash
./target/release/ytmp serve --host 127.0.0.1 --port 8080 --python ./.venv/bin/python
```

Otevři **http://127.0.0.1:8080/** — webové rozhraní (vložené přímo v binárce)
s formulářem a živým progress barem přes SSE.

**Model webové aplikace:** server stáhne médium do dočasného **per-job**
adresáře (`--data-dir`, výchozí `./data`) a po dokončení ho **streamuje do
prohlížeče uživatele** jako download. Uživatel je vzdálený — nic se na server
neukládá natrvalo ani se nevybírá cílová složka. Dokončené úlohy (soubor i
záznam) maže background sweeper po 30 minutách.

### Dev: obsazený port (`--force`)

Pokud při vývoji zůstane na portu viset starý server, příště to server pozná:

```bash
# Bez --force: srozumitelná chyba s PID, který port drží
./target/release/ytmp serve --port 8080
# ✖ Port 8080 je již obsazen. Starý ytmp server (PID [12345]) stále běží.
#   Spusť s --force pro automatické ukončení, nebo: kill 12345

# S --force: starý ytmp server se bezpečně ukončí a port se uvolní
./target/release/ytmp serve --port 8080 --force
```

`--force` ukončí **pouze** proces, jehož příkazová řádka obsahuje `ytmp`
(ověřeno přes `ps`/`lsof`) — cizí procesy na portu nikdy nezabíjí.

### Endpointy

| Endpoint | Popis |
|----------|-------|
| `GET /` | webové UI (HTML + JS, konzumuje SSE) |
| `GET /health` | liveness check |
| `POST /jobs` | zařadí úlohu, vrátí `job_id`, `events_url`, `download_url` |
| `GET /jobs/{id}/events` | SSE proud JSON událostí (s replayem historie) |
| `GET /jobs/{id}/download` | stáhne hotový soubor (příloha, správný `Content-Type`) |

```bash
# 1) zařazení úlohy
curl -X POST http://127.0.0.1:8080/jobs \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://youtu.be/VIDEO_ID","format":"mp3"}'
# -> {"job_id":"<uuid>","events_url":"/jobs/<uuid>/events","download_url":"/jobs/<uuid>/download"}

# 2) sledování progressu (Server-Sent Events)
curl -N http://127.0.0.1:8080/jobs/<uuid>/events
# data: {"status":"downloading","progress":45.2,"speed":"2.3MiB/s","eta":"00:15"}
# data: {"status":"finished",...}

# 3) stažení hotového souboru do prohlížeče/klienta
curl -OJ http://127.0.0.1:8080/jobs/<uuid>/download
```

Jádro je sdílené: stejný proud událostí napájí přes `JobObserver` buď terminálový
progress bar (`download`), nebo SSE stream (`serve`).

Worker lze spustit i samostatně (užitečné pro ladění):

```bash
python3 python_core/downloader.py "URL" --format mp3 --output ./downloads
```

## Návratové kódy

| Kód | Význam |
|-----|--------|
| 0 | vše OK |
| 1 | aspoň jedna úloha selhala / obecná chyba |
| 2 | chybějící závislost (yt-dlp, ffmpeg, Python, skript) |
