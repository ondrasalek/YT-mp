//! HTTP API vrstva (axum) — webová aplikace.
//!
//! Model: server stáhne médium do dočasného **per-job** adresáře a soubor
//! následně **streamuje do prohlížeče** uživatele. Uživatel je vzdálený,
//! takže se nikam na server neukládá natrvalo ani nevybírá cílová složka.
//!
//! Endpointy:
//!   * `GET  /`                    -> webové UI
//!   * `GET  /health`              -> liveness check
//!   * `POST /jobs`                -> zařadí úlohu, vrátí `job_id`, URL streamu a downloadu
//!   * `GET  /jobs/{id}/events`    -> SSE proud JSON událostí progressu
//!   * `GET  /jobs/{id}/download`  -> stáhne hotový soubor (jako příloha)
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
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, StatusCode};
use axum::response::sse::{Event, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::Notify;
use tokio_util::io::ReaderStream;
use uuid::Uuid;

use crate::converter::{execute_job, ConvertError, JobObserver};
use crate::models::{Job, MediaFormat, ProgressEvent};

/// Doba, po které sweeper smaže dokončenou úlohu (soubor + záznam).
const JOB_TTL: Duration = Duration::from_secs(30 * 60);

/// Append-only log událostí jedné úlohy + metadata pro download a úklid.
struct JobLog {
    entries: Mutex<Vec<String>>,
    finished: AtomicBool,
    notify: Notify,
    /// Pracovní adresář úlohy (maže se při úklidu).
    dir: PathBuf,
    /// Cesta k hotovému souboru (vyplní se z `finished` eventu).
    output_path: Mutex<Option<PathBuf>>,
    /// Čas dokončení (pro TTL sweeper).
    finished_at: Mutex<Option<Instant>>,
}

impl JobLog {
    fn new(dir: PathBuf) -> Self {
        Self {
            entries: Mutex::new(Vec::new()),
            finished: AtomicBool::new(false),
            notify: Notify::new(),
            dir,
            output_path: Mutex::new(None),
            finished_at: Mutex::new(None),
        }
    }

    fn push(&self, line: String) {
        if let Ok(mut guard) = self.entries.lock() {
            guard.push(line);
        }
        self.notify.notify_waiters();
    }

    fn set_output(&self, path: PathBuf) {
        if let Ok(mut guard) = self.output_path.lock() {
            *guard = Some(path);
        }
    }

    fn output(&self) -> Option<PathBuf> {
        self.output_path.lock().ok().and_then(|g| g.clone())
    }

    fn finish(&self) {
        self.finished.store(true, Ordering::SeqCst);
        if let Ok(mut guard) = self.finished_at.lock() {
            *guard = Some(Instant::now());
        }
        self.notify.notify_waiters();
    }

    fn finished_elapsed(&self) -> Option<Duration> {
        self.finished_at
            .lock()
            .ok()
            .and_then(|g| *g)
            .map(|t| t.elapsed())
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
    /// Kořenový adresář pro pracovní per-job složky.
    data_dir: PathBuf,
}

type SharedState = Arc<ApiState>;

/// Observer, který zapisuje syrové JSON řádky do `JobLog` a zachytí
/// finální cestu k souboru.
struct ChannelObserver {
    log: Arc<JobLog>,
}

impl JobObserver for ChannelObserver {
    fn on_event(&mut self, raw: &str, event: &ProgressEvent) {
        self.log.push(raw.to_string());
        if let ProgressEvent::Finished { filepath } = event {
            if !filepath.is_empty() {
                self.log.set_output(PathBuf::from(filepath));
            }
        }
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
}

#[derive(Debug, Serialize)]
struct JobResponse {
    job_id: Uuid,
    events_url: String,
    download_url: String,
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

    let id = Uuid::new_v4();
    // Každá úloha má vlastní izolovaný adresář pod data_dir.
    let job_dir = state.data_dir.join(id.to_string());
    tokio::fs::create_dir_all(&job_dir).await.map_err(|e| {
        ApiError(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("nelze vytvořit pracovní adresář: {e}"),
        )
    })?;

    let job = Job {
        url: req.url,
        format,
        output_dir: job_dir.clone(),
    };

    let log = Arc::new(JobLog::new(job_dir));

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
        download_url: format!("/jobs/{id}/download"),
    }))
}

