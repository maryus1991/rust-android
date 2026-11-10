//! The ONLY Rust command reachable from web content.
//!
//! Defence in depth:
//!  1. capabilities/ grants `allow-bridge` to the main window for the configured
//!     origins only (generated from config/app.json);
//!  2. here, every call re-checks the page URL with the exact-match policy;
//!  3. a static action table decides which origin kind and which feature flag
//!     each action requires. Unknown actions are rejected.

use crate::config::Features;
use crate::security::{self, NavDecision};
use crate::state::AppState;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Arc;
use tauri::{AppHandle, State, Url, Webview};

#[derive(Debug, Deserialize)]
pub struct BridgeRequest {
    pub action: String,
    #[serde(default)]
    pub payload: Value,
}

#[derive(Debug, Serialize)]
pub struct BridgeError {
    pub code: &'static str,
    pub message: String,
}

fn err(code: &'static str, message: impl Into<String>) -> BridgeError {
    BridgeError {
        code,
        message: message.into(),
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Origin {
    /// Bundled pages (offline / error).
    Local,
    /// A page whose URL passes the domain allowlist.
    Remote,
}

pub fn origin_of(url: &Url, st: &AppState) -> Option<Origin> {
    if security::is_internal(url) {
        Some(Origin::Local)
    } else if st.policy.is_allowed(url) {
        Some(Origin::Remote)
    } else {
        None
    }
}

struct Spec {
    remote: bool,
    local: bool,
    feature: Option<&'static str>,
}

fn spec(action: &str) -> Option<Spec> {
    let s = |remote, local, feature| {
        Some(Spec {
            remote,
            local,
            feature,
        })
    };
    match action {
        "page.ready" | "page.keepalive" => s(true, false, None),
        "app.info" | "network.status" => s(true, true, None),
        "network.retry" => s(false, true, None),
        "app.openExternal" => s(true, false, Some("externalApps")),
        "clipboard.writeText" => s(true, false, Some("clipboard")),
        "notification.permission" | "notification.request" | "notification.show" => {
            s(true, false, Some("notifications"))
        }
        _ => None,
    }
}

pub fn authorize(action: &str, origin: Option<Origin>, st: &AppState) -> Result<(), BridgeError> {
    let Some(spec) = spec(action) else {
        return Err(err("unknown-action", format!("unknown action '{action}'")));
    };
    let Some(origin) = origin else {
        return Err(err(
            "origin-denied",
            "this page is not allowed to use the bridge",
        ));
    };
    let origin_ok = match origin {
        Origin::Remote => spec.remote,
        Origin::Local => spec.local,
    };
    if !origin_ok {
        return Err(err(
            "origin-denied",
            format!("'{action}' is not available to this page"),
        ));
    }
    if let Some(feature) = spec.feature {
        if !st.cfg.features.is_enabled(feature) {
            return Err(err(
                "feature-disabled",
                format!("feature '{feature}' is disabled in config/app.json"),
            ));
        }
    }
    Ok(())
}

pub fn features_json(f: &Features) -> Value {
    json!({
        "fileUpload": f.file_upload, "camera": f.camera, "microphone": f.microphone,
        "geolocation": f.geolocation, "downloads": f.downloads, "notifications": f.notifications,
        "clipboard": f.clipboard, "externalApps": f.external_apps, "fullscreen": f.fullscreen,
        "networkMonitoring": f.network_monitoring, "multipleWindows": f.multiple_windows,
        "paymentHandoff": f.payment_handoff
    })
}

#[tauri::command]
pub async fn bridge(
    app: AppHandle,
    webview: Webview,
    state: State<'_, Arc<AppState>>,
    request: BridgeRequest,
) -> Result<Value, BridgeError> {
    let st: Arc<AppState> = state.inner().clone();
    let url = webview
        .url()
        .map_err(|_| err("origin-denied", "cannot determine the page origin"))?;
    authorize(&request.action, origin_of(&url, &st), &st)?;
    dispatch(app, st, request).await
}

fn str_field<'a>(payload: &'a Value, key: &str, max: usize) -> Result<&'a str, BridgeError> {
    let v = payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| err("bad-request", format!("'{key}' must be a string")))?;
    if v.chars().count() > max {
        return Err(err("bad-request", format!("'{key}' is too long")));
    }
    Ok(v)
}

async fn dispatch(
    app: AppHandle,
    st: Arc<AppState>,
    req: BridgeRequest,
) -> Result<Value, BridgeError> {
    let ok = || Ok(json!({ "ok": true }));
    match req.action.as_str() {
        "page.ready" => {
            st.sup.on_ready();
            ok()
        }
        "page.keepalive" => {
            st.sup.on_keepalive(
                req.payload
                    .get("hidden")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            );
            ok()
        }
        "app.info" => Ok(json!({
            "name": st.cfg.app.name,
            "version": st.cfg.app.version,
            "platform": std::env::consts::OS,
            "language": st.cfg.app.default_language,
            "theme": st.cfg.app.default_theme,
            "siteName": st.cfg.site.name,
            "siteUrl": st.start_url.as_str(),
            "features": features_json(&st.cfg.features),
        })),
        "network.status" => {
            let st2 = st.clone();
            let r = tauri::async_runtime::spawn_blocking(move || st2.probe_site())
                .await
                .map_err(|e| err("internal", e.to_string()))?;
            Ok(json!({ "online": r.is_online(), "reason": r.reason() }))
        }
        "network.retry" => {
            let (app2, st2) = (app.clone(), st.clone());
            let r = tauri::async_runtime::spawn_blocking(move || {
                crate::supervisor::retry_now(&app2, &st2)
            })
            .await
            .map_err(|e| err("internal", e.to_string()))?;
            Ok(json!({ "online": r.is_online(), "reason": r.reason() }))
        }
        "app.openExternal" => {
            let raw = str_field(&req.payload, "url", 4096)?;
            let url = Url::parse(raw).map_err(|_| err("bad-request", "invalid URL"))?;
            match security::decide(&url, &st.policy, &st.cfg.security, &st.cfg.features) {
                NavDecision::OpenExternal => {
                    crate::window::open_external(&app, &st, &url);
                    ok()
                }
                NavDecision::Allow => Err(err(
                    "bad-request",
                    "URL is inside the app scope; navigate to it normally",
                )),
                NavDecision::Block => {
                    Err(err("blocked", "this URL scheme or target is not allowed"))
                }
            }
        }
        "clipboard.writeText" => {
            use tauri_plugin_clipboard_manager::ClipboardExt;
            let text = str_field(&req.payload, "text", 1_000_000)?;
            app.clipboard()
                .write_text(text.to_string())
                .map_err(|e| err("clipboard", e.to_string()))?;
            ok()
        }
        "notification.permission" | "notification.request" | "notification.show" => {
            notification(&app, &st, &req)
        }
        other => Err(err("unknown-action", format!("unknown action '{other}'"))),
    }
}

