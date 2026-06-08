//! Orchestrace Python workeru a správa fronty úloh.
//!
//! Klíčové vlastnosti:
//!   * Subprocesy se spouští bez shellu (argumenty jako pole) -> bezpečné
//!     proti command injection.
//!   * stdout se čte asynchronně řádek po řádku a parsuje jako `ProgressEvent`.
//!   * Zpracování každého řádku je delegováno na `JobObserver`, takže stejné
//!     jádro umí napájet jak CLI progress bar, tak HTTP/SSE stream.
//!   * Více úloh běží paralelně s limitem daným semaforem.
//!   * Veškeré chyby cestují přes `ConvertError` (žádný panic/unwrap).

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;

use indicatif::{MultiProgress, ProgressBar, ProgressStyle};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

use crate::models::{AppConfig, Job, ProgressEvent};

/// Chyby, které mohou nastat při orchestraci a zpracování úlohy.
#[derive(Debug, Error)]
pub enum ConvertError {
    #[error(
        "Python interpret '{0}' nebyl nalezen. Nainstalujte Python 3.10+ a ujistěte se, že je v PATH."
    )]
    PythonNotFound(String),

    #[error("Skript workeru nebyl nalezen na cestě: {0}")]
    ScriptNotFound(PathBuf),

    #[error("Selhalo spuštění Python procesu: {0}")]
    Spawn(#[source] std::io::Error),

    #[error("Chyba I/O při čtení výstupu workeru: {0}")]
    Io(#[source] std::io::Error),

    #[error("Worker selhal (kód {code}): {message}")]
    Worker { code: i32, message: String },

    #[error("Port {port} je již obsazen. {hint}")]
    AddrInUse { port: u16, hint: String },

    #[error("Úloha byla naplánována, ale interně selhala: {0}")]
    Join(String),
}

/// Pozorovatel průběhu jedné úlohy.
///
/// Jádro (`execute_job`) volá tyto metody synchronně v read-smyčce. Konkrétní
/// implementace rozhoduje, kam se data promítnou (terminál, kanál, SSE, ...).
pub trait JobObserver: Send {
    /// Validní naparsovaná událost; `raw` je původní JSON řádek.
    fn on_event(&mut self, raw: &str, event: &ProgressEvent);

    /// Řádek na stdout, který nešel naparsovat jako `ProgressEvent`.
    fn on_invalid(&mut self, _raw: &str) {}

    /// Závěr úlohy. `error == None` znamená úspěch.
    fn on_finish(&mut self, _error: Option<&ConvertError>) {}
}

/// Vstupní bod CLI: zpracuje celou frontu úloh s omezenou souběžností.
///
/// Vrací počet úspěšných úloh; chyby jednotlivých úloh se logují, ale
/// nezhroutí celý běh (ostatní položky fronty doběhnou).
pub async fn run_queue(
    config: &AppConfig,
    jobs: Vec<Job>,
    python_cmd: String,
    script_path: PathBuf,
) -> Result<usize, ConvertError> {
    // Skript musí existovat ještě před spuštěním čehokoli.
    if !script_path.exists() {
        return Err(ConvertError::ScriptNotFound(script_path));
    }

    let multi = MultiProgress::new();
    let semaphore = Arc::new(Semaphore::new(config.concurrency.max(1)));
    let python_cmd = Arc::new(python_cmd);
    let script_path = Arc::new(script_path);

    let mut set: JoinSet<(String, Result<(), ConvertError>)> = JoinSet::new();

    for job in jobs {
        let permit_sem = Arc::clone(&semaphore);
        let python = Arc::clone(&python_cmd);
        let script = Arc::clone(&script_path);
        let bar = multi.add(ProgressBar::new(100));
        bar.set_style(progress_style());
        bar.set_prefix(truncate(&job.url, 40));

        set.spawn(async move {
            // Drží slot ve frontě po dobu úlohy; uvolní se dropem.
            let _permit = match permit_sem.acquire_owned().await {
                Ok(p) => p,
                Err(_) => {
                    return (
                        job.url.clone(),
                        Err(ConvertError::Join("semafor byl uzavřen".into())),
                    )
                }
            };

            let url = job.url.clone();
            let mut observer = BarObserver { bar };
            let result = execute_job(&job, &python, &script, &mut observer).await;
            (url, result)
        });
    }

    let mut succeeded = 0usize;
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok((_url, Ok(()))) => succeeded += 1,
            Ok((url, Err(err))) => eprintln!("✖ Úloha selhala [{url}]: {err}"),
            Err(join_err) => eprintln!("✖ Interní chyba úlohy: {join_err}"),
        }
    }

    Ok(succeeded)
}

/// Spustí Python worker pro jednu úlohu a směruje jeho výstup do `observer`.
///
/// Veřejné, aby jádro mohla použít i API vrstva s vlastním observerem.
pub async fn execute_job<O: JobObserver>(
    job: &Job,
    python_cmd: &str,
    script_path: &Path,
    observer: &mut O,
) -> Result<(), ConvertError> {
    let result = run_inner(job, python_cmd, script_path, observer).await;
    observer.on_finish(result.as_ref().err());
    result
}

