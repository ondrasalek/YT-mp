//! CLI vstupní bod aplikace "YouTube Video Converter to MP3/MP4".
//!
//! Spojuje konfiguraci (`models`) s orchestrací (`converter`) a poskytuje
//! dvě rozhraní:
//!   * `download` -> přímé stažení v terminálu s progress barem,
//!   * `serve`    -> HTTP API se SSE streamem progressu.

mod api;
mod converter;
mod models;

use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use crate::converter::run_queue;
use crate::models::{AppConfig, Job, MediaFormat};

/// Stáhne a převede YouTube video(a) do MP3 nebo MP4.
#[derive(Debug, Parser)]
#[command(
    name = "ytmp",
    version,
    about = "YouTube -> MP3/MP4 konvertor (Rust jádro + Python yt-dlp worker)",
    long_about = None
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Stáhne jedno či více videí přímo v terminálu.
    Download(DownloadArgs),
    /// Spustí HTTP API server se SSE streamem progressu.
    Serve(ServeArgs),
}

#[derive(Debug, clap::Args)]
struct DownloadArgs {
    /// Jedno nebo více YouTube URL (video nebo playlist).
    #[arg(required = true, value_name = "URL")]
    urls: Vec<String>,

    /// Cílový formát: mp3 (audio 320k) nebo mp4 (video).
    #[arg(short, long, default_value = "mp4")]
    format: MediaFormat,

    /// Výstupní adresář.
    #[arg(short, long, default_value = "./downloads")]
    output: PathBuf,

    /// Maximální počet souběžně běžících stahování.
    #[arg(short = 'j', long, default_value_t = 2)]
    concurrency: usize,

    /// Cesta k Python interpretu (jinak se zkusí python3, pak python).
    #[arg(long)]
    python: Option<String>,

    /// Cesta ke skriptu downloader.py (jinak autodetekce).
    #[arg(long)]
    script: Option<PathBuf>,
}

#[derive(Debug, clap::Args)]
struct ServeArgs {
    /// IP adresa pro naslouchání.
    #[arg(long, default_value = "127.0.0.1")]
    host: IpAddr,

    /// TCP port.
    #[arg(short, long, default_value_t = 8080)]
    port: u16,

    /// Dev režim: pokud port drží starý ytmp server, automaticky ho ukonči.
    #[arg(long)]
    force: bool,

    /// Kořenový adresář pro dočasné per-job soubory (mažou se po TTL).
    #[arg(long, default_value = "./data")]
    data_dir: PathBuf,

    /// Max. počet souběžně běžících konverzí.
    #[arg(long, default_value_t = 3)]
    max_concurrent: usize,

    /// Max. počet úloh čekajících ve frontě (nad rámec běžících).
    #[arg(long, default_value_t = 10)]
    max_queue: usize,

    /// Max. počet úloh na jednu IP za minutu (0 = bez limitu).
    #[arg(long, default_value_t = 10)]
    rate_limit: usize,

    /// Max. délka videa v sekundách (0 = bez limitu).
    #[arg(long, default_value_t = 0)]
    max_duration: u64,

    /// Cookies soubor pro yt-dlp (obejití bot-checku na YouTube).
    #[arg(long)]
    cookies: Option<PathBuf>,

    /// Sdílený token pro admin endpoint /admin/cookies (nahrání/refresh
    /// cookies přes HTTP bez SSH). Bez tohoto tokenu je endpoint vypnutý.
    /// Lze nastavit i přes proměnnou prostředí YTMP_ADMIN_TOKEN (nezůstane
    /// vidět v `ps`/`docker inspect` jako argument příkazu).
    #[arg(long, env = "YTMP_ADMIN_TOKEN")]
    admin_token: Option<String>,

    /// Cesta k Python interpretu (jinak se zkusí python3, pak python).
    #[arg(long)]
    python: Option<String>,

    /// Cesta ke skriptu downloader.py (jinak autodetekce).
    #[arg(long)]
    script: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command {
        Command::Download(args) => run_download(args).await,
        Command::Serve(args) => run_serve(args).await,
    }
}

