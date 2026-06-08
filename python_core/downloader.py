#!/usr/bin/env python3
"""YouTube downloader worker.

Tento skript je navržen jako "hloupý" worker spouštěný Rust jádrem jako
subproces. Komunikace probíhá výhradně přes streamy:

  * STDOUT  -> proud validních JSON objektů (jeden na řádek = NDJSON),
               které popisují průběh a finální stav úlohy.
  * STDERR  -> lidsky čitelné logy / traceby (Rust je může logovat, ale
               neparsuje je jako data).

Kontrakt JSON zpráv na stdout:

  {"status": "starting",   "url": "..."}
  {"status": "metadata",   "title": "...", "duration": 215, "uploader": "..."}
  {"status": "downloading","progress": 45.2, "speed": "2.3MiB/s", "eta": "00:15"}
  {"status": "processing", "postprocessor": "ExtractAudio"}
  {"status": "finished",   "filepath": "/abs/path/output.mp3"}
  {"status": "error",      "error": "Lidsky čitelný popis chyby"}

Návratové kódy:
  0 - úspěch
  1 - obecná chyba (síť, neplatné URL, selhání ffmpeg, ...)
  2 - chybějící systémová závislost (yt-dlp nebo ffmpeg)
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path
from typing import Any, Final

# yt-dlp importujeme "měkce", abychom mohli vrátit srozumitelnou chybu
# (kód 2) místo nečitelného ImportError tracebacku, pokud knihovna chybí.
try:
    from yt_dlp import YoutubeDL
    from yt_dlp.utils import DownloadError
except ImportError:  # pragma: no cover - závisí na prostředí
    YoutubeDL = None  # type: ignore[assignment, misc]
    DownloadError = Exception  # type: ignore[assignment, misc]


AUDIO_BITRATE: Final[str] = "320"  # kbps pro MP3


def emit(payload: dict[str, Any]) -> None:
    """Vypíše jeden JSON objekt na stdout a okamžitě flushne.

    Flush je klíčový: Rust strana čte stdout řádek po řádku v reálném čase,
    takže nesmíme nechat data uvíznout v bufferu.
    """
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log_stderr(message: str) -> None:
    """Diagnostická zpráva na stderr (nikdy se neparsuje jako data)."""
    sys.stderr.write(message + "\n")
    sys.stderr.flush()


def _clean_ansi(value: str | None) -> str:
    """yt-dlp do progress polí občas vkládá ANSI escape sekvence.

    Pro strojové zpracování je odstraníme, ať Rust dostane čistý string.
    """
    if not value:
        return ""
    out: list[str] = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch == "\x1b":
            # přeskoč escape sekvenci až po písmeno (typicky 'm')
            i += 1
            while i < len(value) and value[i] not in "mK":
                i += 1
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out).strip()


def make_progress_hook() -> Any:
    """Vytvoří progress hook, který mapuje yt-dlp slovník na náš JSON kontrakt."""

    def hook(d: dict[str, Any]) -> None:
        status = d.get("status")

        if status == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            downloaded = d.get("downloaded_bytes") or 0
            progress = (downloaded / total * 100.0) if total else 0.0

            emit(
                {
                    "status": "downloading",
                    "progress": round(progress, 1),
                    "speed": _clean_ansi(d.get("_speed_str")) or "N/A",
                    "eta": _clean_ansi(d.get("_eta_str")) or "N/A",
                    "downloaded_bytes": downloaded,
                    "total_bytes": total,
                }
            )

        elif status == "finished":
            # Stažení proběhlo; následně může běžet postprocessing (ffmpeg).
            emit({"status": "processing", "postprocessor": "download_complete"})

    return hook


def postprocessor_hook(d: dict[str, Any]) -> None:
    """Signalizuje běh postprocessorů (extrakce audia, remux)."""
    if d.get("status") == "started":
        emit(
            {
                "status": "processing",
                "postprocessor": d.get("postprocessor", "unknown"),
            }
        )


def build_options(
    media_format: str,
    output_dir: Path,
    cookies: str | None = None,
) -> dict[str, Any]:
    """Sestaví konfiguraci yt-dlp podle požadovaného formátu.

    * mp3 -> stáhne nejlepší audio a přes FFmpegExtractAudio převede na MP3 320k.
    * mp4 -> stáhne nejlepší video+audio a zajistí výstupní kontejner MP4.
    """
    outtmpl = str(output_dir / "%(title)s.%(ext)s")

    common: dict[str, Any] = {
        "outtmpl": outtmpl,
        "noprogress": True,          # vlastní progress řešíme hookem
        "quiet": True,               # potlač defaultní stdout výpisy yt-dlp
        "no_warnings": True,
        "noplaylist": False,         # playlisty jsou povolené dle zadání
        "progress_hooks": [make_progress_hook()],
        "postprocessor_hooks": [postprocessor_hook],
        "ignoreerrors": False,
    }

    if cookies:
        # Cookies soubor pomáhá obejít "Sign in to confirm you're not a bot".
        common["cookiefile"] = cookies

    if media_format == "mp3":
        common.update(
            {
                "format": "bestaudio/best",
                "postprocessors": [
                    {
                        "key": "FFmpegExtractAudio",
                        "preferredcodec": "mp3",
                        "preferredquality": AUDIO_BITRATE,
                    }
                ],
            }
        )
    else:  # mp4
        common.update(
            {
                "format": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                "merge_output_format": "mp4",
                "postprocessors": [
                    {
                        "key": "FFmpegVideoRemuxer",
                        "preferedformat": "mp4",
                    }
                ],
            }
        )

    return common


def resolve_final_path(info: dict[str, Any], media_format: str) -> str:
    """Pokusí se zjistit finální cestu k souboru po postprocessingu."""
    requested = info.get("requested_downloads")
    if requested:
        filepath = requested[0].get("filepath")
        if filepath:
            return filepath

    # Fallback: odvození z původní šablony s upravenou příponou.
    base = info.get("_filename") or info.get("filename") or ""
    if base:
        return str(Path(base).with_suffix(f".{media_format}"))
    return ""


def check_dependencies() -> None:
    """Ověří přítomnost yt-dlp (import) a ffmpeg (PATH). Vyhodí SystemExit(2)."""
    if YoutubeDL is None:
        emit(
            {
                "status": "error",
                "error": "Knihovna 'yt-dlp' není nainstalována. "
                "Spusťte: pip install -r requirements.txt",
            }
        )
        raise SystemExit(2)

    if shutil.which("ffmpeg") is None:
        emit(
            {
                "status": "error",
                "error": "Nástroj 'ffmpeg' nebyl nalezen v PATH. "
                "Nainstalujte ffmpeg (např. 'brew install ffmpeg').",
            }
        )
        raise SystemExit(2)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stáhne YouTube video jako MP3 nebo MP4 a streamuje JSON progress.",
    )
    parser.add_argument("url", help="YouTube URL (video nebo playlist).")
    parser.add_argument(
        "--format",
        "-f",
        choices=("mp3", "mp4"),
        required=True,
        help="Cílový formát: 'mp3' (audio 320k) nebo 'mp4' (video).",
    )
    parser.add_argument(
        "--output",
        "-o",
        required=True,
        help="Adresář pro uložení výstupu.",
    )
    parser.add_argument(
        "--max-duration",
        type=int,
        default=0,
        help="Maximální délka videa v sekundách (0 = bez limitu).",
    )
    parser.add_argument(
        "--cookies",
        default=None,
        help="Cesta k cookies souboru pro yt-dlp (obejití bot-checku).",
    )
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    check_dependencies()

    output_dir = Path(args.output).expanduser().resolve()
    try:
        output_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        emit(
            {
                "status": "error",
                "error": f"Nelze vytvořit/zapsat výstupní adresář '{output_dir}': {exc}",
            }
        )
        return 1

    emit({"status": "starting", "url": args.url})

    options = build_options(args.format, output_dir, cookies=args.cookies)

    try:
        assert YoutubeDL is not None  # check_dependencies to zaručil
        with YoutubeDL(options) as ydl:
            # Nejprve metadata bez stahování -> dáme Rustu název/délku dopředu.
            info = ydl.extract_info(args.url, download=False)
            if info is None:
                emit({"status": "error", "error": "Nepodařilo se získat metadata videa."})
                return 1

            duration = info.get("duration")
            emit(
                {
                    "status": "metadata",
                    "title": info.get("title", "N/A"),
                    "duration": duration,
                    "uploader": info.get("uploader"),
                    "is_playlist": info.get("_type") == "playlist",
                }
            )

            # Ochrana proti zneužití: odmítni příliš dlouhá videa.
            if args.max_duration > 0 and isinstance(duration, (int, float)):
                if duration > args.max_duration:
                    emit(
                        {
                            "status": "error",
                            "error": (
                                f"Video je delší ({int(duration)} s) než povolený "
                                f"limit {args.max_duration} s."
                            ),
                        }
                    )
                    return 1

            # Samotné stažení + postprocessing.
            info = ydl.extract_info(args.url, download=True)
            if info is None:
                emit({"status": "error", "error": "Stahování selhalo (prázdná metadata)."})
                return 1

            final_path = resolve_final_path(info, args.format)
            emit({"status": "finished", "filepath": final_path})
            return 0

    except DownloadError as exc:
        emit({"status": "error", "error": f"Chyba stahování: {exc}"})
        return 1
    except KeyboardInterrupt:
        emit({"status": "error", "error": "Přerušeno uživatelem."})
        return 130
    except OSError as exc:
        emit({"status": "error", "error": f"Chyba I/O nebo sítě: {exc}"})
        return 1
    except Exception as exc:  # noqa: BLE001 - poslední záchytná síť, žádný panik
        emit({"status": "error", "error": f"Neočekávaná chyba: {exc}"})
        log_stderr(f"[downloader] neočekávaná výjimka: {exc!r}")
        return 1


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as exc:  # argparse volá sys.exit při chybě argumentů
        return int(exc.code) if exc.code is not None else 2
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
