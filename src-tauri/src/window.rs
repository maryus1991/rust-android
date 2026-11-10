//! Main window construction: navigation policy, popups, downloads, permissions.

use crate::bridge::features_json;
use crate::security::{self, NavDecision};
use crate::state::AppState;
use crate::supervisor;
use std::path::PathBuf;
use std::sync::Arc;
use tauri::webview::{DownloadEvent, PageLoadEvent, PermissionKind, PermissionResponse};
use tauri::window::Color;
use tauri::{AppHandle, Manager, Url, WebviewUrl, WebviewWindowBuilder, Wry};

type Builder<'a> = WebviewWindowBuilder<'a, Wry, AppHandle>;

const SPLASH_LOGO: &[u8] = include_bytes!("../splash-logo.png");
const BRIDGE_JS: &str = include_str!("bridge.js");

fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            T[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

pub fn bridge_script(st: &AppState) -> String {
    // A 1x1 placeholder logo (<=100 bytes) means "no logo".
    let logo = if SPLASH_LOGO.len() > 200 {
        format!("data:image/png;base64,{}", base64(SPLASH_LOGO))
    } else {
        String::new()
    };
    let cfg = serde_json::json!({
        "platform": std::env::consts::OS,
        "features": features_json(&st.cfg.features),
        "splash": { "enabled": true, "color": st.cfg.appearance.splash_color, "logo": logo },
    });
    BRIDGE_JS.replace("__W2A_CONFIG__", &cfg.to_string())
}

fn parse_color(hex: &str) -> Option<Color> {
    let h = hex.strip_prefix('#')?;
    let v = u32::from_str_radix(h, 16).ok()?;
    Some(Color((v >> 16) as u8, (v >> 8) as u8, v as u8, 255))
}

/// Opens a URL with the OS (browser / dialer / mail client...). Rate limited.
pub fn open_external(app: &AppHandle, st: &AppState, url: &Url) {
    use tauri_plugin_opener::OpenerExt;
    if !st.allow_external_open(url) {
        return;
    }
    if let Err(e) = app.opener().open_url(url.as_str(), None::<&str>) {
        log::warn!("could not open external URL ({}): {e}", url.scheme());
    }
}

/// Decision for web permission prompts (camera, microphone, geolocation ...).
/// `Default` hands over to the platform's own consent flow (OS/WebView prompt);
/// on Linux that default is "deny" (see docs/LIMITATIONS.md). Everything the
/// config does not explicitly enable is denied.
pub fn permission_decision(
    st: &AppState,
    url: Option<&Url>,
    kind: PermissionKind,
) -> PermissionResponse {
    let Some(url) = url else {
        return PermissionResponse::Deny;
    };
    if !st.policy.is_allowed(url) {
        return PermissionResponse::Deny;
    }
    let f = &st.cfg.features;
    let enabled = match kind {
        PermissionKind::Camera => f.camera,
        PermissionKind::Microphone => f.microphone,
        PermissionKind::Geolocation => f.geolocation,
        _ => false,
    };
    if enabled {
        PermissionResponse::Default
    } else {
        PermissionResponse::Deny
    }
}

fn unique_path(dir: &std::path::Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s.to_string(), format!(".{e}")),
        _ => (name.to_string(), String::new()),
    };
    for n in 1..1000 {
        let c = dir.join(format!("{stem} ({n}){ext}"));
        if !c.exists() {
            return c;
        }
    }
    dir.join(format!("{stem}-{}{ext}", std::process::id()))
}

