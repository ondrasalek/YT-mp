//! HTTP API vrstva (axum) nad sdíleným orchestračním jádrem.
//!
//! Endpointy:
//!   * `GET  /health`            -> liveness check
//!   * `POST /jobs`              -> zařadí úlohu, vrátí `job_id` a URL streamu
//!   * `GET  /jobs/{id}/events`  -> SSE proud JSON událostí progressu
//!
//! Stejné jádro (`converter::execute_job`) napájí CLI i API; rozdíl je jen
//! v `JobObserver` — zde se události zapisují do append-only logu, který
//! SSE handler streamuje připojeným klientům (včetně historie pro pozdě
//! připojené odběratele).

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::sse::{Event, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::Notify;
use uuid::Uuid;

use crate::converter::{execute_job, ConvertError, JobObserver};
use crate::models::{Job, MediaFormat, ProgressEvent};

/// Append-only log událostí jedné úlohy + signalizace nových položek.
struct JobLog {
    entries: Mutex<Vec<String>>,
    finished: AtomicBool,
    notify: Notify,
}

impl JobLog {
    fn new() -> Self {
        Self {
            entries: Mutex::new(Vec::new()),
            finished: AtomicBool::new(false),
            notify: Notify::new(),
        }
    }

    fn push(&self, line: String) {
        if let Ok(mut guard) = self.entries.lock() {
            guard.push(line);
        }
        self.notify.notify_waiters();
    }

    fn finish(&self) {
        self.finished.store(true, Ordering::SeqCst);
        self.notify.notify_waiters();
    }

    fn snapshot_from(&self, cursor: usize) -> (Vec<String>, bool) {
        let finished = self.finished.load(Ordering::SeqCst);
        let slice = self
            .entries
            .lock()
            .map(|g| g.get(cursor..).map(<[String]>::to_vec).unwrap_or_default())
            .unwrap_or_default();
        (slice, finished)
    }

    fn len(&self) -> usize {
        self.entries.lock().map(|g| g.len()).unwrap_or(0)
    }
}

/// Sdílený stav serveru.
struct ApiState {
    jobs: Mutex<HashMap<Uuid, Arc<JobLog>>>,
    python_cmd: String,
    script_path: PathBuf,
}

type SharedState = Arc<ApiState>;

/// Observer, který zapisuje syrové JSON řádky do `JobLog`.
struct ChannelObserver {
    log: Arc<JobLog>,
}

impl JobObserver for ChannelObserver {
    fn on_event(&mut self, raw: &str, _event: &ProgressEvent) {
        self.log.push(raw.to_string());
    }

    fn on_invalid(&mut self, raw: &str) {
        self.log
            .push(json!({ "status": "warning", "raw": raw }).to_string());
    }
}

// ---- DTO ----

#[derive(Debug, Deserialize)]
struct JobRequest {
    url: String,
    format: String,
    #[serde(default)]
    output_dir: Option<String>,
}

#[derive(Debug, Serialize)]
struct JobResponse {
    job_id: Uuid,
    events_url: String,
}

/// Jednoduchá chyba API s mapováním na HTTP status + JSON tělo.
struct ApiError(StatusCode, String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({ "error": self.1 }))).into_response()
    }
}

// ---- Handlery ----

/// Statický frontend zabalený přímo do binárky.
const INDEX_HTML: &str = include_str!("../web/index.html");

async fn index() -> impl IntoResponse {
    axum::response::Html(INDEX_HTML)
}

async fn health() -> impl IntoResponse {
    Json(json!({ "status": "ok" }))
}

/// Otevře NATIVNÍ systémový dialog pro výběr složky na stroji, kde běží server.
///
/// Funguje, protože jde o lokální nástroj (server == klientův stroj). Vrací:
///   * `{ "path": "/abs/cesta" }`  když uživatel vybral složku,
///   * `{ "cancelled": true }`     když dialog zrušil,
///   * HTTP 500 + `{ "error": ... }` když dialog nelze otevřít (např. headless).
async fn pick_folder() -> Response {
    match native_pick_folder().await {
        Ok(Some(path)) => Json(json!({ "path": path })).into_response(),
        Ok(None) => Json(json!({ "cancelled": true })).into_response(),
        Err(msg) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": msg })),
        )
            .into_response(),
    }
}

