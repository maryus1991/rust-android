//! Load watchdog, offline/error pages, reconnect and hang recovery.
//!
//! Tauri/wry expose no cross-platform "load failed" or "renderer crashed"
//! callbacks, so this module works with a *heartbeat*: the injected bridge script
//! reports `page.ready` / `page.keepalive`. WebView-native error pages never run
//! our script, so a missing heartbeat + a failing reachability probe means the
//! page could not be loaded. This is a heuristic, documented as such.
//!
//! Safety rails (no reload storms):
//!  * heartbeat-based decisions only start once IPC is proven to work on the site
//!    (`ipc_ok`), so a site whose CSP blocks IPC is never "recovered" in a loop;
//!  * at most `maxAutoRecoveries` hang recoveries per 5 minutes, then an error page;
//!  * reconnect attempts back off 15s -> 30s -> 60s and never overlap.

use crate::network::Reachability;
use crate::state::{local_url, AppState};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, Url};

pub struct Supervisor {
    generation: AtomicU64,
    ready: AtomicBool,
    ipc_ok: AtomicBool,
    foreground: AtomicBool,
    showing_error: AtomicBool,
    last_beat: Mutex<Instant>,
    recoveries: Mutex<VecDeque<Instant>>,
    reconnect_not_before: Mutex<Instant>,
    reconnect_delay_secs: AtomicU64,
    started: AtomicBool,
}

impl Supervisor {
    pub fn new() -> Self {
        Self {
            generation: AtomicU64::new(0),
            ready: AtomicBool::new(false),
            ipc_ok: AtomicBool::new(false),
            foreground: AtomicBool::new(true),
            showing_error: AtomicBool::new(false),
            last_beat: Mutex::new(Instant::now()),
            recoveries: Mutex::new(VecDeque::new()),
            reconnect_not_before: Mutex::new(Instant::now()),
            reconnect_delay_secs: AtomicU64::new(15),
            started: AtomicBool::new(false),
        }
    }

    /// `page.ready` from the bridge script.
    pub fn on_ready(&self) {
        self.ready.store(true, SeqCst);
        self.ipc_ok.store(true, SeqCst);
        self.showing_error.store(false, SeqCst);
        self.reconnect_delay_secs.store(15, SeqCst);
        self.touch();
    }

    /// `page.keepalive` from the bridge script (`hidden` mirrors document.hidden).
    pub fn on_keepalive(&self, hidden: bool) {
        self.foreground.store(!hidden, SeqCst);
        self.touch();
    }

    fn touch(&self) {
        if let Ok(mut t) = self.last_beat.lock() {
            *t = Instant::now();
        }
    }

    fn since_last_beat(&self) -> Duration {
        self.last_beat
            .lock()
            .map(|t| t.elapsed())
            .unwrap_or_default()
    }
}

impl Default for Supervisor {
    fn default() -> Self {
        Self::new()
    }
}

fn lang(st: &AppState) -> String {
    let l = st.cfg.app.default_language.trim();
    if l.is_empty() {
        "en".into()
    } else {
        l.to_string()
    }
}

pub fn navigate_main(app: &AppHandle, url: Url) {
    if let Some(win) = app.get_webview_window("main") {
        if let Err(e) = win.navigate(url) {
            log::warn!("navigate failed: {e}");
        }
    }
}

/// Shows the bundled offline (network) or error (anything else) page.
pub fn show_error(app: &AppHandle, st: &AppState, reason: &str) {
    st.sup.showing_error.store(true, SeqCst);
    st.sup.ready.store(false, SeqCst);
    let page = match reason {
        "dns" | "unreachable" | "timeout" => "offline.html",
        _ => "error.html",
    };
    log::warn!("showing {page} (reason: {reason})");
    navigate_main(
        app,
        local_url(&format!("{page}?reason={reason}&lang={}", lang(st))),
    );
}

/// Leaves the error page and loads the last good (or start) URL. Idempotent.
pub fn resume(app: &AppHandle, st: &AppState) {
    st.sup.showing_error.store(false, SeqCst);
    st.sup.ready.store(false, SeqCst);
    st.sup.touch();
    navigate_main(app, st.resume_url());
}