fn configure<'a>(mut b: Builder<'a>, app: &AppHandle, st: &Arc<AppState>) -> Builder<'a> {
    b = b.initialization_script(bridge_script(st));
    if !st.cfg.site.user_agent.trim().is_empty() {
        b = b.user_agent(st.cfg.site.user_agent.trim());
    }
    if let Some(c) = parse_color(&st.cfg.appearance.background_color) {
        b = b.background_color(c);
    }

    // --- navigation policy -------------------------------------------------
    let (ah, s) = (app.clone(), st.clone());
    b = b.on_navigation(move |url| {
        match security::decide(url, &s.policy, &s.cfg.security, &s.cfg.features) {
            NavDecision::Allow => true,
            NavDecision::OpenExternal => {
                open_external(&ah, &s, url);
                false
            }
            NavDecision::Block => {
                log::warn!(
                    "blocked navigation to {}://{}",
                    url.scheme(),
                    url.host_str().unwrap_or("")
                );
                false
            }
        }
    });

    // --- page load tracking (watchdog) ---------------------------------------
    let (ah, s) = (app.clone(), st.clone());
    b = b.on_page_load(move |_wv, payload| match payload.event() {
        PageLoadEvent::Started => supervisor::on_load_started(&ah, &s, payload.url()),
        PageLoadEvent::Finished => supervisor::on_load_finished(&s, payload.url()),
    });

    // --- web permission prompts -------------------------------------------
    let s = st.clone();
    b = b.on_permission_request(move |wv, kind| {
        permission_decision(&s, wv.url().ok().as_ref(), kind)
    });

    // --- downloads (desktop; Android uses the native plugin's DownloadManager) ---
    #[cfg(not(target_os = "android"))]
    {
        let (ah, s) = (app.clone(), st.clone());
        b = b.on_download(move |_wv, event| match event {
            DownloadEvent::Requested { url, destination } => {
                if !s.cfg.features.downloads {
                    log::warn!("download blocked: feature disabled");
                    return false;
                }
                if security::decide(&url, &s.policy, &s.cfg.security, &s.cfg.features)
                    == NavDecision::Block
                {
                    log::warn!("download blocked: {} is not allowed", url.scheme());
                    return false;
                }
                let raw = destination
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("download")
                    .to_string();
                let name = security::sanitize_filename(&raw);
                let dir = ah
                    .path()
                    .download_dir()
                    .or_else(|_| ah.path().temp_dir())
                    .unwrap_or_else(|_| std::env::temp_dir());
                *destination = unique_path(&dir, &name);
                true
            }
            DownloadEvent::Finished { path, success, .. } => {
                log::info!("download finished (success: {success}, path: {path:?})");
                true
            }
            _ => true,
        });
    }

    // --- popups / window.open (desktop only; unsupported by Tauri on mobile) ---
    #[cfg(desktop)]
    {
        use tauri::webview::NewWindowResponse;
        let (ah, s) = (app.clone(), st.clone());
        b = b.on_new_window(move |url, features| {
            match security::decide(&url, &s.policy, &s.cfg.security, &s.cfg.features) {
                NavDecision::OpenExternal => {
                    open_external(&ah, &s, &url);
                    NewWindowResponse::Deny
                }
                NavDecision::Block => NewWindowResponse::Deny,
                NavDecision::Allow => {
                    if !s.cfg.features.multiple_windows || ah.webview_windows().len() >= 8 {
                        // Behave like a mobile browser: open the link in the main window.
                        supervisor::navigate_main(&ah, url);
                        return NewWindowResponse::Deny;
                    }
                    let label = format!(
                        "popup-{}",
                        ah.webview_windows().len() + 1000 + std::process::id() as usize % 1000
                    );
                    let blank = WebviewUrl::External("about:blank".parse().expect("static url"));
                    let builder = WebviewWindowBuilder::new(&ah, label, blank)
                        .window_features(features)
                        .on_document_title_changed(|w, title| {
                            let _ = w.set_title(&title);
                        });
                    match configure(builder, &ah, &s).build() {
                        Ok(window) => NewWindowResponse::Create { window },
                        Err(e) => {
                            log::warn!("could not create popup window: {e}");
                            NewWindowResponse::Deny
                        }
                    }
                }
            }
        });
    }
    b
}

pub fn create_main(app: &AppHandle, st: &Arc<AppState>) -> tauri::Result<()> {
    let builder =
        WebviewWindowBuilder::new(app, "main", WebviewUrl::External(st.start_url.clone()))
            .title(st.cfg.app.name.clone());
    #[cfg(desktop)]
    let builder = builder
        .inner_size(1100.0, 780.0)
        .min_inner_size(360.0, 480.0)
        .theme(match st.cfg.app.default_theme.as_str() {
            "dark" => Some(tauri::Theme::Dark),
            "light" => Some(tauri::Theme::Light),
            _ => None,
        });
    configure(builder, app, st).build()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config;

    fn state(f: impl FnOnce(&mut config::AppConfig)) -> AppState {
        let mut cfg = config::embedded().unwrap();
        f(&mut cfg);
        AppState::new(cfg).unwrap()
    }

    fn u(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    #[test]
    fn permissions_follow_config_and_origin() {
        let st = state(|c| {
            c.features.camera = true;
            c.features.microphone = false;
        });
        let ok = u("https://example.com/");
        let evil = u("https://evil.com/");
        assert_eq!(
            permission_decision(&st, Some(&ok), PermissionKind::Camera),
            PermissionResponse::Default
        );
        assert_eq!(
            permission_decision(&st, Some(&ok), PermissionKind::Microphone),
            PermissionResponse::Deny
        );
        assert_eq!(
            permission_decision(&st, Some(&ok), PermissionKind::Geolocation),
            PermissionResponse::Deny
        );
        assert_eq!(
            permission_decision(&st, Some(&ok), PermissionKind::Notifications),
            PermissionResponse::Deny
        );
        assert_eq!(
            permission_decision(&st, Some(&ok), PermissionKind::ClipboardRead),
            PermissionResponse::Deny
        );
        assert_eq!(
            permission_decision(&st, Some(&evil), PermissionKind::Camera),
            PermissionResponse::Deny
        );
        assert_eq!(
            permission_decision(&st, None, PermissionKind::Camera),
            PermissionResponse::Deny
        );
    }

    #[test]
    fn base64_matches_reference() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn color_parsing() {
        assert!(parse_color("#3b82f6").is_some());
        assert!(parse_color("3b82f6").is_none());
    }

    #[test]
    fn script_contains_no_unreplaced_placeholder() {
        let st = state(|_| {});
        let js = bridge_script(&st);
        assert!(!js.contains("__W2A_CONFIG__"));
        assert!(js.contains("\"notifications\":false"));
    }
}
