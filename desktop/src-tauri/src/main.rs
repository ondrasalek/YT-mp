// Skryj konzolové okno na Windows v release buildu.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod downloader;

/// Spustí novou konverzní úlohu. Vrací `job_id`, pod kterým frontend
/// odebírá události `ytmp:progress`.
#[tauri::command]
async fn start_job(
    app: tauri::AppHandle,
    url: String,
    format: String,
    output_dir: String,
    browser: Option<String>,
) -> Result<String, String> {
    if url.trim().is_empty() {
        return Err("Prázdné URL.".into());
    }
    if output_dir.trim().is_empty() {
        return Err("Není zvolená cílová složka.".into());
    }
    let job_id = uuid::Uuid::new_v4().to_string();
    let id = job_id.clone();
    tauri::async_runtime::spawn(async move {
        downloader::run_job(app, id, url, format, output_dir, browser).await;
    });
    Ok(job_id)
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![start_job])
        .run(tauri::generate_context!())
        .expect("chyba při spuštění Tauri aplikace");
}