/// Spustí platformově specifický nativní dialog pro výběr adresáře.
async fn native_pick_folder() -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    {
        // AppleScript `choose folder` -> standardní macOS dialog (bez extra oprávnění).
        let out = tokio::process::Command::new("osascript")
            .args([
                "-e",
                "POSIX path of (choose folder with prompt \"Vyber výstupní složku\")",
            ])
            .output()
            .await
            .map_err(|e| format!("nelze spustit osascript: {e}"))?;

        if out.status.success() {
            let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
            return Ok((!path.is_empty()).then_some(path));
        }
        let err = String::from_utf8_lossy(&out.stderr);
        // -128 = uživatel stiskl Zrušit.
        if err.contains("-128") || err.to_lowercase().contains("cancel") {
            return Ok(None);
        }
        return Err(err.trim().to_string());
    }

    #[cfg(target_os = "linux")]
    {
        // Zkusíme zenity (GTK), pak kdialog (KDE).
        for (cmd, args) in [
            ("zenity", vec!["--file-selection", "--directory", "--title=Vyber výstupní složku"]),
            ("kdialog", vec!["--getexistingdirectory", "."]),
        ] {
            match tokio::process::Command::new(cmd).args(&args).output().await {
                Ok(out) if out.status.success() => {
                    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    return Ok((!path.is_empty()).then_some(path));
                }
                Ok(_) => return Ok(None), // nenulový kód = zrušeno
                Err(_) => continue,         // nástroj chybí -> zkus další
            }
        }
        return Err("nenalezen 'zenity' ani 'kdialog' (nainstaluj jeden z nich)".to_string());
    }

    #[cfg(target_os = "windows")]
    {
        let script = "Add-Type -AssemblyName System.Windows.Forms; \
            $d = New-Object System.Windows.Forms.FolderBrowserDialog; \
            if ($d.ShowDialog() -eq 'OK') { [Console]::Out.Write($d.SelectedPath) }";
        let out = tokio::process::Command::new("powershell")
            .args(["-NoProfile", "-STA", "-Command", script])
            .output()
            .await
            .map_err(|e| format!("nelze spustit powershell: {e}"))?;
        let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
        return Ok((!path.is_empty()).then_some(path));
    }

    #[allow(unreachable_code)]
    Err("nativní výběr složky není na této platformě podporován".to_string())
}

async fn submit_job(
    State(state): State<SharedState>,
    Json(req): Json<JobRequest>,
) -> Result<Json<JobResponse>, ApiError> {
    let format: MediaFormat = req
        .format
        .parse()
        .map_err(|e: String| ApiError(StatusCode::BAD_REQUEST, e))?;

    if req.url.trim().is_empty() {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "pole 'url' nesmí být prázdné".to_string(),
        ));
    }

    let output_dir = PathBuf::from(req.output_dir.unwrap_or_else(|| "./downloads".to_string()));
    let job = Job {
        url: req.url,
        format,
        output_dir,
    };

    let id = Uuid::new_v4();
    let log = Arc::new(JobLog::new());

    {
        let mut jobs = state
            .jobs
            .lock()
            .map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "stav serveru".into()))?;
        jobs.insert(id, Arc::clone(&log));
    }

    // Úlohu spustíme na pozadí; klient průběh sleduje přes SSE.
    let python = state.python_cmd.clone();
    let script = state.script_path.clone();
    tokio::spawn(async move {
        let mut observer = ChannelObserver {
            log: Arc::clone(&log),
        };
        let result = execute_job(&job, &python, &script, &mut observer).await;
        if let Err(err) = &result {
            // Chyby orchestrace (např. chybějící Python) ještě nejsou v logu.
            if !matches!(err, ConvertError::Worker { .. }) {
                log.push(json!({ "status": "error", "error": err.to_string() }).to_string());
            }
        }
        log.finish();
    });

    Ok(Json(JobResponse {
        job_id: id,
        events_url: format!("/jobs/{id}/events"),
    }))
}

async fn job_events(
    State(state): State<SharedState>,
    Path(id): Path<Uuid>,
) -> Response {
    let log = match state.jobs.lock() {
        Ok(jobs) => jobs.get(&id).cloned(),
        Err(_) => None,
    };

    let Some(log) = log else {
        return ApiError(StatusCode::NOT_FOUND, format!("úloha {id} nenalezena")).into_response();
    };

    let stream = async_stream::stream! {
        let mut cursor = 0usize;
        loop {
            // Future vytvoříme PŘED snapshotem, aby nám neuniklo žádné
            // upozornění doručené mezi čtením a čekáním.
            let notified = log.notify.notified();

            let (new_entries, finished) = log.snapshot_from(cursor);
            for line in new_entries {
                cursor += 1;
                yield Ok::<Event, Infallible>(Event::default().data(line));
            }

            if finished && cursor >= log.len() {
                break;
            }

            notified.await;
        }
    };

    Sse::new(stream)
        .keep_alive(axum::response::sse::KeepAlive::default())
        .into_response()
}

