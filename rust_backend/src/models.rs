//! Datové modely sdílené napříč jádrem.
//!
//! Obsahuje jak konfiguraci aplikace (`AppConfig`, `MediaFormat`), tak typy
//! pro deserializaci JSON progress streamu, který produkuje Python worker
//! (`ProgressEvent`).

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Cílový formát konverze.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaFormat {
    Mp3,
    Mp4,
}

impl MediaFormat {
    /// Hodnota přesně tak, jak ji očekává `downloader.py` v argumentu `--format`.
    pub fn as_arg(self) -> &'static str {
        match self {
            MediaFormat::Mp3 => "mp3",
            MediaFormat::Mp4 => "mp4",
        }
    }
}

impl std::str::FromStr for MediaFormat {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "mp3" => Ok(MediaFormat::Mp3),
            "mp4" => Ok(MediaFormat::Mp4),
            other => Err(format!(
                "neznámý formát '{other}', povolené hodnoty jsou: mp3, mp4"
            )),
        }
    }
}

impl std::fmt::Display for MediaFormat {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_arg())
    }
}

/// Konfigurace jedné stahovací úlohy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    /// Zdrojové YouTube URL (video nebo playlist).
    pub url: String,
    /// Požadovaný výstupní formát.
    pub format: MediaFormat,
    /// Cílový adresář pro uložení.
    pub output_dir: PathBuf,
    /// Maximální počet souběžně běžících úloh ve frontě.
    pub concurrency: usize,
}

/// Jedna položka fronty (URL + sdílený formát/výstup z `AppConfig`).
#[derive(Debug, Clone)]
pub struct Job {
    pub url: String,
    pub format: MediaFormat,
    pub output_dir: PathBuf,
    /// Max. povolená délka videa v sekundách (None = bez limitu).
    pub max_duration: Option<u64>,
    /// Volitelný cookies soubor pro yt-dlp (obejití bot-check na YouTube).
    pub cookies: Option<PathBuf>,
}

/// Událost progressu deserializovaná z jednoho JSON řádku Python workeru.
///
/// `#[serde(tag = "status")]` znamená, že pole `status` v JSONu určuje variantu.
/// Neznámé/budoucí stavy spadnou do `Unknown` místo selhání deserializace.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "status", rename_all = "lowercase")]
// Některá pole se zatím jen deserializují (jsou součástí drátového kontraktu
// pro budoucí API vrstvu), proto tlumíme dead_code pro celý enum.
#[allow(dead_code)]
pub enum ProgressEvent {
    /// Úloha startuje.
    Starting { url: String },

    /// Metadata získaná před stažením.
    Metadata {
        title: String,
        #[serde(default)]
        duration: Option<f64>,
        #[serde(default)]
        uploader: Option<String>,
        #[serde(default)]
        is_playlist: bool,
    },

    /// Průběžný stav stahování.
    Downloading {
        progress: f64,
        #[serde(default)]
        speed: String,
        #[serde(default)]
        eta: String,
        #[serde(default)]
        downloaded_bytes: u64,
        #[serde(default)]
        total_bytes: u64,
    },

    /// Běží postprocessing (extrakce audia, remux, ...).
    Processing {
        #[serde(default)]
        postprocessor: String,
    },

    /// Úloha úspěšně dokončena.
    Finished {
        #[serde(default)]
        filepath: String,
    },

    /// Chyba reportovaná workerem.
    Error { error: String },

    /// Záchytná varianta pro neznámé stavy (dopředná kompatibilita).
    #[serde(other)]
    Unknown,
}
