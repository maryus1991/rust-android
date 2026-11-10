//! Universal Web2App core.
//!
//! The website is loaded straight into the OS WebView; this crate only adds
//! policy (what may load / open / be granted), recovery and a tiny allowlisted
//! native bridge. See docs/ARCHITECTURE.md.

mod bridge;
mod config;
mod network;
mod security;
mod state;
mod supervisor;
mod window;

use std::sync::Arc;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let cfg = match config::embedded() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[web2app] {e}");
            std::process::exit(2);
        }
    };
    let state = match state::AppState::new(cfg) {
        Ok(s) => Arc::new(s),
        Err(e) => {
            eprintln!("[web2app] {e}");
            std::process::exit(2);
        }
    };

    let mut builder = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_web2app_native::init());
    if state.cfg.features.notifications {
        builder = builder.plugin(tauri_plugin_notification::init());
    }
    if state.cfg.features.clipboard {
        builder = builder.plugin(tauri_plugin_clipboard_manager::init());
    }

    let setup_state = state.clone();
    builder
        .manage(state)
        .invoke_handler(tauri::generate_handler![bridge::bridge])
        .setup(move |app| {
            window::create_main(app.handle(), &setup_state)?;
            supervisor::start(app.handle(), &setup_state);
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Web2App");
}
