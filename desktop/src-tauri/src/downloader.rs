//! Orchestrace **přibaleného** yt-dlp (žádný systémový Python ani Homebrew).
//!
//! Spustíme sidecar `yt-dlp` a přes `--print` / `--progress-template` ho
//! donutíme vypisovat rovnou JSON, který frontend zná (stejný kontrakt jako
//! dřívější Python worker). Každý relevantní řádek přeposíláme do frontendu
//! jako Tauri událost `ytmp:progress`.
//!
//! Streamy yt-dlp:
//!   * `--print before_dl/after_move`  -> STDOUT (metadata, finished)
//!   * `--progress-template download:` -> STDOUT (průběh stahování; nutný `--progress`)
//!   * `--progress-template postprocess:` -> STDERR (postprocessing)
//!   * chyby `ERROR: ...`                  -> STDERR
//!
//! Klíč k obejití bot-checku: aplikace běží lokálně (rezidenční IP), takže
//! yt-dlp stahuje z IP uživatele. Volitelně lze předat `--cookies-from-browser`.

use std::path::PathBuf;
use std::process::Stdio;

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

/// Payload události průběhu (jeden NDJSON řetězec pro frontend).
#[derive(Clone, Serialize)]
struct ProgressPayload {
    job_id: String,
    data: String,
}

const EVENT: &str = "ytmp:progress";

// Tagy, kterými si v outputu yt-dlp označíme vlastní strojové řádky.
const TAG_JSON: &str = "@@J@@"; // hotová JSON zpráva (metadata / finished)
const TAG_DL: &str = "@@D@@"; // průběh stahování (pct/speed/eta)
const TAG_PP: &str = "@@P@@"; // postprocessing (název postprocessoru)

fn target_triple() -> &'static str {
    option_env!("YTMP_TARGET_TRIPLE").unwrap_or("")
}

/// Najde přibalenou binárku (cross-platform; na Windows řeší příponu `.exe`).
/// Pořadí: vedle exe (bundled .app/.exe) -> `binaries/<name>-<triple>` (dev)
/// -> env `YTMP_YT_DLP` / `YTMP_FFMPEG`.
fn resolve_sidecar(name: &str) -> Option<PathBuf> {
    let ext = std::env::consts::EXE_SUFFIX; // "" na unixu, ".exe" na Windows
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let plain = dir.join(format!("{name}{ext}"));
            if plain.exists() {
                return Some(plain);
            }
            let suffixed = dir.join(format!("{name}-{}{ext}", target_triple()));
            if suffixed.exists() {
                return Some(suffixed);
            }
        }
    }
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("binaries")
        .join(format!("{name}-{}{ext}", target_triple()));
    if dev.exists() {
        return Some(dev);
    }
    let env_key = format!("YTMP_{}", name.to_uppercase().replace('-', "_"));
    if let Ok(p) = std::env::var(&env_key) {
        let pb = PathBuf::from(p);
        if pb.exists() {
            return Some(pb);
        }
    }
    None
}

/// "  50.7%" -> 50.7
fn parse_percent(s: &str) -> Option<f64> {
    let cleaned: String = s
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    cleaned.parse::<f64>().ok()
}

fn emit_line(app: &AppHandle, job_id: &str, line: String) {
    let _ = app.emit(
        EVENT,
        ProgressPayload {
            job_id: job_id.to_string(),
            data: line,
        },
    );
}

