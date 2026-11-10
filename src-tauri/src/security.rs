//! Origin / navigation policy. Everything here is pure and unit-tested.
//!
//! Rules of the road:
//!  * hosts are compared EXACTLY (or as a strict `*.suffix` wildcard) after
//!    URL parsing - never with `contains`/`starts_with` on the raw string;
//!  * credentials in URLs, non-default ports and non-HTTPS schemes never match
//!    unless explicitly configured.

use crate::config::{AppConfig, ConfigError, Features, SecurityConfig};
use tauri::Url;

/// Schemes that can never be allowlisted or opened externally.
pub const ALWAYS_BLOCKED_SCHEMES: &[&str] = &[
    "javascript",
    "data",
    "file",
    "content",
    "intent",
    "ftp",
    "view-source",
    "vbscript",
    "ms-msdt",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    host: String,
    wildcard: bool,
    port: Option<u16>,
}

impl Rule {
    fn matches(&self, host: &str) -> bool {
        if self.wildcard {
            host.len() > self.host.len() + 1
                && host.ends_with(&self.host)
                && host.as_bytes()[host.len() - self.host.len() - 1] == b'.'
        } else {
            host == self.host
        }
    }
}

/// Parses `example.com`, `*.example.com`, `example.com:8443`.
pub fn parse_domain_entry(entry: &str) -> Result<Rule, String> {
    let e = entry.trim().to_ascii_lowercase();
    if e.is_empty() {
        return Err("empty domain entry".into());
    }
    if e.contains("://")
        || e.contains('/')
        || e.contains('@')
        || e.contains(' ')
        || e.contains('?')
        || e.contains('#')
    {
        return Err(format!(
            "'{entry}' must be a bare host (no scheme, path, credentials or spaces)"
        ));
    }
    let (wildcard, rest) = match e.strip_prefix("*.") {
        Some(r) => (true, r),
        None => (false, e.as_str()),
    };
    let (host, port) = match rest.rsplit_once(':') {
        Some((h, p)) => {
            let port: u16 = p
                .parse()
                .map_err(|_| format!("'{entry}' has an invalid port"))?;
            (
                h,
                if port == 443 || port == 80 {
                    None
                } else {
                    Some(port)
                },
            )
        }
        None => (rest, None),
    };
    let host = host.trim_end_matches('.');
    let valid = !host.is_empty()
        && host.len() <= 253
        && host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        });
    if !valid || host.contains('*') {
        return Err(format!("'{entry}' is not a valid host name"));
    }
    if wildcard && !host.contains('.') {
        return Err(format!(
            "'{entry}': wildcard on a single label (e.g. *.com) is not allowed"
        ));
    }
    Ok(Rule {
        host: host.to_string(),
        wildcard,
        port,
    })
}

#[derive(Debug, Clone)]
pub struct DomainPolicy {
    rules: Vec<Rule>,
    https_only: bool,
}

impl DomainPolicy {
    pub fn from_config(cfg: &AppConfig) -> Result<Self, ConfigError> {
        let url = Url::parse(&cfg.site.url).map_err(|e| ConfigError::Invalid(e.to_string()))?;
        let host = url
            .host_str()
            .ok_or_else(|| ConfigError::Invalid("site.url has no host".into()))?
            .trim_end_matches('.')
            .to_ascii_lowercase();
        let port = url.port();
        let mut rules = vec![Rule {
            host: host.clone(),
            wildcard: false,
            port,
        }];
        if cfg.site.include_subdomains
            && host.contains('.')
            && host.parse::<std::net::IpAddr>().is_err()
        {
            rules.push(Rule {
                host,
                wildcard: true,
                port,
            });
        }
        for entry in &cfg.site.allowed_domains {
            rules.push(parse_domain_entry(entry).map_err(ConfigError::Invalid)?);
        }
        Ok(Self {
            rules,
            https_only: cfg.security.https_only,
        })
    }

    #[cfg(test)]
    pub fn from_entries(entries: &[&str], https_only: bool) -> Self {
        Self {
            rules: entries
                .iter()
                .map(|e| parse_domain_entry(e).unwrap())
                .collect(),
            https_only,
        }
    }

    pub fn is_allowed(&self, url: &Url) -> bool {
        let scheme_ok = match url.scheme() {
            "https" => true,
            "http" => !self.https_only,
            _ => false,
        };
        if !scheme_ok || !url.username().is_empty() || url.password().is_some() {
            return false;
        }
        let Some(host) = url.host_str() else {
            return false;
        };
        let host = host.trim_end_matches('.').to_ascii_lowercase();
        let port = url.port();
        self.rules
            .iter()
            .any(|r| r.port == port && r.matches(&host))
    }

    /// `https://host[:port]` / `https://*.host` patterns; `build.rs` generates the
    /// remote capability with the same rules and a test asserts they agree.
    #[cfg(test)]
    pub fn capability_patterns(&self) -> Vec<String> {
        let scheme = if self.https_only { "https" } else { "http" };
        self.rules
            .iter()
            .map(|r| {
                let host = if r.wildcard {
                    format!("*.{}", r.host)
                } else {
                    r.host.clone()
                };
                match r.port {
                    Some(p) => format!("{scheme}://{host}:{p}"),
                    None => format!("{scheme}://{host}"),
                }
            })
            .collect()
    }
}

