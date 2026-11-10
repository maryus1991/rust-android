//! Reachability probe used by the Network Manager.
//!
//! IMPORTANT: this is only a *probe* (DNS + TCP connect to the configured site).
//! All real site traffic goes through the OS WebView, never through Rust.

use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Reachability {
    Online,
    /// Host name did not resolve (also what a fully disconnected device looks like).
    DnsFailure,
    /// Resolved, but no address accepted a TCP connection.
    Unreachable,
    Timeout,
}

impl Reachability {
    pub fn is_online(self) -> bool {
        self == Reachability::Online
    }
    pub fn reason(self) -> &'static str {
        match self {
            Reachability::Online => "online",
            Reachability::DnsFailure => "dns",
            Reachability::Unreachable => "unreachable",
            Reachability::Timeout => "timeout",
        }
    }
}

pub fn probe(host: &str, port: u16, timeout: Duration) -> Reachability {
    let addrs: Vec<_> = match (host, port).to_socket_addrs() {
        Ok(a) => a.collect(),
        Err(_) => return Reachability::DnsFailure,
    };
    if addrs.is_empty() {
        return Reachability::DnsFailure;
    }
    let mut saw_timeout = false;
    for addr in addrs {
        match TcpStream::connect_timeout(&addr, timeout) {
            Ok(_) => return Reachability::Online,
            Err(e)
                if e.kind() == std::io::ErrorKind::TimedOut
                    || e.kind() == std::io::ErrorKind::WouldBlock =>
            {
                saw_timeout = true
            }
            Err(_) => {}
        }
    }
    if saw_timeout {
        Reachability::Timeout
    } else {
        Reachability::Unreachable
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn online_when_listener_exists() {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        assert_eq!(
            probe("127.0.0.1", port, Duration::from_secs(2)),
            Reachability::Online
        );
    }

    #[test]
    fn unreachable_when_port_closed() {
        let port = {
            let l = TcpListener::bind("127.0.0.1:0").unwrap();
            l.local_addr().unwrap().port()
        };
        let r = probe("127.0.0.1", port, Duration::from_secs(2));
        assert!(matches!(
            r,
            Reachability::Unreachable | Reachability::Timeout
        ));
    }

    #[test]
    fn dns_failure_for_invalid_host() {
        assert_eq!(
            probe("host.invalid", 443, Duration::from_secs(2)),
            Reachability::DnsFailure
        );
    }
}
