//! Web2App native helpers.
//!
//! * Android: registers the Kotlin `NativePlugin` (download handling).
//!   Manifest permissions for enabled features are merged by Gradle from
//!   `android/src/main/AndroidManifest.xml`, which `scripts/sync-config.sh` generates.
//! * Desktop / iOS: intentionally a no-op (desktop downloads are handled in the
//!   core crate through the Tauri `on_download` hook).

use serde::Deserialize;
use tauri::{
    plugin::{Builder, TauriPlugin},
    Runtime,
};

/// Plugin configuration read from `plugins.web2app-native` in tauri.conf.json.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    #[serde(default = "default_true")]
    pub downloads: bool,
    #[serde(default)]
    pub status_bar_color: Option<String>,
    #[serde(default)]
    pub navigation_bar_color: Option<String>,
}

fn default_true() -> bool {
    true
}

/// Initializes the plugin.
pub fn init<R: Runtime>() -> TauriPlugin<R, Config> {
    Builder::<R, Config>::new("web2app-native")
        .setup(|_app, _api| {
            #[cfg(target_os = "android")]
            _api.register_android_plugin("com.web2app.nativeplugin", "NativePlugin")?;
            Ok(())
        })
        .build()
}