/// Internal (bundled) pages: `tauri://localhost`, `http(s)://tauri.localhost`.
pub fn is_internal(url: &Url) -> bool {
    match url.scheme() {
        "tauri" => url.host_str() == Some("localhost"),
        "http" | "https" => url.host_str() == Some("tauri.localhost") && url.port().is_none(),
        _ => false,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NavDecision {
    Allow,
    OpenExternal,
    Block,
}

pub fn decide(
    url: &Url,
    policy: &DomainPolicy,
    sec: &SecurityConfig,
    feats: &Features,
) -> NavDecision {
    if is_internal(url) || url.as_str() == "about:blank" || policy.is_allowed(url) {
        return NavDecision::Allow;
    }
    let scheme = url.scheme();
    if ALWAYS_BLOCKED_SCHEMES.contains(&scheme) {
        return NavDecision::Block;
    }
    match scheme {
        // blob: URLs carry their creating origin, e.g. blob:https://site/uuid
        "blob" => match Url::parse(url.path()) {
            Ok(inner) if policy.is_allowed(&inner) => NavDecision::Allow,
            _ => NavDecision::Block,
        },
        "http" | "https" => {
            if feats.external_apps && sec.out_of_scope_links == "system-browser" {
                NavDecision::OpenExternal
            } else {
                NavDecision::Block
            }
        }
        s if feats.external_apps && sec.external_schemes.iter().any(|x| x == s) => {
            NavDecision::OpenExternal
        }
        s if feats.payment_handoff && sec.payment_schemes.iter().any(|x| x == s) => {
            NavDecision::OpenExternal
        }
        _ => NavDecision::Block,
    }
}

/// Makes a server-supplied file name safe to use inside the Downloads folder.
pub fn sanitize_filename(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let mut cleaned: String = base
        .chars()
        .map(|c| {
            if c.is_control() || "<>:\"|?*".contains(c) {
                '_'
            } else {
                c
            }
        })
        .collect();
    cleaned = cleaned
        .trim()
        .trim_start_matches('.')
        .trim_end_matches(['.', ' '])
        .to_string();
    let stem = cleaned.split('.').next().unwrap_or("").to_ascii_uppercase();
    let reserved = ["CON", "PRN", "AUX", "NUL"].contains(&stem.as_str())
        || (stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && stem.ends_with(|c: char| c.is_ascii_digit()));
    if cleaned.is_empty() || reserved {
        return "download".to_string();
    }
    if cleaned.chars().count() > 150 {
        let ext = cleaned
            .rsplit_once('.')
            .map(|(_, e)| e.to_string())
            .filter(|e| e.len() <= 10);
        let head: String = cleaned.chars().take(120).collect();
        cleaned = match ext {
            Some(e) => format!("{head}.{e}"),
            None => head,
        };
    }
    cleaned
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    fn policy() -> DomainPolicy {
        DomainPolicy::from_entries(
            &[
                "example.com",
                "*.example.com",
                "pay.other.org",
                "localhost:3000",
            ],
            true,
        )
    }

    #[test]
    fn exact_and_wildcard_hosts() {
        let p = policy();
        assert!(p.is_allowed(&u("https://example.com/a?b=c")));
        assert!(p.is_allowed(&u("https://EXAMPLE.com/")));
        assert!(p.is_allowed(&u("https://www.example.com/")));
        assert!(p.is_allowed(&u("https://a.b.example.com/")));
        assert!(p.is_allowed(&u("https://example.com./")));
        assert!(p.is_allowed(&u("https://pay.other.org/")));
    }

    #[test]
    fn lookalikes_are_rejected() {
        let p = policy();
        for bad in [
            "https://example.com.evil.com/",
            "https://evil-example.com/",
            "https://notexample.com/",
            "https://evil.com/?u=https://example.com",
            "https://evil.com/https://example.com/",
            "https://evil.com#@example.com",
            "https://example.com@evil.com/",
            "https://user:pw@example.com/",
            "https://example.com:8443/",
            "https://other.org/",
            "https://sub.pay.other.org/",
            "http://example.com/",
            "ftp://example.com/",
            "javascript:alert(1)",
        ] {
            assert!(!p.is_allowed(&u(bad)), "{bad} must be rejected");
        }
    }

    #[test]
    fn explicit_port_rule() {
        let p = DomainPolicy::from_entries(&["localhost:3000"], false);
        assert!(p.is_allowed(&u("http://localhost:3000/")));
        assert!(!p.is_allowed(&u("http://localhost:3001/")));
        assert!(!p.is_allowed(&u("http://localhost/")));
    }

    #[test]
    fn domain_entry_validation() {
        for ok in [
            "example.com",
            "*.example.com",
            "a-b.example.co.uk",
            "example.com:8443",
        ] {
            assert!(parse_domain_entry(ok).is_ok(), "{ok}");
        }
        for bad in [
            "",
            "https://example.com",
            "example.com/path",
            "*.com",
            "*",
            "exa mple.com",
            "-a.com",
            "a..com",
            "user@example.com",
            "example.com:99999",
            "ex*ample.com",
        ] {
            assert!(parse_domain_entry(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn internal_pages() {
        assert!(is_internal(&u("tauri://localhost/offline.html")));
        assert!(is_internal(&u("http://tauri.localhost/offline.html")));
        assert!(!is_internal(&u("https://tauri.localhost.evil.com/")));
        assert!(!is_internal(&u("http://tauri.localhost:8080/")));
        assert!(!is_internal(&u("tauri://evil/")));
    }

    fn feats(ext: bool, pay: bool) -> Features {
        Features {
            external_apps: ext,
            payment_handoff: pay,
            ..Default::default()
        }
    }

    fn sec() -> SecurityConfig {
        SecurityConfig {
            payment_schemes: vec!["upi".into()],
            ..Default::default()
        }
    }

    #[test]
    fn navigation_decisions() {
        let p = policy();
        let s = sec();
        assert_eq!(
            decide(&u("https://example.com/x"), &p, &s, &feats(true, false)),
            NavDecision::Allow
        );
        assert_eq!(
            decide(&u("https://google.com/"), &p, &s, &feats(true, false)),
            NavDecision::OpenExternal
        );
        assert_eq!(
            decide(&u("https://google.com/"), &p, &s, &feats(false, false)),
            NavDecision::Block
        );
        assert_eq!(
            decide(&u("tel:+123"), &p, &s, &feats(true, false)),
            NavDecision::OpenExternal
        );
        assert_eq!(
            decide(&u("tel:+123"), &p, &s, &feats(false, false)),
            NavDecision::Block
        );
        assert_eq!(
            decide(&u("upi://pay?x=1"), &p, &s, &feats(true, false)),
            NavDecision::Block
        );
        assert_eq!(
            decide(&u("upi://pay?x=1"), &p, &s, &feats(true, true)),
            NavDecision::OpenExternal
        );
        assert_eq!(
            decide(&u("javascript:alert(1)"), &p, &s, &feats(true, true)),
            NavDecision::Block
        );
        assert_eq!(
            decide(&u("data:text/html,hi"), &p, &s, &feats(true, true)),
            NavDecision::Block
        );
        assert_eq!(
            decide(&u("file:///etc/passwd"), &p, &s, &feats(true, true)),
            NavDecision::Block
        );
        assert_eq!(
            decide(
                &u("intent://x#Intent;scheme=http;end"),
                &p,
                &s,
                &feats(true, true)
            ),
            NavDecision::Block
        );
        assert_eq!(
            decide(
                &u("blob:https://example.com/1234"),
                &p,
                &s,
                &feats(true, true)
            ),
            NavDecision::Allow
        );
        assert_eq!(
            decide(&u("blob:https://evil.com/1234"), &p, &s, &feats(true, true)),
            NavDecision::Block
        );
        assert_eq!(
            decide(&u("about:blank"), &p, &s, &feats(false, false)),
            NavDecision::Allow
        );
        assert_eq!(
            decide(
                &u("tauri://localhost/offline.html"),
                &p,
                &s,
                &feats(false, false)
            ),
            NavDecision::Allow
        );
    }

    #[test]
    fn generated_capability_file_matches_runtime_policy() {
        let cfg = crate::config::embedded().unwrap();
        let expected = DomainPolicy::from_config(&cfg)
            .unwrap()
            .capability_patterns();
        let file: serde_json::Value =
            serde_json::from_str(include_str!("../capabilities/remote.json")).unwrap();
        let actual: Vec<String> = file["remote"]["urls"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            actual, expected,
            "capabilities/remote.json (build.rs) and DomainPolicy disagree"
        );
        assert_eq!(file["local"], serde_json::json!(false));
        assert_eq!(file["permissions"], serde_json::json!(["allow-bridge"]));
    }

    #[test]
    fn capability_patterns_match_rules() {
        let pats =
            DomainPolicy::from_entries(&["example.com", "*.example.com", "localhost:3000"], true)
                .capability_patterns();
        assert_eq!(
            pats,
            vec![
                "https://example.com",
                "https://*.example.com",
                "https://localhost:3000"
            ]
        );
    }

    #[test]
    fn filename_sanitizing() {
        assert_eq!(sanitize_filename("../../etc/passwd"), "passwd");
        assert_eq!(sanitize_filename("C:\\Windows\\evil.exe"), "evil.exe");
        assert_eq!(sanitize_filename("a<b>:c.pdf"), "a_b__c.pdf");
        assert_eq!(sanitize_filename("CON.txt"), "download");
        assert_eq!(sanitize_filename("...."), "download");
        assert_eq!(sanitize_filename(""), "download");
        assert!(sanitize_filename(&"x".repeat(400)).chars().count() <= 150);
        assert_eq!(sanitize_filename("report.pdf"), "report.pdf");
    }
}