fn perm_str(p: tauri_plugin_notification::PermissionState) -> &'static str {
    use tauri_plugin_notification::PermissionState::*;
    match p {
        Granted => "granted",
        Denied => "denied",
        _ => "default",
    }
}

fn notification(app: &AppHandle, st: &AppState, req: &BridgeRequest) -> Result<Value, BridgeError> {
    use tauri_plugin_notification::NotificationExt;
    let n = app.notification();
    match req.action.as_str() {
        "notification.permission" => {
            let p = n
                .permission_state()
                .map_err(|e| err("notification", e.to_string()))?;
            Ok(json!(perm_str(p)))
        }
        "notification.request" => {
            let p = n
                .request_permission()
                .map_err(|e| err("notification", e.to_string()))?;
            Ok(json!(perm_str(p)))
        }
        _ => {
            let title = str_field(&req.payload, "title", 200)?;
            let body = req
                .payload
                .get("body")
                .and_then(Value::as_str)
                .unwrap_or("");
            if body.chars().count() > 2000 {
                return Err(err("bad-request", "'body' is too long"));
            }
            let key = req
                .payload
                .get("tag")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| format!("{title}\u{1}{body}"));
            let granted = matches!(
                n.permission_state(),
                Ok(tauri_plugin_notification::PermissionState::Granted)
            );
            if !granted {
                return Err(err(
                    "permission-denied",
                    "notification permission has not been granted",
                ));
            }
            if !st.allow_notification(&key) {
                return Ok(json!({ "ok": true, "deduplicated": true }));
            }
            n.builder()
                .title(title)
                .body(body)
                .show()
                .map_err(|e| err("notification", e.to_string()))?;
            Ok(json!({ "ok": true }))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config;

    fn state_with(f: impl FnOnce(&mut config::AppConfig)) -> AppState {
        let mut cfg = config::embedded().unwrap();
        f(&mut cfg);
        AppState::new(cfg).unwrap()
    }

    fn u(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    #[test]
    fn origin_kinds() {
        let st = state_with(|_| {});
        assert_eq!(
            origin_of(&u("https://example.com/x"), &st),
            Some(Origin::Remote)
        );
        assert_eq!(
            origin_of(&u("tauri://localhost/offline.html"), &st),
            Some(Origin::Local)
        );
        assert_eq!(origin_of(&u("https://evil.com/"), &st), None);
        assert_eq!(origin_of(&u("https://example.com.evil.com/"), &st), None);
    }

    #[test]
    fn unknown_origin_and_actions_are_rejected() {
        let st = state_with(|_| {});
        assert!(authorize("page.ready", None, &st).is_err());
        assert!(authorize("fs.readFile", Some(Origin::Remote), &st).is_err());
        assert!(authorize("", Some(Origin::Remote), &st).is_err());
        assert!(authorize("plugin:fs|read_file", Some(Origin::Remote), &st).is_err());
    }

    #[test]
    fn origin_kind_restrictions() {
        let st = state_with(|c| c.features.notifications = true);
        assert!(authorize("page.ready", Some(Origin::Remote), &st).is_ok());
        assert!(authorize("page.ready", Some(Origin::Local), &st).is_err());
        assert!(authorize("network.retry", Some(Origin::Local), &st).is_ok());
        assert!(authorize("network.retry", Some(Origin::Remote), &st).is_err());
        assert!(authorize("notification.show", Some(Origin::Local), &st).is_err());
        assert!(authorize("notification.show", Some(Origin::Remote), &st).is_ok());
    }

    #[test]
    fn disabled_features_are_rejected() {
        let off = state_with(|c| {
            c.features.notifications = false;
            c.features.clipboard = false;
            c.features.external_apps = false;
        });
        for a in [
            "notification.show",
            "notification.request",
            "clipboard.writeText",
            "app.openExternal",
        ] {
            assert_eq!(
                authorize(a, Some(Origin::Remote), &off).unwrap_err().code,
                "feature-disabled",
                "{a}"
            );
        }
        let on = state_with(|c| c.features.clipboard = true);
        assert!(authorize("clipboard.writeText", Some(Origin::Remote), &on).is_ok());
    }

    #[test]
    fn dedupe_notifications() {
        let st = state_with(|_| {});
        assert!(st.allow_notification("a"));
        assert!(!st.allow_notification("a"));
        assert!(st.allow_notification("b"));
    }
}