async fn run_inner<O: JobObserver>(
    job: &Job,
    python_cmd: &str,
    script_path: &Path,
    observer: &mut O,
) -> Result<(), ConvertError> {
    // POZOR: argumenty se předávají jako pole -> žádný shell, žádná injection.
    let mut command = Command::new(python_cmd);
    command
        .arg(script_path)
        .arg(&job.url)
        .arg("--format")
        .arg(job.format.as_arg())
        .arg("--output")
        .arg(&job.output_dir);
    if let Some(secs) = job.max_duration {
        command.arg("--max-duration").arg(secs.to_string());
    }
    if let Some(cookies) = &job.cookies {
        command.arg("--cookies").arg(cookies);
    }
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::null())
        .spawn()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                ConvertError::PythonNotFound(python_cmd.to_string())
            } else {
                ConvertError::Spawn(e)
            }
        })?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| ConvertError::Spawn(std::io::Error::other("stdout nedostupný")))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| ConvertError::Spawn(std::io::Error::other("stderr nedostupný")))?;

    // stderr čteme paralelně do bufferu pro případnou diagnostiku.
    let stderr_handle = tokio::spawn(async move {
        let mut buf = String::new();
        let mut lines = BufReader::new(stderr).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            buf.push_str(&line);
            buf.push('\n');
        }
        buf
    });

    // Hlavní smyčka: čteme stdout řádek po řádku a aktualizujeme stav.
    let mut last_error: Option<String> = None;
    let mut reader = BufReader::new(stdout).lines();

    loop {
        let line = match reader.next_line().await {
            Ok(Some(line)) => line,
            Ok(None) => break, // EOF
            Err(e) => return Err(ConvertError::Io(e)),
        };

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        match serde_json::from_str::<ProgressEvent>(trimmed) {
            Ok(event) => {
                observer.on_event(trimmed, &event);
                if let ProgressEvent::Error { error } = &event {
                    last_error = Some(error.clone());
                }
            }
            Err(_) => observer.on_invalid(trimmed),
        }
    }

    // Počkáme na ukončení procesu a vyhodnotíme návratový kód.
    let status = child.wait().await.map_err(ConvertError::Io)?;
    let stderr_output = stderr_handle.await.unwrap_or_default();

    if status.success() && last_error.is_none() {
        return Ok(());
    }

    // Sestavíme co nejvýmluvnější chybovou zprávu.
    let code = status.code().unwrap_or(-1);
    let message = last_error.unwrap_or_else(|| {
        let tail = stderr_output.trim();
        if tail.is_empty() {
            "worker skončil bez bližšího popisu".to_string()
        } else {
            tail.lines().last().unwrap_or(tail).to_string()
        }
    });

    Err(ConvertError::Worker { code, message })
}

/// Observer napájející `indicatif` progress bar v terminálu.
struct BarObserver {
    bar: ProgressBar,
}

impl JobObserver for BarObserver {
    fn on_event(&mut self, _raw: &str, event: &ProgressEvent) {
        apply_event(event, &self.bar);
    }

    fn on_invalid(&mut self, raw: &str) {
        self.bar
            .set_message(format!("⚠ neparsovatelný výstup: {}", truncate(raw, 60)));
    }

    fn on_finish(&mut self, error: Option<&ConvertError>) {
        if let Some(err) = error {
            self.bar.abandon_with_message(format!("✖ {err}"));
        }
    }
}

/// Promítne jednu událost na progress bar.
fn apply_event(event: &ProgressEvent, bar: &ProgressBar) {
    match event {
        ProgressEvent::Starting { url } => {
            bar.set_prefix(truncate(url, 40));
            bar.set_message("start...");
        }
        ProgressEvent::Metadata { title, duration, .. } => {
            let dur = duration
                .map(|d| format!(" ({}s)", d as u64))
                .unwrap_or_default();
            bar.set_prefix(truncate(title, 40));
            bar.set_message(format!("metadata{dur}"));
        }
        ProgressEvent::Downloading {
            progress, speed, eta, ..
        } => {
            bar.set_position(progress.clamp(0.0, 100.0) as u64);
            bar.set_message(format!("{speed} • ETA {eta}"));
        }
        ProgressEvent::Processing { postprocessor } => {
            bar.set_message(format!("zpracování: {postprocessor}"));
        }
        ProgressEvent::Finished { filepath } => {
            bar.set_position(100);
            let label = if filepath.is_empty() {
                "✔ hotovo".to_string()
            } else {
                format!("✔ {}", truncate(filepath, 50))
            };
            bar.finish_with_message(label);
        }
        ProgressEvent::Error { error } => {
            bar.set_message(format!("✖ {}", truncate(error, 60)));
        }
        ProgressEvent::Unknown => {}
    }
}

/// Styl progress baru sdílený všemi úlohami.
fn progress_style() -> ProgressStyle {
    ProgressStyle::with_template("{prefix:40!} [{bar:30.cyan/blue}] {pos:>3}% {msg}")
        .unwrap_or_else(|_| ProgressStyle::default_bar())
        .progress_chars("=>-")
}

/// Zkrátí string na `max` znaků s elipsou (počítá Unicode znaky, ne byty).
fn truncate(s: &str, max: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= max {
        s.to_string()
    } else {
        let cut: String = chars.into_iter().take(max.saturating_sub(1)).collect();
        format!("{cut}…")
    }
}