/// Spustí jednu úlohu a streamuje její průběh do frontendu.
pub async fn run_job(
    app: AppHandle,
    job_id: String,
    url: String,
    format: String,
    output_dir: String,
    browser: Option<String>,
) {
    let ytdlp = match resolve_sidecar("yt-dlp") {
        Some(p) => p,
        None => {
            emit_line(
                &app,
                &job_id,
                json!({ "status": "error", "error": "Přibalený yt-dlp nebyl nalezen." })
                    .to_string(),
            );
            return;
        }
    };
    let ffmpeg = resolve_sidecar("ffmpeg");

    emit_line(&app, &job_id, json!({ "status": "starting", "url": url }).to_string());

    let outtmpl = format!("{}/%(title)s.%(ext)s", output_dir.trim_end_matches('/'));

    let mut command = Command::new(&ytdlp);
    command
        .arg(&url)
        .arg("-o")
        .arg(&outtmpl)
        .arg("--no-color")
        .arg("--newline")
        .arg("--no-warnings")
        .arg("--progress")
        .arg("--progress-template")
        .arg(format!(
            "download:{TAG_DL}{{\"pct\":\"%(progress._percent_str)s\",\"speed\":\"%(progress._speed_str)s\",\"eta\":\"%(progress._eta_str)s\"}}"
        ))
        .arg("--progress-template")
        .arg(format!("postprocess:{TAG_PP}%(progress.postprocessor)s"))
        .arg("--print")
        .arg(format!(
            "before_dl:{TAG_JSON}{{\"status\":\"metadata\",\"title\":%(title)j,\"duration\":%(duration)j}}"
        ))
        .arg("--print")
        .arg(format!(
            "after_move:{TAG_JSON}{{\"status\":\"finished\",\"filepath\":%(filepath)j}}"
        ));

    if let Some(ff) = &ffmpeg {
        command.arg("--ffmpeg-location").arg(ff);
    }

    if format == "mp3" {
        command
            .arg("-x")
            .arg("--audio-format")
            .arg("mp3")
            .arg("--audio-quality")
            .arg("320K");
    } else {
        command
            .arg("-f")
            .arg("bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b")
            .arg("--merge-output-format")
            .arg("mp4");
    }

    if let Some(b) = browser.as_deref().filter(|b| !b.trim().is_empty()) {
        command.arg("--cookies-from-browser").arg(b);
    }

    let mut child = match command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            emit_line(
                &app,
                &job_id,
                json!({ "status": "error", "error": format!("Nelze spustit yt-dlp: {e}") })
                    .to_string(),
            );
            return;
        }
    };

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    // STDERR: emituj postprocessing (@@P@@) a sbírej ERROR řádky pro diagnostiku.
    let app_err = app.clone();
    let job_err = job_id.clone();
    let stderr_handle = tokio::spawn(async move {
        let mut errors = String::new();
        if let Some(stderr) = stderr {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let t = line.trim();
                if let Some(pp) = t.strip_prefix(TAG_PP) {
                    if !pp.is_empty() {
                        emit_line(
                            &app_err,
                            &job_err,
                            json!({ "status": "processing", "postprocessor": pp }).to_string(),
                        );
                    }
                } else if t.starts_with("ERROR:") || t.contains("ERROR:") {
                    errors.push_str(t);
                    errors.push('\n');
                }
            }
        }
        errors
    });

    // STDOUT: metadata / finished (@@J@@) a průběh stahování (@@D@@).
    let mut saw_finished = false;
    let mut saw_error = false;
    if let Some(stdout) = stdout {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let t = line.trim();
            if let Some(rest) = t.strip_prefix(TAG_JSON) {
                if rest.contains("\"finished\"") {
                    saw_finished = true;
                }
                if rest.contains("\"error\"") {
                    saw_error = true;
                }
                emit_line(&app, &job_id, rest.to_string());
            } else if let Some(rest) = t.strip_prefix(TAG_DL) {
                if let Ok(v) = serde_json::from_str::<Value>(rest) {
                    let progress = v
                        .get("pct")
                        .and_then(|x| x.as_str())
                        .and_then(parse_percent)
                        .unwrap_or(0.0);
                    let speed = v.get("speed").and_then(|x| x.as_str()).unwrap_or("").trim();
                    let eta = v.get("eta").and_then(|x| x.as_str()).unwrap_or("").trim();
                    emit_line(
                        &app,
                        &job_id,
                        json!({
                            "status": "downloading",
                            "progress": progress,
                            "speed": speed,
                            "eta": eta
                        })
                        .to_string(),
                    );
                }
            }
        }
    }

    let status = child.wait().await;
    let errors = stderr_handle.await.unwrap_or_default();

    let failed = matches!(&status, Ok(s) if !s.success()) || status.is_err();
    if (failed || (!saw_finished && !saw_error)) && !saw_error {
        // Doplň chybu jen pokud opravdu nedoběhlo úspěšně.
        if failed && !saw_finished {
            let msg = errors
                .trim()
                .lines()
                .last()
                .map(|l| l.trim_start_matches("ERROR:").trim().to_string())
                .filter(|m| !m.is_empty())
                .unwrap_or_else(|| "Stahování selhalo.".to_string());
            emit_line(
                &app,
                &job_id,
                json!({ "status": "error", "error": msg }).to_string(),
            );
        }
    }
}
