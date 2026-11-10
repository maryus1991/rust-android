//! Typed view of `config/app.json` (embedded at build time) + validation.
//!
//! The same file is validated by `scripts/validate.sh` before a build, and again
//! here at start-up, so an invalid configuration can never silently ship.

use serde::Deserialize;
use serde_json::Value;
use thiserror::Error;

const APP_JSON: &str = include_str!("../../config/app.json");
const FEATURES_JSON: &str = include_str!("../../config/features.json");

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("config JSON is malformed: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid configuration: {0}")]
    Invalid(String),
}

fn bad<T>(msg: impl Into<String>) -> Result<T, ConfigError> {
    Err(ConfigError::Invalid(msg.into()))
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppConfig {
    pub app: AppInfo,
    pub site: Site,
    pub appearance: Appearance,
    pub features: Features,
    pub security: SecurityConfig,
    pub behavior: Behavior,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppInfo {
    pub name: String,
    pub identifier: String,
    pub version: String,
    pub description: String,
    pub default_language: String,
    pub default_theme: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Site {
    pub name: String,
    pub url: String,
    pub include_subdomains: bool,
    pub allowed_domains: Vec<String>,
    pub user_agent: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Appearance {
    pub primary_color: String,
    pub background_color: String,
    pub splash_color: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Features {
    pub file_upload: bool,
    pub camera: bool,
    pub microphone: bool,
    pub geolocation: bool,
    pub downloads: bool,
    pub notifications: bool,
    pub clipboard: bool,
    pub external_apps: bool,
    pub fullscreen: bool,
    pub network_monitoring: bool,
    pub multiple_windows: bool,
    pub payment_handoff: bool,
}

impl Features {
    /// Look a feature up by its config key (used by the bridge action table).
    pub fn is_enabled(&self, key: &str) -> bool {
        match key {
            "fileUpload" => self.file_upload,
            "camera" => self.camera,
            "microphone" => self.microphone,
            "geolocation" => self.geolocation,
            "downloads" => self.downloads,
            "notifications" => self.notifications,
            "clipboard" => self.clipboard,
            "externalApps" => self.external_apps,
            "fullscreen" => self.fullscreen,
            "networkMonitoring" => self.network_monitoring,
            "multipleWindows" => self.multiple_windows,
            "paymentHandoff" => self.payment_handoff,
            _ => false,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SecurityConfig {
    pub https_only: bool,
    pub out_of_scope_links: String,
    pub external_schemes: Vec<String>,
    pub payment_schemes: Vec<String>,
}

impl Default for SecurityConfig {
    fn default() -> Self {
        Self {
            https_only: true,
            out_of_scope_links: "system-browser".into(),
            external_schemes: vec!["tel".into(), "mailto".into(), "sms".into()],
            payment_schemes: vec![],
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Behavior {
    pub load_timeout_secs: u64,
    pub hang_timeout_secs: u64,
    pub crash_watchdog: bool,
    pub max_auto_recoveries: usize,
}

impl Default for Behavior {
    fn default() -> Self {
        Self {
            load_timeout_secs: 20,
            hang_timeout_secs: 120,
            crash_watchdog: true,
            max_auto_recoveries: 3,
        }
    }
}

/// The configuration compiled into this binary.
pub fn embedded() -> Result<AppConfig, ConfigError> {
    parse_and_validate(APP_JSON)
}

pub fn parse_and_validate(json: &str) -> Result<AppConfig, ConfigError> {
    let raw: Value = serde_json::from_str(json)?;
    check_feature_flags(&raw)?;
    let cfg: AppConfig = serde_json::from_value(raw)?;
    validate(&cfg)?;
    Ok(cfg)
}

/// Rejects unknown feature keys and any feature whose registry status is `planned`.
fn check_feature_flags(raw: &Value) -> Result<(), ConfigError> {
    let registry: Value = serde_json::from_str(FEATURES_JSON)?;
    let known = registry.get("features").and_then(Value::as_object);
    let Some(flags) = raw.get("features").and_then(Value::as_object) else {
        return Ok(());
    };
    for (key, value) in flags {
        let Some(entry) = known.and_then(|k| k.get(key)) else {
            return bad(format!("unknown feature '{key}' in features"));
        };
        let enabled = value.as_bool().unwrap_or(false);
        let status = entry.get("status").and_then(Value::as_str).unwrap_or("");
        if enabled && status == "planned" {
            return bad(format!(
                "feature '{key}' is not implemented in this release (status: planned) and cannot be enabled"
            ));
        }
    }
    Ok(())
}

fn is_hex_color(s: &str) -> bool {
    s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|c| c.is_ascii_hexdigit())
}

fn is_identifier(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() >= 2
        && parts.iter().all(|p| {
            let mut ch = p.chars();
            matches!(ch.next(), Some(c) if c.is_ascii_alphabetic())
                && ch.all(|c| c.is_ascii_alphanumeric() || c == '_')
        })
}

fn is_semver(s: &str) -> bool {
    let core = s.split(['-', '+']).next().unwrap_or("");
    let nums: Vec<&str> = core.split('.').collect();
    nums.len() == 3
        && nums
            .iter()
            .all(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

pub fn validate(cfg: &AppConfig) -> Result<(), ConfigError> {
    if cfg.app.name.trim().is_empty() {
        return bad("app.name must not be empty");
    }
    if !is_identifier(&cfg.app.identifier) {
        return bad("app.identifier must look like com.company.app (letters, digits, underscore; each part starts with a letter)");
    }
    if !is_semver(&cfg.app.version) {
        return bad("app.version must be a semantic version such as 1.0.0");
    }
    let url = tauri::Url::parse(&cfg.site.url)
        .map_err(|e| ConfigError::Invalid(format!("site.url is not a valid URL: {e}")))?;
    if url.host_str().is_none() {
        return bad("site.url must contain a host name");
    }
    if !url.username().is_empty() || url.password().is_some() {
        return bad("site.url must not contain credentials");
    }
    match url.scheme() {
        "https" => {}
        "http" if !cfg.security.https_only => {}
        _ => return bad("site.url must use https (set security.httpsOnly=false to allow http)"),
    }
    for entry in &cfg.site.allowed_domains {
        crate::security::parse_domain_entry(entry)
            .map_err(|e| ConfigError::Invalid(format!("site.allowedDomains: {e}")))?;
    }
    for (name, color) in [
        ("appearance.primaryColor", &cfg.appearance.primary_color),
        (
            "appearance.backgroundColor",
            &cfg.appearance.background_color,
        ),
        ("appearance.splashColor", &cfg.appearance.splash_color),
    ] {
        if !is_hex_color(color) {
            return bad(format!("{name} must be a #RRGGBB color"));
        }
    }
    if !matches!(
        cfg.security.out_of_scope_links.as_str(),
        "system-browser" | "block"
    ) {
        return bad("security.outOfScopeLinks must be 'system-browser' or 'block'");
    }
    for s in cfg
        .security
        .external_schemes
        .iter()
        .chain(&cfg.security.payment_schemes)
    {
        if crate::security::ALWAYS_BLOCKED_SCHEMES.contains(&s.as_str()) {
            return bad(format!(
                "scheme '{s}' is always blocked and cannot be allowlisted"
            ));
        }
        if s.is_empty()
            || !s
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "+-.".contains(c))
        {
            return bad(format!("invalid URL scheme '{s}'"));
        }
    }
    if !(5..=120).contains(&cfg.behavior.load_timeout_secs) {
        return bad("behavior.loadTimeoutSecs must be between 5 and 120");
    }
    if !(30..=3600).contains(&cfg.behavior.hang_timeout_secs) {
        return bad("behavior.hangTimeoutSecs must be between 30 and 3600");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_config_is_valid() {
        embedded().expect("config/app.json must validate");
    }

    #[test]
    fn rejects_planned_feature() {
        let mut v: Value = serde_json::from_str(APP_JSON).unwrap();
        v["features"]["biometric"] = Value::Bool(true);
        assert!(parse_and_validate(&v.to_string()).is_err());
    }

    #[test]
    fn rejects_unknown_feature() {
        let mut v: Value = serde_json::from_str(APP_JSON).unwrap();
        v["features"]["teleport"] = Value::Bool(true);
        assert!(parse_and_validate(&v.to_string()).is_err());
    }

    #[test]
    fn rejects_http_when_https_only() {
        let mut v: Value = serde_json::from_str(APP_JSON).unwrap();
        v["site"]["url"] = Value::String("http://example.com".into());
        assert!(parse_and_validate(&v.to_string()).is_err());
    }

    #[test]
    fn rejects_bad_identifier_version_color() {
        for (path, val) in [
            ("identifier", "bad id"),
            ("identifier", "single"),
            ("version", "1.0"),
        ] {
            let mut v: Value = serde_json::from_str(APP_JSON).unwrap();
            v["app"][path] = Value::String(val.into());
            assert!(parse_and_validate(&v.to_string()).is_err(), "{path}={val}");
        }
        let mut v: Value = serde_json::from_str(APP_JSON).unwrap();
        v["appearance"]["primaryColor"] = Value::String("blue".into());
        assert!(parse_and_validate(&v.to_string()).is_err());
    }

    #[test]
    fn rejects_dangerous_scheme_allowlist() {
        let mut v: Value = serde_json::from_str(APP_JSON).unwrap();
        v["security"]["externalSchemes"] = serde_json::json!(["tel", "javascript"]);
        assert!(parse_and_validate(&v.to_string()).is_err());
    }
}