pub fn on_load_started(app: &AppHandle, st: &Arc<AppState>, url: &Url) {
    if crate::security::is_internal(url) || !st.cfg.features.network_monitoring {
        return;
    }
    let generation = st.sup.generation.fetch_add(1, SeqCst) + 1;
    st.sup.ready.store(false, SeqCst);
    st.sup.touch();
    let (app, st) = (app.clone(), st.clone());
    std::thread::spawn(move || watchdog_load(app, st, generation));
}

pub fn on_load_finished(st: &AppState, url: &Url) {
    if st.policy.is_allowed(url) {
        if let Ok(mut last) = st.last_url.lock() {
            *last = Some(url.clone());
        }
    }
}

fn watchdog_load(app: AppHandle, st: Arc<AppState>, generation: u64) {
    let wait = Duration::from_secs(st.cfg.behavior.load_timeout_secs);
    for _ in 0..2 {
        std::thread::sleep(wait);
        if st.sup.generation.load(SeqCst) != generation || st.sup.ready.load(SeqCst) {
            return;
        }
        let reach = st.probe_site();
        if reach != Reachability::Online {
            show_error(&app, &st, reach.reason());
            return;
        }
        if !st.sup.ipc_ok.load(SeqCst) {
            // Site reachable but we never saw a heartbeat and IPC is unproven:
            // do not interfere (strict CSP, slow site, WebView error page...).
            return;
        }
    }
    if st.sup.generation.load(SeqCst) == generation && !st.sup.ready.load(SeqCst) {
        show_error(&app, &st, "load-failed");
    }
}

/// Starts the single background monitor (reconnect + hang detection).
pub fn start(app: &AppHandle, st: &Arc<AppState>) {
    if !st.cfg.features.network_monitoring || st.sup.started.swap(true, SeqCst) {
        return;
    }
    let (app, st) = (app.clone(), st.clone());
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(4));
        if st.sup.showing_error.load(SeqCst) {
            maybe_reconnect(&app, &st);
        } else if st.cfg.behavior.crash_watchdog
            && st.sup.ipc_ok.load(SeqCst)
            && st.sup.ready.load(SeqCst)
            && st.sup.foreground.load(SeqCst)
            && st.sup.since_last_beat() > Duration::from_secs(st.cfg.behavior.hang_timeout_secs)
        {
            recover_hang(&app, &st);
        }
    });
}

fn maybe_reconnect(app: &AppHandle, st: &Arc<AppState>) {
    let now = Instant::now();
    let allowed = st
        .sup
        .reconnect_not_before
        .lock()
        .map(|t| now >= *t)
        .unwrap_or(false);
    if !allowed || !st.probe_site().is_online() {
        return;
    }
    let delay = st.sup.reconnect_delay_secs.load(SeqCst);
    if let Ok(mut t) = st.sup.reconnect_not_before.lock() {
        *t = now + Duration::from_secs(delay);
    }
    st.sup
        .reconnect_delay_secs
        .store((delay * 2).min(60), SeqCst);
    log::info!("network is back, reloading the site");
    resume(app, st);
}

fn recover_hang(app: &AppHandle, st: &Arc<AppState>) {
    let allowed = {
        let Ok(mut q) = st.sup.recoveries.lock() else {
            return;
        };
        let now = Instant::now();
        while q
            .front()
            .is_some_and(|t| now.duration_since(*t) > Duration::from_secs(300))
        {
            q.pop_front();
        }
        if q.len() >= st.cfg.behavior.max_auto_recoveries {
            false
        } else {
            q.push_back(now);
            true
        }
    };
    if allowed {
        log::warn!("page stopped responding, reloading");
        resume(app, st);
    } else {
        show_error(app, st, "unresponsive");
    }
}

/// Used by `network.retry` from the offline page.
pub fn retry_now(app: &AppHandle, st: &AppState) -> Reachability {
    let reach = st.probe_site();
    if reach.is_online() {
        resume(app, st);
    }
    reach
}
