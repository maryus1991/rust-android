//! Shared application state.

use crate::config::{AppConfig, ConfigError};
use crate::network::{self, Reachability};
use crate::security::DomainPolicy;
use crate::supervisor::Supervisor;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::Url;

pub struct AppState {
    pub cfg: AppConfig,
    pub policy: DomainPolicy,
    pub start_url: Url,
    pub site_host: String,
    pub site_port: u16,
    pub last_url: Mutex<Option<Url>>,
    pub last_external: Mutex<Option<(String, Instant)>>,
    pub notif_seen: Mutex<HashMap<String, Instant>>,
    pub sup: Supervisor,
}

impl AppState {
    pub fn new(cfg: AppConfig) -> Result<Self, ConfigError> {
        let policy = DomainPolicy::from_config(&cfg)?;
        let start_url =
            Url::parse(&cfg.site.url).map_err(|e| ConfigError::Invalid(e.to_string()))?;
        let site_host = start_url.host_str().unwrap_or_default().to_string();
        let site_port = start_url.port_or_known_default().unwrap_or(443);
        Ok(Self {
            cfg,
            policy,
            start_url,
            site_host,
            site_port,
            last_url: Mutex::new(None),
            last_external: Mutex::new(None),
            notif_seen: Mutex::new(HashMap::new()),
            sup: Supervisor::new(),
        })
    }

    pub fn probe_site(&self) -> Reachability {
        network::probe(&self.site_host, self.site_port, Duration::from_secs(4))
    }

    /// URL to return to after an error page: the last good in-scope page or the start URL.
    pub fn resume_url(&self) -> Url {
        self.last_url
            .lock()
            .ok()
            .and_then(|g| g.clone())
            .unwrap_or_else(|| self.start_url.clone())
    }

    /// Suppresses the same external URL being opened repeatedly (redirect loops, popup spam).
    pub fn allow_external_open(&self, url: &Url) -> bool {
        let Ok(mut guard) = self.last_external.lock() else {
            return false;
        };
        let now = Instant::now();
        if let Some((last, at)) = guard.as_ref() {
            if last == url.as_str() && now.duration_since(*at) < Duration::from_millis(1500) {
                return false;
            }
        }
        *guard = Some((url.as_str().to_string(), now));
        true
    }

    /// De-duplicates notifications (same key within 3 seconds).
    pub fn allow_notification(&self, key: &str) -> bool {
        let Ok(mut seen) = self.notif_seen.lock() else {
            return false;
        };
        let now = Instant::now();
        seen.retain(|_, at| now.duration_since(*at) < Duration::from_secs(60));
        if let Some(at) = seen.get(key) {
            if now.duration_since(*at) < Duration::from_secs(3) {
                return false;
            }
        }
        seen.insert(key.to_string(), now);
        true
    }
}

/// URL of a bundled page (offline/error) for the current platform's custom protocol.
pub fn local_url(path_and_query: &str) -> Url {
    #[cfg(any(windows, target_os = "android"))]
    let base = "http://tauri.localhost/";
    #[cfg(not(any(windows, target_os = "android")))]
    let base = "tauri://localhost/";
    Url::parse(base)
        .and_then(|b| b.join(path_and_query))
        .expect("valid local url")
}
