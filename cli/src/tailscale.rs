//! Tailscale peers as discovery candidates.
//!
//! Multicast does not cross the tailnet, so LocalSend devices on other
//! Tailscale nodes are found by probing their Tailscale addresses directly.

use localsend::discovery::HttpChannel;
use localsend::model::discovery::ProtocolType;
use serde::Deserialize;
use std::collections::HashMap;
use std::net::IpAddr;
use std::time::Duration;

/// A node of the tailnet other than this one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TailscalePeer {
    pub name: String,
    pub ip: IpAddr,
    pub os: String,

    /// Tailscale's own online flag. It lags behind for idle nodes, so it is
    /// shown but not used to skip a peer.
    pub online: bool,
}

#[derive(Deserialize)]
struct Status {
    #[serde(rename = "Self")]
    self_node: Option<Node>,
    #[serde(rename = "Peer")]
    peer: Option<HashMap<String, Node>>,
}

#[derive(Deserialize)]
struct Node {
    #[serde(rename = "HostName")]
    host_name: Option<String>,
    #[serde(rename = "DNSName")]
    dns_name: Option<String>,
    #[serde(rename = "OS")]
    os: Option<String>,
    #[serde(rename = "TailscaleIPs")]
    tailscale_ips: Option<Vec<String>>,
    #[serde(rename = "Online")]
    online: Option<bool>,
}

impl Node {
    fn ips(&self) -> Vec<IpAddr> {
        self.tailscale_ips
            .iter()
            .flatten()
            .filter_map(|ip| ip.parse::<IpAddr>().ok())
            .collect()
    }

    fn name(&self) -> String {
        // The DNS name is unique in the tailnet, the host name is not.
        self.dns_name
            .as_deref()
            .and_then(|dns| dns.split('.').next())
            .filter(|name| !name.is_empty())
            .or(self.host_name.as_deref())
            .unwrap_or("")
            .to_string()
    }
}

/// Parses the output of `tailscale status --json` into the peers, sorted by
/// name. Each peer is reachable at its first IPv4 address (IPv6 if it has
/// none); peers sharing an address with this node are skipped.
pub fn parse_status(json: &str) -> anyhow::Result<Vec<TailscalePeer>> {
    let status: Status = serde_json::from_str(json)?;
    let self_ips = status.self_node.as_ref().map(Node::ips).unwrap_or_default();

    let mut peers: Vec<TailscalePeer> = status
        .peer
        .unwrap_or_default()
        .into_values()
        .filter_map(|node| {
            let ips = node.ips();
            let ip = ips
                .iter()
                .find(|ip| ip.is_ipv4())
                .or_else(|| ips.first())
                .copied()?;
            if self_ips.contains(&ip) {
                return None;
            }
            Some(TailscalePeer {
                name: node.name(),
                ip,
                os: node.os.clone().unwrap_or_default(),
                online: node.online.unwrap_or(false),
            })
        })
        .collect();
    peers.sort_by(|a, b| a.name.cmp(&b.name).then(a.ip.cmp(&b.ip)));
    Ok(peers)
}

/// Runs `tailscale status --json`. Fails when Tailscale is not installed or
/// not running.
pub async fn peers() -> anyhow::Result<Vec<TailscalePeer>> {
    let output = tokio::time::timeout(
        Duration::from_secs(5),
        tokio::process::Command::new("tailscale")
            .args(["status", "--json"])
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| anyhow::anyhow!("tailscale status --json timed out after 5s"))??;
    anyhow::ensure!(
        output.status.success(),
        "tailscale status --json failed: status={} stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    parse_status(&String::from_utf8_lossy(&output.stdout))
}

/// The LocalSend addresses to probe for [peers] (HTTPS, like the app).
pub fn channels(peers: &[TailscalePeer], port: u16) -> Vec<HttpChannel> {
    peers
        .iter()
        .map(|peer| HttpChannel {
            host: peer.ip.to_string(),
            port,
            protocol: ProtocolType::Https,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const STATUS: &str = r#"{
        "Self": {"HostName": "chenxiaobai", "DNSName": "chenxiaobai.tail1234.ts.net.", "OS": "linux",
                 "TailscaleIPs": ["100.93.84.127", "fd7a:115c:a1e0::1"], "Online": true},
        "Peer": {
            "nodekey:b": {"HostName": "MacBook Air", "DNSName": "macbook-air.tail1234.ts.net.", "OS": "macOS",
                          "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.75.58.59"], "Online": false},
            "nodekey:a": {"HostName": "localhost", "DNSName": "mate-30-5g.tail1234.ts.net.", "OS": "android",
                          "TailscaleIPs": ["100.75.118.59"], "Online": true},
            "nodekey:c": {"HostName": "no-ip", "DNSName": "", "OS": "linux", "TailscaleIPs": []}
        }
    }"#;

    #[test]
    fn parses_peers_prefers_ipv4_and_keeps_offline_ones() {
        let peers = parse_status(STATUS).unwrap();
        assert_eq!(
            peers,
            vec![
                TailscalePeer {
                    name: "macbook-air".to_string(),
                    ip: "100.75.58.59".parse().unwrap(),
                    os: "macOS".to_string(),
                    online: false,
                },
                TailscalePeer {
                    name: "mate-30-5g".to_string(),
                    ip: "100.75.118.59".parse().unwrap(),
                    os: "android".to_string(),
                    online: true,
                },
            ]
        );
    }

    #[test]
    fn skips_peers_with_an_address_of_this_node() {
        let json = r#"{"Self": {"TailscaleIPs": ["100.1.1.1"]},
                       "Peer": {"k": {"HostName": "dup", "TailscaleIPs": ["100.1.1.1"]}}}"#;
        assert!(parse_status(json).unwrap().is_empty());
    }

    #[test]
    fn handles_a_status_without_peers() {
        assert!(parse_status(r#"{"Self": null}"#).unwrap().is_empty());
    }

    #[test]
    fn builds_https_channels() {
        let peers = parse_status(STATUS).unwrap();
        let channels = channels(&peers, 53317);
        assert_eq!(channels.len(), 2);
        assert_eq!(channels[0].host, "100.75.58.59");
        assert_eq!(channels[0].port, 53317);
        assert_eq!(channels[0].protocol, ProtocolType::Https);
    }
}
