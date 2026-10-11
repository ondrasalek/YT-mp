// Skryj konzolové okno na Windows v release buildu.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod downloader;

use std::collections::HashMap;
use std::sync::Mutex;

use tauri::{Emitter, Manager, State};
use tokio::sync::oneshot;

/// Běžící úlohy -> kanál pro jejich zrušení.
#[derive(Default)]
struct Jobs(Mutex<HashMap<String, oneshot::Sender<()>>>);

/// Spustí novou konverzní úlohu. Vrací `job_id`, pod kterým frontend
/// odebírá události `ytmp:progress`.
#[tauri::command]
async fn start_job(
    app: tauri::AppHandle,
    jobs: State<'_, Jobs>,
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
    let (tx, rx) = oneshot::channel();
    jobs.0.lock().unwrap().insert(job_id.clone(), tx);
    tauri::async_runtime::spawn(async move {
        downloader::run_job(app.clone(), id.clone(), url, format, output_dir, browser, rx).await;
        app.state::<Jobs>().0.lock().unwrap().remove(&id);
    });
    Ok(job_id)
}

/// Zruší běžící úlohu (zabije yt-dlp proces).
#[tauri::command]
fn cancel_job(jobs: State<'_, Jobs>, job_id: String) {
    if let Some(tx) = jobs.0.lock().unwrap().remove(&job_id) {
        let _ = tx.send(());
    }
}

/// Vlastní menu pro macOS: do app menu (vedle  Apple) přidá „Settings…"
/// (⌘,), který otevře nastavení ve frontendu. Zbytek (Edit/Window) je
/// standardní, ať fungují systémové zkratky (kopírovat/vložit v poli URL).
#[cfg(target_os = "macos")]
fn build_menu(app: &tauri::AppHandle) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    use tauri::menu::{AboutMetadataBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder};

    let settings = MenuItemBuilder::new("Settings…")
        .id("settings")
        .accelerator("Cmd+,")
        .build(app)?;

    let about = AboutMetadataBuilder::new()
        .name(Some("YT-mp".to_string()))
        .version(Some(env!("CARGO_PKG_VERSION").to_string()))
        .build();

    let app_menu = SubmenuBuilder::new(app, "YT-mp")
        .about(Some(about))
        .separator()
        .item(&settings)
        .separator()
        .services()
        .separator()
        .hide()
        .hide_others()
        .show_all()
        .separator()
        .quit()
        .build()?;

    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;

    let window_menu = SubmenuBuilder::new(app, "Window")
        .minimize()
        .separator()
        .close_window()
        .build()?;

    MenuBuilder::new(app)
        .items(&[&app_menu, &edit_menu, &window_menu])
        .build()
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(Jobs::default())
        .invoke_handler(tauri::generate_handler![start_job, cancel_job])
        .setup(|app| {
            // Vlastní menu jen na macOS (jiné platformy mají gear v okně).
            #[cfg(target_os = "macos")]
            {
                let menu = build_menu(app.handle())?;
                app.set_menu(menu)?;
            }
            let _ = app;
            Ok(())
        })
        .on_menu_event(|app, event| {
            if event.id().as_ref() == "settings" {
                let _ = app.emit("ytmp:open-settings", ());
            }
        })
        .run(tauri::generate_context!())
        .expect("chyba při spuštění Tauri aplikace");
}