async fn job_events(State(state): State<SharedState>, Path(id): Path<Uuid>) -> Response {
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

/// Stáhne hotový soubor úlohy a streamuje ho jako přílohu.
async fn download_job(State(state): State<SharedState>, Path(id): Path<Uuid>) -> Response {
    let log = match state.jobs.lock() {
        Ok(jobs) => jobs.get(&id).cloned(),
        Err(_) => None,
    };
    let Some(log) = log else {
        return ApiError(StatusCode::NOT_FOUND, format!("úloha {id} nenalezena")).into_response();
    };

    let Some(path) = log.output() else {
        return ApiError(
            StatusCode::CONFLICT,
            "soubor ještě není připraven (úloha neskončila nebo selhala)".into(),
        )
        .into_response();
    };

    // Bezpečnost: soubor MUSÍ ležet uvnitř adresáře úlohy (anti path-traversal).
    let canon_file = tokio::fs::canonicalize(&path).await.ok();
    let canon_dir = tokio::fs::canonicalize(&log.dir).await.ok();
    let inside = matches!((canon_file, canon_dir), (Some(f), Some(d)) if f.starts_with(&d));
    if !inside {
        return ApiError(StatusCode::NOT_FOUND, "soubor nenalezen".into()).into_response();
    }

    let file = match tokio::fs::File::open(&path).await {
        Ok(f) => f,
        Err(_) => return ApiError(StatusCode::NOT_FOUND, "soubor nelze otevřít".into()).into_response(),
    };

    let filename = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("download")
        .to_string();
    let content_type = match path.extension().and_then(|s| s.to_str()) {
        Some("mp3") => "audio/mpeg",
        Some("mp4") => "video/mp4",
        Some("m4a") => "audio/mp4",
        _ => "application/octet-stream",
    };

    let body = Body::from_stream(ReaderStream::new(file));
    Response::builder()
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CONTENT_DISPOSITION, content_disposition(&filename))
        .body(body)
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

/// Sestaví hlavičku Content-Disposition s ASCII fallbackem i UTF-8 názvem (RFC 5987).
fn content_disposition(filename: &str) -> String {
    let ascii: String = filename
        .chars()
        .map(|c| if c.is_ascii() && c != '"' && c != '\\' { c } else { '_' })
        .collect();
    format!(
        "attachment; filename=\"{ascii}\"; filename*=UTF-8''{}",
        percent_encode(filename)
    )
}

/// Percent-encoding pro RFC 5987 (bez externí závislosti).
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push('%');
            out.push_str(&format!("{b:02X}"));
        }
    }
    out
}

/// Sestaví router se sdíleným stavem.
fn build_router(state: SharedState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/health", get(health))
        .route("/jobs", post(submit_job))
        .route("/jobs/{id}/events", get(job_events))
        .route("/jobs/{id}/download", get(download_job))
        .with_state(state)
}

/// Periodicky maže dokončené úlohy starší než `JOB_TTL` (soubory i záznamy).
fn spawn_cleanup(state: SharedState) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;

            let mut expired: Vec<(Uuid, PathBuf)> = Vec::new();
            if let Ok(jobs) = state.jobs.lock() {
                for (id, log) in jobs.iter() {
                    if matches!(log.finished_elapsed(), Some(elapsed) if elapsed >= JOB_TTL) {
                        expired.push((*id, log.dir.clone()));
                    }
                }
            }

            for (id, dir) in expired {
                if let Ok(mut jobs) = state.jobs.lock() {
                    jobs.remove(&id);
                }
                let _ = tokio::fs::remove_dir_all(&dir).await;
            }
        }
    });
}

// ---- Spuštění serveru + dev-friendly bind ----

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
        eprintln!("⚠ Port {port} drží starý ytmp server (PID {ours:?}) — ukončuji (--force)…");
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
    data_dir: PathBuf,
    force: bool,
) -> Result<(), ConvertError> {
    if !script_path.exists() {
        return Err(ConvertError::ScriptNotFound(script_path));
    }

    tokio::fs::create_dir_all(&data_dir)
        .await
        .map_err(ConvertError::Io)?;

    let state = Arc::new(ApiState {
        jobs: Mutex::new(HashMap::new()),
        python_cmd,
        script_path,
        data_dir,
    });

    spawn_cleanup(Arc::clone(&state));
    let app = build_router(state);

    let listener = bind_listener(addr, force).await?;

    println!("▶ Web UI:  http://{addr}/");
    println!("  POST http://{addr}/jobs   body: {{\"url\":\"...\",\"format\":\"mp3\"}}");
    println!("  GET  http://{addr}/jobs/<id>/events    (SSE)");
    println!("  GET  http://{addr}/jobs/<id>/download  (soubor)");

    axum::serve(listener, app).await.map_err(ConvertError::Io)?;
    Ok(())
}