/// Sestaví router se sdíleným stavem.
fn build_router(state: SharedState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/health", get(health))
        .route("/pick-folder", get(pick_folder))
        .route("/jobs", post(submit_job))
        .route("/jobs/{id}/events", get(job_events))
        .with_state(state)
}

/// Najde PID(y) procesů naslouchajících na daném TCP portu (přes `lsof`).
async fn find_port_holders(port: u16) -> Vec<u32> {
    let output = tokio::process::Command::new("lsof")
        .args(["-ti", &format!("tcp:{port}"), "-sTCP:LISTEN"])
        .output()
        .await;
    match output {
        Ok(out) => String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter_map(|line| line.trim().parse::<u32>().ok())
            .collect(),
        Err(_) => Vec::new(), // lsof nedostupný -> bez detekce
    }
}

/// Ověří, zda PID patří našemu `ytmp` serveru (abychom nezabili cizí proces).
async fn is_ytmp_process(pid: u32) -> bool {
    let output = tokio::process::Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output()
        .await;
    match output {
        Ok(out) => String::from_utf8_lossy(&out.stdout).contains("ytmp"),
        Err(_) => false,
    }
}

/// Pošle SIGTERM danému PID (best-effort).
async fn kill_pid(pid: u32) {
    let _ = tokio::process::Command::new("kill")
        .arg(pid.to_string())
        .status()
        .await;
}

/// Nabinduje listener; při obsazeném portu nabídne dev-friendly chování.
async fn bind_listener(
    addr: SocketAddr,
    force: bool,
) -> Result<tokio::net::TcpListener, ConvertError> {
    match tokio::net::TcpListener::bind(addr).await {
        Ok(listener) => return Ok(listener),
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => { /* řešíme níže */ }
        Err(e) => return Err(ConvertError::Io(e)),
    }

    // Port je obsazen — zjistíme kým a rozhodneme se podle --force.
    let port = addr.port();
    let mut ours: Vec<u32> = Vec::new();
    let mut foreign: Vec<u32> = Vec::new();
    for pid in find_port_holders(port).await {
        if is_ytmp_process(pid).await {
            ours.push(pid);
        } else {
            foreign.push(pid);
        }
    }

    if force && !ours.is_empty() {
        eprintln!(
            "⚠ Port {port} drží starý ytmp server (PID {ours:?}) — ukončuji (--force)…"
        );
        for pid in &ours {
            kill_pid(*pid).await;
        }
        // Krátký backoff, než OS port skutečně uvolní.
        for _ in 0..20 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            if let Ok(listener) = tokio::net::TcpListener::bind(addr).await {
                println!("✔ Port {port} uvolněn, pokračuji.");
                return Ok(listener);
            }
        }
    }

    let hint = if !foreign.is_empty() {
        format!("Drží ho cizí proces (PID {foreign:?}). Zvol jiný --port.")
    } else if !ours.is_empty() {
        format!(
            "Starý ytmp server (PID {ours:?}) stále běží. \
             Spusť s --force pro automatické ukončení, nebo: kill {}",
            ours.iter().map(u32::to_string).collect::<Vec<_>>().join(" ")
        )
    } else {
        "Zvol jiný --port (např. --port 8081).".to_string()
    };
    Err(ConvertError::AddrInUse { port, hint })
}

/// Spustí HTTP server. Blokuje, dokud server neskončí.
pub async fn serve(
    addr: SocketAddr,
    python_cmd: String,
    script_path: PathBuf,
    force: bool,
) -> Result<(), ConvertError> {
    if !script_path.exists() {
        return Err(ConvertError::ScriptNotFound(script_path));
    }

    let state = Arc::new(ApiState {
        jobs: Mutex::new(HashMap::new()),
        python_cmd,
        script_path,
    });

    let app = build_router(state);

    let listener = bind_listener(addr, force).await?;

    println!("▶ Web UI:  http://{addr}/");
    println!("  POST http://{addr}/jobs   body: {{\"url\":\"...\",\"format\":\"mp3\"}}");
    println!("  GET  http://{addr}/jobs/<id>/events  (SSE)");

    axum::serve(listener, app).await.map_err(ConvertError::Io)?;
    Ok(())
}