async fn run_download(args: DownloadArgs) -> ExitCode {
    let python_cmd = args.python.unwrap_or_else(detect_python);
    let script_path = match resolve_script(args.script) {
        Ok(p) => p,
        Err(code) => return code,
    };

    let config = AppConfig {
        url: args.urls.first().cloned().unwrap_or_default(),
        format: args.format,
        output_dir: args.output.clone(),
        concurrency: args.concurrency,
    };

    let jobs: Vec<Job> = args
        .urls
        .into_iter()
        .map(|url| Job {
            url,
            format: args.format,
            output_dir: args.output.clone(),
            max_duration: None,
            cookies: None,
        })
        .collect();

    let total = jobs.len();
    println!(
        "▶ Spouštím {total} úloh(y) | formát: {} | výstup: {} | souběžnost: {}",
        config.format,
        config.output_dir.display(),
        config.concurrency
    );

    match run_queue(&config, jobs, python_cmd, script_path).await {
        Ok(ok) => {
            let failed = total.saturating_sub(ok);
            println!("\n✔ Dokončeno: {ok}/{total} úspěšných, {failed} chybných.");
            if failed == 0 {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        Err(err) => {
            eprintln!("\n✖ Fatální chyba: {err}");
            ExitCode::FAILURE
        }
    }
}

async fn run_serve(args: ServeArgs) -> ExitCode {
    let python_cmd = args.python.unwrap_or_else(detect_python);
    let script_path = match resolve_script(args.script) {
        Ok(p) => p,
        Err(code) => return code,
    };

    let addr = SocketAddr::new(args.host, args.port);
    let cfg = api::ServeConfig {
        addr,
        python_cmd,
        script_path,
        data_dir: args.data_dir,
        force: args.force,
        max_active: args.max_concurrent,
        max_queue: args.max_queue,
        rate_per_min: args.rate_limit,
        max_duration: (args.max_duration > 0).then_some(args.max_duration),
        cookies: args.cookies,
        admin_token: args.admin_token,
    };
    match api::serve(cfg).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("✖ Server selhal: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Vyřeší cestu ke skriptu z argumentu nebo autodetekcí; jinak vrátí exit kód 2.
fn resolve_script(explicit: Option<PathBuf>) -> Result<PathBuf, ExitCode> {
    if let Some(p) = explicit {
        return Ok(p);
    }
    match locate_script() {
        Some(p) => Ok(p),
        None => {
            eprintln!(
                "✖ Nepodařilo se najít 'downloader.py'. \
                 Zadejte cestu přes --script nebo proměnnou YTMP_SCRIPT."
            );
            Err(ExitCode::from(2))
        }
    }
}

/// Vybere dostupný Python interpret (preferuje python3).
fn detect_python() -> String {
    for candidate in ["python3", "python"] {
        if which(candidate).is_some() {
            return candidate.to_string();
        }
    }
    "python3".to_string()
}

/// Najde downloader.py: env YTMP_SCRIPT -> typické relativní cesty.
fn locate_script() -> Option<PathBuf> {
    if let Ok(env_path) = std::env::var("YTMP_SCRIPT") {
        let p = PathBuf::from(env_path);
        if p.exists() {
            return Some(p);
        }
    }

    let candidates = [
        PathBuf::from("python_core/downloader.py"),
        PathBuf::from("../python_core/downloader.py"),
        PathBuf::from("../../python_core/downloader.py"),
    ];

    for rel in &candidates {
        if rel.exists() {
            return rel.canonicalize().ok().or_else(|| Some(rel.clone()));
        }
    }

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for rel in &candidates {
                let joined = dir.join(rel);
                if joined.exists() {
                    return joined.canonicalize().ok().or(Some(joined));
                }
            }
        }
    }

    None
}

/// Minimalistická náhrada `which`: hledá spustitelný soubor v PATH.
fn which(cmd: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join(cmd);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}
